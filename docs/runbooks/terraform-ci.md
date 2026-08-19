# Runbook: Terraform CI

No infrastructure change reaches `main` without a reviewed plan.

| Job | Runs on | Needs secrets |
|---|---|---|
| `lint` | every PR, per module | no |
| `checkov` | every PR | no |
| `plan` | PRs from this repo only, per module | yes |
| `apply` | manual dispatch only | yes |

## Why apply is manual

`apply` never runs on push or merge. An apply here creates or destroys real,
billable infrastructure, and ADR-0002 makes destroy an *everyday* operation rather than an
exceptional one — so an automatic apply on merge would be a routine way to delete a cluster
someone was using. A human picks the module and environment from the dispatch form.

## Why fork pull requests get no plan

The workflow uses `pull_request`, never `pull_request_target`.

This repository is public. `pull_request_target` runs workflow code from the base branch **with
secrets available** to a fork's pull request — the standard way credentials leak out of public
repos. With `pull_request`, a fork simply has no secrets, and the plan job skips itself rather than
failing noisily.

Lint and checkov still run for forks, so an outside contribution is still checked; it just cannot
reach state.

## Plan output is public

The plan is posted as a PR comment, and this repository is public. Terraform redacts values marked
`sensitive`, but resource attributes are visible: bucket names, hostnames, tunnel IDs.

None of those are secrets — bucket names are already in the repo and the tunnel ID is already in
public DNS — but it is a deliberate acceptance rather than an oversight. If a future module plans
something genuinely revealing, post a summary instead of the full plan.

## Required secrets

Repository → Settings → Secrets and variables → Actions. Nine of them:

| Secret | What |
|---|---|
| `R2_ACCESS_KEY_ID` | R2 key — Terraform state (ADR-0005) |
| `R2_SECRET_ACCESS_KEY` | R2 secret |
| `R2_ENDPOINT` | `https://<account_id>.r2.cloudflarestorage.com` |
| `HETZNER_S3_ACCESS_KEY` | Hetzner infra key — the durable buckets |
| `HETZNER_S3_SECRET_KEY` | Hetzner infra secret |
| `HETZNER_PROJECT_ID` | numeric project ID, for bucket policy ARNs |
| `HETZNER_KEY_INFRA` / `_APP` / `_DB` / `_OBS` | access key IDs for the policies |
| `HCLOUD_TOKEN` | Hetzner Cloud API token — the cluster |
| `CLOUDFLARE_API_TOKEN` | Cloudflare token — DNS and tunnel |
| `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_ZONE_ID` | edge module identifiers |
| `FIREWALL_SOURCE_CIDRS` | JSON list, e.g. `["203.0.113.4/32"]` |

Set them yourself rather than pasting values into a session:

```bash
gh secret set R2_ACCESS_KEY_ID --repo mertkan-iscan/xenopsbase-stemcell
```

Until they exist, `plan` emits a warning and skips. Lint and checkov work regardless, so the
workflow is useful from the moment it merges.

## What checkov is actually worth here

Be honest about this one. Checkov's Terraform rules target AWS, and Hetzner Object Storage
implements a subset of the S3 API — so most S3 checks are not "risks accepted" but **APIs that do
not exist to configure**. After waiving those, checkov reports zero passed and zero failed on the
current code: every applicable check is inapplicable either way.

That makes it a **regression detector**, not a security bar. It earns its place by catching a *new*
class of problem in code we add later — verified by temporarily adding a bucket with public access
blocks disabled, which it flagged immediately (`CKV_AWS_53`, `CKV_AWS_54`).

The security properties that actually matter are verified directly rather than statically:

- bucket isolation, by probing each bucket with each credential (T-1.2)
- public exposure, by port-scanning every node from outside (T-1.5)

The one finding worth reading is `CKV_AWS_93` — *"bucket policy does not lockout all but root
user"*. Checkov independently identified the exact hazard the canary procedure exists for. It is
skipped only because the check cannot see the three mitigations; the reasoning is in
`.checkov.yaml`, and if those mitigations are ever removed the skip must go with them.

## Scan scope is on the command line, not in the config

`.checkov.yaml` deliberately does **not** set `directory` or `framework`. With them in the config
file the scan scope resolves differently and silently covers less — observed as `Passed checks: 0`
against a tree the CLI flag reports 7 for. Keeping scope on the command line makes a CI run and a
laptop run the same scan.

To reproduce CI locally:

```bash
python -m checkov.main --directory infra/terraform --framework terraform --config-file .checkov.yaml
```

## Action pinning

Actions are pinned to commit SHAs where the SHA is known. `tflint` and `checkov` are installed
directly instead, because pinning to an *unverified* SHA is worse than not pinning: it looks
rigorous while pointing at something nobody checked, in a workflow that runs with repository
permissions.
