package com.xenopsoftware.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers.mockUser;
import static org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers.springSecurity;

import com.xenopsoftware.gateway.IntegrationTest;
import io.github.resilience4j.bulkhead.Bulkhead;
import io.github.resilience4j.bulkhead.BulkheadRegistry;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import java.io.IOException;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.ApplicationContext;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.reactive.server.WebTestClient;

/**
 * The gateway shedding load rather than collapsing under it (T-5.11).
 *
 * <p>T-5.10 measured a stack whose only defence against overload was a circuit breaker, which is a
 * binary control: it serves everything or nothing. At 1600 req/s offered it served 154. The missing
 * piece was a concurrency limit that refuses the excess and keeps serving the rest — the bulkhead,
 * which was declared, wired, and set to a ceiling four times higher than any concurrency the system
 * ever reached, so it had never once refused a request.
 *
 * <p>Three things have to hold for that to be fixed, and none of them is visible in a metric:
 *
 * <ol>
 *   <li>a request arriving at a full bulkhead is refused <b>without being forwarded</b> — shedding
 *       is only cheap if the refused request costs nothing downstream;
 *   <li>shedding <b>does not open the circuit breaker</b>. The breaker sits outside the bulkhead,
 *       so without {@code ignoreExceptions} the gateway's own admission control reads as evidence
 *       that core is failing, and the outage T-5.10 measured comes straight back;
 *   <li>the caller is told <b>which</b> of these happened, because a refused request definitely had
 *       no effect and a timed-out one may well have committed.
 * </ol>
 *
 * <p>The downstream here is a socket that accepts connections and never answers, rather than the
 * closed port {@code DeadDownstreamIT} uses. That is deliberate: with a black hole behind it, a
 * bulkhead that quietly failed to apply would produce a <em>timeout</em> rather than a refusal, and
 * the tests below would fail on the message instead of passing for the wrong reason.
 */
@IntegrationTest
// Same reason as DeadDownstreamIT: src/test/resources/config/application.yml REPLACES the main
// file on the test classpath, so the production route and the whole resilience4j block are absent
// and have to be restated here. GatewayRouteConfigurationTest covers the other half -- that the
// production file actually declares this posture.
@TestPropertySource(
    properties = {
        "spring.cloud.gateway.server.webflux.routes[0].id=core",
        // Resolved from the property @DynamicPropertySource registers below, NOT registered as
        // `routes[0].uri` directly. Spring Boot binds an indexed collection from ONE property
        // source: a dynamic source contributing a single `routes[0].*` key wins the whole list and
        // every key declared here is dropped, which surfaces as "routes[0].predicates must not be
        // empty" and reads like a typo in this block.
        "spring.cloud.gateway.server.webflux.routes[0].uri=http://127.0.0.1:${black-hole.port}",
        "spring.cloud.gateway.server.webflux.routes[0].predicates[0]=Path=/services/core/**",
        "spring.cloud.gateway.server.webflux.routes[0].filters[0].name=StripPrefix",
        "spring.cloud.gateway.server.webflux.routes[0].filters[0].args.parts=2",
        "spring.cloud.gateway.server.webflux.routes[0].filters[1].name=CircuitBreaker",
        "spring.cloud.gateway.server.webflux.routes[0].filters[1].args.name=core",
        "spring.cloud.gateway.server.webflux.routes[0].filters[1].args.fallbackUri=forward:/fallback/core",
        // ONE permit, so "full" is reachable by holding exactly one call. Production carries 8;
        // what is under test is the behaviour at the limit, not the limit.
        "resilience4j.bulkhead.instances.core.maxConcurrentCalls=1",
        // Zero is not a tuning choice. A non-zero wait makes SemaphoreBulkhead park the calling
        // thread, and the calling thread here is a Netty event loop.
        "resilience4j.bulkhead.instances.core.maxWaitDuration=0",
        // The line this test exists to prove the value of. Remove it and
        // sheddingLoadDoesNotOpenTheCircuit fails.
        "resilience4j.circuitbreaker.instances.core.ignoreExceptions=io.github.resilience4j.bulkhead.BulkheadFullException",
        "resilience4j.circuitbreaker.instances.core.slidingWindowType=COUNT_BASED",
        "resilience4j.circuitbreaker.instances.core.slidingWindowSize=10",
        "resilience4j.circuitbreaker.instances.core.minimumNumberOfCalls=5",
        "resilience4j.circuitbreaker.instances.core.failureRateThreshold=50",
        "resilience4j.circuitbreaker.instances.core.waitDurationInOpenState=2s",
        "resilience4j.circuitbreaker.instances.core.automaticTransitionFromOpenToHalfOpenEnabled=false",
        // Short enough that the timeout case below is a test rather than a wait. Production
        // allows 12s.
        "resilience4j.timelimiter.instances.core.timeoutDuration=500ms",
        "management.endpoints.web.exposure.include=health,prometheus",
        "management.endpoints.web.base-path=/management",
    }
)
class BulkheadIT {

    /**
     * Accepts connections and answers none of them. A closed port would be refused immediately,
     * which is a different failure and would let a broken bulkhead look like a working one.
     */
    private static final ServerSocket BLACK_HOLE = openBlackHole();

    private static final List<Socket> ACCEPTED = Collections.synchronizedList(new ArrayList<>());

    @DynamicPropertySource
    static void downstream(DynamicPropertyRegistry registry) {
        // Port 0 rather than a literal: a fixed port collides with whatever else the machine
        // running the build happens to have bound, and does it intermittently.
        registry.add("black-hole.port", BLACK_HOLE::getLocalPort);
    }

    @Autowired
    private ApplicationContext context;

    @Autowired
    private BulkheadRegistry bulkheadRegistry;

    @Autowired
    private CircuitBreakerRegistry circuitBreakerRegistry;

    @Autowired
    private MeterRegistry meterRegistry;

    private WebTestClient webTestClient;

    private boolean permitHeld;

    @BeforeEach
    void setUp() {
        // apply(springSecurity()) is required for mockUser() to have any effect; without it every
        // request arrives unauthenticated and 401s, pointing at the wrong subsystem.
        webTestClient = WebTestClient.bindToApplicationContext(context).apply(springSecurity()).configureClient().build();
        circuitBreakerRegistry.circuitBreaker("core").reset();

        // NOT bulkheadRegistry.remove("core"). The instance's size comes from the properties above
        // and is applied when resilience4j-spring-boot3 registers it at startup; re-creating it
        // from the registry afterwards yields the registry's DEFAULT config -- 25 permits -- and
        // every assertion below would then pass or fail for reasons unrelated to what it names.
        assertThat(bulkheadRegistry.bulkhead("core").getMetrics().getAvailableConcurrentCalls())
            .as("a previous test leaked a permit; the ones that follow would be testing a full bulkhead by accident")
            .isEqualTo(1);
    }

    @AfterEach
    void releaseHeldPermit() {
        if (permitHeld) {
            bulkheadRegistry.bulkhead("core").releasePermission();
            permitHeld = false;
        }
    }

    private Bulkhead coreBulkhead() {
        return bulkheadRegistry.bulkhead("core");
    }

    /** Occupies the only permit, so the next request through the route meets a full bulkhead. */
    private void fillTheBulkhead() {
        assertThat(coreBulkhead().tryAcquirePermission()).as("hold the only permit").isTrue();
        permitHeld = true;
    }

    private WebTestClient.ResponseSpec callCore() {
        return webTestClient.mutateWith(mockUser()).get().uri("/services/core/api/anything").exchange();
    }

    @Test
    void theRouteIsGovernedByTheBulkheadInstanceTheConfigurationNames() {
        // The reactive CircuitBreaker resolves the bulkhead by the breaker's id, so the `core`
        // filter argument and the `core` bulkhead instance are joined by a string. Nothing fails
        // if they stop matching -- the call silently gets a fresh library-default bulkhead of 25
        // instead, which is above anything this stack reaches and so limits nothing.
        assertThat(coreBulkhead().getBulkheadConfig().getMaxConcurrentCalls())
            .as("the bulkhead the route actually acquires from must be the configured one")
            .isEqualTo(1);
    }

    @Test
    void aRequestArrivingAtAFullBulkheadIsRefusedWithoutBeingForwarded() {
        fillTheBulkhead();
        int connectionsBefore = ACCEPTED.size();

        callCore()
            .expectStatus()
            .isEqualTo(503)
            .expectHeader()
            .contentTypeCompatibleWith(MediaType.APPLICATION_PROBLEM_JSON)
            // A permit frees the moment an in-flight call finishes, so the honest answer is
            // "about a second", not the breaker's open-state duration.
            .expectHeader()
            .valueEquals(HttpHeaders.RETRY_AFTER, "1")
            .expectBody()
            .jsonPath("$.status")
            .isEqualTo(503)
            // The part a caller acts on. A refused call is the one case where the gateway can
            // promise this, and it must not say it about a timeout.
            .jsonPath("$.detail")
            .value(detail -> {
                assertThat((String) detail).contains("had no effect");
                assertThat((String) detail)
                    .as("the reason must distinguish shedding from an open circuit -- they need different responses from the caller")
                    .contains("concurrent");
                assertThat((String) detail).doesNotContain("circuit is open");
            });

        assertThat(ACCEPTED).as("a refused request must cost the downstream nothing at all").hasSize(connectionsBefore);
    }

    @Test
    void sheddingLoadDoesNotOpenTheCircuit() {
        // This is the T-5.10 failure written as a test. The breaker sits OUTSIDE the bulkhead, so
        // every rejection passes through it; counted, they are a 100% failure rate, and the
        // breaker opens and cuts off a downstream that was never even asked.
        CircuitBreaker breaker = circuitBreakerRegistry.circuitBreaker("core");
        fillTheBulkhead();

        // Comfortably above minimumNumberOfCalls for this test's window: if rejections were being
        // recorded, the breaker would be open several times over by the end of this loop.
        for (int i = 0; i < 20; i++) {
            callCore().expectStatus().isEqualTo(503);
        }

        assertThat(breaker.getState())
            .as("the gateway refusing work is not the downstream failing, and must not be counted as it")
            .isEqualTo(CircuitBreaker.State.CLOSED);
        assertThat(breaker.getMetrics().getNumberOfFailedCalls()).isZero();
        assertThat(breaker.getMetrics().getNumberOfBufferedCalls())
            .as("ignored, not recorded as successes -- shedding must not mask a real failure rate either")
            .isZero();
    }

    @Test
    void aTimedOutRequestIsNotDescribedAsHavingHadNoEffect() {
        // The bug T-5.10 flagged and this fixes. The fallback used to return one fixed sentence --
        // "the request was not forwarded, so it had no effect" -- for every reason it was reached,
        // including this one, where the request WAS forwarded and may have committed.
        callCore()
            .expectStatus()
            .isEqualTo(503)
            .expectBody()
            .jsonPath("$.detail")
            .value(detail -> {
                assertThat((String) detail)
                    .as("a timed-out request may have reached the downstream; claiming otherwise is the one lie a caller acts on")
                    .doesNotContain("had no effect");
                assertThat((String) detail).contains("may have taken effect");
            });
    }

    @Test
    void bulkheadActivityIsRecordedAsMetrics() {
        fillTheBulkhead();
        callCore().expectStatus().isEqualTo(503);

        // A limit nobody can see is a limit nobody will notice binding -- which is exactly how
        // this one sat at its declared ceiling through a 2000 req/s run without comment.
        assertThat(meterRegistry.find("resilience4j.bulkhead.available.concurrent.calls").gauges())
            .as("available permits must be observable")
            .isNotEmpty();

        // And the gauge alone is not enough: Resilience4j counts permits, never refusals, so a
        // scrape sees shedding only if it lands mid-refusal. The reason tag is what separates
        // "the system is shedding, as designed" from "the circuit is open", which arrive at the
        // caller as the same 503 and mean opposite things.
        assertThat(meterRegistry.find("gateway.fallback").tag("reason", "bulkhead_full").counter())
            .as("shedding must be countable, not merely inferable from a gauge that happened to dip")
            .isNotNull()
            .extracting(Counter::count)
            .isEqualTo(1.0d);
    }

    @AfterAll
    static void closeBlackHole() throws IOException {
        for (Socket socket : ACCEPTED) {
            socket.close();
        }
        BLACK_HOLE.close();
    }

    private static ServerSocket openBlackHole() {
        try {
            ServerSocket socket = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
            Thread accepter = new Thread(() -> {
                while (!socket.isClosed()) {
                    try {
                        // Held open and never written to. Closing the accepted socket would
                        // turn this into a reset, which is a different failure again.
                        ACCEPTED.add(socket.accept());
                    } catch (IOException stopping) {
                        return;
                    }
                }
            }, "bulkhead-it-black-hole");
            accepter.setDaemon(true);
            accepter.start();
            return socket;
        } catch (IOException e) {
            throw new IllegalStateException("could not open the stand-in downstream", e);
        }
    }
}
