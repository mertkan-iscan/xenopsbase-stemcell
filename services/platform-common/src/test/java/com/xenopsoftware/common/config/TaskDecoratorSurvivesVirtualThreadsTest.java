package com.xenopsoftware.common.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.core.task.AsyncTaskExecutor;
import org.springframework.core.task.TaskDecorator;

/**
 * A {@link TaskDecorator} is still applied when virtual threads are on (T-9.8).
 *
 * <h2>The failure this exists to catch, which produces no error</h2>
 *
 * Boot builds the executor through a <em>different auto-configuration path</em> when
 * {@code spring.threads.virtual.enabled} is true: a {@code SimpleAsyncTaskExecutor} with a virtual
 * thread factory, rather than a {@code ThreadPoolTaskExecutor}. A decorator wired to one and not the
 * other is not a compile error and not a startup failure — it is an {@code @Async} method quietly
 * losing whatever the decorator was carrying.
 *
 * <p>In this template that is the correlation id and, once the tenancy seam is activated, the
 * tenant. Losing the first makes an async log line uncorrelatable, which reads as a gap in the logs.
 * Losing the second is a tenant boundary that stops holding on exactly the code paths nobody watches.
 *
 * <h2>There is a TaskDecorator now, and this test still supplies its own</h2>
 *
 * When this was written in T-9.8 there was none, and the plan said to write it anyway: "written
 * now, this is the thing that fails the day somebody adds a decorator to a virtual-threaded
 * application and assumes it works." That day was T-9.10, and it found more than expected — the
 * production {@code @Async} executor was hand-built and would have dropped any decorator whatever
 * this test said. {@code ContextPropagatingTaskDecorator} and {@code AsyncConfigurationTest} in
 * platform-common-web and beside this file are the result.
 *
 * <p>This test keeps supplying its OWN decorator rather than the production one, deliberately. What
 * it asserts is Boot's behaviour — that an executor built the virtual-threads way still runs a
 * decorator bean — and using the real decorator would couple that to whatever the real one happens
 * to carry. The production wiring is asserted separately, where it belongs.
 */
class TaskDecoratorSurvivesVirtualThreadsTest {

    private final ApplicationContextRunner runner = new ApplicationContextRunner().withConfiguration(
        AutoConfigurations.of(org.springframework.boot.autoconfigure.task.TaskExecutionAutoConfiguration.class)
    );

    @Test
    @DisplayName("with virtual threads on, a TaskDecorator bean is still applied to the executor")
    void decoratorIsAppliedOnVirtualThreads() {
        AtomicBoolean decorated = new AtomicBoolean(false);
        AtomicReference<Boolean> ranOnVirtualThread = new AtomicReference<>();

        runner
            .withPropertyValues("spring.threads.virtual.enabled=true")
            .withBean(TaskDecorator.class, () -> runnable -> () -> {
                decorated.set(true);
                runnable.run();
            })
            .run(context -> {
                assertThat(context).hasNotFailed();

                AsyncTaskExecutor executor = context.getBean("applicationTaskExecutor", AsyncTaskExecutor.class);
                CountDownLatch done = new CountDownLatch(1);
                executor.execute(() -> {
                    ranOnVirtualThread.set(Thread.currentThread().isVirtual());
                    done.countDown();
                });

                assertThat(done.await(10, TimeUnit.SECONDS)).as("the task ran").isTrue();

                // Both halves matter. The second on its own would pass with the decorator silently
                // dropped, which is the exact defect being guarded against.
                assertThat(ranOnVirtualThread.get()).as("virtual threads really are in effect").isTrue();
                assertThat(decorated.get()).as("the TaskDecorator was applied to the virtual-thread executor").isTrue();
            });
    }

    @Test
    @DisplayName("and on the pooled executor too, so the assertion above is about virtual threads")
    void decoratorIsAppliedOnPlatformThreads() {
        AtomicBoolean decorated = new AtomicBoolean(false);

        runner
            .withPropertyValues("spring.threads.virtual.enabled=false")
            .withBean(TaskDecorator.class, () -> runnable -> () -> {
                decorated.set(true);
                runnable.run();
            })
            .run(context -> {
                assertThat(context).hasNotFailed();

                AsyncTaskExecutor executor = context.getBean("applicationTaskExecutor", AsyncTaskExecutor.class);
                CountDownLatch done = new CountDownLatch(1);
                executor.execute(done::countDown);

                assertThat(done.await(10, TimeUnit.SECONDS)).isTrue();
                // The control. Without it, a decorator applied on NEITHER path would make the
                // first test's failure look specific to virtual threads when it is not.
                //
                // Note what is NOT supplied here: a ThreadPoolTaskExecutorBuilder. The first
                // version of this test provided one, which replaced the auto-configured builder --
                // the very object that applies the decorator -- and failed. That is the same class
                // of mistake the test is about, made one level up, and it is worth leaving on the
                // record: the decorator is wired by Boot's builder, so anything that substitutes
                // the builder silently drops it.
                assertThat(decorated.get()).isTrue();
            });
    }
}
