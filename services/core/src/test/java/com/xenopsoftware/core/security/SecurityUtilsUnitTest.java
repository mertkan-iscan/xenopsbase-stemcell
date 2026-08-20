package com.xenopsoftware.core.security;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.oauth2.core.oidc.endpoint.OidcParameterNames.ID_TOKEN;

import java.time.Instant;
import java.util.*;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContext;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.client.authentication.OAuth2AuthenticationToken;
import org.springframework.security.oauth2.core.oidc.OidcIdToken;
import org.springframework.security.oauth2.core.oidc.user.DefaultOidcUser;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;

/**
 * Test class for the {@link SecurityUtils} utility class.
 */
class SecurityUtilsUnitTest {

    @BeforeEach
    @AfterEach
    void cleanup() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void testGetCurrentUserLogin() {
        SecurityContext securityContext = SecurityContextHolder.createEmptyContext();
        securityContext.setAuthentication(new UsernamePasswordAuthenticationToken("admin", "admin"));
        SecurityContextHolder.setContext(securityContext);
        Optional<String> login = SecurityUtils.getCurrentUserLogin();
        assertThat(login).contains("admin");
    }

    @Test
    void testGetCurrentUserLoginForOAuth2() {
        SecurityContext securityContext = SecurityContextHolder.createEmptyContext();
        Map<String, Object> claims = new HashMap<>();
        claims.put("groups", AuthoritiesConstants.USER);
        claims.put("sub", 123);
        claims.put("preferred_username", "admin");
        OidcIdToken idToken = new OidcIdToken(ID_TOKEN, Instant.now(), Instant.now().plusSeconds(60), claims);
        Collection<GrantedAuthority> authorities = new ArrayList<>();
        authorities.add(new SimpleGrantedAuthority(AuthoritiesConstants.USER));
        OidcUser user = new DefaultOidcUser(authorities, idToken);
        OAuth2AuthenticationToken auth2AuthenticationToken = new OAuth2AuthenticationToken(user, authorities, "oidc");
        securityContext.setAuthentication(auth2AuthenticationToken);
        SecurityContextHolder.setContext(securityContext);

        Optional<String> login = SecurityUtils.getCurrentUserLogin();

        assertThat(login).contains("admin");
    }

    /**
     * Keycloak puts realm roles in a nested {@code realm_access.roles} array. This is the shape every
     * token from this platform actually has, and reading only the flat claims below is what made
     * authorization silently deny everyone until T-3.5.
     */
    @Test
    void testExtractAuthorityFromRealmAccess() {
        Map<String, Object> claims = new HashMap<>();
        claims.put("realm_access", Map.of("roles", List.of(AuthoritiesConstants.ADMIN, AuthoritiesConstants.USER)));

        List<GrantedAuthority> authorities = SecurityUtils.extractAuthorityFromClaims(claims);

        assertThat(authorities)
            .extracting(GrantedAuthority::getAuthority)
            .containsExactlyInAnyOrder("app-admin", "app-user", "ROLE_APP_ADMIN", "ROLE_APP_USER");
    }

    /** Client roles arrive per-client under {@code resource_access.<client>.roles}. */
    @Test
    void testExtractAuthorityFromResourceAccess() {
        Map<String, Object> claims = new HashMap<>();
        claims.put("resource_access", Map.of("gateway", Map.of("roles", List.of(AuthoritiesConstants.ADMIN))));

        List<GrantedAuthority> authorities = SecurityUtils.extractAuthorityFromClaims(claims);

        assertThat(authorities).extracting(GrantedAuthority::getAuthority).containsExactlyInAnyOrder("app-admin", "ROLE_APP_ADMIN");
    }

    @Test
    void testExtractAuthorityFromClaims() {
        Map<String, Object> claims = new HashMap<>();
        claims.put("groups", List.of(AuthoritiesConstants.ADMIN, AuthoritiesConstants.USER));

        List<GrantedAuthority> authorities = SecurityUtils.extractAuthorityFromClaims(claims);

        assertThat(authorities)
            .extracting(GrantedAuthority::getAuthority)
            .containsExactlyInAnyOrder("app-admin", "app-user", "ROLE_APP_ADMIN", "ROLE_APP_USER");
    }

    @Test
    void testExtractAuthorityFromClaims_NamespacedRoles() {
        Map<String, Object> claims = new HashMap<>();
        claims.put(SecurityUtils.CLAIMS_NAMESPACE + "roles", List.of(AuthoritiesConstants.ADMIN, AuthoritiesConstants.USER));

        List<GrantedAuthority> authorities = SecurityUtils.extractAuthorityFromClaims(claims);

        assertThat(authorities)
            .extracting(GrantedAuthority::getAuthority)
            .containsExactlyInAnyOrder("app-admin", "app-user", "ROLE_APP_ADMIN", "ROLE_APP_USER");
    }

    /**
     * Each Keycloak role yields two authorities: the raw name, which {@code @PreAuthorize} checks
     * with {@code hasAuthority}, and a normalised {@code ROLE_} alias for {@code hasRole} and for
     * any generator-era code that still expects the Spring convention.
     */
    @Test
    void testExtractAuthorityFromClaims_MapsHyphensAndDotsInTheRoleAlias() {
        Map<String, Object> claims = new HashMap<>();
        claims.put("realm_access", Map.of("roles", List.of("billing.read-only")));

        List<GrantedAuthority> authorities = SecurityUtils.extractAuthorityFromClaims(claims);

        assertThat(authorities)
            .extracting(GrantedAuthority::getAuthority)
            .containsExactlyInAnyOrder("billing.read-only", "ROLE_BILLING_READ_ONLY");
    }

    /** A role already carrying the prefix must not become {@code ROLE_ROLE_ADMIN}. */
    @Test
    void testExtractAuthorityFromClaims_DoesNotDoublePrefix() {
        Map<String, Object> claims = new HashMap<>();
        claims.put("realm_access", Map.of("roles", List.of("ROLE_ADMIN")));

        List<GrantedAuthority> authorities = SecurityUtils.extractAuthorityFromClaims(claims);

        assertThat(authorities).extracting(GrantedAuthority::getAuthority).containsExactly("ROLE_ADMIN");
    }

    @Test
    void testIsAuthenticated() {
        SecurityContext securityContext = SecurityContextHolder.createEmptyContext();
        securityContext.setAuthentication(new UsernamePasswordAuthenticationToken("admin", "admin"));
        SecurityContextHolder.setContext(securityContext);
        boolean isAuthenticated = SecurityUtils.isAuthenticated();
        assertThat(isAuthenticated).isTrue();
    }

    @Test
    void testAnonymousIsNotAuthenticated() {
        SecurityContext securityContext = SecurityContextHolder.createEmptyContext();
        var authorities = List.of(new SimpleGrantedAuthority(AuthoritiesConstants.ANONYMOUS));
        securityContext.setAuthentication(new UsernamePasswordAuthenticationToken("anonymous", "anonymous", authorities));
        SecurityContextHolder.setContext(securityContext);
        boolean isAuthenticated = SecurityUtils.isAuthenticated();
        assertThat(isAuthenticated).isFalse();
    }

    @Test
    void testHasCurrentUserThisAuthority() {
        SecurityContext securityContext = SecurityContextHolder.createEmptyContext();
        var authorities = List.of(new SimpleGrantedAuthority(AuthoritiesConstants.USER));
        securityContext.setAuthentication(new UsernamePasswordAuthenticationToken("anonymous", "anonymous", authorities));
        SecurityContextHolder.setContext(securityContext);

        assertThat(SecurityUtils.hasCurrentUserThisAuthority(AuthoritiesConstants.USER)).isTrue();
        assertThat(SecurityUtils.hasCurrentUserThisAuthority(AuthoritiesConstants.ADMIN)).isFalse();
    }

    @Test
    void testHasCurrentUserAnyOfAuthorities() {
        SecurityContext securityContext = SecurityContextHolder.createEmptyContext();
        var authorities = List.of(new SimpleGrantedAuthority(AuthoritiesConstants.USER));
        securityContext.setAuthentication(new UsernamePasswordAuthenticationToken("anonymous", "anonymous", authorities));
        SecurityContextHolder.setContext(securityContext);

        assertThat(SecurityUtils.hasCurrentUserAnyOfAuthorities(AuthoritiesConstants.USER, AuthoritiesConstants.ADMIN)).isTrue();
        assertThat(SecurityUtils.hasCurrentUserAnyOfAuthorities(AuthoritiesConstants.ANONYMOUS, AuthoritiesConstants.ADMIN)).isFalse();
    }

    @Test
    void testHasCurrentUserNoneOfAuthorities() {
        SecurityContext securityContext = SecurityContextHolder.createEmptyContext();
        var authorities = List.of(new SimpleGrantedAuthority(AuthoritiesConstants.USER));
        securityContext.setAuthentication(new UsernamePasswordAuthenticationToken("anonymous", "anonymous", authorities));
        SecurityContextHolder.setContext(securityContext);

        assertThat(SecurityUtils.hasCurrentUserNoneOfAuthorities(AuthoritiesConstants.USER, AuthoritiesConstants.ADMIN)).isFalse();
        assertThat(SecurityUtils.hasCurrentUserNoneOfAuthorities(AuthoritiesConstants.ANONYMOUS, AuthoritiesConstants.ADMIN)).isTrue();
    }
}
