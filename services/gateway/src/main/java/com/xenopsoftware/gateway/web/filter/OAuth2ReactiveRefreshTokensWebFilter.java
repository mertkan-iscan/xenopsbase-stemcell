package com.xenopsoftware.gateway.web.filter;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.security.authentication.AuthenticationCredentialsNotFoundException;
import org.springframework.security.oauth2.client.ClientAuthorizationException;
import org.springframework.security.oauth2.client.OAuth2AuthorizeRequest;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClient;
import org.springframework.security.oauth2.client.ReactiveOAuth2AuthorizedClientManager;
import org.springframework.security.oauth2.client.authentication.OAuth2AuthenticationToken;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.web.server.ServerAuthenticationEntryPoint;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import org.springframework.web.server.WebFilter;
import org.springframework.web.server.WebFilterChain;
import org.springframework.web.server.WebSession;
import reactor.core.publisher.Mono;

/**
 * Refresh oauth2 tokens based on TokenRelayGatewayFilterFactory.
 */
@Component
public class OAuth2ReactiveRefreshTokensWebFilter implements WebFilter {

    private static final Logger LOG = LoggerFactory.getLogger(OAuth2ReactiveRefreshTokensWebFilter.class);

    /**
     * THE ONE PATH THAT HAS TO WORK WHEN THE TOKENS DO NOT (T-3.19, #179).
     *
     * <p>Logging out is what a user does when the session is already in a bad state, so gating it
     * on a successful token refresh has the dependency backwards: the moment the refresh token is
     * refused, {@code POST /api/logout} would answer 401 and the only way out of a broken session
     * would be to clear cookies by hand.
     *
     * <p>Nothing is skipped that logout needs. {@link
     * com.xenopsoftware.gateway.web.rest.LogoutResource} reads the id token off the principal and
     * the end-session endpoint off the client registration, invalidates the session, and never
     * looks at the authorized client at all -- so a token this filter could not refresh was never
     * going to be used by the request it was blocking.
     */
    private static final String LOGOUT_PATH = "/api/logout";

    private final ReactiveOAuth2AuthorizedClientManager clientManager;

    private final ServerAuthenticationEntryPoint authenticationEntryPoint;

    public OAuth2ReactiveRefreshTokensWebFilter(
        ReactiveOAuth2AuthorizedClientManager clientManager,
        ServerAuthenticationEntryPoint authenticationEntryPoint
    ) {
        this.clientManager = clientManager;
        this.authenticationEntryPoint = authenticationEntryPoint;
    }

    public Mono<Void> filter(ServerWebExchange exchange, WebFilterChain chain) {
        if (LOGOUT_PATH.equals(exchange.getRequest().getPath().value())) {
            return chain.filter(exchange);
        }
        return exchange
            .getPrincipal()
            .filter(principal -> principal instanceof OAuth2AuthenticationToken)
            .cast(OAuth2AuthenticationToken.class)
            .flatMap(authentication -> authorizedClient(exchange, authentication))
            .thenReturn(exchange)
            .flatMap(chain::filter)
            .onErrorResume(ClientAuthorizationException.class, failure -> sessionIsOver(exchange, failure));
    }

    private Mono<OAuth2AuthorizedClient> authorizedClient(ServerWebExchange exchange, OAuth2AuthenticationToken oauth2Authentication) {
        String clientRegistrationId = oauth2Authentication.getAuthorizedClientRegistrationId();
        OAuth2AuthorizeRequest request = OAuth2AuthorizeRequest.withClientRegistrationId(clientRegistrationId)
            .principal(oauth2Authentication)
            .attribute(ServerWebExchange.class.getName(), exchange)
            .build();
        if (clientManager == null) {
            return Mono.error(
                new IllegalStateException(
                    "No ReactiveOAuth2AuthorizedClientManager bean was found. Did you include the " +
                        "org.springframework.boot:spring-boot-starter-oauth2-client dependency?"
                )
            );
        }
        return clientManager.authorize(request);
    }

    /**
     * A session Keycloak has already ended is reported as one, not as a 500 (T-3.19, #179).
     *
     * <p>The refresh above is the first thing on every request that touches a downstream, and it
     * talks to Keycloak. When Keycloak says {@code invalid_grant} -- the SSO session hit its idle
     * or absolute bound, an administrator ended it, the user signed out in another tab -- the
     * generated filter let the exception escape, so a routine and entirely expected event arrived
     * as:
     *
     * <pre>
     *   500 Server Error for HTTP GET "/app.js"
     *   ClientAuthorizationException: [invalid_grant] Session not active
     * </pre>
     *
     * <p>That is wrong twice over. A 500 says this service is broken when nothing here is, and it
     * offers the browser no way out: the WebSession is still valid, so the user stays
     * authenticated to the gateway, and every reload produces the same 500 until the cookie
     * finally expires. Observed on the deployed gateway as a page that would not load and would
     * not re-authenticate either.
     *
     * <p>Invalidating the session is the substantive half. Once the refresh token is refused,
     * every credential the session holds is spent, and the {@link
     * org.springframework.security.oauth2.client.web.server.WebSessionServerOAuth2AuthorizedClientRepository}
     * this project now uses stores them IN that session -- so dropping it is what removes them.
     * Leaving the session in place is what created the loop.
     *
     * <p>The answer then comes from the same entry point the rest of security uses, which is the
     * point of taking it as a bean rather than building a second one here: browser navigation is
     * redirected into a fresh login and recovers in one round trip, while a fetch gets 401 and an
     * RFC 9457 body. The frontend already handles that 401 -- {@code app.js} shows "Your session
     * ended. Reload the page to sign in again." -- which is only true because it is a 401 and not
     * a 302 the fetch would follow cross-origin into a CSP violation.
     *
     * <p>{@code ClientAuthorizationRequiredException} is a subclass and is caught here too,
     * deliberately. Spring answers that one with an unconditional 302 into the authorization
     * endpoint whatever the caller asked for, which is the behaviour that made a stylesheet and
     * an XHR both try to load the Keycloak authorization URL. The entry point makes the same
     * distinction here that it makes everywhere else.
     */
    private Mono<Void> sessionIsOver(ServerWebExchange exchange, ClientAuthorizationException failure) {
        // Committed means the downstream has already started writing, so there is no status left
        // to set. Rare -- the refresh runs before the chain -- but the alternative is an
        // UnsupportedOperationException replacing the error that actually happened.
        if (exchange.getResponse().isCommitted()) {
            return Mono.error(failure);
        }

        LOG.warn("token refresh failed, ending the session and asking for a new login: {}", describe(failure));

        return exchange
            .getSession()
            .flatMap(WebSession::invalidate)
            .then(
                Mono.defer(() ->
                    authenticationEntryPoint.commence(
                        exchange,
                        new AuthenticationCredentialsNotFoundException("the OAuth2 session could not be refreshed")
                    )
                )
            );
    }

    /**
     * The error code and description are Keycloak's words arriving over the network and landing in
     * a log line, so a newline in either would write fabricated entries -- the same log-forging
     * vector {@link OidcAuthenticationFailureHandler} and the correlation id are guarded against.
     */
    private static String describe(ClientAuthorizationException failure) {
        OAuth2Error error = failure.getError();
        return escape(error.getErrorCode()) + " - " + escape(String.valueOf(error.getDescription()));
    }

    private static String escape(String value) {
        return value == null ? "" : value.replace("\n", "").replace("\r", "");
    }
}
