# ADR-0007: Postgres backs up through the Barman Cloud plugin, not the in-tree path

- **Status:** Accepted
- **Date:** 2026-08-19
- **Task:** T-2.4

## Context

CloudNativePG can archive base backups and WAL to object storage two ways, and both are supported
today:

1. **In-tree** — `spec.backup.barmanObjectStore` inside the `Cluster`. One block, no extra
   components, years of production use behind it.
2. **The Barman Cloud plugin** — a CNPG-I extension: a separate Deployment, its own CRD
   (`ObjectStore`), and a sidecar injected into every instance pod.

The forces that make this a real decision rather than an obvious one:

**The in-tree path is deprecated but not dying.** CloudNativePG deprecated it in 1.26 and is moving
to a backup-agnostic architecture where the interface standardises WAL archiving, base backups and
recovery. As of 1.30 the field is fully present and works. No removal version has been announced.

**The plugin is the future but is not finished.** It has been developed since September 2024 and is
still at **v0.14.0** — pre-1.0 after roughly two years. Pre-1.0 is an explicit statement that the
API may still break.

**This is a stemcell.** Every project forked from it inherits whatever is chosen here, and inherits
the migration if that choice expires. That raises the weight of "which way is this moving" relative
to "which is more comfortable today".

**Backups are the least forgiving component in the stack.** [ADR-0002](0002-ephemeral-cluster-and-durable-state.md)
makes the cluster disposable specifically because the durable copy lives in object storage. If
archiving is silently broken, the entire premise of that decision is false, and nothing else in the
system reports it.

## Decision criteria

Written before the options were compared:

1. **Where does the migration cost land?** Both options cost a migration eventually. The question is
   whether it arrives on our schedule or someone else's.
2. **How does it fail?** Loudly is acceptable, silently is not.
3. **Does it get fixes and features?** A path receiving neither is a liability regardless of how
   stable it looks.
4. **How much machinery does it add** to a template meant to be understood by whoever forks it?
5. **Is it reversible**, and at what cost?

## Decision

Postgres archives through the **Barman Cloud plugin**. The in-tree `barmanObjectStore` field is not
used anywhere in this repository.

Concretely: an `ObjectStore` resource names the bucket and credentials, and the `Cluster` references
it through `spec.plugins` with `isWALArchiver: true`.

The deciding argument is criterion 1. Choosing in-tree does not avoid the migration, it defers it to
whenever CloudNativePG removes the field — at which point the upgrade is forced, urgent, and
touching backups. Choosing the plugin pays in smaller increments, at times of our choosing, on a
component whose breakages appear at upgrade time rather than at recovery time.

Criterion 3 reinforces it: the in-tree path is explicitly receiving no new features. It is not
merely older, it is frozen.

## Consequences

### What this makes easy

- Tracking upstream. This is the path that gets fixes, and the recovery documentation is written
  against it.
- Swapping the backup implementation later without rewriting the `Cluster`. That is the entire point
  of a backup-agnostic interface, and the next backend arrives as a different plugin rather than a
  different database manifest.
- Reusing one `ObjectStore` definition across clusters, and keeping bucket and credentials out of the
  `Cluster` manifest entirely.

### What this makes hard

- **More moving parts.** A plugin Deployment, a CRD, a cert-manager dependency for the plugin's gRPC
  certificates, and a sidecar in every instance pod. A reader of this repository has more to hold in
  their head than one `backup:` block would require.
- **Ordering now matters and fails quietly.** A `Cluster` that names a plugin which has not
  registered comes up `Healthy` and never archives. This is handled with explicit Argo sync waves
  (operator → plugin → database) precisely because the failure does not announce itself.
- **Pre-1.0 churn.** Breaking changes are expected and must be read before upgrading. The plugin
  version is pinned for this reason.
- **`method` defaults the wrong way for us.** `ScheduledBackup.spec.method` defaults to
  `barmanObjectStore`. Omitting it produces a schedule that looks correct and fails every night, so
  every `ScheduledBackup` in this repository must set `method: plugin` explicitly.

### What it commits us to

Running one more controller, and reading plugin release notes at upgrade time rather than assuming
a patch release is safe.

Reversal is cheap in mechanism and expensive in confidence: moving back to in-tree is a manifest
change, since the on-disk layout in the bucket is barman's either way and the same archive is
readable by both. What it would cost is re-proving recovery, which is the only evidence that
matters.

## Alternatives considered

### In-tree `barmanObjectStore` — rejected

Simpler, proven, and fine today. Rejected because it is frozen and its removal is a matter of when.
Building a template on it hands every fork a forced migration on someone else's timetable, on the
one component where a botched migration is discovered during a recovery.

### Volume snapshots — rejected

CloudNativePG supports backups via CSI volume snapshots, and Hetzner's CSI driver can provide them.
Rejected on ADR-0002 grounds: it ties the durable copy to the provider's volume service rather than
to the bucket, and it does not give point-in-time recovery, which T-7.4 requires. Worth revisiting
as a *complement* — snapshots are much faster to restore for large databases — but not as the
archive of record.

### Both, with in-tree as a fallback — rejected

`isWALArchiver` cannot be combined with `spec.backup.barmanObjectStore`; the API refuses it. Even if
it did not, two archivers writing the same bucket is a correctness problem, not redundancy.

## Revisit if

- The plugin reaches 1.0. Some of the caution here is priced on it being pre-1.0, and that should be
  re-read rather than assumed permanent.
- A plugin upgrade breaks archiving in a way that is not caught before it reaches production. That
  would mean the "smaller increments" argument is not holding in practice.
- CloudNativePG announces a removal version for the in-tree path, which converts this from a
  judgement call into a settled fact and is worth recording.
- Restore time becomes the binding constraint rather than durability, which is when volume snapshots
  stop being a complement and start being the primary path.
