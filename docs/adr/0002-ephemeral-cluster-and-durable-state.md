# ADR-0002: The cluster is ephemeral, and durable state lives outside it

- **Status:** Accepted
- **Date:** 2026-08-18
- **Task:** T-0.3

## Context

The stemcell targets **near-zero infrastructure cost while idle**. Projects built from it are
developed in bursts; between bursts, nothing should be billed. The intended lifecycle is therefore
`make up` at the start of a working session and `make down` at the end, plus destroy-and-rebuild
whenever infrastructure changes.

Treated as a budget line this is unremarkable. Treated as an architectural constraint it is the
single most consequential decision in the project, because it makes one property mandatory:
**destroying the cluster must never destroy anything that matters.**

That property does not arrive by intention. It arrives by drawing an explicit boundary and then
refusing to cross it. Every system that has lost data to a teardown lost it to something nobody
remembered was in there — a hand-applied secret, a dashboard built in a UI, a realm configured in
an admin console, a volume someone assumed was backed up.

The precedent is direct. The predecessor project `hedportal-terraform` documents this exact class
of assumption in its disaster-recovery runbook: Hetzner snapshots cover the root disk only, and
attached volumes — holding the database and every uploaded document — are excluded. The failure
mode is not that backups were missing. It is that the boundary between protected and unprotected
was implicit, and therefore got assumed wrongly.

## Decision criteria

- Can the property be **verified mechanically**, rather than remembered?
- Does the cost of a rebuild stay low enough that rebuilds actually happen? A rebuild path that is
  expensive stops being exercised, and an unexercised recovery path does not work.
- Does the boundary hold for a **new** component added later by someone who has not read this ADR?

## Decision

The cluster is **cattle**. It may be destroyed at any time, by anyone, without notice or
preparation, and rebuilt from this repository plus the contents of object storage.

### The durable-state boundary

| Lives **outside** the cluster — survives `terraform destroy` | Lives **inside** — disposable |
|---|---|
| Uploaded documents — Hetzner Object Storage | All pods, PVCs and node disks |
| PostgreSQL base backups and WAL archive — object storage | The PostgreSQL cluster itself |
| Terraform state — object storage, versioned and locked | Ingress, cert-manager, Keycloak pods |
| Keycloak realm, clients, roles — JSON in git | Issued sessions and tokens |
| Keycloak **users and their `sub`** — Postgres, restored with it (ADR-0010) | Grafana's and Prometheus's own volumes |
| All manifests and Helm values — git, reconciled by GitOps | Grafana dashboards at runtime |
| Container images — GHCR | Loki index; chunks go to object storage |

Anything not in the left column **will be lost**, and losing it must be acceptable. If a new
component needs state that is not acceptable to lose, that state moves to the left column before
the component ships. There is no third category.

### The operating rule

> **No state may be created by a human.**

Not `kubectl apply` against a live cluster. Not a click in the Hetzner console. Not a realm edited
in the Keycloak admin UI. Not a dashboard built in Grafana. Not a secret typed into a terminal.

Every one of those produces state that exists in exactly one place, is invisible to review, and
disappears at the next teardown — silently, and usually at the moment it is most needed.

The rule is not a matter of discipline. It is enforced structurally: GitOps reconciles the cluster
from git and reverts drift, and the nightly rebuild drill (T-7.3) destroys anything that survived
by accident. Hand-made state does not persist long enough to be depended upon, which is the point.

### Recovery objectives

These are targets that the design must hit, to be measured and recorded by T-7.2 and tracked over
time by T-7.3. If a measurement misses a target, either the design or the target changes — the
number is not quietly abandoned.

| Objective | Target | Mechanism |
|---|---|---|
| Cold rebuild: empty Hetzner project to serving, data restored | ≤ 60 min | `make up` plus GitOps convergence plus restore |
| Warm start: `make up` on unchanged infrastructure code | ≤ 20 min | Same path, cached module and image layers |
| RPO, uploaded documents | 0 | Never stored in the cluster; teardown cannot affect them |
| RPO, database | ≤ 5 min | Continuous WAL archiving to object storage. Worst case, not typical — set by `archive_timeout` in `platform/envs/dev/database/cluster.yaml` (T-2.13) |
| Rollback of an application version | ≤ 5 min | Image tag revert through GitOps (T-6.4) |

## Consequences

### What this makes easy

- **Disaster recovery stops being a separate discipline.** The rebuild path and the deploy path
  are the same code, exercised at the start of every working session. The most common reason DR
  fails — the runbook was written once and never run — is structurally removed.
- Cost tracks usage rather than calendar time.
- Infrastructure changes are tested by destroying and rebuilding, not by mutating a long-lived
  cluster whose current state nobody fully knows.
- Configuration drift cannot accumulate, because nothing lives long enough to drift.

### What this makes hard

- **Every stateful component needs its state externalized before it ships.** This is real work per
  component and is the main tax this ADR imposes.
- Observability history does not survive teardown unless it is written to object storage. Loki
  chunks go there; the Prometheus TSDB does not. Metrics history is bounded by cluster lifetime,
  and that is accepted (T-2.6).
- Bootstrapping needs at least one credential that exists before the cluster does. Minimizing that
  surface is exactly the problem ADR-0003 has to solve.
- First request after `make up` is slow, and TLS issuance must not hit Let's Encrypt rate limits
  under frequent rebuilds (T-2.2).

### What it commits us to

This ADR is upstream of most of the board. T-1.1 (remote state), T-1.7 (`make up` / `make down`),
T-2.1 (GitOps convergence), T-2.4 (WAL archiving), T-2.5 (declarative realm), T-7.2 (cold rebuild)
and T-7.3 (nightly drill) all exist to satisfy it. Reversing it — moving to a long-lived cluster —
would not break those tasks, but it would remove the forcing function that keeps them honest.

## Alternatives considered

### A long-lived cluster with scheduled backups — rejected

The conventional approach, and operationally simpler day to day. Rejected because it fails the
cost target outright, and because it makes the recovery path rare. A restore procedure exercised
quarterly is a procedure that works quarterly. The predecessor project demonstrates the specific
consequence: a carefully written runbook, and a boundary between protected and unprotected data
that had to be discovered rather than declared.

### A long-lived cluster, scaled to zero when idle — rejected

Keeps the control plane and volumes alive while workloads scale down. Cheaper than always-on but
not near-zero, since control-plane nodes and block storage bill continuously. It also preserves
exactly the thing this ADR is trying to eliminate: a place for undocumented state to hide.

### Fully managed platform, such as a PaaS — rejected

Would remove most of this work. Rejected because the stemcell's purpose includes owning and
understanding the infrastructure layer, and because per-service managed pricing does not reach
near-zero when idle.

## Revisit if

- A component proves genuinely impossible to externalize, forcing either a pet node or a change to
  this decision.
- Measured cold-rebuild time exceeds the 60-minute target by enough that rebuilds stop happening
  in practice. Watch T-7.3's recorded times for a trend, not a single bad run.
- A project forked from the stemcell needs continuous availability, at which point that fork —
  not the stemcell — supersedes this ADR.
