package com.xenopsoftware.core.service;

import com.xenopsoftware.core.config.ConditionalOnDocumentStorage;
import com.xenopsoftware.core.config.ApplicationProperties;
import com.xenopsoftware.core.domain.Document;
import com.xenopsoftware.core.repository.DocumentRepository;
import com.xenopsoftware.core.service.storage.DocumentStorage;
import java.net.URI;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Document lifecycle across two systems that cannot share a transaction (T-3.7).
 *
 * <h2>The consistency story</h2>
 *
 * Postgres holds metadata, the bucket holds bytes, and no transaction spans them. Rather than
 * pretend otherwise, the order of operations is chosen so that the surviving inconsistency is
 * always the harmless one:
 *
 * <ol>
 *   <li><b>Initiate.</b> Row committed as {@code PENDING}, then a presigned URL is returned. If
 *       the client never uploads, a row exists with no object. Invisible to users, reaped later.</li>
 *   <li><b>Complete.</b> The object store is asked whether the object is really there, and the
 *       row is promoted to {@code AVAILABLE} with the size <em>the store reports</em>, not the
 *       size the client claimed. Only {@code AVAILABLE} rows are downloadable.</li>
 *   <li><b>Delete.</b> Row first, object second. An object outliving its row is garbage that
 *       costs storage; a row outliving its object is a download that 404s at the worst moment.
 *       Garbage is the better failure.</li>
 * </ol>
 *
 * The inverse ordering is what to avoid: writing the object first would make an interrupted
 * upload produce unreferenced data that nothing can find, delete, or account for.
 */
@Service
@ConditionalOnDocumentStorage
public class DocumentService {

    private static final Logger LOG = LoggerFactory.getLogger(DocumentService.class);

    /** Date-partitioned so a bucket listing stays navigable once there are millions of keys. */
    private static final DateTimeFormatter KEY_PREFIX = DateTimeFormatter.ofPattern("yyyy/MM").withZone(ZoneOffset.UTC);

    private final DocumentRepository repository;
    private final DocumentStorage storage;
    private final ApplicationProperties.Storage settings;

    public DocumentService(DocumentRepository repository, DocumentStorage storage, ApplicationProperties properties) {
        this.repository = repository;
        this.storage = storage;
        this.settings = properties.getStorage();
    }

    /**
     * Records the intent to upload and returns a URL the client PUTs to directly.
     *
     * <p>Committed before the URL is handed out, so there is never a live presigned URL for an
     * object this service has no record of.
     */
    @Transactional
    public Upload initiateUpload(String filename, String contentType, long sizeBytes, String owner) {
        if (sizeBytes <= 0 || sizeBytes > settings.getMaxUploadBytes()) {
            throw new UploadTooLargeException(sizeBytes, settings.getMaxUploadBytes());
        }

        Document document = new Document();
        document.setObjectKey(generateObjectKey());
        document.setFilename(filename);
        document.setContentType(contentType);
        document.setOwner(owner);
        document.setStatus(Document.Status.PENDING);
        document.setCreatedAt(Instant.now());

        Document saved = repository.saveAndFlush(document);

        // Signing the DECLARED size makes the object store enforce it: the client must send
        // exactly this many bytes or the PUT is refused with a 403. The cap is checked above,
        // before signing, because the signature can only pin one value -- it cannot express a
        // range. Together that is a real limit rather than a request the client may ignore.
        URI url = storage.presignUpload(saved.getObjectKey(), contentType, sizeBytes, settings.getPresignTtl());

        return new Upload(saved, url, settings.getPresignTtl().toSeconds(), sizeBytes);
    }

    /**
     * Promotes a {@code PENDING} row once the object is confirmed present.
     *
     * <p>Idempotent: completing an already-complete document returns it unchanged, because a
     * client that retries after a lost response must not get an error for succeeding twice.
     */
    @Transactional
    public Optional<Document> completeUpload(Long id, String owner) {
        Document document = repository.findByIdAndOwner(id, owner).orElse(null);
        if (document == null) {
            return Optional.empty();
        }

        if (document.getStatus() == Document.Status.AVAILABLE) {
            return Optional.of(document);
        }

        // The only source of truth about whether bytes exist is the store. A client saying it is
        // done proves nothing, because that is what a client would say either way.
        DocumentStorage.StoredObject stored = storage.stat(document.getObjectKey()).orElse(null);
        if (stored == null) {
            LOG.warn("Completion requested for document {} but object {} is absent", id, document.getObjectKey());
            return Optional.empty();
        }

        document.setSizeBytes(stored.sizeBytes());
        document.setStatus(Document.Status.AVAILABLE);
        document.setCompletedAt(Instant.now());
        return Optional.of(repository.save(document));
    }

    /** A short-lived URL for the client to GET the object directly. */
    @Transactional(readOnly = true)
    public Optional<URI> presignDownload(Long id, String owner) {
        return repository
            .findByIdAndOwner(id, owner)
            .filter(d -> d.getStatus() == Document.Status.AVAILABLE)
            .map(d -> storage.presignDownload(d.getObjectKey(), d.getFilename(), settings.getPresignTtl()));
    }

    @Transactional(readOnly = true)
    public List<Document> listAvailable(String owner) {
        return repository.findByOwnerAndStatusOrderByCreatedAtDesc(owner, Document.Status.AVAILABLE);
    }

    /**
     * Removes the row, then the object.
     *
     * <p>The object delete runs after the row is gone rather than before it. The other order
     * would leave a row pointing at bytes that no longer exist if the transaction rolled back,
     * which is the failure this ordering exists to prevent.
     */
    @Transactional
    public boolean delete(Long id, String owner) {
        Document document = repository.findByIdAndOwner(id, owner).orElse(null);
        if (document == null) {
            return false;
        }
        String objectKey = document.getObjectKey();
        repository.delete(document);
        repository.flush();

        storage.delete(objectKey);
        return true;
    }

    /**
     * Deletes rows whose upload was presigned and never completed.
     *
     * <p>Not scheduled here on purpose. What sweeps this, and how often, is a deployment
     * decision: a CronJob, a scheduled task, or nothing at all in a fork that does not need it.
     * Wiring a {@code @Scheduled} into the template would run it on every replica at once.
     *
     * @param olderThan cutoff; must be comfortably longer than the presign TTL, or this deletes
     *                  rows whose upload is still legitimately in flight
     */
    @Transactional
    public int reapAbandonedUploads(Instant olderThan) {
        List<Document> abandoned = repository.findByStatusAndCreatedAtBefore(Document.Status.PENDING, olderThan);
        for (Document document : abandoned) {
            // Delete the object too: an upload can complete after the client gave up, leaving
            // bytes behind a row nobody will ever promote.
            storage.delete(document.getObjectKey());
        }
        repository.deleteAll(abandoned);
        if (!abandoned.isEmpty()) {
            LOG.info("Reaped {} abandoned uploads older than {}", abandoned.size(), olderThan);
        }
        return abandoned.size();
    }

    /**
     * Keys are generated, never derived from the uploaded filename.
     *
     * <p>A key built from user input is a collision and traversal surface, and an object store
     * has no directory to escape from, so the usual path defences do not apply. A UUID also means
     * two users uploading the same filename cannot overwrite one another.
     */
    private String generateObjectKey() {
        return KEY_PREFIX.format(Instant.now()) + "/" + UUID.randomUUID().toString().toLowerCase(Locale.ROOT);
    }

    /** What the caller needs to perform the upload. */
    public record Upload(Document document, URI uploadUrl, long expiresInSeconds, long contentLength) {}

    /** The declared size is missing, non-positive, or above {@code application.storage.max-upload-bytes}. */
    public static class UploadTooLargeException extends IllegalArgumentException {

        private static final long serialVersionUID = 1L;

        public UploadTooLargeException(long requested, long limit) {
            super("Declared upload size " + requested + " bytes is outside the permitted range (1.." + limit + ")");
        }
    }
}
