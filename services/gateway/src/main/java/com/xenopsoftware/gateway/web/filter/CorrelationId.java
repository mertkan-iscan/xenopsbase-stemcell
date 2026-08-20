package com.xenopsoftware.gateway.web.filter;

/**
 * The correlation identifier contract, shared by the gateway and every downstream service (T-3.8).
 *
 * <p>One request gets one id at the edge, and every log line it causes — in any service — carries
 * it. Without that, correlating a user-visible failure with the log line that explains it means
 * guessing from timestamps across services, which stops working the moment there is more than one
 * request in flight.
 *
 * <p>Deliberately a separate concept from the W3C {@code traceparent} used by distributed tracing.
 * They answer different questions and have different lifetimes: a trace id is for spans and
 * sampling, and a sampled-out trace still needs a correlation id in its logs. When tracing lands
 * (T-2.7) both should appear on a log line rather than one replacing the other.
 */
public final class CorrelationId {

    /**
     * {@code X-Request-Id} rather than a bespoke name: proxies, load balancers and Cloudflare
     * already understand it, so an id set further out survives instead of being replaced here.
     */
    public static final String HEADER = "X-Request-Id";

    /** MDC key. Referenced by name in logback-spring.xml, so renaming it silently empties the field. */
    public static final String MDC_KEY = "requestId";

    /**
     * An inbound id is accepted only if it looks like one. The value is attacker-controlled and
     * ends up in every log line, so an unvalidated one is a log-injection and log-forging vector:
     * a newline in it writes fabricated entries into the log.
     */
    public static final int MAX_LENGTH = 64;

    private CorrelationId() {}

    /** True if an inbound header value is safe to adopt rather than replace. */
    public static boolean isAcceptable(String value) {
        if (value == null || value.isBlank() || value.length() > MAX_LENGTH) {
            return false;
        }
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            boolean allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
            if (!allowed) {
                return false;
            }
        }
        return true;
    }
}
