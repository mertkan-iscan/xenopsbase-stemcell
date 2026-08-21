package com.xenopsoftware.gateway.web.rest;

import java.util.Map;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.core.annotation.CurrentSecurityContext;
import org.springframework.security.oauth2.client.authentication.OAuth2AuthenticationToken;
import org.springframework.security.oauth2.client.registration.ClientRegistration;
import org.springframework.security.oauth2.client.registration.ReactiveClientRegistrationRepository;
import org.springframework.security.oauth2.core.oidc.OidcIdToken;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.WebSession;
import org.springframework.web.util.UriComponentsBuilder;
import reactor.core.publisher.Mono;

/**
 * REST controller for managing global OIDC logout.
 */
@RestController
public class LogoutResource {

    private final ReactiveClientRegistrationRepository registrationRepository;

    public LogoutResource(ReactiveClientRegistrationRepository registrationRepository) {
        this.registrationRepository = registrationRepository;
    }

    /**
     * {@code POST  /api/logout} : logout the current user.
     *
     * @param oAuth2AuthenticationToken the OAuth2 authentication token.
     * @param oidcUser the OIDC user.
     * @param request a {@link ServerHttpRequest} request.
     * @param session the current {@link WebSession}.
     * @return status {@code 200 (OK)} and a body with a global logout URL.
     */
    @PostMapping("/api/logout")
    public Mono<Map<String, String>> logout(
        @CurrentSecurityContext(expression = "authentication") OAuth2AuthenticationToken oAuth2AuthenticationToken,
        @AuthenticationPrincipal OidcUser oidcUser,
        ServerHttpRequest request,
        WebSession session
    ) {
        return session
            .invalidate()
            .then(
                registrationRepository
                    .findByRegistrationId(oAuth2AuthenticationToken.getAuthorizedClientRegistrationId())
                    .map(oidc -> prepareLogoutUri(request, oidc, oidcUser.getIdToken()))
            );
    }

    private Map<String, String> prepareLogoutUri(ServerHttpRequest request, ClientRegistration clientRegistration, OidcIdToken idToken) {
        StringBuilder logoutUrl = new StringBuilder();

        logoutUrl.append(clientRegistration.getProviderDetails().getConfigurationMetadata().get("end_session_endpoint").toString());

        // Derived from the request, NOT from the Origin header.
        //
        // getOrigin() returns null whenever the caller did not send one, and the
        // null went straight into the URL: post_logout_redirect_uri=null, the
        // four-character string. Keycloak answers 400 "Invalid redirect uri" --
        // the same error a missing registration produces, one hop away from the
        // gateway that built it, so it reads as a Keycloak fault.
        //
        // Browsers always send Origin on a POST, so a browser never sees this
        // and the SPA was never affected. Everything that is not a browser hits
        // it: the generated client from T-3.11, the smoke suite in T-5.5, any
        // scripted teardown. The endpoint answers 200 and hands back a URL that
        // is already broken, which is the failure mode this template keeps
        // producing -- a success status carrying an unusable result.
        //
        // Safe to derive only because the edge now overwrites X-Forwarded-Host.
        // getURI() reflects the forwarded headers, so before that a caller could
        // have chosen this value by sending its own -- which is worse than a
        // null, because it works.
        String originUrl = UriComponentsBuilder.fromUri(request.getURI()).replacePath(null).replaceQuery(null).build().toUriString();

        logoutUrl.append("?id_token_hint=").append(idToken.getTokenValue()).append("&post_logout_redirect_uri=").append(originUrl);

        return Map.of("logoutUrl", logoutUrl.toString());
    }
}
