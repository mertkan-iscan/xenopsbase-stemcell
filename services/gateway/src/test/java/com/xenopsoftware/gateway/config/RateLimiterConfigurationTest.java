package com.xenopsoftware.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.cloud.gateway.filter.ratelimit.KeyResolver;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import org.springframework.security.authentication.AnonymousAuthenticationToken;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.authority.AuthorityUtils;
import org.springframework.security.core.context.ReactiveSecurityContextHolder;
import org.springframework.security.oauth2.core.oidc.OidcIdToken;
import org.springframework.security.oauth2.core.oidc.user.DefaultOidcUser;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;

/**
 * What counts as "a client" for rate limiting.
 *
 * <p>This resolver decides who shares a bucket, and both ways of getting it wrong are quiet. One key
 * for everyone means the first busy caller rate-limits the rest; a fresh key per request means the
 * limit never binds and the control is decorative. Neither shows up as an error.
 *
 * <p>13 of its branches were untaken. T-8.3 (#61) proves a limit exists and is per-client through a
 * live run; this covers the identity decision itself, including the cases a live run does not
 * conveniently produce.
 */
class RateLimiterConfigurationTest {

    // No exempt role, which is the default in every environment but dev. The exemption itself is
    // covered in RateLimiterKeyResolverTest (T-5.13, #371).
    private final KeyResolver resolver = new RateLimiterConfiguration("").clientKeyResolver();

    private MockServerWebExchange exchangeFrom(String forwardedFor, String remoteHost) {
        MockServerHttpRequest.BaseBuilder<?> builder = MockServerHttpRequest.get("/services/core/api/documents");
        if (forwardedFor != null) {
            builder = builder.header("X-Forwarded-For", forwardedFor);
        }
        if (remoteHost != null) {
            builder = builder.remoteAddress(new java.net.InetSocketAddress(remoteHost, 51000));
        }
        return MockServerWebExchange.from(builder.build());
    }

    private String keyFor(Authentication authentication, MockServerWebExchange exchange) {
        var mono = resolver.resolve(exchange);
        if (authentication != null) {
            mono = mono.contextWrite(ReactiveSecurityContextHolder.withAuthentication(authentication));
        }
        return mono.block();
    }

    private OidcUser oidcUserWithSubject(String subject) {
        OidcIdToken token = new OidcIdToken("token-value", null, null, Map.of("sub", subject, "preferred_username", "someone"));
        return new DefaultOidcUser(AuthorityUtils.createAuthorityList("ROLE_USER"), token, "sub");
    }

    /** An authenticated caller is identified by their subject, so their limit follows them. */
    @Test
    void anAuthenticatedUserIsKeyedBySubject() {
        OidcUser user = oidcUserWithSubject("11111111-2222-3333-4444-555555555555");
        Authentication authentication = new TestingAuthenticationToken(user, "n/a", "ROLE_USER");

        String key = keyFor(authentication, exchangeFrom(null, "203.0.113.9"));

        assertThat(key).isEqualTo("sub:11111111-2222-3333-4444-555555555555");
    }

    /** A non-OIDC principal still has a name, and it is used rather than falling back to the address. */
    @Test
    void anAuthenticatedNonOidcPrincipalIsKeyedByName() {
        Authentication authentication = new TestingAuthenticationToken("service-account", "n/a", "ROLE_USER");

        assertThat(keyFor(authentication, exchangeFrom(null, "203.0.113.9"))).isEqualTo("sub:service-account");
    }

    /**
     * Anonymous is not a user. Keying by it would put every unauthenticated caller in one bucket,
     * so the first of them would rate-limit all the others.
     */
    @Test
    void anAnonymousTokenFallsBackToTheAddress() {
        Authentication anonymous = new AnonymousAuthenticationToken(
            "key",
            "anonymousUser",
            AuthorityUtils.createAuthorityList("ROLE_ANONYMOUS")
        );

        assertThat(keyFor(anonymous, exchangeFrom(null, "203.0.113.9"))).isEqualTo("ip:203.0.113.9");
    }

    /** Authenticated=false is the other way to not be a user. */
    @Test
    void anUnauthenticatedTokenFallsBackToTheAddress() {
        TestingAuthenticationToken authentication = new TestingAuthenticationToken("someone", "n/a", List.of());
        authentication.setAuthenticated(false);

        assertThat(keyFor(authentication, exchangeFrom(null, "203.0.113.9"))).isEqualTo("ip:203.0.113.9");
    }

    /** No security context at all: the common case for a public route. */
    @Test
    void anAbsentSecurityContextFallsBackToTheAddress() {
        assertThat(keyFor(null, exchangeFrom(null, "203.0.113.9"))).isEqualTo("ip:203.0.113.9");
    }

    /**
     * Behind the tunnel and ingress-nginx the peer address is a proxy, so every caller would share
     * one bucket without this. maxTrustedIndex(1) takes the last hop rather than the leftmost
     * value, which a caller can set to anything.
     */
    @Test
    void theForwardedAddressIsPreferredOverThePeer() {
        String key = keyFor(null, exchangeFrom("198.51.100.7", "10.0.0.1"));

        assertThat(key).isEqualTo("ip:198.51.100.7");
    }

    /** Nothing to identify the caller by at all still produces a key rather than failing. */
    @Test
    void anExchangeWithNoAddressAtAllStillResolves() {
        assertThat(keyFor(null, exchangeFrom(null, null))).isEqualTo("ip:");
    }
}
