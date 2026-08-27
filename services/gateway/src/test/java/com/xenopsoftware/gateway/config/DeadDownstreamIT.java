package com.xenopsoftware.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers.mockUser;
import static org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers.springSecurity;

import com.xenopsoftware.gateway.IntegrationTest;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.micrometer.core.instrument.MeterRegistry;
import java.io.IOException;
import java.net.InetAddress;
import java.net.ServerSocket;
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
 * What the gateway does when core is not there (T-3.9).
 *
 * <p>The route is pointed at a port nothing listens on. Connection-refused rather than a black
 * hole, deliberately: it is immediate and deterministic, where a timeout test would have to wait
 * out the real timeout on every run and would still be timing-dependent. The path through the
 * gateway is the same one a hung downstream takes once its timeout fires — what differs is only
 * how long the failure takes to arrive.
 *
 * <p>What this proves is that a dead downstream produces a <b>bounded, described failure</b>
 * rather than a hang. Without the circuit breaker and the fallback, a caller gets whatever Spring
 * decides to render, after however long the transport takes to give up, and the gateway keeps
 * spending connections on a service that cannot answer.
 */
@IntegrationTest
// The route is declared here rather than inherited from production config, because
// src/test/resources/config/application.yml REPLACES the main file on the test classpath and
// declares no routes at all -- a request to /services/core/** falls through to the static resource
// handler and 404s, which reads as a routing bug rather than as missing test configuration.
//
// So this exercises the resilience WIRING -- breaker, fallback, timeouts -- against a route shaped
// like the real one. GatewayRouteConfigurationTest covers the other half: that production actually
// declares the filter. Neither test is sufficient alone.
@TestPropertySource(
    properties = {
        "spring.cloud.gateway.server.webflux.routes[0].id=core",
        "spring.cloud.gateway.server.webflux.routes[0].uri=http://127.0.0.1:${refused.port}",
        "spring.cloud.gateway.server.webflux.routes[0].predicates[0]=Path=/services/core/**",
        "spring.cloud.gateway.server.webflux.routes[0].filters[0].name=StripPrefix",
        "spring.cloud.gateway.server.webflux.routes[0].filters[0].args.parts=2",
        "spring.cloud.gateway.server.webflux.routes[0].filters[1].name=CircuitBreaker",
        "spring.cloud.gateway.server.webflux.routes[0].filters[1].args.name=core",
        "spring.cloud.gateway.server.webflux.routes[0].filters[1].args.fallbackUri=forward:/fallback/core",
        // The resilience4j block lives in the main application.yml, which the test classpath
        // replaces -- so without these the breaker runs on LIBRARY defaults: a sliding window of
        // 100 and a minimum of 100 calls. Twelve failures would not open it, and the test would
        // read as "the breaker does not work" when it was never configured.
        //
        // Deliberately smaller than production so the test is fast and deterministic rather than
        // a hundred round trips. What is under test is the behaviour, not the numbers.
        "resilience4j.circuitbreaker.instances.core.slidingWindowType=COUNT_BASED",
        "resilience4j.circuitbreaker.instances.core.slidingWindowSize=10",
        "resilience4j.circuitbreaker.instances.core.minimumNumberOfCalls=5",
        "resilience4j.circuitbreaker.instances.core.failureRateThreshold=50",
        "resilience4j.circuitbreaker.instances.core.waitDurationInOpenState=10s",
        "resilience4j.circuitbreaker.instances.core.automaticTransitionFromOpenToHalfOpenEnabled=false",
        // Bounded explicitly, because the library defaults are not the regime production runs in
        // and this test's timings should not depend on them. Production allows 2s to connect
        // against a 12s limiter; the same shape, scaled down.
        "spring.cloud.gateway.server.webflux.httpclient.connect-timeout=250",
        "resilience4j.timelimiter.instances.core.timeoutDuration=2s",
        // The management config is likewise absent from the test file.
        "management.endpoints.web.exposure.include=health,prometheus",
        "management.endpoints.web.base-path=/management",
    }
)
class DeadDownstreamIT {

    // WHICH FAILURE THIS TEST PRODUCES USED TO DEPEND ON THE MACHINE (T-5.11).
    //
    // The route used to point at 127.0.0.1:1 -- privileged, never bound in a test environment, so
    // "connections are refused immediately". That holds on Linux and CI. It does not hold on
    // Windows, where a connect to that port is dropped rather than refused: nothing came back,
    // the TimeLimiter fired, and the test was quietly exercising a TIMEOUT while claiming to
    // exercise a refusal.
    //
    // Nobody could have noticed while FallbackResource returned one fixed sentence for every
    // cause. It became visible the moment that body started telling the truth (T-5.11), because
    // a refusal and a timeout now say opposite things about whether the request had an effect --
    // and this test asserts the refusal's half of that.
    //
    // A port that was bound and then closed is refused on every platform, and cannot collide with
    // something real the way a guessed high port can.
    private static final int REFUSED_PORT = portNobodyIsListeningOn();

    @DynamicPropertySource
    static void refusedPort(DynamicPropertyRegistry registry) {
        // Registered as its own key and referenced by placeholder above, NOT as `routes[0].uri`.
        // Spring Boot binds an indexed collection from ONE property source, so a dynamic source
        // contributing a single `routes[0].*` key wins the whole list and silently discards every
        // route key declared above -- which surfaces as "routes[0].predicates must not be empty".
        registry.add("refused.port", () -> REFUSED_PORT);
    }

    private static int portNobodyIsListeningOn() {
        try (ServerSocket socket = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
            return socket.getLocalPort();
        } catch (IOException e) {
            throw new IllegalStateException("could not reserve a port to close", e);
        }
    }

    @Autowired
    private ApplicationContext context;

    @Autowired
    private CircuitBreakerRegistry circuitBreakerRegistry;

    @Autowired
    private MeterRegistry meterRegistry;

    private WebTestClient webTestClient;

    @BeforeEach
    void setUp() {
        // apply(springSecurity()) is required for mockUser() to have any effect. Without it the
        // mutator is silently inert and every request arrives unauthenticated -- which surfaces
        // as 401 where the test expected a downstream failure, pointing at the wrong subsystem.
        webTestClient = WebTestClient.bindToApplicationContext(context).apply(springSecurity()).configureClient().build();
        circuitBreakerRegistry.circuitBreaker("core").reset();
    }

    private WebTestClient.ResponseSpec callCore() {
        return webTestClient.mutateWith(mockUser()).get().uri("/services/core/api/anything").exchange();
    }

    @Test
    void aDeadDownstreamProducesAProblemDocumentRatherThanAHangOrAStackTrace() {
        callCore()
            .expectStatus()
            .isEqualTo(503)
            .expectHeader()
            .contentTypeCompatibleWith(MediaType.APPLICATION_PROBLEM_JSON)
            // An open or failing circuit has a known duration, so the server can answer
            // "when should I come back" instead of leaving the client to invent a backoff.
            .expectHeader()
            .exists(HttpHeaders.RETRY_AFTER)
            .expectBody()
            .jsonPath("$.status")
            .isEqualTo(503)
            .jsonPath("$.title")
            .isEqualTo("Service unavailable")
            // The client needs to know the request had no effect. A timeout leaves that
            // ambiguous; a short-circuited request definitively did not reach the service.
            .jsonPath("$.detail")
            .value(detail -> assertThat((String) detail).contains("had no effect"));
    }

    @Test
    void repeatedFailuresOpenTheCircuitSoLaterCallsAreNotEvenAttempted() {
        CircuitBreaker breaker = circuitBreakerRegistry.circuitBreaker("core");
        assertThat(breaker.getState()).isEqualTo(CircuitBreaker.State.CLOSED);

        // Above minimumNumberOfCalls for this test's window; below that, a failure rate is not
        // evidence of anything.
        for (int i = 0; i < 8; i++) {
            callCore().expectStatus().isEqualTo(503);
        }

        assertThat(breaker.getState())
            .as("after sustained failure the breaker must stop forwarding, not keep spending connections")
            .isIn(CircuitBreaker.State.OPEN, CircuitBreaker.State.HALF_OPEN);

        long notPermitted = (long) breaker.getMetrics().getNumberOfNotPermittedCalls();
        // The caller still gets 503; the difference is that this one cost nothing downstream.
        callCore().expectStatus().isEqualTo(503);
        assertThat((long) breaker.getMetrics().getNumberOfNotPermittedCalls())
            .as("a call made while open is rejected outright rather than forwarded")
            .isGreaterThan(notPermitted);
    }

    @Test
    void circuitBreakerActivityIsRecordedAsMetrics() {
        callCore().expectStatus().isEqualTo(503);

        // Asserted against the MeterRegistry rather than by scraping /management/prometheus.
        // The actuator exposure list lives in the main application.yml, which the test classpath
        // replaces -- so an HTTP assertion here would be testing this test's own synthetic
        // config, not what a deployment exposes. That half is checked statically by
        // GatewayRouteConfigurationTest, against the real file.
        //
        // What this proves is the part a static read cannot: the breaker is actually instrumented
        // and emitting. A breaker whose state nothing records is one nobody will notice opening.
        assertThat(meterRegistry.find("resilience4j.circuitbreaker.calls").meters())
            .as("the breaker must record call outcomes")
            .isNotEmpty();

        assertThat(meterRegistry.find("resilience4j.circuitbreaker.state").gauges())
            .as("state must be observable, not merely internal")
            .isNotEmpty();
    }
}
