package com.xenopsoftware.common.outbox;

import static org.assertj.core.api.Assertions.assertThat;

import io.nats.client.api.RetentionPolicy;
import io.nats.client.api.StorageType;
import io.nats.client.api.StreamConfiguration;
import java.time.Duration;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * The stream this application declares, and the one property that is not a preference (T-9.9).
 *
 * <p>Every assertion here guards something that fails without an error. A stream on the wrong
 * subjects stores nothing and the publisher is told so only because the publish is acknowledged; a
 * stream on {@code &gt;} stores everything, including another product traffic on the same broker;
 * memory storage loses the lot on a broker restart and turns a deploy into a replay storm.
 */
class StreamsTest {

    @Test
    @DisplayName("with no prefix the root is `platform`, which is what this template actually publishes")
    void theDefaultRootMatchesTheDefaultMessageTypes() {
        // The message types are `platform.probe.initiated` and friends. A default root that did not
        // match them would produce a stream that exists, reports healthy, and covers nothing.
        assertThat(Streams.rootOf("")).isEqualTo("platform");
        assertThat(Streams.rootOf(null)).isEqualTo("platform");
        assertThat(Streams.rootOf("   ")).isEqualTo("platform");
    }

    @Test
    @DisplayName("a configured prefix becomes the root, so a fork gets its own namespace")
    void aPrefixBecomesTheRoot() {
        assertThat(Streams.rootOf("acme")).isEqualTo("acme");
        assertThat(Streams.rootOf("  acme  ")).isEqualTo("acme");
    }

    @Test
    @DisplayName("THE SUBJECTS ARE ROOTED, NOT `>` — the broker is shared with xenopsbase-learn")
    void theStreamDoesNotClaimEverySubject() {
        StreamConfiguration stream = Streams.streamFor("platform");

        // THE ASSERTION THIS CLASS EXISTS FOR. The same NATS serves this repository from `apps` and
        // xenopsbase-learn from `learn`, whose streams are identity.>, catalog.>, streaming.> and
        // reporting.>. JetStream refuses overlapping subjects, so a stream on `>` here either fails
        // at startup or wins the race and captures every message the other product publishes.
        assertThat(stream.getSubjects()).containsExactly("platform.>");
        assertThat(stream.getSubjects()).doesNotContain(">");
    }

    @Test
    @DisplayName("a dotted prefix still produces a legal stream name")
    void aDottedPrefixIsSanitisedIntoTheName() {
        StreamConfiguration stream = Streams.streamFor("acme.eu");

        // A stream NAME may not contain a dot; a subject root may. A fork should not have to know
        // that rule to pick a prefix, so the name is derived and the subjects are not.
        assertThat(stream.getName()).isEqualTo("acme_eu");
        assertThat(stream.getSubjects()).containsExactly("acme.eu.>");
    }

    @Test
    @DisplayName("file storage, limits retention, and both bounds set")
    void theStreamIsDurableAndBounded() {
        StreamConfiguration stream = Streams.streamFor("platform");

        // File: memory storage forgets on restart, so every deploy would replay the outbox.
        assertThat(stream.getStorageType()).isEqualTo(StorageType.File);
        // Limits, not WorkQueue: more than one consumer may want the same event, and a work queue
        // hands it to exactly one of them.
        assertThat(stream.getRetentionPolicy()).isEqualTo(RetentionPolicy.Limits);
        // Bounded by age AND size. Age alone lets a burst fill the PVC before anything expires --
        // and the PVC is shared with the other product streams on this broker.
        assertThat(stream.getMaxAge()).isEqualTo(Duration.ofDays(7));
        assertThat(stream.getMaxBytes()).isEqualTo(512L * 1024 * 1024);
        // The window NatsPublisher Nats-Msg-Id header is useless without.
        assertThat(stream.getDuplicateWindow()).isEqualTo(Duration.ofMinutes(10));
    }
}
