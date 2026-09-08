package com.xenopsoftware.common.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.concurrent.Executor;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.core.task.AsyncTaskExecutor;
import org.springframework.core.task.SimpleAsyncTaskExecutor;

/**
 * {@code @Async} runs on the executor BOOT built, not one this class made (T-9.10).
 *
 * <h2>The regression this exists to catch, which no other test can</h2>
 *
 * {@code ContextPropagatingTaskDecoratorTest} proves the decorator works.
 * {@code AsyncCarriesTheCorrelationIdTest} proves Boot's builder applies it. Neither notices if
 * this class goes back to {@code new ThreadPoolTaskExecutor()} — both would still pass, and
 * {@code @Async} would silently stop carrying anything again.
 *
 * <p>That is not hypothetical: it is what this class did until T-9.10, and it cost two things at
 * once. A {@code TaskDecorator} bean never reached {@code @Async}, because Boot applies decorators
 * when it BUILDS an executor and one constructed here is never shown to the builder. And T-9.8's
 * virtual threads never reached it either, because a hand-built {@code ThreadPoolTaskExecutor}
 * ignores {@code spring.threads.virtual.enabled}.
 *
 * <p>So this asserts the one property that fixes both: the executor handed to {@code @Async} is the
 * one Boot auto-configured.
 */
class AsyncConfigurationTest {

    /** The smallest real {@link ObjectProvider}: enough for the one call under test. */
    private static ObjectProvider<AsyncTaskExecutor> providing(AsyncTaskExecutor executor) {
        return new ObjectProvider<>() {
            @Override
            public AsyncTaskExecutor getObject() {
                return executor;
            }

            @Override
            public AsyncTaskExecutor getObject(Object... args) {
                return executor;
            }

            @Override
            public AsyncTaskExecutor getIfAvailable() {
                return executor;
            }

            @Override
            public AsyncTaskExecutor getIfUnique() {
                return executor;
            }
        };
    }

    @Test
    @DisplayName("the async executor delegates to Boot's, rather than being built here")
    void asyncWorkRunsOnBootsExecutor() {
        AtomicBoolean ranOnTheProvidedExecutor = new AtomicBoolean(false);
        AsyncTaskExecutor boots = new SimpleAsyncTaskExecutor() {
            @Override
            public void execute(Runnable task) {
                // Marking rather than counting: the assertion is "this object was used at all",
                // which is exactly what a hand-built executor would make false.
                ranOnTheProvidedExecutor.set(true);
                task.run();
            }
        };

        Executor executor = new AsyncConfiguration(providing(boots)).getAsyncExecutor();
        executor.execute(() -> {});

        assertThat(ranOnTheProvidedExecutor)
            .as("a hand-built executor here is what silently drops the TaskDecorator and virtual threads")
            .isTrue();
    }

    @Test
    @DisplayName("it is still wrapped, so an @Async failure is still logged")
    void theExceptionHandlingWrapperIsKept() {
        Executor executor = new AsyncConfiguration(providing(new SimpleAsyncTaskExecutor())).getAsyncExecutor();

        // getAsyncUncaughtExceptionHandler covers void-returning @Async methods only; this wrapper
        // is what reports the rest. Delegating to Boot's executor must not have quietly dropped it.
        assertThat(executor).isInstanceOf(tech.jhipster.async.ExceptionHandlingAsyncTaskExecutor.class);
    }
}
