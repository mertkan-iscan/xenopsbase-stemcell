package com.xenopsoftware.core.domain;

import jakarta.persistence.*;
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
public class ExampleItem {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @NotBlank
    @Size(max = 200)
    @Column(name = "name", nullable = false, length = 200)
    private String name;

    @Column(name = "created_at", nullable = false)
    private Instant createdAt = Instant.now();

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
}
