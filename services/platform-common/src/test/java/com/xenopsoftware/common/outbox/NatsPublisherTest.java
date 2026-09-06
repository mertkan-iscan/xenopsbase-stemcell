package com.xenopsoftware.common.outbox;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.xenopsoftware.common.correlation.CorrelationId;
import io.nats.client.Connection;
import io.nats.client.JetStream;
import io.nats.client.Message;
import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.test.util.ReflectionTestUtils;

/**
 * What actually goes on the wire, and what refuses to (T-9.6, T-9.9, ADR-0018).
 *
 * <p>Asserted rather than assumed because none of it fails loudly. A wrong subject publishes to a
 * topic nobody is subscribed to; a missing correlation header breaks the causal chain at the broker
 * and shows up weeks later as two halves of a request that cannot be joined; and a publish through a
 * connection that is not up returns normally, which is how the relay came to mark rows published
 * that the broker never kept.
 */
class NatsPublisherTest {

    private JetStream jetStream;

    private static OutboxMessage message() {
        OutboxMessage message = new OutboxMessage();
        // The id is database-generated and has no setter, which is right for the entity and
        // inconvenient here. Set through reflection rather than widening the production API for
        // a test: the id is exactly what Nats-Msg-Id carries, so a test that left it null would
        // assert the de-duplication key is the string "null".
        ReflectionTestUtils.setField(message, "id", 42L);
        message.setMessageType("platform.probe.initiated");
        message.setAggregateType("PlatformProbe");
        message.setAggregateId("7");
        message.setPayload("{\"label\":\"x\"}");
        message.setCorrelationId("abc123");
        return message;
    }

    /** A connection that is up, with a JetStream context this test can look inside. */
    private Connection connected() {
        Connection connection = mock(Connection.class);
        jetStream = mock(JetStream.class);
        when(connection.getStatus()).thenReturn(Connection.Status.CONNECTED);
        try {
            when(connection.jetStream()).thenReturn(jetStream);
        } catch (Exception impossible) {
            throw new AssertionError(impossible);
        }
        return connection;
    }

    private Message published() {
        ArgumentCaptor<Message> sent = ArgumentCaptor.forClass(Message.class);
        try {
            verify(jetStream).publish(sent.capture());
        } catch (Exception impossible) {
            throw new AssertionError(impossible);
        }
        return sent.getValue();
    }

    @Test
    @DisplayName("the subject is the message type, verbatim")
    void theSubjectIsTheMessageType() {
        new NatsPublisher(connected(), "").publish(message());

        // A mapping table between message types and subjects would be a second place for the two to
        // disagree. The types this template writes are already dot-separated.
        assertThat(published().getSubject()).isEqualTo("platform.probe.initiated");
    }

    @Test
    @DisplayName("a prefix is what keeps two products on one broker apart")
    void aPrefixNamespacesTheSubject() {
        new NatsPublisher(connected(), "stemcell").publish(message());

        // Without this, this template and xenopsbase-learn both publish
        // `platform.probe.initiated` to the same subject and each receives the other messages.
        // The prefix also picks the stream -- see StreamsTest.
        assertThat(published().getSubject()).isEqualTo("stemcell.platform.probe.initiated");
    }

    @Test
    @DisplayName("the payload crosses unwrapped, and the metadata rides in headers")
    void thePayloadIsNotWrapped() {
        new NatsPublisher(connected(), "").publish(message());
        Message sent = published();

        // Unwrapped, so a consumer deserialises the produced JSON directly. An envelope would make
        // every consumer unwrap before it could read anything, including consumers that never look
        // at the metadata.
        assertThat(new String(sent.getData(), StandardCharsets.UTF_8)).isEqualTo("{\"label\":\"x\"}");

        assertThat(sent.getHeaders().getFirst("X-Aggregate-Type")).isEqualTo("PlatformProbe");
        assertThat(sent.getHeaders().getFirst("X-Aggregate-Id")).isEqualTo("7");
        // The id crosses the broker, so a consumer log line can be joined back to the request that
        // caused the event. Without it the causal chain stops at the publish.
        assertThat(sent.getHeaders().getFirst(CorrelationId.HEADER)).isEqualTo("abc123");
    }

    @Test
    @DisplayName("Nats-Msg-Id carries the outbox row id, so the stream can drop the common duplicate")
    void theOutboxIdIsTheDeduplicationKey() {
        new NatsPublisher(connected(), "").publish(message());

        // The header NATS itself reads. Paired with the stream duplicateWindow it makes the frequent
        // duplicate -- a relay that published and died before marking the row -- free. It is an
        // optimisation, not the guarantee: the window is finite and consumers must still be
        // idempotent.
        assertThat(published().getHeaders().getFirst("Nats-Msg-Id")).isEqualTo("42");
    }

    @Test
    @DisplayName("a message with no correlation id publishes anyway, without a null header")
    void anAbsentCorrelationIdIsOmitted() {
        OutboxMessage message = message();
        message.setCorrelationId(null);

        new NatsPublisher(connected(), "").publish(message);

        // A message recorded outside a request -- a reconciliation, a startup task -- has no
        // correlation id, and adding a null-valued header would throw rather than degrade.
        assertThat(published().getHeaders().containsKey(CorrelationId.HEADER)).isFalse();
    }

    @Test
    @DisplayName("a disconnected broker THROWS rather than publishing into a buffer nobody drains")
    void aDisconnectedPublishIsRefused() {
        // THE ASSERTION THIS CLASS EXISTS FOR NOW.
        //
        // connection.publish buffers on a connection that is not up and returns normally, so
        // OutboxRelay marked the row published and the message never left. The contract on
        // MessagePublisher is that publish throws when it cannot deliver; this enforces it rather
        // than trusting the client to.
        Connection connection = mock(Connection.class);
        when(connection.getStatus()).thenReturn(Connection.Status.DISCONNECTED);

        assertThatThrownBy(() -> new NatsPublisher(connection, "").publish(message()))
            .isInstanceOf(IllegalStateException.class)
            .hasMessageContaining("DISCONNECTED")
            // Naming the row is what makes the log line actionable rather than a count.
            .hasMessageContaining("42");
    }

    @Test
    @DisplayName("a broker that refuses the publish throws, so the relay retries instead of marking it done")
    void aRefusedPublishThrows() throws Exception {
        Connection connection = connected();
        when(jetStream.publish(any(Message.class))).thenThrow(new java.io.IOException("no stream matches subject"));

        // The case a missing stream produces. Before the acknowledged publish it was not observable
        // at all: the message was dropped by the server and the client never knew.
        assertThatThrownBy(() -> new NatsPublisher(connection, "").publish(message()))
            .isInstanceOf(IllegalStateException.class)
            .hasMessageContaining("platform.probe.initiated")
            .hasRootCauseMessage("no stream matches subject");
    }

    @Test
    @DisplayName("nothing is published when the connection is down, not even optimistically")
    void nothingIsSentWhenDisconnected() {
        Connection connection = mock(Connection.class);
        when(connection.getStatus()).thenReturn(Connection.Status.CLOSED);

        assertThatThrownBy(() -> new NatsPublisher(connection, "").publish(message())).isInstanceOf(IllegalStateException.class);

        // Belt to the braces of the throw: a version that threw AFTER publishing would pass the
        // test above and still double-send on the retry.
        verify(connection, never()).publish(any(Message.class));
    }
}
