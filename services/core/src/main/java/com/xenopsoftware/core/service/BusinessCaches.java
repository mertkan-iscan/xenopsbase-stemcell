package com.xenopsoftware.core.service;

import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

/**
 * Every business cache this service has, and the TTL each one carries (T-3.22, #264; ADR-0011).
 *
 * <p><b>Why this is in the service layer and not next to the cache configuration.</b>
 * {@code TechnicalStructureTest} declares {@code Config} as a layer that
 * {@code mayNotBeAccessedByAnyLayer}. A {@code @Cacheable} annotation naming a constant that lives
 * in {@code ..config..} is a Service to Config dependency and fails that rule. Config may read
 * Service, so the names live here and the cache manager is built from them.
 *
 * <p><b>Why the TTLs are here too, rather than in the cache configuration.</b> ADR-0011 requires
 * that no entry is ever written without a TTL, and that the rule is <em>enforced at startup, not in
 * review</em>:
 *
 * <blockquote>A cache name configured without a TTL fails the context rather than inheriting an
 * unbounded default. A rule with no enforcement point is a convention, and this repository has now
 * found several controls that reported success while governing nothing.</blockquote>
 *
 * <p>There are two enforcement points, and the structural one is the real guarantee: the cache
 * manager is built <em>from</em> the TTL map with {@code disableCreateOnMissingCache()}, so a cache
 * with no TTL cannot be constructed and a {@code @Cacheable} naming one fails rather than getting
 * an unbounded default. {@link #assertEveryCacheHasATtl()} is the second, and exists only so the
 * failure arrives at startup with a message that says what to do.
 *
 * <p>Either way, adding a cache and forgetting its TTL breaks the context in every environment and
 * every test, rather than quietly producing entries that live until something else needs the
 * memory -- which under {@code allkeys-lru} is not a policy anybody chose, and is the failure
 * T-2.19 (#262) exists to prevent, seen from the other side.
 */
public final class BusinessCaches {

    /**
     * Documents belonging to one owner, one page at a time.
     *
     * <p>The only genuinely cacheable read path in this service. {@code presignDownload} returns a
     * credential with its own expiry, which ADR-0011 puts on the never-cache list, and the
     * remaining repository reads back write operations.
     */
    public static final String DOCUMENT_LIST = "document-list";

    /**
     * ADR-0011's key namespace. Cannot collide with {@code spring:session:*}, which belongs to the
     * gateway and to a different Valkey instance (T-2.19, #262).
     */
    public static final String KEY_NAMESPACE = "xob:c:";

    /**
     * Bumped whenever a cached DTO changes shape in a way {@code ignoreUnknown} cannot absorb. Old
     * entries then become <b>unreachable</b> rather than misread, which is the safe failure, and
     * they age out under their TTL. Expect one hit-ratio collapse per bump (T-2.20, #263).
     */
    public static final String SCHEMA_VERSION = "v1";

    /**
     * The full key prefix for one cache: {@code xob:c:v1:<cache>:}.
     *
     * <p>The {@code @Cacheable} key then supplies {@code <owner>:<discriminator>}, giving
     * ADR-0011's format end to end. Both the cache manager and the eviction path derive their keys
     * from here, so they cannot drift apart -- an evictor computing its own prefix is how a cache
     * comes to be invalidated at a pattern nothing writes to.
     */
    public static String keyPrefix(String cacheName) {
        return KEY_NAMESPACE + SCHEMA_VERSION + ":" + cacheName + ":";
    }

    /**
     * The glob matching every entry of {@code cacheName} owned by {@code owner}.
     *
     * <p>Owner-scoped rather than whole-cache, so invalidating one user's documents does not cost
     * every other user their cached pages. The owner is a Keycloak {@code sub} (ADR-0010), a UUID,
     * so it carries no glob metacharacters of its own.
     */
    public static String ownerKeyPattern(String cacheName, String owner) {
        return keyPrefix(cacheName) + owner + ":*";
    }

    /**
     * ADR-0011's default, chosen as a bound rather than measured: <em>the stated maximum time
     * Postgres and Valkey may disagree</em> after a write whose invalidation was lost. It is not a
     * performance knob, and a card that wants a different value must record why.
     */
    private static final Duration DEFAULT_TTL = Duration.ofMinutes(5);

    private static final Map<String, Duration> TTLS = Map.of(DOCUMENT_LIST, DEFAULT_TTL);

    private BusinessCaches() {}

    /** The configured caches and their TTLs, in a stable order so startup logging is diffable. */
    public static Map<String, Duration> ttls() {
        Map<String, Duration> ordered = new LinkedHashMap<>();
        for (String name : new TreeSet<>(TTLS.keySet())) {
            ordered.put(name, TTLS.get(name));
        }
        return ordered;
    }

    /**
     * Every cache this service is allowed to use. Adding one here without a TTL fails startup.
     *
     * <p>Kept explicit rather than reflected out of the constants above, because those now include
     * the key-format strings and a reflective sweep cannot tell a cache name from a namespace
     * without a convention nobody would remember to follow.
     */
    private static final Set<String> NAMES = Set.of(DOCUMENT_LIST);

    /**
     * Fails if a declared cache has no TTL, or a TTL names a cache that does not exist.
     *
     * <p>Called from the cache configuration during context refresh, so the failure is a context
     * that will not start rather than a review comment nobody wrote.
     *
     * <p>This is the second of two enforcement points and the weaker one. The structural guarantee
     * is that the cache manager is built <em>from</em> {@link #TTLS} with
     * {@code disableCreateOnMissingCache()}, so a cache with no TTL cannot be constructed at all --
     * a {@code @Cacheable} naming one fails instead of silently getting an unbounded default. This
     * check exists so the failure arrives at startup with a message, rather than at the first
     * request with a {@code IllegalArgumentException} about a missing cache.
     */
    public static void assertEveryCacheHasATtl() {
        Set<String> withoutTtl = new TreeSet<>(NAMES);
        withoutTtl.removeAll(TTLS.keySet());
        if (!withoutTtl.isEmpty()) {
            throw new IllegalStateException(
                "ADR-0011: every cache must declare a TTL, and these do not: " +
                    withoutTtl +
                    ". Add them to BusinessCaches.TTLS. An entry with no TTL lives until something else " +
                    "needs the memory, which under allkeys-lru is not a policy anybody chose."
            );
        }

        Set<String> unknown = new TreeSet<>(TTLS.keySet());
        unknown.removeAll(NAMES);
        if (!unknown.isEmpty()) {
            throw new IllegalStateException("TTLs configured for caches that BusinessCaches.NAMES does not declare: " + unknown);
        }
    }
}
