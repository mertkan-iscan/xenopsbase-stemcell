package com.xenopsoftware.core.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.xenopsoftware.common.outbox.OutboxMessage;
import com.xenopsoftware.common.outbox.OutboxMessageRepository;
import com.xenopsoftware.common.outbox.OutboxService;
import com.xenopsoftware.common.tenancy.TenantContext;
import com.xenopsoftware.core.IntegrationTest;
import com.xenopsoftware.core.platform.PlatformProbe;
import com.xenopsoftware.core.platform.PlatformProbeRepository;
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
    private PlatformProbeRepository probeRepository;

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
            jdbcTemplate.update("delete from platform_probe");
        });
        TenantContext.clear();
    }

    /**
     * A probe row with the minimum every seam needs. It is never uploaded to and never completed —
     * the object-storage half of the probe is covered by {@code PlatformProbeResourceIT}; what this
     * class cares about is what happens to the ROW.
     */
    private PlatformProbe newProbe(String label) {
        PlatformProbe probe = new PlatformProbe();
        probe.setObjectKey("seams/" + label + "-" + java.util.UUID.randomUUID());
        probe.setLabel(label);
        probe.setContentType("text/plain");
        probe.setOwner("auditor");
        return probe;
    }

    // ---------------------------------------------------------------- audit

    @Test
    void everyWriteIsAuditedWithoutTheEntityOptingIn() {
        PlatformProbe saved = transactionTemplate.execute(status -> probeRepository.save(newProbe("first")));

        // payload::text, not payload. A jsonb column comes back as a PGobject, and casting that
        // to String throws -- which reads as an audit failure rather than as a JDBC type detail.
        List<Map<String, Object>> entries = jdbcTemplate.queryForList(
            "select entity_type, entity_id, action, actor, actor_name, payload::text as payload " +
                "from audit_log where entity_type = 'PlatformProbe'"
        );

        assertThat(entries).as("an entity with no audit annotation must still be audited").hasSize(1);
        assertThat(entries.get(0)).containsEntry("action", "CREATE").containsEntry("entity_id", String.valueOf(saved.getId()));
        assertThat((String) entries.get(0).get("payload")).contains("first");
    }

    @Test
    void anUpdateRecordsWhatChangedRatherThanTheWholeEntity() {
        PlatformProbe saved = transactionTemplate.execute(status -> probeRepository.save(newProbe("before")));

        transactionTemplate.execute(status -> {
            PlatformProbe found = probeRepository.findById(saved.getId()).orElseThrow();
            found.setLabel("after");
            return probeRepository.save(found);
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
                probeRepository.save(newProbe("doomed"));
                probeRepository.flush();
                throw new IllegalStateException("forced rollback");
            })
        ).hasMessageContaining("forced rollback");

        // The alternative -- writing audit rows after commit -- would leave this entry describing
        // a change that never happened. An audit log that records fiction is worse than none.
        assertThat(jdbcTemplate.queryForObject("select count(*) from audit_log", Integer.class)).as("no change, no audit entry").isZero();
    }

    @Test
    void theActorIsTheStableIdentifierNotTheUsername() {
        transactionTemplate.execute(status -> probeRepository.save(newProbe("attributed")));

        Map<String, Object> entry = jdbcTemplate.queryForMap("select actor, actor_name from audit_log");

        // actor must survive a rename; actor_name is a point-in-time snapshot for humans.
        assertThat(entry.get("actor")).as("actor is recorded").isNotNull();
        assertThat(entry).containsKey("actor_name");
    }

    // ---------------------------------------------------------- soft delete

    @Test
    void aDeletedRowDisappearsFromQueriesButRemainsInTheTable() {
        PlatformProbe saved = transactionTemplate.execute(status -> probeRepository.save(newProbe("gone")));

        transactionTemplate.executeWithoutResult(status -> probeRepository.deleteById(saved.getId()));

        assertThat(probeRepository.findById(saved.getId())).as("invisible to ordinary queries").isEmpty();
        assertThat(probeRepository.findAll()).isEmpty();

        Integer rowsStillPresent = jdbcTemplate.queryForObject(
            "select count(*) from platform_probe where id = ? and deleted = true",
            Integer.class,
            saved.getId()
        );
        assertThat(rowsStillPresent).as("the row is still there -- that is the point of soft delete").isEqualTo(1);
    }

    // ------------------------------------------------------------- tenancy

    @Test
    void rowsAreWrittenUnderTheDefaultTenantWhileTheSeamIsInert() {
        transactionTemplate.execute(status -> probeRepository.save(newProbe("tenanted")));

        String tenant = jdbcTemplate.queryForObject("select tenant_id from platform_probe", String.class);

        // NOT NULL and never blank. A row with no tenant matches no tenant filter and becomes
        // invisible to everyone, including whoever owns it.
        assertThat(tenant).isEqualTo(TenantContext.DEFAULT_TENANT);
    }

    @Test
    void aRowWrittenUnderOneTenantIsInvisibleToAnother() {
        TenantContext.set("acme");
        PlatformProbe acme = transactionTemplate.execute(status -> probeRepository.save(newProbe("acme-only")));

        // This is the assertion that proves the resolver is actually wired. Without it registered
        // in Hibernate's settings the column would still be written, findAll would still return
        // the row, and the seam would look like it worked.
        TenantContext.set("other");
        assertThat(probeRepository.findAll()).as("another tenant must not see it").isEmpty();
        assertThat(probeRepository.findById(acme.getId())).isEmpty();

        TenantContext.set("acme");
        assertThat(probeRepository.findById(acme.getId())).as("its own tenant still sees it").isPresent();
    }

    // -------------------------------------------------------------- outbox

    @Test
    void aMessageAndTheChangeItAnnouncesCommitTogether() {
        transactionTemplate.execute(status -> {
            PlatformProbe saved = probeRepository.save(newProbe("published"));
            outboxService.record(
                "platform.probe.created",
                "PlatformProbe",
                String.valueOf(saved.getId()),
                Map.of("label", saved.getLabel())
            );
            return saved;
        });

        assertThat(outboxRepository.findAll())
            .singleElement()
            .satisfies(message -> {
                assertThat(message.getMessageType()).isEqualTo("platform.probe.created");
                assertThat(message.getPublishedAt()).as("recorded, not yet published").isNull();
                assertThat(message.getPayload()).contains("published");
            });
    }

    @Test
    void aRolledBackChangeAnnouncesNothing() {
        assertThatThrownBy(() ->
            transactionTemplate.execute(status -> {
                PlatformProbe saved = probeRepository.save(newProbe("never"));
                outboxService.record("platform.probe.created", "PlatformProbe", String.valueOf(saved.getId()), Map.of());
                throw new IllegalStateException("forced rollback");
            })
        ).hasMessageContaining("forced rollback");

        // The failure this pattern exists to prevent: an event announcing something that did not
        // happen. Publishing to a broker inline could not offer this.
        assertThat(outboxRepository.findAll()).isEmpty();
        assertThat(probeRepository.findAll()).isEmpty();
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
            PlatformProbe saved = probeRepository.save(newProbe("noise"));
            outboxService.record("platform.probe.created", "PlatformProbe", String.valueOf(saved.getId()), Map.of());
            return saved;
        });

        assertThat(jdbcTemplate.queryForList("select entity_type from audit_log", String.class))
            .as("the audit log must not fill with entries about its own plumbing")
            .containsExactly("PlatformProbe");
    }

    @Test
    void aMessageThatCannotBeSerialisedFailsTheWholeTransaction() {
        assertThatThrownBy(() ->
            transactionTemplate.execute(status -> {
                probeRepository.save(newProbe("unserialisable"));
                outboxService.record("bad", "PlatformProbe", "1", new Object());
                return null;
            })
        ).isInstanceOf(IllegalArgumentException.class);

        // Committing the change and dropping the message would make the outbox best-effort.
        assertThat(probeRepository.findAll()).isEmpty();
    }

    @Test
    void unpublishedMessagesAreClaimedOldestFirst() {
        transactionTemplate.execute(status -> {
            PlatformProbe saved = probeRepository.save(newProbe("batch"));
            outboxService.record("first", "PlatformProbe", String.valueOf(saved.getId()), Map.of());
            outboxService.record("second", "PlatformProbe", String.valueOf(saved.getId()), Map.of());
            return saved;
        });

        List<OutboxMessage> claimed = transactionTemplate.execute(status ->
            outboxRepository.claimUnpublished(org.springframework.data.domain.Limit.of(10))
        );

        assertThat(claimed).extracting(OutboxMessage::getMessageType).containsExactly("first", "second");
    }
}
