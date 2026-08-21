package com.xenopsoftware.core.domain;

import jakarta.persistence.*;
import org.hibernate.annotations.SoftDelete;
import org.hibernate.annotations.TenantId;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import java.time.Instant;

/**
 * ============================================================================
 * DELETE THIS. It is the one throwaway entity the stemcell ships, and it exists
 * to prove the chain works, not because anything needs an "item".
 *
 * What it demonstrates, and what breaks silently if you skip it when adding
 * your first real entity:
 *
 *   - The table is created by a Flyway migration (V2__example_item.sql), never
 *     by Hibernate. spring.jpa.hibernate.ddl-auto is `validate`, so if the
 *     entity and the migration disagree the application refuses to start
 *     instead of quietly altering the schema.
 *
 *   - Because of that, the correct order is ALWAYS: write the migration, then
 *     the entity. Doing it the other way round appears to work in a fresh
 *     database and fails in every environment that already has data.
 *
 * To remove: delete this class, ExampleItemRepository, ExampleItemResource, and
 * add a migration that drops the table. Do NOT delete V2 itself -- migrations
 * are append-only, and editing history is how two environments end up with the
 * same version number and different schemas.
 * ============================================================================
 */
@Entity
@Table(name = "example_item")
// Soft delete (T-3.10). Hibernate rewrites DELETE into UPDATE ... SET deleted = true and adds the
// predicate to every query, so ordinary repository code needs no changes and cannot forget it --
// which is the reason to use the mapping rather than a hand-written @Where plus @SQLDelete.
//
// The cost, and it is a real one: deleted rows become invisible to JPA ENTIRELY. There is no
// "include deleted" switch. Reading them back is a native query -- see ExampleItemRepository.
@SoftDelete(columnName = "deleted")
public class ExampleItem extends AbstractAuditingEntity<Long> {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @NotBlank
    @Size(max = 200)
    @Column(name = "name", nullable = false, length = 200)
    private String name;

    @Column(name = "created_at", nullable = false)
    private Instant createdAt = Instant.now();

    /**
     * The tenancy seam (T-3.10). Present and inert: with the default resolver every row is written
     * as {@code default} and every query filters to {@code default}, so behaviour is unchanged.
     *
     * <p>Hibernate sets this on insert and adds it to every query automatically. That is the whole
     * point of using {@code @TenantId} rather than an ordinary column: a column the application
     * has to remember to filter by is a column that will eventually not be filtered by, and the
     * failure mode of forgetting is one tenant reading another's data.
     *
     * <p>Not settable from outside. A tenant a caller can choose is not a tenant boundary.
     */
    @TenantId
    @Column(name = "tenant_id", nullable = false, length = 64, updatable = false)
    private String tenantId;

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public String getName() {
        return name;
    }

    public void setName(String name) {
        this.name = name;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(Instant createdAt) {
        this.createdAt = createdAt;
    }

    /** Read-only. Hibernate populates it from the current tenant resolver. */
    public String getTenantId() {
        return tenantId;
    }
}
