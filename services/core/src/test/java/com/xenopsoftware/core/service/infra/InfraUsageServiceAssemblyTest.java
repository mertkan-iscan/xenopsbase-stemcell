package com.xenopsoftware.core.service.infra;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.anything;

import com.xenopsoftware.core.config.ApplicationProperties;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.mock.http.client.MockClientHttpResponse;
import org.springframework.test.web.client.ExpectedCount;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.test.web.client.ResponseCreator;
import org.springframework.web.client.RestClient;

/**
 * What {@link InfraUsageService} builds when Prometheus answers with data.
 *
 * <p>{@link InfraUsageServiceTest} covers the failure paths; this covers the assembly, which is the
 * other half of the same class and where the remaining branches are: the union of CPU and memory
 * keys, resolving a pod's node from the one series that carries a node NAME, and pairing volume
 * usage with capacity.
 *
 * <p>Each query gets its OWN response, chosen by inspecting the PromQL rather than by expecting the
 * queries in a fixed order. Order-dependent stubs break when a query is added in the middle and
 * blame the wrong thing.
 */
class InfraUsageServiceAssemblyTest {

    private static final String CONTAINER_CPU = """
        {"status":"success","data":{"result":[
          {"metric":{"namespace":"apps","pod":"core-1","container":"core"},"value":[1,"0.25"]}
        ]}}""";

    /** A SECOND container, present in memory only: it has no CPU rate but is certainly running. */
    private static final String CONTAINER_MEMORY = """
        {"status":"success","data":{"result":[
          {"metric":{"namespace":"apps","pod":"core-1","container":"core"},"value":[1,"536870912"]},
          {"metric":{"namespace":"apps","pod":"idle-1","container":"idle"},"value":[1,"1048576"]}
        ]}}""";

    private static final String POD_NODE = """
        {"status":"success","data":{"result":[
          {"metric":{"namespace":"apps","pod":"core-1","node":"worker-0"},"value":[1,"1"]},
          {"metric":{"namespace":"apps","pod":"idle-1","node":"worker-1"},"value":[1,"1"]}
        ]}}""";

    private static final String VOLUME_USED = """
        {"status":"success","data":{"result":[
          {"metric":{"namespace":"database","persistentvolumeclaim":"postgres-1"},"value":[1,"1073741824"]}
        ]}}""";

    private static final String VOLUME_CAPACITY = """
        {"status":"success","data":{"result":[
          {"metric":{"namespace":"database","persistentvolumeclaim":"postgres-1"},"value":[1,"10737418240"]}
        ]}}""";

    private static final String EMPTY = """
        {"status":"success","data":{"result":[]}}""";

    /** Answers by what the query asks for, so adding a query cannot silently shift the fixtures. */
    private static ResponseCreator byQuery() {
        return request -> {
            String q = URLDecoder.decode(request.getURI().getRawQuery(), StandardCharsets.UTF_8);
            String body;
            if (q.contains("container_cpu_usage_seconds_total")) {
                body = CONTAINER_CPU;
            } else if (q.contains("container_memory_working_set_bytes")) {
                body = CONTAINER_MEMORY;
            } else if (q.contains("kube_pod_info")) {
                body = POD_NODE;
            } else if (q.contains("kubelet_volume_stats_used_bytes")) {
                body = VOLUME_USED;
            } else if (q.contains("kubelet_volume_stats_capacity_bytes")) {
                body = VOLUME_CAPACITY;
            } else {
                body = EMPTY;
            }
            MockClientHttpResponse response = new MockClientHttpResponse(body.getBytes(StandardCharsets.UTF_8), HttpStatus.OK);
            response.getHeaders().setContentType(MediaType.APPLICATION_JSON);
            return response;
        };
    }

    private InfraUsageService.Usage usage() {
        RestClient.Builder builder = RestClient.builder();
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(ExpectedCount.manyTimes(), anything()).andRespond(byQuery());

        ApplicationProperties properties = new ApplicationProperties();
        properties.getInfra().setPrometheusUrl("http://prom:9090");
        return new InfraUsageService(properties, builder).usage();
    }

    /**
     * The union, not the intersection. A container with memory and no CPU rate is still running,
     * and dropping it would hide precisely the container that is wedged doing nothing, which the
     * service's own comment calls out.
     */
    @Test
    void aContainerWithMemoryButNoCpuIsStillListed() {
        InfraUsageService.Usage usage = usage();

        assertThat(usage.containers()).extracting(InfraUsageService.ContainerUsage::pod).contains("core-1", "idle-1");
    }

    /** kube_pod_info is the only series carrying a node NAME; the rest identify a node by scrape target. */
    @Test
    void aPodIsPlacedOnTheNodeNameRatherThanAScrapeTarget() {
        InfraUsageService.Usage usage = usage();

        assertThat(usage.containers())
            .filteredOn(c -> "core-1".equals(c.pod()))
            .singleElement()
            .satisfies(c -> {
                assertThat(c.node()).isEqualTo("worker-0");
                assertThat(c.cpuCores()).isEqualTo(0.25);
                assertThat(c.memoryBytes()).isEqualTo(536870912L);
            });
    }

    /** Used and capacity arrive from separate queries and have to be paired by claim. */
    @Test
    void volumeUsageIsPairedWithItsCapacity() {
        InfraUsageService.Usage usage = usage();

        assertThat(usage.volumes())
            .singleElement()
            .satisfies(v -> {
                assertThat(v.namespace()).isEqualTo("database");
                assertThat(v.claim()).isEqualTo("postgres-1");
                assertThat(v.usedBytes()).isEqualTo(1073741824L);
                assertThat(v.capacityBytes()).isEqualTo(10737418240L);
            });
    }

    /**
     * The queries that returned nothing are still named, even on a run where others returned data.
     * A partly-empty answer is the case most likely to be read as "the cluster is idle".
     */
    @Test
    void queriesThatMatchedNothingAreStillNamedOnAPartialAnswer() {
        InfraUsageService.Usage usage = usage();

        assertThat(usage.containers()).isNotEmpty();
        assertThat(usage.emptyQueries()).as("the node queries returned nothing here").isNotEmpty();
    }
}
