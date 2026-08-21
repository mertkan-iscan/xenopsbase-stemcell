package com.xenopsoftware.core.service.outbox;

import com.xenopsoftware.core.domain.OutboxMessage;

/**
 * Where an outbox message goes once it is ready to leave (T-3.10).
 *
 * <p>Deliberately one method and no broker concepts. There is no message broker in this stack yet,
 * and an interface shaped around one that has not been chosen would encode assumptions —
 * partitions, acks, headers — that the eventual choice may not share.
 *
 * <p>Implementations must be safe to call twice with the same message. The relay can publish and
 * then fail before recording that it did, so delivery is at-least-once. That is a property of the
 * pattern, not a gap in this implementation: making it exactly-once requires the broker and the
 * database to share a transaction, which they cannot.
 */
public interface MessagePublisher {
    /**
     * @throws RuntimeException to signal the message was not published; the relay records the
     *                          failure and leaves the row unpublished for a later attempt
     */
    void publish(OutboxMessage message);
}
