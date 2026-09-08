package com.xenopsoftware.common.config;

import com.xenopsoftware.common.correlation.CorrelationId;
import com.xenopsoftware.common.tenancy.TenantContext;
import org.slf4j.MDC;
import org.springframework.core.task.TaskDecorator;

/**
 * Carries the correlation id and the tenant across the submit-to-worker gap (T-9.10).
 *
 * <h2>There was no TaskDecorator in this repository at all</h2>
 *
 * {@code TaskDecoratorSurvivesVirtualThreadsTest} was written in T-9.8 to guard one that did not
 * exist yet, and said so: "written now, this is the thing that fails the day somebody adds a
 * decorator to a virtual-threaded application and assumes it works." This is that decorator.
 *
 * <p>Both values live in a {@code ThreadLocal} — MDC is one, {@link TenantContext} is another — and
 * a thread pool does not inherit one. So an {@code @Async} method ran with no correlation id and no
 * tenant. Nothing failed: the log line was written, it simply could not be joined to the request
 * that caused it, which reads as a gap in the logs rather than as a bug.
 *
 * <p>The tenant half is inert today, because nothing in this template populates
 * {@code TenantContext} — see its own note. It is wired now for the reason the seam exists at all:
 * the day somebody activates it with a filter, async work already carries the tenant, rather than
 * silently running everything under {@code default} in the one place nobody looks.
 *
 * <h2>Read at submit time, bound in the worker, cleared in a finally</h2>
 *
 * The capture happens on the calling thread, while the request's values are still bound. Anything
 * read inside the returned {@code Runnable} would be read on the worker, which is the bug this
 * exists to fix rather than a way to fix it.
 *
 * <p>The {@code finally} matters as much as the binding. A pooled thread outlives the task, so a
 * value left behind is inherited by whatever runs next — the same leak, in the opposite direction,
 * and worse: a stale tenant is not a missing tenant, it is somebody else's.
 *
 * <h2>One MDC key, not the whole map</h2>
 *
 * The same choice the gateway's Reactor bridge makes, for the same reason: copying all of MDC would
 * also copy whatever a library happened to leave in it, and a value that arrives on a worker thread
 * without anybody deciding it should is how MDC becomes untrustworthy.
 */
public class ContextPropagatingTaskDecorator implements TaskDecorator {

    @Override
    public Runnable decorate(Runnable task) {
        // On the SUBMITTING thread, while the request's context is still bound.
        String correlationId = MDC.get(CorrelationId.MDC_KEY);
        String tenant = TenantContext.getTenant();

        return () -> {
            if (correlationId != null) {
                MDC.put(CorrelationId.MDC_KEY, correlationId);
            }
            TenantContext.set(tenant);
            try {
                task.run();
            } finally {
                // Cleared, not restored to what the worker had. A pooled thread has no legitimate
                // request context of its own; anything it was carrying was left by the previous
                // task and should not outlive it either.
                MDC.remove(CorrelationId.MDC_KEY);
                TenantContext.clear();
            }
        };
    }
}
