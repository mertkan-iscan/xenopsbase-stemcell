# Runbook: Postgres

CloudNativePG, with continuous archiving to object storage through the Barman Cloud plugin
([ADR-0007](../adr/0007-postgres-backup-mechanism.md)).

## The shape of it

```
Cluster/postgres           2 instances, anti-affinity, one per worker
  └─ plugins[]             barman-cloud.cloudnative-pg.io, isWALArchiver: true
       └─ ObjectStore      pg-backups  ->  s3://xenopsbase-<env>-pg-backups/
            └─ Secret      pg-backup-s3  (SOPS-encrypted, the `db` key only)
ScheduledBackup/postgres-daily   03:00, method: plugin
```

The Postgres volumes are a **working disk**. The bucket is the durable copy
([ADR-0002](../adr/0002-ephemeral-cluster-and-durable-state.md)). Anything that only exists on the
volumes is expected to be lost.

## Is it actually backing up?

Two things must be true, and only one of them is obvious.

```bash
kubectl -n database get cluster postgres
kubectl -n database get backup
```

A `Cluster` reporting `Cluster in healthy state` says **nothing** about archiving. Check the bucket
directly:

```bash
source ~/.xenopsbase.env
curl -sS --aws-sigv4 "aws:amz:fsn1:s3" \
  --user "$PG_BACKUP_ACCESS_KEY_ID:$PG_BACKUP_SECRET_ACCESS_KEY" \
  "https://fsn1.your-objectstorage.com/xenopsbase-dev-pg-backups?list-type=2" \
  | grep -oE '<Key>[^<]*</Key>'
```

Expect both, and be suspicious if you only see one:

```
postgres/base/<timestamp>/          base backups
postgres/wals/<timeline>/           WAL segments, continuously
```

**Base backups without WAL** means recovery can only reach the last base backup. **WAL without a
base backup** means recovery is impossible: WAL only replays forward from a base.

### Why this needs checking rather than trusting

The two ways it breaks are both silent:

- A `Cluster` referencing a plugin that has not registered comes up **Healthy and never archives**.
  This is why Argo sync waves order operator → plugin → database.
- `ScheduledBackup.spec.method` defaults to `barmanObjectStore`, the deprecated in-tree path this
  platform does not configure. Omitting `method: plugin` gives a schedule that looks correct and
  fails every night.

Neither turns anything red.

## Restoring

**A backup that has never been restored is a hypothesis.** Restoring is also the only way to
answer "is the archive good", so do it deliberately rather than during an incident.

Recovery creates a **new** Cluster; it does not overwrite an existing one.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-restore
  namespace: database
spec:
  instances: 1
  storage:
    size: 10Gi
    storageClass: hcloud-volumes
  bootstrap:
    recovery:
      source: postgres-archive
  externalClusters:
    - name: postgres-archive
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: pg-backups
          # The directory in the bucket, which is the ORIGINAL cluster's name --
          # not the name of the cluster being created here.
          serverName: postgres
```

Note what is deliberately absent: no `plugins:` block. The restored cluster does **not** archive.
Two clusters writing the same `serverName` would interleave WAL from different timelines into one
path, which corrupts the archive for both.

Restoring to a point in time rather than to the end of the archive:

```yaml
  bootstrap:
    recovery:
      source: postgres-archive
      recoveryTarget:
        targetTime: "2026-08-19 18:55:00+00"
```

Verify by looking for data, not by looking at status:

```bash
kubectl -n database exec -it postgres-restore-1 -c postgres -- psql -U postgres -d app -c '\dt'
```

Then delete it, **including the PVC** — see the orphaned-volume warning below.

```bash
kubectl -n database delete cluster postgres-restore
kubectl -n database delete pvc -l cnpg.io/cluster=postgres-restore
```

### Verified on 2026-08-19

A row written at 19:00:37 — thirteen minutes after the only base backup completed at 18:47:05 — was
present in a cluster restored from the archive. It could only have arrived by WAL replay, which is
what makes this evidence rather than a green checkmark.

## Failover

```bash
kubectl -n database get cluster postgres -o jsonpath='{.status.currentPrimary}'
kubectl -n database delete pod <the primary>
```

Promotion took **10 seconds** when tested, and a row written before the delete was readable from the
new primary afterwards.

Anti-affinity is `required`, so the two instances are on different workers. A replica sharing a node
with its primary protects against a process crash but not against losing the machine, which is the
failure that actually happens.

Manual switchover, which is the polite version:

```bash
kubectl cnpg promote postgres postgres-2 -n database
```

## After a cluster rebuild

**The database does not come back with data.** The manifest bootstraps with `initdb`, so a rebuilt
cluster gets an **empty** database and the previous archive is untouched but unused.

That is deliberate — `bootstrap` only applies at creation, and a manifest that always recovered
could not create a database the first time. But it means restoring after a rebuild is a **conscious
act**: apply a recovery Cluster as above.

### Rebuilds restore the database; they do not start it empty

`bootstrap` runs only when a Cluster is **created**, so it is what happens on every rebuild. This
platform bootstraps by **recovering from the archive**, which is what makes ADR-0002's promise real:
the cluster is disposable because the data is not.

Two settings make that work, and they are a **matched pair**:

```yaml
metadata:
  annotations:
    cnpg.io/skipEmptyWalArchiveCheck: "enabled"
spec:
  bootstrap:
    recovery:
      source: archive
```

barman refuses by default to archive into a path that already holds history — a check that exists to
stop two *different* databases interleaving timelines into one archive and destroying recovery for
both. That default is right, and **recovery alone does not exempt you from it**: a recovered cluster
runs the same check and fails with

```
WAL archive check failed for server postgres-g3: Expected empty archive
```

The annotation disables it, and is safe *only* in this combination: the cluster restores from the
exact path it archives to, so it is one lineage continuing on a new timeline — which is precisely
what barman's timeline handling is for.

> **Never set the annotation while bootstrapping with `initdb`.** A brand-new empty database would
> begin writing into the previous one's archive and silently destroy its recoverability. Change one,
> change the other.

Because the lineage continues, `serverName` never changes and there is no generation to bump. That
matters: the previous design required a human to increment it on every rebuild, and it failed both
times it was needed — once for five hours, across the creation of an entire database, while the
cluster reported `Healthy`.

Verified on 2026-08-20 by deleting the Cluster and its PVCs outright:

```
core migrations   2          restored
keycloak tables   100        restored
example_item      dr-test-marker, written 15:14 -- AFTER the 14:22 base backup,
                             so it could only arrive by WAL replay
ContinuousArchiving  True    same path, no bump
```

### First install in a new environment

There is nothing to recover from, so the recovery bootstrap **fails, loudly**. That is the intended
default for a system that holds data: creating an empty database is the exceptional act, not the
routine one.

To bootstrap a genuinely new environment, temporarily swap the `bootstrap` block for:

```yaml
  bootstrap:
    initdb:
      database: app
      owner: app
```

**and remove the `skipEmptyWalArchiveCheck` annotation** while doing so. Take a base backup, confirm
it lands in the bucket, then restore both settings in the same commit.

## Connecting

CloudNativePG creates the services and credentials:

```bash
kubectl -n database get svc                      # postgres-rw, postgres-ro, postgres-r
kubectl -n database get secret postgres-app -o jsonpath='{.data.password}' | base64 -d
```

Use **`postgres-rw`** for writes: it follows the primary across a failover. Pointing an application
at a pod name survives exactly until the first promotion.

## Known gaps

**No separate WAL volume in dev.** Hetzner volumes have a 10 Gi minimum, so a separate `walStorage`
would double volume count for a database with no traffic. It belongs in staging and prod, where a
WAL burst filling the data volume and stalling writes is a real failure.

**Deleting a Cluster deletes its PVCs, and orphans the underlying Hetzner volumes** if the cluster
is torn down by Terraform first. See #109 — `make verify-teardown` catches it; nothing else does.

**No monitoring yet.** `enablePodMonitor` is off until T-2.6 provides the ServiceMonitor CRD. Until
then, backup failures are discovered by looking, which is the weakest part of this setup.

**Retention is 30 days and lives on the ObjectStore**, not in a bucket lifecycle rule. Expiring a
WAL segment that a base backup still depends on silently destroys recoverability for everything
after it; barman understands that dependency, a lifecycle rule does not.
