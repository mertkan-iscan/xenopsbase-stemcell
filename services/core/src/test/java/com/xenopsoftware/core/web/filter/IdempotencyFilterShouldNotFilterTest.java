package com.xenopsoftware.core.web.filter;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.xenopsoftware.core.repository.IdempotencyRecordRepository;
import jakarta.servlet.http.HttpServletRequest;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/**
 * The gate in front of {@link IdempotencyFilter}, which decides whether a request is subject to
 * idempotency at all.
 *
 * <p>{@link IdempotencyFilterIT} covers what happens to a request the filter DOES handle. This
 * covers the four ways it declines to, which is the cheaper half to get wrong: a predicate that
 * says "not mine" too readily disables the feature silently, and one that says it too rarely makes
 * every GET take a database write.
 *
 * <p>Called directly rather than through a request cycle — it is a pure predicate over one header
 * and the method, and a context would add nothing but seconds.
 */
class IdempotencyFilterShouldNotFilterTest {

    private final IdempotencyFilter filter = new IdempotencyFilter(mock(IdempotencyRecordRepository.class));

    private boolean skipsRequest(String method, String key) {
        HttpServletRequest request = mock(HttpServletRequest.class);
        when(request.getMethod()).thenReturn(method);
        when(request.getHeader(IdempotencyFilter.HEADER)).thenReturn(key);
        return filter.shouldNotFilter(request);
    }

    /** No key means the caller is not asking for idempotency, so it is not imposed. */
    @Test
    void aRequestWithoutTheHeaderIsNotHandled() {
        assertThat(skipsRequest("POST", null)).isTrue();
    }

    @ParameterizedTest
    @ValueSource(strings = { "", "   " })
    void aBlankKeyIsTreatedAsAbsent(String blank) {
        assertThat(skipsRequest("POST", blank)).isTrue();
    }

    /**
     * The key is attacker-supplied and becomes a database key. Refusing an overlong one here is
     * cheaper than discovering the column width at insert time.
     */
    @Test
    void anOverlongKeyIsNotHandled() {
        assertThat(skipsRequest("POST", "k".repeat(1024))).isTrue();
    }

    /**
     * Safe methods are excluded by definition — replaying a GET is not a correctness problem, and
     * recording one would cost a write per read.
     */
    @ParameterizedTest
    @ValueSource(strings = { "GET", "HEAD", "OPTIONS" })
    void safeMethodsAreNotHandledEvenWithAKey(String method) {
        assertThat(skipsRequest(method, "abc-123")).isTrue();
    }

    /** The case the filter exists for: an unsafe method carrying a usable key. */
    @ParameterizedTest
    @ValueSource(strings = { "POST", "PUT", "PATCH", "DELETE" })
    void anUnsafeMethodWithAUsableKeyIsHandled(String method) {
        assertThat(skipsRequest(method, "abc-123")).isFalse();
    }
}
