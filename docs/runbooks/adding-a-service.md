# Runbook: adding a service

**Task:** T-9.7

This is the checklist the whole T-9 line of work exists to make short. Before it, adding a third
service meant copying a 1400-line pom, duplicating twelve classes, editing four places in the
gateway, editing six hardcoded `[core, gateway]` lists, and inventing a Keycloak story that did not
exist.

**Derived from the repository, not from memory.** Every path below was found by `git grep` while
writing this, the same way [forking.md](../forking.md) derives its table.

---

## The short version

```bash
# 1. the module
mkdir -p services/reporting/src/main/java/com/xenopsoftware/reporting
$EDITOR services/pom.xml                     # add <module>reporting</module>
$EDITOR services/reporting/pom.xml           # copy core's; it is ~60 lines

# 2. the route
$EDITOR services/gateway/src/main/resources/config/application.yml   # copy the `core` route block

# 3. identity
$EDITOR platform/envs/dev/keycloak/realm-import.yaml                 # audience mapper + svc client

# 4. the deployment
cp platform/envs/dev/services/core.yaml platform/envs/dev/services/reporting.yaml
$EDITOR platform/envs/dev/services/kustomization.yaml
```

Everything else derives. **There is no seventh step where you go and find the lists.**

---

## 1. The Maven module

Add it to `services/pom.xml`'s `<modules>`, in dependency order. **That list is the service
registry**: `infra/scripts/service-modules.sh` reads it, and two GitHub Actions matrices, CodeQL, the
security scan and four Makefile loops read that. A module named `platform-common*` is treated as a
library and excluded; anything else is a service.

Copy `services/core/pom.xml`. It is short now — coordinates, a `start-class`, its coverage floors,
its dependencies, and the five plugins that make a module deployable. Everything else is inherited
(ADR-0017).

**Depend on `platform-common-web`**, not on `platform-common`. The gateway is the only module that
takes the stack-neutral half alone, and an enforcer rule in its pom stops that being an accident.

**Name the shared packages in `DatabaseConfiguration`** if the service persists:

```java
@EntityScan({ "com.xenopsoftware.reporting", "com.xenopsoftware.common" })
@EnableJpaRepositories({ "com.xenopsoftware.reporting", "com.xenopsoftware.common" })
```

The shared modules deliberately do not declare this for you: `@EntityScan` anywhere *replaces* the
application's default entity packages rather than adding to them, so a library that declared one
would silently stop your own entities from being scanned. Forgetting it fails at startup with the
class named, which is the failure worth having.

**Namespace the migrations.** `db/migration/<service>`, and point `spring.flyway.locations` at it.
`classpath:db/migration` resolves across every jar on the classpath and every module numbers from
`V1`, so two services in one process — or one depending on another's jar — makes Flyway refuse to
start with *"Found more than one migration with version 1"*.

## 2. The gateway route

One block in `spring.cloud.gateway.server.webflux.routes`. Copy the `core` one and change the name in
its five places.

**Do not add resilience4j `instances`.** Resilience4j applies `configs.default` to an instance it
creates on demand for a name it has never seen, and
`ResilienceDefaultsApplyToUnconfiguredServicesTest` asserts that against a name configured nowhere
rather than assuming it. Add an `instances.<name>` block only when the service has a measured reason
to differ.

**Do not add a fallback method.** `FallbackResource` takes the service name from its path.

## 3. Identity

Three things in `platform/envs/dev/keycloak/realm-import.yaml`, and each has a way of failing
quietly:

| | where | if you forget |
|---|---|---|
| audience mapper on the `gateway` client | `clients[gateway].protocolMappers` | every call to the new service is 401 with a token that just logged in successfully |
| audience mapper on `smoke-tests` | `clients[smoke-tests].protocolMappers` | the smoke suite and `RealTokenAuthorizationIT` fail the same way |
| `svc-<name>` client + service-account user | `clients`, `users` | only if the service CALLS another one |

Then narrow the service's own accepted audience to its name — `jhipster.security.oauth2.audience` —
so it accepts tokens minted for it and not tokens minted for the realm.

**The mappers go on the CLIENTS, never on a shared client scope.** That was tried: Keycloak's import
created the scope and silently dropped its `protocolMappers`, so the scope existed, the mapper did
not, and tokens still had no audience.

**A service account's realm roles go on the USER, not on the client.** `serviceAccountsRealmRoles`
reads like the field for it and is not a field at all — it belongs to keycloak-config-cli, and
Keycloak refuses the entire import with *"Unrecognized field"*. Declare
`service-account-<clientId>` in `users:` with `serviceAccountClientId` and the roles.

See [authorization.md](authorization.md) for the two-credential model and the secret-rotation trap.

## 4. The deployment

Copy `platform/envs/dev/services/core.yaml` and add it to that directory's `kustomization.yaml`.

It is ~400 lines, and most of them are comments explaining decisions that apply to any service:
the OIDC-wait initContainer, the probe timings, the security context, the resource sizing method.
Read them rather than trimming them.

What is genuinely per-service: the name, the container port, the database secret, the resources, and
whichever env vars the service actually reads.

**If the image is not built by this repository's pipeline**, it must be pinned by digest in
`platform/envs/dev/policy/third-party-allowlist.yaml` AND the namespace's directory added to
`ENROLLED_DIRS` in `infra/scripts/check-image-allowlist.sh`. Policy-controller denies anything
matching no policy, at the next pod restart rather than at deploy time. `make
verify-image-allowlist` is what catches it in CI instead.

## 5. What you do NOT have to edit

This is the part that used to be the work. All of it now derives from `services/pom.xml`:

| | derived by |
|---|---|
| `.github/workflows/services.yml` build matrix | `service-modules.sh --json` |
| `.github/workflows/services.yml` publish matrix | the same |
| `.github/workflows/codeql.yml` matrix | the same |
| `.github/workflows/security.yml` image + SBOM matrices | the same |
| `make api-spec-check`, `make api-compat` | `service-modules.sh` |
| `make format`, `make format-check` | one reactor pass |
| the pre-commit hook | one reactor pass |
| Dependabot | one `/services` entry; it resolves the modules |

---

## Verifying it

```bash
cd services && ./mvnw verify -pl reporting -am -DskipITs=false
make format-check
make api-spec && make api-spec-check
```

Then, before it reaches a cluster:

- **`make verify-headroom`.** A new service is a new pod on workers that are already tight. The
  arithmetic comes first and this confirms it — see ADR-0018 for how that is done.
- **`make connection-budget`.** `hikari.maximum-pool-size` times the HPA ceiling is what the
  database sees, and virtual threads (T-9.8) made the pool the real admission control rather than
  Tomcat's thread count.

## The two things most likely to bite

**A bean that is not found does not report an error.** The shared modules contribute beans through
`META-INF/spring/...AutoConfiguration.imports`, not through component scanning, precisely because
`com.xenopsoftware.common` is outside your scan root. Copy
`PlatformCommonBeansExistIT` into the new service. It is a list of `getBeansOfType` assertions and it
is the only thing that fails when the wiring silently does not happen.

**A guard that never runs looks exactly like a guard that passes.** Every check in this repository
that turned out to be governing nothing — #2, #113, #155, #211, #418 — looked green. When you add a
list, add the thing that reads it back.
