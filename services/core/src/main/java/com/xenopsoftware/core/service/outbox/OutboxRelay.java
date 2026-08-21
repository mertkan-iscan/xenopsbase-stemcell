package com.xenopsoftware.core.service.outbox;

import com.xenopsoftware.core.domain.OutboxMessage;
import com.xenopsoftware.core.repository.OutboxMessageRepository;
import java.time.Instant;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.data.domain.Limit;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Moves recorded messages out to a publisher (T-3.10).
 *
 * <h2>Not scheduled here</h2>
 *
 * There is no {@code @Scheduled} on {@link #relayBatch()}, for the same reason the document reaper
 * has none: a schedule baked into a template runs on every replica simultaneously. What drives this
 * is a deployment decision — a CronJob, a {@code ShedLock}-guarded task, or a listener on the
 * database's own change stream. The method is the unit of work; the trigger is not this file's
 * business.
 *
 * <p>A fork that just wants it running adds {@code @Scheduled(fixedDelay = 1000)} and accepts that
 * every replica polls, which the row locking below makes safe if wasteful.
 */
@Service
public class OutboxRelay {

    private static final Logger LOG = LoggerFactory.getLogger(OutboxRelay.class);

    /** Bounded so one pass cannot hold a transaction open across an unbounded number of rows. */
    private static final int BATCH_SIZE = 100;

    private final OutboxMessageRepository repository;
    private final MessagePublisher publisher;

    /**
     * Resolves the publisher through an {@link ObjectProvider} rather than injecting it directly,
     * so the default needs no {@code @ConditionalOnMissingBean} — see
     * {@link LoggingMessagePublisher} for why that annotation is the wrong tool here.
     *
     * <p>Resolved once at construction. Doing it per call would let the destination change under a
     * running relay, which is a surprise nobody needs while debugging delivery.
     */
    public OutboxRelay(OutboxMessageRepository repository, ObjectProvider<MessagePublisher> publisher) {
        this.repository = repository;
        this.publisher = publisher.getIfAvailable(LoggingMessagePublisher::new);
    }

    /**
     * Publishes one batch and returns how many were sent.
     *
     * <p>Transactional so the claim, the publish and the mark happen under one lock. A publisher
     * that throws leaves the row unpublished and the error recorded, and the message is retried on
     * the next pass — which is why a publisher must tolerate seeing the same message twice.
     *
     * <p>A failure in one message does not abandon the batch. Otherwise a single permanently
     * unpublishable message blocks every message behind it, forever, and the queue stops moving
     * for a reason that looks like the relay being broken.
     */
    @Transactional
    public int relayBatch() {
        List<OutboxMessage> batch = repository.claimUnpublished(Limit.of(BATCH_SIZE));
        int published = 0;

        for (OutboxMessage message : batch) {
            try {
                publisher.publish(message);
                message.setPublishedAt(Instant.now());
                message.setLastError(null);
                published++;
            } catch (RuntimeException e) {
                message.setAttempts(message.getAttempts() + 1);
                // Truncated: a driver exception can carry a very large message, and an unbounded
                // error column turns a broken downstream into a storage problem as well.
                message.setLastError(abbreviate(e.toString()));
                LOG.warn("Outbox message {} failed to publish (attempt {})", message.getId(), message.getAttempts(), e);
            }
        }

        if (published > 0) {
            LOG.debug("Relayed {} of {} outbox messages", published, batch.size());
        }
        return published;
    }

    private static String abbreviate(String value) {
        return value.length() <= 2000 ? value : value.substring(0, 2000) + "...";
    }
}
