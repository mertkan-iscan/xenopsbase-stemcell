# ADR-0016: The threat model is six boundaries, and every mitigation names a task or is an accepted risk

- **Status:** Accepted
- **Date:** 2026-08-29
- **Task:** T-8.1 (#59)

## Context

A stemcell is forked. Whatever security posture it ships with is inherited by every project built
on it, along with the reasoning — or the absence of it. A fork can read the code and see that
`cloudflared` dials outward and that nothing listens publicly; it cannot read the code and learn
*which threat that answers*, *what it does not answer*, and *what was accepted rather than fixed*.

That is the gap this record fills. It is not a security review of the code (T-5.8 and T-5.11 own
scanning), not a control list, and not a claim that the system is secure. It is the answer to one
question, written down: **where does trust change hands here, and what goes wrong at each of those
points?**

### Why now, and why an ADR rather than a document

Two of this project's sharper findings were failures of the threat model rather than of a control:

- **#148 (T-3.15)** — the gateway trusted `X-Forwarded-*` from any source. Every individual
  component was configured correctly. What was missing was a stated boundary saying which hop is
  the last untrusted one.
- **#149 (T-8.6)** — dev was internet-reachable with working credentials published in a public
  repository. Nothing was misconfigured against its own intent; the intent had never been written
  down, so nothing could be checked against it.

Both are the same shape: a boundary that existed in the architecture but not in anybody's head. A
list of controls would not have caught either. A boundary diagram with an owner per edge would
have.

It is an ADR because it constrains later work — every card in E8 inherits it, and the accepted
risks below are decisions with costs, not observations.

### Scope, honestly stated

This models **dev as it exists on 2026-08-29**, which is the only environment that exists
(T-6.6, #194). Two consequences a reader should not have to infer:

- Dev carries no real user data. Several risks are accepted *because of that* and are marked as
  such; a fork that puts real data behind this stemcell inherits the boundary map, **not** the
  acceptances.
- Staging and prod do not exist. Where a mitigation is "prod would do X", that is a plan and is
  written as one.

## Decision criteria

What makes something a boundary, and what makes a mitigation count. Stated before the pass, so the
conclusions cannot be retrofitted:

1. **A boundary is where trust changes**, not where a network hop happens. Two components on the
   same trust footing with a wire between them are one zone.
2. **A mitigation must name a mechanism that exists, and where it lives.** "Validated input" is not
   a mitigation. A class, a manifest, a workflow, or a task number is.
3. **A control that reports success while governing nothing is not a mitigation.** This repository
   has now found several — #2, #113, #155, #211, #329 — and each looked like coverage until it was
   read. Where a control's *enforcement* is unproven, it is written as unproven.
4. **Everything unmitigated is either a task or an accepted risk. There is no third state.** An
   unmitigated threat with no card and no acceptance is how a threat model becomes decoration.
5. **An acceptance states what would revoke it.** "Accepted" without a trigger is indistinguishable
   from "forgotten".

## The system, and where trust changes hands

```
        ┌─────────────────────────────────────────── B1 ─────┐
        │                    the internet                     │
        └──────────────────────────┬──────────────────────────┘
                                   │ TLS
                        ┌──────────▼──────────┐
                        │  Cloudflare edge    │  DNS, TLS termination,
                        │  Access, WAF, proxy │  Access policy (T-8.6)
                        └──────────┬──────────┘
        ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│─ ─ ─ ─ ─ ─ ─ ─ ─ ─ B2 ─ ─
                                   │ mTLS tunnel, dialled OUTWARD
                        ┌──────────▼──────────┐
                        │  cloudflared        │  in-cluster, no listener
                        └──────────┬──────────┘
                                   │
                        ┌──────────▼──────────┐      ┌──────────────┐
                        │  ingress-nginx      │◀────▶│  Keycloak    │ auth-dev,
                        └──────────┬──────────┘      │  (identity)  │ no Access
                                   │                 └──────────────┘
                        ┌──────────▼──────────┐
                        │  gateway  (BFF)     │  session in Valkey,
                        │  OIDC confidential  │  token relayed downstream
                        └──────────┬──────────┘
        ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│─ ─ ─ ─ ─ ─ ─ ─ ─ ─ B3 ─ ─
                                   │ bearer token, in-cluster HTTP
                        ┌──────────▼──────────┐
                        │  core               │  owns the domain,
                        │                     │  authorises by owner
                        └────┬───────────┬────┘
              ─ ─ B4 ─ ─ ─ ─ │           │ ─ ─ ─ ─ ─ B5 ─ ─
                   ┌─────────▼───┐   ┌───▼──────────────┐
                   │  Postgres   │   │  Object storage  │
                   │  (CNPG)     │   │  (Hetzner S3)    │
                   └─────────────┘   └──────────────────┘

  B6 crosses all of the above: git → CI → Argo CD → cluster, plus the nodes,
     the tailnet and the age keys. Nothing above exists without it.
```

**Zones, and what each one trusts:**

| Zone | Trusts | Notes |
|---|---|---|
| Internet | nothing | Includes an authenticated user; authentication is not trust |
| Cloudflare edge | Cloudflare | Third party on the serving path — a deliberate cost of ADR-0006's shape |
| Cluster network | itself, flat | One NetworkPolicy exists (valkey). Everything else is mutually reachable — T-8.2 |
| `apps` (gateway, core) | the token, and each other | Same zone; B3 is a boundary of *authority*, not of network |
| `database`, storage | whoever holds the credential | Credentials are per-service; the network is not the control |
| Control plane / supply chain | git history and the age keys | The root of all the above (B6) |

Note what is deliberately **not** a boundary: gateway → core is not a network boundary, because the
cluster network is flat and pretending otherwise would be the theatre criterion 3 rejects. It is a
boundary of *authority*, and it is modelled as one.

## Decision

STRIDE per boundary. Every row is mitigated with a named mechanism, carries a task, or appears in
the accepted-risk table. Status is **enforced** (a mechanism exists and something proves it),
**present** (a mechanism exists, nothing proves it), or **open** (a card).

### B1 — Internet → Cloudflare edge

| | Threat here | Mitigation | Status |
|---|---|---|---|
| **S**poofing | A stranger reaches `app-dev` and logs in as somebody | Cloudflare Access in front of `app-dev` — team identities plus a CI service token (T-8.6, #149); OIDC against Keycloak behind it (T-3.2, T-3.5) | enforced |
| **T**ampering | Request or response modified in flight | TLS to the edge; the edge is the TLS terminator and the origin is only reachable through the tunnel (T-1.6) | enforced |
| **R**epudiation | A request cannot be attributed | Cloudflare access logs at the edge; application audit is `AbstractAuditingEntity` (T-3.10). Neither is retained anywhere durable — see accepted risk **A5** | open |
| **I**nformation disclosure | Credentials or hostnames leak from a public repository | The repository is public by design; every secret is SOPS-encrypted (ADR-0003) and `make check-secrets` refuses plaintext, in CI and in a pre-commit hook (T-0.4). #149 is the case where this was not enough on its own | enforced |
| **D**enial of service | Volumetric or application-layer flood | Cloudflare absorbs volumetric. Application-layer rate limiting **does not exist**: T-8.3 (#61) owns it, and ADR-0009 records that the Redis-backed limiter needs a shared store, which now exists | open |
| **E**levation of privilege | Bypassing Access by reaching the origin directly | There is no origin to reach: `cloudflared` dials outward and nothing listens. Asserted from outside by `make verify-exposure` (T-1.5), which does raw TCP connects rather than reading the firewall config back | enforced |

`auth-dev` (Keycloak) is deliberately **not** behind Access — it has to be reachable for the OIDC
redirect. It is therefore the widest part of B1, and its exposure is Keycloak's own login page.

### B2 — Cloudflare edge → cluster

| | Threat here | Mitigation | Status |
|---|---|---|---|
| **S**poofing | Something other than Cloudflare presents itself as the tunnel | The tunnel is mTLS and is established by the connector using a token; the token is a bootstrap secret held encrypted (ADR-0003) | enforced |
| **T**ampering | A downstream component trusts forged proxy headers | **This is #148 (T-3.15).** The gateway trusted `X-Forwarded-*` from any source; it now trusts only the known proxy hop. The single most instructive entry in this table, because every component was individually correct | enforced |
| **R**epudiation | The real client is lost behind the proxy chain, so nothing can be attributed | `X-Forwarded-*`, derived by Spring Cloud Gateway's `XForwardedHeadersFilter` and consumed downstream via `forward-headers-strategy`. It is attribution built on the header chain the row above had to be taught not to trust from anywhere, so the two are one mechanism read from opposite ends | present |
| **I**nformation disclosure | Cloudflare sees plaintext | It does, unavoidably — accepted risk **A1** | accepted |
| **D**enial of service | The tunnel is the single ingress path | Two `cloudflared` replicas, spread across nodes. A Cloudflare outage is a total outage — accepted risk **A2** | accepted |
| **E**levation of privilege | A compromised connector reaches the cluster network | It already is *in* the cluster network, which is flat. T-8.2 (#60) default-deny is the control that would bound it | open |

### B3 — Gateway → core (authority, not network)

| | Threat here | Mitigation | Status |
|---|---|---|---|
| **S**poofing | Something in the cluster calls `core` directly with a forged identity | `core` is an OAuth2 resource server: it validates the token's signature and issuer against Keycloak, so a caller without a Keycloak-issued token gets nothing. What it does **not** do is check *which* workload called — anything holding a valid user token is indistinguishable from the gateway | present |
| **T**ampering | A relayed token is altered | Signature validation. Relay is the gateway's `TokenRelay` (T-3.5) | enforced |
| **R**epudiation | An action cannot be tied to a principal | The `sub` is carried end to end and is the `owner` column on `Document` (ADR-0010) | enforced |
| **I**nformation disclosure | One user's data returned to another | Authorisation is enforced **in the query**: `findByIdAndOwner`, not a filter applied afterwards. ADR-0011 makes that a key-format rule so a cache cannot undo it | enforced |
| **D**enial of service | One caller exhausts core, or the connection pool | Timeouts, retries, circuit breakers and bulkheads (T-3.9). The pool ceiling is **81 of 100 and nothing enforces the arithmetic** — T-2.18 (#259) | open |
| **E**levation of privilege | A user acts with a role they were not granted | Realm roles from Keycloak, `@PreAuthorize` on both spellings so `hasRole` cannot silently deny (T-3.20, #186; `docs/runbooks/authorization.md`). Keycloak is the only source of who may do what | enforced |

### B4 — Core → Postgres

| | Threat here | Mitigation | Status |
|---|---|---|---|
| **S**poofing | Something else connects as the application user | Per-service credentials issued by CNPG into a Secret; no shared superuser on the application path | enforced |
| **T**ampering | Schema changed outside review | Flyway owns the schema, `ddl-auto: validate` from commit one (T-3.6), so a drifting entity fails startup rather than migrating silently (T-3.6a, #142) | enforced |
| **R**epudiation | A write cannot be traced | `AbstractAuditingEntity` records created/modified by and when (T-3.10) | present |
| **I**nformation disclosure | Data read from the volume, or from a base backup or WAL segment in the bucket | Access control only: the volume is attached to one node, the bucket is reachable with the backup credential. **Nothing here is encrypted by a key this project holds**, and what the provider does underneath is not asserted — accepted risk **A3** | accepted |
| **D**enial of service | Connection exhaustion, or the volume filling | T-2.18 (#259) for connections; the volume is watched after T-2.21 (#267), where WAL sharing the data volume was the failure | open |
| **E**levation of privilege | SQL injection | Spring Data / JPA parameter binding throughout; no string-concatenated SQL in `core`. CodeQL runs on every push (T-5.8) | enforced |

### B5 — Core → object storage

| | Threat here | Mitigation | Status |
|---|---|---|---|
| **S**poofing | A forged presigned URL | URLs are signed by the credential and time-limited; the key is server-generated and never derived from the filename (T-3.7 — see `Document.objectKey`) | enforced |
| **T**ampering | An object replaced under an existing row | The `documents` bucket is versioned, with old versions expiring after 90d (T-1.2) | enforced |
| **R**epudiation | Who uploaded what | The `owner` column, plus the `PENDING → AVAILABLE` status that only advances once the object is confirmed present | enforced |
| **I**nformation disclosure | A presigned URL outlives its need, or is shared | Short expiry; ADR-0011 forbids caching presigned URLs, precisely because a cache extends an expiry the issuer chose. **A leaked URL is valid until it expires** — accepted risk **A4** | accepted |
| **D**enial of service | Unbounded upload cost | Bucket lifecycle rules exist but are **shared across environments**, so dev cannot be bounded without touching prod — T-1.14 (#151) | open |
| **E**levation of privilege | The credential can do more than it needs | Per-bucket policies with an owner key; `make preflight` checks token scope, and it could not tell Read from Edit until T-1.15 (#152) — an example of criterion 3 caught in the act | enforced |

Also here: **#147 (T-7.8)** — a realm re-import changed every `sub`, orphaning every document. Not
a STRIDE row; a reminder that the `owner` column's meaning depends on an identity provider whose
state is itself managed, which is why ADR-0010 exists.

### B6 — Supply chain and control plane

Not in the acceptance criteria's list of five, and included because it is the boundary that
compromises all the others at once. Everything above is reconciled from git by Argo CD; whoever
writes to `main` writes to production.

| | Threat here | Mitigation | Status |
|---|---|---|---|
| **S**poofing | A commit that nobody wrote | Branch protection: no direct pushes, review plus green checks required (T-0.7, #161). Commit **signing is not required** — accepted risk **A6** | present |
| **T**ampering | A malicious change reaches the cluster | The PR gate: Terraform fmt/validate/tflint/checkov (T-1.8), CodeQL, dependency and image scanning (T-5.8, T-6.8). The conventional-commit check governs what *lands*, not just the PR title (T-0.10, #215) | enforced |
| **R**epudiation | An unattributable deploy | Argo CD reconciles a commit; `make rollout-status` reports which one each environment is on (T-6.7, #195) | enforced |
| **I**nformation disclosure | The age keys leak, or are lost | Two recipients since T-0.8 (#163); the second is offline. Losing every copy loses every secret — T-0.9 (#191) adds a KMS recipient and is open | present |
| **D**enial of service | The cluster cannot be rebuilt | The cold rebuild is the everyday path, measured by T-7.2 (#54). It currently fails on kube-prometheus-stack — T-2.24 (#327) | open |
| **E**levation of privilege | An image runs as something it should not | Images are digest-pinned and scanned, and an unpinned one now fails the list job (T-6.9, #330). Pod Security Standards are **not** enforced and there is **no default-deny NetworkPolicy** — T-8.2 (#60). Signing and admission verification are T-6.2 (#49) | open |

The tailnet belongs here too: node access is Tailscale-only, with no public SSH and no bastion
(ADR-0006). Its live defect is **#290 (T-1.29)** — stale devices keep a name pointed at a dead
node, which has already made a verification report a false negative.

## Accepted risks

Explicitly accepted, with what revokes each. Criterion 5: an acceptance without a trigger is a
thing somebody forgot.

| | Risk | Why it is accepted | Revoked when |
|---|---|---|---|
| **A1** | **Cloudflare sees plaintext.** TLS terminates at the edge, so a third party is on the serving path for every request | It is the price of ADR-0006's shape — no public listener, stable DNS across rebuilds, no load balancer billing while idle. The alternative is a public origin, which is a larger risk | The data behind this stemcell makes a third party on the path unacceptable — regulated data, or a contractual bar. That is a fork's decision, and it means changing the edge, not tightening it |
| **A2** | **Cloudflare is a single point of failure.** Its outage is a total outage, with no second path in | Dev. No SLA is owed to anyone, and a second ingress path costs a load balancer that bills while idle | An availability SLO is committed to (T-5.6 publishes them; T-7.6, #58, routes on them) |
| **A3** | **No encryption at rest under a key this project holds.** Documents, the database volume, base backups and the WAL archive are protected by access control, and by whatever the provider does at the storage layer — which is not verified here and is not relied on | Dev holds no real data, and application-level encryption is a key-management problem larger than the one it solves at this size. Stating it as "the provider encrypts it" would be exactly the unverified control criterion 3 rejects | Real user data lands, or a fork carries data whose exposure is regulated. The first step is then to establish what the provider actually guarantees, in writing, rather than to assume it |
| **A4** | **A leaked presigned URL is valid until it expires.** There is no revocation | Short expiry, server-generated keys, and the alternative (proxying every download through `core`) puts document bytes on the request path and costs the object store's whole advantage | Documents become sensitive enough that a leaked link is an incident rather than a nuisance |
| **A5** | **Audit and access logs are not durably retained.** Loki chunks expire at 30d and are in the disposable column; Cloudflare's logs are not exported at all | No compliance obligation exists, and durable audit is a durable-state decision (ADR-0002) rather than a logging one | A compliance requirement appears, or an incident needs a timeline older than 30 days. Then it is an ADR-0002 amendment, not a retention setting |
| **A6** | **Commits are not signature-verified.** Branch protection requires review and green checks; it does not require a signature | The threat it answers — a forged commit from a stolen token — is bounded by review being required, and the operational cost of signing on a solo project is high relative to that | More than one person can push, or T-6.2 (#49) lands signing for artefacts, at which point the same argument applies to commits and the cost is already paid |
| **A7** | **The cluster network is flat.** One NetworkPolicy exists (valkey ← apps); everything else is mutually reachable | Not a decision so much as work not yet done. It is listed here rather than only as T-8.2 so that a fork reading this today is not misled by the presence of one policy into thinking there is a posture | T-8.2 (#60) lands default-deny. Until then, assume any pod can reach any other |
| **A8** | **Dev is internet-reachable at all.** Cloudflare Access in front of it is the only thing between the internet and a development environment | #149 established Access as that control after finding the environment open. The alternative — tailnet-only — breaks the OIDC redirect and the smoke tests that run from CI | A staging environment exists (T-6.6, #194) and dev no longer needs to be reachable, or Access is found insufficient |

## Consequences

### What this makes easy

- A fork inherits a boundary map, so its first security question is "what did this stemcell accept
  that I cannot?" rather than "what does this do?".
- Every E8 card now has a stated reason to exist. T-8.2 is not "hardening in general"; it is A7 and
  three **open** rows.
- New work has a place to be checked against: a change that moves data across a boundary this
  record does not name is a change that needs the record updated.

### What this makes hard

- It dates. A threat model is a snapshot, and this one names specific open cards; when they close,
  the rows are wrong until somebody edits them. That cost is accepted — a stale model that is read
  beats an evergreen one that says nothing.
- It says out loud that the cluster network is flat and that there is no rate limiting. The
  repository is public. This is judged to be the right trade: everything here is derivable from the
  manifests in about ten minutes, and a fork that is not told will inherit the gap unknowingly.

### What it commits us to

Updating this when a boundary moves — a new external dependency, a new ingress path, a new
credential. Not when a mitigation's implementation changes.

The heavier commitment is the acceptances. Each is a decision with a trigger, and a trigger that
fires without anyone noticing is the failure mode this record shares with every other control it
criticises.

## Alternatives considered

### A control checklist (CIS, OWASP ASVS) — rejected as the primary artefact

Concrete, and it produces a score. Rejected because a checklist answers "did we do the things on
the list" and neither #148 nor #149 was on any list — both were boundaries nobody had drawn. A
checklist is a good *second* artefact, and T-8.2 is where one belongs.

### Attack trees per asset — rejected

Better for depth against a specific asset, worse for coverage. At this size the useful question is
"is any boundary unexamined", not "how many ways into the document store are there".

### LINDDUN (privacy threat modelling) — rejected, for now

The right tool once real personal data is behind this. Today the only personal data is a Keycloak
`sub` and whatever a user names a file, and running a privacy model over a system with no users
would produce findings about a hypothetical. Revisit with A3.

### One threat model per fork, none in the stemcell — rejected

The argument is that a stemcell cannot know its fork's threats, which is true. It is also how every
fork ends up with none: the moment to write it is never obviously now. Shipping the boundary map
and the acceptances means a fork edits a document rather than starting one, and the acceptances are
the part it most needs to see.

## Revisit if

- **A boundary moves.** A new ingress path, a new third party on the serving path, a new credential
  crossing a zone. Not when a mitigation's implementation changes.
- **Real data lands.** A3, A5 and the LINDDUN rejection all turn on this, and it is the single
  change that invalidates the most of this record at once.
- **Staging or prod exists** (T-6.6, #194). Half the acceptances rest on "this is dev".
- **More than one person can push** (A6), or the fork is not a solo project.
- **Any accepted risk's trigger fires.** That is what the trigger column is for; the acceptance is
  void, not weakened.
- **T-8.5 (#63) forks the stemcell into a throwaway project.** That exercise is the first real test
  of whether this record is usable by somebody who did not write it.
