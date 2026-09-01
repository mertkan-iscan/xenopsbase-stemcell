package com.xenopsoftware.core.service.infra;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.anything;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withServerError;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

import com.xenopsoftware.core.config.ApplicationProperties;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.ExpectedCount;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

/**
 * The error paths of {@link InfraUsageService}, which are the reason it exists.
 *
 * <p>{@link InfraUsageResourceIT} already covers the endpoint answering with real data. What was
 * covered by nothing is everything this service does when Prometheus does not behave: 2 of its 46
 * branches were taken before this class. That inversion — the happy path tested, the failure paths
 * not — is exactly what T-5.9 (#172) says to go after, and it is the shape of this project's
 * defects: an archive that never archived, alerts routed nowhere.
 *
 * <p>These are unit tests with a stubbed Prometheus rather than integration tests, because every
 * branch below is reachable without a container and none of them is about wiring.
 */
class InfraUsageServiceTest {

    private static final String EMPTY_VECTOR = """
        {"status":"success","data":{"resultType":"vector","result":[]}}""";

    private ApplicationProperties propertiesWithUrl(String url) {
        ApplicationProperties properties = new ApplicationProperties();
        properties.getInfra().setPrometheusUrl(url);
        return properties;
    }

    /**
     * Blank URL is the shipped default, and it must be distinguishable from a configured Prometheus
     * that answered with nothing — the property's own javadoc is about that distinction.
     */
    @Test
    void unconfiguredReportsItselfRatherThanQuerying() {
        RestClient.Builder builder = RestClient.builder();
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        InfraUsageService service = new InfraUsageService(propertiesWithUrl(""), builder);

        assertThat(service.isConfigured()).isFalse();
        assertThatThrownBy(service::usage).isInstanceOf(InfraUsageService.NotConfiguredException.class);

        // The point of the branch: it must not have asked anyone.
        server.verify();
    }

    /** Prometheus reachable but answering 500. */
    @Test
    void aFailedQueryIsUnavailableRatherThanEmpty() {
        RestClient.Builder builder = RestClient.builder();
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(ExpectedCount.manyTimes(), anything()).andRespond(withServerError());

        InfraUsageService service = new InfraUsageService(propertiesWithUrl("http://prom:9090"), builder);

        assertThatThrownBy(service::usage).isInstanceOf(InfraUsageService.UnavailableException.class).hasMessageContaining("failed");
    }

    /**
     * A 200 carrying {@code status: error}. Treating this as "no data" would render an idle-looking
     * cluster from a query that did not run, which is the failure this service is written against.
     */
    @Test
    void aNonSuccessBodyIsUnavailableRatherThanEmpty() {
        RestClient.Builder builder = RestClient.builder();
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(ExpectedCount.manyTimes(), anything()).andRespond(
            withSuccess(
                """
                {"status":"error","errorType":"bad_data","error":"parse error"}""",
                MediaType.APPLICATION_JSON
            )
        );

        InfraUsageService service = new InfraUsageService(propertiesWithUrl("http://prom:9090"), builder);

        assertThatThrownBy(service::usage).isInstanceOf(InfraUsageService.UnavailableException.class).hasMessageContaining("non-success");
    }

    /**
     * Every query succeeds and matches nothing. The tables are empty AND every query is named in
     * emptyQueries — "Prometheus answered, with nothing" reported as itself rather than as an idle
     * cluster.
     */
    @Test
    void queriesThatMatchNothingAreNamedRatherThanRenderedAsIdle() {
        RestClient.Builder builder = RestClient.builder();
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(ExpectedCount.manyTimes(), anything()).andRespond(withSuccess(EMPTY_VECTOR, MediaType.APPLICATION_JSON));

        InfraUsageService service = new InfraUsageService(propertiesWithUrl("http://prom:9090"), builder);

        InfraUsageService.Usage usage = service.usage();

        assertThat(usage.containers()).isEmpty();
        assertThat(usage.volumes()).isEmpty();
        assertThat(usage.nodes()).isEmpty();
        assertThat(usage.emptyQueries()).as("a query that matched nothing must say so by name").isNotEmpty().contains("container-cpu");
    }

    /**
     * Prometheus renders NaN and +Inf as strings. Skipping them is correct — they are not values,
     * and they are not errors either, so neither a throw nor a zero is the right answer.
     */
    @Test
    void nonNumericSamplesAreSkippedWithoutFailing() {
        RestClient.Builder builder = RestClient.builder();
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(ExpectedCount.manyTimes(), anything()).andRespond(
            withSuccess(
                """
                {"status":"success","data":{"resultType":"vector","result":[
                  {"metric":{"namespace":"apps","pod":"core-1","container":"core"},"value":[1,"NaN"]},
                  {"metric":{"namespace":"apps","pod":"core-1","container":"core"},"value":[1,"+Inf"]}
                ]}}""",
                MediaType.APPLICATION_JSON
            )
        );

        InfraUsageService service = new InfraUsageService(propertiesWithUrl("http://prom:9090"), builder);

        InfraUsageService.Usage usage = service.usage();

        assertThat(usage.containers()).as("NaN and +Inf are not usable samples").isEmpty();
        assertThat(usage.emptyQueries()).isNotEmpty();
    }
}
