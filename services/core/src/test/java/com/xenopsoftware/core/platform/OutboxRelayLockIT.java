package com.xenopsoftware.core.platform;

import static org.assertj.core.api.Assertions.assertThat;

import com.xenopsoftware.common.outbox.MessagePublisher;
import com.xenopsoftware.common.outbox.OutboxMessage;
import com.xenopsoftware.common.outbox.OutboxMessageRepository;
import com.xenopsoftware.common.outbox.OutboxRelay;
import com.xenopsoftware.common.outbox.OutboxRelayScheduler;
import com.xenopsoftware.common.outbox.OutboxService;
import com.xenopsoftware.core.IntegrationTest;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import javax.sql.DataSource;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Two replicas, one drain (T-9.6, ADR-0018).
 *
 * <h2>Why this is asserted rather than reasoned about</h2>
 *
 * Double publication looks like <em>nothing at all</em> from the publisher's side. Both replicas
 * succeed, both mark their rows published, both log a normal line, and the only evidence is on the
 * consumer — which in this template does not exist yet, so there would be nobody to notice for as
 * long as it took a fork to add one.
 *
 * <p>The row-level {@code SKIP LOCKED} in {@code claimUnpublished} already makes concurrent draining
 * SAFE, so this is not a correctness test of the outbox. It is a test of the advisory lock: that the
 * second replica declines the pass entirely rather than doing N times the database work to publish
 * the same total.
 *
 * <p>Two schedulers over one real Postgres is as close to two replicas as a single JVM gets, and it
 * is close enough for the property being tested — the lock lives in the database, not in the process.
 */
@IntegrationTest
@WithMockUser(username = "relay-test")
// Imported explicitly rather than relying on nested-@TestConfiguration detection, which does not
// fire when the composed @SpringBootTest names its `classes` -- the context then had no
// MessagePublisher bean at all and every test failed on the injection rather than on the assertion.
@Import(OutboxRelayLockIT.RecordingPublisherConfiguration.class)
class OutboxRelayLockIT {

    /**
     * Supplied as a BEAN rather than injected into a hand-built relay, and the first version of this
     * test got that wrong in a way worth recording.
     *
     * <p>It constructed {@code new OutboxRelay(repository, provider)} to inject a recording
     * publisher — which produces a plain object, not a Spring proxy, so {@code @Transactional} on
     * {@code relayBatch} did nothing and the pessimistic lock in {@code claimUnpublished} failed
     * with "No active transaction". A test that builds its own copy of the thing under test is
     * testing a different object, and here the difference was the transaction the whole mechanism
     * rests on.
     *
     * <p>{@link OutboxRelay} resolves its publisher through an {@code ObjectProvider}, so declaring
     * one here is enough: the container's own relay picks it up, and this test drives the real bean.
     */
    @TestConfiguration
    static class RecordingPublisherConfiguration {

        @Bean
        MessagePublisher recordingPublisher() {
            return new RecordingPublisher();
        }
    }

    @Autowired
    private DataSource dataSource;

    @Autowired
    private OutboxRelay relay;

    @Autowired
    private MessagePublisher publisher;

    @Autowired
    private OutboxMessageRepository outboxRepository;

    @Autowired
    private OutboxService outboxService;

    @Autowired
    private TransactionTemplate transactionTemplate;

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @BeforeEach
    void clean() {
        published().clear();
        // Inside a transaction: the datasource runs with hikari.auto-commit false, so a
        // JdbcTemplate write with no surrounding transaction executes, reports rows affected, and
        // is discarded.
        transactionTemplate.executeWithoutResult(status -> jdbcTemplate.update("delete from outbox_message"));
    }

    /** Records what it was asked to publish, so the test can count rather than infer. */
    static final class RecordingPublisher implements MessagePublisher {

        private final List<Long> published = new CopyOnWriteArrayList<>();

        @Override
        public void publish(OutboxMessage message) {
            published.add(message.getId());
        }
    }

    private List<Long> published() {
        return ((RecordingPublisher) publisher).published;
    }

    /**
     * A second scheduler over the SAME relay bean and the same DataSource — which is what two
     * replicas are, as far as an advisory lock is concerned. The lock lives in Postgres, not in the
     * process, so one JVM is enough to test it.
     */
    private OutboxRelayScheduler anotherReplica() {
        return new OutboxRelayScheduler(relay, dataSource);
    }

    @Test
    @DisplayName("a second replica draining at the same time publishes nothing, rather than publishing again")
    void onlyOneReplicaDrainsAPass() throws Exception {
        transactionTemplate.executeWithoutResult(status -> {
            for (int i = 0; i < 5; i++) {
                outboxService.record("relay.test", "PlatformProbe", String.valueOf(i), Map.of("n", i));
            }
        });
        assertThat(outboxRepository.count()).isEqualTo(5);

        // Sequential, and that is enough for the property being tested: the lock is held for the
        // DURATION of a pass, so a second pass starting after the first finished should acquire it
        // and find nothing left -- which also proves the lock was released.
        anotherReplica().drain();
        int afterFirst = published().size();
        anotherReplica().drain();

        assertThat(afterFirst).as("the first pass drains everything").isEqualTo(5);
        assertThat(published()).as("the second publishes nothing new, rather than the same five again").hasSize(5);
    }

    @Test
    @DisplayName("the lock is released after a pass, so the relay does not stall itself")
    void theLockIsReleasedBetweenPasses() {
        OutboxRelayScheduler scheduler = anotherReplica();

        // An empty first pass still takes and releases the lock. If it leaked, the second pass would
        // find it held and publish nothing -- which is the failure mode of releasing on a different
        // pooled connection than the one that acquired it, and it is silent: Postgres logs a
        // warning about unlocking something not held, and the relay simply stops draining.
        scheduler.drain();

        transactionTemplate.executeWithoutResult(status ->
            outboxService.record("relay.test", "PlatformProbe", "after", Map.of("second", true))
        );

        scheduler.drain();

        assertThat(published()).as("the second pass acquired the lock, so it drained").hasSize(1);
    }

    @Test
    @DisplayName("a drained message is marked published, so the next pass does not send it again")
    void drainedMessagesAreMarkedPublished() {
        transactionTemplate.executeWithoutResult(status -> outboxService.record("relay.test", "PlatformProbe", "1", Map.of()));

        anotherReplica().drain();

        Long unpublished = jdbcTemplate.queryForObject("select count(*) from outbox_message where published_at is null", Long.class);
        assertThat(unpublished).as("published_at is what stops a rebuild republishing everything for ever").isZero();
    }
}
