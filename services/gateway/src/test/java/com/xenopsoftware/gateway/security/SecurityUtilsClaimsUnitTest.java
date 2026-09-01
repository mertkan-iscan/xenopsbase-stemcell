package com.xenopsoftware.gateway.security;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.security.core.GrantedAuthority;

/**
 * Tests for {@link SecurityUtils#extractAuthorityFromClaims(Map)}.
 *
 * <p>This is the function that decides what the bearer of a token is allowed to do: everything
 * downstream authorizes against the authorities it returns. Its two failure modes are not
 * symmetric. Dropping a role locks a user out, which someone reports within the hour. Inventing one
 * grants access nobody asked for, and produces no error, no log line and no failing request — the
 * only visible sign is that a request that should have been rejected succeeds.
 *
 * <p>It is also the seam between two vocabularies. Keycloak issues {@code app-admin}; Spring's
 * {@code hasRole} expects {@code ROLE_APP_ADMIN}. The mapping emits both, so a rule written either
 * way keeps working — which means a change to the naming convention has to keep emitting both, and
 * these tests are what says so.
 */
class SecurityUtilsClaimsUnitTest {

    private static List<String> authorityNamesFrom(Map<String, Object> claims) {
        return SecurityUtils.extractAuthorityFromClaims(claims).stream().map(GrantedAuthority::getAuthority).toList();
    }

    @Test
    void mapsRealmRolesToBothTheRawRoleAndItsSpringSpelling() {
        assertThat(authorityNamesFrom(Map.of("realm_access", Map.of("roles", List.of(AuthoritiesConstants.ADMIN))))).containsExactly(
            AuthoritiesConstants.ADMIN,
            "ROLE_APP_ADMIN"
        );
    }

    /**
     * Hyphens and dots are legal in a Keycloak role name and illegal in a Spring one, so they are
     * folded to underscores. Without this a role named {@code app.admin} would silently produce an
     * authority no {@code hasRole} expression can match.
     */
    @Test
    void foldsHyphensAndDotsToUnderscoresAndUppercasesTheSpringSpelling() {
        assertThat(authorityNamesFrom(Map.of("groups", List.of("tenant.read-only")))).containsExactly(
            "tenant.read-only",
            "ROLE_TENANT_READ_ONLY"
        );
    }

    /** A claim already in Spring's vocabulary is passed through once, not prefixed twice. */
    @Test
    void leavesAnAlreadyPrefixedRoleAlone() {
        assertThat(authorityNamesFrom(Map.of("roles", List.of("ROLE_ADMIN")))).containsExactly("ROLE_ADMIN");
    }

    @Test
    void readsRolesFromGroupsRolesAndTheNamespacedClaim() {
        assertThat(authorityNamesFrom(Map.of("groups", List.of("from-groups")))).contains("from-groups");
        assertThat(authorityNamesFrom(Map.of("roles", List.of("from-roles")))).contains("from-roles");
        assertThat(authorityNamesFrom(Map.of(SecurityUtils.CLAIMS_NAMESPACE + "roles", List.of("from-namespace")))).contains(
            "from-namespace"
        );
    }

    /**
     * Every client's roles under {@code resource_access} are merged, not just those of the client
     * this token was issued to. That is the template's documented behaviour rather than an accident,
     * but it means a role granted for a different client becomes an authority here, so it is pinned
     * deliberately: if the merge is ever narrowed to the audience, this test should be the thing
     * that fails and forces the decision to be made explicitly.
     */
    @Test
    void mergesClientRolesFromEveryClientUnderResourceAccess() {
        Map<String, Object> claims = Map.of(
            "resource_access",
            Map.of("web-app", Map.of("roles", List.of("web-role")), "other-client", Map.of("roles", List.of("other-role")))
        );
        assertThat(authorityNamesFrom(claims)).contains("web-role", "other-role");
    }

    @Test
    void collectsRealmAndClientAndFallbackRolesTogether() {
        Map<String, Object> claims = Map.of(
            "realm_access",
            Map.of("roles", List.of("realm-role")),
            "resource_access",
            Map.of("web-app", Map.of("roles", List.of("client-role"))),
            "groups",
            List.of("group-role")
        );
        assertThat(authorityNamesFrom(claims)).contains("realm-role", "client-role", "group-role");
    }

    /**
     * A role appearing in two places is one authority. Duplicates would not grant anything extra,
     * but they turn any equality assertion on the authority list into a test of claim ordering.
     */
    @Test
    void doesNotRepeatARoleThatAppearsInMoreThanOneClaim() {
        Map<String, Object> claims = Map.of("realm_access", Map.of("roles", List.of("shared")), "groups", List.of("shared"));
        assertThat(authorityNamesFrom(claims)).containsExactly("shared", "ROLE_SHARED");
    }

    @Test
    void ignoresBlankRoleNames() {
        assertThat(authorityNamesFrom(Map.of("groups", List.of("", "   ", "real")))).containsExactly("real", "ROLE_REAL");
    }

    /**
     * Claims come from a token, so their shapes are whatever the issuer sent. A wrongly-typed claim
     * has to be skipped rather than thrown on: an exception here fails the whole request, turning a
     * cosmetically malformed token into an outage instead of a user with fewer authorities.
     */
    @Test
    void skipsClaimsWhoseShapeIsNotTheOneItExpects() {
        assertThat(authorityNamesFrom(Map.of("realm_access", "not-a-map"))).isEmpty();
        assertThat(authorityNamesFrom(Map.of("realm_access", Map.of("roles", "not-a-collection")))).isEmpty();
        assertThat(authorityNamesFrom(Map.of("realm_access", Map.of("no-roles-key", List.of("x"))))).isEmpty();
        assertThat(authorityNamesFrom(Map.of("resource_access", "not-a-map"))).isEmpty();
        assertThat(authorityNamesFrom(Map.of("resource_access", Map.of("web-app", "not-a-map")))).isEmpty();
        assertThat(authorityNamesFrom(Map.of("resource_access", Map.of("web-app", Map.of("roles", "not-a-collection"))))).isEmpty();
        assertThat(authorityNamesFrom(Map.of("groups", "not-a-collection"))).isEmpty();
    }

    /** A token with no role claims at all grants nothing, rather than defaulting to anything. */
    @Test
    void grantsNothingWhenThereAreNoRoleClaims() {
        assertThat(authorityNamesFrom(Map.of("sub", "user-1"))).isEmpty();
        assertThat(authorityNamesFrom(Map.of())).isEmpty();
    }
}
