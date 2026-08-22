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
| Orchestration | K3s on Hetzner via the `kube-hetzner` Terraform module |
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
- Spikes
  - [T-3.1 JHipster](docs/spikes/t-3.1-jhipster.md) — what it generates, what gets deleted, and why
- [CHANGELOG.md](CHANGELOG.md) — what moved away from the generated defaults, and why
- [services/README.md](services/README.md) — package conventions and the tech.jhipster exit path
- [CONTRIBUTING.md](CONTRIBUTING.md) — branching, commits, and the no-manual-configuration rule
- Runbooks
  - [Disaster recovery](docs/runbooks/disaster-recovery.md) — RPO and RTO per component, measured; scenarios; what is not protected
  - [Secrets](docs/runbooks/secrets.md) — SOPS, age, the one bootstrap key, rotation
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
