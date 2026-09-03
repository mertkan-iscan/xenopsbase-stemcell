package com.xenopsoftware.core.config;

import org.springframework.test.context.DynamicPropertyRegistry;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.utility.DockerImageName;

/**
 * A real Valkey for the business-cache tests (T-3.22, #264).
 *
 * <p>Valkey rather than an embedded fake, for the same reason {@link ObjectStorageTestcontainer}
 * runs MinIO: the behaviour under test is what a real server does. Serialisation round trips, key
 * prefixes, TTLs actually being set, and SCAN matching the eviction pattern are all things a mock
 * would agree with regardless of whether the production configuration was right.
 *
 * <p><b>Same singleton-holder shape as the object storage container, and for the same reason.</b>
 * {@code CacheConfiguration} is {@code @ConditionalOnProperty} on {@code application.cache.enabled},
 * and conditions are evaluated before an {@code @ImportTestcontainers} bean would register anything.
 * A {@code @DynamicPropertySource} on the test class is applied before refresh, so the condition
 * sees the value and the cache manager actually exists.
 *
 * <p>The image is the same one the platform runs, pinned by digest in
 * {@code platform/envs/dev/cache/valkey-cache.yaml}. Pinned by tag here rather than digest because
 * a test that fails when Docker Hub changes a digest is a test that fails for a reason unrelated to
 * the code.
 */
public final class CacheTestcontainer {

    private static final GenericContainer<?> CONTAINER = new GenericContainer<>(
        DockerImageName.parse("valkey/valkey:9.0-alpine")
    ).withExposedPorts(6379);

    private CacheTestcontainer() {}

    /** Starts the container if needed and points the application at it, with caching switched on. */
    public static void registerTo(DynamicPropertyRegistry registry) {
        if (!CONTAINER.isRunning()) {
            CONTAINER.start();
        }
        registry.add("application.cache.enabled", () -> true);
        registry.add("spring.data.redis.host", CONTAINER::getHost);
        registry.add("spring.data.redis.port", () -> CONTAINER.getMappedPort(6379));
    }

    /**
     * Points the application at a port nothing is listening on, with caching switched ON.
     *
     * <p>This is the "Valkey is gone" fixture the card asks for, and it is deliberately harsher
     * than stopping a running container mid-test: an unreachable server from the very start also
     * exercises <b>startup</b>, which is the third and most easily missed failure point --
     * degradation that works at runtime and fails at boot is degradation that fails during a
     * rollout, which is exactly when Valkey is most likely to be moving.
     *
     * <p>Port 1 rather than a stopped container, so the test does not depend on teardown ordering
     * between classes that share the singleton above.
     */
    public static void registerUnreachable(DynamicPropertyRegistry registry) {
        registry.add("application.cache.enabled", () -> true);
        registry.add("spring.data.redis.host", () -> "127.0.0.1");
        registry.add("spring.data.redis.port", () -> 1);
    }
}
