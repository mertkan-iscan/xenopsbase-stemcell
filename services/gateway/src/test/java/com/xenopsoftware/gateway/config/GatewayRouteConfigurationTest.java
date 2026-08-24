package com.xenopsoftware.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.config.YamlPropertiesFactoryBean;
import org.springframework.core.io.FileSystemResource;

/**
 * Guards the production route table's resilience settings (T-3.9).
 *
 * <p>This exists because {@code DeadDownstreamIT} cannot cover it. The test classpath's
 * {@code config/application.yml} <b>replaces</b> the main one rather than merging with it, so no
 * integration test in this service ever loads the real routes — they have to be declared in the
 * test, and a test that declares its own route proves only that the mechanism works, not that
 * production uses it.
 *
 * <p>The gap that leaves is specific and easy to walk into: deleting the {@code CircuitBreaker}
 * filter from the production route would keep every test green while removing the protection
 * entirely. A static read of the file is the only thing that notices.
 *
 * <p>Deliberately asserts that the values are PRESENT rather than what they are. The numbers are a
 * default posture and are meant to be tuned per deployment; pinning them here would turn ordinary
 * tuning into a test failure and teach people to edit the assertion.
 */
class GatewayRouteConfigurationTest {

    private static final Path CONFIG = Path.of("src/main/resources/config/application.yml");

    private static final String ROUTE = "spring.cloud.gateway.server.webflux.routes[0]";
    private static final String HTTPCLIENT = "spring.cloud.gateway.server.webflux.httpclient";

    private final Properties config = flatten();

    @Test
    void theCoreRouteIsProtectedByACircuitBreakerWithAFallback() {
        assertThat(filterNames())
            .as("removing the CircuitBreaker filter leaves every test green and the gateway unprotected")
            .contains("CircuitBreaker");

        String fallback = findFilterArg("CircuitBreaker", "fallbackUri");
        assertThat(fallback)
            .as("without a fallbackUri an open circuit renders a generic error instead of a problem document")
            .isEqualTo("forward:/fallback/core");

        assertThat(findFilterArg("CircuitBreaker", "name"))
            .as("the breaker instance must match a resilience4j instance, or it silently uses defaults")
            .isEqualTo("core");
    }

    @Test
    void retriesAreRestrictedToIdempotentMethods() {
        String methods = findFilterArg("Retry", "methods");
        assertThat(methods).as("a Retry filter with no method restriction replays POSTs").isNotNull();
        assertThat(methods.toUpperCase())
            .as("the gateway cannot know whether a POST committed downstream, nor whether the client sent an Idempotency-Key")
            .doesNotContain("POST")
            .doesNotContain("PATCH")
            .doesNotContain("DELETE");
    }

    @Test
    void everyOutboundCallHasAnExplicitTimeout() {
        // Reactor Netty's defaults are effectively unbounded. Unset here does not mean "sensible
        // default", it means a downstream that stops answering holds connections indefinitely.
        assertThat(config.getProperty(HTTPCLIENT + ".connect-timeout"))
            .as("connect timeout")
            .isNotBlank();
        assertThat(config.getProperty(HTTPCLIENT + ".response-timeout"))
            .as("response timeout")
            .isNotBlank();
    }

    @Test
    void theCircuitBreakerInstanceReferencedByTheRouteIsActuallyConfigured() {
        // A CircuitBreaker filter naming an instance that does not exist does not fail — it falls
        // back to library defaults, which are not the posture this project chose.
        assertThat(config.stringPropertyNames())
            .as("resilience4j must define the instance the route names")
            .anyMatch(key -> key.startsWith("resilience4j.circuitbreaker.instances.core"));
    }

    @Test
    void circuitBreakerMetricsAreExposedForScraping() {
        // The behavioural test proves the breaker emits meters. This proves a deployment can
        // actually read them: instrumentation nothing scrapes is instrumentation nobody sees.
        assertThat(config.stringPropertyNames())
            .as("management exposure must include prometheus")
            .anyMatch(key -> key.startsWith("management.endpoints.web.exposure.include") && "prometheus".equals(config.getProperty(key)));
    }

    private String filterNames() {
        StringBuilder names = new StringBuilder();
        for (int i = 0; i < 20; i++) {
            String name = config.getProperty(ROUTE + ".filters[" + i + "].name");
            if (name != null) {
                names.append(name).append(' ');
            }
        }
        return names.toString();
    }

    private String findFilterArg(String filterName, String arg) {
        for (int i = 0; i < 20; i++) {
            if (filterName.equals(config.getProperty(ROUTE + ".filters[" + i + "].name"))) {
                return config.getProperty(ROUTE + ".filters[" + i + "].args." + arg);
            }
        }
        return null;
    }

    private static Properties flatten() {
        assertThat(Files.isRegularFile(CONFIG)).as("expected to run from the module directory: %s", CONFIG).isTrue();
        YamlPropertiesFactoryBean factory = new YamlPropertiesFactoryBean();
        factory.setResources(new FileSystemResource(CONFIG));
        Properties properties = factory.getObject();
        return properties == null ? new Properties() : properties;
    }
}
