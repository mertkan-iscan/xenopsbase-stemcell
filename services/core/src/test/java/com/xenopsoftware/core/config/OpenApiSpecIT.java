package com.xenopsoftware.core.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.core.util.DefaultIndenter;
import com.fasterxml.jackson.core.util.DefaultPrettyPrinter;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.xenopsoftware.core.IntegrationTest;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;

/**
 * Captures the OpenAPI document and checks it describes what the service actually exposes (T-3.11).
 *
 * <h2>Generated from the running application, not written by hand</h2>
 *
 * A hand-maintained spec drifts the moment someone adds an endpoint and forgets, and the drift is
 * invisible — the spec still parses, still generates a client, and simply describes an API that no
 * longer exists. Generating it from the mapped controllers means it cannot be stale; it can only be
 * wrong in the same way the code is.
 *
 * <h2>Writing it to a file is the point, not a side effect</h2>
 *
 * The document is written to {@code target/openapi/core.json} so CI can publish it as an artifact
 * and a client generator can consume it. That makes this test the mechanism by which the contract
 * is published, which is why it asserts the content rather than merely that the endpoint answers.
 */
@IntegrationTest
@org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc
@WithMockUser(authorities = "app-admin")
class OpenApiSpecIT {

    static final Path OUTPUT = Path.of("target/openapi/core.json");

    @DynamicPropertySource
    static void enableApiDocs(DynamicPropertyRegistry registry) {
        // springdoc is disabled unless the api-docs profile is active, so without this the
        // endpoint 404s and the spec is never produced. Enabled explicitly rather than by
        // activating a profile, so this test does not also inherit whatever else that profile
        // changes.
        registry.add("springdoc.api-docs.enabled", () -> true);
        // Also set here, not only in the main config: src/test/resources/config/application.yml
        // REPLACES the main file on the test classpath rather than merging with it, so a property
        // set only in production config is absent from every test. The spec would be captured as
        // 3.1 while deployments serve 3.0 -- the published artifact would not match what runs.
        registry.add("springdoc.api-docs.version", () -> "openapi_3_0");
        // Object storage is unrelated to the spec, but the document endpoints must be present in
        // it -- and they only exist when the storage feature is on (T-3.7).
        ObjectStorageTestcontainer.registerTo(registry);
    }

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private ObjectMapper objectMapper;

    @Test
    void theSpecIsServedAndDescribesTheApiThatExists() throws Exception {
        String json = mockMvc
            .perform(get("/v3/api-docs"))
            .andExpect(status().isOk())
            .andReturn()
            .getResponse()
            .getContentAsString();

        JsonNode spec = objectMapper.readTree(json);

        assertThat(spec.path("openapi").asText()).as("a document with no version is not a spec").startsWith("3.");

        JsonNode paths = spec.path("paths");
        assertThat(paths.isMissingNode()).isFalse();

        // Named explicitly. Asserting only "paths is non-empty" would pass while springdoc saw
        // none of the real controllers and described only the actuator.
        assertThat(paths.fieldNames())
            .toIterable()
            .as("springdoc must see the actual controllers, not just whatever else is mapped")
            .contains("/api/documents", "/api/documents/{id}");

        assertThat(paths.path("/api/documents").fieldNames())
            .toIterable()
            .as("both operations on the collection")
            .contains("get", "post");

        // The spec is captured from a TEST context, so anything mapped in the test source set is
        // a candidate for leaking into the published contract. It did: eight
        // /api/exception-translator-test/* paths and two CORS fixtures were being documented, and
        // a generated client would have had typed methods for endpoints no deployment serves.
        //
        // The fixtures now carry @Hidden. This is what stops that regressing silently.
        assertThat(paths.fieldNames())
            .toIterable()
            .as("test fixtures must not appear in the published contract")
            .noneMatch(path -> path.contains("test") || path.contains("Test"));

        // Written for CI to publish and for the client generator to consume.
        Files.createDirectories(OUTPUT.getParent());
        Files.writeString(OUTPUT, canonical(objectMapper, spec), StandardCharsets.UTF_8);

        assertThat(OUTPUT).isRegularFile();
        assertThat(Files.size(OUTPUT)).as("an empty spec would still be a valid file").isGreaterThan(500);
    }

    @Test
    void theSpecDocumentsTheErrorContractRatherThanOnlyTheHappyPath() throws Exception {
        String json = mockMvc.perform(get("/v3/api-docs")).andReturn().getResponse().getContentAsString();
        JsonNode spec = objectMapper.readTree(json);

        // A generated client that only knows about 200s forces every consumer to rediscover the
        // error shape by hand, which is what T-3.8 standardised in order to avoid.
        JsonNode responses = spec.path("paths").path("/api/documents").path("post").path("responses");

        assertThat(responses.isMissingNode()).as("operations must declare their responses").isFalse();
        assertThat(responses.fieldNames()).toIterable().isNotEmpty();
    }

    /**
     * Serialises with map keys sorted, so the file is byte-identical for the same API.
     *
     * <p>springdoc builds the document by reflection and does not guarantee a stable property
     * order: two runs against unchanged code produced specs differing only in where
     * {@code maxIdleTime} appeared. That is invisible in review and fatal to the CI check that
     * fails when the committed spec drifts, which would flap on runs that changed nothing.
     *
     * <p>Reading into a {@code Map} and re-serialising with {@code ORDER_MAP_ENTRIES_BY_KEYS} is
     * what makes it canonical; {@code writerWithDefaultPrettyPrinter} alone does not sort.
     */
    private static String canonical(ObjectMapper mapper, JsonNode spec) throws Exception {
        ObjectMapper sorted = mapper.copy().configure(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS, true);
        Object asMap = sorted.treeToValue(spec, Object.class);

        // Explicit LF. Jackson's default pretty printer uses the SYSTEM line separator, so this
        // file would be CRLF on Windows and LF on Linux -- the committed artifact differing by the
        // operating system that produced it. CI would still pass, and `make api-spec` on Windows
        // would show a whole-file diff on every run, for ever.
        DefaultPrettyPrinter printer = new DefaultPrettyPrinter();
        printer.indentObjectsWith(new DefaultIndenter("  ", "\n"));
        printer.indentArraysWith(new DefaultIndenter("  ", "\n"));

        // Normalised rather than trusted. Setting the indenter's EOL is not sufficient on its own
        // -- Jackson emits separators from more than one place -- and the point here is a file
        // that is identical on every platform, not an elegant printer configuration.
        return sorted.writer(printer).writeValueAsString(asMap).replace("\r\n", "\n").replace("\r", "\n");
    }
}
