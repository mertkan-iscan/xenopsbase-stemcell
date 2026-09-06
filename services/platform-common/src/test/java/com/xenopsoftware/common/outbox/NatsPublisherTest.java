package com.xenopsoftware.common.outbox;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

import com.xenopsoftware.common.correlation.CorrelationId;
import io.nats.client.Connection;
import io.nats.client.impl.Headers;
import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * What actually goes on the wire (T-9.6, ADR-0018).
 *
 * <p>Asserted rather than assumed because none of it fails loudly. A wrong subject publishes to a
 * topic nobody is subscribed to; a missing correlation header breaks the causal chain at the broker
 * and shows up weeks later as two halves of a request that cannot be joined.
 */
class NatsPublisherTest {

    private static OutboxMessage message() {
        OutboxMessage message = new OutboxMessage();
        message.setMessageType("platform.probe.initiated");
        message.setAggregateType("PlatformProbe");
        message.setAggregateId("42");
        message.setPayload("{\"label\":\"x\"}");
        message.setCorrelationId("abc123");
        return message;
    }

    @Test
    @DisplayName("the subject is the message type, verbatim")
    void theSubjectIsTheMessageType() {
        Connection connection = mock(Connection.class);
        new NatsPublisher(connection, "").publish(message());

        ArgumentCaptor<String> subject = ArgumentCaptor.forClass(String.class);
        verify(connection).publish(subject.capture(), any(Headers.class), any(byte[].class));

        // A mapping table between message types and subjects would be a second place for the two to
        // disagree. The types this template writes are already dot-separated.
        assertThat(subject.getValue()).isEqualTo("platform.probe.initiated");
    }

    @Test
    @DisplayName("a prefix is what keeps two products on one broker apart")
    void aPrefixNamespacesTheSubject() {
        Connection connection = mock(Connection.class);
        new NatsPublisher(connection, "stemcell").publish(message());

        ArgumentCaptor<String> subject = ArgumentCaptor.forClass(String.class);
        verify(connection).publish(subject.capture(), any(Headers.class), any(byte[].class));

        // Without this, this template and xenopsbase-learn both publish
        // `platform.probe.initiated` to the same subject and each receives the other's messages.
        assertThat(subject.getValue()).isEqualTo("stemcell.platform.probe.initiated");
    }

    @Test
    @DisplayName("the payload crosses unwrapped, and the metadata rides in headers")
    void thePayloadIsNotWrapped() {
        Connection connection = mock(Connection.class);
        new NatsPublisher(connection, "").publish(message());

        ArgumentCaptor<Headers> headers = ArgumentCaptor.forClass(Headers.class);
        ArgumentCaptor<byte[]> body = ArgumentCaptor.forClass(byte[].class);
        verify(connection).publish(anyString(), headers.capture(), body.capture());

        // Unwrapped, so a consumer deserialises the producer's own JSON directly. An envelope would
        // make every consumer unwrap before it could read anything, including consumers that never
        // look at the metadata.
        assertThat(new String(body.getValue(), StandardCharsets.UTF_8)).isEqualTo("{\"label\":\"x\"}");

        assertThat(headers.getValue().getFirst("X-Aggregate-Type")).isEqualTo("PlatformProbe");
        assertThat(headers.getValue().getFirst("X-Aggregate-Id")).isEqualTo("42");
        // The id crosses the broker, so a consumer's log line can be joined back to the request that
        // caused the event. Without it the causal chain stops at the publish.
        assertThat(headers.getValue().getFirst(CorrelationId.HEADER)).isEqualTo("abc123");
    }

    @Test
    @DisplayName("a message with no correlation id publishes anyway, without a null header")
    void anAbsentCorrelationIdIsOmitted() {
        Connection connection = mock(Connection.class);
        OutboxMessage message = message();
        message.setCorrelationId(null);

        new NatsPublisher(connection, "").publish(message);

        ArgumentCaptor<Headers> headers = ArgumentCaptor.forClass(Headers.class);
        verify(connection).publish(anyString(), headers.capture(), any(byte[].class));

        // A message recorded outside a request -- a reconciliation, a startup task -- has no
        // correlation id, and adding a null-valued header would throw rather than degrade.
        assertThat(headers.getValue().containsKey(CorrelationId.HEADER)).isFalse();
    }
}
