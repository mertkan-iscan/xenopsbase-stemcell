package com.xenopsoftware.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.net.InetSocketAddress;
import java.time.Duration;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.cloud.gateway.filter.headers.TrustedProxies;
import org.springframework.cloud.gateway.filter.headers.XForwardedHeadersFilter;
import org.springframework.http.HttpHeaders;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import reactor.netty.DisposableServer;
import reactor.netty.http.client.HttpClient;
import reactor.netty.http.server.HttpServer;

/**
 * What `spring.cloud.gateway.trusted-proxies` actually does (T-3.15, #148).
 *
 * WHY THIS TEST EXISTS
 *
 * The setting has now been changed twice on an inference and reverted once, at
 * the cost of a client contract: narrowing it in 0c8129a made the gateway strip
 * every X-Forwarded-* header, so core built its pagination `Link` URLs from its
 * own in-cluster address and handed clients `http://core:8081/...`.
 *
 * The revert (d861dbf) recorded a HYPOTHESIS for why the pattern
 * `10\\.42\\.\\d{1,3}\\.\\d{1,3}` failed to match a request from 10.42.3.26: that the
 * value is matched against a remote address string that INCLUDES THE PORT.
 *
 * That hypothesis is wrong, and this test is what says so rather than a third
 * inference. The upstream filter matches against
 * `getRemoteAddress().getHostString()`, which carries no port at all.
 *
 * Everything asserted here is upstream behaviour, not ours. That is the point:
 * the next person to touch this setting gets the mechanism from a test that
 * fails when Spring changes it, instead of from a commit message.
 */
class TrustedProxiesTest {

    @Test
    @DisplayName("the pattern is a FULL match, not a search")
    void patternIsAFullMatch() {
        // This is the whole reason a pattern that "looks right" can reject
        // every request: `10\\.42\\.` finds inside "10.42.3.26" but does not
        // match it.
        assertThat(TrustedProxies.from("10\\.42\\.").isTrusted("10.42.3.26")).isFalse();
        assertThat(TrustedProxies.from("10\\.42\\..*").isTrusted("10.42.3.26")).isTrue();
    }

    @Test
    @DisplayName("the reverted pattern DOES match the address it was blamed for")
    void theRevertedPatternMatchesTheObservedAddress() {
        // d861dbf blamed `10\\.42\\.\\d{1,3}\\.\\d{1,3}` for not matching 10.42.3.26.
        // Against a bare IPv4 string it matches perfectly well. So the pattern
        // was not what failed -- the string it was fed was not this string.
        assertThat(TrustedProxies.from("10\\.42\\.\\d{1,3}\\.\\d{1,3}").isTrusted("10.42.3.26")).isTrue();
    }

    @Test
    @DisplayName("an IPv4-mapped IPv6 address defeats every IPv4 pattern")
    void ipv4MappedIpv6DefeatsIpv4Patterns() {
        // The remaining candidate explanation, and the one worth defending
        // against: if the address arrives in IPv6 form, an IPv4 pattern rejects
        // it and the gateway silently strips the headers.
        String mapped = "::ffff:10.42.3.26";
        assertThat(TrustedProxies.from("10\\.42\\.\\d{1,3}\\.\\d{1,3}").isTrusted(mapped)).isFalse();
        assertThat(TrustedProxies.from("10\\.42\\..*").isTrusted(mapped)).isFalse();
    }

    @Test
    @DisplayName("OBSERVED: what Reactor Netty reports as the remote address")
    void observeTheRemoteAddressFormReactorNettyProduces() {
        // Not an assertion about Kubernetes -- it cannot be, from a unit test.
        // It pins the FORM the gateway's own server stack produces for an IPv4
        // connection, which is the fact the two previous attempts guessed at.
        AtomicReference<String> seen = new AtomicReference<>();

        DisposableServer server = HttpServer
            .create()
            .host("127.0.0.1")
            .port(0)
            .handle((req, res) -> {
                InetSocketAddress remote = req.remoteAddress();
                seen.set(remote == null ? null : remote.getHostString());
                return res.sendString(reactor.core.publisher.Mono.just("ok"));
            })
            .bindNow();

        try {
            HttpClient
                .create()
                .get()
                .uri("http://127.0.0.1:" + server.port() + "/")
                .responseContent()
                .aggregate()
                .block(Duration.ofSeconds(10));
        } finally {
            server.disposeNow();
        }

        String observed = seen.get();
        assertThat(observed).as("remote address as the filter sees it").isNotNull();

        // The two things that actually matter, stated as properties rather than
        // as a literal, because the literal is environment-specific:
        assertThat(observed).as("carries no port -- the reverted hypothesis").doesNotContain(":" + server.port());

        // And the pattern this task lands must accept whatever form that is.
        assertThat(TrustedProxies.from(loopbackPattern()).isTrusted(observed))
            .as("observed form %s must be matched by the pattern shape we ship", observed)
            .isTrue();
    }


    @Test
    @DisplayName("an untrusted remote address strips EVERY X-Forwarded-* header")
    void untrustedRemoteAddressStripsEveryForwardedHeader() {
        // This is the regression 0c8129a shipped, made executable. The upstream
        // filter does not merely decline to ADD headers when the peer is not
        // trusted -- it removes the ones nginx already set, so core receives no
        // host and no proto and falls back to its own in-cluster address.
        //
        // That is why a wrong value here is worse than no value: it does not
        // fail closed on the attack, it fails open on the client contract.
        XForwardedHeadersFilter filter = new XForwardedHeadersFilter("10\\.42\\..*");

        HttpHeaders incoming = new HttpHeaders();
        incoming.add("X-Forwarded-Host", "app-dev.xenopsoftware.com");
        incoming.add("X-Forwarded-Proto", "https");
        incoming.add("Accept", "application/json");

        MockServerHttpRequest request = MockServerHttpRequest
            .get("/services/core/api/documents")
            .remoteAddress(new InetSocketAddress("192.0.2.10", 44444))
            .headers(incoming)
            .build();

        HttpHeaders result = filter.filter(incoming, MockServerWebExchange.from(request));

        assertThat(result.headerNames()).noneMatch(h -> h.toLowerCase(java.util.Locale.ROOT).startsWith("x-forwarded-"));
        assertThat(result.getFirst("Accept")).as("non-forwarded headers survive").isEqualTo("application/json");
    }

    @Test
    @DisplayName("a trusted remote address preserves the proto core builds https:// links from")
    void trustedRemoteAddressPreservesProto() {
        XForwardedHeadersFilter filter = new XForwardedHeadersFilter("10\\.42\\..*");

        HttpHeaders incoming = new HttpHeaders();
        incoming.add("X-Forwarded-Host", "app-dev.xenopsoftware.com");
        incoming.add("X-Forwarded-Proto", "https");

        MockServerHttpRequest request = MockServerHttpRequest
            .get("/services/core/api/documents")
            .remoteAddress(new InetSocketAddress("10.42.3.26", 44444))
            .headers(incoming)
            .build();

        HttpHeaders result = filter.filter(incoming, MockServerWebExchange.from(request));

        assertThat(result.getFirst("X-Forwarded-Host")).isEqualTo("app-dev.xenopsoftware.com");
        assertThat(result.headerNames()).anyMatch(h -> h.equalsIgnoreCase("X-Forwarded-Proto"));
    }

    /**
     * The shape of pattern this task ships, exercised against loopback rather
     * than the cluster range: an explicit alternation that accepts both the
     * IPv4 literal and the IPv4-mapped IPv6 form of the same address.
     */
    private static String loopbackPattern() {
        return "(127\\.0\\.0\\.1|::ffff:127\\.0\\.0\\.1|0:0:0:0:0:ffff:7f00:1|::1)";
    }
}
