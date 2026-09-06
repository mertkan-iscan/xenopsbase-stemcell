package com.xenopsoftware.common.outbox;

import javax.sql.DataSource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;

/**
 * What finally drives {@link OutboxRelay#relayBatch()} (T-9.6, ADR-0018).
 *
 * <h2>Nothing called it until now, which made the whole outbox inert</h2>
 *
 * {@code OutboxRelay} has existed since T-3.10 with a comment explaining that the trigger is "not
 * this file's business" — a deployment decision between a CronJob, a ShedLock-guarded task, or a
 * change-stream listener. That was a reasonable thing to say and it left the mechanism doing
 * nothing: messages were written into {@code outbox_message} and never read out, in every
 * environment, since the day the table was created.
 *
 * <h2>An advisory lock, not a schedule on every replica</h2>
 *
 * {@code extension-seams.md} already stated why a bare {@code @Scheduled} in a template is wrong: it
 * runs on every replica at once. The row-level {@code SKIP LOCKED} in
 * {@link OutboxMessageRepository#claimUnpublished} makes that SAFE — two replicas draining
 * concurrently take different rows — but it is still N times the database work to do one drain, and
 * it scales the wrong way with replica count.
 *
 * <p>So one advisory lock, taken and released around each pass.
 *
 * <h2>Why an advisory lock and not ShedLock</h2>
 *
 * <ul>
 *   <li><b>No table, no migration, no dependency.</b> {@code pg_try_advisory_lock} is one round trip
 *       against a database every replica already holds a connection to.</li>
 *   <li><b>It cannot go stale.</b> A session-scoped advisory lock is released by Postgres when the
 *       session ends — including when the pod is killed, the node is drained, or the JVM dies. A
 *       lock TABLE gets that case wrong: the row survives the holder and blocks every replica until
 *       somebody notices and deletes it, which is precisely the failure mode of a lock designed to
 *       prevent a stall.</li>
 *   <li><b>It is what the shape being copied already does.</b> xenopsbase-learn's relay solves this
 *       exact problem this exact way.</li>
 * </ul>
 *
 * <p>The cost is that the lock is held by a CONNECTION, so it must be taken and released on the same
 * one — see the {@code execute} below, which does both inside a single callback rather than through
 * two {@code JdbcTemplate} calls that would each borrow a different connection from the pool. That is
 * the one way to get this wrong, and it fails silently: the try succeeds, the unlock runs on a
 * connection that does not hold the lock, Postgres logs a warning nobody reads, and the lock is held
 * until that connection is recycled.
 */
public class OutboxRelayScheduler {

    private static final Logger LOG = LoggerFactory.getLogger(OutboxRelayScheduler.class);

    /**
     * The advisory lock's identity. Any {@code bigint} works and Postgres attaches no meaning to it;
     * what matters is that nothing else in this database picks the same number for something else.
     *
     * <p>Derived from the string {@code xenopsbase.outbox.relay} rather than typed as a magic
     * constant, so a fork that renames the project gets a different lock without having to know that
     * this number exists.
     */
    private static final long LOCK_KEY = "xenopsbase.outbox.relay".hashCode();

    private final OutboxRelay relay;
    private final JdbcTemplate jdbcTemplate;

    public OutboxRelayScheduler(OutboxRelay relay, DataSource dataSource) {
        this.relay = relay;
        this.jdbcTemplate = new JdbcTemplate(dataSource);
    }

    /**
     * {@code fixedDelay}, not {@code fixedRate}. A rate schedules the next run from the start of the
     * previous one, so a drain that takes longer than the interval queues the next immediately and
     * a slow broker turns into overlapping passes. A delay measures from the END, so the relay can
     * never race itself.
     *
     * <p>Two seconds because the outbox is a background path, not a request path: a message is
     * already committed and the caller has already been answered. Anything faster spends database
     * round trips discovering there is nothing to do; anything much slower makes the tail latency of
     * an event visible to whoever is waiting for it.
     *
     * <p>{@code initialDelay} lets the application finish starting. A relay that begins draining
     * during context refresh competes with Flyway and with connection-pool warmup for the same
     * connections.
     */
    @Scheduled(
        fixedDelayString = "${platform.outbox.relay.delay:PT2S}",
        initialDelayString = "${platform.outbox.relay.initial-delay:PT10S}"
    )
    public void drain() {
        jdbcTemplate.execute((java.sql.Connection connection) -> {
            // ONE CONNECTION FOR BOTH, and this callback is the reason. pg_advisory_lock is
            // session-scoped, so taking it on one pooled connection and releasing it on another
            // leaves it held until the first is recycled -- and the unlock reports a warning
            // rather than an error, so nothing fails.
            boolean acquired;
            try (var statement = connection.prepareStatement("select pg_try_advisory_lock(?)")) {
                statement.setLong(1, LOCK_KEY);
                try (var rs = statement.executeQuery()) {
                    acquired = rs.next() && rs.getBoolean(1);
                }
            }

            if (!acquired) {
                // Another replica is draining. Not a warning: this is the mechanism working, and
                // logging it at anything above trace would produce one line per replica per two
                // seconds, for ever.
                LOG.trace("Another replica holds the outbox relay lock; skipping this pass");
                return null;
            }

            try {
                int published = relay.relayBatch();
                if (published > 0) {
                    LOG.debug("Outbox relay published {} messages", published);
                }
            } finally {
                // Released explicitly rather than left to session end, because the session here is
                // a pooled connection that may live for hours. Postgres would release it eventually
                // -- on connection close -- which is exactly long enough to look like a stuck relay.
                try (var statement = connection.prepareStatement("select pg_advisory_unlock(?)")) {
                    statement.setLong(1, LOCK_KEY);
                    statement.execute();
                }
            }
            return null;
        });
    }
}
