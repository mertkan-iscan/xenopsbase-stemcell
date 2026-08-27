package com.xenopsoftware.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;

import io.github.resilience4j.bulkhead.Bulkhead;
import io.github.resilience4j.bulkhead.BulkheadConfig;
import io.github.resilience4j.bulkhead.BulkheadFullException;
import io.github.resilience4j.bulkhead.BulkheadRegistry;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.github.resilience4j.timelimiter.TimeLimiterRegistry;
import java.time.Duration;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.cloud.circuitbreaker.resilience4j.ReactiveResilience4JCircuitBreakerFactory;
import org.springframework.cloud.circuitbreaker.resilience4j.ReactiveResilience4jBulkheadProvider;
import org.springframework.cloud.circuitbreaker.resilience4j.Resilience4JConfigurationProperties;
import org.springframework.cloud.client.circuitbreaker.ReactiveCircuitBreaker;
import reactor.core.publisher.Mono;

/**
 * How the gateway's bulkhead is actually reached, asserted against the real upstream classes
 * (T-5.11).
 *
 * <h2>Why this test exists</h2>
 *
 * T-5.10 reported the bulkhead as <b>inert</b> and explained it as "reactive Spring Cloud Gateway
 * does not apply Resilience4j bulkheads at all". <b>That explanation was wrong</b> — see the
 * retraction in {@code docs/slos.md}. On the version this service pins,
 * {@code ReactiveResilience4JCircuitBreaker.run()} does decorate the call with a bulkhead. The
 * bulkhead did nothing for a much duller reason: it was sized above any concurrency the stack ever
 * reached.
 *
 * <p>The correction is only worth as much as the evidence behind it, and reading bytecode is not
 * evidence a build can re-check. So this asserts the three things the fix depends on, by running
 * them:
 *
 * <ol>
 *   <li>the bulkhead is applied at all;
 *   <li>it is resolved by the breaker's <b>id</b>, which is what makes the {@code core} instance in
 *       {@code application.yml} the one that governs the {@code core} route — the provider is
 *       called with {@code groupName}, and {@code create(id)} sets the group to the id, so a future
 *       release that groups routes differently would silently swap the bulkhead for a default one;
 *   <li>the breaker sits <b>outside</b> the bulkhead, so a rejection reaches the breaker as a
 *       throwable it will count unless told not to.
 * </ol>
 *
 * <p>Nesting matters more than it looks. The YAML lists {@code circuitbreaker}, {@code timelimiter}
 * and {@code bulkhead} as three peers; the runtime composes them as
 * {@code fallback(timeLimiter(circuitBreaker(bulkhead(call))))}. If that ever inverts, the
 * {@code ignoreExceptions} entry in {@code application.yml} becomes both unnecessary and
 * misleading, and this test says so by failing.
 *
 * <p>Deliberately built from the upstream classes directly rather than from a Spring context. A
 * context test would prove this application is wired correctly today; this proves what the library
 * does, which is the part that changes underneath us on an upgrade.
 */
class ReactiveBulkheadWiringTest {

    private static final String INSTANCE = "core";

    /** One permit, so "full" is reachable by holding exactly one call. */
    private static final BulkheadConfig ONE_AT_A_TIME = BulkheadConfig.custom()
        .maxConcurrentCalls(1)
        .maxWaitDuration(Duration.ZERO)
        .build();

    private BulkheadRegistry bulkheadRegistry;
    private CircuitBreakerRegistry circuitBreakerRegistry;
    private ReactiveResilience4JCircuitBreakerFactory factory;

    @BeforeEach
    void setUp() {
        bulkheadRegistry = BulkheadRegistry.ofDefaults();
        // Registered under the instance name BEFORE the factory ever asks for it, exactly as
        // resilience4j-spring-boot3 registers `resilience4j.bulkhead.instances.core` at startup.
        // The provider does computeIfAbsent, so if it looks up this name it gets this config, and
        // if it looks up any other name it gets a fresh library-default bulkhead of 25.
        bulkheadRegistry.bulkhead(INSTANCE, ONE_AT_A_TIME);

        circuitBreakerRegistry = CircuitBreakerRegistry.ofDefaults();
        factory = new ReactiveResilience4JCircuitBreakerFactory(
            circuitBreakerRegistry,
            TimeLimiterRegistry.ofDefaults(),
            new ReactiveResilience4jBulkheadProvider(bulkheadRegistry),
            new Resilience4JConfigurationProperties()
        );
    }

    private ReactiveCircuitBreaker breakerForCore() {
        // The single-argument form is what SpringCloudCircuitBreakerFilterFactory calls with the
        // route filter's `name: core`.
        return factory.create(INSTANCE);
    }

    @Test
    void theBulkheadNamedByTheBreakerIdIsTheOneThatGovernsTheCall() {
        Bulkhead core = bulkheadRegistry.bulkhead(INSTANCE);
        assertThat(core.getMetrics().getAvailableConcurrentCalls()).isEqualTo(1);

        AtomicReference<Integer> availableDuringCall = new AtomicReference<>();
        String result = breakerForCore()
            .run(
                Mono.fromSupplier(() -> {
                    availableDuringCall.set(core.getMetrics().getAvailableConcurrentCalls());
                    return "answered";
                }),
                throwable -> Mono.just("fell back")
            )
            .block(Duration.ofSeconds(5));

        assertThat(result).isEqualTo("answered");
        assertThat(availableDuringCall.get())
            .as("a call in flight must hold a permit from the `%s` bulkhead, or nothing is limiting concurrency", INSTANCE)
            .isZero();
        assertThat(core.getMetrics().getAvailableConcurrentCalls()).as("the permit must be released when the call completes").isEqualTo(1);
    }

    @Test
    void aCallArrivingAtAFullBulkheadIsRejectedWithoutReachingTheDownstream() {
        Bulkhead core = bulkheadRegistry.bulkhead(INSTANCE);
        // Hold the only permit. Deterministic where firing concurrent requests and hoping they
        // overlap is not.
        assertThat(core.tryAcquirePermission()).isTrue();

        AtomicBoolean downstreamCalled = new AtomicBoolean();
        AtomicReference<Throwable> seenByFallback = new AtomicReference<>();

        String result = breakerForCore()
            .run(
                Mono.fromSupplier(() -> {
                    downstreamCalled.set(true);
                    return "answered";
                }),
                throwable -> {
                    seenByFallback.set(throwable);
                    return Mono.just("fell back");
                }
            )
            .block(Duration.ofSeconds(5));

        assertThat(result).isEqualTo("fell back");
        assertThat(downstreamCalled).as("shedding is only cheap if the refused call never reaches the downstream").isFalse();
        // FallbackResource classifies on exactly this type to tell the caller its request had no
        // effect, and to set a Retry-After of a second rather than the breaker's open duration.
        assertThat(seenByFallback.get()).isInstanceOf(BulkheadFullException.class);
    }

    @Test
    void theBreakerIsOutsideTheBulkheadSoARejectionIsCountedUnlessIgnored() {
        // The default config used here does NOT ignore BulkheadFullException. That is the point:
        // this test documents what happens without the `ignoreExceptions` entry that
        // application.yml now carries, and it is the loop that recreates T-5.10's outage --
        // the gateway's own admission control read as evidence that core is failing.
        Bulkhead core = bulkheadRegistry.bulkhead(INSTANCE);
        assertThat(core.tryAcquirePermission()).isTrue();

        breakerForCore()
            .run(Mono.just("answered"), throwable -> Mono.just("fell back"))
            .block(Duration.ofSeconds(5));

        CircuitBreaker breaker = circuitBreakerRegistry.circuitBreaker(INSTANCE);
        assertThat(breaker.getMetrics().getNumberOfFailedCalls())
            .as("a bulkhead rejection must pass THROUGH the breaker, which is what makes ignoreExceptions necessary")
            .isEqualTo(1);
    }

    @Test
    void ignoringBulkheadFullExceptionStopsSheddingFromOpeningTheBreaker() {
        // The production posture, asserted end to end: the same rejection, against a breaker
        // configured the way application.yml configures it.
        CircuitBreakerRegistry ignoring = CircuitBreakerRegistry.of(
            CircuitBreakerConfig.custom().ignoreExceptions(BulkheadFullException.class).build()
        );
        ReactiveResilience4JCircuitBreakerFactory configured = new ReactiveResilience4JCircuitBreakerFactory(
            ignoring,
            TimeLimiterRegistry.ofDefaults(),
            new ReactiveResilience4jBulkheadProvider(bulkheadRegistry),
            new Resilience4JConfigurationProperties()
        );

        Bulkhead core = bulkheadRegistry.bulkhead(INSTANCE);
        assertThat(core.tryAcquirePermission()).isTrue();

        String result = configured
            .create(INSTANCE)
            .run(Mono.just("answered"), throwable -> Mono.just("fell back"))
            .block(Duration.ofSeconds(5));

        assertThat(result).isEqualTo("fell back");

        CircuitBreaker breaker = ignoring.circuitBreaker(INSTANCE);
        assertThat(breaker.getMetrics().getNumberOfFailedCalls()).as("shed load is not a downstream failure").isZero();
        assertThat(breaker.getMetrics().getNumberOfBufferedCalls())
            .as("an ignored call is excluded from the window entirely -- not recorded as a success")
            .isZero();
        assertThat(breaker.getState()).isEqualTo(CircuitBreaker.State.CLOSED);
    }
}
