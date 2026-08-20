package com.xenopsoftware.core.security;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContext;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.oauth2.core.oidc.user.DefaultOidcUser;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;

/**
 * Utility class for Spring Security.
 */
public final class SecurityUtils {

    public static final String CLAIMS_NAMESPACE = "https://www.jhipster.tech/";

    private SecurityUtils() {}

    /**
     * Get the login of the current user.
     *
     * @return the login of the current user.
     */
    public static Optional<String> getCurrentUserLogin() {
        SecurityContext securityContext = SecurityContextHolder.getContext();
        return Optional.ofNullable(extractPrincipal(securityContext.getAuthentication()));
    }

    private static String extractPrincipal(Authentication authentication) {
        if (authentication == null) {
            return null;
        } else if (authentication.getPrincipal() instanceof UserDetails springSecurityUser) {
            return springSecurityUser.getUsername();
        } else if (authentication instanceof JwtAuthenticationToken jwtToken) {
            return (String) jwtToken.getToken().getClaims().get("preferred_username");
        } else if (authentication.getPrincipal() instanceof DefaultOidcUser oidcUser) {
            Map<String, Object> attributes = oidcUser.getAttributes();
            if (attributes.containsKey("preferred_username")) {
                return (String) attributes.get("preferred_username");
            }
        } else if (authentication.getPrincipal() instanceof String s) {
            return s;
        }
        return null;
    }

    /**
     * Check if a user is authenticated.
     *
     * @return true if the user is authenticated, false otherwise.
     */
    public static boolean isAuthenticated() {
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        return authentication != null && getAuthorities(authentication).noneMatch(AuthoritiesConstants.ANONYMOUS::equals);
    }

    /**
     * Checks if the current user has any of the authorities.
     *
     * @param authorities the authorities to check.
     * @return true if the current user has any of the authorities, false otherwise.
     */
    public static boolean hasCurrentUserAnyOfAuthorities(String... authorities) {
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        return authentication != null && getAuthorities(authentication).anyMatch(authority -> List.of(authorities).contains(authority));
    }

    /**
     * Checks if the current user has none of the authorities.
     *
     * @param authorities the authorities to check.
     * @return true if the current user has none of the authorities, false otherwise.
     */
    public static boolean hasCurrentUserNoneOfAuthorities(String... authorities) {
        return !hasCurrentUserAnyOfAuthorities(authorities);
    }

    /**
     * Checks if the current user has a specific authority.
     *
     * @param authority the authority to check.
     * @return true if the current user has the authority, false otherwise.
     */
    public static boolean hasCurrentUserThisAuthority(String authority) {
        return hasCurrentUserAnyOfAuthorities(authority);
    }

    private static Stream<String> getAuthorities(Authentication authentication) {
        Collection<? extends GrantedAuthority> authorities =
            authentication instanceof JwtAuthenticationToken jwtToken
                ? extractAuthorityFromClaims(jwtToken.getToken().getClaims())
                : authentication.getAuthorities();
        return authorities.stream().map(GrantedAuthority::getAuthority);
    }

    public static List<GrantedAuthority> extractAuthorityFromClaims(Map<String, Object> claims) {
        return mapRolesToGrantedAuthorities(getRolesFromClaims(claims));
    }

    /**
     * Pulls roles out of a Keycloak token.
     *
     * KEYCLOAK PUTS REALM ROLES IN realm_access.roles -- a nested object, not a
     * top-level claim. The generated code read only "groups", "roles" and a
     * JHipster namespace, none of which Keycloak populates, so every realm role
     * was silently discarded: tokens carried app-user and app-admin, the
     * application saw neither, and every authorization check evaluated against
     * an empty authority list.
     *
     * The other claim names are kept as fallbacks so this still works against a
     * provider that flattens roles differently.
     */
    @SuppressWarnings("unchecked")
    private static Collection<String> getRolesFromClaims(Map<String, Object> claims) {
        Collection<String> roles = new LinkedHashSet<>();

        Object realmAccess = claims.get("realm_access");
        if (realmAccess instanceof Map<?, ?> realmAccessMap) {
            Object realmRoles = realmAccessMap.get("roles");
            if (realmRoles instanceof Collection<?> collection) {
                collection.forEach(r -> roles.add(String.valueOf(r)));
            }
        }

        // Client roles, for the resource_access.<client>.roles shape. Only used
        // when a project needs per-client roles; realm roles are the default.
        Object resourceAccess = claims.get("resource_access");
        if (resourceAccess instanceof Map<?, ?> resourceAccessMap) {
            for (Object client : resourceAccessMap.values()) {
                if (client instanceof Map<?, ?> clientMap && clientMap.get("roles") instanceof Collection<?> collection) {
                    collection.forEach(r -> roles.add(String.valueOf(r)));
                }
            }
        }

        for (String fallback : List.of("groups", "roles", CLAIMS_NAMESPACE + "roles")) {
            Object value = claims.get(fallback);
            if (value instanceof Collection<?> collection) {
                collection.forEach(r -> roles.add(String.valueOf(r)));
            }
        }
        return roles;
    }

    /**
     * Each role becomes TWO authorities, deliberately.
     *
     * Keycloak names roles the way humans write them (app-admin). Spring's
     * hasRole() silently prepends ROLE_ and upper-cases nothing, so
     * hasRole("app-admin") looks for ROLE_app-admin and never matches -- a
     * check that compiles, runs, and quietly denies everyone.
     *
     * Emitting both the raw name and ROLE_APP_ADMIN means hasAuthority("app-admin")
     * and hasRole("APP_ADMIN") both work, and neither reading of the code is
     * wrong. The previous filter kept only names already starting with ROLE_,
     * which discarded every Keycloak role there has ever been.
     */
    private static List<GrantedAuthority> mapRolesToGrantedAuthorities(Collection<String> roles) {
        return roles
            .stream()
            .filter(role -> role != null && !role.isBlank())
            .flatMap(role -> {
                String springRole = "ROLE_" + role.replace('-', '_').replace('.', '_').toUpperCase(Locale.ROOT);
                return role.startsWith("ROLE_") ? Stream.of(role) : Stream.of(role, springRole);
            })
            .distinct()
            .map(SimpleGrantedAuthority::new)
            .collect(Collectors.toList());
    }
}
