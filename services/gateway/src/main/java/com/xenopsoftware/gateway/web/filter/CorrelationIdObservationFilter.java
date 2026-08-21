package com.xenopsoftware.gateway.web.filter;

import io.micrometer.common.KeyValue;
import io.micrometer.observation.Observation;
import io.micrometer.observation.ObservationFilter;
import org.springframework.http.server.reactive.ServerHttpResponse;
import org.springframework.http.server.reactive.observation.ServerRequestObservationContext;
import org.springframework.stereotype.Component;

/**
 * Puts the correlation id onto the span, so a trace can be found by the id a caller can quote
 * (T-3.8).
 *
 * <p>Without this the two halves of the criterion are asymmetric. A log line already carries
 * {@code requestId}, {@code traceId} and {@code spanId} together, so going from a log line to its
 * trace is one hop. Going the other way — from the id in a user's response header to the trace —
 * meant searching logs for the id, reading the trace id off the line, and searching again. The
 * value a caller actually has was the one value the trace store could not be queried by.
 *
 * <h2>Why an ObservationFilter rather than setting it on the span directly</h2>
 *
 * {@code Span.current()} is empty where the correlation id is assigned. {@link
 * CorrelationIdWebFilter} runs at {@code HIGHEST_PRECEDENCE} deliberately, so that every log line
 * is correlated — which places it <em>ahead</em> of the observation that creates the server span.
 * Setting an attribute there succeeds against an invalid span and records nothing, which is the
 * shape of failure this codebase keeps finding: configured, green, and doing nothing.
 *
 * <p>An {@link ObservationFilter} runs when the observation stops, by which point the span exists
 * and the response header has long been set.
 *
 * <h2>High cardinality, and why that word is load-bearing</h2>
 *
 * Micrometer sends low-cardinality key values to metrics <em>and</em> spans, high-cardinality ones
 * to spans only. A correlation id is unique per request: as a low-cardinality key it would mint a
 * new Prometheus time series for every request the system serves. That is not a degradation, it is
 * an outage of the metrics stack, arriving hours later and looking like a Prometheus fault.
 *
 * <p>That the mechanism works is observable in the trace store already — {@code uri} is the
 * low-cardinality, templated form and {@code http.url} the high-cardinality one, and both are
 * present as span attributes.
 */
@Component
public class CorrelationIdObservationFilter implements ObservationFilter {

    /**
     * Dotted, unlike the {@code requestId} MDC key, because span attributes are namespaced with
     * dots by convention and every other attribute in the trace store follows it.
     */
    public static final String SPAN_ATTRIBUTE = "request.id";

    @Override
    public Observation.Context map(Observation.Context context) {
        if (!(context instanceof ServerRequestObservationContext serverContext)) {
            return context;
        }

        // Read from the RESPONSE, not the request. The response header is the value the caller
        // actually receives and would quote, and it is set unconditionally -- including for a
        // request that arrived with no id, or with one that failed validation and was replaced.
        // Reading the inbound header would silently skip exactly those requests.
        ServerHttpResponse response = serverContext.getResponse();
        if (response == null) {
            return context;
        }

        String id = response.getHeaders().getFirst(CorrelationId.HEADER);
        if (id == null || id.isBlank()) {
            return context;
        }

        return context.addHighCardinalityKeyValue(KeyValue.of(SPAN_ATTRIBUTE, id));
    }
}
