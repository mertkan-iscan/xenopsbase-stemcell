package com.xenopsoftware.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers.mockJwt;
import static org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers.mockUser;
import static org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers.springSecurity;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.core.util.DefaultIndenter;
import com.fasterxml.jackson.core.util.DefaultPrettyPrinter;
import com.fasterxml.jackson.databind.SerializationFeature;
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
        // Set here too: the test config replaces the main file rather than merging, so a property
        // set only in production config never reaches a test. Without it the captured spec is 3.1
        // while deployments serve 3.0.
        "springdoc.api-docs.version=openapi_3_0",
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
        Files.writeString(OUTPUT, canonical(objectMapper, spec), StandardCharsets.UTF_8);
    }

    @Test
    void theSpecIsNotReadableWithoutTheAdminAuthority() {
        // The document lists every route, parameter and schema. Serving it unauthenticated hands
        // an attacker the map before they have to look for it.
        webTestClient.mutateWith(mockUser()).get().uri("/v3/api-docs").exchange().expectStatus().isForbidden();
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
