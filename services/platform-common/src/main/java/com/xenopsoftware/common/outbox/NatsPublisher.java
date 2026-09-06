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
 * <h2>Publish, not publish-and-confirm, and that is deliberate</h2>
 *
 * This uses core NATS publish rather than a JetStream acknowledged publish. It looks like the weaker
 * choice and is the correct one here, because of where this sits: {@link OutboxRelay} calls this
 * inside a transaction that has already claimed the row with {@code SKIP LOCKED}, and only marks it
 * published if this returns normally. A throw leaves the row unpublished and it is retried on the
 * next pass.
 *
 * <p>So the durability question is already answered by Postgres, and adding a broker-side ack would
 * buy a second, weaker guarantee at the cost of holding a database transaction open across a network
 * round trip per message — which is the thing most likely to turn a slow broker into database lock
 * contention.
 *
 * <p>What that leaves is genuinely at-least-once: a message can be published and then fail to be
 * marked, and it is published again. {@link MessagePublisher}'s contract has always said so, and
 * ADR-0018 makes it a stated obligation on consumers rather than a footnote.
 */
public class NatsPublisher implements MessagePublisher {

    private static final Logger LOG = LoggerFactory.getLogger(NatsPublisher.class);

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
        if (message.getCorrelationId() != null) {
            // The id crosses the broker too, so a consumer's log line can be joined to the request
            // that caused the event. Without it the causal chain stops at the publish.
            headers.add(com.xenopsoftware.common.correlation.CorrelationId.HEADER, message.getCorrelationId());
        }

        connection.publish(subject, headers, message.getPayload().getBytes(StandardCharsets.UTF_8));
        LOG.debug("Published outbox message {} to {}", message.getId(), subject);
    }
}
