package com.xenopsoftware.core.repository;

import com.xenopsoftware.core.domain.OutboxMessage;
import jakarta.persistence.LockModeType;
import java.util.List;
import org.springframework.data.domain.Limit;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.jpa.repository.QueryHints;
import org.springframework.stereotype.Repository;

@Repository
public interface OutboxMessageRepository extends JpaRepository<OutboxMessage, Long> {
    /**
     * The relay's claim query, oldest first.
     *
     * <p>{@code PESSIMISTIC_WRITE} with {@code SKIP LOCKED} is what makes more than one relay
     * instance safe. Without the lock, every replica reads the same unpublished rows and publishes
     * each message once per replica. Without {@code SKIP LOCKED}, they queue behind each other and
     * the throughput of N relays is the throughput of one.
     */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @QueryHints(@jakarta.persistence.QueryHint(name = "jakarta.persistence.lock.timeout", value = "-2"))
    @Query("select m from OutboxMessage m where m.publishedAt is null order by m.createdAt")
    List<OutboxMessage> claimUnpublished(Limit limit);
}
