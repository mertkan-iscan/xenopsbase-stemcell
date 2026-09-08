package com.xenopsoftware.common.config;

import static org.assertj.core.api.Assertions.assertThat;

import com.xenopsoftware.common.correlation.CorrelationId;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.slf4j.MDC;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.autoconfigure.task.TaskExecutionAutoConfiguration;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.core.task.AsyncTaskExecutor;
import org.springframework.core.task.TaskDecorator;

/**
 * The decorator is actually WIRED to the executor async work runs on (T-9.10).
 *
 * <h2>Why this is separate from ContextPropagatingTaskDecoratorTest</h2>
 *
 * That test proves the decorator does its job when something calls it. This one proves something
 * calls it — which is the half that was broken, and broken invisibly.
 *
 * <p>{@code AsyncConfiguration} used to build its own {@code ThreadPoolTaskExecutor}. Boot applies
 * {@link TaskDecorator} beans when it BUILDS an executor, so an executor constructed by hand never
 * sees one. The decorator would have existed, been a bean, looked wired, and been applied to
 * nothing. A test of the decorator alone passes throughout that.
 *
 * <p>So this asserts the property through Boot's own executor, with the real decorator, under
 * virtual threads — which T-9.8 turned on, and which the hand-built executor also ignored.
 */
class AsyncCarriesTheCorrelationIdTest {

    private final ApplicationContextRunner runner =
        new ApplicationContextRunner()
            .withConfiguration(AutoConfigurations.of(TaskExecutionAutoConfiguration.class))
            // The production bean, not a stand-in. A lambda here would prove Boot applies SOME
            // decorator, which TaskDecoratorSurvivesVirtualThreadsTest already covers.
            .withBean(ContextPropagatingTaskDecorator.class, ContextPropagatingTaskDecorator::new);

    @AfterEach
    void clearCallingThread() {
        MDC.remove(CorrelationId.MDC_KEY);
    }

    private static AtomicReference<String> runAndCapture(AsyncTaskExecutor executor) throws Exception {
        AtomicReference<String> seen = new AtomicReference<>("(not run)");
        CountDownLatch done = new CountDownLatch(1);
        executor.execute(() -> {
            seen.set(MDC.get(CorrelationId.MDC_KEY));
            done.countDown();
        });
        assertThat(done.await(10, TimeUnit.SECONDS)).as("the task ran").isTrue();
        return seen;
    }

    @Test
    @DisplayName("with virtual threads on, work submitted to Boot's executor keeps the correlation id")
    void theIdSurvivesOnVirtualThreads() {
        runner.withPropertyValues("spring.threads.virtual.enabled=true").run(context -> {
            assertThat(context).hasNotFailed();
            MDC.put(CorrelationId.MDC_KEY, "abc123");

            var executor = context.getBean("applicationTaskExecutor", AsyncTaskExecutor.class);
            assertThat(runAndCapture(executor).get())
                .as("Boot applied the production decorator to the executor it built")
                .isEqualTo("abc123");
        });
    }

    @Test
    @DisplayName("and on the pooled executor, so the assertion above is about wiring, not threads")
    void theIdSurvivesOnPlatformThreads() {
        runner.withPropertyValues("spring.threads.virtual.enabled=false").run(context -> {
            assertThat(context).hasNotFailed();
            MDC.put(CorrelationId.MDC_KEY, "abc123");

            var executor = context.getBean("applicationTaskExecutor", AsyncTaskExecutor.class);
            // The control. Without it, a decorator applied on NEITHER path would make the first
            // test's failure look specific to virtual threads when it is not.
            assertThat(runAndCapture(executor).get()).isEqualTo("abc123");
        });
    }
}
