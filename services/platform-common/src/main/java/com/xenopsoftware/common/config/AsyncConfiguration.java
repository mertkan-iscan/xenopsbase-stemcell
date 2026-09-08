package com.xenopsoftware.common.config;

import java.util.concurrent.Executor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.aop.interceptor.AsyncUncaughtExceptionHandler;
import org.springframework.aop.interceptor.SimpleAsyncUncaughtExceptionHandler;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Profile;
import org.springframework.core.task.AsyncTaskExecutor;
import org.springframework.scheduling.annotation.AsyncConfigurer;
import org.springframework.scheduling.annotation.EnableAsync;
import org.springframework.scheduling.annotation.EnableScheduling;
import tech.jhipster.async.ExceptionHandlingAsyncTaskExecutor;

@AutoConfiguration
@EnableAsync
@EnableScheduling
@Profile("!testdev & !testprod")
public class AsyncConfiguration implements AsyncConfigurer {

    private static final Logger LOG = LoggerFactory.getLogger(AsyncConfiguration.class);

    private final ObjectProvider<AsyncTaskExecutor> applicationTaskExecutor;

    public AsyncConfiguration(ObjectProvider<AsyncTaskExecutor> applicationTaskExecutor) {
        this.applicationTaskExecutor = applicationTaskExecutor;
    }

    /**
     * BOOT'S EXECUTOR, NOT ONE BUILT HERE, AND THAT IS A FIX RATHER THAN TIDYING (T-9.10).
     *
     * <p>This method used to do {@code new ThreadPoolTaskExecutor()} and configure it from
     * {@code TaskExecutionProperties} by hand. It looked equivalent to what Boot builds. It was
     * not, in two ways that both fail silently.
     *
     * <ul>
     *   <li><b>A {@code TaskDecorator} bean never reached it.</b> Boot applies decorators when it
     *       BUILDS an executor; an executor constructed here is never shown to the builder. So the
     *       correlation id and the tenant would have been dropped by every {@code @Async} call
     *       while a decorator sat in the context looking wired.
     *       {@code TaskDecoratorSurvivesVirtualThreadsTest} records this exact trap in a comment —
     *       "anything that substitutes the builder silently drops it" — and this file was the thing
     *       doing it.</li>
     *   <li><b>Virtual threads did not apply.</b> T-9.8 set
     *       {@code spring.threads.virtual.enabled}, which makes Boot build a virtual-thread
     *       executor. A hand-built {@code ThreadPoolTaskExecutor} ignores that setting entirely, so
     *       {@code @Async} kept running on a bounded platform-thread pool — the one path where the
     *       change was most likely to matter, and the one place it did not happen.</li>
     * </ul>
     *
     * <p>Delegating to the auto-configured executor gets both, and keeps the pool properties
     * working: Boot reads the same {@code spring.task.execution} values this used to copy.
     *
     * <p>Still wrapped in {@code ExceptionHandlingAsyncTaskExecutor}, which logs what an
     * {@code @Async} task threw. {@link #getAsyncUncaughtExceptionHandler()} only covers
     * void-returning methods; this covers the rest. The wrapper delegates, so the decorator applied
     * by the builder underneath is unaffected.
     */
    @Override
    @Bean(name = "taskExecutor")
    public Executor getAsyncExecutor() {
        AsyncTaskExecutor executor = applicationTaskExecutor.getObject();
        LOG.debug("Async tasks run on Boot's {}", executor.getClass().getSimpleName());
        return new ExceptionHandlingAsyncTaskExecutor(executor);
    }

    @Override
    public AsyncUncaughtExceptionHandler getAsyncUncaughtExceptionHandler() {
        return new SimpleAsyncUncaughtExceptionHandler();
    }
}
