package com.xenopsoftware.gateway.web.filter;

import com.xenopsoftware.gateway.IntegrationTest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.ApplicationContext;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.test.web.reactive.server.WebTestClient;

/**
 * How an unauthenticated request is refused (T-3.8).
 *
 * <p>The behaviour under test was a real defect, recorded during T-3.2. {@code oauth2Login}
 * installs a redirecting entry point, so an API client received 302, followed it, was served the
 * Keycloak login page, and got <b>200 OK with a body of HTML</b>. No error status and no error
 * body — a client checking the status code concludes the call worked.
 *
 * <p>Both directions are asserted. A test that only checked "API clients get 401" would still pass
 * if the browser redirect had been broken in the process, and losing interactive login is not a
 * better outcome than the bug being fixed.
 */
@IntegrationTest
class UnauthenticatedRequestIT {

    @Autowired
    private ApplicationContext context;

    private WebTestClient webTestClient;

    @BeforeEach
    void setUp() {
        // No mutateWith(mockUser): the whole point is what happens with no credentials at all.
        webTestClient = WebTestClient.bindToApplicationContext(context).configureClient().build();
    }

    @Test
    void anApiClientGetsAProblemDetailRatherThanARedirectToALoginPage() {
        webTestClient
            .get()
            .uri("/api/documents")
            .accept(MediaType.APPLICATION_JSON)
            .exchange()
            .expectStatus()
            .isUnauthorized()
            // RFC 9110: a 401 without this is not a well-formed 401.
            .expectHeader()
            .valueMatches(HttpHeaders.WWW_AUTHENTICATE, "Bearer.*")
            .expectHeader()
            .contentTypeCompatibleWith(MediaType.APPLICATION_PROBLEM_JSON)
            .expectBody()
            .jsonPath("$.status")
            .isEqualTo(401)
            .jsonPath("$.title")
            .isEqualTo("Unauthorized")
            .jsonPath("$.instance")
            .isEqualTo("/api/documents");
    }

    @Test
    void aClientStatingNoPreferenceIsTreatedAsAnApiClient() {
        // curl sends Accept: *_/_* by default. Redirecting it to a login page would produce the
        // original bug for the most common debugging tool there is.
        webTestClient.get().uri("/api/documents").exchange().expectStatus().isUnauthorized();
    }

    @Test
    void aBrowserNavigationStillRedirectsToLogin() {
        webTestClient
            .get()
            .uri("/api/documents")
            .accept(MediaType.TEXT_HTML)
            .exchange()
            .expectStatus()
            .isFound()
            .expectHeader()
            .value(HttpHeaders.LOCATION, location -> org.assertj.core.api.Assertions.assertThat(location).contains("/oauth2/authorization"));
    }

    @Test
    void everyResponseCarriesACorrelationIdWhetherOrNotTheCallerSuppliedOne() {
        webTestClient
            .get()
            .uri("/api/documents")
            .exchange()
            .expectHeader()
            .value(CorrelationId.HEADER, id -> org.assertj.core.api.Assertions.assertThat(id).isNotBlank());

        // A supplied id is adopted, so one request has one id end to end rather than a new one
        // per hop.
        webTestClient
            .get()
            .uri("/api/documents")
            .header(CorrelationId.HEADER, "caller-supplied-id")
            .exchange()
            .expectHeader()
            .valueEquals(CorrelationId.HEADER, "caller-supplied-id");
    }

    @Test
    void aForgedCorrelationIdIsReplacedRatherThanEchoed() {
        // The value lands in every log line. Echoing a newline back would let a caller write
        // fabricated log entries.
        webTestClient
            .get()
            .uri("/api/documents")
            .header(CorrelationId.HEADER, "bad id with spaces and \"quotes\"")
            .exchange()
            .expectHeader()
            .value(CorrelationId.HEADER, id ->
                org.assertj.core.api.Assertions.assertThat(id).doesNotContain(" ").doesNotContain("\"").hasSize(32)
            );
    }
}
