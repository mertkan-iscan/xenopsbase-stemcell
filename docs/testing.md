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
| End-to-end | — | — | none yet (T-5.5, #44) |
| Load | — | — | none yet (T-5.6, #45) |
| Chaos | — | — | none yet (T-5.7, #46) |
| Security | partial — secret scan only | GitHub Actions | `secrets.yml` on PR and push |

Counted on 2026-08-22: gateway 8 unit and 5 integration classes, core 9 unit and 7 integration.

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

**Does not cover identity.** There is no Keycloak container. `TestSecurityConfiguration` mocks
`ReactiveJwtDecoder`, so token signature validation, audience enforcement, the `roles` client scope
and the mapping from realm roles to authorities are **never exercised against a real identity
provider**. Every authorization failure this project has hit — the missing `aud` claim, the dropped
`roles` scope, the absent `offline_access` role — would have passed this layer. T-4.2 (#36) is the
card that adds it.

**Does not cover** anything outside one service. The gateway's ITs do not start core, and core's do
not start the gateway.

**Does not cover** the deployed configuration. ITs run under the test profile; `application-prod.yml`
is not exercised by anything until the service is deployed.

### Contract — not built (T-5.4, #43)

**Will cover** the gateway and core agreeing on request and response shapes without deploying both.

There is a partial guard already, and it is worth naming so it is not mistaken for the layer:
`OpenApiSpecIT` captures the served spec and CI fails when the committed `docs/api/*.json` has
drifted. That catches *the spec changing*. It does not catch a consumer breaking, because nothing
asserts what a consumer expects. It also cannot detect a breaking change between two revisions of
the contract — noted on #34 as a known gap.

### End-to-end — not built (T-5.5, #44)

**Will cover** a real browser or client against a real cluster: sign in, upload, list, download,
sign out.

**Must cover one thing specifically.** Ownership spans the database and the realm — documents are
owned by the Keycloak `sub`, which lives in Keycloak's schema, while the rows live in another
database and the bytes in object storage. An e2e suite that signs in with a fresh account each run
would never notice ownership breaking across a rebuild. See ADR-0010 and the note on #54 and #55.

**Will not cover** performance. A green e2e run says nothing about latency under load.

### Load — not built (T-5.6, #45)

**Will cover** a k6 baseline and published SLOs.

**Does not exist yet, and that has already cost something.** Caching was deferred on #127 because
nobody should guess at a cache without a load baseline; the resilience numbers on #32 — a 2s
connect, a 10s response timeout, a 12s time limiter, a bulkhead of 50 — are reasoned rather than
measured. They are written down so they can be reviewed, not because they are known to be right.

### Chaos — not built (T-5.7, #46)

**Will cover** behaviour against the SLOs when a dependency degrades rather than dies.

**Why it is separate from integration:** connection-refused is immediate and deterministic, and
`DeadDownstreamIT` covers it. A *hung* downstream is not — testing it means waiting out a real
timeout, which is the point of a chaos drill and poison in a unit suite.

### Security — partial (T-5.8, #47)

**Covers today:** `secrets.yml` scans for unencrypted secrets on PR and push. Terraform static
analysis via checkov and tflint runs in `terraform.yml`.

**Does not cover** dependency vulnerabilities, container image scanning, SAST, or authorization
regression. That last one is the gap that matters most, and it compounds with integration not
covering identity: nothing anywhere asserts that an unprivileged user is refused an admin endpoint
against a real token.

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
