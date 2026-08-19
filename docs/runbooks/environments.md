# Runbook: environments

Three environments — `dev`, `staging`, `prod` — sharing one set of Terraform code. The only thing
that differs between them is a `.tfvars` file.

```
infra/terraform/
  storage/            durable buckets, per environment
    env/dev.tfvars              committed
    env/dev.secrets.tfvars      gitignored — key IDs and project ID
  cluster/            the K3s cluster, per environment
    env/dev.tfvars              committed
```

Every target takes `ENV`, defaulting to `dev`:

```bash
make cluster-plan ENV=staging
```

## Adding a fourth environment

Two files, no HCL changes:

```bash
cp infra/terraform/cluster/env/staging.tfvars infra/terraform/cluster/env/qa.tfvars
cp infra/terraform/storage/env/staging.tfvars infra/terraform/storage/env/qa.tfvars
```

Set `environment = "qa"` in both, adjust sizing, then:

```bash
make storage-init storage-apply storage-lifecycle ENV=qa
```

The acceptance criterion for T-1.4 said *one* new tfvars file. It is two, because storage and
cluster are separate root modules with separate state — the split that stops a cluster teardown
reaching the durable buckets (ADR-0002). Collapsing them into one file would mean collapsing the
modules, which would trade a real safety property for a smaller number in a checklist.

If the environment needs its own S3 credentials, also copy
`storage/env/secrets.tfvars.example` to `storage/env/qa.secrets.tfvars`.

## Why buckets are named per environment

Bucket names include the environment: `xenopsbase-dev-documents`, `xenopsbase-prod-documents`.

This is not tidiness. Bucket policies are the **only** isolation mechanism Hetzner offers — keys
are project-wide by default and otherwise read everything — and a policy applies to a whole bucket.
One shared `documents` bucket would mean allowlisting the dev app key *and* the prod app key on it,
so a leaked dev credential reads production documents.

Separate buckets are what make the least-privilege claim survive a second environment. The original
single-environment layout in T-1.2 would have quietly stopped being true the moment staging existed.

## How the wrong-state mistake is prevented

The classic failure of a shared-code layout is applying one environment's variables against
another's state. It is silent, and by the time it is visible the damage is done.

State keys are **derived from `ENV`**, never written into `backend.hcl`:

| Module | State key |
|---|---|
| storage | `storage/$(ENV)/terraform.tfstate` |
| cluster | `$(ENV)/cluster.tfstate` |

Every `init` passes `-reconfigure` along with the derived key, so the backend is re-pointed by the
same command that selects the var file. There is no window in which they can disagree.

Two further guards run before any Terraform command:

- **The environment must exist.** A typo lists the real ones rather than silently doing nothing.
- **The tfvars must declare the same environment it is named for.** Copy-pasting `staging.tfvars`
  to `qa.tfvars` and forgetting to edit `environment` would otherwise apply staging's sizing under
  qa's name, into qa's state.

```
$ make cluster-plan ENV=nope
error: no such environment 'nope' - infra/terraform/cluster/env/nope.tfvars is missing
       available: dev prod staging
```

## Credentials, and a trap worth knowing about

`~/.aws/credentials` is read by the AWS SDK when the environment variables are unset. If another
project has left credentials there — and on this machine one had — then forgetting to
`source ~/.xenopsbase.env` does not fail. Terraform silently proceeds with a different account.

The symptom is not "you forgot to set credentials". It is an error like
`Credential access key has length 20, should be 32`, surfacing from inside a backend operation
rather than at the point of the mistake.

So every environment target checks first:

```
$ make storage-plan
error: AWS_ACCESS_KEY_ID is not set.
       run: source ~/.xenopsbase.env
       without it Terraform silently falls back to ~/.aws/credentials,
       which belongs to a different account entirely.
```

It also catches the specific swap of putting a Hetzner key (20 chars) in the R2 slot, since the
two credential sets are easy to confuse — see [terraform state](terraform-state.md#two-s3-services-two-credential-sets).

## Sizing

| | dev | staging | prod |
|---|---|---|---|
| Control plane | 1 × cx23 | 3 × cx23 | 3 × cx33 |
| Workers | 2 × cx23 | 2 × cx23 | 3 × cx43 |
| Highly available | no | yes | yes |

**dev is deliberately not HA.** It is destroyed between working sessions, so an hour of downtime
has no consumer to inconvenience, and paying for availability nobody uses is waste rather than
prudence.

**staging is HA at the smallest size that proves it.** The point of staging is to exercise prod's
failure modes; a single-node control plane cannot lose etcd quorum, so a 1-node staging would never
catch that class of bug.

**Never 2 control plane nodes.** etcd needs a quorum of more than half, so two tolerate zero
failures while costing twice as much — strictly worse than one. The variable validation rejects
even totals outright.

## Confirming isolation after a change

Policies take a few seconds to propagate. A check run immediately after `storage-apply` can report
a denial that resolves on retry — that happened during this task and briefly looked like a lockout.
Retry once before concluding anything.

```bash
AWS_ACCESS_KEY_ID=<observability key> AWS_SECRET_ACCESS_KEY=<secret> \
  aws --endpoint-url https://fsn1.your-objectstorage.com --region fsn1 \
  s3 ls s3://xenopsbase-dev-documents/
```

Must be denied. And check the infra key still reaches **every** bucket in the same pass: a policy
that isolates the consumers but locks out Terraform is not a success.
