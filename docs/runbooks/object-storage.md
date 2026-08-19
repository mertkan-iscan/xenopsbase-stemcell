# Runbook: object storage

Four buckets hold the entire left-hand column of
[ADR-0002](../adr/0002-ephemeral-cluster-and-durable-state.md). Clusters are disposable; these are
not. Everything that would hurt to lose is in here.

| Bucket | Holds | Versioned | Lifecycle backstop |
|---|---|---|---|
| `<prefix>-documents` | Uploaded documents | Yes | Old versions expire after 90d. Current versions never expire |
| `<prefix>-pg-backups` | CloudNativePG base backups and WAL | No | Objects expire after 35d — this is the PITR ceiling |
| `<prefix>-loki-chunks` | Loki log chunks | No | Objects expire after 30d |
| `<prefix>-tfstate` | Reserved for state backups (ADR-0005) | Yes | Old versions expire after 365d |

## Why storage is a separate root module

`make down` runs `terraform destroy` as an everyday operation — that is the whole point of the
ephemeral model. If these buckets lived in the same state as the cluster, **the routine teardown
would delete the durable side of the boundary.** Every document, every backup, gone, as a normal
Tuesday.

So `infra/terraform/storage/` is its own root module with its own state key
(`storage/terraform.tfstate`), and `make down` is wired to `infra/terraform/cluster/` only. Every
bucket additionally carries `prevent_destroy`, and there is deliberately no `storage-destroy`
target. Deleting these should require editing Terraform by hand and meaning it.

## Lifecycle rules are not managed by Terraform

`aws_s3_bucket_lifecycle_configuration` cannot be used against Hetzner. The PUT works; the
provider's post-write stabilization is what fails.

After writing, the provider polls `GetBucketLifecycleConfiguration` until the response matches what
it sent. Both HCL forms — `filter {}` and the deprecated `prefix = ""` — normalize internally to a
V2 `Filter`. Hetzner always returns the V1 form instead:

```xml
<Rule><ID>..</ID><Prefix></Prefix><Status>Enabled</Status>..</Rule>
```

No `Filter` element, ever. So the comparison never converges: every lifecycle resource burns its
full 3-minute timeout and then fails — **having applied the rules correctly**. Verified 2026-08-19
against aws provider v6.60.0: 21 polls, a correct response every time, never accepted.

The rules therefore live in `infra/lifecycle/*.json` and are applied by
`infra/scripts/apply-lifecycle-rules.sh`, which reads them back to confirm they stuck:

```bash
make storage-lifecycle
```

This is still code under review, not manual configuration. ADR-0002 forbids state created **by
hand**, and nothing here is. Revisit if Hetzner starts returning `Filter`, or the provider gains a
way to skip stabilization.

## Retention is layered, and the order matters

Lifecycle rules here are **backstops**, not the primary policy. Each component enforces its own,
shorter retention:

```
component retention  <  bucket lifecycle
CloudNativePG 30d     <  pg-backups 35d
Loki          21d     <  loki-chunks 30d
```

Get this backwards and the failure is quiet and delayed. Lifecycle deletes a WAL segment that
CloudNativePG still lists as part of a recoverable timeline; nothing errors at the time, and the
gap only surfaces during a restore — which is the worst possible moment to discover it. The same
applies to Loki: a query for a chunk the index still references fails outright rather than
returning fewer rows.

When changing either number, change the component first and the bucket second.

## Credentials and least privilege

Hetzner S3 keys are **project-wide by default**. Every key pair can read and write every bucket in
the project, including buckets created later. Without a bucket policy, a leaked Loki key can read
every uploaded document and delete every database backup.

Bucket policies are the only mechanism Hetzner offers to narrow this. `policies.tf` uses the
same-project pattern from [Hetzner's documentation](https://docs.hetzner.com/storage/object-storage/faq/s3-credentials/):
deny everything, with `NotPrincipal` listing the keys that keep access.

Four key pairs, generated in **Cloud Console → Object Storage → Credentials**:

| Key | Access |
|---|---|
| `infra` | Every bucket. Used by Terraform and CI |
| `app` | `documents` only |
| `db` | `pg-backups` only |
| `observability` | `loki-chunks` only |

Hetzner has no API for creating these, so generating them is a manual bootstrap step — the same
category as the age key in [ADR-0003](../adr/0003-secrets-management.md). What *is* automated is
the authorization: which key may touch which bucket is code.

### The lockout hazard

> `NotPrincipal` denies every principal **not** in the list. If that list is wrong — a typo'd key
> ID, a rotated key, a wrong project ID — then nobody can access the bucket, **including the key
> needed to remove the policy.** There is no self-service recovery. It is a support ticket.

Two guards:

1. The `infra` key is appended to every allowlist unconditionally, enforced by a Terraform
   `precondition`. Terraform always retains the ability to remove a policy it applied.
2. `enable_bucket_policies` defaults to `false`.

So the first apply creates buckets with no policy. Confirm the key IDs are exactly right, then set
`enable_bucket_policies = true` and apply again. One extra apply, versus a support ticket.

### Prove the ARN format on a canary first

Checking the key IDs is not quite enough. The genuinely unrecoverable mistake is a wrong
`project_id`, because it makes **every** principal ARN wrong at once — including infra's, on all
four buckets simultaneously. There is no key left that can remove the policy.

Before the first real apply, prove the ARN format against a disposable bucket:

```bash
aws --endpoint-url https://fsn1.your-objectstorage.com --region fsn1 s3api create-bucket --bucket xenopsbase-policy-canary
```

Put an object in it, apply the same `Deny` + `NotPrincipal` policy naming only your infra key and
`project_id`, then confirm **infra can still read the object**. If it can, the ARN format is right
and the real buckets are safe. If it cannot, you have lost a bucket you did not need.

Then check the deny half with a non-allowlisted key — it must get `403`. Delete the canary
afterwards.

This takes two minutes and converts the one irreversible step in this runbook into a reversible
one. Worth it every time the project ID or the infra key changes.

## First-time setup

Two credential sets are in play — see [terraform state](terraform-state.md#two-s3-services-two-credential-sets).
The `AWS_*` names belong to **R2** (Terraform state); Hetzner takes the explicit ones:

```bash
export TF_VAR_hetzner_s3_access_key=<hetzner infra key>  TF_VAR_hetzner_s3_secret_key=<hetzner infra secret>
```

```bash
export AWS_ACCESS_KEY_ID=<r2 key>  AWS_SECRET_ACCESS_KEY=<r2 secret>
```

```bash
cp infra/terraform/storage/backend.hcl.example infra/terraform/storage/backend.hcl
cp infra/terraform/storage/terraform.tfvars.example infra/terraform/storage/terraform.tfvars
```

Edit both, then:

```bash
make storage-init && make storage-adopt-state
```

`storage-adopt-state` is only relevant if a Hetzner `tfstate` bucket already exists from before
ADR-0005 moved state to R2. On a fresh project it will find nothing to import, which is correct —
the Hetzner `tfstate` bucket is now reserved for scheduled state backups rather than live state.

```bash
make storage-plan
```

The plan should show three buckets to create and one already imported. If it proposes to *destroy*
anything, stop and work out why before continuing.

```bash
make storage-apply
```

```bash
make storage-lifecycle
```

Then verify the key IDs, set `enable_bucket_policies = true`, and apply once more.

## Verifying isolation actually works

After policies are enabled, confirm each key is confined. Using the `observability` key:

```bash
AWS_ACCESS_KEY_ID=<observability key> AWS_SECRET_ACCESS_KEY=<observability secret> \
  aws --endpoint-url https://fsn1.your-objectstorage.com --region fsn1 \
  s3 ls s3://xenopsbase-documents/
```

This must fail with `AccessDenied`. If it succeeds, the policy is not in effect and the
least-privilege claim is false — a security finding, not a configuration nit.

Check the infra key still reaches **every** bucket in the same pass. A policy that isolates the
consumers but also locks out Terraform is not a success.

Verified 2026-08-19:

| Bucket | infra key | observability key |
|---|---|---|
| documents | OK | denied |
| pg-backups | OK | denied |
| loki-chunks | OK | ALLOWED |
| tfstate | OK | denied |

Before the policies were applied, the observability key could read the documents bucket. That is
the project-wide default these policies exist to correct, and it is worth reproducing once so the
risk is understood rather than taken on faith.

## Rotating a key

1. Generate a replacement pair in the console. Do not delete the old one yet.
2. Add the new key ID to `access_keys` in `terraform.tfvars` and apply, so both are allowlisted.
3. Update the consumer to use the new pair.
4. Confirm the consumer works.
5. Remove the old key ID from `terraform.tfvars`, apply, then delete the old pair in the console.

Deleting first strands the consumer. Applying a policy without the new key locks it out.

## Costs

Hetzner Object Storage bills on stored volume and egress. The buckets are the only thing in this
project that bills while the cluster is destroyed, so they are the whole of the "near zero"
baseline rather than nothing at all. The lifecycle rules exist to keep that baseline flat, and
`abort_incomplete_multipart_upload` matters more than it looks: failed uploads leave parts that
bill indefinitely and are invisible in a normal bucket listing.
