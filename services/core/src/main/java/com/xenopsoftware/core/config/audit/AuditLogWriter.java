package com.xenopsoftware.core.config.audit;

import com.xenopsoftware.core.security.SecurityUtils;
import java.sql.Timestamp;
import java.time.Instant;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Writes one audit row per change, on the transaction's own connection (T-3.10).
 *
 * <h2>Written immediately, not buffered until commit</h2>
 *
 * The first version of this class collected entries and flushed them from a
 * {@code TransactionSynchronization} at {@code beforeCommit}. That does not work, and the way it
 * fails is instructive:
 *
 * <ul>
 *   <li>Spring runs every synchronization callback <b>before</b> the JPA transaction commits, and
 *       the commit is what triggers Hibernate's flush. So dirty-check events — updates and deletes —
 *       fire after the last callback has already run.</li>
 *   <li>Registration was lazy, on the first buffered entry. For a transaction containing only
 *       updates, the first entry arrived during that commit-time flush, so the synchronization was
 *       never registered at all and nothing was ever written.</li>
 *   <li><b>Inserts hid all of this.</b> {@code IDENTITY} generation forces an immediate INSERT
 *       during {@code save()} to obtain the key, so {@code PostInsert} fires early. Creates were
 *       audited correctly while updates and deletes were silently lost — an audit log that looks
 *       populated and is missing exactly the events people consult it for.</li>
 * </ul>
 *
 * <p>Writing straight through is simpler and has none of that. {@link JdbcTemplate} resolves the
 * connection already bound to the current transaction, so the audit row and the change it describes
 * commit or roll back together — which is the guarantee that matters. And because this is plain
 * JDBC it never touches the persistence context, so it is safe to call from inside a flush, which
 * is the reason buffering seemed necessary in the first place.
 */
@Component
public class AuditLogWriter {

    private static final String INSERT =
        "insert into audit_log (entity_type, entity_id, action, actor, actor_name, occurred_at, payload) " +
        "values (?, ?, ?, ?, ?, ?, ?::jsonb)";

    private final JdbcTemplate jdbcTemplate;

    public AuditLogWriter(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    /** What one change looks like. {@code payload} is null for deletes. */
    public record AuditEntry(String entityType, String entityId, String action, String payload) {}

    /**
     * Ignored outside a transaction, deliberately.
     *
     * <p>Not a swallowed error: with no transaction there is nothing for the row to be atomic with,
     * and writing it anyway would record a change that may never commit. It also matters
     * practically — the datasource runs with auto-commit off, so a write outside a transaction is
     * discarded on connection release without raising anything.
     */
    public void record(AuditEntry entry) {
        if (!TransactionSynchronizationManager.isActualTransactionActive()) {
            return;
        }

        jdbcTemplate.update(
            INSERT,
            entry.entityType(),
            entry.entityId(),
            entry.action(),
            // The immutable identifier, so attribution survives a username change.
            SecurityUtils.getCurrentUserId().orElse("system"),
            // A point-in-time snapshot of the display name, correct precisely because it makes no
            // claim to still be current.
            SecurityUtils.getCurrentUserLogin().orElse(null),
            Timestamp.from(Instant.now()),
            entry.payload()
        );
    }
}
