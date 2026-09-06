package com.xenopsoftware.common.outbox;

import io.nats.client.JetStreamManagement;
import io.nats.client.api.RetentionPolicy;
import io.nats.client.api.StorageType;
import io.nats.client.api.StreamConfiguration;
import java.time.Duration;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * The stream this application publishes into, declared here rather than made by hand (T-9.9).
 *
 * <h2>Publishing without a stream stores nothing, and reports success</h2>
 *
 * ADR-0018 was written as though a stream existed. One did not. NATS core is fire-and-forget: a
 * publish to a subject no stream is bound to is not an error, it is a message nobody kept. Measured
 * on the dev cluster the day the broker went in — {@code in_msgs: 2}, JetStream storage {@code 0},
 * zero streams — while {@code outbox_message.published_at} was set on both rows, so the outbox
 * believed it had delivered.
 *
 * <p>That is the exact defect T-9.6 existed to end, one layer further out: a mechanism reporting
 * success while delivering nothing. It also made two of the ADR's claims false. "A cluster rebuild
 * recreates the streams empty; the relay then republishes everything it has not marked published"
 * only holds for messages the relay has NOT marked, and every dropped message was marked. And "a
 * fork that adds a consumer gets messages rather than log lines" held only for messages published
 * while that consumer happened to be connected.
 *
 * <p>This is xenopsbase-learn's {@code Streams}, which solved the problem first and states the rule
 * plainly: a stream somebody made with a CLI on a laptop exists in exactly one environment, and the
 * first anybody knows is a consumer somewhere else receiving nothing.
 *
 * <h2>ONE STREAM, AND ITS SUBJECTS ARE NOT `&gt;`</h2>
 *
 * The obvious topology — one stream over everything — is wrong here, and not subtly. This broker is
 * shared: the same NATS serves this repository from {@code apps} and xenopsbase-learn from
 * {@code learn}, whose streams are {@code identity.&gt;}, {@code catalog.&gt;},
 * {@code streaming.&gt;} and {@code reporting.&gt;}. JetStream refuses to create a stream whose
 * subjects overlap another's, so a stream on {@code &gt;} here would either fail at startup or, if
 * it won the race, capture every message the other product publishes.
 *
 * <p>So the subject space is rooted, and the root is
 * {@code platform.outbox.subject-prefix} when it is set and {@code platform} when it is not — which
 * is what {@link NatsPublisher} already prepends. That makes the prefix load-bearing rather than
 * decorative: a second fork on this broker sets one and gets its own namespace, and the failure if
 * it does not is a refused stream at startup rather than two products quietly reading each other's
 * events.
 */
public final class Streams {

    private static final Logger LOG = LoggerFactory.getLogger(Streams.class);

    private Streams() {}

    /**
     * The subject root for a given configured prefix.
     *
     * <p>{@code platform} is the default because it is what this template's message types already
     * begin with — {@code platform.probe.initiated} — so an unconfigured fork gets a stream that
     * actually covers what it publishes rather than an empty one.
     */
    static String rootOf(String subjectPrefix) {
        return subjectPrefix == null || subjectPrefix.isBlank() ? "platform" : subjectPrefix.trim();
    }

    /**
     * Makes the broker match this file: creates what is missing, updates what has drifted, and is
     * therefore safe to run on every connect and every reconnect.
     *
     * @param management the JetStream management interface for the connection
     * @param subjectPrefix {@code platform.outbox.subject-prefix}, blank when unset
     */
    public static void apply(JetStreamManagement management, String subjectPrefix) throws Exception {
        StreamConfiguration wanted = streamFor(rootOf(subjectPrefix));
        if (management.getStreamNames().contains(wanted.getName())) {
            management.updateStream(wanted);
        } else {
            management.addStream(wanted);
        }
        LOG.info("Bus topology applied: stream {} over {}", wanted.getName(), wanted.getSubjects());
    }

    static StreamConfiguration streamFor(String root) {
        // A stream NAME may not contain a dot, and a prefix may. Replaced rather than rejected: the
        // prefix is a subject namespace and a fork should not have to know this rule to pick one.
        String name = root.replace('.', '_');
        return StreamConfiguration.builder()
            .name(name)
            .subjects(root + ".>")
            // FILE, not memory. The outbox is the record and the broker is transport -- but
            // transport that forgets on every restart turns every deploy into a replay storm.
            .storageType(StorageType.File)
            // LIMITS rather than WorkQueue: more than one consumer may care about the same event,
            // and a work queue hands it to exactly one of them. Which consumer has read what is the
            // consumer's business, not the stream's.
            .retentionPolicy(RetentionPolicy.Limits)
            // A week. Long enough for a consumer to be down for a weekend and catch up; short
            // enough that the broker does not become a second database. Anything older is
            // re-derivable from the outbox, which is the actual record.
            .maxAge(Duration.ofDays(7))
            // Bounded by the PVC rather than by hope. The volume is 1Gi and nats.yaml already caps
            // the store below it; this caps the stream below THAT, so a runaway publisher fills a
            // stream and gets an error naming it rather than filling the disk and taking the broker
            // down for the other product sharing it.
            .maxBytes(512L * 1024 * 1024)
            // Duplicate suppression keyed on the message id the outbox generated, over a window a
            // relay retry could plausibly span. Belt to the consumer's braces: the outbox is
            // at-least-once by design, so this makes the COMMON duplicate free and consumers still
            // have to be idempotent, because a window is not a guarantee.
            .duplicateWindow(Duration.ofMinutes(10))
            .build();
    }
}
