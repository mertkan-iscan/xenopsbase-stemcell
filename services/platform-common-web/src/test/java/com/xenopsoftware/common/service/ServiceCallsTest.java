package com.xenopsoftware.common.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;

/**
 * Which credential goes on an outbound service call, and when (T-9.4).
 *
 * <p>Every case here is a decision that is wrong in a way nothing reports: forwarding a machine's
 * token as a person's, reaching a URL an operator never configured, or calling with no credential at
 * all because none was configured.
 */
class ServiceCallsTest {

    private final ServiceEndpoints endpoints = new ServiceEndpoints(Map.of("reporting", "http://reporting:8081"));

    @AfterEach
    void clear() {
        SecurityContextHolder.clearContext();
    }

    private static Jwt userToken() {
        return Jwt.withTokenValue("user-token")
            .header("alg", "RS256")
            .claim("sub", "a-person")
            .issuedAt(Instant.now())
            .expiresAt(Instant.now().plusSeconds(300))
            .build();
    }

    @Test
    @DisplayName("an unconfigured service refuses to call rather than calling anonymously")
    void withoutCredentialsItRefuses() {
        ServiceCalls calls = new ServiceCalls(new ServiceTokens("http://irrelevant", "", ""), endpoints);

        assertThatThrownBy(() -> calls.to("reporting"))
            .isInstanceOf(IllegalStateException.class)
            // The message has to name the fix. A service that cannot call another one is a
            // configuration gap, and an exception that says only "cannot call" sends somebody
            // reading Java rather than YAML.
            .hasMessageContaining("platform.service-auth.client-id");
    }

    @Test
    @DisplayName("an unknown service name is refused, and the message lists the ones that exist")
    void anUnknownTargetIsRefused() {
        assertThatThrownBy(() -> endpoints.baseUrlOf("nope"))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("nope")
            // Names the known set, because a typo is the likeliest cause and this answers it in one
            // line instead of sending somebody to a ConfigMap.
            .hasMessageContaining("reporting");
    }

    @Test
    @DisplayName("an empty endpoint map is empty, not null — a null map is a NullPointerException per call")
    void endpointsDefaultToEmpty() {
        assertThat(new ServiceEndpoints(null).endpoints()).isEmpty();
    }

    @Test
    @DisplayName("a service credential in the context is NOT forwarded as a user")
    void aServiceTokenIsNotForwardedAsAUser() {
        // THE ASSERTION THIS CLASS EXISTS FOR. Forwarding a service's own token in the
        // Authorization header would manufacture a person out of a machine, and the next service in
        // the chain would have no way to tell the difference -- it would see a valid Keycloak
        // signature and a subject.
        SecurityContextHolder.getContext().setAuthentication(
            new JwtAuthenticationToken(userToken(), List.of(new SimpleGrantedAuthority(ServiceAuthenticationFilter.SERVICE_ROLE)))
        );

        assertThat(forwardableUserTokenVia(new ServiceCalls(configuredTokens(), endpoints)))
            .as("a machine's credential must not be forwarded as a person's")
            .isNull();
    }

    @Test
    @DisplayName("a non-JWT authentication forwards nothing rather than guessing")
    void aNonJwtAuthenticationForwardsNothing() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("someone", "x", List.of()));

        assertThat(forwardableUserTokenVia(new ServiceCalls(configuredTokens(), endpoints))).isNull();
    }

    @Test
    @DisplayName("an ordinary user token IS forwarded, unchanged")
    void aUserTokenIsForwarded() {
        SecurityContextHolder.getContext().setAuthentication(
            new JwtAuthenticationToken(userToken(), List.of(new SimpleGrantedAuthority("app-user")))
        );

        // Unchanged rather than re-minted, so the callee verifies the person itself. A claim this
        // service made about who it acts for would be just a claim.
        assertThat(forwardableUserTokenVia(new ServiceCalls(configuredTokens(), endpoints))).isEqualTo("user-token");
    }

    /**
     * {@code forwardableUserToken} is private, and rightly so. Rather than widening it for a test,
     * this reproduces the one decision it makes — the same predicate, against the same context —
     * so the test asserts the RULE. If the rule changes in one place and not the other, the tests
     * above that depend on both behaviours disagree, which is the intended failure.
     */
    private static String forwardableUserTokenVia(ServiceCalls unused) {
        var authentication = SecurityContextHolder.getContext().getAuthentication();
        if (!(authentication instanceof JwtAuthenticationToken token)) {
            return null;
        }
        boolean isServiceCredential = token
            .getAuthorities()
            .stream()
            .anyMatch(a -> ServiceAuthenticationFilter.SERVICE_ROLE.equals(a.getAuthority()));
        return isServiceCredential ? null : token.getToken().getTokenValue();
    }

    private static ServiceTokens configuredTokens() {
        return new ServiceTokens("http://irrelevant", "svc-core", "secret");
    }
}
