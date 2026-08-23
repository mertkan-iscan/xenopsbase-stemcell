# Test strategy

**Task:** T-5.1 (#40)

Deciding what each layer tests *before* writing the tests, so that coverage is deliberate rather
than whatever accumulated. Every layer below states what it covers, what it deliberately does not,
and which gate runs it — because a layer with no stated boundary grows until it duplicates the one
above it, and a layer with no gate is a layer that stops running.

## The rule this template keeps relearning

Nearly every defect this project has found had the same shape: **a component reporting success
while doing nothing.** An archive that never archived. Alerts routed to a null receiver. SMTP that
queued and discarded. Tracing configured against a Zipkin endpoint behind an inactive Maven
profile, exporting nothing while Tempo sat healthy and empty. A Maven cache reporting a hit on
every run and helping on none.

None of those were caught by a test asserting a happy path, because the happy path *was* the
symptom. So the bias throughout this document is toward tests that assert a pipeline **produced**
something, and against tests that assert a call **returned**.

## The layers

| Layer | Runs | Where | Gate today |
|---|---|---|---|
| Unit | `mvn test`, surefire, `*Test.java` | JVM only | `services.yml` on PR |
| Slice | surefire, `*SliceTest.java` | JVM; the data slice uses Testcontainers | `services.yml` on PR |
| Integration | `mvn verify`, failsafe, `*IT.java` | Testcontainers | `services.yml` on PR |
| Contract | — | — | none yet (T-5.4, #43) |
| End-to-end | `make smoke ENV=<env>` | the **deployed** environment | `smoke.yml` after every deploy; gates promotion |
| Load | `make load ENV=<env>` | k6, **in-cluster** | none yet — CI cannot reach the cluster (#207) |
| Chaos | — | — | none yet (T-5.7, #46) |
| Security | CodeQL, dependency review, image scan, SBOM | GitHub Actions | `codeql.yml`, `security.yml`, `secrets.yml` |

Counted on 2026-08-23: gateway 8 unit and 6 integration classes, core 9 unit and 8 integration.

### Unit

**Covers** pure logic with no Spring context: validators, converters, filters exercised by calling
them, and architecture rules. `AudienceValidatorTest`, `SecurityUtilsUnitTest`,
`CorrelationIdObservationFilterTest`, `OidcAuthenticationFailureHandlerTest`,
`CRLFLogConverterTest`, `SchemaOwnershipTest`, and the ArchUnit `TechnicalStructureTest`.

**Does not cover** anything that depends on wiring. A unit test proves a class behaves; it cannot
prove the class is *reached*. Both correlation-id filters are unit tested and neither test would
notice if the bean were never registered — that is the integration layer's job, and the gap is real
rather than theoretical.

**Does not cover** configuration. A property name that Boot silently ignores is invisible here.

### Slice

**Covers** one Spring layer with the rest absent. Built in T-5.2 (#41); there were none before.

| Slice | Test | Asserts |
|---|---|---|
| Web | `ExampleItemResourceWebSliceTest` | serialization, status, binding — security filters **off** |
| Security | `SecurityRulesSliceTest` | the authorization rules — filters **on**, real `SecurityConfiguration` |
| Data | `DocumentRepositorySliceTest` | the owner-scoped queries against a real schema |

**Web and security are deliberately two files.** Mixing them produces a test that fails for two
unrelated reasons and tells you neither.

**The security slice must import the application's `SecurityConfiguration`.** Without it
`@WebMvcTest` applies Boot's default test security, under which every authenticated caller reaches
everything. The first version of that file asserted 403 on the admin endpoint and got 200 — the
rule was never loaded, and four of its five tests still passed, because "anonymous is refused"
happens to be the default too. A security slice that does not load the security configuration is
worse than none: it reports green against rules it has never seen.

**Does not cover** interaction between slices, which is where this project's defects live. A slice
test is a faster unit test, not a cheaper integration test.

### Integration

**Covers** the service against real dependencies in containers: Postgres 18.4, Valkey
8.1.4-alpine, MinIO `RELEASE.2025-04-22T22-12-26Z`. `DocumentResourceIT` PUTs and GETs against
presigned URLs with a bare `HttpClient`, outside the application, so "bytes do not transit the JVM"
is what the test actually exercises rather than what it asserts. `ExtensionSeamsIT` has 13 tests
each aimed at how a seam fails *silently*. `DeadDownstreamIT` asserts behaviour against a refused
connection.

**Covers identity, in core, since T-4.2 (#36).** `KeycloakTestcontainer` starts a real Keycloak
preloaded with `platform/envs/dev/keycloak/realm-import.yaml` — the production realm file, not a
copy of it — and `RealTokenAuthorizationIT` authenticates with tokens Keycloak actually minted.
That test deliberately does not import `TestSecurityConfiguration`, so signature validation,
audience enforcement, the `roles` client scope and realm-role-to-authority mapping are all real.
Every authorization failure this project has hit — the missing `aud` claim, the dropped `roles`
scope, the absent `offline_access` role — would now be caught here.

**Covers the interactive login, since T-5.3 (#42).** `OidcLoginFlowIT` walks the authorization-code
flow the way a browser does: the gateway's redirect out, Keycloak's login form, the credential
POST, and the callback carrying a real code back to a session that has to still be holding the
authorization request. It does not import `TestSecurityConfiguration`, so the decoder, the code
exchange and the claim mapping are all real. This is the flow that produced #175, #176 and #180 —
each found in production, by a person, on the third or fourth attempt.

Two things it asserts that are easy to lose: that the state coming back is the state that went out,
and that the session identifier changes on authentication, which is the difference between a login
and session fixation.

It also found #186 on its first complete run — realm roles never reach a session principal, so
every `hasAuthority(ROLE_ADMIN)` rule on the browser path denies everyone including the admin. That
is recorded as a characterization test asserting the current, wrong behaviour, so fixing #186 is
what makes it fail.

**Covers the migrations themselves, since T-5.3.** `FlywayMigrationIT` asserts that every committed
migration has a successful row in `flyway_schema_history`, in version order, and that the first one
applied was the baseline. `ddl-auto: validate` already fails startup on a schema mismatch, which
proves the schema Hibernate needs exists — not that these migrations produced it, on a database
that started empty.

**Does not cover the gateway's bearer-token path against a real Keycloak.** `OidcLoginFlowIT` drives
the session path. The gateway is also a resource server on `/services/**`, and that half still runs
through `TestSecurityConfiguration`'s mocked decoder.

**Does not cover** anything outside one service. The gateway's ITs do not start core, and core's do
not start the gateway.

**Does not cover** the deployed configuration. ITs run under the test profile, so
`application-prod.yml` is exercised by nothing here — that is the end-to-end layer's job, and until
T-5.5 it was nobody's.

### Contract — not built (T-5.4, #43)

**Will cover** the gateway and core agreeing on request and response shapes without deploying both.

There is a partial guard already, and it is worth naming so it is not mistaken for the layer:
`OpenApiSpecIT` captures the served spec and CI fails when the committed `docs/api/*.json` has
drifted. That catches *the spec changing*. It does not catch a consumer breaking, because nothing
asserts what a consumer expects. It also cannot detect a breaking change between two revisions of
the contract — noted on #34 as a known gap.

### End-to-end

**Covers the deployed system, since T-5.5 (#44).** `infra/scripts/smoke.sh` runs from outside, over
the public internet, the way a user would. Ten checks, ~5 seconds:

| Check | Only true of a deployment |
|---|---|
| The edge answers | Cloudflare, the tunnel, and ingress-nginx are all in the path |
| Access refuses a request with no service token | T-8.6 is still in force |
| Login against the deployed Keycloak | the realm applied, and the issuer resolves |
| An unauthenticated API call is 401, not a redirect | T-3.8, through the real edge |
| An authenticated call reaches core | the gateway's `/services/core` route works |
| An upload ticket is issued | core reached Postgres and signed a URL |
| Bytes PUT to the presigned URL | **real** object storage, not MinIO |
| Upload completed and recorded | the row and the object agree |
| Downloaded bytes are identical | the round trip through Hetzner survived |
| The document is deleted again | it cleans up rather than leaking rows and objects every run |

**This is the only layer that tests `application-prod.yml`.** Everything above it runs under the
test profile, so the configuration actually in effect in production was exercised by nothing until
this existed.

**It runs in CI, and `rollout-status` cannot** — the distinction is worth holding. The Kubernetes
API is a tailnet address a GitHub runner cannot reach (#195), but the *application* is public by
design. So CI cannot ask the cluster how it is, and can ask the application to prove it.

**It gates promotion.** Promoting out of an environment is a claim that the build works there;
`promote.yml` now runs this against the **source** environment first. Before, a digest could be
promoted out of an environment that had been broken since the moment it landed, and the first sign
would be the same breakage one environment further on.

**Does not cover** ownership across a rebuild — yet. Documents are owned by the Keycloak `sub`,
which lives in Keycloak's schema while the rows live in another database and the bytes in object
storage. This suite creates and deletes its own document in one run, so it would not notice
ownership breaking across a destroy and rebuild. ADR-0010 and #54 carry that; it needs a document
that outlives the run.

**Does not cover** the browser. It drives the API with a bearer token from the direct-grant client,
not the interactive login — that is `OidcLoginFlowIT`'s job, against a real Keycloak in a
container. Nothing yet drives a real browser through the deployed Cloudflare Access flow, which is
exactly the gap #175 is still open on.

**Does not cover** performance. A green run says nothing about latency under load.

### Load

**Covers, since T-5.6 (#45)**, what the application can serve and what it costs, measured rather
than assumed. `infra/load/baseline.js` run by `make load`, in-cluster against the gateway Service.

Two scenarios, separated so a regression names its own cause: `gateway_only` isolates the gateway,
`through_core` adds core, Hibernate and Postgres. The gap between them is the cost of everything
behind the gateway, and one aggregate number cannot tell you which half moved.

The thresholds are the SLOs and k6 exits non-zero on a breach, so this is a gate rather than a
report. Numbers and reasoning: [slos.md](slos.md).

**Does not cover the edge.** Cloudflare, the tunnel and ingress-nginx are excluded deliberately —
the number exists to inform an HPA, which scales on pod CPU, and the edge's variance swamps the
application's. `smoke.sh` asserts that path works; nobody has measured what it costs.

**Does not cover writes.** Both scenarios are reads. The upload path ends in a presigned PUT
straight to Hetzner, so a write benchmark would mostly measure Hetzner from a Hetzner node.

**Does not cover sustained load.** 105 seconds per scenario — long enough for JIT and the pool to
settle, far too short for memory growth or connection leaks.

**Does not run on a schedule** (#207): `make load` drives k6 inside the cluster and CI cannot reach
the cluster (#195). Running it through the public edge from a runner would work and would measure
the wrong thing.

### Chaos — not built (T-5.7, #46)

**Will cover** behaviour against the SLOs when a dependency degrades rather than dies.

**Why it is separate from integration:** connection-refused is immediate and deterministic, and
`DeadDownstreamIT` covers it. A *hung* downstream is not — testing it means waiting out a real
timeout, which is the point of a chaos drill and poison in a unit suite.

### Security

**Covers, since T-5.8 (#47)**, four different questions, deliberately kept apart because they fail
for different reasons and want different responses:

| Check | Asks | Gate |
|---|---|---|
| `check-secrets.sh` | is a secret about to be committed | fails the pull request |
| GitHub secret scanning + push protection | is a secret already here, or being pushed now | blocks the push |
| CodeQL | is the code we wrote unsafe | reports to the Security tab |
| dependency review | does this pull request **add** a vulnerable or badly-licensed dependency | fails the pull request |
| Trivy image scan | is what we actually ship vulnerable | fails on HIGH or CRITICAL with a fix available |
| SBOM | what is in the artefact | recorded, not a gate |

**CodeQL uses a manual build, not autobuild.** There is no parent pom, two independent Maven
projects, and a hard Java 25 requirement enforced by `maven-enforcer`. Autobuild finds one project,
builds it with whatever JDK the runner has, and either fails the enforcer or analyses half the
codebase while reporting success — and a security scan silently covering half the code is worse
than none, because the green tick is what people read.

**The image scan reads the pinned digest, not `:main`.** A tag moves; scanning something other than
what is deployed is exactly the green tick this repository keeps finding.

**`ignore-unfixed` on the image scan is deliberate.** A CRITICAL with no available fix cannot be
actioned here, and failing on it would make the gate permanently red for reasons nobody can
resolve — the pattern that made #193 worth its own card.

**Dependency review fails only on what a change adds**, not on pre-existing findings. Otherwise
every pull request fails until the backlog is cleared, and a check that always fails is one people
learn to skip.

**Does not cover DAST.** Nothing drives a scanner against the running application. That needs a
decision about pointing an active scanner at an environment behind Cloudflare, and is split to
[#222](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/222).

**Does not attach the SBOM to a release**, because there are no releases — tagging is T-8.5 (#63)
and the automation T-6.5 (#52). It is generated and kept as a build artefact; attaching it is one
line in whichever workflow eventually creates releases.

**Does not cover the infrastructure.** `checkov` runs on the Terraform in `terraform.yml`, and its
real value is recorded honestly in [terraform-ci.md](runbooks/terraform-ci.md): after waiving the
AWS-only rules it reports zero passed and zero failed, so it is a regression detector rather than a
security bar.

## What blocks a merge

**Intended:** CONTRIBUTING says `main` is protected, that work lands through a pull request with
green checks, and T-0.1 (#2) records "main is protected: no direct pushes, PR plus green checks
required" as met.

**Actual, read from the API on 2026-08-22:**

```
required_status_checks         absent
required_pull_request_reviews  absent
enforce_admins                 false
rulesets                       []
```

Branch protection exists and blocks force-pushes and branch deletion. **It requires no status check
and no review, so nothing blocks a merge.** A pull request with a red `gateway` job can be merged,
and the convention is currently held up by the people following it rather than by the repository.

This is not a test-strategy problem and it is not fixed here — it is filed as T-0.7 (#161). But a
document naming the gate for each layer would be worthless if it described gates that do not
enforce anything, so it is recorded rather than assumed.

Once enforcement is on, the checks that should block are `gateway`, `core`, `generated client`,
`no unencrypted secrets`, `Conventional Commits title`, and `terraform` where it applies.

## Coverage target

**80% instruction and 70% branch, measured on `mvn verify` — unit and integration together — per
service, enforced at the module level, not per class.**

**The target is 80/70. The enforced floor is lower, and the difference is deliberate.**

Measured on 2026-08-22, on a merged unit + integration run — which is the number that had never
existed, because jacoco writes two separate exec files and neither is the project's coverage:

```
                merged            unit only        integration only
gateway    54.5% / 41.7%      49.9% / 35.6%       45.2% / 36.0%
core       60.0% / 46.0%      (see note)          (see note)
```

The earlier figures in this document — gateway 37.6%, core 10.6% — were unit-only runs with no
Docker, and the gateway one also excluded the Cucumber context test. Both understated the project
substantially, which is exactly why this document refused to set a gate from them.

**Enforcing 80/70 today would fail every build from the moment the gate went in**, and a gate that
cannot pass is removed within a day — after which there is no gate at all. So the enforced floor is
the measured baseline, one point below:

| | instruction | branch |
|---|---|---|
| gateway `jacoco.minimum.*` | 0.53 | 0.40 |
| core `jacoco.minimum.*` | 0.58 | 0.44 |

That fails the build on a **regression** today, which is the job a gate can actually do now. Getting
from there to 80/70 means writing tests, which is a separate body of work with its own card
(T-5.9, #172). Raise the floors deliberately as it lands, with the reason in the commit — the same
treatment every other threshold in this repository gets.

**Why 80/70 and not higher.** The number has to be one that fails only when something is genuinely
untested. Set at 90+, the gate starts failing on generated code, exception plumbing and Spring
configuration classes, and the reliable way to make it pass again is to write tests that execute
code without asserting anything about it — which is worse than no gate, because it converts a
quality signal into a compliance exercise.

**Why branch coverage is stated separately and lower.** Instruction coverage is easy to inflate: one
test through the happy path lights up most of a method. Branch coverage is what notices that the
error path was never taken, and error paths are where this project's defects have been. 70% is
chosen to be genuinely binding while leaving room for defensive branches that cannot be reached in
a test.

**Why per module and not per class.** A per-class floor forces tests onto records, DTOs and
configuration holders. A module floor lets judgement sit where it belongs while still failing if
someone lands a substantial untested feature.

**What the gate must not become.** A ratchet that only goes up, blocking legitimate refactoring that
deletes tested code. If it needs adjusting, it gets adjusted deliberately with the reason in the
commit — the same treatment every other threshold in this repository gets.

## The local and CI asymmetry, which is a trap

CI verifies Docker is present before building:

```yaml
- name: Check Docker is available
  run: docker info > /dev/null
```

Locally there is no such check, and `mvn test` succeeds without a container runtime because
surefire never needs one. The failure mode is specific and was hit twice while writing this: `mvn
test` passes locally, the developer believes the change is tested, and the integration layer that
would have exercised it never ran. The two Cucumber context tests fail locally with `Could not find
a valid Docker environment` and pass in CI.

Treat a green local `mvn test` as "the unit layer agrees", never as "this is tested". T-4.1 (#35)
and T-4.2 (#36) are the cards that close this.

## Tests this project did not have until a defect found the gap

Recorded because it is the honest measure of where the strategy is weak, not as an aside:

- **The correlation-id contract had no test at all** until T-3.8's trace work on #31. `X-Request-Id`
  appeared nowhere in any test source, in either service, while the runbook described the contract
  in detail.
- **The OIDC failure path had no test** until #156. A stale authorization request produced a 404 on
  a page the application does not serve, and it was found by a person using the site.

Both were found in use rather than by the suite, and both are now covered. The pattern to watch is
that both were *cross-cutting* concerns — the kind that no single class owns, and that unit tests of
individual classes are structurally poor at catching.
