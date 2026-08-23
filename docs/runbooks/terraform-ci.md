# Runbook: Terraform CI

An infrastructure change is *supposed* to reach `main` only with a reviewed plan. Right now it
does not: `plan (cluster)` has been failing since 2026-08-21 and `terraform` is deliberately not
among the required status checks until it is fixed
([#183](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/183)). Read that before
trusting a green tick on an infrastructure pull request.

| Job | Runs on | Needs secrets |
|---|---|---|
| `changed paths (terraform)` | every PR and every push to `main` | no |
| `lint` | per module, when Terraform changed | no |
| `checkov` | when Terraform changed | no |
| `plan` | PRs from this repo only, per module, when Terraform changed | yes |
| `terraform` | every PR — aggregates the four above | no |
| `apply` | manual dispatch only | yes |

## Why the workflow starts even when no Terraform changed

The trigger carries no `paths:` filter, which looks wasteful and is not. A required status check
whose workflow never ran is reported by GitHub as **expected**, not skipped, and a pull request
waiting on a check that will never arrive cannot be merged at all. Filtering at the trigger and
requiring the check are mutually exclusive.

So the filter lives in `changed paths (terraform)` instead — one cheap job that diffs the merge
base and applies exactly the path list the trigger used to hold. Everything expensive is gated on
its output and skips when nothing relevant changed. A skipped job counts as success to branch
protection; a workflow that never ran counts as nothing.

`terraform` is a single aggregate context that fails if any job it needs reported anything other
than success or skipped. Branch protection names that one context rather than the eight
matrix-derived job names, so adding a fourth root module or renaming one cannot silently drop a
required check. `apply` is not among its needs — it is dispatch-only and has nothing to say about
whether a branch is mergeable.

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

Fifteen of them. Rather than setting each by hand, run the script — it reads every value from the
same `~/.xenopsbase.env` used for local applies and pipes each straight to `gh secret set`, so no
value is ever pasted anywhere:

From the repository root:

```bash
cd /path/to/xenopsbase-stemcell && source ~/.xenopsbase.env && bash infra/scripts/set-ci-secrets.sh
```

For reference, what it sets:

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

Verify with `gh secret list`. The script is safe to re-run; setting an existing secret overwrites it.

Until they exist, `plan` emits a warning and skips. Lint and checkov work regardless, so the
workflow is useful from the moment it merges.

**Sixteenth, and missing:** `TAILSCALE_AUTH_KEY`. Every environment now runs
`node_transport_mode = "tailscale"`, and the cluster module rejects that at plan time without
`TF_VAR_tailscale_auth_key` — so `plan (cluster)` and `apply (cluster / …)` both die on variable
validation before reaching a provider. See
[#183](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/183), including why a
placeholder value is not an option: the key reaches nodes through cloud-init `user_data`, which is
part of the plan diff, so a fake one makes the plan propose replacing every node.

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
