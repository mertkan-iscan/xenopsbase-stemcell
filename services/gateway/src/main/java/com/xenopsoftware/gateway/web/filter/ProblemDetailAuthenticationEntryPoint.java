package com.xenopsoftware.gateway.web.filter;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import org.springframework.core.io.buffer.DataBuffer;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.server.reactive.ServerHttpResponse;
import org.springframework.security.core.AuthenticationException;
import org.springframework.security.web.server.ServerAuthenticationEntryPoint;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

/**
 * Answers an unauthenticated API request with 401 and an RFC 9457 body, rather than a redirect
 * to a login page (T-3.8).
 *
 * <h2>Why this exists</h2>
 *
 * Spring's {@code oauth2Login} installs a redirecting entry point, which is right for a browser
 * and actively harmful for an API client. The client receives a 302, follows it, is served the
 * Keycloak login page, and gets <b>200 OK with a body of HTML</b>. Nothing in that exchange looks
 * like a failure: no error status, no error body. A client that checks the status code concludes
 * the call succeeded and then fails somewhere else entirely, parsing HTML as JSON.
 *
 * <p>That is the same failure shape this project has met repeatedly — an archive that never
 * archived, alerts routed to a null receiver, SMTP that queued and discarded. Something reports
 * success while doing nothing.
 *
 * <p>401 with {@code WWW-Authenticate} is what RFC 9110 asks for and what every HTTP client
 * already knows how to handle.
 *
 * <p>The body is written by hand rather than through the {@code ExceptionTranslator}. Security
 * runs as a WebFilter, before any {@code @ControllerAdvice} exists to consult — so an advice-based
 * handler is never reached for an authentication failure, however correct it looks.
 */
public class ProblemDetailAuthenticationEntryPoint implements ServerAuthenticationEntryPoint {

    /**
     * Points at the RFC section defining 401 rather than at a page on this service. A
     * {@code type} URI is an identifier, not a promise to host documentation, and a link into
     * an application that may not be reachable is worse than a stable external one.
     */
    private static final String TYPE = "https://datatracker.ietf.org/doc/html/rfc9110#section-15.5.2";

    @Override
    public Mono<Void> commence(ServerWebExchange exchange, AuthenticationException e) {
        ServerHttpResponse response = exchange.getResponse();
        response.setStatusCode(HttpStatus.UNAUTHORIZED);
        response.getHeaders().setContentType(MediaType.APPLICATION_PROBLEM_JSON);

        // Names the scheme so a client knows what to present, and points at the login endpoint
        // so a browser-based caller can still discover where to go without being redirected
        // into it mid-request.
        response.getHeaders().set(HttpHeaders.WWW_AUTHENTICATE, "Bearer realm=\"api\"");

        String instance = exchange.getRequest().getPath().value();
        String body = """
            {"type":"%s",\
            "title":"Unauthorized",\
            "status":401,\
            "detail":"Authentication is required. Present a bearer token, or start a browser \
            session at /oauth2/authorization/oidc.",\
            "instance":"%s"}""".formatted(TYPE, escape(instance));

        DataBuffer buffer = response.bufferFactory().wrap(body.getBytes(StandardCharsets.UTF_8));
        return response.writeWith(Mono.just(buffer));
    }

    /** The path is attacker-controlled and lands inside a JSON string literal. */
    private static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "").replace("\r", "");
    }
}
