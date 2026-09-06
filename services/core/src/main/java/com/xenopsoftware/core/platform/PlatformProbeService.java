package com.xenopsoftware.core.platform;

import com.xenopsoftware.common.outbox.OutboxService;
import com.xenopsoftware.common.storage.ConditionalOnObjectStore;
import com.xenopsoftware.common.storage.ObjectStore;
import com.xenopsoftware.common.storage.ObjectStoreProperties;
import com.xenopsoftware.core.config.ApplicationProperties;
import com.xenopsoftware.core.service.BusinessCaches;
import com.xenopsoftware.core.service.SingleFlight;
import java.net.URI;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * The probe's lifecycle, across two systems that cannot share a transaction (T-9.2).
 *
 * <p>This is the template's self-test path, not a business service. Every seam the stemcell ships
 * is on it, deliberately, so that {@code smoke.sh}, the k6 suites and the restore drill exercise
 * something real rather than passing because there is nothing left to check.
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
@ConditionalOnObjectStore
public class PlatformProbeService {

    private static final Logger LOG = LoggerFactory.getLogger(PlatformProbeService.class);

    /** Date-partitioned so a bucket listing stays navigable once there are millions of keys. */
    private static final DateTimeFormatter KEY_PREFIX = DateTimeFormatter.ofPattern("yyyy/MM").withZone(ZoneOffset.UTC);

    private final PlatformProbeRepository repository;
    private final ObjectStore storage;
    private final ObjectStoreProperties settings;
    private final ApplicationEventPublisher events;
    private final SingleFlight singleFlight;
    private final OutboxService outbox;

    public PlatformProbeService(
        PlatformProbeRepository repository,
        ObjectStore storage,
        ApplicationProperties properties,
        ApplicationEventPublisher events,
        SingleFlight singleFlight,
        OutboxService outbox
    ) {
        this.repository = repository;
        this.storage = storage;
        this.settings = properties.getStorage();
        this.events = events;
        this.singleFlight = singleFlight;
        this.outbox = outbox;
    }

    /**
     * Records the intent to upload and returns a URL the client PUTs to directly.
     *
     * <p>Committed before the URL is handed out, so there is never a live presigned URL for an
     * object this service has no record of.
     */
    @Transactional
    public Upload initiateUpload(String label, String contentType, long sizeBytes, String owner) {
        if (sizeBytes <= 0 || sizeBytes > settings.getMaxUploadBytes()) {
            throw new UploadTooLargeException(sizeBytes, settings.getMaxUploadBytes());
        }

        PlatformProbe probe = new PlatformProbe();
        probe.setObjectKey(generateObjectKey());
        probe.setLabel(label);
        probe.setContentType(contentType);
        probe.setOwner(owner);
        probe.setStatus(PlatformProbe.Status.PENDING);
        probe.setCreatedAt(Instant.now());

        PlatformProbe saved = repository.saveAndFlush(probe);

        // THE OUTBOX SEAM, EXERCISED RATHER THAN DOCUMENTED. Recorded in the SAME transaction as
        // the row, which is the entire guarantee OutboxService exists to provide: the message and
        // the change it announces commit together or not at all. Publishing to a broker from here
        // instead could not offer that -- the commit and the publish are two systems, and every
        // ordering of them leaves a window where one happened and the other did not.
        //
        // Nothing consumes this yet; LoggingMessagePublisher writes a log line. That is the point
        // of the seam being here: the mechanism is observable end to end without the template
        // having chosen a broker on a fork's behalf.
        outbox.record("platform.probe.initiated", "PlatformProbe", String.valueOf(saved.getId()), Map.of("label", label));

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
     * <p>Idempotent: completing an already-complete probe returns it unchanged, because a
     * client that retries after a lost response must not get an error for succeeding twice.
     */
    @Transactional
    public Optional<PlatformProbe> completeUpload(Long id, String owner) {
        PlatformProbe probe = repository.findByIdAndOwner(id, owner).orElse(null);
        if (probe == null) {
            return Optional.empty();
        }

        if (probe.getStatus() == PlatformProbe.Status.AVAILABLE) {
            return Optional.of(probe);
        }

        // The only source of truth about whether bytes exist is the store. A client saying it is
        // done proves nothing, because that is what a client would say either way.
        ObjectStore.StoredObject stored = storage.stat(probe.getObjectKey()).orElse(null);
        if (stored == null) {
            LOG.warn("Completion requested for probe {} but object {} is absent", id, probe.getObjectKey());
            return Optional.empty();
        }

        probe.setSizeBytes(stored.sizeBytes());
        probe.setStatus(PlatformProbe.Status.AVAILABLE);
        probe.setCompletedAt(Instant.now());
        PlatformProbe saved = repository.save(probe);

        // PENDING -> AVAILABLE, so this row now belongs in the owner's list. Consumed after commit;
        // see ProbeCacheEviction for why it cannot be a @CacheEvict here.
        events.publishEvent(new ProbesChanged(owner));
        return Optional.of(saved);
    }

    /** A short-lived URL for the client to GET the object directly. */
    @Transactional(readOnly = true)
    public Optional<URI> presignDownload(Long id, String owner) {
        return repository
            .findByIdAndOwner(id, owner)
            .filter(d -> d.getStatus() == PlatformProbe.Status.AVAILABLE)
            .map(d -> storage.presignDownload(d.getObjectKey(), d.getLabel(), settings.getPresignTtl()));
    }

    @Transactional(readOnly = true)
    public Page<PlatformProbe> listAvailable(String owner, Pageable pageable) {
        return repository.findByOwnerAndStatus(owner, PlatformProbe.Status.AVAILABLE, pageable);
    }

    /**
     * The same page, cache-aside through Valkey (T-3.22, #264; ADR-0011).
     *
     * <p>This is the only read path in this service that is cached, and the only one that can be:
     * {@code presignDownload} returns a credential with its own expiry, which ADR-0011's never-cache
     * list rules out, and everything else here backs a write.
     *
     * <p><b>The key carries the owner, and that is a correctness property rather than a naming
     * convention.</b> {@code findByOwnerAndStatus} enforces authorisation by not returning the row;
     * a cache keyed on the page alone would answer a request the database itself would have refused,
     * with another user's probes. ADR-0011 is explicit that this is a different severity class
     * from a stale read, which is why the owner is first in the key and why the DTO does not repeat
     * it in the value -- a second copy of the field that decides who may read the entry is a second
     * chance to get it wrong.
     *
     * <p>The discriminator is the page coordinates. Sort is included because two pages that differ
     * only by ordering are different answers, and omitting it would serve one for the other.
     *
     * <p>Returns a DTO, never the entity: ADR-0011 refuses to serialise a JPA entity, which carries
     * lazy proxies and a persistence context it cannot be separated from.
     *
     * <p>On a cache miss, an unreachable Valkey, or a value that will not deserialise, this falls
     * through to the query above. That is not incidental -- it is T-3.22's acceptance criterion, and
     * {@code CacheConfiguration}'s error handler is what makes it true.
     */
    @Cacheable(
        cacheNames = BusinessCaches.PROBE_LIST,
        key = "#owner + ':' + #pageable.pageNumber + '-' + #pageable.pageSize + '-' + #pageable.sort"
    )
    public CachedProbePage listAvailableCached(String owner, Pageable pageable) {
        // Concurrent misses on one key rebuild it ONCE per replica (T-3.23, #265). Waiters hold no
        // transaction and therefore no connection, which is the whole point: a cold cache must not
        // put one Postgres primary under one request's worth of load per in-flight request.
        //
        // Deliberately NOT @Transactional. The annotation here would open a transaction -- and take
        // a Hikari connection -- for every waiting thread before the coalescing had a chance to
        // stop it, which is exactly the pressure this is meant to remove. The repository call below
        // gets its own transaction, so only the thread that actually queries holds a connection.
        // The SAME key the @Cacheable annotation above builds, sort included. Omitting the sort
        // would coalesce two callers asking for different orderings into one load and hand one of
        // them the other's answer -- a correctness bug, not a tuning detail.
        String key =
            BusinessCaches.keyPrefix(BusinessCaches.PROBE_LIST) +
            owner +
            ":" +
            pageable.getPageNumber() +
            "-" +
            pageable.getPageSize() +
            "-" +
            pageable.getSort();
        return singleFlight.call(key, () -> loadAvailable(owner, pageable));
    }

    private CachedProbePage loadAvailable(String owner, Pageable pageable) {
        Page<PlatformProbe> page = repository.findByOwnerAndStatus(owner, PlatformProbe.Status.AVAILABLE, pageable);
        List<CachedProbePage.CachedProbe> content = page
            .getContent()
            .stream()
            .map(probe ->
                new CachedProbePage.CachedProbe(
                    probe.getId(),
                    probe.getLabel(),
                    probe.getContentType(),
                    probe.getSizeBytes(),
                    probe.getStatus().name(),
                    probe.getCreatedAt()
                )
            )
            .toList();
        return new CachedProbePage(content, page.getTotalElements());
    }

    /**
     * Tombstones the row, and deletes the object for real.
     *
     * <h2>The two halves are deliberately different, and that is the whole soft-delete story</h2>
     *
     * {@code repository.delete} on a {@code @SoftDelete} entity is an {@code UPDATE ... SET deleted
     * = true}: the row stops being visible to every query and its history survives. The object is
     * NOT soft-deleted, because there is no such thing — it is removed from the bucket, now.
     *
     * <p>That asymmetry is the answer to the objection the entity this replaced raised against
     * soft delete: a tombstoned row whose bytes still exist is a leak wearing a tombstone. It
     * still costs storage, and it is still readable by anyone holding a presigned URL that has not
     * yet expired. Deleting the object eagerly removes both, and leaves only the row, which costs
     * nothing and is the part worth keeping.
     *
     * <p>The object delete runs after the row update rather than before it. The other order would
     * leave a visible row pointing at bytes that no longer exist if the transaction rolled back,
     * which is the failure this ordering exists to prevent.
     */
    @Transactional
    public boolean delete(Long id, String owner) {
        PlatformProbe probe = repository.findByIdAndOwner(id, owner).orElse(null);
        if (probe == null) {
            return false;
        }
        String objectKey = probe.getObjectKey();

        // Recorded before the delete, in the same transaction: the message describes a change that
        // is about to commit with it. Recording it afterwards would be the same thing, but
        // recording it OUTSIDE the transaction would not -- see OutboxService for why the
        // propagation is MANDATORY.
        outbox.record("platform.probe.deleted", "PlatformProbe", String.valueOf(id), Map.of("objectKey", objectKey));

        repository.delete(probe);
        repository.flush();

        storage.delete(objectKey);
        events.publishEvent(new ProbesChanged(owner));
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
        List<PlatformProbe> abandoned = repository.findByStatusAndCreatedAtBefore(PlatformProbe.Status.PENDING, olderThan);
        for (PlatformProbe probe : abandoned) {
            // Delete the object too: an upload can complete after the client gave up, leaving
            // bytes behind a row nobody will ever promote.
            storage.delete(probe.getObjectKey());
        }
        repository.deleteAll(abandoned);
        if (!abandoned.isEmpty()) {
            LOG.info("Reaped {} abandoned uploads older than {}", abandoned.size(), olderThan);
        }
        return abandoned.size();
    }

    /**
     * Keys are generated, never derived from the caller-supplied label.
     *
     * <p>A key built from user input is a collision and traversal surface, and an object store
     * has no directory to escape from, so the usual path defences do not apply. A UUID also means
     * two users uploading the same filename cannot overwrite one another.
     */
    private String generateObjectKey() {
        return KEY_PREFIX.format(Instant.now()) + "/" + UUID.randomUUID().toString().toLowerCase(Locale.ROOT);
    }

    /** What the caller needs to perform the upload. */
    public record Upload(PlatformProbe probe, URI uploadUrl, long expiresInSeconds, long contentLength) {}

    /** The declared size is missing, non-positive, or above {@code application.storage.max-upload-bytes}. */
    public static class UploadTooLargeException extends IllegalArgumentException {

        private static final long serialVersionUID = 1L;

        public UploadTooLargeException(long requested, long limit) {
            super("Declared upload size " + requested + " bytes is outside the permitted range (1.." + limit + ")");
        }
    }
}
