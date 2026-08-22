package com.xenopsoftware.core.web.rest;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.xenopsoftware.core.CoreApp;
import com.xenopsoftware.core.config.AsyncSyncConfiguration;
import com.xenopsoftware.core.config.DatabaseTestcontainer;
import com.xenopsoftware.core.config.JacksonConfiguration;
import com.xenopsoftware.core.config.KeycloakTestcontainer;
import com.xenopsoftware.core.config.ObjectStorageTestcontainer;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Base64;
import java.util.Map;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.http.HttpHeaders;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

/**
 * Authorization against a real identity provider (T-4.2).
 *
 * <p><b>Deliberately does not import {@code TestSecurityConfiguration}.</b> That is the whole point:
 * it mocks {@code JwtDecoder}, and every other integration test in this service authenticates
 * against nothing as a result. Here the token is minted by Keycloak, signed by Keycloak's key,
 * carries the {@code aud} its protocol mapper adds and the realm roles the realm declares, and is
 * validated by the application's real decoder.
 *
 * <p>Everything asserted below would pass against a mock regardless of whether it were true.
 */
// The audience has to be set, and its absence is itself a finding.
//
// src/main/resources/config/application.yml declares `jhipster.security.oauth2.audience` and
// explains that it must match what Keycloak issues. The TEST profile declares none, and nothing
// noticed, because a mocked JwtDecoder never builds an AudienceValidator. The first run against a
// real Keycloak failed at startup with "Allowed audience should not be null or empty" -- a gap that
// had been sitting in the test configuration for as long as the mock had.
@TestPropertySource(properties = { "jhipster.security.oauth2.audience[0]=account", "jhipster.security.oauth2.audience[1]=gateway" })
@SpringBootTest(classes = { CoreApp.class, JacksonConfiguration.class, AsyncSyncConfiguration.class })
@AutoConfigureMockMvc
@ImportTestcontainers({ DatabaseTestcontainer.class, KeycloakTestcontainer.class })
class RealTokenAuthorizationIT {

    private static final String PASSWORD = "smoke-dev-only";

    /**
     * ObjectStorageTestcontainer is a static registrar, not an @ImportTestcontainers interface like
     * the other two. Importing it does nothing: the container never starts and the storage
     * properties are never registered, which leaves this context configured to talk to real AWS.
     * That is how the first version of this test broke DocumentResourceIT rather than itself.
     */
    @DynamicPropertySource
    static void objectStorage(DynamicPropertyRegistry registry) {
        ObjectStorageTestcontainer.registerTo(registry);
    }

    @Autowired
    private MockMvc mvc;

    /** A real password grant against the realm's own automation client. */
    private static String tokenFor(String username) throws Exception {
        String body =
            "grant_type=password&client_id=" +
            KeycloakTestcontainer.TEST_CLIENT_ID +
            "&username=" +
            username +
            "&password=" +
            PASSWORD;

        HttpResponse<String> response = HttpClient
            .newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build()
            .send(
                HttpRequest
                    .newBuilder(URI.create(KeycloakTestcontainer.issuerUri() + "/protocol/openid-connect/token"))
                    .header("Content-Type", "application/x-www-form-urlencoded")
                    .POST(HttpRequest.BodyPublishers.ofString(body))
                    .build(),
                HttpResponse.BodyHandlers.ofString()
            );

        assertThat(response.statusCode()).as("token endpoint rejected the grant: %s", response.body()).isEqualTo(200);

        @SuppressWarnings("unchecked")
        Map<String, Object> json = new tools.jackson.databind.ObjectMapper().readValue(response.body(), Map.class);
        return (String) json.get("access_token");
    }

    private static Map<String, Object> claimsOf(String jwt) {
        String payload = new String(Base64.getUrlDecoder().decode(jwt.split("\\.")[1]), StandardCharsets.UTF_8);
        @SuppressWarnings("unchecked")
        Map<String, Object> claims = new tools.jackson.databind.ObjectMapper().readValue(payload, Map.class);
        return claims;
    }

    @Test
    @DisplayName("the realm issues a token carrying the aud that AudienceValidator requires")
    void tokenCarriesTheExpectedAudience() throws Exception {
        Map<String, Object> claims = claimsOf(tokenFor("smoke"));

        // The defect this catches: Keycloak adds no audience by itself. Without the protocol mapper
        // the realm declares, every service validating `aud` rejects a token that is otherwise
        // perfectly valid -- and a mocked decoder never notices.
        assertThat(claims.get("aud").toString()).contains("gateway");
    }

    @Test
    @DisplayName("the realm issues realm_access.roles, which is where authorities come from")
    void tokenCarriesRealmRoles() throws Exception {
        Map<String, Object> claims = claimsOf(tokenFor("smoke-admin"));

        // The defect this catches: declaring defaultClientScopes REPLACES the realm defaults, so
        // omitting `roles` drops realm_access entirely and every authority check silently sees a
        // user with no roles.
        assertThat(claims.get("realm_access").toString()).contains("app-admin").contains("app-user");
    }

    @Test
    @DisplayName("a real user token reaches an authenticated endpoint")
    void realUserTokenIsAccepted() throws Exception {
        mvc
            .perform(get("/api/example-items").header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("smoke")))
            .andExpect(status().isOk());
    }

    @Test
    @DisplayName("a real user token is REFUSED the admin endpoint")
    void realUserTokenIsRefusedAdmin() throws Exception {
        mvc
            .perform(get("/api/admin/example-items").header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("smoke")))
            .andExpect(status().isForbidden());
    }

    @Test
    @DisplayName("a real admin token reaches the admin endpoint, so the rule is not denying everyone")
    void realAdminTokenReachesAdmin() throws Exception {
        mvc
            .perform(get("/api/admin/example-items").header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor("smoke-admin")))
            .andExpect(status().isOk());
    }

    @Test
    @DisplayName("a forged token is refused - the assertion a mocked decoder cannot make")
    void forgedTokenIsRefused() throws Exception {
        String forged = tokenFor("smoke-admin") + "tampered";

        mvc
            .perform(get("/api/admin/example-items").header(HttpHeaders.AUTHORIZATION, "Bearer " + forged))
            .andExpect(status().isUnauthorized());
    }
}
