package com.xenopsoftware.core.service.storage;

import com.xenopsoftware.core.config.ConditionalOnDocumentStorage;
import com.xenopsoftware.core.config.ApplicationProperties;
import java.net.URI;
import java.time.Duration;
import java.util.Optional;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.DeleteObjectRequest;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.HeadObjectRequest;
import software.amazon.awssdk.services.s3.model.HeadObjectResponse;
import software.amazon.awssdk.services.s3.model.NoSuchKeyException;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;
import software.amazon.awssdk.services.s3.presigner.model.GetObjectPresignRequest;
import software.amazon.awssdk.services.s3.presigner.model.PutObjectPresignRequest;

/**
 * {@link DocumentStorage} over the plain S3 API.
 *
 * <p>Uses the AWS SDK as an S3 <em>client</em>, not as an AWS integration. Every call below exists
 * in every S3-compatible implementation. Reaching for an AWS-only feature here — Glacier tiers,
 * S3 Select, bucket notifications — would silently make the template unportable, which is the
 * failure this class is shaped to avoid.
 */
@Service
@ConditionalOnDocumentStorage
public class S3DocumentStorage implements DocumentStorage {

    private static final Logger LOG = LoggerFactory.getLogger(S3DocumentStorage.class);

    private final S3Client s3;
    private final S3Presigner presigner;
    private final String bucket;

    public S3DocumentStorage(S3Client s3, S3Presigner presigner, ApplicationProperties properties) {
        this.s3 = s3;
        this.presigner = presigner;
        this.bucket = properties.getStorage().getBucket();
    }

    @Override
    public URI presignUpload(String objectKey, String contentType, long contentLength, Duration ttl) {
        // Signed, and therefore EXACT. An upload of any other length fails the signature check at
        // the object store, so the declared size is enforced by S3 rather than trusted here.
        PutObjectRequest put = PutObjectRequest.builder()
            .bucket(bucket)
            .key(objectKey)
            .contentType(contentType)
            .contentLength(contentLength)
            .build();

        return presigner
            .presignPutObject(PutObjectPresignRequest.builder().signatureDuration(ttl).putObjectRequest(put).build())
            .url()
            .toString()
            .transform(URI::create);
    }

    @Override
    public URI presignDownload(String objectKey, String downloadFilename, Duration ttl) {
        GetObjectRequest get = GetObjectRequest.builder()
            .bucket(bucket)
            .key(objectKey)
            // Overridden per request rather than stored on the object: the same object can then
            // be served under whatever name the metadata says, and renaming a document does not
            // mean rewriting it.
            .responseContentDisposition("attachment; filename=\"" + sanitizeForHeader(downloadFilename) + "\"")
            .build();

        return presigner
            .presignGetObject(GetObjectPresignRequest.builder().signatureDuration(ttl).getObjectRequest(get).build())
            .url()
            .toString()
            .transform(URI::create);
    }

    @Override
    public Optional<StoredObject> stat(String objectKey) {
        try {
            HeadObjectResponse head = s3.headObject(HeadObjectRequest.builder().bucket(bucket).key(objectKey).build());
            return Optional.of(new StoredObject(objectKey, head.contentLength(), head.contentType()));
        } catch (NoSuchKeyException e) {
            return Optional.empty();
        }
    }

    @Override
    public void delete(String objectKey) {
        // S3 DELETE is already idempotent -- deleting a missing key returns 204 -- so there is
        // nothing to catch. Stated because the absence of a try/catch here looks like an
        // oversight and is not.
        s3.deleteObject(DeleteObjectRequest.builder().bucket(bucket).key(objectKey).build());
        LOG.debug("Deleted object {}", objectKey);
    }

    /**
     * Strips what would break the Content-Disposition header rather than rejecting the name.
     * A quote or newline here is a header-injection vector, and the filename is user-supplied.
     */
    private static String sanitizeForHeader(String filename) {
        return filename.replaceAll("[\"\\\r\n]", "_");
    }
}
