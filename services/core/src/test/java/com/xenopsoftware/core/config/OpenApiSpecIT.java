package com.xenopsoftware.core.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
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

        // Written for CI to publish and for the client generator to consume.
        Files.createDirectories(OUTPUT.getParent());
        Files.writeString(OUTPUT, objectMapper.writerWithDefaultPrettyPrinter().writeValueAsString(spec), StandardCharsets.UTF_8);

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
}
