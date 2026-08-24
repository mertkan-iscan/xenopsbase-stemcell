package com.xenopsoftware.gateway.web.filter;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.io.buffer.DataBuffer;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseCookie;
import org.springframework.http.server.reactive.ServerHttpResponse;
import org.springframework.security.core.AuthenticationException;
import org.springframework.security.oauth2.core.OAuth2AuthenticationException;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.web.server.WebFilterExchange;
import org.springframework.security.web.server.authentication.ServerAuthenticationFailureHandler;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

/**
 * Decides where the browser goes when an OIDC login fails (T-3.17).
 *
 * <h2>Why this exists</h2>
 *
 * Spring's default sends the browser to {@code /login?error}. This application does not serve
 * {@code /login} -- no controller, no route, no static file, because the frontend is a single page
 * at {@code /} plus APIs. So the default turns a routine, recoverable failure into a 404 naming a
 * missing static resource, which describes the second-order symptom and says nothing about the
 * authentication error that caused it. The reason was unreachable from the response.
 *
 * <h2>How it is reached, which is not exotic</h2>
 *
 * A browser replays an authorization URL whose {@code state} belongs to a finished flow -- an old
 * tab, a history entry, a bookmark, the back button. Keycloak still has an SSO session so it
 * issues a code immediately, and there is no saved authorization request here to match it against.
 *
 * <p>It is invisible unless you are already signed in. With no session the dead end is intercepted
 * by security and redirected into a fresh login, which works; with one, the request passes
 * security, finds no handler, and 404s. Signing in is what breaks the page, and only for the
 * people who have done it -- the same asymmetry {@code anyExchange().authenticated()} already
 * carries a comment about.
 *
 * <h2>Redirecting to / recovers the common case, and could loop</h2>
 *
 * Reaching {@code /} unauthenticated starts a <em>fresh</em> authorization request, so the stale
 * {@code state} case resolves in one round trip. A persistent failure -- a broken client
 * registration, clock skew, a nonce mismatch -- would instead cycle until the browser gave up, and
 * "too many redirects" is a poor way to report a misconfiguration.
 *
 * <p>So the redirect happens <b>once</b>. A short-lived cookie marks that the retry was spent, and
 * a failure arriving with that cookie present is answered with a problem document instead of
 * another redirect. The cookie is cleared at the same time, so the next attempt starts clean
 * rather than being stuck in the terminal branch.
 */
public class OidcAuthenticationFailureHandler implements ServerAuthenticationFailureHandler {

    private static final Logger LOG = LoggerFactory.getLogger(OidcAuthenticationFailureHandler.class);

    /**
     * Names the RFC section defining 401 rather than a page on this service, for the same reason
     * {@link ProblemDetailAuthenticationEntryPoint} does: a {@code type} URI identifies, it does
     * not promise to host documentation.
     */
    private static final String TYPE = "https://datatracker.ietf.org/doc/html/rfc9110#section-15.5.2";

    /** Deliberately short. It exists to break a loop, not to remember anything about the user. */
    private static final Duration RETRY_TTL = Duration.ofSeconds(60);

    static final String RETRY_COOKIE = "oidc-retry";

    @Override
    public Mono<Void> onAuthenticationFailure(WebFilterExchange webFilterExchange, AuthenticationException exception) {
        ServerWebExchange exchange = webFilterExchange.getExchange();
        ServerHttpResponse response = exchange.getResponse();
        String reason = describe(exception);

        if (exchange.getRequest().getCookies().containsKey(RETRY_COOKIE)) {
            // The retry has already been spent. Another redirect here is the loop.
            LOG.warn("OIDC login failed again after a retry, answering with a problem document: {}", reason);
            response.addCookie(retryCookie(Duration.ZERO));
            return problemDocument(exchange);
        }

        // Logged because the response deliberately carries no detail: the failure is reported to
        // the caller in general terms and to the operator specifically. The log line carries the
        // correlation id (T-3.8), so this is reachable from the request a user quotes.
        LOG.warn("OIDC login failed, restarting the flow at /: {}", reason);
        response.addCookie(retryCookie(RETRY_TTL));
        response.setStatusCode(HttpStatus.FOUND);
        response.getHeaders().setLocation(URI.create("/"));
        return response.setComplete();
    }

    private static ResponseCookie retryCookie(Duration maxAge) {
        return ResponseCookie.from(RETRY_COOKIE, "1")
            .path("/")
            .maxAge(maxAge)
            .httpOnly(true)
            .secure(true)
            // Lax rather than Strict: the cookie has to survive a top-level navigation arriving
            // from the identity provider's hostname, which Strict would drop.
            .sameSite("Lax")
            .build();
    }

    private Mono<Void> problemDocument(ServerWebExchange exchange) {
        ServerHttpResponse response = exchange.getResponse();
        response.setStatusCode(HttpStatus.UNAUTHORIZED);
        response.getHeaders().setContentType(MediaType.APPLICATION_PROBLEM_JSON);

        // The provider's error text is NOT echoed. It is content this application did not author,
        // and reflecting it into a response is a place to put someone else's words.
        String body =
            "{\"type\":\"" +
            TYPE +
            "\",\"title\":\"Unauthorized\",\"status\":401," +
            "\"detail\":\"Signing in did not complete. Start again at /oauth2/authorization/oidc; " +
            "if this repeats, the identity provider configuration is at fault.\"," +
            "\"instance\":\"" +
            escape(exchange.getRequest().getPath().value()) +
            "\"}";

        DataBuffer buffer = response.bufferFactory().wrap(body.getBytes(StandardCharsets.UTF_8));
        return response.writeWith(Mono.just(buffer));
    }

    /**
     * The error code and description come from the identity provider and land in a log line, so a
     * newline in either would write fabricated entries -- the same log-forging vector the
     * correlation id is validated against.
     */
    private static String describe(AuthenticationException exception) {
        if (exception instanceof OAuth2AuthenticationException oauth2) {
            OAuth2Error error = oauth2.getError();
            return escape(error.getErrorCode()) + " - " + escape(String.valueOf(error.getDescription()));
        }
        return escape(exception.getClass().getSimpleName()) + " - " + escape(String.valueOf(exception.getMessage()));
    }

    private static String escape(String value) {
        return value == null ? "" : value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "").replace("\r", "");
    }
}
