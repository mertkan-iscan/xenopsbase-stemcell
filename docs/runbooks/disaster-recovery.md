# Disaster recovery

**Task:** T-7.1 (#53) · **Decides nothing on its own** — it records what ADR-0002, ADR-0007 and
ADR-0010 already imply, and states the parts nobody had written down.

Every figure below was measured or read from the running system on 2026-08-22, not estimated. Where
something is unverified, it says so.

## RPO and RTO per component

RPO is how much you lose. RTO is how long until it is back.

| Component | RPO | RTO | Mechanism |
|---|---|---|---|
| Uploaded documents | **0** | 0 for the data, stack RTO for access | Never in the cluster. Versioned bucket, noncurrent versions kept 90 days |
| Postgres — `core`, `keycloak`, `app` | **≤ 5 min** | ~18 min, measured | WAL archived every 300s + daily base backup, Barman Cloud plugin (ADR-0007) |
| Keycloak users and their `sub` | ≤ 5 min | ~18 min | Rides on Postgres. Ownership depends on this (ADR-0010) |
| Terraform state | ~0 | minutes | R2, versioned and locked (ADR-0005) |
| Cloudflare edge — DNS, tunnel, Access | 0 | 0 | Outside the cluster entirely; `terraform destroy` of the cluster does not touch it |
| Container images | 0 | minutes | GHCR, and reproducible from the commit (T-6.1) |
| OS snapshot | 0 | ~10 min to rebuild | `make snapshot`, once per Hetzner project |
| The cluster itself | n/a — disposable | **1058s measured** | `make up`, ADR-0002 |
| Valkey — sessions | **total loss, by design** | n/a | Disposable (ADR-0009). Everyone is signed out |
| Prometheus history | **total loss** | n/a | Volume deleted with the cluster. See "what is not protected" |
| Loki logs | ≤ chunk flush | stack RTO | Chunks in object storage, expire at 30 days |
| Tempo traces | ≤ flush | stack RTO | Object storage, expire at 7 days |
| **SOPS-encrypted secrets** | 0 | **∞ without the age key** | See the section on the age key. This is the one that ends the project |

### Where the measured numbers come from

**Stack RTO: 1058s** — a full `make down` followed by `make up ENV=dev` on 2026-08-22. Terraform
provisioning plus GitOps convergence to a serving stack: 716s of that was from Terraform-complete to
`https://app-dev.xenopsoftware.com` answering. ADR-0002's target is ≤ 60 min cold; the measured
figure is well inside it, for a rebuild where durable state was intact.

**Database RPO: 5 minutes**, read from the running server rather than from the manifest:

```
archive_mode = on
archive_timeout = 300 s
wal_level = logical
```

Corroborated by the bucket — WAL segments land at 12:21, 12:26, 12:31, 12:36.

**`archive_timeout` is not pinned anywhere in `platform/`.** 300s is CNPG's default, not a value
this project chose. The stated RPO therefore rests on an upstream default that could change under a
chart bump, silently, and the first sign would be a worse RPO nobody asked for. Filed as T-2.13
(#164).

Note also that 300s is a *ceiling*: it bounds how long a quiet database waits before forcing a
segment. A busy one archives sooner, so 5 minutes is the worst case rather than the typical one.

**Document RPO: 0** — documents are written directly to object storage by a presigned PUT and never
enter the cluster, so there is no window in which a cluster failure can lose one. Verified on
2026-08-22: the 13 documents uploaded before a destroy were listed and downloaded by their owner
afterwards.

## What is protected, bluntly

Everything in the left column of ADR-0002's durable-state table, and nothing else.

Concretely: uploaded documents, the contents of all three Postgres databases including every
Keycloak user, Terraform state, the Cloudflare edge, and the images. A total loss of the Hetzner
*cluster* costs you the time in the table above and nothing else.

## What is not protected, equally bluntly

**Prometheus history is gone on every rebuild.** The TSDB is a PVC. `make down` deletes it, and
`verify-teardown` treats a surviving one as a leak to be removed (#159 covers the case where it is
not deleted). There is no metrics history across a rebuild and there is not meant to be. If a
dashboard needs to answer "what did this look like last week", it cannot.

**Every session is destroyed.** Valkey is disposable, so a rebuild signs everybody out. That is
correct and it is not a fault.

**Nothing is replicated off Hetzner.** Documents, backups and logs are all in one provider, in one
region (fsn1). A provider-level or region-level loss takes all of it at once. T-7.5 (#57) is the
card; it is not built. **This is the largest single gap in this plan.**

**There is no second copy of Terraform state outside R2.** T-1.9 (#71) is the card; not built.

**No restore has ever been proven end to end by automation.** T-7.3 (#55) and T-7.4 (#56) are not
built. Everything in the RTO column for Postgres is inferred from a rebuild that used
`bootstrap.recovery` successfully — which is a real restore, but it is not a *drill*, and nobody
has demonstrated point-in-time recovery to an arbitrary timestamp.

## The age key, which is the real single point of failure

Every secret in this repository is encrypted to one age recipient:

```
age1sgwm6ckyjns0grwu6hsc6zhh2esh3ja7xmwynkw9ukc3ygq8tf8qsgusx5
```

The private half lives in `TF_VAR_sops_age_key`, in `~/.xenopsbase.env`, on one machine.

**Lose it and nothing else in this plan matters.** The cluster rebuilds from nothing, the database
restores, the documents were never at risk — and none of it can be brought up, because the database
credentials, the gateway client secret, the S3 keys and the Cloudflare token are all ciphertext that
nothing can read. Backups you cannot decrypt are not backups.

There is no escrow, no second recipient, and no documented recovery. That is an omission being
named, not a decision: nobody chose it. ADR-0003 weighed SOPS against Vault and External Secrets and
did not discuss key custody at all.

Adding a second recipient costs one line in `.sops.yaml` and a re-encrypt. It is **the
highest-value item in this document**, and it is filed as T-0.8 (#163).

## Scenarios

Symptom first, because that is what you have when it happens.

### The site is down and the cluster is unreachable

```bash
source ~/.xenopsbase.env
export KUBECONFIG=$PWD/infra/terraform/cluster/kubeconfig
kubectl get nodes                    # nothing? the cluster is gone or the tailnet is down
tailscale status                     # nodes are reachable only over the tailnet (ADR-0006)
```

If the nodes are gone, rebuild. This is routine, not an emergency:

```bash
make up ENV=dev
```

Expect ~18 minutes. Postgres restores from the archive automatically —
`bootstrap.recovery` is the configured path, not a manual step. Then verify ownership survived,
because that is the part a database check misses:

```bash
# sign in as the owning user and confirm the documents are reachable
curl ... /services/core/api/documents      # expect X-Total-Count to match what it was
```

### The site is up but every login fails

Check whether the realm survived, not just the database:

```bash
kubectl exec -n database postgres-1 -c postgres -- \
  psql -U postgres -d keycloak -At -c \
  "SELECT ue.username, ue.id FROM user_entity ue JOIN realm r ON ue.realm_id=r.id WHERE r.name='xenopsbase';"
```

If the users are present with their original ids, identity is intact and the fault is elsewhere —
check the gateway's OIDC configuration and the issuer hostname. If the ids have *changed*, a realm
was deleted and re-imported; documents are now owned by users that no longer exist. ADR-0010 and
`docs/runbooks/authorization.md` cover it. Declared users carry pinned ids precisely so this cannot
happen by accident.

### A document is missing or was overwritten

The bucket is versioned and noncurrent versions are kept 90 days.

```bash
aws --endpoint-url https://fsn1.your-objectstorage.com \
  s3api list-object-versions --bucket xenopsbase-dev-documents --prefix <key>
```

Restore by copying the desired version id back over the current one. Past 90 days the lifecycle rule
has removed it and it is gone.

### A bad deploy

Revert the digest in `platform/envs/dev/services/kustomization.yaml` to the previous one — the file
is the deployment history, one commit per deploy — and let Argo sync. Roughly two minutes to
healthy in practice, unmeasured.

**A rollback does not undo a database migration.** Flyway has already run; reverting the image
leaves the new schema in place under the old code. If the migration is the problem, the recovery is
point-in-time recovery, not a rollback. T-6.4 (#51) is the card that builds and measures this
properly; it depends on T-6.3 (#50).

### The database is corrupted, or a migration destroyed data

Point-in-time recovery. **This has never been performed here** — T-7.4 (#56) is the card that proves
it. The mechanism exists: base backups at

```
s3://xenopsbase-dev-pg-backups/postgres-g3/base/
  20260820T142252/  20260820T153608/  20260821T104801/  20260822T084633/
```

with continuous WAL alongside, retained 30 days by Barman and 35 days by the bucket lifecycle rule.
The bucket is deliberately the longer of the two, so lifecycle never deletes something Barman still
expects to find.

Recovery to a timestamp means a new `Cluster` with `bootstrap.recovery` and a
`recoveryTarget`. Do not attempt it for the first time during an incident.

### The whole Hetzner project is lost

Everything durable except the documents and backups themselves is elsewhere: Terraform state in R2,
images in GHCR, the edge in Cloudflare, all manifests in git. Recovery is `make bootstrap-state` if
needed, `make snapshot`, then `make up`.

But the documents and the database backups were in that project. **There is no second copy.** This
scenario is currently unrecoverable for data, by omission rather than by decision — see T-7.5 (#57).

## Known gaps, as deliberate decisions

Listed so the next person inherits the reasoning, not just the gap.

| Gap | Card | Why it is still open |
|---|---|---|
| No offsite replication to a second provider | #57 | The largest gap here. Cost and complexity were deferred while the project was pre-v1 |
| No automated restore drill | #55 | Must assert a pre-rebuild document is downloadable by its owner afterwards, not just that Postgres came back |
| PITR never proven | #56 | The mechanism is configured and untested. Untested recovery is a belief |
| Backup age is not observable | #145 | `LastBackupSucceeded: True` while `lastSuccessfulBackup` is empty — see below |
| No application metrics reach Prometheus | #155 | So alerting on backup age cannot be built even if the field were populated |
| `archive_timeout` not pinned | #164 | The stated 5-minute RPO depends on a CNPG default |
| Lifecycle rules are shared across environments | #151 | A retention change for dev would apply to prod |
| No second age recipient | **#163** | Nobody decided this; see the age key section |
| Rollback not measured | #51 | Blocked on T-6.3 (#50) |

### The one that undermines the rest

On 2026-08-22 the cluster reported:

```
ContinuousArchiving   True   Continuous archiving is working
LastBackupSucceeded   True   Backup was successful

lastSuccessfulBackup:      <empty>
firstRecoverabilityPoint:  <empty>
```

Backups are genuinely working — four base backups and current WAL are in the bucket, checked
directly. But the two fields that say *how old the newest recoverable point is* are blank, so
nothing can alert on backup age. The conditions are green whether the last backup was an hour ago
or a month ago.

This is #145, and it matters more in a DR document than anywhere else: the entire plan above
assumes you find out when backups stop. Today you would not. **Until #145 is fixed, check the bucket
directly** rather than trusting the cluster status:

```bash
aws --endpoint-url https://fsn1.your-objectstorage.com \
  s3 ls s3://xenopsbase-dev-pg-backups/postgres-g3/base/
```
