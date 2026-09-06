package com.xenopsoftware.common.web.filter;

import com.xenopsoftware.common.correlation.CorrelationId;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.UUID;
import org.slf4j.MDC;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Adopts the correlation id the gateway assigned, so a request can be followed across services
 * (T-3.8).
 *
 * <p>Far simpler than the gateway's equivalent, and that difference is the point of keeping the
 * reactive footprint in the gateway alone. A servlet service is one request, one thread, so MDC
 * works exactly as it appears to. No Reactor context, no thread-local accessor, no propagation
 * hook.
 *
 * <p>The header name, the MDC key and what counts as an acceptable inbound value all come from
 * {@link CorrelationId} in the stack-neutral module, so this filter and the gateway's WebFilter
 * cannot drift apart (ADR-0017).
 *
 * <h2>Generating an id here is a signal, not a fallback</h2>
 *
 * If no id arrives, one is generated with a {@code direct-} prefix. Every request that reached
 * this service through the gateway carries an id, so a {@code direct-} id in the logs means
 * something bypassed the gateway — which is worth being able to see rather than smoothing over.
 */
@Order(Ordered.HIGHEST_PRECEDENCE)
public class CorrelationIdFilter extends OncePerRequestFilter {

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
        throws ServletException, IOException {
        String id = sanitize(request.getHeader(CorrelationId.HEADER));
        MDC.put(CorrelationId.MDC_KEY, id);
        response.setHeader(CorrelationId.HEADER, id);
        try {
            chain.doFilter(request, response);
        } finally {
            // Threads are pooled. Leaving the id behind attributes the next request's log lines
            // to this one, which is worse than having no id: the logs are confidently wrong.
            MDC.remove(CorrelationId.MDC_KEY);
        }
    }

    /**
     * The header is attacker-controlled and lands in every log line, so an unvalidated value is a
     * log-forging vector — a newline in it writes fabricated entries.
     */
    private static String sanitize(String inbound) {
        return CorrelationId.isAcceptable(inbound) ? inbound : "direct-" + UUID.randomUUID().toString().replace("-", "");
    }
}
