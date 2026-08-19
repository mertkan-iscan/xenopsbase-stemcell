# ADR-0005: Terraform state lives in Cloudflare R2, not Hetzner

- **Status:** Accepted
- **Date:** 2026-08-19
- **Task:** T-1.1

## Context

[ADR-0002](0002-ephemeral-cluster-and-durable-state.md) puts Terraform state in the durable column.
Losing state does not lose the infrastructure; it loses the *record* of it, leaving billable
servers and volumes running with nothing tracking them and no `terraform destroy` able to reach
them.

T-1.1 placed state in Hetzner Object Storage, alongside every other durable artefact, and relied on
Terraform's S3-native locking (`use_lockfile`). That locking works by writing a `.tflock` object
with a conditional `PutObject` carrying `If-None-Match`; a second writer should receive HTTP 412.

**Verification on 2026-08-19 showed Hetzner does not implement conditional writes.** Confirmed at
two levels against a real bucket:

| Test | Expected | Actual |
|---|---|---|
| `plan` while an `apply` held the lock | refused | exit 0, lock acquired |
| `put-object --if-none-match "*"` twice, same key | 2nd → `412` | 2nd → `200`, overwrote |

The second test isolates the S3 primitive, so this is not a Terraform defect or a local
misconfiguration.

The failure mode is the dangerous kind. Locking **fails open**: two concurrent applies both believe
they hold the lock, both write, and neither reports anything. Corruption is discovered later,
through something unrelated breaking.

It is also a live risk rather than a theoretical one. T-7.3 adds a nightly rebuild drill — an
automated second writer that will eventually run while someone is applying by hand.

## Decision criteria

- **Does it actually prevent concurrent writes?** Verified, not documented.
- **Does the rebuild path stay self-contained?** ADR-0003 rejected a SaaS dependency for secrets on
  the grounds that their outage becomes our inability to recover. The same logic applies here.
- **Cost at this volume**, which is a few hundred kilobytes and a handful of operations per day.
- **Does the local `make up` / `make down` loop survive?** T-1.7 depends on it.

## Decision

**Terraform state moves to Cloudflare R2.** Everything else — documents, database backups, Loki
chunks — stays in Hetzner Object Storage.

Only the state bucket moves. This is not a migration away from Hetzner; it is the narrowest
possible change that makes locking real.

R2 documents `If-None-Match` on `PutObject` as supported, and that claim was **verified rather
than trusted**, using the same script that caught the Hetzner problem:

| Test | Hetzner | R2 |
|---|---|---|
| `plan` while an `apply` holds the lock | exit 0, lock acquired | **refused** |
| `put-object --if-none-match "*"` twice | 2nd → `200`, overwrote | **2nd → `PreconditionFailed`** |
| Content after the second PUT | overwritten | **preserved** |

Verified 2026-08-19 against the real bucket. Re-run `verify-state-locking.sh` after any Terraform
upgrade or backend change; documented support is evidence, not proof.

### Consequence: two sets of S3 credentials

The storage module now talks to two different S3 services at once: the *backend* writes state to
R2, while the `aws` *provider* manages buckets on Hetzner. Both would read `AWS_ACCESS_KEY_ID` by
default, so they are separated explicitly:

| Credential | Env var | Used by |
|---|---|---|
| R2 | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Terraform S3 backend (state) |
| Hetzner | `TF_VAR_hetzner_s3_access_key` / `..._secret_key` | `aws` provider (buckets) |

The backend has no way to read a `TF_VAR_`, so the standard AWS names belong to R2 and Hetzner
takes the explicit ones.

## Consequences

### What this makes easy

- Locking works, so concurrent applies are genuinely refused. The nightly drill and a local apply
  can no longer silently corrupt each other.
- The local loop survives. `make up` and `make down` stay ordinary local commands, which
  serializing every apply through CI would have removed.
- Free at this volume, on both sides.

### What this makes hard — and the real cost

**R2 does not support bucket versioning.** `PutBucketVersioning` and `GetBucketVersioning` are
listed as unimplemented. Hetzner *did* support it, so this decision trades one protection for
another rather than simply adding one:

| | Hetzner | R2 |
|---|---|---|
| State locking | ✗ | ✓ |
| Bucket versioning | ✓ | ✗ |

They defend against different failures. Locking **prevents** the most likely cause of corruption,
concurrent writes. Versioning **recovers** from a bad write of any cause, including ones locking
cannot stop: a botched `terraform state rm`, a bad import, a truncated upload.

Prevention was chosen over recovery because the prevented failure is the one this design actually
provokes — an automated nightly writer alongside a human one. But the recovery gap is real, and
the state-recovery procedure in the runbook no longer works as written.

**Compensating control:** state is copied on a schedule into the Hetzner `tfstate` bucket, which
keeps versioning. That restores a version history without giving up locking. Tracked separately;
until it exists, a bad state write is unrecoverable.

Also: a second vendor now sits on the rebuild path. ADR-0003 rejected exactly this for secrets.
The distinction is that ADR-0003 was choosing between options that *both* worked, where the SaaS
merely added a dependency; here the self-contained option does not work at all. A dependency that
functions beats an absence of one that does not.

### What it commits us to

Two providers, two credential sets, and a first-run step on Cloudflare. The blast radius is small —
if R2 ever becomes a problem, moving state elsewhere is a `terraform init -migrate-state`, not a
redesign, because nothing but state lives there.

## Alternatives considered

### Serialize every apply through a single CI job — rejected

Keeps everything on Hetzner and needs no lock, because there is only ever one writer. Free, no new
vendor, and genuinely robust.

Rejected because it removes local applies entirely, and T-1.7 makes `make up` / `make down` the
everyday loop. Turning a 30-second local command into a push-and-wait CI round trip taxes the
action this project is built around performing constantly. Worth revisiting if the team ever grows
past one person, where centralized applies are the right answer anyway.

### Accept the risk, serialize by convention — rejected

Costs nothing and changes nothing. Rejected because the only safeguard is remembering, the failure
is silent, and the project deliberately introduces an automated second writer in T-7.3. This is the
option that looks cheapest until the day it is not.

### HCP Terraform free tier — rejected

Purpose-built, real locking, free at this scale, and it would remove the problem rather than route
around it. Rejected as a larger dependency than R2 for the same benefit: it owns the whole state
workflow rather than storing a file, which is harder to leave. R2 keeps state as a plain object in
a bucket we control.

## Revisit if

- `verify-state-locking.sh` fails against R2 too, which would mean the documented support is not
  real and this ADR is void before it is useful.
- Hetzner implements conditional writes, at which point state should come home and remove a vendor.
- The team grows past one person, where centralized applies through CI become correct for reasons
  beyond locking.
- The scheduled state backup proves unreliable, making the versioning gap a live problem rather
  than a covered one.
