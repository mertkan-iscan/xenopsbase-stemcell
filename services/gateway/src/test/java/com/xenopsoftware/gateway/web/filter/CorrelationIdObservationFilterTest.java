package com.xenopsoftware.gateway.web.filter;

import static org.assertj.core.api.Assertions.assertThat;

import io.micrometer.common.KeyValue;
import io.micrometer.observation.Observation;
import java.util.HashMap;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.http.server.reactive.observation.ServerRequestObservationContext;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.http.server.reactive.MockServerHttpResponse;

/**
 * The trace side of T-3.8's correlation id criterion.
 *
 * <p>Each test is aimed at a way this can fail without anything reporting it: the id missing from
 * spans entirely, or present as a low-cardinality key value, which would put a unique value per
 * request into Prometheus.
 */
class CorrelationIdObservationFilterTest {

    private final CorrelationIdObservationFilter filter = new CorrelationIdObservationFilter();

    private static ServerRequestObservationContext context(String responseHeaderValue) {
        MockServerHttpRequest request = MockServerHttpRequest.get("/api/documents").build();
        MockServerHttpResponse response = new MockServerHttpResponse();
        if (responseHeaderValue != null) {
            response.getHeaders().set(CorrelationId.HEADER, responseHeaderValue);
        }
        return new ServerRequestObservationContext(request, response, new HashMap<>());
    }

    @Test
    @DisplayName("the id a caller receives is the id the span carries")
    void tagsTheSpanWithTheResponseHeader() {
        Observation.Context mapped = filter.map(context("a1b2c3d4"));

        assertThat(mapped.getHighCardinalityKeyValue(CorrelationIdObservationFilter.SPAN_ATTRIBUTE))
            .isEqualTo(KeyValue.of(CorrelationIdObservationFilter.SPAN_ATTRIBUTE, "a1b2c3d4"));
    }

    @Test
    @DisplayName("HIGH cardinality, so a per-request value never reaches a metric tag")
    void doesNotAddTheIdAsALowCardinalityKeyValue() {
        Observation.Context mapped = filter.map(context("a1b2c3d4"));

        assertThat(mapped.getLowCardinalityKeyValues().stream().map(KeyValue::getKey))
            .doesNotContain(CorrelationIdObservationFilter.SPAN_ATTRIBUTE);
    }

    @Test
    @DisplayName("no header, no tag - rather than a tag with an empty value")
    void addsNothingWhenTheHeaderIsAbsent() {
        Observation.Context mapped = filter.map(context(null));

        assertThat(mapped.getHighCardinalityKeyValues().stream().map(KeyValue::getKey))
            .doesNotContain(CorrelationIdObservationFilter.SPAN_ATTRIBUTE);
    }

    @Test
    @DisplayName("a non-HTTP observation passes through untouched")
    void leavesOtherObservationContextsAlone() {
        Observation.Context other = new Observation.Context();

        assertThat(filter.map(other)).isSameAs(other);
        assertThat(other.getHighCardinalityKeyValues()).isEmpty();
    }
}
