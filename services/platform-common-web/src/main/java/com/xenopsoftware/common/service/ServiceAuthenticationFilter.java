package com.xenopsoftware.common.service;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtException;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Who is calling, and whether they may (T-9.4).
 *
 * <h2>Two credentials, and each answers a different question</h2>
 *
 * The {@code Authorization} bearer is the <b>end user's own token</b>, forwarded unchanged through
 * every hop. The callee validates it exactly as it would from the edge — signature, issuer,
 * audience, expiry — which is what makes the propagated identity <b>verified rather than
 * asserted</b>. A calling service cannot fabricate a user it was never given, because doing so
 * would mean forging a Keycloak signature.
 *
 * <p>{@link #HEADER} carries the caller's own client-credentials token, and it answers "which
 * service is this". The answer comes from the realm — the {@code svc-caller} role is granted to
 * service accounts and to nothing else — not from a header the caller writes, so a service cannot
 * claim to be one.
 *
 * <p>The alternative, trusting a header like {@code X-On-Behalf-Of}, is what makes a permission
 * model decorative: every service becomes able to act as any user, and a bug in the least careful
 * one is a full compromise.
 *
 * <h2>How this differs from the shape it was ported from</h2>
 *
 * xenopsbase-learn distinguishes a service token by a custom {@code svc} claim. This realm uses the
 * {@code svc-caller} REALM ROLE instead, because realm roles already reach the token through the
 * built-in {@code roles} client scope that every client here declares — and adding a custom claim
 * mapper would have been a fourth thing to remember per service, in a file whose comments already
 * record two occasions where a forgotten mapper produced tokens that looked fine and were refused
 * everywhere.
 *
 * <h2>What is refused</h2>
 *
 * A request presenting a service header that does not verify is refused outright, and counted.
 * <b>Absence is not refusal</b>: a request with no service header is an ordinary edge request,
 * which the security chain judges on the user token alone. That distinction is what lets this
 * filter be present in every service while inter-service calls do not yet exist.
 */
@Order(Ordered.LOWEST_PRECEDENCE - 110)
public class ServiceAuthenticationFilter extends OncePerRequestFilter {

    /**
     * Deliberately not {@code Authorization}. The user's token already occupies that header and
     * must arrive at the callee untouched; a scheme that overwrote it would replace a verified
     * person with a machine, which is precisely the substitution this design exists to prevent.
     */
    public static final String HEADER = "X-Service-Authorization";

    /** The realm role a service account holds, and an ordinary user never does. */
    public static final String SERVICE_ROLE = "svc-caller";

    private static final Logger LOG = LoggerFactory.getLogger(ServiceAuthenticationFilter.class);

    private final JwtDecoder decoder;
    private final AtomicLong refused = new AtomicLong();

    public ServiceAuthenticationFilter(JwtDecoder decoder) {
        this.decoder = decoder;
    }

    /** How many calls have been refused for a bad service credential. */
    public long refusedCount() {
        return refused.get();
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
        throws ServletException, IOException {
        String header = request.getHeader(HEADER);
        if (header == null || header.isBlank()) {
            // Not an inter-service call. The security chain still judges the user token.
            chain.doFilter(request, response);
            return;
        }
        if (!header.startsWith("Bearer ")) {
            reject(response, "malformed");
            return;
        }

        Jwt jwt;
        try {
            jwt = decoder.decode(header.substring("Bearer ".length()));
        } catch (JwtException e) {
            // The message, not the stack: a rejected credential is an operational event rather than
            // a defect, and a stack trace per refused call is how a log stops being readable during
            // exactly the incident it is needed for.
            LOG.warn("Refused a service call: the service credential did not verify ({})", e.getMessage());
            reject(response, "invalid");
            return;
        }

        if (!realmRolesOf(jwt).contains(SERVICE_ROLE)) {
            // A VALID token that is not a service account's. Refused rather than downgraded to an
            // ordinary request, because presenting this header is a claim to be a service, and a
            // claim that is wrong should fail loudly rather than quietly become something else.
            LOG.warn("Refused a service call: token for '{}' does not hold {}", jwt.getClaimAsString("azp"), SERVICE_ROLE);
            reject(response, "not a service account");
            return;
        }

        // The authority is what @PreAuthorize can be written against. Set on the SERVICE
        // credential's own authentication, deliberately: the user's token stays untouched in the
        // Authorization header and is authenticated by the resource-server chain as usual, so a
        // request can be both "from service X" and "on behalf of person Y" without either claim
        // overwriting the other.
        var authentication = new JwtAuthenticationToken(jwt, List.of(new SimpleGrantedAuthority(SERVICE_ROLE)));
        SecurityContextHolder.getContext().setAuthentication(authentication);
        try {
            chain.doFilter(request, response);
        } finally {
            // Threads are pooled. A service identity left behind is the next request's identity,
            // which is the same class of bug as a leaked tenant and is worse than having none.
            SecurityContextHolder.clearContext();
        }
    }

    @SuppressWarnings("unchecked")
    private static List<String> realmRolesOf(Jwt jwt) {
        Map<String, Object> realmAccess = jwt.getClaimAsMap("realm_access");
        if (realmAccess == null || !(realmAccess.get("roles") instanceof List<?> roles)) {
            return List.of();
        }
        return (List<String>) roles;
    }

    private void reject(HttpServletResponse response, String why) throws IOException {
        refused.incrementAndGet();
        response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
        response.setContentType("application/problem+json");
        // Deliberately terse. The caller is a service, not a person, and a detailed reason here is
        // a probing oracle for anyone who reached this endpoint without a credential.
        response.getWriter().write("{\"title\":\"Service credential rejected\",\"status\":401,\"detail\":\"" + why + "\"}");
    }
}
