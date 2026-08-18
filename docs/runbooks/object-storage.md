# Runbook: object storage

Four buckets hold the entire left-hand column of
[ADR-0002](../adr/0002-ephemeral-cluster-and-durable-state.md). Clusters are disposable; these are
not. Everything that would hurt to lose is in here.

| Bucket | Holds | Versioned | Lifecycle backstop |
|---|---|---|---|
| `<prefix>-documents` | Uploaded documents | Yes | Old versions expire after 90d. Current versions never expire |
| `<prefix>-pg-backups` | CloudNativePG base backups and WAL | No | Objects expire after 35d — this is the PITR ceiling |
| `<prefix>-loki-chunks` | Loki log chunks | No | Objects expire after 30d |
| `<prefix>-tfstate` | Terraform state | Yes | Old versions expire after 365d |

## Why storage is a separate root module

`make down` runs `terraform destroy` as an everyday operation — that is the whole point of the
ephemeral model. If these buckets lived in the same state as the cluster, **the routine teardown
would delete the durable side of the boundary.** Every document, every backup, gone, as a normal
Tuesday.

So `infra/terraform/storage/` is its own root module with its own state key
(`storage/terraform.tfstate`), and `make down` is wired to `infra/terraform/cluster/` only. Every
bucket additionally carries `prevent_destroy`, and there is deliberately no `storage-destroy`
target. Deleting these should require editing Terraform by hand and meaning it.

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

## First-time setup

```bash
export AWS_ACCESS_KEY_ID=<infra key>  AWS_SECRET_ACCESS_KEY=<infra secret>
```

```bash
make bootstrap-state
```

```bash
cp infra/terraform/storage/backend.hcl.example infra/terraform/storage/backend.hcl
cp infra/terraform/storage/terraform.tfvars.example infra/terraform/storage/terraform.tfvars
```

Edit both, then:

```bash
make storage-init && make storage-adopt-state
```

`storage-adopt-state` imports the state bucket that `bootstrap-state` created, so that versioning
and lifecycle are enforced in one place rather than living half in a script and half in HCL.

```bash
make storage-plan
```

The plan should show three buckets to create and one already imported. If it proposes to *destroy*
anything, stop and work out why before continuing.

```bash
make storage-apply
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
