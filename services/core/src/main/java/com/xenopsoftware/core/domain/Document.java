package com.xenopsoftware.core.domain;

import jakarta.persistence.*;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import java.time.Instant;

/**
 * Metadata for a document whose bytes live in object storage (T-3.7).
 *
 * <p>This row and the object it describes are in two different systems with no shared transaction.
 * {@link Status} is what bridges them: a row is written first as {@code PENDING}, and only becomes
 * {@code AVAILABLE} once the object has been confirmed present. See {@code V3__document.sql} for
 * why the ordering is that way round.
 */
@Entity
@Table(name = "document")
public class Document {

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
     * The object's key in the bucket. Server-generated, never derived from {@link #filename} —
     * see the migration for why.
     */
    @NotBlank
    @Size(max = 512)
    @Column(name = "object_key", nullable = false, length = 512, updatable = false)
    private String objectKey;

    /** The name the user gave the file. Presentation only; it never reaches the object key. */
    @NotBlank
    @Size(max = 255)
    @Column(name = "filename", nullable = false, length = 255)
    private String filename;

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

    /** The {@code sub} of the uploading principal. Keycloak owns identity; this is only a key. */
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

    public String getObjectKey() {
        return objectKey;
    }

    public void setObjectKey(String objectKey) {
        this.objectKey = objectKey;
    }

    public String getFilename() {
        return filename;
    }

    public void setFilename(String filename) {
        this.filename = filename;
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
