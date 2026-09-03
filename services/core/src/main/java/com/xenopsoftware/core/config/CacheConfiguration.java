package com.xenopsoftware.core.config;

import com.xenopsoftware.core.service.BusinessCaches;
import com.xenopsoftware.core.service.dto.CachedDocumentPage;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.cache.Cache;
import org.springframework.cache.annotation.CachingConfigurer;
import org.springframework.cache.annotation.EnableCaching;
import org.springframework.cache.interceptor.CacheErrorHandler;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.cache.RedisCacheConfiguration;
import org.springframework.data.redis.cache.RedisCacheManager;
import org.springframework.data.redis.cache.RedisCacheWriter;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.serializer.JacksonJsonRedisSerializer;
import org.springframework.data.redis.serializer.RedisSerializationContext;
import org.springframework.data.redis.serializer.RedisSerializer;

/**
 * Valkey as a business cache for {@code core} (T-3.22, #264), under the constraints ADR-0011 set.
 *
 * <p>Cache-aside on the read path only. The cache is never written to as part of a transaction, so
 * an unreachable Valkey cannot fail or lose a write -- which is ADR-0009's disposability being kept
 * true rather than assumed.
 *
 * <p><b>Losing Valkey must not fail a request, and that is a property of THIS class more than of
 * any calling code.</b> Three distinct failure points, and all three are handled here:
 *
 * <ol>
 *   <li><b>Read.</b> Spring's default {@code SimpleCacheErrorHandler} rethrows, so an unreachable
 *       cache turns a GET into a 500. {@link #errorHandler()} replaces it: a failed get logs and
 *       returns, the caller misses, and the miss is served from Postgres.
 *   <li><b>Write.</b> A failed eviction must not fail a transaction that already committed --
 *       otherwise a Valkey outage turns every successful write into a 500 <em>after</em> the data
 *       was saved, which is the worst of both outcomes. Same handler; and the eviction itself runs
 *       after commit, so there is no transaction left to fail.
 *   <li><b>Startup.</b> Degradation that works at runtime and fails at boot is degradation that
 *       fails during a rollout, which is exactly when Valkey is most likely to be moving. Nothing
 *       here opens a connection during refresh: the cache manager resolves caches lazily and
 *       Lettuce connects on first use. The readiness group in {@code application.yml} is
 *       {@code readinessState,db} and deliberately does not include {@code redis}, so an absent
 *       cache cannot take the pod out of the Service either.
 * </ol>
 *
 * <p><b>CONNECTIONS PER REPLICA: ONE, and it is stated rather than inherited (T-2.18, #259).</b>
 *
 * <p>{@code commons-pool2} is deliberately not on the classpath, so Spring Data Redis runs Lettuce
 * in its shared mode: a single connection per {@code LettuceConnectionFactory}, multiplexed across
 * every request thread, rather than a pool sized per call. Adding a pool would be the change that
 * makes this arithmetic interesting, and it would need this comment rewritten.
 *
 * <pre>
 *   core at HPA ceiling      3 replicas x 1 connection  =  3
 *   redis_exporter sidecar   1 per Valkey pod           =  1
 *   Valkey maxclients                                   = 10000 (default)
 * </pre>
 *
 * <p>So the cache is nowhere near a ceiling, which is the opposite of the Postgres situation #259
 * was filed about -- there the declared demand was 171 against a {@code max_connections} of 100 and
 * held only by luck. It is stated anyway, because "nowhere near" is a measurement that stops being
 * true silently, and #259's whole point is that an unstated number is one nobody notices moving.
 *
 * <p>This adds nothing to the Postgres budget: no Hikari setting changes here, and
 * {@code make connection-budget} still reports 65 of 100.
 *
 * <p><b>Opt-in, and off is the default.</b> Without {@code application.cache.enabled=true} none of
 * this is created, for the same reason the S3 client is not created without a bucket: a fork that
 * does not want a cache should carry no cache configuration rather than a disabled one. It is also
 * what the "Valkey is gone" test switches, so the fallback is proven rather than described.
 */
@Configuration
@EnableCaching
@ConditionalOnProperty(name = "application.cache.enabled", havingValue = "true")
public class CacheConfiguration implements CachingConfigurer {

    private static final Logger LOG = LoggerFactory.getLogger(CacheConfiguration.class);

    /**
     * Plus or minus 20% on every TTL.
     *
     * <p>ADR-0011 requires jitter because entries written together would otherwise expire together,
     * turning the TTL into a scheduled stampede against Postgres (T-3.23, #265). The load baseline
     * fills a page cache in one burst, so "written together" is the normal case here, not a corner.
     */
    private static final double JITTER_FRACTION = 0.20;

    /**
     * The concrete type each cache holds.
     *
     * <p>ADR-0011 forbids polymorphic type information: Jackson's {@code @class} header would embed
     * the class name in the payload, reintroducing the class-shape coupling that JSON was chosen to
     * avoid and turning cache contents into an instantiation surface. So each cache declares its
     * type here and gets a serializer bound to it --
     * {@code JacksonJsonRedisSerializer}, never {@code GenericJacksonJsonRedisSerializer}.
     */
    private static final Map<String, Class<?>> CACHED_TYPES = Map.of(BusinessCaches.DOCUMENT_LIST, CachedDocumentPage.class);

    @Bean
    public RedisCacheManager cacheManager(RedisConnectionFactory connectionFactory) {
        // ADR-0011's "enforced at startup, not in review". Runs before any cache exists.
        BusinessCaches.assertEveryCacheHasATtl();

        Map<String, RedisCacheConfiguration> configurations = new LinkedHashMap<>();
        BusinessCaches.ttls().forEach((cacheName, ttl) -> {
            Class<?> type = CACHED_TYPES.get(cacheName);
            if (type == null) {
                throw new IllegalStateException(
                    "Cache '" +
                        cacheName +
                        "' has a TTL but no declared type. ADR-0011 requires a serializer bound to a " +
                        "concrete type, because the alternative is polymorphic type headers."
                );
            }
            configurations.put(cacheName, configurationFor(ttl, type));
            LOG.info(
                "Business cache '{}' -> {}, ttl {}s +/-{}%",
                cacheName,
                type.getSimpleName(),
                ttl.toSeconds(),
                (int) (JITTER_FRACTION * 100)
            );
        });

        return RedisCacheManager.builder(connectionFactory)
            .withInitialCacheConfigurations(configurations)
            // A @Cacheable naming a cache that is not configured above fails, rather than being
            // created on the fly with an unbounded default TTL. That default is precisely what
            // ADR-0011 refuses, so the manager must not be able to produce one.
            .disableCreateOnMissingCache()
            .build();
    }

    private static RedisCacheConfiguration configurationFor(Duration ttl, Class<?> type) {
        return RedisCacheConfiguration.defaultCacheConfig()
            // ADR-0011's key format, `xob:c:v<schema>:<cache>:<owner>:<discriminator>`. This half
            // is the prefix; the @Cacheable key supplies `<owner>:<discriminator>`.
            //
            // The format is owned by BusinessCaches rather than duplicated here, because the
            // eviction path is in the service layer and cannot read this class -- and two
            // components computing the same prefix independently is how a cache comes to be
            // invalidated at a pattern nothing writes to.
            //
            // computePrefixWith rather than prefixCacheNameWith: the latter keeps Spring's default
            // `::` separator, and the resulting key would not be the one ADR-0011 specifies.
            .computePrefixWith(BusinessCaches::keyPrefix)
            .serializeKeysWith(RedisSerializationContext.SerializationPair.fromSerializer(RedisSerializer.string()))
            .serializeValuesWith(RedisSerializationContext.SerializationPair.fromSerializer(new JacksonJsonRedisSerializer<>(type)))
            // A cached null would answer "this owner has no documents" from a miss that was really
            // a failure, and it is indistinguishable from a real empty page once stored.
            .disableCachingNullValues()
            .entryTtl(jittered(ttl));
    }

    /**
     * A TTL within +/- {@link #JITTER_FRACTION} of the configured one, drawn per entry.
     *
     * <p>Note this is applied on WRITE, so two entries written in the same millisecond get
     * different expiries. Jittering the read would not help: it is the write burst that
     * synchronises them.
     */
    private static RedisCacheWriter.TtlFunction jittered(Duration ttl) {
        long baseMillis = ttl.toMillis();
        long spread = (long) (baseMillis * JITTER_FRACTION);
        return (key, value) -> {
            long offset = ThreadLocalRandom.current().nextLong(-spread, spread + 1);
            return Duration.ofMillis(baseMillis + offset);
        };
    }

    /**
     * Every cache failure degrades to the database, and none of them reaches the caller.
     *
     * <p>This is the acceptance criterion of T-3.22 rather than a convenience. Spring's default
     * handler propagates, which would make an unreachable Valkey a 500 on reads and -- worse -- a
     * 500 on writes that had already committed.
     *
     * <p>Logged at WARN with the cache and key, not swallowed silently: a cache that has quietly
     * stopped working looks exactly like one that is working and never hit, and T-2.20's
     * {@code redis_evicted_keys_total} does not distinguish them either.
     */
    /**
     * Installed via {@link CachingConfigurer}, and that is load bearing rather than stylistic.
     *
     * <p>A bare {@code @Bean CacheErrorHandler} is created, injected nowhere, and silently ignored
     * by the caching infrastructure -- the default rethrowing handler stays in place. The first
     * version of this class did exactly that, and {@code DocumentCacheDegradationIT} failed with a
     * {@code RedisConnectionFailureException} reaching the caller: the precise bug this class exists
     * to prevent, caught by the test written to catch it.
     */
    @Bean
    @Override
    public CacheErrorHandler errorHandler() {
        return new CacheErrorHandler() {
            @Override
            public void handleCacheGetError(RuntimeException exception, Cache cache, Object key) {
                LOG.warn("Cache get failed on '{}' key '{}'; serving from the database", cache.getName(), key, exception);
            }

            @Override
            public void handleCachePutError(RuntimeException exception, Cache cache, Object key, Object value) {
                LOG.warn("Cache put failed on '{}' key '{}'; the response is unaffected", cache.getName(), key, exception);
            }

            @Override
            public void handleCacheEvictError(RuntimeException exception, Cache cache, Object key) {
                // The write is already committed. Failing here would report an error for data that
                // was saved. ADR-0011 accepts the consequence explicitly: a write whose eviction
                // did not run serves stale reads for up to one TTL.
                LOG.warn(
                    "Cache evict failed on '{}' key '{}'; the write is committed and a stale entry may survive until its TTL",
                    cache.getName(),
                    key,
                    exception
                );
            }

            @Override
            public void handleCacheClearError(RuntimeException exception, Cache cache) {
                LOG.warn("Cache clear failed on '{}'; entries expire under their TTL instead", cache.getName(), exception);
            }
        };
    }
}
