package com.xenopsoftware.gateway.config;

import com.xenopsoftware.gateway.web.filter.CorrelationId;
import io.micrometer.context.ContextRegistry;
import io.micrometer.context.ThreadLocalAccessor;
import jakarta.annotation.PostConstruct;
import org.slf4j.MDC;
import org.springframework.context.annotation.Configuration;
import reactor.core.publisher.Hooks;

/**
 * Bridges the correlation id between the Reactor context and MDC (T-3.8).
 *
 * <p>In a reactive application the two are not the same thing and neither works alone. The Reactor
 * context follows the request across threads but logback cannot read it; MDC is what
 * {@code %X{requestId}} reads but it is thread-local, and WebFlux moves a request between threads
 * whenever it pleases.
 *
 * <p>Registering a {@link ThreadLocalAccessor} tells Micrometer's context propagation how to
 * restore the id into MDC around each operator, so a log line written from any scheduler carries
 * it. Without this the pattern silently renders an empty field — the logs look fine and simply
 * have nothing in that column, which is a hard thing to notice and an easy thing to assume is
 * working.
 *
 * <p>{@code Hooks.enableAutomaticContextPropagation()} is what applies it without every operator
 * opting in. It has a cost — the restore happens per operator — and it is paid deliberately here,
 * because logs that cannot be correlated are only useful when exactly one request is in flight.
 */
@Configuration
public class CorrelationIdContextConfiguration {

    @PostConstruct
    public void registerCorrelationIdAccessor() {
        ContextRegistry.getInstance().registerThreadLocalAccessor(new MdcCorrelationIdAccessor());
        Hooks.enableAutomaticContextPropagation();
    }

    /**
     * Moves one MDC entry, not the whole map. Propagating all of MDC would also carry values a
     * downstream operator never set, which produces log lines attributed to the wrong request —
     * a subtler and more damaging failure than having no id at all.
     */
    static final class MdcCorrelationIdAccessor implements ThreadLocalAccessor<String> {

        @Override
        public Object key() {
            return CorrelationId.MDC_KEY;
        }

        @Override
        public String getValue() {
            return MDC.get(CorrelationId.MDC_KEY);
        }

        @Override
        public void setValue(String value) {
            MDC.put(CorrelationId.MDC_KEY, value);
        }

        @Override
        public void setValue() {
            // Called when the context has no value: the thread must be left clean, or the id
            // leaks into the next request that happens to reuse this thread.
            MDC.remove(CorrelationId.MDC_KEY);
        }
    }
}
