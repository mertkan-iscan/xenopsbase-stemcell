package com.xenopsoftware.gateway.web.filter;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/**
 * Tests for {@link CorrelationId#isAcceptable(String)}.
 *
 * <p>This predicate is the only thing standing between an attacker-controlled header and every log
 * line the request produces. Both ways of getting it wrong are silent: too strict and an id set by
 * Cloudflare is discarded, so correlation across the edge breaks with no error anywhere; too loose
 * and a newline in the header forges log entries, which is worse than no correlation at all because
 * the forged lines look genuine.
 *
 * <p>The character test is a hand-written chain of range comparisons, so the interesting cases are
 * the boundaries either side of each range — an off-by-one there widens the accepted set into
 * punctuation without failing any test that only uses ordinary ids.
 */
class CorrelationIdTest {

    @ParameterizedTest
    @ValueSource(strings = { "a", "z", "A", "Z", "0", "9", "-", "_", "abc123", "0f8b3d2a-4c7e-4a1b-9f2e-6d5c4b3a2e10", "az-AZ_09" })
    void acceptsIdsMadeOnlyOfUnreservedCharacters(String value) {
        assertThat(CorrelationId.isAcceptable(value)).isTrue();
    }

    /**
     * One character either side of every accepted range. These are the cases a typo in a bound lets
     * through, and each of them is printable, so nothing downstream would look wrong.
     */
    @ParameterizedTest
    @ValueSource(strings = { "`", "{", "@", "[", "/", ":", "^", "." })
    void rejectsTheCharactersJustOutsideEachAcceptedRange(String value) {
        assertThat(CorrelationId.isAcceptable(value)).isFalse();
    }

    /** The log-forging case the character rule exists for. */
    @Test
    void rejectsValuesThatWouldInjectIntoALogLine() {
        assertThat(CorrelationId.isAcceptable("id\nWARN fabricated log line")).isFalse();
        assertThat(CorrelationId.isAcceptable("id\r\nWARN fabricated log line")).isFalse();
        assertThat(CorrelationId.isAcceptable("id[31m")).isFalse();
        assertThat(CorrelationId.isAcceptable("id with spaces")).isFalse();
        assertThat(CorrelationId.isAcceptable("id;drop")).isFalse();
        assertThat(CorrelationId.isAcceptable("<script>")).isFalse();
    }

    @Test
    void rejectsNullBlankAndOverlongValues() {
        assertThat(CorrelationId.isAcceptable(null)).isFalse();
        assertThat(CorrelationId.isAcceptable("")).isFalse();
        assertThat(CorrelationId.isAcceptable("   ")).isFalse();
        assertThat(CorrelationId.isAcceptable("a".repeat(CorrelationId.MAX_LENGTH + 1))).isFalse();
    }

    /**
     * The length rule is inclusive at the limit. Pinned because the boundary is the whole point of
     * having a limit: a cap that rejected at exactly {@code MAX_LENGTH} would drop ids of the
     * documented maximum size, and a UUID plus a short prefix is already close to it.
     */
    @Test
    void acceptsAValueOfExactlyTheMaximumLength() {
        assertThat(CorrelationId.isAcceptable("a".repeat(CorrelationId.MAX_LENGTH))).isTrue();
    }
}
