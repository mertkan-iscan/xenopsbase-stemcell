package com.xenopsoftware.core.web.filter;

import static org.assertj.core.api.Assertions.assertThat;

import io.micrometer.common.KeyValue;
import io.micrometer.observation.Observation;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.http.server.observation.ServerRequestObservationContext;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

/** The servlet twin of the gateway's test, aimed at the same silent failures. */
class CorrelationIdObservationFilterTest {

    private final CorrelationIdObservationFilter filter = new CorrelationIdObservationFilter();

    private static ServerRequestObservationContext context(String responseHeaderValue) {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/api/documents");
        MockHttpServletResponse response = new MockHttpServletResponse();
        if (responseHeaderValue != null) {
            response.setHeader(CorrelationIdFilter.HEADER, responseHeaderValue);
        }
        return new ServerRequestObservationContext(request, response);
    }

    @Test
    @DisplayName("the id a caller receives is the id the span carries")
    void tagsTheSpanWithTheResponseHeader() {
        Observation.Context mapped = filter.map(context("a1b2c3d4"));

        assertThat(mapped.getHighCardinalityKeyValue(CorrelationIdObservationFilter.SPAN_ATTRIBUTE)).isEqualTo(
            KeyValue.of(CorrelationIdObservationFilter.SPAN_ATTRIBUTE, "a1b2c3d4")
        );
    }

    @Test
    @DisplayName("a generated direct- id is tagged too, so a gateway bypass is visible in traces")
    void tagsAGeneratedDirectId() {
        Observation.Context mapped = filter.map(context("direct-0123456789abcdef"));

        assertThat(mapped.getHighCardinalityKeyValue(CorrelationIdObservationFilter.SPAN_ATTRIBUTE).getValue()).isEqualTo(
            "direct-0123456789abcdef"
        );
    }

    @Test
    @DisplayName("HIGH cardinality, so a per-request value never reaches a metric tag")
    void doesNotAddTheIdAsALowCardinalityKeyValue() {
        Observation.Context mapped = filter.map(context("a1b2c3d4"));

        assertThat(mapped.getLowCardinalityKeyValues().stream().map(KeyValue::getKey)).doesNotContain(
            CorrelationIdObservationFilter.SPAN_ATTRIBUTE
        );
    }

    @Test
    @DisplayName("no header, no tag - rather than a tag with an empty value")
    void addsNothingWhenTheHeaderIsAbsent() {
        Observation.Context mapped = filter.map(context(null));

        assertThat(mapped.getHighCardinalityKeyValues().stream().map(KeyValue::getKey)).doesNotContain(
            CorrelationIdObservationFilter.SPAN_ATTRIBUTE
        );
    }

    @Test
    @DisplayName("a non-HTTP observation passes through untouched")
    void leavesOtherObservationContextsAlone() {
        Observation.Context other = new Observation.Context();

        assertThat(filter.map(other)).isSameAs(other);
        assertThat(other.getHighCardinalityKeyValues()).isEmpty();
    }
}
