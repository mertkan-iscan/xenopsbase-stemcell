package com.xenopsoftware.core.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

/**
 * Concurrent misses on one key produce one load (T-3.23, #265).
 *
 * <p>A unit test with real threads rather than an integration test, because the property is about
 * concurrency and nothing else: no cache, no database, no container. Counting loads with an
 * {@link AtomicInteger} is a direct measurement of the thing the card asks for -- <em>concurrent
 * misses on one key produce one rebuild, shown by a test with concurrent callers</em> -- where
 * counting queries through Hibernate statistics would measure the same property through two more
 * layers that can go wrong for other reasons.
 */
class SingleFlightTest {

    private static final int CALLERS = 24;

    private final SingleFlight singleFlight = new SingleFlight();

    /** The headline property: many callers, one load, everyone gets the value. */
    @Test
    void concurrentCallersOnOneKeyProduceOneLoad() throws Exception {
        AtomicInteger loads = new AtomicInteger();
        CountDownLatch allArrived = new CountDownLatch(CALLERS);
        CountDownLatch release = new CountDownLatch(1);

        List<Future<String>> results = new ArrayList<>();
        try (ExecutorService pool = Executors.newFixedThreadPool(CALLERS)) {
            for (int i = 0; i < CALLERS; i++) {
                results.add(
                    pool.submit(() -> {
                        allArrived.countDown();
                        // Every caller is inside call() before any load is allowed to finish, so
                        // this is a genuine stampede rather than a sequence that happens to overlap.
                        return singleFlight.call("k", () -> {
                            loads.incrementAndGet();
                            try {
                                release.await(5, TimeUnit.SECONDS);
                            } catch (InterruptedException e) {
                                Thread.currentThread().interrupt();
                            }
                            return "value";
                        });
                    })
                );
            }

            assertThat(allArrived.await(5, TimeUnit.SECONDS)).isTrue();
            release.countDown();

            for (Future<String> result : results) {
                assertThat(result.get(10, TimeUnit.SECONDS)).isEqualTo("value");
            }
        }

        assertThat(loads.get()).as("%d concurrent callers, one load", CALLERS).isEqualTo(1);
        assertThat(singleFlight.inFlightCount()).as("nothing is left behind").isZero();
    }

    /** Different keys must not wait on each other, or this becomes a global lock. */
    @Test
    void differentKeysDoNotBlockEachOther() throws Exception {
        AtomicInteger loads = new AtomicInteger();
        CountDownLatch bothStarted = new CountDownLatch(2);

        try (ExecutorService pool = Executors.newFixedThreadPool(2)) {
            List<Future<String>> results = new ArrayList<>();
            for (String key : List.of("a", "b")) {
                results.add(
                    pool.submit(() ->
                        singleFlight.call(key, () -> {
                            loads.incrementAndGet();
                            bothStarted.countDown();
                            try {
                                // Deadlocks if the two keys share a lock: neither can finish until
                                // the other has started.
                                bothStarted.await(5, TimeUnit.SECONDS);
                            } catch (InterruptedException e) {
                                Thread.currentThread().interrupt();
                            }
                            return key;
                        })
                    )
                );
            }
            assertThat(results.get(0).get(10, TimeUnit.SECONDS)).isEqualTo("a");
            assertThat(results.get(1).get(10, TimeUnit.SECONDS)).isEqualTo("b");
        }

        assertThat(loads.get()).isEqualTo(2);
    }

    /**
     * A failing leader must not fail its waiters.
     *
     * <p>Turning one bad load into N failed requests is the opposite of what this class is for, and
     * it is the failure mode a naive implementation has: share the future, share the exception.
     */
    @Test
    void aFailingLeaderDoesNotFailTheWaiters() throws Exception {
        AtomicInteger attempts = new AtomicInteger();
        CountDownLatch leaderInside = new CountDownLatch(1);
        CountDownLatch waiterArrived = new CountDownLatch(1);

        try (ExecutorService pool = Executors.newFixedThreadPool(2)) {
            Future<String> leader = pool.submit(() ->
                singleFlight.call("k", () -> {
                    attempts.incrementAndGet();
                    leaderInside.countDown();
                    try {
                        waiterArrived.await(5, TimeUnit.SECONDS);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                    throw new IllegalStateException("database said no");
                })
            );

            assertThat(leaderInside.await(5, TimeUnit.SECONDS)).isTrue();

            Future<String> waiter = pool.submit(() -> {
                waiterArrived.countDown();
                return singleFlight.call("k", () -> {
                    attempts.incrementAndGet();
                    return "recovered";
                });
            });

            assertThatThrownBy(leader::get).cause().isInstanceOf(IllegalStateException.class);
            assertThat(waiter.get(10, TimeUnit.SECONDS)).as("the waiter loads for itself").isEqualTo("recovered");
        }

        assertThat(attempts.get()).isEqualTo(2);
    }

    /** The caller's exception reaches the caller unchanged, so nothing is swallowed. */
    @Test
    void theLoadersExceptionReachesItsOwnCaller() {
        assertThatThrownBy(() ->
            singleFlight.call("k", () -> {
                throw new IllegalStateException("boom");
            })
        )
            .isInstanceOf(IllegalStateException.class)
            .hasMessage("boom");

        assertThat(singleFlight.inFlightCount()).as("a failed load is not left in the map").isZero();
    }
}
