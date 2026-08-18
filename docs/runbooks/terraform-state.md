# Runbook: Terraform state

Terraform state is in the durable column of [ADR-0002](../adr/0002-ephemeral-cluster-and-durable-state.md).
Clusters are destroyed routinely; state is what makes the next `terraform apply` a rebuild rather
than an orphaning of everything the previous one created.

Losing state does not lose the infrastructure. It loses the *record* of it — leaving billable
servers, volumes and load balancers running with nothing tracking them, and no `terraform destroy`
able to clean them up.

## The chicken-and-egg problem

Terraform cannot create the bucket that holds its own state. Two bad answers and the one used here:

| Approach | Why not |
|---|---|
| A second Terraform config with local state | The local state file becomes durable state on one laptop — precisely what ADR-0002 forbids. Lose the laptop, lose the ability to manage the bucket. |
| Create the bucket by hand in the console | Violates the no-manual-configuration rule, and nothing records how it was configured. Versioning gets forgotten, and nobody notices until a bad write. |
| **An idempotent script, version-controlled** | The script *is* the record. Re-runnable, reviewable, and it verifies versioning rather than assuming it. |

`infra/scripts/bootstrap-state-bucket.sh` is that script. It is the only step in the whole system
that runs before Terraform, and it is deliberately tiny.

## Prerequisites

| Tool | Needed for | Notes |
|---|---|---|
| Terraform ≥ 1.10 | Everything | `use_lockfile` landed in 1.10. Verified against 1.14.8 |
| aws CLI | Bucket bootstrap | Speaks S3 to any compatible endpoint; no AWS account involved |
| GNU make | The `make` targets | On Windows: `scoop install main/make`, and run the targets from Git Bash |
| bash | Both scripts | Git Bash on Windows |

The scripts are plain bash and can be run directly if you would rather not install make:

```bash
bash infra/scripts/bootstrap-state-bucket.sh xenopsbase-tfstate fsn1
bash infra/scripts/verify-state-locking.sh infra/terraform/storage/backend.hcl
```

## First-time setup

```bash
export AWS_ACCESS_KEY_ID=...       # Hetzner Console -> Object Storage -> Credentials
export AWS_SECRET_ACCESS_KEY=...
```

```bash
make bootstrap-state BUCKET=xenopsbase-tfstate REGION=fsn1
```

```bash
cp infra/terraform/storage/backend.hcl.example infra/terraform/storage/backend.hcl
```

Edit `backend.hcl`, then:

```bash
make init
```

```bash
make verify-locking
```

**Do not skip the last step.** Reasoning below.

## ⚠️ Locking does not work on Hetzner

**Verified 2026-08-19. State locking currently provides no protection.**

Hetzner Object Storage silently ignores the `If-None-Match` header, so the conditional `PutObject`
that implements `use_lockfile` degrades to an ordinary overwrite. Confirmed at two levels:

```
verify-state-locking.sh
  holder:    apply holding the lock for 45s
  contender: plan against the same state -> exit code 0   (expected: refused)
```

```
aws s3api put-object --if-none-match "*" --key <same key>   # twice
  PUT #1 -> 200 OK
  PUT #2 -> 200 OK, overwrote  (real S3 returns 412 PreconditionFailed)
```

The second test isolates the primitive: this is not a Terraform bug or a misconfiguration, it is
Hetzner not implementing conditional writes.

**Until this is resolved, run applies from exactly one place at a time.** Two concurrent applies
will both believe they hold the lock, both write state, and neither will report anything wrong.
The corruption is discovered later, by something else failing.

Note the nightly rebuild drill (T-7.3) is an automated second writer, so this is a live risk in the
intended design rather than a theoretical one.

Tracked in the decision issue for choosing a fix. Options are a state backend that honours
conditional writes, or serializing every apply through a single CI job.

## Why locking had to be proven, not assumed

Terraform's S3-native locking writes a `.tflock` object using a conditional `PutObject` carrying
`If-None-Match`. A second writer should receive HTTP 412 and refuse to proceed.

Hetzner's [supported-actions documentation](https://docs.hetzner.com/storage/object-storage/supported-actions/)
does not state whether conditional requests are honoured. Versioning and object lock are
documented; conditional writes are not mentioned in either direction.

If they are not honoured, the conditional PUT silently degrades to an ordinary PUT. Both applies
"acquire" the lock. Both write state. Neither reports an error.

**Locking fails open.** There is no error message to notice and no partial failure to investigate —
just two runs that each believe they hold exclusive access. That is why it is verified explicitly
rather than trusted, and re-verified after any Terraform upgrade or endpoint change.

`make verify-locking` holds a real lock with a slow apply and asserts a concurrent operation is
refused, against a throwaway state key that never touches real state.

### If verification fails

Do not run applies from more than one place. Then pick one:

- **Serialize applies through a single CI job** with concurrency limited to one. Removes the race
  without changing storage, at the cost of no longer being able to apply from a laptop.
- **Move state to a provider with proven conditional-write support.** Costs a little money and some
  of the single-provider simplicity.

Either way it needs an ADR, because it changes the durable-state story.

## Backend flags, and why each is present

| Flag | Reason |
|---|---|
| `skip_credentials_validation` | STS does not exist outside AWS |
| `skip_requesting_account_id` | No AWS account to resolve |
| `skip_metadata_api_check` | No EC2 instance metadata endpoint |
| `skip_region_validation` | `fsn1` is not an AWS region name |
| `skip_s3_checksum` | Hetzner does not implement the extra checksum headers Terraform sends by default. Applies to the lock object as well as the state object |
| `use_path_style` | Path-style addressing, which avoids bucket-name-in-hostname problems |
| `use_lockfile` | S3-native locking, no DynamoDB. Unproven until verified — see above |

## Recovery

### State is corrupted or truncated

Versioning is enabled on the bucket, which is what makes this recoverable at all.

```bash
aws --endpoint-url https://fsn1.your-objectstorage.com --region fsn1 \
  s3api list-object-versions --bucket xenopsbase-tfstate --prefix dev/terraform.tfstate
```

Identify the last good `VersionId` by `LastModified`, then:

```bash
aws --endpoint-url https://fsn1.your-objectstorage.com --region fsn1 \
  s3api get-object --bucket xenopsbase-tfstate \
  --key dev/terraform.tfstate --version-id <VersionId> recovered.tfstate
```

Inspect `recovered.tfstate` before pushing it. Then `terraform state push recovered.tfstate`,
and immediately `terraform plan` — an empty diff means the recovery was clean.

### A lock is stuck after a crashed run

A run killed mid-apply leaves the `.tflock` object behind. Terraform prints the lock ID:

```bash
terraform force-unlock <LOCK_ID>
```

Confirm no apply is genuinely still running first. Force-unlocking a live apply produces exactly
the concurrent-write corruption the lock exists to prevent.

### State is lost entirely

Infrastructure keeps running; Terraform simply no longer knows about it. Either `terraform import`
each resource, or destroy everything through the Hetzner console and rebuild. In the ephemeral
model the second option is usually faster and is already exercised — but check for orphaned volumes
and load balancers afterwards, since those bill independently of the servers.

## Conventions

- **One state key per environment.** `dev/terraform.tfstate`, `staging/…`, `prod/…`. The lock is
  per state object, so a shared key means a dev apply blocks a prod apply.
- **Storage and cluster are separate root modules with separate state.** `storage/terraform.tfstate`
  is not per-environment: there is one set of durable buckets, outliving every cluster. The split
  exists so that `make down` — which destroys the cluster routinely — cannot reach the buckets. See
  [object storage](object-storage.md).
- **Credentials only from the environment.** Never in `backend.hcl`, which is gitignored anyway,
  and never in a `.tf` file. This repository is public.
- **`.terraform.lock.hcl` is committed.** Provider versions must be identical across a rebuild.
