package com.xenopsoftware.core.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.ArrayList;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.locks.LockSupport;
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

    /**
     * How long a load waits for its fellow callers before the test gives up on its own premise.
     *
     * <p>Generous because it is only ever paid on failure: the callers are already running when the
     * wait begins, and all they have to do is reach a map lookup.
     */
    private static final long ARRIVAL_TIMEOUT_NANOS = TimeUnit.SECONDS.toNanos(10);

    private final SingleFlight singleFlight = new SingleFlight();

    /**
     * The headline property: many callers, one load, everyone gets the value.
     *
     * <p>The load is its own barrier -- it returns only once every other caller is parked inside
     * {@link SingleFlight#call} -- so the stampede is a fact of the test rather than a hope about
     * the scheduler. {@link #awaitOtherCallersInsideCall} says why nothing a caller signals on its
     * own way in can stand in for that.
     */
    @Test
    void concurrentCallersOnOneKeyProduceOneLoad() throws Exception {
        AtomicInteger loads = new AtomicInteger();
        Set<Thread> callers = ConcurrentHashMap.newKeySet();
        AtomicBoolean everyCallerArrived = new AtomicBoolean(true);

        List<Future<String>> results = new ArrayList<>();
        try (ExecutorService pool = Executors.newFixedThreadPool(CALLERS)) {
            for (int i = 0; i < CALLERS; i++) {
                results.add(
                    pool.submit(() -> {
                        callers.add(Thread.currentThread());
                        return singleFlight.call("k", () -> {
                            loads.incrementAndGet();
                            if (!awaitOtherCallersInsideCall(callers, CALLERS - 1)) {
                                everyCallerArrived.set(false);
                            }
                            return "value";
                        });
                    })
                );
            }

            for (Future<String> result : results) {
                assertThat(result.get(30, TimeUnit.SECONDS)).isEqualTo("value");
            }
        }

        assertThat(everyCallerArrived).as("all %d callers were inside call() before any load was allowed to finish", CALLERS).isTrue();
        assertThat(loads.get()).as("%d concurrent callers, one load", CALLERS).isEqualTo(1);
        assertThat(singleFlight.inFlightCount()).as("nothing is left behind").isZero();
    }

    /**
     * Blocks until {@code expected} caller threads other than this one are parked inside
     * {@link SingleFlight#call}, so a load running on this thread cannot finish before they have
     * all been coalesced onto it.
     *
     * <p>Parked inside {@code call()} is the strongest claim available from outside, and it is the
     * one that matters: {@code call()} blocks nowhere before it publishes its future into the map,
     * so a caller parked in there is already following the load in progress. A latch counted down
     * on the way in proves strictly less. That countdown happens before the map lookup it is meant
     * to stand for, and a caller descheduled in between can arrive after this load has finished and
     * its key has been removed -- at which point it loads for itself and the count is 2. That is a
     * race in the test rather than in {@link SingleFlight}, and on a runner with fewer cores than
     * {@link #CALLERS} it is frequent enough to see.
     *
     * @return true if they all arrived; false if the timeout expired first, in which case the test
     *     never had the stampede it set out to measure and its load count proves nothing
     */
    private static boolean awaitOtherCallersInsideCall(Set<Thread> callers, int expected) {
        Thread self = Thread.currentThread();
        // Arrival is monotonic while this load runs -- a follower cannot leave call() until the
        // load completes -- so a caller seen inside it never has to be looked at again. Stack
        // traces are expensive enough for that to be worth saying.
        Set<Thread> arrived = Collections.newSetFromMap(new IdentityHashMap<>());
        long deadline = System.nanoTime() + ARRIVAL_TIMEOUT_NANOS;
        while (true) {
            for (Thread caller : callers) {
                if (caller != self && !arrived.contains(caller) && isParkedInsideCall(caller)) {
                    arrived.add(caller);
                }
            }
            if (arrived.size() >= expected) {
                return true;
            }
            if (System.nanoTime() - deadline >= 0) {
                return false;
            }
            LockSupport.parkNanos(TimeUnit.MILLISECONDS.toNanos(1));
        }
    }

    /**
     * True while {@code caller} is parked inside {@link SingleFlight#call}.
     *
     * <p>The state is what turns "on the stack" into "has registered": a caller between entering
     * {@code call()} and its map lookup is on the stack too, but it is runnable rather than parked,
     * and one queued behind the map's bin lock is blocked rather than parked.
     */
    private static boolean isParkedInsideCall(Thread caller) {
        Thread.State state = caller.getState();
        if (state != Thread.State.WAITING && state != Thread.State.TIMED_WAITING) {
            return false;
        }
        for (StackTraceElement frame : caller.getStackTrace()) {
            if (SingleFlight.class.getName().equals(frame.getClassName()) && "call".equals(frame.getMethodName())) {
                return true;
            }
        }
        return false;
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
