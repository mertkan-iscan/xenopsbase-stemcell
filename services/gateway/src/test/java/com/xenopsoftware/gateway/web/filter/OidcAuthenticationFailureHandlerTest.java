package com.xenopsoftware.gateway.web.filter;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseCookie;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.security.core.AuthenticationException;
import org.springframework.security.oauth2.core.OAuth2AuthenticationException;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.web.server.WebFilterExchange;
import reactor.core.publisher.Mono;

/**
 * The dead end this fixes (T-3.17): a failed OIDC login went to {@code /login?error}, which this
 * application does not serve, so a recoverable failure came back as a 404 about a missing static
 * resource.
 *
 * <p>Each test is aimed at one of the two ways this can go wrong — dead-ending again, or looping
 * forever instead.
 */
class OidcAuthenticationFailureHandlerTest {

    private final OidcAuthenticationFailureHandler handler = new OidcAuthenticationFailureHandler();

    private static final AuthenticationException STALE_STATE = new OAuth2AuthenticationException(
        new OAuth2Error("authorization_request_not_found"),
        "authorization_request_not_found"
    );

    private static MockServerWebExchange exchangeWith(String... cookies) {
        MockServerHttpRequest.BaseBuilder<?> builder = MockServerHttpRequest.get("/login/oauth2/code/oidc");
        for (String cookie : cookies) {
            builder = builder.cookie(new org.springframework.http.HttpCookie(cookie, "1"));
        }
        return MockServerWebExchange.from((MockServerHttpRequest) builder.build());
    }

    private void handle(MockServerWebExchange exchange, AuthenticationException exception) {
        handler.onAuthenticationFailure(new WebFilterExchange(exchange, e -> Mono.empty()), exception).block();
    }

    @Test
    @DisplayName("a stale authorization request restarts the flow at / rather than 404ing")
    void redirectsToRootOnFirstFailure() {
        MockServerWebExchange exchange = exchangeWith();

        handle(exchange, STALE_STATE);

        assertThat(exchange.getResponse().getStatusCode()).isEqualTo(HttpStatus.FOUND);
        assertThat(exchange.getResponse().getHeaders().getLocation()).hasToString("/");
    }

    @Test
    @DisplayName("never sends the browser to /login, which does not exist here")
    void neverRedirectsToTheLoginPageSpringWouldPick() {
        MockServerWebExchange exchange = exchangeWith();

        handle(exchange, STALE_STATE);

        assertThat(String.valueOf(exchange.getResponse().getHeaders().getLocation())).doesNotContain("/login");
    }

    @Test
    @DisplayName("the first failure spends a retry, recorded in a short-lived cookie")
    void setsTheRetryCookieOnFirstFailure() {
        MockServerWebExchange exchange = exchangeWith();

        handle(exchange, STALE_STATE);

        ResponseCookie cookie = exchange.getResponse().getCookies().getFirst(OidcAuthenticationFailureHandler.RETRY_COOKIE);
        assertThat(cookie).isNotNull();
        assertThat(cookie.getMaxAge()).isEqualTo(Duration.ofSeconds(60));
        assertThat(cookie.isHttpOnly()).isTrue();
        assertThat(cookie.isSecure()).isTrue();
    }

    @Test
    @DisplayName("a second failure answers rather than redirecting again - this is the loop guard")
    void doesNotRedirectTwice() {
        MockServerWebExchange exchange = exchangeWith(OidcAuthenticationFailureHandler.RETRY_COOKIE);

        handle(exchange, STALE_STATE);

        assertThat(exchange.getResponse().getStatusCode()).isEqualTo(HttpStatus.UNAUTHORIZED);
        assertThat(exchange.getResponse().getHeaders().getLocation()).isNull();
        assertThat(exchange.getResponse().getHeaders().getContentType()).isEqualTo(MediaType.APPLICATION_PROBLEM_JSON);
    }

    @Test
    @DisplayName("the loop guard clears itself, so the next attempt is not stuck in the terminal branch")
    void clearsTheRetryCookieOnTheSecondFailure() {
        MockServerWebExchange exchange = exchangeWith(OidcAuthenticationFailureHandler.RETRY_COOKIE);

        handle(exchange, STALE_STATE);

        ResponseCookie cookie = exchange.getResponse().getCookies().getFirst(OidcAuthenticationFailureHandler.RETRY_COOKIE);
        assertThat(cookie).isNotNull();
        assertThat(cookie.getMaxAge()).isEqualTo(Duration.ZERO);
    }

    @Test
    @DisplayName("the terminal response is a problem document that does not echo the provider's text")
    void problemDocumentDoesNotReflectTheProviderMessage() {
        MockServerWebExchange exchange = exchangeWith(OidcAuthenticationFailureHandler.RETRY_COOKIE);
        AuthenticationException chatty = new OAuth2AuthenticationException(
            new OAuth2Error("invalid_grant", "<script>alert(1)</script>", null),
            "invalid_grant"
        );

        handle(exchange, chatty);

        String body = exchange.getResponse().getBodyAsString().block();
        assertThat(body).contains("\"status\":401").contains("\"title\":\"Unauthorized\"");
        assertThat(body).doesNotContain("script").doesNotContain("invalid_grant");
    }

    @Test
    @DisplayName("a non-OAuth2 failure is handled the same way, not thrown")
    void handlesANonOAuth2Failure() {
        MockServerWebExchange exchange = exchangeWith();

        handle(exchange, new BadCredentialsException("nope"));

        assertThat(exchange.getResponse().getStatusCode()).isEqualTo(HttpStatus.FOUND);
    }
}
