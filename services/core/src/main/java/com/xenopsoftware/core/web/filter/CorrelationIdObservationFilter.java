package com.xenopsoftware.core.web.filter;

import io.micrometer.common.KeyValue;
import io.micrometer.observation.Observation;
import io.micrometer.observation.ObservationFilter;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.http.server.observation.ServerRequestObservationContext;
import org.springframework.stereotype.Component;

/**
 * Puts the correlation id onto the span, so a trace can be found by the id a caller can quote
 * (T-3.8).
 *
 * <p>The gateway's twin, and the same reasoning: see {@code CorrelationIdObservationFilter} there.
 * The duplication is the servlet/reactive split again — the two stacks have different
 * {@code ServerRequestObservationContext} types in different packages, and neither can see the
 * other's. This looks like copy-paste and is not, in the same way {@code SecurityProblemSupport}
 * exists twice.
 *
 * <p>The value tagged here is core's own view of the id, which is what makes a {@code direct-}
 * prefix visible in the trace store as well as in the logs: a span carrying one is a span for a
 * request that reached this service without passing the gateway.
 */
@Component
public class CorrelationIdObservationFilter implements ObservationFilter {

    /** The same attribute name the gateway uses, or a trace carries the id under two spellings. */
    public static final String SPAN_ATTRIBUTE = "request.id";

    @Override
    public Observation.Context map(Observation.Context context) {
        if (!(context instanceof ServerRequestObservationContext serverContext)) {
            return context;
        }

        // The response, for the same reason as the gateway: it is set on every path, including
        // the one where an absent or rejected inbound id was replaced with a generated one.
        HttpServletResponse response = serverContext.getResponse();
        if (response == null) {
            return context;
        }

        String id = response.getHeader(CorrelationIdFilter.HEADER);
        if (id == null || id.isBlank()) {
            return context;
        }

        return context.addHighCardinalityKeyValue(KeyValue.of(SPAN_ATTRIBUTE, id));
    }
}
