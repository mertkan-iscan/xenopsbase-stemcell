package com.xenopsoftware.gateway.web.filter;

import static org.assertj.core.api.Assertions.assertThat;

import com.xenopsoftware.gateway.config.SecurityConfiguration;
import java.util.List;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.client.ClientAuthorizationException;
import org.springframework.security.oauth2.client.ClientAuthorizationRequiredException;
import org.springframework.security.oauth2.client.ReactiveOAuth2AuthorizedClientManager;
import org.springframework.security.oauth2.client.authentication.OAuth2AuthenticationToken;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.user.DefaultOAuth2User;
import org.springframework.security.web.server.ServerAuthenticationEntryPoint;
import org.springframework.web.server.WebFilterChain;
import reactor.core.publisher.Mono;

/**
 * What happens when the token refresh fails (T-3.19, #179).
 *
 * <p>The generated filter let {@link ClientAuthorizationException} escape, so Keycloak reporting
 * {@code invalid_grant} -- an SSO session that reached its idle bound, or that an administrator
 * ended -- arrived as {@code 500 Server Error for HTTP GET "/app.js"}. The gateway session stayed
 * valid, so there was no way back: every reload produced the same 500 until the cookie expired.
 *
 * <p>Both branches of the answer are asserted, for the same reason {@link UnauthenticatedRequestIT}
 * asserts both: a fix that returned 401 to everything would take interactive login with it.
 */
class OAuth2ReactiveRefreshTokensWebFilterTest {

    /** The entry point the application runs, not a stand-in -- the html/json split is the assertion. */
    private final ServerAuthenticationEntryPoint entryPoint = new SecurityConfiguration(null, null).authenticationEntryPoint();

    private static final OAuth2AuthenticationToken PRINCIPAL = new OAuth2AuthenticationToken(
        new DefaultOAuth2User(List.of(new SimpleGrantedAuthority("ROLE_USER")), java.util.Map.of("sub", "u-1"), "sub"),
        List.of(new SimpleGrantedAuthority("ROLE_USER")),
        "oidc"
    );

    /** Never reached in these tests: the refresh fails before the chain is invoked. */
    private static final WebFilterChain UNREACHED = exchange -> Mono.error(new AssertionError("the chain must not be reached"));

    private MockServerWebExchange run(RuntimeException refreshFailure, MediaType accept) {
        return run(refreshFailure, accept, "/services/core/api/documents", UNREACHED);
    }

    private MockServerWebExchange run(RuntimeException refreshFailure, MediaType accept, String path, WebFilterChain chain) {
        MockServerWebExchange exchange = MockServerWebExchange.from(MockServerHttpRequest.get(path).accept(accept).build());
        ReactiveOAuth2AuthorizedClientManager refusing = request -> Mono.error(refreshFailure);
        new OAuth2ReactiveRefreshTokensWebFilter(refusing, entryPoint).filter(new PrincipalExchange(exchange, PRINCIPAL), chain).block();
        return exchange;
    }

    private static ClientAuthorizationException sessionNotActive() {
        return new ClientAuthorizationException(new OAuth2Error("invalid_grant", "Session not active", null), "oidc");
    }

    @Test
    @DisplayName("a refused refresh is a 401 problem document to a fetch, not a 500")
    void jsonCallerGetsUnauthorized() {
        MockServerWebExchange exchange = run(sessionNotActive(), MediaType.APPLICATION_JSON);

        assertThat(exchange.getResponse().getStatusCode()).isEqualTo(HttpStatus.UNAUTHORIZED);
        assertThat(exchange.getResponse().getHeaders().getFirst(HttpHeaders.WWW_AUTHENTICATE)).startsWith("Bearer");
    }

    @Test
    @DisplayName("a refused refresh sends browser navigation back into login, which recovers it")
    void browserNavigationIsRedirectedToLogin() {
        MockServerWebExchange exchange = run(sessionNotActive(), MediaType.TEXT_HTML);

        assertThat(exchange.getResponse().getStatusCode()).isEqualTo(HttpStatus.FOUND);
        assertThat(exchange.getResponse().getHeaders().getLocation()).hasToString("/oauth2/authorization/oidc");
    }

    @Test
    @DisplayName("a missing authorized client does not redirect an XHR into the identity provider")
    void aMissingClientIsAlsoAnsweredByTheEntryPoint() {
        // ClientAuthorizationRequiredException is what the pod WITHOUT the tokens threw, back when
        // they lived in one JVM's heap. Spring answers it with an unconditional 302 into the
        // Keycloak authorization endpoint whatever the caller asked for -- which is how a fetch
        // and a stylesheet both ended up loading that URL and tripping connect-src and style-src.
        MockServerWebExchange exchange = run(new ClientAuthorizationRequiredException("oidc"), MediaType.APPLICATION_JSON);

        assertThat(exchange.getResponse().getStatusCode()).isEqualTo(HttpStatus.UNAUTHORIZED);
    }

    @Test
    @DisplayName("logout is reachable with a refresh token Keycloak has already refused")
    void logoutIsNotGatedOnTheRefresh() {
        // Gating logout on a successful refresh has the dependency backwards: it is what a user
        // does BECAUSE the session is broken. LogoutResource reads the id token off the principal
        // and never touches the authorized client, so there is nothing here to refresh for it.
        java.util.concurrent.atomic.AtomicBoolean reached = new java.util.concurrent.atomic.AtomicBoolean();
        WebFilterChain records = exchange -> {
            reached.set(true);
            return Mono.empty();
        };

        MockServerWebExchange exchange = run(sessionNotActive(), MediaType.APPLICATION_JSON, "/api/logout", records);

        assertThat(reached).isTrue();
        assertThat(exchange.getResponse().getStatusCode()).isNotEqualTo(HttpStatus.UNAUTHORIZED);
    }

    /** MockServerWebExchange has no principal of its own; the filter reads exchange.getPrincipal(). */
    private static final class PrincipalExchange extends org.springframework.web.server.ServerWebExchangeDecorator {

        private final java.security.Principal principal;

        private PrincipalExchange(MockServerWebExchange delegate, java.security.Principal principal) {
            super(delegate);
            this.principal = principal;
        }

        @Override
        @SuppressWarnings("unchecked")
        public <T extends java.security.Principal> Mono<T> getPrincipal() {
            return Mono.just((T) principal);
        }
    }
}
