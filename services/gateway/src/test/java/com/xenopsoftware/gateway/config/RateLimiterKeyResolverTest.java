package com.xenopsoftware.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.net.InetSocketAddress;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.cloud.gateway.filter.ratelimit.KeyResolver;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import org.springframework.security.authentication.AnonymousAuthenticationToken;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.authority.AuthorityUtils;
import org.springframework.security.core.context.ReactiveSecurityContextHolder;
import org.springframework.security.core.context.SecurityContextImpl;
import reactor.core.publisher.Mono;

/**
 * What a rate limit counts against (T-8.3, #61).
 *
 * <p>Every case here is a way of accidentally building ONE bucket for everybody, which is a limiter
 * that reports itself configured and governs nothing — the shape of control failure this repository
 * keeps finding. A test that only asserted "some key comes back" would pass for all of them.
 */
class RateLimiterKeyResolverTest {

    private final KeyResolver resolver = new RateLimiterConfiguration("").clientKeyResolver();

    private static MockServerWebExchange exchangeFrom(String address, String forwardedFor) {
        MockServerHttpRequest.BaseBuilder<?> builder = MockServerHttpRequest.get("/services/core/api/documents").remoteAddress(
            new InetSocketAddress(address, 44444)
        );
        if (forwardedFor != null) {
            builder = builder.header("X-Forwarded-For", forwardedFor);
        }
        return MockServerWebExchange.from(builder.build());
    }

    private String keyFor(MockServerWebExchange exchange, Object authentication) {
        return keyFor(resolver, exchange, authentication);
    }

    private String keyFor(KeyResolver which, MockServerWebExchange exchange, Object authentication) {
        Mono<String> key = which.resolve(exchange);
        if (authentication != null) {
            key = key.contextWrite(
                ReactiveSecurityContextHolder.withSecurityContext(
                    Mono.just(new SecurityContextImpl((org.springframework.security.core.Authentication) authentication))
                )
            );
        }
        return key.block();
    }

    @Test
    @DisplayName("no security context at all falls back to the address")
    void unauthenticatedIsKeyedOnAddress() {
        assertThat(keyFor(exchangeFrom("203.0.113.7", null), null)).isEqualTo("ip:203.0.113.7");
    }

    @Test
    @DisplayName("ANONYMOUS is not a user, even though it reports itself authenticated")
    void anonymousIsKeyedOnAddressAndNotOnItsName() {
        // The trap. AnonymousAuthenticationToken.isAuthenticated() is true and its name is the
        // constant "anonymousUser", so a resolver that only checked isAuthenticated() would put
        // every logged-out request in the world into one bucket -- and would look right in review.
        AnonymousAuthenticationToken anonymous = new AnonymousAuthenticationToken(
            "key",
            "anonymousUser",
            AuthorityUtils.createAuthorityList("ROLE_ANONYMOUS")
        );

        String key = keyFor(exchangeFrom("203.0.113.7", null), anonymous);

        assertThat(key).isEqualTo("ip:203.0.113.7");
        assertThat(key).doesNotContain("anonymousUser");
    }

    @Test
    @DisplayName("an authenticated caller is keyed on its subject, not its address")
    void authenticatedIsKeyedOnSubject() {
        TestingAuthenticationToken authenticated = new TestingAuthenticationToken("af70f9df-8441", "n/a", "ROLE_USER");

        // Keyed on identity rather than address so a client changing network keeps its bucket, and
        // so rotating addresses does not hand an authenticated caller a fresh one.
        assertThat(keyFor(exchangeFrom("203.0.113.7", null), authenticated)).isEqualTo("sub:af70f9df-8441");
    }

    @Test
    @DisplayName("the address comes from the closest proxy's entry, not the client's own claim")
    void forwardedForIsReadFromTheTrustedEnd() {
        // maxTrustedIndex(1): the LAST entry, written by the hop we actually talk to. The first is
        // whatever the client sent, so a resolver reading that end would let anyone mint a fresh
        // bucket per request by adding a header.
        String key = keyFor(exchangeFrom("10.42.1.9", "198.51.100.23, 203.0.113.7"), null);

        assertThat(key).isEqualTo("ip:203.0.113.7");
        assertThat(key).doesNotContain("198.51.100.23");
    }

    @Test
    @DisplayName("the exempt role produces NO key, which is how the limiter is skipped")
    void exemptRoleIsNotKeyed() {
        // An empty key is not "unidentified" here, it is "do not count this one".
        // RequestRateLimiter skips the limiter entirely rather than consuming a token, which is what
        // lets the k6 baseline measure the pods instead of this filter (T-5.13, #371).
        KeyResolver exempting = new RateLimiterConfiguration("app-loadtest").clientKeyResolver();
        TestingAuthenticationToken loadTester = new TestingAuthenticationToken("load-1", "n/a", "app-loadtest");

        assertThat(keyFor(exempting, exchangeFrom("203.0.113.7", null), loadTester)).isNull();
    }

    @Test
    @DisplayName("the exempt role is matched in either spelling Spring may have produced")
    void exemptRoleMatchesPrefixedSpelling() {
        // SecurityUtils emits app-loadtest AND ROLE_APP_LOADTEST, because hasRole() prepends and
        // upper-cases. Matching one spelling only is a check that compiles and matches nothing.
        KeyResolver exempting = new RateLimiterConfiguration("app-loadtest").clientKeyResolver();
        TestingAuthenticationToken loadTester = new TestingAuthenticationToken("load-1", "n/a", "ROLE_APP_LOADTEST");

        assertThat(keyFor(exempting, exchangeFrom("203.0.113.7", null), loadTester)).isNull();
    }

    @Test
    @DisplayName("with no role configured, holding one exempts nobody")
    void unsetRoleExemptsNobody() {
        // The default everywhere but dev. A realm that does not declare the role cannot produce a
        // token carrying it, and an environment that does not set the variable would not honour one
        // if it did.
        TestingAuthenticationToken looksExempt = new TestingAuthenticationToken("af70f9df", "n/a", "app-loadtest");

        assertThat(keyFor(exchangeFrom("203.0.113.7", null), looksExempt)).isEqualTo("sub:af70f9df");
    }
}
