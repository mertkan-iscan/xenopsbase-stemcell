package com.xenopsoftware.gateway.security;

/**
 * Constants for Spring Security authorities.
 */
public final class AuthoritiesConstants {

    /**
     * These MUST match the realm roles in
     * platform/envs/dev/keycloak/realm-import.yaml. Keycloak is the source of
     * truth; this file only names what it issues.
     *
     * The generated constants were ROLE_ADMIN and ROLE_USER, which no token has
     * ever contained -- so every check against them denied silently. Core hit
     * this and fixed it; the gateway kept the generated names, which is half of
     * why every admin rule here refused the administrator (T-3.20, #186). The
     * other half was that the authorities were empty to begin with, because
     * they were read from UserInfo -- see SecurityConfiguration#oidcUserService.
     *
     * Either defect alone is enough to break every admin endpoint, which is
     * worth remembering: fixing one and testing against a rule that was already
     * unreachable proves nothing.
     *
     * Renaming them here rather than renaming the realm roles keeps Keycloak's
     * naming readable (app-admin, not ROLE_APP_ADMIN) and puts the translation
     * in one place: SecurityUtils, which emits both spellings.
     *
     * Adding a role is therefore two edits, in this order:
     *   1. add it to `roles.realm` in the realm import, and let it apply
     *   2. add a constant here and use it in the authorization rules
     */
    public static final String ADMIN = "app-admin";

    public static final String USER = "app-user";

    public static final String ANONYMOUS = "ROLE_ANONYMOUS";

    private AuthoritiesConstants() {}
}
