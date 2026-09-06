package com.xenopsoftware.core.platform;

import com.xenopsoftware.common.domain.AbstractAuditingEntity;
import jakarta.persistence.*;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import java.time.Instant;
import org.hibernate.annotations.SoftDelete;
import org.hibernate.annotations.TenantId;

/**
 * The template's self-test, as a row (T-9.2).
 *
 * <h2>What this is, and what it deliberately is not</h2>
 *
 * It is not a business entity, and it is not an example whose shape should be copied. It is the one
 * record type this template owns, so that the seams it ships are exercised end to end by something
 * — because a seam nothing exercises is indistinguishable from a broken one, and this repository
 * has now found several controls that reported success while governing nothing.
 *
 * <p>It replaces {@code Document} and {@code ExampleItem}, which were a demo domain in a template
 * that claims to have none. The name says what it is. A fork deletes it once its own entities
 * exercise the same paths; until then it is what keeps {@code smoke.sh}, the k6 suites and the
 * restore drill meaningful rather than green by absence.
 *
 * <h2>Every seam, on one row</h2>
 *
 * <ul>
 *   <li><b>Audit columns</b> — {@link AbstractAuditingEntity}, with no opt-in from this class</li>
 *   <li><b>{@code audit_log}</b> — the Hibernate event listener, which needs nothing here either</li>
 *   <li><b>Soft delete</b> — {@link SoftDelete}, below</li>
 *   <li><b>Multi-tenancy</b> — {@link #tenantId}, present and inert</li>
 *   <li><b>Transactional outbox</b> — written by {@link PlatformProbeService}, not by this class</li>
 *   <li><b>Idempotency</b> — the filter, on the POST that creates one of these</li>
 *   <li><b>Object storage</b> — {@link #objectKey}, and the consistency story below</li>
 * </ul>
 *
 * <h2>The consistency story, written into the schema rather than assumed</h2>
 *
 * This row and the object it describes are in two different systems with no shared transaction.
 * {@link Status} is what bridges them: a row is written first as {@code PENDING}, and only becomes
 * {@code AVAILABLE} once the object has been confirmed present. See {@code V8__platform_probe.sql}
 * for why the ordering is that way round.
 */
@Entity
@Table(name = "platform_probe")
/*
 * SOFT DELETE (T-3.10). Hibernate rewrites DELETE into UPDATE ... SET deleted = true and adds the
 * predicate to every query, so ordinary repository code needs no changes and cannot forget it --
 * which is the reason to use the mapping rather than a hand-written @Where plus @SQLDelete.
 *
 * The cost, and it is a real one: deleted rows become invisible to JPA ENTIRELY. There is no
 * "include deleted" switch. Reading them back is a native query -- see PlatformProbeRepository.
 *
 * WHY THIS IS SAFE HERE WHEN IT WAS NOT SAFE ON `document`. The entity this replaces carried a
 * comment refusing soft delete, on the grounds that a row marked deleted while its object still
 * exists is a leak wearing a tombstone: it still costs storage and is still readable by anyone
 * holding a presigned URL. That objection is answered rather than dropped. PlatformProbeService
 * deletes the OBJECT for real, immediately, in the same operation that tombstones the row. The
 * bytes are what costs money and leaks; the row is what has history worth keeping. Separating the
 * two is what lets one entity demonstrate both seams without lying about either.
 */
@SoftDelete(columnName = "deleted")
public class PlatformProbe extends AbstractAuditingEntity<Long> {

    public enum Status {
        /** Row exists, object may not. The client holds a presigned URL it may never use. */
        PENDING,
        /** Object confirmed present. The only status that can be downloaded. */
        AVAILABLE,
    }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

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

    /**
     * The object's key in the bucket. Server-generated, never derived from {@link #label} — see
     * the migration for why.
     */
    @NotBlank
    @Size(max = 512)
    @Column(name = "object_key", nullable = false, length = 512, updatable = false)
    private String objectKey;

    /**
     * A caller-supplied name for this probe. Presentation only; it never reaches the object key,
     * and it is the name the download is served under.
     */
    @NotBlank
    @Size(max = 255)
    @Column(name = "label", nullable = false, length = 255)
    private String label;

    @NotBlank
    @Size(max = 255)
    @Column(name = "content_type", nullable = false, length = 255)
    private String contentType;

    /**
     * Null until the upload is confirmed. Set from the object store's own view of the object
     * rather than from what the client claimed, because the claim is unverified until then.
     */
    @Column(name = "size_bytes")
    private Long sizeBytes;

    /** The {@code sub} of the creating principal. Keycloak owns identity; this is only a key. */
    @NotBlank
    @Size(max = 255)
    @Column(name = "owner", nullable = false, length = 255, updatable = false)
    private String owner;

    @Enumerated(EnumType.STRING)
    @Column(name = "status", nullable = false, length = 20)
    private Status status = Status.PENDING;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt = Instant.now();

    @Column(name = "completed_at")
    private Instant completedAt;

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    /** Read-only. Hibernate populates it from the current tenant resolver. */
    public String getTenantId() {
        return tenantId;
    }

    public String getObjectKey() {
        return objectKey;
    }

    public void setObjectKey(String objectKey) {
        this.objectKey = objectKey;
    }

    public String getLabel() {
        return label;
    }

    public void setLabel(String label) {
        this.label = label;
    }

    public String getContentType() {
        return contentType;
    }

    public void setContentType(String contentType) {
        this.contentType = contentType;
    }

    public Long getSizeBytes() {
        return sizeBytes;
    }

    public void setSizeBytes(Long sizeBytes) {
        this.sizeBytes = sizeBytes;
    }

    public String getOwner() {
        return owner;
    }

    public void setOwner(String owner) {
        this.owner = owner;
    }

    public Status getStatus() {
        return status;
    }

    public void setStatus(Status status) {
        this.status = status;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(Instant createdAt) {
        this.createdAt = createdAt;
    }

    public Instant getCompletedAt() {
        return completedAt;
    }

    public void setCompletedAt(Instant completedAt) {
        this.completedAt = completedAt;
    }
}
