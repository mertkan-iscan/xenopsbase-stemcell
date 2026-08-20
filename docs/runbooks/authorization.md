# Runbook: authorization

Keycloak issues the roles; the services enforce them. **Keycloak is the source of truth** — nothing
in the application defines who may do what.

## How a role becomes a decision

```
realm-import.yaml      roles.realm: app-user, app-admin
   |                   users[].realmRoles assigns them
   v
token                  realm_access.roles: ["app-admin","app-user"]
   |                   (produced by the `roles` client scope, which Keycloak
   |                    creates itself — see the trap below)
   v
SecurityUtils          reads realm_access.roles, emits TWO authorities per role
   |                     app-admin  and  ROLE_APP_ADMIN
   v
@PreAuthorize          hasAuthority('app-admin')  or  hasRole('APP_ADMIN')
```

Both spellings exist deliberately. Spring's `hasRole()` silently prepends `ROLE_` and upper-cases
nothing, so `hasRole('app-admin')` looks for `ROLE_app-admin` and matches nothing — a check that
compiles, runs, and quietly denies everyone. Emitting both means neither reading is wrong.

## Adding a role — the worked example

Three edits, in this order. The order matters: a constant referencing a role the realm does not issue
denies silently.

**1. Define it in the realm** (`platform/envs/dev/keycloak/realm-import.yaml`):

```yaml
    roles:
      realm:
        - name: app-auditor
          description: Read-only access to audit endpoints.
```

**2. Name it in the service** (`security/AuthoritiesConstants.java`):

```java
    public static final String AUDITOR = "app-auditor";
```

**3. Use it:**

```java
    @GetMapping("/admin/audit")
    @PreAuthorize("hasAuthority('" + AuthoritiesConstants.AUDITOR + "')")
    public List<AuditEntry> audit() { ... }
```

Assign it to a user with `realmRoles:` in the realm import, or in the admin console for real users.

**Realm changes do not apply to an existing realm.** The import runs once, at realm creation. To
apply a change in dev, delete the realm and let the import recreate it — the procedure is at the
bottom of this page.

## Verified behaviour

```
                              smoke (app-user)   smoke-admin (app-admin)
/api/example-items                 200                   200
/api/admin/example-items           403                   200
```

Both directions matter. A 403 for an unprivileged user only shows the check fires; a check that
denies everyone looks identical to one that works.

## Service-to-service

Client credentials, never a shared header. The `gateway` client has `serviceAccountsEnabled: true`,
so a service obtains its own token:

```bash
curl -X POST -d grant_type=client_credentials \
     -d client_id=gateway -d client_secret=$SECRET \
     https://auth-dev.xenopsoftware.com/realms/xenopsbase/protocol/openid-connect/token
```

That token is validated exactly like a user's — same issuer, same audience check, same expiry. A
shared secret header would be none of those things: it never expires, it is not scoped, and it
cannot be revoked without redeploying everything that knows it.

**A service-account token has no user.** No `preferred_username`, and Keycloak's `/userinfo` returns
**403** for it. The gateway therefore falls back to `sub` for the principal and treats enrichment as
optional — see [ADR-context in the gateway's SecurityConfiguration](../../services/gateway/src/main/java/com/xenopsoftware/gateway/config/SecurityConfiguration.java).

## Token lifetime and refresh

| Setting | Value | Why |
|---|---|---|
| `accessTokenLifespan` | 300s | bounds how long a leaked token is useful |
| `ssoSessionIdleTimeout` | 1800s | idle sessions expire |
| `ssoSessionMaxLifespan` | 36000s | absolute ceiling |

The gateway holds the refresh token and renews the access token transparently
(`OAuth2ReactiveRefreshTokensWebFilter`); browsers never see it. Five minutes is short on purpose —
if it feels short, that is the point, and the refresh flow is what absorbs it.

## The trap that cost four rounds

**Never declare a `clientScopes:` block in the realm import.**

Declaring it suppresses Keycloak's creation of the built-in scopes and does not reliably create the
replacements either. The realm ends up with almost no scopes, every client's `defaultClientScopes`
points at scopes that do not exist, and tokens arrive with **no `realm_access.roles` and no
`preferred_username`** — so authorization evaluates against an empty authority list.

The only visible symptom is one line in the import job log:

```
Referenced client scope 'roles' doesn't exist. Ignoring
```

`realm_access.roles` is not a Keycloak default either — it is produced by a protocol mapper on the
built-in `roles` scope. Keycloak creates that scope and mapper itself, provided nothing overrides it.

## Applying a realm change in dev

```bash
K=".../infra/terraform/cluster/kubeconfig"
# delete the realm, then let Argo recreate the import
curl -X DELETE -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://auth-dev.xenopsoftware.com/admin/realms/xenopsbase
KUBECONFIG=$K kubectl -n keycloak delete keycloakrealmimport xenopsbase
KUBECONFIG=$K kubectl -n argocd annotate app keycloak argocd.argoproj.io/refresh=hard --overwrite
```

This destroys every user in the realm. Acceptable in dev, where the only users are the two
throwaway test accounts. **Never do this in an environment with real users** — realm changes there
need the admin API or a migration, not a re-import.
