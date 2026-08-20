package com.xenopsoftware.core.web.filter;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.UUID;
import org.slf4j.MDC;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Adopts the correlation id the gateway assigned, so a request can be followed across services
 * (T-3.8).
 *
 * <p>Far simpler than the gateway's equivalent, and that difference is the point of keeping the
 * reactive footprint in the gateway alone. Core is servlet-based: one request, one thread, so MDC
 * works exactly as it appears to. No Reactor context, no thread-local accessor, no propagation
 * hook.
 *
 * <h2>Generating an id here is a signal, not a fallback</h2>
 *
 * If no id arrives, one is generated with a {@code direct-} prefix. Every request that reached
 * this service through the gateway carries an id, so a {@code direct-} id in the logs means
 * something bypassed the gateway — which is worth being able to see rather than smoothing over.
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class CorrelationIdFilter extends OncePerRequestFilter {

    /**
     * {@code X-Request-Id}: the same header the gateway sets, and one that proxies and Cloudflare
     * already understand. Both services must agree on the spelling or the chain breaks silently
     * at the hop — each side would generate its own id and neither would report an error.
     */
    public static final String HEADER = "X-Request-Id";

    public static final String MDC_KEY = "requestId";

    private static final int MAX_LENGTH = 64;

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
        throws ServletException, IOException {
        String id = sanitize(request.getHeader(HEADER));
        MDC.put(MDC_KEY, id);
        response.setHeader(HEADER, id);
        try {
            chain.doFilter(request, response);
        } finally {
            // Threads are pooled. Leaving the id behind attributes the next request's log lines
            // to this one, which is worse than having no id: the logs are confidently wrong.
            MDC.remove(MDC_KEY);
        }
    }

    /**
     * The header is attacker-controlled and lands in every log line, so an unvalidated value is a
     * log-forging vector — a newline in it writes fabricated entries.
     */
    private static String sanitize(String inbound) {
        if (inbound == null || inbound.isBlank() || inbound.length() > MAX_LENGTH) {
            return "direct-" + UUID.randomUUID().toString().replace("-", "");
        }
        for (int i = 0; i < inbound.length(); i++) {
            char c = inbound.charAt(i);
            boolean allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
            if (!allowed) {
                return "direct-" + UUID.randomUUID().toString().replace("-", "");
            }
        }
        return inbound;
    }
}
