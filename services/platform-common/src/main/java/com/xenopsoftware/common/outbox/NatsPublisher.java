package com.xenopsoftware.common.outbox;

import io.nats.client.Connection;
import java.nio.charset.StandardCharsets;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Publishes outbox messages to NATS (T-9.6, ADR-0018).
 *
 * <h2>The subject is derived, not configured</h2>
 *
 * {@code messageType} becomes the subject verbatim — {@code platform.probe.initiated} publishes to
 * {@code platform.probe.initiated}. NATS subjects are dot-separated by convention and the message
 * types this template writes already are, so a mapping table would be a second place for the two to
 * disagree.
 *
 * <p>A prefix is configurable for the case that matters: two products sharing one broker. Without
 * it, xenopsbase-learn and this template would publish {@code platform.probe.initiated} to the same
 * subject and each would receive the other's messages.
 *
 * <h2>Publish-and-confirm, REVERSING what this file used to argue (T-9.9)</h2>
 *
 * It said core NATS publish was "the weaker choice and the correct one here", because
 * {@link OutboxRelay} only marks a row published if this returns normally, so "the durability
 * question is already answered by Postgres".
 *
 * <p>The reasoning was sound and the premise was false. It assumed publish fails loudly when it
 * cannot deliver. It does not: {@code connection.publish} is fire-and-forget, it buffers on a
 * connection that is not up, and a subject with no stream bound to it is not an error to NATS — it
 * is a message nobody kept. So "returns normally" did not mean delivered, and the relay recorded
 * delivery either way.
 *
 * <p>Measured on the dev cluster the day the broker went in: {@code in_msgs 2}, JetStream storage
 * {@code 0}, no streams, and {@code published_at} set on both outbox rows. A mechanism reporting
 * success while delivering nothing — which is the thing T-9.6 existed to end.
 *
 * <p>{@code jetStream().publish} blocks until the server confirms it STORED the message, so a
 * missing stream, a full stream or a broker that went away all become an exception the relay
 * retries. The cost is a network round trip on a background path whose caller has already been
 * answered, which is the right place to spend one. {@link Streams} declares the stream that makes
 * the confirmation possible.
 *
 * <p>What this still leaves is at-least-once: a message can be stored and the relay die before
 * marking the row, and it is published again. {@code Nats-Msg-Id} plus the stream's duplicate
 * window makes that common case free, and it is an optimisation rather than the guarantee — the
 * window is finite. {@link MessagePublisher}'s contract has always said implementations must be
 * safe to call twice, and ADR-0018 makes idempotent consumption a stated obligation.
 */
public class NatsPublisher implements MessagePublisher {

    private static final Logger LOG = LoggerFactory.getLogger(NatsPublisher.class);

    /** Standard JetStream header. Named by NATS, not by us. */
    private static final String MESSAGE_ID = "Nats-Msg-Id";

    private final Connection connection;
    private final String subjectPrefix;

    public NatsPublisher(Connection connection, String subjectPrefix) {
        this.connection = connection;
        this.subjectPrefix = subjectPrefix == null || subjectPrefix.isBlank() ? "" : subjectPrefix + ".";
    }

    @Override
    public void publish(OutboxMessage message) {
        String subject = subjectPrefix + message.getMessageType();

        // Headers rather than a wrapper envelope around the payload. The payload is whatever the
        // producer serialised and a consumer deserialises it directly; wrapping it would make every
        // consumer unwrap before it could read anything, including consumers that never look at the
        // metadata.
        io.nats.client.impl.Headers headers = new io.nats.client.impl.Headers();
        headers.add("X-Aggregate-Type", message.getAggregateType());
        headers.add("X-Aggregate-Id", message.getAggregateId());
        headers.add("X-Outbox-Id", String.valueOf(message.getId()));
        // The standard JetStream de-duplication header, named by NATS rather than by us. The
        // stream's duplicateWindow drops a re-publish of the same id for free, which covers the
        // common duplicate: a relay that published and died before marking the row. It is an
        // optimisation and NOT the guarantee -- the window is finite, the outbox is at-least-once
        // by design, and consumers still have to be idempotent.
        headers.add(MESSAGE_ID, String.valueOf(message.getId()));
        if (message.getCorrelationId() != null) {
            // The id crosses the broker too, so a consumer's log line can be joined to the request
            // that caused the event. Without it the causal chain stops at the publish.
            headers.add(com.xenopsoftware.common.correlation.CorrelationId.HEADER, message.getCorrelationId());
        }

        // THE CONNECTION IS CHECKED FIRST, and this is not belt-and-braces. Publishing through a
        // connection that is not up does NOT throw -- it buffers -- so the relay marked the row
        // published and the message never left the building. That is the exact failure the outbox
        // exists to prevent, arriving through the one path that was trusted not to produce it.
        // MessagePublisher's contract is that publish throws when it cannot deliver, so it is
        // enforced here rather than assumed of the client. Borrowed from xenopsbase-learn, which
        // found it first.
        if (connection.getStatus() != Connection.Status.CONNECTED) {
            throw new IllegalStateException(
                "Not connected to the broker (" +
                    connection.getStatus() +
                    "); leaving outbox message " +
                    message.getId() +
                    " for the next pass"
            );
        }

        try {
            // THE ACKNOWLEDGED PUBLISH, and this reverses what this file used to argue.
            //
            // It said a broker-side ack "would buy a second, weaker guarantee at the cost of holding
            // a database transaction open across a network round trip per message". The premise was
            // wrong in a way the cluster demonstrated: connection.publish is fire-and-forget, and a
            // subject with no stream bound to it is not an error to NATS -- it is a message nobody
            // kept. Measured on dev the day the broker went in: in_msgs 2, JetStream storage 0, and
            // published_at set on both rows. The relay had recorded delivery of messages that were
            // never stored.
            //
            // jetStream().publish blocks until the server confirms it STORED the message, so a
            // missing stream, a full stream or a broker that went away become an exception the relay
            // retries, rather than a row marked published. The round trip is real and it is on a
            // background path the caller has already been answered on.
            connection
                .jetStream()
                .publish(
                    io.nats.client.impl.NatsMessage.builder()
                        .subject(subject)
                        .headers(headers)
                        .data(message.getPayload().getBytes(StandardCharsets.UTF_8))
                        .build()
                );
        } catch (Exception e) {
            // Wrapped and rethrown, never swallowed: the relay retries what throws and marks what
            // does not, so a publisher that hid a failure would produce a table of lies.
            throw new IllegalStateException("Could not publish outbox message " + message.getId() + " to " + subject, e);
        }
        LOG.debug("Published outbox message {} to {}", message.getId(), subject);
    }
}
