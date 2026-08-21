package com.xenopsoftware.core.service.infra;

import com.fasterxml.jackson.databind.JsonNode;
import com.xenopsoftware.core.config.ApplicationProperties;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

/**
 * Reads container, volume and node usage out of Prometheus (T-3.16).
 *
 * <h2>Fixed queries, not a PromQL passthrough</h2>
 *
 * Proxying the Prometheus query API would be a handful of lines, and would hand the browser
 * arbitrary query execution against the monitoring system — including the expensive kind that
 * takes Prometheus down. It would also put the response shape outside the OpenAPI document, so the
 * generated client (T-3.11) would know nothing about it.
 *
 * <p>The queries below are the contract instead. They are the same ones a person would write by
 * hand, and they live in exactly one place.
 *
 * <h2>Metric names are somebody else's contract</h2>
 *
 * {@code container_memory_working_set_bytes} and its neighbours come from cAdvisor,
 * kube-state-metrics and node-exporter. A chart upgrade can rename or drop one, and the natural
 * failure is a panel that reads zero rather than an error — a container using no memory looks
 * perfectly plausible.
 *
 * <p>So a query that succeeds and matches nothing is recorded by name in
 * {@link Usage#emptyQueries()}. "Prometheus answered, with nothing" and "we never got an answer"
 * must not look the same on a dashboard.
 */
@Service
public class InfraUsageService {

    private static final Logger LOG = LoggerFactory.getLogger(InfraUsageService.class);

    /**
     * Excludes the pause container and the cgroup roll-up series.
     *
     * <p>Without it every pod is counted twice: cAdvisor exports a per-container series and a
     * pod-level one with an empty container label, and summing both silently doubles the total.
     */
    private static final String REAL_CONTAINERS = "container!=\"\",container!=\"POD\"";

    private final ApplicationProperties properties;
    private final RestClient restClient;

    public InfraUsageService(ApplicationProperties properties, RestClient.Builder restClientBuilder) {
        this.properties = properties;
        this.restClient = restClientBuilder.build();
    }

    /** No Prometheus configured. Distinct from unavailable, so the caller can say which. */
    public static class NotConfiguredException extends RuntimeException {

        public NotConfiguredException() {
            super("application.infra.prometheus-url is not set, so infrastructure usage cannot be read");
        }
    }

    /** Configured, but did not answer. */
    public static class UnavailableException extends RuntimeException {

        public UnavailableException(String message, Throwable cause) {
            super(message, cause);
        }
    }

    public boolean isConfigured() {
        return !properties.getInfra().getPrometheusUrl().isBlank();
    }

    // ------------------------------------------------------------------ model

    /**
     * @param cpuCores        cores, so 0.25 is a quarter of one core
     * @param cpuLimitCores   null means no limit is set, which is different from a limit of zero
     */
    public record ContainerUsage(
        String namespace,
        String pod,
        String container,
        Double cpuCores,
        Long memoryBytes,
        Double cpuLimitCores,
        Long memoryLimitBytes
    ) {}

    public record VolumeUsage(String namespace, String claim, Long usedBytes, Long capacityBytes) {}

    public record NodeUsage(String node, Double cpuCores, Double cpuUsedCores, Long memoryTotalBytes, Long memoryUsedBytes) {}

    /**
     * @param emptyQueries names of queries that succeeded and matched nothing — what a renamed
     *                     metric looks like from here
     */
    public record Usage(
        Instant collectedAt,
        List<NodeUsage> nodes,
        List<ContainerUsage> containers,
        List<VolumeUsage> volumes,
        List<String> emptyQueries
    ) {}

    // ------------------------------------------------------------------ query

    public Usage usage() {
        if (!isConfigured()) {
            throw new NotConfiguredException();
        }

        String window = toPromDuration(properties.getInfra().getCpuWindow());
        List<String> empty = new ArrayList<>();

        Map<String, Double> cpu = scalarsBy(
            "container-cpu",
            "sum by (namespace, pod, container) (rate(container_cpu_usage_seconds_total{" + REAL_CONTAINERS + "}[" + window + "]))",
            InfraUsageService::containerKey,
            empty
        );
        Map<String, Double> memory = scalarsBy(
            "container-memory",
            "sum by (namespace, pod, container) (container_memory_working_set_bytes{" + REAL_CONTAINERS + "})",
            InfraUsageService::containerKey,
            empty
        );
        Map<String, Double> cpuLimit = scalarsBy(
            "container-cpu-limit",
            "sum by (namespace, pod, container) (kube_pod_container_resource_limits{resource=\"cpu\"})",
            InfraUsageService::containerKey,
            empty
        );
        Map<String, Double> memoryLimit = scalarsBy(
            "container-memory-limit",
            "sum by (namespace, pod, container) (kube_pod_container_resource_limits{resource=\"memory\"})",
            InfraUsageService::containerKey,
            empty
        );

        // The UNION of keys, not just the ones with a CPU sample. A container with memory and no
        // CPU rate is still running, and dropping it would hide precisely the container that is
        // wedged doing nothing.
        List<String> keys = new ArrayList<>(cpu.keySet());
        for (String key : memory.keySet()) {
            if (!keys.contains(key)) {
                keys.add(key);
            }
        }

        Map<String, ContainerUsage> containers = new LinkedHashMap<>();
        for (String key : keys) {
            String[] parts = key.split("/", 3);
            if (parts.length < 3) {
                continue;
            }
            containers.put(
                key,
                new ContainerUsage(
                    parts[0],
                    parts[1],
                    parts[2],
                    cpu.get(key),
                    asLong(memory.get(key)),
                    cpuLimit.get(key),
                    asLong(memoryLimit.get(key))
                )
            );
        }

        Map<String, Double> volumeUsed = scalarsBy(
            "volume-used",
            "sum by (namespace, persistentvolumeclaim) (kubelet_volume_stats_used_bytes)",
            metric -> label(metric, "namespace") + "/" + label(metric, "persistentvolumeclaim"),
            empty
        );
        Map<String, Double> volumeCapacity = scalarsBy(
            "volume-capacity",
            "sum by (namespace, persistentvolumeclaim) (kubelet_volume_stats_capacity_bytes)",
            metric -> label(metric, "namespace") + "/" + label(metric, "persistentvolumeclaim"),
            empty
        );
        List<VolumeUsage> volumes = new ArrayList<>();
        volumeUsed.forEach((key, used) -> {
            String[] parts = key.split("/", 2);
            volumes.add(new VolumeUsage(parts[0], parts.length > 1 ? parts[1] : "", asLong(used), asLong(volumeCapacity.get(key))));
        });

        Map<String, Double> nodeCpu = scalarsBy(
            "node-cpu",
            "count by (instance) (node_cpu_seconds_total{mode=\"idle\"})",
            metric -> label(metric, "instance"),
            empty
        );
        Map<String, Double> nodeCpuUsed = scalarsBy(
            "node-cpu-used",
            "sum by (instance) (1 - rate(node_cpu_seconds_total{mode=\"idle\"}[" + window + "]))",
            metric -> label(metric, "instance"),
            empty
        );
        Map<String, Double> nodeMemTotal = scalarsBy(
            "node-memory-total",
            "sum by (instance) (node_memory_MemTotal_bytes)",
            metric -> label(metric, "instance"),
            empty
        );
        Map<String, Double> nodeMemAvailable = scalarsBy(
            "node-memory-available",
            "sum by (instance) (node_memory_MemAvailable_bytes)",
            metric -> label(metric, "instance"),
            empty
        );

        List<NodeUsage> nodes = new ArrayList<>();
        nodeMemTotal.forEach((instance, total) -> {
            Double available = nodeMemAvailable.get(instance);
            nodes.add(
                new NodeUsage(
                    instance,
                    nodeCpu.get(instance),
                    nodeCpuUsed.get(instance),
                    asLong(total),
                    available == null ? null : asLong(total - available)
                )
            );
        });

        return new Usage(Instant.now(), nodes, new ArrayList<>(containers.values()), volumes, empty);
    }

    // ------------------------------------------------------------- plumbing

    private static String containerKey(JsonNode metric) {
        return label(metric, "namespace") + "/" + label(metric, "pod") + "/" + label(metric, "container");
    }

    private static String label(JsonNode metric, String name) {
        JsonNode value = metric.path(name);
        return value.isMissingNode() ? "" : value.asText();
    }

    private static Long asLong(Double value) {
        return value == null ? null : Math.round(value);
    }

    /**
     * Runs one instant query and reduces it to key to value.
     *
     * <p>A query that matches nothing records its name in {@code empty} rather than returning an
     * empty map that the caller cannot tell apart from a metric that genuinely reads zero.
     */
    private Map<String, Double> scalarsBy(String name, String query, Function<JsonNode, String> keyOf, List<String> empty) {
        JsonNode body;
        try {
            body = restClient
                .get()
                .uri(properties.getInfra().getPrometheusUrl() + "/api/v1/query?query={q}", query)
                .retrieve()
                .body(JsonNode.class);
        } catch (RuntimeException e) {
            LOG.warn("infra usage query '{}' failed: {}", name, e.getMessage());
            throw new UnavailableException("Prometheus query '" + name + "' failed", e);
        }

        if (body == null || !"success".equals(body.path("status").asText())) {
            throw new UnavailableException("Prometheus returned a non-success status for '" + name + "'", null);
        }

        Map<String, Double> out = new LinkedHashMap<>();
        for (JsonNode result : body.path("data").path("result")) {
            String key = keyOf.apply(result.path("metric"));
            JsonNode value = result.path("value");
            if (value.isArray() && value.size() == 2) {
                try {
                    out.put(key, Double.parseDouble(value.get(1).asText()));
                } catch (NumberFormatException ignored) {
                    // Prometheus renders NaN and +Inf as strings. Skipping them is correct; they
                    // are not values, and they are not errors either.
                }
            }
        }
        if (out.isEmpty()) {
            empty.add(name);
        }
        return out;
    }

    /** Prometheus wants {@code 5m}; {@link Duration#toString()} gives {@code PT5M}. */
    private static String toPromDuration(Duration duration) {
        long seconds = Math.max(1, duration.toSeconds());
        return seconds % 60 == 0 ? (seconds / 60) + "m" : seconds + "s";
    }
}
