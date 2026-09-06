package com.xenopsoftware.common.correlation;

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
 * sampling, and a sampled-out trace still needs a correlation id in its logs. Both appear on a log
 * line rather than one replacing the other.
 *
 * <h2>Why this class is here and not in a filter</h2>
 *
 * The two web stacks cannot share a filter — the gateway is WebFlux and every other service is
 * servlet — but they must share the spelling, or the chain breaks silently at the hop: each side
 * would generate its own id and neither would report an error. So the constants live in the
 * stack-neutral module and each stack brings its own filter (ADR-0017).
 */
public final class CorrelationId {

    /**
     * {@code X-Correlation-Id}: the name that says what the value is — a join key across services
     * — rather than what carried it.
     *
     * <p>THIS USED TO BE {@code X-Request-Id}, and the rename is what makes a request that crosses
     * from xenopsbase-learn into this template carry ONE id instead of two. Learn had already
     * settled on this spelling; a request crossing the two products previously got an id from each
     * and no way to join them. The stemcell is the template, so it is the side that moved.
     *
     * <p>Proxies and Cloudflare understand {@code X-Request-Id} and not this, which is the cost:
     * an id set further out by infrastructure is no longer adopted. That is acceptable because the
     * gateway is the edge for these services and mints the id itself; a deployment that terminates
     * somewhere else can map the header at that hop.
     */
    public static final String HEADER = "X-Correlation-Id";

    /** MDC key. Referenced by name in logback-spring.xml, so renaming it silently empties the field. */
    public static final String MDC_KEY = "correlationId";

    /**
     * The span attribute both stacks tag, so a trace can be found by the id a caller can quote.
     * One spelling, or a trace carries the id under two names.
     */
    public static final String SPAN_ATTRIBUTE = "correlation.id";

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
