package com.xenopsoftware.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers.mockJwt;
import static org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers.mockUser;
import static org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers.springSecurity;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.xenopsoftware.gateway.IntegrationTest;
import com.xenopsoftware.gateway.security.AuthoritiesConstants;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.ApplicationContext;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.reactive.server.WebTestClient;

/**
 * Captures the gateway's OpenAPI document (T-3.11).
 *
 * <p>Worth having separately from core's, and not only for symmetry. The gateway runs WebFlux, so
 * it uses a different springdoc starter entirely — and that starter was pinned to the 2.x line,
 * built against Spring Framework 6, while this service runs Boot 4 on Framework 7. A version
 * mismatch of that kind does not fail the build; it fails at runtime, on an endpoint nothing was
 * asserting. This test is what makes that visible.
 */
@IntegrationTest
@TestPropertySource(
    properties = {
        // springdoc is off unless the api-docs profile is active. Enabled directly so the test
        // does not inherit everything else that profile changes.
        "springdoc.api-docs.enabled=true",
    }
)
class OpenApiSpecIT {

    static final Path OUTPUT = Path.of("target/openapi/gateway.json");

    @Autowired
    private ApplicationContext context;

    @Autowired
    private ObjectMapper objectMapper;

    private WebTestClient webTestClient;

    @BeforeEach
    void setUp() {
        webTestClient = WebTestClient.bindToApplicationContext(context).apply(springSecurity()).configureClient().build();
    }

    @Test
    void theSpecIsServedAndWrittenForPublication() throws Exception {
        // /v3/api-docs requires the admin authority — the spec names every endpoint, which is a
        // map of the attack surface, so it is not public by default.
        byte[] body = webTestClient
            // mockJwt, not mockUser: this service authenticates bearer tokens, and its authority
            // mapping runs over JWT claims. A mock user carries authorities the resource-server
            // filter chain never consults, which presents as 403 for a caller that looks like an
            // admin in the test and is not one to the application.
            .mutateWith(mockJwt().authorities(new SimpleGrantedAuthority(AuthoritiesConstants.ADMIN)))
            .get()
            .uri("/v3/api-docs")
            .exchange()
            .expectStatus()
            .isOk()
            .expectBody()
            .returnResult()
            .getResponseBody();

        assertThat(body).as("an empty body is not a spec").isNotNull().isNotEmpty();

        JsonNode spec = objectMapper.readTree(body);
        assertThat(spec.path("openapi").asText()).startsWith("3.");
        assertThat(spec.path("paths").isMissingNode()).isFalse();

        Files.createDirectories(OUTPUT.getParent());
        Files.writeString(OUTPUT, objectMapper.writerWithDefaultPrettyPrinter().writeValueAsString(spec), StandardCharsets.UTF_8);
    }

    @Test
    void theSpecIsNotReadableWithoutTheAdminAuthority() {
        // The document lists every route, parameter and schema. Serving it unauthenticated hands
        // an attacker the map before they have to look for it.
        webTestClient.mutateWith(mockUser()).get().uri("/v3/api-docs").exchange().expectStatus().isForbidden();
    }
}
