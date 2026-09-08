package com.xenopsoftware.common.config;

import static org.assertj.core.api.Assertions.assertThat;

import com.xenopsoftware.common.correlation.CorrelationId;
import com.xenopsoftware.common.tenancy.TenantContext;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.slf4j.MDC;

/**
 * What survives the submit-to-worker gap, and what is left behind (T-9.10).
 *
 * <p>Every assertion here guards something that produces no error. A correlation id that does not
 * cross is a log line nobody can join to a request — it reads as a gap in the logs. A tenant that
 * does not cross is worse once the seam is live, and a tenant that is not CLEARED is worse again:
 * the next task on that pooled thread inherits somebody else's.
 */
class ContextPropagatingTaskDecoratorTest {

    private final ContextPropagatingTaskDecorator decorator = new ContextPropagatingTaskDecorator();

    @AfterEach
    void clearCallingThread() {
        MDC.remove(CorrelationId.MDC_KEY);
        TenantContext.clear();
    }

    /** Runs the decorated task on a DIFFERENT thread, which is the whole point. */
    private static void onAnotherThread(Runnable task) throws Exception {
        var pool = Executors.newSingleThreadExecutor();
        try {
            CountDownLatch done = new CountDownLatch(1);
            pool.execute(() -> {
                try {
                    task.run();
                } finally {
                    done.countDown();
                }
            });
            assertThat(done.await(10, TimeUnit.SECONDS)).as("the task ran").isTrue();
        } finally {
            pool.shutdownNow();
        }
    }

    @Test
    @DisplayName("the correlation id crosses to the worker thread")
    void theCorrelationIdCrosses() throws Exception {
        MDC.put(CorrelationId.MDC_KEY, "abc123");
        AtomicReference<String> seen = new AtomicReference<>();

        Runnable decorated = decorator.decorate(() -> seen.set(MDC.get(CorrelationId.MDC_KEY)));
        // Cleared on the CALLING thread before the task runs, so a passing assertion cannot be
        // explained by the worker having somehow shared this thread's MDC.
        MDC.remove(CorrelationId.MDC_KEY);
        onAnotherThread(decorated);

        assertThat(seen.get()).isEqualTo("abc123");
    }

    @Test
    @DisplayName("the tenant crosses too, so the seam works the day it is activated")
    void theTenantCrosses() throws Exception {
        TenantContext.set("acme");
        AtomicReference<String> seen = new AtomicReference<>();

        Runnable decorated = decorator.decorate(() -> seen.set(TenantContext.getTenant()));
        TenantContext.clear();
        onAnotherThread(decorated);

        assertThat(seen.get()).isEqualTo("acme");
    }

    @Test
    @DisplayName("the worker thread is left CLEAN, so the next task inherits nothing")
    void theWorkerIsCleanedUpAfterwards() throws Exception {
        // THE ASSERTION THAT MATTERS MOST. Propagating without clearing turns one leak into a
        // different, worse leak: the next task on this pooled thread would run as `acme` having
        // been submitted by nobody.
        MDC.put(CorrelationId.MDC_KEY, "abc123");
        TenantContext.set("acme");
        Runnable first = decorator.decorate(() -> {});

        AtomicReference<String> leakedId = new AtomicReference<>("(not run)");
        AtomicReference<String> leakedTenant = new AtomicReference<>("(not run)");

        var pool = Executors.newSingleThreadExecutor();
        try {
            CountDownLatch done = new CountDownLatch(1);
            pool.execute(first);
            // Undecorated, and deliberately: this is the next piece of work to land on the same
            // pooled thread, and it must see nothing at all.
            pool.execute(() -> {
                leakedId.set(MDC.get(CorrelationId.MDC_KEY));
                leakedTenant.set(TenantContext.getTenant());
                done.countDown();
            });
            assertThat(done.await(10, TimeUnit.SECONDS)).isTrue();
        } finally {
            pool.shutdownNow();
        }

        assertThat(leakedId.get()).as("no correlation id left on the pooled thread").isNull();
        assertThat(leakedTenant.get()).as("no tenant left on the pooled thread").isEqualTo(TenantContext.DEFAULT_TENANT);
    }

    @Test
    @DisplayName("work submitted with no correlation id does not invent one")
    void anAbsentCorrelationIdStaysAbsent() throws Exception {
        AtomicReference<String> seen = new AtomicReference<>("(not run)");

        Runnable decorated = decorator.decorate(() -> seen.set(MDC.get(CorrelationId.MDC_KEY)));
        onAnotherThread(decorated);

        // A scheduled job or a startup hook has no request behind it. Binding an empty string, or
        // whatever the worker happened to hold, would make a log line look correlated when it is
        // not -- which is worse than an uncorrelated line, because it points somewhere wrong.
        assertThat(seen.get()).isNull();
    }
}
