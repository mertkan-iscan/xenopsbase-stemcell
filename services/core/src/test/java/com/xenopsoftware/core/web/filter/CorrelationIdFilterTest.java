package com.xenopsoftware.core.web.filter;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import jakarta.servlet.FilterChain;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.mockito.ArgumentCaptor;
import org.slf4j.MDC;

/**
 * The header this filter sanitises is attacker-controlled and lands in every log line, so the
 * rejection rules are a security control rather than tidiness — the class javadoc says so, and
 * before this test 25 of its 26 branches were untaken.
 *
 * <p>Which is the combination T-5.9 (#172) is about: a defence nothing exercises is indistinguishable
 * from an absent one until somebody forges a log entry.
 */
class CorrelationIdFilterTest {

    private final CorrelationIdFilter filter = new CorrelationIdFilter();

    /** Runs the filter and returns the id it settled on, taken from the response header. */
    private String idFor(String inboundHeader) throws Exception {
        HttpServletRequest request = mock(HttpServletRequest.class);
        HttpServletResponse response = mock(HttpServletResponse.class);
        FilterChain chain = mock(FilterChain.class);
        when(request.getHeader(CorrelationIdFilter.HEADER)).thenReturn(inboundHeader);

        filter.doFilterInternal(request, response, chain);

        ArgumentCaptor<String> captor = ArgumentCaptor.forClass(String.class);
        verify(response).setHeader(org.mockito.ArgumentMatchers.eq(CorrelationIdFilter.HEADER), captor.capture());
        return captor.getValue();
    }

    /**
     * A generated id is prefixed {@code direct-} on purpose: every request through the gateway
     * carries one, so the prefix means something bypassed it. The javadoc calls that a signal
     * rather than a fallback, and a test that only checked "an id exists" would lose the
     * distinction.
     */
    @ParameterizedTest
    @ValueSource(strings = { "", "   ", "\t" })
    void aBlankHeaderIsReplacedWithAGeneratedId(String blank) throws Exception {
        assertThat(idFor(blank)).startsWith("direct-");
    }

    @Test
    void anAbsentHeaderIsReplacedWithAGeneratedId() throws Exception {
        assertThat(idFor(null)).startsWith("direct-");
    }

    /** 64 characters is the limit; one more is refused rather than truncated. */
    @Test
    void anOverlongHeaderIsRefusedRatherThanTruncated() throws Exception {
        String tooLong = "a".repeat(65);

        String id = idFor(tooLong);

        assertThat(id).startsWith("direct-").doesNotContain(tooLong);
    }

    @Test
    void exactlyTheMaximumLengthIsAccepted() throws Exception {
        String atLimit = "b".repeat(64);

        assertThat(idFor(atLimit)).isEqualTo(atLimit);
    }

    /** Each half of the allowed set, so no single class of character is accepted by accident. */
    @ParameterizedTest
    @ValueSource(strings = { "abcdef", "ABCDEF", "012345", "a-b-c", "a_b_c", "aZ9-_" })
    void anIdMadeOnlyOfAllowedCharactersIsAdopted(String clean) throws Exception {
        assertThat(idFor(clean)).isEqualTo(clean);
    }

    /**
     * The reason the whole method exists. A newline in a header that reaches every log line lets a
     * caller write fabricated entries; the others are the neighbouring characters that would slip
     * through a rule written slightly too loosely.
     */
    @ParameterizedTest
    @ValueSource(strings = { "abc\ndef", "abc\rdef", "abc def", "abc;def", "abc/def", "abc.def", "abc:def", "üst" })
    void aHeaderCarryingAnythingElseIsDiscarded(String forged) throws Exception {
        String id = idFor(forged);

        assertThat(id).startsWith("direct-");
        assertThat(id).doesNotContain("\n").doesNotContain("\r");
    }

    /**
     * Threads are pooled, so an id left behind attributes the next request's log lines to this one.
     * The class comment calls that worse than having no id: the logs are confidently wrong.
     */
    @Test
    void theIdIsRemovedFromMdcEvenWhenTheChainThrows() throws Exception {
        HttpServletRequest request = mock(HttpServletRequest.class);
        HttpServletResponse response = mock(HttpServletResponse.class);
        FilterChain chain = mock(FilterChain.class);
        when(request.getHeader(CorrelationIdFilter.HEADER)).thenReturn("abc123");

        List<String> seenInsideChain = new ArrayList<>();
        org.mockito.Mockito.doAnswer(invocation -> {
            seenInsideChain.add(MDC.get(CorrelationIdFilter.MDC_KEY));
            throw new IllegalStateException("downstream blew up");
        })
            .when(chain)
            .doFilter(request, response);

        try {
            filter.doFilterInternal(request, response, chain);
        } catch (IllegalStateException expected) {
            // the point is what happens after it, not the exception itself
        }

        assertThat(seenInsideChain).containsExactly("abc123");
        assertThat(MDC.get(CorrelationIdFilter.MDC_KEY)).as("a pooled thread must not carry the id onward").isNull();
    }
}
