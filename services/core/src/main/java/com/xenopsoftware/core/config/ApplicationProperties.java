package com.xenopsoftware.core.config;

import com.xenopsoftware.common.storage.ObjectStoreProperties;
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

    private final ObjectStoreProperties storage = new ObjectStoreProperties();
    private final Infra infra = new Infra();
    private final Cache cache = new Cache();

    public Cache getCache() {
        return cache;
    }

    /**
     * Bound here as well as by {@link ObjectStoreProperties} itself, which is not redundant:
     * this class is {@code ignoreUnknownFields = false}, so a property under {@code application.}
     * that nothing here binds fails the context. Dropping this field to "avoid duplication" would
     * mean giving up that strictness, and the strictness is what catches a typo'd flag that would
     * otherwise silently never take effect.
     */
    public ObjectStoreProperties getStorage() {
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
}
