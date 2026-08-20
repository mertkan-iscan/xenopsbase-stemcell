package com.xenopsoftware.core.service.storage;

import java.net.URI;
import java.time.Duration;
import java.util.Optional;

/**
 * The object-storage seam (T-3.7).
 *
 * <p>Deliberately narrow, and deliberately expressed in terms of the S3 API rather than any
 * provider's extensions. Hetzner Object Storage in deployed environments and MinIO locally are
 * both just endpoints behind this interface; if a method here could not be implemented against
 * plain S3, it does not belong.
 *
 * <p>Note what is absent: there is no {@code upload(InputStream)} and no {@code download()}.
 * Routing bytes through the JVM would make every upload a heap-and-socket cost on the service,
 * turn a large file into an outage, and put the service on the critical path for something the
 * object store already does better. Callers get a signed URL and talk to the store directly.
 */
public interface DocumentStorage {
    /**
     * A URL the client can {@code PUT} exactly one object to.
     *
     * <p>{@code contentLength} is part of what gets signed, and S3 treats it as an <b>exact</b>
     * value rather than a ceiling: an upload of any other size fails the signature check and is
     * refused by the object store with a 403. That is stricter than a maximum and is why the
     * caller has to know the size up front — there is no way to presign "at most N bytes" with a
     * plain PUT.
     */
    URI presignUpload(String objectKey, String contentType, long contentLength, Duration ttl);

    /**
     * A URL the client can {@code GET} the object from.
     *
     * @param downloadFilename name the browser should save it as; sent as a response-header
     *                         override so the stored key never has to carry it
     */
    URI presignDownload(String objectKey, String downloadFilename, Duration ttl);

    /** The object store's own view of an object, or empty if it is not there. */
    Optional<StoredObject> stat(String objectKey);

    /** Idempotent: deleting an object that is already gone is a success, not an error. */
    void delete(String objectKey);

    /** What the store reports about an object, as opposed to what a client claimed. */
    record StoredObject(String objectKey, long sizeBytes, String contentType) {}
}
