# XenOpsBase Stemcell

A reusable, production-shaped backend skeleton with **no business logic in it**. Fork it per
project and grow domain code on top.

Runs on Hetzner, built entirely by Terraform, and leans on off-the-shelf components — auth,
logging, orchestration, scaling, document storage — rather than hand-rolled ones.

Planning board: [XenOpsBase Stemcell (project #5)](https://github.com/users/mertkan-iscan/projects/5)

## Decisions

| Decision | Choice |
|---|---|
| Topology | API gateway + one core service; microservice seams, two deployables |
| Orchestration | K3s on Hetzner. Agents boot a Packer golden image; the control plane is still provisioned by the `kube-hetzner` module |
| Generator | JHipster to bootstrap, then detach and own the code |
| Database | PostgreSQL via CloudNativePG operator, PITR archived to object storage |
| Documents | Hetzner Object Storage (S3-compatible), S3 API only |
| Edge | Cloudflare Tunnel — no public load balancer, DNS stable across rebuilds |
| Observability | Self-hosted Grafana LGTM (Loki, Grafana, Tempo, Prometheus) + OpenTelemetry |
| Identity | Keycloak, realm defined declaratively in git |
| GitOps | Argo CD, app-of-apps, bootstrapped by Terraform |
| Secrets | SOPS with age, encrypted in git, one bootstrap key per environment |
| Budget | Near zero when idle — the cluster is torn down and rebuilt on demand |

## The constraint that drives the design

"Near zero when idle" is not a budget number, it is the architecture. The cluster is **cattle, not
a pet**: nothing that matters may live inside it, and no state may be created by a human running
`kubectl`. That forces a hard durable-state boundary.

| Outside the cluster — survives `terraform destroy` | Inside — disposable |
|---|---|
| Uploaded documents (object storage) | All pods, PVCs, node disks |
| Postgres base backups + WAL archive (object storage) | The Postgres cluster itself |
| Terraform state (Cloudflare R2, locked — ADR-0005) | Ingress, cert-manager, Keycloak pods |
| Keycloak realm definition (git) | Issued sessions and tokens |
| All manifests and Helm values (git, GitOps) | Grafana dashboards at runtime |
| Container images (GHCR) | Loki index — chunks go to object storage |
| OS snapshot (Packer-built, Hetzner) | |
| Cloudflare edge — tunnel, DNS, Access, rulesets | |
| Object storage buckets, policies and lifecycle rules | |
| Mail DNS — Brevo, DMARC | |
| The age private keys — without them nothing decrypts | |

The bottom five rows survive `make down` because it destroys the cluster module and nothing else.
They were added by [ADR-0008](docs/adr/0008-durable-state-outside-terraform.md), which amends
ADR-0002 after an audit found the original table had been assembled by asking what lives *in* the
cluster — a question that cannot find state living outside it.

### What it actually costs

Priced from Hetzner's own API rather than a figure typed once and left to rot — `make cost` reads
the project and prints this live, including anything orphaned.

| | € / hour | € / day |
|---|---|---|
| 1 × cx23 control plane | 0.0088 | 0.21 |
| 2 × cx33 workers | 0.0272 | 0.65 |
| 3 primary IPv4 | 0.0024 | 0.06 |
| 3 × 10 GB volumes | 0.0023 | 0.06 |
| **running total** | **0.0408** | **0.98** |
| OS snapshot, 1.5 GB — survives `make down` | 0.00003 | 0.0007 |

**About €1 a day while up, and about €0.02 a month while down.** The second number is the one
ADR-0002 is about: what survives a teardown is the snapshot and the object storage, and neither is
billed by the hour.

Measured 2026-08-24 at the dev sizing. It is not a promise — server prices change and the sizing
will — which is why `make cost` exists and this table does not need to be trusted.

A scheduled check fails if a cluster has been running longer than twelve hours, or if anything
billable is attached to nothing. It does not destroy anything: `make down` needs the cluster's API
to flush the WAL first, and CI cannot reach it (#195).

The payoff: **cold rebuild from nothing is the everyday path, not a rare fire drill.** The DR test
and the deploy pipeline are the same code, exercised every time work starts.

### The lifecycle is two commands

```bash
make up ENV=dev      # apply, then wait until the stack is SERVING
make down ENV=dev    # destroy everything billable, then prove it
```

`up` does not finish when Terraform does. It waits on three gates — every node `Ready`, every Argo
Application `Healthy`, then the public hostname answering — because the gap between "the apply
succeeded" and "the stack works" is where the interesting failures live.

`down` releases CSI volumes while the cluster can still do it, destroys, and then runs
`verify-teardown`, which asserts both halves of the table above: the durable column survived, and
nothing billable was orphaned.

| | measured | notes |
|---|---|---|
| `make up`, already serving | **15s** | Idempotent. Terraform reports no changes; the gates pass in 2s. |
| `make down` | *see T-7.2* | |
| `make up`, from nothing | *see T-7.2* | |

The two cold figures are deliberately **not** filled in from memory. [T-7.2](../../issues/54) owns
the measured cold rebuild, and a number recorded here from a run nobody timed is worse than an
empty cell — it would be quoted back as a capacity fact.

## Critical path

```
T-0.3 -> T-1.1 -> T-1.3 -> T-2.1 -> T-2.4 / T-2.5 -> T-3.2 -> T-7.2
```

State boundary decided, Terraform state exists, cluster exists, GitOps converges it, Postgres and
Keycloak run, the app authenticates against them, and the cold rebuild proves the whole thing
reproduces from nothing.

## Epics

| Label | Epic |
|---|---|
| `E0-foundations` | Foundations & decisions (ADRs) |
| `E1-infrastructure` | Infrastructure as code (Terraform) |
| `E2-platform` | Cluster platform, off-the-shelf |
| `E3-app-skeleton` | Application skeleton |
| `E4-devex` | Developer experience |
| `E5-testing` | Testing strategy |
| `E6-cicd` | CI/CD |
| `E7-dr-ops` | Disaster recovery & operations |
| `E8-security` | Security, cost & release |

## Documentation

- [Architecture decision records](docs/adr/README.md) — what was decided and why
  - [ADR-0001](docs/adr/0001-service-topology.md) — gateway plus one core service
  - [ADR-0002](docs/adr/0002-ephemeral-cluster-and-durable-state.md) — the durable-state boundary
  - [ADR-0003](docs/adr/0003-secrets-management.md) — SOPS and age, one bootstrap secret
  - [ADR-0004](docs/adr/0004-gitops-engine.md) — Argo CD, app-of-apps
  - [ADR-0005](docs/adr/0005-terraform-state-backend.md) — Terraform state in Cloudflare R2
  - [ADR-0006](docs/adr/0006-tailscale-node-transport.md) — Tailscale transport, no public API endpoint
  - [ADR-0007](docs/adr/0007-postgres-backup-mechanism.md) — Postgres backs up through the Barman Cloud plugin
  - [ADR-0008](docs/adr/0008-durable-state-outside-terraform.md) — durable state Terraform does not create; amends ADR-0002
  - [ADR-0009](docs/adr/0009-in-memory-store.md) — Valkey is the in-memory store, and it is disposable
  - [ADR-0010](docs/adr/0010-user-identity-durability.md) — user identity is durable; declared users carry explicit ids
  - [ADR-0012](docs/adr/0012-database-scaling.md) — how the database scales, and the evidence required first
- Spikes
  - [T-3.1 JHipster](docs/spikes/t-3.1-jhipster.md) — what it generates, what gets deleted, and why
- [CHANGELOG.md](CHANGELOG.md) — what moved away from the generated defaults, and why
- [services/README.md](services/README.md) — package conventions and the tech.jhipster exit path
- [CONTRIBUTING.md](CONTRIBUTING.md) — branching, commits, and the no-manual-configuration rule
- [Forking this into a new project](docs/forking.md) — what to rename, what to delete, what to keep
- [Service level objectives](docs/slos.md) — measured latency and throughput, and what they say about autoscaling
- Runbooks
  - [Everyday operation](docs/runbooks/everyday-operation.md) — **start here**: `make up`, `make down`, what to check, and when you do not need a cluster at all
  - [Local development](docs/runbooks/local-development.md) — one command, no cluster, no credentials
  - [Cold rebuild](docs/runbooks/cold-rebuild.md) — the drill, and what to do when the automation itself fails
  - [Disaster recovery](docs/runbooks/disaster-recovery.md) — RPO and RTO per component, measured; scenarios; what is not protected
  - [Secrets](docs/runbooks/secrets.md) — SOPS, age, the one bootstrap key, rotation
  - [Promotion](docs/runbooks/promotion.md) — moving a build between environments, and the gate before production
  - [Terraform CI](docs/runbooks/terraform-ci.md) — lint, checkov, plan-on-PR, manual apply
  - [Edge](docs/runbooks/edge.md) — Cloudflare tunnel, DNS, and the shared-zone hazard
  - [Network access](docs/runbooks/network-access.md) — exposure model, SSH policy, escape hatch
  - [Environments](docs/runbooks/environments.md) — dev/staging/prod layout, ENV targets, guards
  - [Terraform state](docs/runbooks/terraform-state.md) — bootstrap, locking, recovery
  - [Authorization](docs/runbooks/authorization.md) — roles, method-level checks, service-to-service
  - [Database](docs/runbooks/database.md) — backups, restore, failover, and what a rebuild does not restore
  - [Ingress and TLS](docs/runbooks/ingress-tls.md) — the serving path, QUIC firewall, DNS-01 certificates
  - [Object storage](docs/runbooks/object-storage.md) — per-environment durable buckets, retention, least privilege

## Prior art

Generalized from `mertkan-iscan/hedportal-terraform`, which runs the same shape in production.
The stemcell exists partly to close the three gaps that project's `docs/DISASTER-RECOVERY.md`
names as known and accepted: no offsite copy, no schema rollback, no point-in-time recovery.
