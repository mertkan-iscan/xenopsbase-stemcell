# Runbook: Terraform state

Terraform state is in the durable column of [ADR-0002](../adr/0002-ephemeral-cluster-and-durable-state.md).
Clusters are destroyed routinely; state is what makes the next `terraform apply` a rebuild rather
than an orphaning of everything the previous one created.

Losing state does not lose the infrastructure. It loses the *record* of it — leaving billable
servers, volumes and load balancers running with nothing tracking them, and no `terraform destroy`
able to clean them up.

**State lives in Cloudflare R2. Everything else lives in Hetzner.** See
[ADR-0005](../adr/0005-terraform-state-backend.md) for why, and what it cost.

## Two S3 services, two credential sets

This is the part that catches people. The storage module talks to both at once:

| | Endpoint | Credentials | Holds |
|---|---|---|---|
| **R2** | `https://<account_id>.r2.cloudflarestorage.com` | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Terraform state |
| **Hetzner** | `https://fsn1.your-objectstorage.com` | `TF_VAR_hetzner_s3_access_key` / `..._secret_key` | documents, backups, Loki chunks |

The Terraform S3 backend can only read the standard `AWS_*` names — it has no way to read a
`TF_VAR_` — so those belong to R2, and Hetzner takes the explicit ones. Swapping them produces an
`InvalidAccessKeyId` that looks like a wrong key rather than a wrong *service*.

## Why state is not in Hetzner

Terraform's S3-native locking writes a `.tflock` object with a conditional `PutObject` carrying
`If-None-Match`. A second writer should receive HTTP 412.

**Hetzner does not implement conditional writes.** Verified 2026-08-19:

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

The second test isolates the primitive — not a Terraform bug, not a misconfiguration.

Locking there **failed open**: two concurrent applies would both believe they held the lock, both
write, and neither report anything. That is a live risk in this design, because T-7.3's nightly
rebuild drill is an automated second writer.

### What the move cost

R2 does not support bucket versioning. The trade is explicit:

| | Hetzner | R2 |
|---|---|---|
| State locking | ✗ | ✓ |
| Bucket versioning | ✓ | ✗ |

Locking **prevents** the most likely corruption; versioning **recovers** from any bad write.
Prevention won because the prevented failure is the one this design provokes. The gap is real, and
the compensating control — a scheduled copy of state into the versioned Hetzner bucket — is tracked
separately. **Until it exists, a bad state write is not recoverable.**

## Prerequisites

| Tool | Needed for | Notes |
|---|---|---|
| Terraform ≥ 1.10 | Everything | `use_lockfile` landed in 1.10. Verified against 1.14.8 |
| aws CLI | Bucket bootstrap | Speaks S3 to any compatible endpoint |
| GNU make | The `make` targets | On Windows: `scoop install main/make`, run from Git Bash |
| bash | Both scripts | Git Bash on Windows |

## Cloudflare setup, once

1. A Cloudflare account, then **R2** in the dashboard. Enabling R2 may require a payment method
   even on the free tier; usage at this volume stays inside it.
2. Note your **account ID**, shown in the R2 section. It forms the endpoint hostname.
3. **R2** → **API** → **Manage API tokens** → create a token with **Object Read & Write**. It
   yields an access key ID and a secret access key. The secret is shown once.

## First-time setup

```bash
export AWS_ACCESS_KEY_ID=<r2 access key>  AWS_SECRET_ACCESS_KEY=<r2 secret>
```

```bash
bash infra/scripts/bootstrap-state-bucket.sh xenopsbase-tfstate https://<account_id>.r2.cloudflarestorage.com auto
```

It will report that versioning is unavailable. That is expected on R2 and is not fatal — see above.

```bash
cp infra/terraform/storage/backend.hcl.example infra/terraform/storage/backend.hcl
```

Set the endpoint in it, then:

```bash
cd infra/terraform/storage && terraform init -backend-config=backend.hcl
```

```bash
bash infra/scripts/verify-state-locking.sh infra/terraform/storage/backend.hcl
```

**Do not skip that last step**, and do not trust Cloudflare's documentation in place of it. Hetzner
documented nothing and turned out not to work; R2 documents support, which is evidence but not
proof. The script is the proof.

Verified on R2, 2026-08-19:

```
verify-state-locking.sh
  contender exit code: 1
  PASS - the second operation was refused while the lock was held.

aws s3api put-object --if-none-match "*"   # twice, same key
  PUT #1 -> 200 OK
  PUT #2 -> PreconditionFailed, original content preserved
```

## Backend flags, and why each is present

| Flag | Reason |
|---|---|
| `skip_credentials_validation` | STS does not exist outside AWS |
| `skip_requesting_account_id` | No AWS account to resolve |
| `skip_metadata_api_check` | No EC2 instance metadata endpoint |
| `skip_region_validation` | R2 uses the literal `auto`, not an AWS region |
| `skip_s3_checksum` | Extra checksum headers Terraform sends by default are not implemented |
| `use_path_style` | Path-style addressing, avoiding bucket-name-in-hostname problems |
| `use_lockfile` | S3-native locking. Works on R2; did nothing on Hetzner |

## Recovery

### State is corrupted or truncated

There is a rollback (T-1.9, #71). R2 still has no version history; the **Hetzner `tfstate` bucket
does**, and the `State backup` workflow copies every state object into it daily. Locking stops two
writers corrupting each other, and this is the other half — the one bad write from a single writer.

**1. Find the version you want.** Versions are listed newest first; the one you want is almost
always the one *before* the write that broke it.

```bash
export AWS_ACCESS_KEY_ID="$HETZNER_S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$HETZNER_S3_SECRET_KEY"
aws --endpoint-url https://fsn1.your-objectstorage.com --region fsn1 \
  s3api list-object-versions --bucket xenopsbase-tfstate --prefix dev/cluster.tfstate \
  --query 'Versions[].{v:VersionId,when:LastModified,size:Size}' --output table
```

**2. Pull it down and read what it is.** `serial` goes up with every write and `lineage` identifies
the state's whole history — a restore whose lineage does not match what the backend holds is a
different state file, and pushing it is a much worse day than the one you are having.

```bash
aws --endpoint-url https://fsn1.your-objectstorage.com --region fsn1 \
  s3api get-object --bucket xenopsbase-tfstate --key dev/cluster.tfstate \
  --version-id <VERSION_ID> restored.tfstate

python3 -c "import json;s=json.load(open('restored.tfstate'));print(s['serial'],s['lineage'],len(s['resources']))"
```

**3. Check it against reality before pushing it.** A restored state describes the infrastructure as
it was at that moment, not as it is now.

```bash
terraform plan -state=restored.tfstate   # read only; expect a diff, read every line of it
```

**4. Push it.** `terraform state push` refuses a lower serial unless forced, which is the guard
working — bump it deliberately rather than reaching for `-force` reflexively.

```bash
terraform state push restored.tfstate
```

If the backup itself is missing or stale, `infra/scripts/backup-state.sh` says so loudly rather than
reporting success; run it by hand (or dispatch the workflow) and read what it prints. Failing that,
the pre-#71 recovery still applies: reconstruct with `terraform import` per resource, or destroy
through the provider consoles and rebuild — checking for orphaned volumes and load balancers
afterwards, since those bill independently.

### Checking the backup without a disaster

```bash
make state-backup-verify
```

Reads the newest version of every object out of the Hetzner bucket, compares it byte-for-byte with
what R2 currently holds, and reports how old the newest copy is. It writes nothing, to either
bucket, so it is safe to run at any time — including while an apply is in flight. It is every step
of the procedure above except the final push, which is the point: a restore path nobody has walked
is a hypothesis.

Exercised on 2026-08-29 against the live buckets; see #71 for the run.

### A lock is stuck after a crashed run

A run killed mid-apply leaves the `.tflock` object behind. Terraform prints the lock ID:

```bash
terraform force-unlock <LOCK_ID>
```

Confirm no apply is genuinely still running first. Force-unlocking a live apply produces exactly
the concurrent-write corruption the lock exists to prevent — and now that locking actually works,
this is the main way to defeat it.

### State is lost entirely

Infrastructure keeps running; Terraform no longer knows about it. Either `terraform import` each
resource, or destroy everything through the console and rebuild. In the ephemeral model the second
is usually faster and already exercised — but check for orphaned volumes and load balancers, which
bill independently of servers.

## Conventions

- **One state key per environment.** `dev/cluster.tfstate`, `staging/…`, `prod/…`. The lock is per
  state object, so a shared key means a dev apply blocks a prod apply.
- **Storage and cluster are separate root modules with separate state.**
  `storage/terraform.tfstate` is not per-environment: there is one set of durable buckets,
  outliving every cluster. The split exists so that `make down` — which destroys the cluster
  routinely — cannot reach the buckets. See [object storage](object-storage.md).
- **Credentials only from the environment.** Never in `backend.hcl` or a `.tf` file. This
  repository is public.
- **`.terraform.lock.hcl` is committed**, generated for linux, darwin and windows. A
  single-platform lock fails CI on Linux.
