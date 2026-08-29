package com.xenopsoftware.gateway.config;

import java.net.InetSocketAddress;
import org.springframework.cloud.gateway.filter.ratelimit.KeyResolver;
import org.springframework.cloud.gateway.support.ipresolver.XForwardedRemoteAddressResolver;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.AnonymousAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.ReactiveSecurityContextHolder;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

/**
 * Who a rate limit counts against (T-8.3, #61).
 *
 * <h2>Why this bean exists at all</h2>
 *
 * {@code RequestRateLimiter} needs to be told what "a client" is. Spring Cloud Gateway ships no
 * default, deliberately: the answer is application-specific, and getting it wrong produces a limiter
 * that looks configured and governs nothing.
 *
 * <p>Two ways to get it wrong here, both of which produce ONE bucket for everybody:
 *
 * <ul>
 *   <li>Keying on the remote address without the forwarded chain. Every request arrives from
 *       ingress-nginx, so the limit becomes a global ceiling and the first busy user rate-limits the
 *       rest. This gateway is already configured so that {@code getRemoteAddress()} carries the real
 *       client — see the {@code trusted-proxies} block in application.yml, which was settled by
 *       measurement on the live cluster — but that is a property to depend on knowingly rather than
 *       to assume.
 *   <li>Keying on the authentication without excluding anonymous. An
 *       {@link AnonymousAuthenticationToken} reports {@code isAuthenticated() == true} and always
 *       has the same name, so every unauthenticated request would share the bucket named
 *       {@code anonymousUser}. That is the same global ceiling wearing a different label, and it is
 *       the one that looks correct in review.
 * </ul>
 *
 * <h2>The key</h2>
 *
 * <pre>
 *   sub:&lt;keycloak subject&gt;   for an authenticated session
 *   ip:&lt;client address&gt;      otherwise
 * </pre>
 *
 * <p>The subject is preferred because it survives a client changing address — a phone moving between
 * networks mid-session should keep its bucket, and an attacker rotating addresses should not get a
 * fresh one for free once authenticated. Before login there is nothing else to key on.
 *
 * <p>{@code sub} rather than {@code preferred_username}: #140 was a NullPointerException from a token
 * that carried no {@code preferred_username}, and a rate limit key that can be null is a rate limit
 * that stops applying to exactly the tokens that are unusual.
 *
 * <h2>Why the IP key is only as good as the edge</h2>
 *
 * {@code trusted-proxies} is {@code '.*'} — the reasoning, and the two measurements behind it, are in
 * application.yml. Anything that could reach the origin directly could therefore present its own
 * {@code X-Forwarded-For} and mint a fresh bucket per request.
 *
 * <p>Nothing can: {@code cloudflared} dials outward and there is no public listener (ADR-0006), so the
 * header is written by Cloudflare. That makes the edge rate limit not a redundant second layer but
 * the thing that makes this one meaningful — which is why T-8.3 asks for both.
 *
 * <h2>What happens when the key cannot be resolved</h2>
 *
 * The request is served. {@code deny-empty-key} is false in configuration, so a client this cannot
 * identify gets through rather than getting a 403. A limiter that fails closed turns a bug in
 * identifying callers into an outage, and the edge limit is still in front of it.
 */
@Configuration
public class RateLimiterConfiguration {

    /**
     * Resolves the bucket key for one request.
     *
     * <p>Referenced by name from application.yml as {@code #{@clientKeyResolver}}. Naming it there
     * rather than relying on "there is exactly one KeyResolver bean" means adding a second resolver
     * later is a compile-time question rather than a silent change of behaviour.
     */
    @Bean
    public KeyResolver clientKeyResolver() {
        XForwardedRemoteAddressResolver addressResolver = XForwardedRemoteAddressResolver.maxTrustedIndex(1);

        return exchange ->
            ReactiveSecurityContextHolder.getContext()
                .map(context -> context.getAuthentication())
                .filter(RateLimiterConfiguration::isRealUser)
                .map(RateLimiterConfiguration::subjectOf)
                .filter(subject -> !subject.isBlank())
                .map(subject -> "sub:" + subject)
                // switchIfEmpty rather than defaultIfEmpty: the address lookup should happen only
                // when it is needed, not on every authenticated request as well.
                .switchIfEmpty(Mono.fromSupplier(() -> "ip:" + clientAddress(addressResolver, exchange)));
    }

    /**
     * True for a real principal. Anonymous authentication is authenticated, which is the trap this
     * exists to avoid — see the class javadoc.
     */
    private static boolean isRealUser(Authentication authentication) {
        return authentication != null && authentication.isAuthenticated() && !(authentication instanceof AnonymousAuthenticationToken);
    }

    private static String subjectOf(Authentication authentication) {
        if (authentication.getPrincipal() instanceof OidcUser oidcUser && oidcUser.getSubject() != null) {
            return oidcUser.getSubject();
        }
        // getName() is the name-attribute claim, which is configurable and has been null here
        // before (#140). Kept as a fallback rather than as the primary, and null-safe.
        String name = authentication.getName();
        return name == null ? "" : name;
    }

    /**
     * The client's address, one proxy hop back.
     *
     * <p>{@code maxTrustedIndex(1)} takes the last entry of {@code X-Forwarded-For} — the address the
     * closest proxy observed — rather than the first, which is client-supplied and therefore
     * arbitrary. With Cloudflare and ingress-nginx both in the path the header can carry several
     * entries; the one written by the hop we actually talk to is the only one worth counting.
     *
     * <p>Falls back to the socket address when there is no forwarded header at all, which is the
     * in-cluster case — {@code make load-ratelimit} drives the gateway Service directly, and that is
     * how the k6 scenario gets a stable key.
     */
    private static String clientAddress(XForwardedRemoteAddressResolver resolver, ServerWebExchange exchange) {
        InetSocketAddress resolved = resolver.resolve(exchange);
        if (resolved != null && resolved.getAddress() != null) {
            return resolved.getAddress().getHostAddress();
        }
        InetSocketAddress remote = exchange.getRequest().getRemoteAddress();
        return remote == null || remote.getAddress() == null ? "" : remote.getAddress().getHostAddress();
    }
}
