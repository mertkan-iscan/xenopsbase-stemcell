package com.xenopsoftware.core.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.xenopsoftware.core.IntegrationTest;
import com.xenopsoftware.core.domain.ExampleItem;
import com.xenopsoftware.core.domain.OutboxMessage;
import com.xenopsoftware.core.repository.ExampleItemRepository;
import com.xenopsoftware.core.repository.OutboxMessageRepository;
import com.xenopsoftware.core.service.outbox.OutboxService;
import com.xenopsoftware.core.tenancy.TenantContext;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * The four extension seams, exercised against a real database (T-3.10).
 *
 * <p>Each assertion targets the way its seam fails <em>silently</em> rather than the happy path.
 * A seam that appears present and does nothing is worse than an absent one, because nobody goes
 * looking for it.
 */
@IntegrationTest
@WithMockUser(username = "auditor")
class ExtensionSeamsIT {

    @Autowired
    private ExampleItemRepository exampleItemRepository;

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
        // Inside a transaction, and that is not incidental. The datasource runs with
        // hikari.auto-commit: false, so a JdbcTemplate write with no surrounding transaction takes
        // a connection, executes, and hands it back without committing -- the work is discarded
        // and the affected-row count still reports success.
        //
        // The symptom was every test in this class seeing the previous ones' rows while the
        // deletes claimed to have removed them.
        transactionTemplate.executeWithoutResult(status -> {
            jdbcTemplate.update("delete from audit_log");
            jdbcTemplate.update("delete from outbox_message");
            jdbcTemplate.update("delete from example_item");
        });
        TenantContext.clear();
    }

    private ExampleItem newItem(String name) {
        ExampleItem item = new ExampleItem();
        item.setName(name);
        return item;
    }

    // ---------------------------------------------------------------- audit

    @Test
    void everyWriteIsAuditedWithoutTheEntityOptingIn() {
        ExampleItem saved = transactionTemplate.execute(status -> exampleItemRepository.save(newItem("first")));

        // payload::text, not payload. A jsonb column comes back as a PGobject, and casting that
        // to String throws -- which reads as an audit failure rather than as a JDBC type detail.
        List<Map<String, Object>> entries = jdbcTemplate.queryForList(
            "select entity_type, entity_id, action, actor, actor_name, payload::text as payload " +
                "from audit_log where entity_type = 'ExampleItem'"
        );

        assertThat(entries).as("an entity with no audit annotation must still be audited").hasSize(1);
        assertThat(entries.get(0)).containsEntry("action", "CREATE").containsEntry("entity_id", String.valueOf(saved.getId()));
        assertThat((String) entries.get(0).get("payload")).contains("first");
    }

    @Test
    void anUpdateRecordsWhatChangedRatherThanTheWholeEntity() {
        ExampleItem saved = transactionTemplate.execute(status -> exampleItemRepository.save(newItem("before")));

        transactionTemplate.execute(status -> {
            ExampleItem found = exampleItemRepository.findById(saved.getId()).orElseThrow();
            found.setName("after");
            return exampleItemRepository.save(found);
        });

        String payload = jdbcTemplate.queryForObject("select payload::text from audit_log where action = 'UPDATE'", String.class);

        // Both sides. A log that records only the new value cannot answer "what was it before",
        // which is the question an audit log exists for.
        assertThat(payload).contains("before").contains("after");
    }

    @Test
    void auditEntriesRollBackWithTheChangeTheyDescribe() {
        assertThatThrownBy(() ->
            transactionTemplate.execute(status -> {
                exampleItemRepository.save(newItem("doomed"));
                exampleItemRepository.flush();
                throw new IllegalStateException("forced rollback");
            })
        ).hasMessageContaining("forced rollback");

        // The alternative -- writing audit rows after commit -- would leave this entry describing
        // a change that never happened. An audit log that records fiction is worse than none.
        assertThat(jdbcTemplate.queryForObject("select count(*) from audit_log", Integer.class)).as("no change, no audit entry").isZero();
    }

    @Test
    void theActorIsTheStableIdentifierNotTheUsername() {
        transactionTemplate.execute(status -> exampleItemRepository.save(newItem("attributed")));

        Map<String, Object> entry = jdbcTemplate.queryForMap("select actor, actor_name from audit_log");

        // actor must survive a rename; actor_name is a point-in-time snapshot for humans.
        assertThat(entry.get("actor")).as("actor is recorded").isNotNull();
        assertThat(entry).containsKey("actor_name");
    }

    // ---------------------------------------------------------- soft delete

    @Test
    void aDeletedRowDisappearsFromQueriesButRemainsInTheTable() {
        ExampleItem saved = transactionTemplate.execute(status -> exampleItemRepository.save(newItem("gone")));

        transactionTemplate.executeWithoutResult(status -> exampleItemRepository.deleteById(saved.getId()));

        assertThat(exampleItemRepository.findById(saved.getId())).as("invisible to ordinary queries").isEmpty();
        assertThat(exampleItemRepository.findAll()).isEmpty();

        Integer rowsStillPresent = jdbcTemplate.queryForObject(
            "select count(*) from example_item where id = ? and deleted = true",
            Integer.class,
            saved.getId()
        );
        assertThat(rowsStillPresent).as("the row is still there -- that is the point of soft delete").isEqualTo(1);
    }

    // ------------------------------------------------------------- tenancy

    @Test
    void rowsAreWrittenUnderTheDefaultTenantWhileTheSeamIsInert() {
        transactionTemplate.execute(status -> exampleItemRepository.save(newItem("tenanted")));

        String tenant = jdbcTemplate.queryForObject("select tenant_id from example_item", String.class);

        // NOT NULL and never blank. A row with no tenant matches no tenant filter and becomes
        // invisible to everyone, including whoever owns it.
        assertThat(tenant).isEqualTo(TenantContext.DEFAULT_TENANT);
    }

    @Test
    void aRowWrittenUnderOneTenantIsInvisibleToAnother() {
        TenantContext.set("acme");
        ExampleItem acme = transactionTemplate.execute(status -> exampleItemRepository.save(newItem("acme-only")));

        // This is the assertion that proves the resolver is actually wired. Without it registered
        // in Hibernate's settings the column would still be written, findAll would still return
        // the row, and the seam would look like it worked.
        TenantContext.set("other");
        assertThat(exampleItemRepository.findAll()).as("another tenant must not see it").isEmpty();
        assertThat(exampleItemRepository.findById(acme.getId())).isEmpty();

        TenantContext.set("acme");
        assertThat(exampleItemRepository.findById(acme.getId())).as("its own tenant still sees it").isPresent();
    }

    // -------------------------------------------------------------- outbox

    @Test
    void aMessageAndTheChangeItAnnouncesCommitTogether() {
        transactionTemplate.execute(status -> {
            ExampleItem saved = exampleItemRepository.save(newItem("published"));
            outboxService.record("example.created", "ExampleItem", String.valueOf(saved.getId()), Map.of("name", saved.getName()));
            return saved;
        });

        assertThat(outboxRepository.findAll())
            .singleElement()
            .satisfies(message -> {
                assertThat(message.getMessageType()).isEqualTo("example.created");
                assertThat(message.getPublishedAt()).as("recorded, not yet published").isNull();
                assertThat(message.getPayload()).contains("published");
            });
    }

    @Test
    void aRolledBackChangeAnnouncesNothing() {
        assertThatThrownBy(() ->
            transactionTemplate.execute(status -> {
                ExampleItem saved = exampleItemRepository.save(newItem("never"));
                outboxService.record("example.created", "ExampleItem", String.valueOf(saved.getId()), Map.of());
                throw new IllegalStateException("forced rollback");
            })
        ).hasMessageContaining("forced rollback");

        // The failure this pattern exists to prevent: an event announcing something that did not
        // happen. Publishing to a broker inline could not offer this.
        assertThat(outboxRepository.findAll()).isEmpty();
        assertThat(exampleItemRepository.findAll()).isEmpty();
    }

    @Test
    void recordingOutsideATransactionFailsRatherThanCommittingOnItsOwn() {
        // Propagation.MANDATORY. Without it this would open its own transaction and commit the
        // message independently of any change -- silently removing the only guarantee the outbox
        // provides, while appearing to work.
        assertThatThrownBy(() -> outboxService.record("orphan", "None", "1", Map.of())).isInstanceOf(
            org.springframework.transaction.IllegalTransactionStateException.class
        );

        assertThat(outboxRepository.findAll()).isEmpty();
    }

    @Test
    void outboxRowsAreNotThemselvesAudited() {
        transactionTemplate.execute(status -> {
            ExampleItem saved = exampleItemRepository.save(newItem("noise"));
            outboxService.record("example.created", "ExampleItem", String.valueOf(saved.getId()), Map.of());
            return saved;
        });

        assertThat(jdbcTemplate.queryForList("select entity_type from audit_log", String.class))
            .as("the audit log must not fill with entries about its own plumbing")
            .containsExactly("ExampleItem");
    }

    @Test
    void aMessageThatCannotBeSerialisedFailsTheWholeTransaction() {
        assertThatThrownBy(() ->
            transactionTemplate.execute(status -> {
                exampleItemRepository.save(newItem("unserialisable"));
                outboxService.record("bad", "ExampleItem", "1", new Object());
                return null;
            })
        ).isInstanceOf(IllegalArgumentException.class);

        // Committing the change and dropping the message would make the outbox best-effort.
        assertThat(exampleItemRepository.findAll()).isEmpty();
    }

    @Test
    void unpublishedMessagesAreClaimedOldestFirst() {
        transactionTemplate.execute(status -> {
            ExampleItem saved = exampleItemRepository.save(newItem("batch"));
            outboxService.record("first", "ExampleItem", String.valueOf(saved.getId()), Map.of());
            outboxService.record("second", "ExampleItem", String.valueOf(saved.getId()), Map.of());
            return saved;
        });

        List<OutboxMessage> claimed = transactionTemplate.execute(status ->
            outboxRepository.claimUnpublished(org.springframework.data.domain.Limit.of(10))
        );

        assertThat(claimed).extracting(OutboxMessage::getMessageType).containsExactly("first", "second");
    }
}
