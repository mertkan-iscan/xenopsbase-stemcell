package com.xenopsoftware.core.service;

import java.util.concurrent.CancellationException;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.function.Supplier;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * Concurrent misses on the same key produce one load; everybody else waits for it (T-3.23, #265).
 *
 * <p><b>The problem is capacity, not duplicated work.</b> Valkey has no persistence
 * ({@code save ""}, {@code appendonly no}), so a restart, rollout, node move or eviction storm
 * leaves a completely cold cache. At that moment every request that would have been served from the
 * cache goes to one Postgres primary, from up to three replicas, with no pooler in front. This
 * exists to protect the database, not the CPU.
 *
 * <p><b>Per process, not distributed, and that is a decision rather than a shortcut.</b>
 *
 * <p>Spring Data Redis offers exactly two cache writers and neither is a per-key single-flight:
 *
 * <ul>
 *   <li>{@code nonLockingRedisCacheWriter} — the default, and what this application uses. It does
 *       no coalescing at all, so {@code @Cacheable(sync = true)} on top of it would read as
 *       protection while providing none.
 *   <li>{@code lockingRedisCacheWriter} — its lock is taken on the CACHE NAME
 *       ({@code DefaultRedisCacheWriter.lock(String name)}), not on the key. It serialises every
 *       key in the cache against every other, and it exists to make {@code clear()} safe rather
 *       than to coalesce loads.
 * </ul>
 *
 * <p>The second is also the failure mode T-3.23 names outright: <em>a distributed lock in Valkey is
 * unavailable exactly when the cache is unavailable, which is the scenario it was added for.</em>
 * A cold cache after a Valkey restart is the case this card is about, and a Valkey-hosted lock is
 * missing in precisely that case.
 *
 * <p>So coalescing happens in the JVM, and the arithmetic is what makes that sufficient here:
 *
 * <pre>
 *   without this   one load per concurrent REQUEST      unbounded, up to the Tomcat thread pool
 *   with this      one load per REPLICA per key         3 at the HPA ceiling (T-2.8)
 * </pre>
 *
 * <p>Three concurrent rebuilds of one key, against a connection budget that already reserves 36 for
 * {@code core} and reports 65 of 100 in use at full scale (T-2.18, #259). The residual duplication
 * is bounded by the replica count and is far below anything the database notices; buying the last
 * factor of three would cost a lock that is absent when it is needed.
 *
 * <p><b>Losing this degrades to a direct read, never to a failed request.</b> There is nothing to
 * lose: no external dependency, no lock to acquire, no timeout to expire. If the leader's load
 * throws, every waiter runs the load itself rather than inheriting the failure — a rebuild that
 * fails must not turn one error into N.
 */
@Component
public class SingleFlight {

    private static final Logger LOG = LoggerFactory.getLogger(SingleFlight.class);

    /**
     * Keyed by the cache key, so two owners never wait on each other.
     *
     * <p>Entries live only for the duration of one load and are removed in a {@code finally}, so
     * this cannot grow: it holds at most one entry per key currently being rebuilt.
     */
    private final ConcurrentMap<String, CompletableFuture<Object>> inFlight = new ConcurrentHashMap<>();

    /**
     * Runs {@code loader} for {@code key}, or waits for the load already running for it.
     *
     * @return the loaded value, whoever loaded it
     */
    @SuppressWarnings("unchecked")
    public <T> T call(String key, Supplier<T> loader) {
        CompletableFuture<Object> mine = new CompletableFuture<>();
        CompletableFuture<Object> leader = inFlight.putIfAbsent(key, mine);

        if (leader != null) {
            try {
                return (T) leader.join();
            } catch (CompletionException | CancellationException e) {
                // The leader failed. Do the work rather than propagating someone else's exception:
                // a follower that inherits the failure turns one bad load into N failed requests,
                // which is the opposite of what this class is for.
                LOG.debug("Leader load failed for {}; loading directly", key);
                return loader.get();
            }
        }

        try {
            T value = loader.get();
            mine.complete(value);
            return value;
        } catch (RuntimeException e) {
            mine.completeExceptionally(e);
            throw e;
        } finally {
            // Remove only our own future. A plain remove(key) could delete a newer load started by
            // another thread between our completion and this line, stranding its waiters.
            inFlight.remove(key, mine);
        }
    }

    /** Visible for tests: how many loads are in flight right now. */
    int inFlightCount() {
        return inFlight.size();
    }
}
