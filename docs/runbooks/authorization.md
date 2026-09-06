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
/api/whoami                             200                   200
/api/admin/platform/probe               403                   200
```

Both endpoints live on `PlatformIdentityResource`. They were on the demo domain's controller until
T-9.2 and had to move rather than be deleted with it: `/api/admin/**` is the only place the ADMIN
rule in core's `SecurityConfiguration` is exercised at all, and removing the endpoint would have
removed the assertion along with it — silently, because a rule nothing reaches passes every test
there is. `SecurityRulesSliceTest` asserts both rows of the table above.

Both directions matter. A 403 for an unprivileged user only shows the check fires; a check that
denies everyone looks identical to one that works.

## Service-to-service

Client credentials, never a shared header. Each service that CALLS another has its own confidential
client, `svc-<name>`, and obtains its own token:

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

### Two credentials, two questions (T-9.4)

An inter-service call carries both, and conflating them is the mistake the design exists to prevent.

```
Authorization: Bearer <the USER's token, forwarded unchanged>
X-Service-Authorization: Bearer <the CALLING SERVICE's own token>
```

| | answers | verified how |
|---|---|---|
| `Authorization` | *on whose behalf* | the callee validates the Keycloak signature itself |
| `X-Service-Authorization` | *by which service* | same, plus the `svc-caller` realm role |

The user token is **forwarded, never re-minted**. A claim the calling service made about who it is
acting for would be a claim, and the third service in a chain has no reason to believe it. Forwarding
unchanged is also what makes a chain of any length work: the token that reaches the last service is
the one the person presented at the edge.

`ServiceAuthenticationFilter` maps `svc-caller` to an authority, so `@PreAuthorize` can distinguish a
service caller from a user. **Absence of the service header is not a refusal** — a request without one
is an ordinary edge request, which is what lets the filter ship in every service before any
inter-service call exists.

### Per-service audiences

Until T-9.4 core accepted `aud: account, gateway`, which meant it accepted any token this realm
issued for the gateway — and so would every service added behind it. Every service trusted every
relayed token identically, so a token minted for one was replayable against another and nothing
would have noticed.

Each service now narrows its accepted audience to its own name, and each client whose tokens reach a
service carries an `oidc-audience-mapper` naming it. **Adding a service is adding a mapper**, on the
client, not widening the accepted list.

> The mappers are on the CLIENTS, not on a shared client scope. That was tried and Keycloak's import
> created the scope while silently dropping its `protocolMappers` — the scope existed, the mapper did
> not, and tokens still had no audience. Do not tidy them into a scope.

### The realm secret and the Kubernetes Secret must change together

`svc-core`'s secret exists twice: in the realm, imported from `keycloak-clients` in the `keycloak`
namespace, and in `service-clients` in `apps`, which the service reads.

**When they disagree, nothing looks wrong.** Every pod is Ready, the databases are up, the gateway
serves users normally. Keycloak's token endpoint answers `invalid_client`, the caller never obtains a
token, and so it never makes a request that anyone can see fail — there is no 401 downstream to find,
because there was no downstream call. Rotate both or neither.

```bash
# What to check first when inter-service calls stop working and nothing is unhealthy.
kubectl -n keycloak get secret keycloak-clients -o jsonpath='{.data.SVC_CORE_CLIENT_SECRET}' | base64 -d
kubectl -n apps      get secret service-clients  -o jsonpath='{.data.SVC_CORE_CLIENT_SECRET}' | base64 -d
```

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

This deletes every user in the realm and the import recreates them.

That used to be described as harmless because "the only users are the two throwaway test accounts".
It stopped being harmless once those accounts owned documents: ownership is the Keycloak `sub`, and
a recreated user gets a new one, so every document would belong to a user that no longer exists —
silently, with the rows still in Postgres and the objects still in the bucket (T-7.8, #147).

It is safe **because the declared users now carry explicit `id`s** in `realm-import.yaml`, so the
re-import restores the same subs. If you add a user there, give it an id, or you are reintroducing
this. Anyone created at runtime instead of declared is still lost — ADR-0010 covers why that is
accepted and what fixing it properly would take.

**Never do this in an environment with real users** — realm changes there need the admin API or a
migration, not a re-import.
