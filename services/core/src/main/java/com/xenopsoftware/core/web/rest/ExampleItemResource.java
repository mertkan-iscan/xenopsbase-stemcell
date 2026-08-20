package com.xenopsoftware.core.web.rest;

import com.xenopsoftware.core.domain.ExampleItem;
import com.xenopsoftware.core.repository.ExampleItemRepository;
import com.xenopsoftware.core.security.AuthoritiesConstants;
import jakarta.validation.Valid;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

/**
 * DELETE THIS along with {@link ExampleItem}.
 *
 * Two endpoints, each proving something the next real controller depends on.
 */
@RestController
@RequestMapping("/api")
public class ExampleItemResource {

    private final ExampleItemRepository repository;

    public ExampleItemResource(ExampleItemRepository repository) {
        this.repository = repository;
    }

    /**
     * Proves the identity actually arrived. The gateway relays the access token
     * inward, so this reports what the CORE service sees -- not what the gateway
     * saw. Those differ whenever the relay is misconfigured, and without an
     * endpoint like this the difference is invisible: requests still succeed,
     * they are just anonymous by the time they land here.
     */
    @GetMapping("/whoami")
    public Map<String, Object> whoami(Authentication authentication) {
        if (authentication == null) {
            return Map.of("authenticated", false);
        }
        // HashMap, not Map.of: Map.of rejects null values, and getName() is null
        // for a client-credentials token, which carries no preferred_username.
        // That turned a working relay into an opaque 500 -- the identity had
        // arrived correctly and the endpoint reporting it was what failed.
        Map<String, Object> out = new HashMap<>();
        out.put("authenticated", authentication.isAuthenticated());
        out.put("name", authentication.getName());
        out.put("authorities", authentication.getAuthorities().stream().map(Object::toString).toList());
        if (authentication.getPrincipal() instanceof Jwt jwt) {
            // What the CORE service sees in the relayed token, which is the
            // whole point of this endpoint.
            out.put("iss", jwt.getClaimAsString("iss"));
            out.put("aud", jwt.getClaimAsStringList("aud"));
            out.put("azp", jwt.getClaimAsString("azp"));
            out.put("scope", jwt.getClaimAsString("scope"));
            out.put("sub", jwt.getClaimAsString("sub"));
        }
        return out;
    }

    /**
     * Method-level authorization, and the seam projects extend.
     *
     * The realm defines app-user and app-admin; SecurityUtils maps each to both
     * the raw name and a ROLE_ form, so either spelling works:
     *
     *   @PreAuthorize("hasAuthority('app-admin')")   // Keycloak's name
     *   @PreAuthorize("hasRole('APP_ADMIN')")        // Spring's convention
     *
     * TO ADD A ROLE: add it to roles.realm in the realm import, add a constant
     * to AuthoritiesConstants, then reference it here. Nothing else changes --
     * that is the point of putting the translation in one place.
     *
     * This endpoint exists to prove the chain works end to end. A token without
     * app-admin gets 403 here while still being accepted everywhere else, which
     * is the distinction that matters: authenticated is not authorized.
     */
    @GetMapping("/admin/example-items")
    @PreAuthorize("hasAuthority('" + AuthoritiesConstants.ADMIN + "')")
    public List<ExampleItem> listAsAdmin() {
        return repository.findAll();
    }

    /** Proves JPA, Flyway and ddl-auto=validate agree about the schema. */
    @GetMapping("/example-items")
    public List<ExampleItem> list() {
        return repository.findAll();
    }

    @PostMapping("/example-items")
    public ResponseEntity<ExampleItem> create(@Valid @RequestBody ExampleItem item) {
        item.setId(null);
        return ResponseEntity.ok(repository.save(item));
    }
}
