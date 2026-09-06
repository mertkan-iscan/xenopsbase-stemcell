package com.xenopsoftware.core.platform;

import com.xenopsoftware.common.security.AuthoritiesConstants;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Two endpoints that answer "did identity actually arrive, and does authorization actually fire?"
 * (T-9.2).
 *
 * <p>Both were on {@code ExampleItemResource}, which was deleted with the rest of the demo domain.
 * They are here rather than deleted with it because each is the ONLY test of something real, and
 * both failures are silent:
 *
 * <ul>
 *   <li>a broken token relay does not error — requests still succeed, they are just anonymous by
 *       the time they land here;</li>
 *   <li>an authorization rule that denies everybody looks exactly like one that works, until
 *       somebody with the role tries it.</li>
 * </ul>
 *
 * <p>Unlike {@link PlatformProbeResource} this carries no {@code @ConditionalOnObjectStore}: a fork
 * with no bucket still has identity and still has authorization rules, and losing the endpoint that
 * proves them because storage is unconfigured would be the wrong coupling.
 */
@RestController
@RequestMapping("/api")
public class PlatformIdentityResource {

    private final PlatformProbeRepository repository;

    public PlatformIdentityResource(PlatformProbeRepository repository) {
        this.repository = repository;
    }

    /**
     * Proves the identity actually arrived. The gateway relays the access token inward, so this
     * reports what THIS service sees — not what the gateway saw. Those differ whenever the relay
     * is misconfigured, and without an endpoint like this the difference is invisible: requests
     * still succeed, they are just anonymous by the time they land here.
     */
    @GetMapping("/whoami")
    public Map<String, Object> whoami(Authentication authentication) {
        if (authentication == null) {
            return Map.of("authenticated", false);
        }
        // HashMap, not Map.of: Map.of rejects null values, and getName() is null for a
        // client-credentials token, which carries no preferred_username. That turned a working
        // relay into an opaque 500 -- the identity had arrived correctly and the endpoint
        // reporting it was what failed.
        Map<String, Object> out = new HashMap<>();
        out.put("authenticated", authentication.isAuthenticated());
        out.put("name", authentication.getName());
        out.put("authorities", authentication.getAuthorities().stream().map(Object::toString).toList());
        if (authentication.getPrincipal() instanceof Jwt jwt) {
            // What this service sees in the relayed token, which is the whole point.
            out.put("iss", jwt.getClaimAsString("iss"));
            out.put("aud", jwt.getClaimAsStringList("aud"));
            out.put("azp", jwt.getClaimAsString("azp"));
            out.put("scope", jwt.getClaimAsString("scope"));
            out.put("sub", jwt.getClaimAsString("sub"));
        }
        return out;
    }

    /**
     * Method-level authorization, and the seam a fork extends.
     *
     * <p>The realm defines {@code app-user} and {@code app-admin}; {@code SecurityUtils} maps each
     * to both the raw name and a {@code ROLE_} form, so either spelling works:
     *
     * <pre>
     *   &#64;PreAuthorize("hasAuthority('app-admin')")   // Keycloak's name
     *   &#64;PreAuthorize("hasRole('APP_ADMIN')")        // Spring's convention
     * </pre>
     *
     * <p>TO ADD A ROLE: add it to {@code roles.realm} in the realm import, add a constant to
     * {@code AuthoritiesConstants}, then reference it here. Nothing else changes — that is the
     * point of putting the translation in one place.
     *
     * <p><b>Why this returns other people's rows on purpose.</b> Every other read in this package
     * is scoped to the caller's {@code sub}. This one is not, and that difference is the assertion:
     * a token without {@code app-admin} gets 403 here while still being accepted everywhere else,
     * which is the distinction that matters — authenticated is not authorized. Bounded to one page
     * because an admin endpoint that returns the whole table is a denial of service with a role
     * attached.
     */
    @GetMapping("/admin/platform/probe")
    @PreAuthorize("hasAuthority('" + AuthoritiesConstants.ADMIN + "')")
    public List<PlatformProbe> listAsAdmin() {
        return repository.findAll(PageRequest.of(0, 100, Sort.by(Sort.Direction.DESC, "createdAt"))).getContent();
    }
}
