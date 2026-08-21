package com.xenopsoftware.gateway.web.rest;

import static com.xenopsoftware.gateway.test.util.OAuth2TestUtil.ID_TOKEN;
import static com.xenopsoftware.gateway.test.util.OAuth2TestUtil.authenticationToken;
import static com.xenopsoftware.gateway.test.util.OAuth2TestUtil.registerAuthenticationToken;
import static org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers.*;

import com.xenopsoftware.gateway.IntegrationTest;
import com.xenopsoftware.gateway.security.AuthoritiesConstants;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.ApplicationContext;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.security.oauth2.client.ReactiveOAuth2AuthorizedClientService;
import org.springframework.security.oauth2.client.registration.ClientRegistration;
import org.springframework.security.oauth2.client.registration.ReactiveClientRegistrationRepository;
import org.springframework.test.web.reactive.server.WebTestClient;

/**
 * Integration tests for the {@link LogoutResource} REST controller.
 */
@IntegrationTest
class LogoutResourceIT {

    @Autowired
    private ReactiveClientRegistrationRepository registrations;

    @Autowired
    private ApplicationContext context;

    @Autowired
    private ReactiveOAuth2AuthorizedClientService authorizedClientService;

    @Autowired
    private ClientRegistration clientRegistration;

    private WebTestClient webTestClient;

    private Map<String, Object> claims;

    @BeforeEach
    void before() {
        claims = new HashMap<>();
        claims.put("groups", List.of(AuthoritiesConstants.USER));
        claims.put("sub", 123);

        this.webTestClient = WebTestClient.bindToApplicationContext(this.context).apply(springSecurity()).configureClient().build();
    }

    private static final String ORIGIN_URL = "http://localhost:8080";

    private String expectedLogoutUrl() {
        String endSession = this.registrations
            .findByRegistrationId("oidc")
            .map(oidc -> oidc.getProviderDetails().getConfigurationMetadata().get("end_session_endpoint").toString())
            .block();
        return endSession + "?id_token_hint=" + ID_TOKEN + "&post_logout_redirect_uri=" + ORIGIN_URL;
    }

    /**
     * NO Origin header, deliberately.
     *
     * <p>This used to send one, and passing meant only that the header had been echoed back.
     * Without it the endpoint returned {@code post_logout_redirect_uri=null} -- the literal
     * string -- and Keycloak rejected it with the same "Invalid redirect uri" a missing
     * registration produces, one hop from the gateway that built it.
     *
     * <p>A browser always sends Origin on a POST, so no browser could reach the broken path.
     * Everything else does: the generated client in T-3.11, the smoke suite in T-5.5, any
     * scripted teardown. Sending the header here reproduced the one case that already worked.
     */
    @Test
    void getLogoutInformationWithoutAnOriginHeader() {
        this.webTestClient
            .mutateWith(csrf())
            .mutateWith(
                mockAuthentication(registerAuthenticationToken(authorizedClientService, clientRegistration, authenticationToken(claims)))
            )
            .post()
            .uri(ORIGIN_URL + "/api/logout")
            .exchange()
            .expectStatus()
            .isOk()
            .expectHeader()
            .contentType(MediaType.APPLICATION_JSON_VALUE)
            .expectBody()
            .jsonPath("$.logoutUrl")
            .isEqualTo(expectedLogoutUrl());
    }

    /**
     * The caller does not get to choose where logout lands.
     *
     * <p>The redirect target is now derived from the request rather than read from the header,
     * so an Origin the caller invented is ignored. Asserting that it is ignored, rather than
     * merely that the happy path works, is what stops the header being reintroduced as a
     * convenience later: post_logout_redirect_uri is a value Keycloak will redirect a browser
     * to, and letting a caller supply it is the shape of an open redirect.
     */
    @Test
    void ignoresAnOriginSuppliedByTheCaller() {
        this.webTestClient
            .mutateWith(csrf())
            .mutateWith(
                mockAuthentication(registerAuthenticationToken(authorizedClientService, clientRegistration, authenticationToken(claims)))
            )
            .post()
            .uri(ORIGIN_URL + "/api/logout")
            .header(HttpHeaders.ORIGIN, "https://attacker.example.com")
            .exchange()
            .expectStatus()
            .isOk()
            .expectBody()
            .jsonPath("$.logoutUrl")
            .isEqualTo(expectedLogoutUrl());
    }
}
