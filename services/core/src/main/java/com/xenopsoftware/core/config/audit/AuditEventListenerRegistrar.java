package com.xenopsoftware.core.config.audit;

import com.xenopsoftware.core.domain.OutboxMessage;
import jakarta.annotation.PostConstruct;
import jakarta.persistence.EntityManagerFactory;
import java.util.Arrays;
import java.util.stream.Collectors;
import java.util.stream.IntStream;
import org.hibernate.event.service.spi.EventListenerRegistry;
import org.hibernate.event.spi.EventType;
import org.hibernate.event.spi.PostDeleteEvent;
import org.hibernate.event.spi.PostDeleteEventListener;
import org.hibernate.event.spi.PostInsertEvent;
import org.hibernate.event.spi.PostInsertEventListener;
import org.hibernate.event.spi.PostUpdateEvent;
import org.hibernate.event.spi.PostUpdateEventListener;
import org.hibernate.internal.SessionFactoryImpl;
import org.hibernate.persister.entity.EntityPersister;
import org.springframework.stereotype.Component;

/**
 * Writes an audit entry for every insert, update and delete, automatically (T-3.10).
 *
 * <h2>Why Hibernate events rather than JPA {@code @EntityListeners}</h2>
 *
 * JPA callbacks receive the entity but not what changed about it — there is no "before" state, so
 * an update produces a snapshot with no way to tell which fields moved. Hibernate's
 * {@link PostUpdateEvent} carries both {@code getState()} and {@code getOldState()}, which is the
 * difference between an audit log and a pile of copies.
 *
 * <p>They also apply to <em>every</em> entity without annotation. Anything requiring a per-entity
 * opt-in is something a new entity can silently miss, and an audit trail with a hole in it is worse
 * than no audit trail, because it is trusted.
 *
 * <h2>Registered here rather than via a Hibernate Integrator</h2>
 *
 * An {@code Integrator} is discovered through {@code ServiceLoader} and is built before the Spring
 * context exists, so it cannot be given {@link AuditLogWriter}. Reaching into the
 * {@code SessionFactory} after startup is less elegant and is the reason the writer is an ordinary
 * bean with ordinary dependencies.
 */
@Component
public class AuditEventListenerRegistrar {

    private final EntityManagerFactory entityManagerFactory;
    private final AuditLogWriter writer;

    public AuditEventListenerRegistrar(EntityManagerFactory entityManagerFactory, AuditLogWriter writer) {
        this.entityManagerFactory = entityManagerFactory;
        this.writer = writer;
    }

    @PostConstruct
    public void register() {
        EventListenerRegistry registry = entityManagerFactory
            .unwrap(SessionFactoryImpl.class)
            .getServiceRegistry()
            .getService(EventListenerRegistry.class);

        Listener listener = new Listener();
        // POST_INSERT only. Registering POST_COMMIT_INSERT as well fires the same listener twice
        // for every insert, producing two audit rows for one change -- and a duplicated audit log
        // is not a cosmetic problem: it makes counts wrong for exactly the questions the log is
        // consulted to answer.
        registry.appendListeners(EventType.POST_INSERT, listener);
        registry.appendListeners(EventType.POST_UPDATE, listener);
        registry.appendListeners(EventType.POST_DELETE, listener);
    }

    private final class Listener implements PostInsertEventListener, PostUpdateEventListener, PostDeleteEventListener {

        @Override
        public void onPostInsert(PostInsertEvent event) {
            if (skip(event.getEntity())) {
                return;
            }
            writer.record(
                new AuditLogWriter.AuditEntry(
                    name(event.getEntity()),
                    String.valueOf(event.getId()),
                    "CREATE",
                    json(event.getPersister().getPropertyNames(), event.getState())
                )
            );
        }

        @Override
        public void onPostUpdate(PostUpdateEvent event) {
            if (skip(event.getEntity())) {
                return;
            }

            // Only the fields that actually moved. Recording the whole entity on every update
            // makes the log large and makes "what changed" a diffing exercise for the reader.
            int[] dirty = event.getDirtyProperties();
            if (dirty == null || dirty.length == 0) {
                return;
            }

            String[] names = event.getPersister().getPropertyNames();
            String payload = IntStream.of(dirty)
                .mapToObj(i -> quote(names[i]) + ":{\"from\":" + literal(old(event, i)) + ",\"to\":" + literal(event.getState()[i]) + "}")
                .collect(Collectors.joining(",", "{", "}"));

            writer.record(new AuditLogWriter.AuditEntry(name(event.getEntity()), String.valueOf(event.getId()), "UPDATE", payload));
        }

        @Override
        public void onPostDelete(PostDeleteEvent event) {
            if (skip(event.getEntity())) {
                return;
            }
            // No payload. What matters about a delete is that it happened, by whom and when; the
            // values are already in this entity's earlier entries.
            writer.record(new AuditLogWriter.AuditEntry(name(event.getEntity()), String.valueOf(event.getId()), "DELETE", null));
        }

        @Override
        public boolean requiresPostCommitHandling(EntityPersister persister) {
            return false;
        }
    }

    /**
     * The audit log does not audit the outbox.
     *
     * <p>Outbox rows are plumbing, not domain changes, and every one of them would produce an
     * audit entry describing a message about a change that already has its own entry. The relay
     * marking a row published would generate one more. Left in, the log becomes mostly noise about
     * itself.
     */
    private static boolean skip(Object entity) {
        return entity instanceof OutboxMessage || entity == null;
    }

    private static String name(Object entity) {
        return entity.getClass().getSimpleName();
    }

    private static Object old(PostUpdateEvent event, int index) {
        Object[] oldState = event.getOldState();
        // Null when the entity was not loaded in this session -- a detached merge, for instance.
        // The change is still recorded; only the previous value is unavailable.
        return oldState == null ? null : oldState[index];
    }

    private static String json(String[] names, Object[] state) {
        return IntStream.range(0, names.length)
            .mapToObj(i -> quote(names[i]) + ":" + literal(state[i]))
            .collect(Collectors.joining(",", "{", "}"));
    }

    /**
     * Values are rendered as JSON strings rather than typed, because the state array holds
     * whatever Hibernate mapped and this runs on the flush path where reflection is expensive.
     * The payload is for reading, not for querying by type.
     */
    private static String literal(Object value) {
        if (value == null) {
            return "null";
        }
        if (value instanceof Number || value instanceof Boolean) {
            return value.toString();
        }
        if (value.getClass().isArray()) {
            return quote(Arrays.deepToString(new Object[] { value }));
        }
        return quote(value.toString());
    }

    private static String quote(String value) {
        return '"' + value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "") + '"';
    }
}
