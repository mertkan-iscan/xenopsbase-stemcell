package com.xenopsoftware.common.storage;

import java.time.Duration;
import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Object storage, as a platform capability rather than a feature of one service (T-3.7).
 *
 * <p>Every field here describes the <em>S3 API</em>, not a provider. The same settings point at
 * Hetzner Object Storage, MinIO or any other S3-compatible endpoint; nothing in this template may
 * depend on which one is behind it.
 *
 * <h2>Bound twice, deliberately</h2>
 *
 * This class was {@code ApplicationProperties.Storage} in {@code core}. It is bound here at
 * {@code application.storage} so the shared beans need nothing from a service's own properties
 * class, and each service that also declares a {@code storage} field of this type binds the same
 * keys again into its own object. That looks redundant and is what keeps
 * {@code ignoreUnknownFields = false} honest: a service whose {@code ApplicationProperties} did
 * not mention {@code storage} would fail its own binding on every {@code application.storage.*}
 * key, and the typo protection that strictness exists for would have to be given up to move this
 * class out.
 */
@ConfigurationProperties(prefix = "application.storage")
public class ObjectStoreProperties {

    /** Bucket holding stored objects. Per environment — see infra/terraform/storage. */
    private String bucket;

    /**
     * S3 endpoint. Required: unlike AWS, every provider this template targets needs one stated
     * explicitly, and defaulting to AWS would send a misconfigured deployment's objects to the
     * wrong company.
     */
    private String endpoint;

    /**
     * Region. Most S3-compatible providers ignore the value but require the signature to carry
     * one, so this is about signing rather than placement.
     */
    private String region = "us-east-1";

    /**
     * Path-style addressing ({@code endpoint/bucket/key}) rather than virtual-host style
     * ({@code bucket.endpoint/key}).
     * <p>
     * Default true because virtual-host style needs a wildcard DNS entry and a wildcard
     * certificate per bucket, which self-hosted providers and MinIO generally do not have.
     */
    private boolean pathStyleAccess = true;

    /**
     * How long a presigned URL stays valid.
     * <p>
     * Short on purpose. A presigned URL is a bearer credential: anyone holding it can read or
     * write that object, with no further authentication. It will end up in browser history,
     * proxy logs and copy-pasted links, so its value is bounded by how quickly it expires.
     */
    private Duration presignTtl = Duration.ofMinutes(15);

    /**
     * Largest upload the service will presign, in bytes.
     * <p>
     * Enforced by the signature itself via a content-length condition, not merely checked
     * here — a limit the client could ignore would not be a limit.
     */
    private long maxUploadBytes = 50L * 1024 * 1024;

    public String getBucket() {
        return bucket;
    }

    public void setBucket(String bucket) {
        this.bucket = bucket;
    }

    public String getEndpoint() {
        return endpoint;
    }

    public void setEndpoint(String endpoint) {
        this.endpoint = endpoint;
    }

    public String getRegion() {
        return region;
    }

    public void setRegion(String region) {
        this.region = region;
    }

    public boolean isPathStyleAccess() {
        return pathStyleAccess;
    }

    public void setPathStyleAccess(boolean pathStyleAccess) {
        this.pathStyleAccess = pathStyleAccess;
    }

    public Duration getPresignTtl() {
        return presignTtl;
    }

    public void setPresignTtl(Duration presignTtl) {
        this.presignTtl = presignTtl;
    }

    public long getMaxUploadBytes() {
        return maxUploadBytes;
    }

    public void setMaxUploadBytes(long maxUploadBytes) {
        this.maxUploadBytes = maxUploadBytes;
    }
}
