package com.xenopsoftware.core.config;

import java.time.Duration;
import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Properties specific to Core.
 * <p>
 * Properties are configured in the {@code application.yml} file.
 * See {@link tech.jhipster.config.JHipsterProperties} for a good example.
 */
@ConfigurationProperties(prefix = "application", ignoreUnknownFields = false)
public class ApplicationProperties {

    private final Storage storage = new Storage();
    private final Infra infra = new Infra();
    private final Cache cache = new Cache();

    public Cache getCache() {
        return cache;
    }

    public Storage getStorage() {
        return storage;
    }

    public Infra getInfra() {
        return infra;
    }

    /**
     * Where the infrastructure usage view reads its numbers from (T-3.16).
     */
    /**
     * Valkey as a business cache (T-3.22, #264; ADR-0011).
     *
     * <p>Bound here rather than read only through {@code @ConditionalOnProperty} because this class
     * is {@code ignoreUnknownFields = false}: a property under {@code application.} that nothing
     * binds fails the context. That strictness caught this the first time the flag was added, which
     * is the point of it -- the alternative is a typo'd flag that silently never takes effect.
     */
    public static class Cache {

        /**
         * Off unless a deployment turns it on, for the same reason {@link Storage#bucket} is unset:
         * a fork that does not want a cache should carry no cache configuration rather than a
         * disabled one. With this false there is no cache manager and no eviction listener.
         *
         * <p>Turning it on also requires {@code spring.data.redis.host}, and it must point at the
         * CACHE Valkey rather than the one holding sessions -- T-2.19 (#262) separated them so a
         * cached entry cannot evict a session.
         */
        private boolean enabled = false;

        public boolean isEnabled() {
            return enabled;
        }

        public void setEnabled(boolean enabled) {
            this.enabled = enabled;
        }
    }

    public static class Infra {

        /**
         * Base URL of the Prometheus HTTP API, e.g. {@code http://prometheus.observability.svc:9090}.
         *
         * <p><b>No default, deliberately.</b> A default pointing at localhost would make an
         * unconfigured deployment look like a running one with nothing to report: the dashboard
         * would render, every panel would be empty, and "the cluster is idle" is indistinguishable
         * from "the query never reached Prometheus". Blank means the feature reports itself
         * unavailable and says why.
         */
        private String prometheusUrl = "";

        /**
         * How long to wait for a query before giving up.
         *
         * <p>Short on purpose. This endpoint is a convenience view; a Prometheus that has become
         * slow must not be able to occupy request threads in the service that serves documents.
         */
        private Duration timeout = Duration.ofSeconds(5);

        /**
         * Window for rate() when turning the CPU counter into cores.
         *
         * <p>Must be several scrape intervals wide or rate() returns nothing at all for a series
         * with too few samples, which presents as a container using exactly zero CPU.
         */
        private Duration cpuWindow = Duration.ofMinutes(5);

        public String getPrometheusUrl() {
            return prometheusUrl;
        }

        public void setPrometheusUrl(String prometheusUrl) {
            this.prometheusUrl = prometheusUrl;
        }

        public Duration getTimeout() {
            return timeout;
        }

        public void setTimeout(Duration timeout) {
            this.timeout = timeout;
        }

        public Duration getCpuWindow() {
            return cpuWindow;
        }

        public void setCpuWindow(Duration cpuWindow) {
            this.cpuWindow = cpuWindow;
        }
    }

    /**
     * Object storage for documents (T-3.7).
     * <p>
     * Every field here describes the <em>S3 API</em>, not a provider. The same settings point at
     * Hetzner Object Storage, MinIO or any other S3-compatible endpoint; nothing in this service
     * may depend on which one is behind it.
     */
    public static class Storage {

        /** Bucket holding uploaded documents. Per environment — see infra/terraform/storage. */
        private String bucket;

        /**
         * S3 endpoint. Required: unlike AWS, every provider this template targets needs one
         * stated explicitly, and defaulting to AWS would send a misconfigured deployment's
         * documents to the wrong company.
         */
        private String endpoint;

        /**
         * Region. Most S3-compatible providers ignore the value but require the signature to
         * carry one, so this is about signing rather than placement.
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
}
