package com.xenopsoftware.gateway.config;

import org.slf4j.LoggerFactory;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.output.Slf4jLogConsumer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.junit.jupiter.Container;

/**
 * A real Valkey for the integration tests (T-2.11).
 *
 * <h2>Why a container rather than an embedded fake</h2>
 *
 * Session storage is the one thing this gateway cannot be wrong about: it holds the OIDC session,
 * so a broken store means either everybody is signed out or nobody can sign in. An in-process fake
 * would exercise Spring Session's wiring and none of the protocol, which is where the differences
 * live.
 *
 * <h2>Why this is not optional</h2>
 *
 * Spring Boot 4 removed {@code spring.session.store-type}; the session store is chosen by what is
 * on the classpath. Adding {@code spring-boot-starter-session-data-redis} therefore makes Redis a
 * hard dependency of this application, with no property that turns it off.
 *
 * <p>That was found the noisy way. The first attempt configured
 * {@code store-type: none} and expected an in-memory store; the property does not exist, bound to
 * nothing, and the reactive repository was used regardless. CI reported it as a BlockHound failure
 * — {@code ReactiveRedisTemplate} resolving an empty hostname on an event-loop thread — which names
 * the symptom several layers from the cause.
 *
 * <p>The same image and major version as the platform runs (ADR-0009). Testing against a different
 * server than production runs is a way of discovering protocol differences in production.
 */
public interface ValkeyTestcontainer {
    @Container
    GenericContainer<?> valkeyContainer = new GenericContainer<>("valkey/valkey:8.1.4-alpine")
        .withExposedPorts(6379)
        // Waiting for the port to be open is not enough: the port listens before the server is
        // ready to answer, so the first test would fail intermittently on a slow machine.
        .withCommand("valkey-server", "--save", "", "--appendonly", "no")
        .waitingFor(Wait.forLogMessage(".*Ready to accept connections.*\\n", 1))
        .withLogConsumer(new Slf4jLogConsumer(LoggerFactory.getLogger(ValkeyTestcontainer.class)))
        .withReuse(true);

    @DynamicPropertySource
    static void registerProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.data.redis.host", valkeyContainer::getHost);
        registry.add("spring.data.redis.port", () -> valkeyContainer.getMappedPort(6379));
        // No password. The container is bound to a random localhost port for the life of one test
        // run, and a password here would only be a constant in the repository pretending to be a
        // secret. The deployment supplies a real one from SOPS.
        registry.add("spring.data.redis.password", () -> "");
    }
}
