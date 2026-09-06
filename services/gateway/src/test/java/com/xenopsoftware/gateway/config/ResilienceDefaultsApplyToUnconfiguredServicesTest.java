package com.xenopsoftware.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;

import io.github.resilience4j.bulkhead.BulkheadConfig;
import io.github.resilience4j.bulkhead.BulkheadRegistry;
import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.github.resilience4j.timelimiter.TimeLimiterConfig;
import io.github.resilience4j.timelimiter.TimeLimiterRegistry;
import java.time.Duration;
import java.util.Map;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * Resilience4j gives an instance it has never heard of the DEFAULT config, not the library's (T-9.5).
 *
 * <h2>The claim this is here to check</h2>
 *
 * T-9.5 deleted three `instances: {core: {baseConfig: default}}` blocks from application.yml, which
 * is what makes adding a service one YAML block instead of four edits. That rests entirely on
 * resilience4j creating an instance on demand for an unknown name <em>and giving it
 * {@code configs.default}</em>.
 *
 * <p>If that were wrong the failure would be silent and expensive: a new service would run with
 * library defaults — an unbounded-ish bulkhead of 25 permits, a one-second time limiter, a breaker
 * with a different window — and look completely fine until it was the one under load. Nothing would
 * log. The numbers in application.yml would still be right about a service they no longer governed.
 *
 * <h2>Why this does not boot the application</h2>
 *
 * It did, at first, and that was wrong twice over. The gateway resolves its OIDC issuer over the
 * network during context refresh, so a {@code @SpringBootTest} here needs Keycloak — a container, to
 * assert a property of a library. And booting the app would have made this test pass or fail for
 * reasons that have nothing to do with the claim.
 *
 * <p>So the registries are built here the way Spring Cloud Circuit Breaker builds them: from a map
 * whose only entry is {@code default}. That is the exact shape application.yml now produces, and it
 * isolates the one uncertain thing. {@code GatewayRouteConfigurationTest} asserts the other half
 * statically — that {@code configs.default} really is declared, and that no per-service instance has
 * crept back.
 */
class ResilienceDefaultsApplyToUnconfiguredServicesTest {

    /** Names nothing in application.yml. That is the whole design of this test. */
    private static final String UNCONFIGURED = "a-service-that-is-not-configured";

    @Test
    @DisplayName("an unconfigured breaker gets configs.default, not the library's own defaults")
    void circuitBreakerInheritsTheDefaultConfig() {
        // Values chosen to differ from the library's defaults in every field asserted, so a registry
        // that ignored the map would fail rather than coincide with it.
        CircuitBreakerConfig declared = CircuitBreakerConfig.custom()
            .failureRateThreshold(37)
            .slidingWindowSize(17)
            .minimumNumberOfCalls(7)
            .permittedNumberOfCallsInHalfOpenState(3)
            .waitDurationInOpenState(Duration.ofSeconds(2))
            .build();

        CircuitBreakerRegistry registry = CircuitBreakerRegistry.of(Map.of("default", declared));
        var onDemand = registry.circuitBreaker(UNCONFIGURED).getCircuitBreakerConfig();

        assertThat(onDemand.getFailureRateThreshold()).isEqualTo(37f);
        assertThat(onDemand.getSlidingWindowSize()).isEqualTo(17);
        assertThat(onDemand.getMinimumNumberOfCalls()).isEqualTo(7);
        assertThat(onDemand.getPermittedNumberOfCallsInHalfOpenState()).isEqualTo(3);
        assertThat(onDemand.getWaitIntervalFunctionInOpenState().apply(1)).isEqualTo(2000L);

        // And the library's own default is genuinely different, so the assertions above mean
        // something. 50% is resilience4j's failureRateThreshold; if that ever became 37 this test
        // would start passing for the wrong reason.
        assertThat(CircuitBreakerConfig.ofDefaults().getFailureRateThreshold()).isNotEqualTo(37f);
    }

    @Test
    @DisplayName("an unconfigured time limiter gets configs.default, not one second")
    void timeLimiterInheritsTheDefaultConfig() {
        TimeLimiterConfig declared = TimeLimiterConfig.custom().timeoutDuration(Duration.ofSeconds(12)).build();

        TimeLimiterRegistry registry = TimeLimiterRegistry.of(Map.of("default", declared));

        assertThat(registry.timeLimiter(UNCONFIGURED).getTimeLimiterConfig().getTimeoutDuration()).isEqualTo(Duration.ofSeconds(12));

        // The specific wrong answer, named: resilience4j defaults to one second, which is shorter
        // than the gateway's transport response-timeout, so every slow response would be attributed
        // to the wrong layer.
        assertThat(TimeLimiterConfig.ofDefaults().getTimeoutDuration()).isEqualTo(Duration.ofSeconds(1));
    }

    @Test
    @DisplayName("an unconfigured bulkhead gets configs.default, including maxWaitDuration zero")
    void bulkheadInheritsTheDefaultConfig() {
        BulkheadConfig declared = BulkheadConfig.custom().maxConcurrentCalls(50).maxWaitDuration(Duration.ZERO).build();

        BulkheadRegistry registry = BulkheadRegistry.of(Map.of("default", declared));
        var onDemand = registry.bulkhead(UNCONFIGURED).getBulkheadConfig();

        assertThat(onDemand.getMaxConcurrentCalls()).isEqualTo(50);

        // The value that must not be inherited wrongly under any circumstances: a non-zero wait
        // makes SemaphoreBulkhead call the BLOCKING tryAcquire on a Netty event loop thread, which
        // parks an event loop under exactly the overload the bulkhead exists to survive.
        assertThat(onDemand.getMaxWaitDuration()).as("a blocking bulkhead wait on an event loop is what BlockHound fails on").isZero();

        // And the library default is 25, which is the number that would silently govern every route
        // if the on-demand instance did NOT inherit the declared config.
        assertThat(BulkheadConfig.ofDefaults().getMaxConcurrentCalls()).isEqualTo(25);
    }
}
