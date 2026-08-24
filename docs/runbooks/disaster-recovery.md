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
| **SOPS-encrypted secrets** | 0 | **∞ without an age key** | Two recipients since 2026-08-23 (T-0.8); either alone decrypts everything |

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

**`archive_timeout` is pinned in `platform/envs/dev/database/cluster.yaml`** (T-2.13, #164). It
holds the same 300s that CNPG defaults to, so pinning it changed no behaviour — it changed who owns
the number. Before, the published RPO rested on an upstream default: a chart bump could have moved
it with no manifest differing, no alert firing, and the first evidence being more data lost than
expected during a real recovery. The setting now carries a comment naming this runbook and ADR-0002,
so it cannot be changed without the documents that quote it surfacing.

**5 minutes is a worst case, not the typical loss.** `archive_timeout` is a *ceiling*: it bounds how
long a **quiet** database waits before forcing a WAL segment. A busy one fills segments and archives
sooner, so actual loss is usually well under the figure. The worst case is the only number safe to
publish, and it is the one quoted here and in ADR-0002 — but do not read it as an estimate of what a
given incident will cost.

**Worst-case RPO, measured (T-7.4, #56): 301 seconds.**

Two components, both measured on 2026-08-22 rather than assumed:

| | |
|---|---|
| Time a committed transaction can sit in an unarchived segment | ≤ 300s — `archive_timeout` |
| Time from segment close to the object existing in the bucket | **1.08s**, measured |

```
pg_switch_wal() at   09:57:57.150
last_archived_time   09:57:58.227
```

So the most a sudden total loss of the primary and its volume can cost is **301 seconds of
commits** — and only if the loss lands in the worst instant of a quiet period. Under write load the
segment fills and ships sooner, and the figure improves without anything being reconfigured.

This is the number to quote. ADR-0002's "≤ 5 min" is correct, and this is where it comes from.

**One observation worth recording rather than alarming about.** `pg_stat_archiver` shows
`failed_count = 12`, all against `00000006.history` at 08:45:03 — during the recovery bootstrap of
that morning's rebuild, before the archiver settled. There have been no failures since and
`archived_count` climbs normally. A *rising* `failed_count` would be the thing to act on, and there
is currently nothing watching it (#155, #145).

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

**No restore is proven by automation.** Point-in-time recovery *has* now been demonstrated by hand
(#56, and the drill below reproduces it), but nothing runs it on a schedule, so a regression would
go unnoticed until it mattered. T-7.3 (#55) is that card and it is not built.

## The age keys, and why there are now two

Every secret in this repository is encrypted to **two** age recipients, and either one alone
decrypts everything:

| Recipient | Private half | Role |
|---|---|---|
| `age1sgwm6cky…q8tf8qsgusx5` | `TF_VAR_sops_age_key` in `~/.xenopsbase.env`, plus the `SOPS_AGE_KEY` GitHub Actions secret | everyday work and CI |
| `age16y5yn6md…tlw3qfq7repy8` | offline, off this machine — location in [secrets.md](secrets.md) | recovery only |

**Every RTO in the table above is conditional on being able to decrypt.** The cluster rebuilds from
nothing, the database restores from the WAL archive, the documents were never at risk — and none of
it comes up if the database credentials, the gateway client secret, the S3 keys and the Cloudflare
token are ciphertext nothing can read. Backups you cannot decrypt are not backups.

Until 2026-08-23 there was one recipient, one private half, one machine, and no escrow. That was an
omission rather than a decision — ADR-0003 weighed SOPS against Vault and External Secrets and did
not discuss custody at all. It is fixed under T-0.8 (#163) and recorded as an amendment to that ADR.

### Recovering when the everyday key is gone

This is the scenario the second key exists for: the machine is gone, or `~/.xenopsbase.env` is.

```bash
export TF_VAR_sops_age_key="$(cat /path/to/escrow.age)"
make up ENV=dev
```

Everything downstream is the ordinary path. The escrow key is not a different mechanism, it is the
same mechanism with the other key — which is deliberate, because a recovery path that works
differently from the everyday one is a recovery path nobody has exercised.

Verified on 2026-08-23 by decrypting with the primary removed from the environment; the control,
with neither key present, correctly refused.

### What still has to be true

- The escrow key is **not on this machine**. If it is still at `~/.xenopsbase-escrow.age`, this
  section is describing redundancy that does not exist — two copies on one disk are one copy.
- Both files carry both recipients. Adding a recipient to `.sops.yaml` does not re-key existing
  files and sops reports no error, so `make secrets-verify` runs on every pull request to catch it.

### What this does not fix

Both keys are held by one person. This removes the single *object* whose loss is unrecoverable, not
the single *person*. A cloud KMS recipient, recoverable through an account rather than an object, is
the next layer and is tracked as T-0.9 (#191).

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

Point-in-time recovery. **Demonstrated on 2026-08-22** (T-7.4, #56) — a restore to an arbitrary
instant, asserted in both directions, with the drill below reproducing it. Base backups at

```
s3://xenopsbase-dev-pg-backups/postgres-g3/base/
  20260820T142252/  20260820T153608/  20260821T104801/  20260822T084633/
```

with continuous WAL alongside, retained 30 days by Barman and 35 days by the bucket lifecycle rule.
The bucket is deliberately the longer of the two, so lifecycle never deletes something Barman still
expects to find.

#### The drill, which is also the procedure

`infra/drills/pitr-cluster.yaml` is a throwaway `Cluster` that restores the `postgres` lineage to a
chosen instant. It lives outside `platform/` deliberately: anything under `platform/envs/<env>/` is
reconciled by Argo CD and would be kept alive, which is the opposite of a drill.

**It has no `plugins:` block, and that is the one thing not to "fix".** Give it one and it starts
archiving into `s3://.../postgres-g3/` — the live lineage the real cluster restores from. Two
servers writing one archive, discovered during the next real recovery. `externalClusters` is
read-only and is how the restore *finds* the archive.

```bash
export KUBECONFIG=$PWD/infra/terraform/cluster/kubeconfig
TARGET="2026-08-22 09:53:13.735077+00"          # any instant inside the retention window

sed "s|__TARGET_TIME__|$TARGET|" infra/drills/pitr-cluster.yaml | kubectl apply -f -
kubectl get cluster postgres-pitr -n database -w   # ~2 min to "Cluster in healthy state"

kubectl exec -n database postgres-pitr-1 -c postgres --   psql -U postgres -d app -c "SELECT * FROM <your table>;"
```

**Always clean up, and the PVC is a separate delete:**

```bash
kubectl delete cluster postgres-pitr -n database
kubectl delete pvc -n database -l cnpg.io/cluster=postgres-pitr
```

Deleting the `Cluster` alone leaves 10Gi of Hetzner volume billing indefinitely — the same trap as
T-1.11 (#109) and T-1.16 (#159). Confirm with `hcloud volume list`, or against the API, that the
count returned to its steady state.

#### What the drill proved

Two rows were committed sixty seconds either side of a chosen target:

```
committed 09:52:13.668  'BEFORE the target'
target    09:53:13.735
committed 09:54:13.796  'AFTER the target'
```

The restored cluster contained the first and not the second, while the live cluster still had both:

```
PASS: row committed BEFORE the target is present
PASS: row committed AFTER the target is absent
```

Correctness in both directions matters. A restore that simply came up would have passed a
present-row check while silently replaying too far.

**Restore took 107 seconds** for a 10Gi cluster — base backup fetch, WAL replay to the target, and
promotion. That is the RTO for a corrupted database, and it is far below the whole-stack figure
because nothing else is rebuilt.

Do not attempt this for the first time during an incident. That is what the drill is for.

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
| ~~PITR never proven~~ | **closed** | Demonstrated 2026-08-22, #56. `infra/drills/pitr-cluster.yaml` reproduces it |
| ~~`archive_timeout` not pinned~~ | **closed** | Pinned 2026-08-24, #164. Same value, but now this project's rather than CNPG's |
| Backup age is not observable | #145 | `LastBackupSucceeded: True` while `lastSuccessfulBackup` is empty — see below |
| No application metrics reach Prometheus | #155 | So alerting on backup age cannot be built even if the field were populated |
| Lifecycle rules are shared across environments | #151 | A retention change for dev would apply to prod |
| Both age keys held by one person | #191 | Two recipients removes the single object, not the single person |
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

This is #145, and the cause is now known. Under the barman-cloud **plugin** backup method this
project uses, CloudNativePG never populates the in-tree backup fields:
`status.lastSuccessfulBackup` is absent from the resource altogether, and
`cnpg_collector_last_available_backup_timestamp` is pinned at `0`. Both belong to the deprecated
`barmanObjectStore` path. `LastBackupSucceeded` is maintained from `Backup` resources and is
truthful — it simply says nothing about *age*.

So no field on the cluster answers "when did this last back up". Read the bucket instead:

```bash
make backup-status ENV=dev
```

```
✓ base backups: 4, newest 20260822T084633 (90 min old)
✓ WAL: newest 000000060000000100000080.gz (4 min old)

  for contrast, what the Cluster resource says:
      LastBackupSucceeded condition : True
      status.lastSuccessfulBackup   : <absent — see #145>

BACKUP CHECK PASSED
```

It exits non-zero when the newest base backup is older than 30 hours or the newest WAL segment is
older than 15 minutes, and **it gates `cluster-destroy`** — the pre-destroy question is "is this
recoverable", and that check now reads objects rather than a condition. `SKIP_BACKUP_CHECK=1`
overrides it, because a cluster whose backups are broken is exactly one you may still need to tear
down.

Two alerts, `PostgresNoRecentBaseBackup` and `PostgresLastBackupFailed`, cannot fire for the same
reason. They are documented as such in place rather than deleted, so they resume working by
themselves if the metric is ever populated. `PostgresBackupAgeUnobservable` fires while they cannot,
and `PostgresArchivingStalled` covers the RPO directly from `pg_stat_archiver`, which does carry
real values.
