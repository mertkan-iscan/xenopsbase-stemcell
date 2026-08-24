# ADR-0008: The durable-state boundary includes things Terraform does not create

- **Status:** Accepted
- **Date:** 2026-08-24
- **Task:** T-0.6 (#69)
- **Amends:** [ADR-0002](0002-ephemeral-cluster-and-durable-state.md)

## Context

ADR-0002 is the decision the rest of the project rests on: the cluster is cattle, and a table
divides what survives `terraform destroy` from what does not. It ends with a rule that is stronger
than most tables get — *"Anything not in the left column **will be lost** … There is no third
category."*

That rule is only as good as the table, and T-1.3 found something missing from it.

`make up` provisions every node from a **Packer-built OS snapshot** in the Hetzner project. It is
not created by Terraform, it is not removed by `make down`, and without it a rebuild fails before
creating anything. By ADR-0002's own definition it belongs in the left column, alongside container
images — which the table does list.

The snapshot is not an oversight in the code. `infra/scripts/verify-teardown.sh` has been asserting
its survival since T-1.3:

```
printf '  %-30s ' "OS snapshot"
if hcloud image list --selector leapmicro-snapshot=yes ... ; then
  echo "present"
else
  echo "GONE  <-- next build must run packer again"
```

So the teardown check enforced a boundary the decision record did not state. That gap is the reason
for this ADR: a control that is right by accident is one refactor away from being wrong, because
nothing explains why it is there.

Since ADR-0002 must not be edited to quietly absorb the omission, this amends it — and since one
omission is evidence of a class rather than an incident, the amendment is scoped to the class.

## Decision criteria

What earns a row in the durable table, applied uniformly rather than to the snapshot alone:

1. **It survives `make down`.** `down` destroys the cluster module and nothing else.
2. **A rebuild depends on it**, or losing it costs something that cannot be recreated from this
   repository.
3. **Nothing in the cluster recreates it.** GitOps reconciles the cluster from git; it has no
   reach outside.

The original table was assembled by asking what lives in the cluster. That framing is what let the
snapshot through: the snapshot is not *in* the cluster and not *in* git, so neither side of the
question found it.

## Decision

**ADR-0002's durable-state table is amended to include the rows below.** The left column is
authoritative; ADR-0002's version is superseded by this one where they differ.

| Added to **outside the cluster — survives `terraform destroy`** | Why it qualifies |
|---|---|
| **OS snapshot** — Hetzner, built by Packer (`make snapshot`) | Every node is provisioned from it. `apply` fails before creating anything without it. Not Terraform-managed at all |
| **Cloudflare edge** — tunnel, tunnel config, DNS records, Access application, policies and service token, WAF and request-header rulesets, zone settings | The `edge` module, separate state. It is *why* DNS is stable across rebuilds — the property the README advertises — and that property is exactly durability |
| **Object storage buckets themselves** — not only their contents | The `storage` module. Bucket policy, versioning and lifecycle rules are state; `verify-teardown.sh` already fails when lifecycle rules go missing |
| **Mail DNS** — Brevo DKIM, SPF, tracking and verification records, DMARC | The `mail-dns` module. Deliverability reputation is earned slowly and cannot be rebuilt on demand |
| **The age private keys** — offline, and a KMS recipient once T-0.9 lands | The most consequential row here. Every secret in git is encrypted to them. Lose them all and the repository still builds nothing: no secret decrypts, so no environment comes up |

### The audit this came from

The fourth acceptance criterion of T-0.6 asked whether anything *else* added since ADR-0002 is
unlisted. It was, and the answer was not one item:

- `make down` runs `cluster-destroy` and only that. Everything in the `storage`, `edge` and
  `mail-dns` modules therefore survives by construction — three modules, none represented in the
  table.
- The age keys are outside the cluster *and* outside Terraform, which is why neither the original
  framing nor the module sweep would have found them. They surfaced because T-0.8 (#163) had
  already made them a subject.

Two things follow. First, "container images — GHCR" was in the table not because the boundary was
reasoned through to its edge but because images are conspicuous. Second, the near miss is
instructive: **the age keys are the one row where the loss is unrecoverable rather than expensive**,
and they were the last to be noticed.

## Consequences

### What this makes easy

`verify-teardown.sh` now has a decision record to check itself against, rather than being the only
place a rule exists. The snapshot check reads as an implementation of a stated boundary.

Anyone forking the stemcell gets a complete list of what must exist before `make up` can work —
which is the list [docs/forking.md](../forking.md) needs to be true, and it now is.

### What this makes hard

The rule "anything not in the left column will be lost" is easy to state and, as this ADR
demonstrates, hard to keep true. Every new provider-side resource is a candidate row, and nothing
enforces the discipline automatically. What exists is `verify-teardown.sh`, which checks a subset
and now diverges from the table — it does not assert the Cloudflare edge or the mail DNS.

That divergence is **deliberately left open** rather than closed here, because closing it means
deciding whether a teardown check should call the Cloudflare API at all, and that is a design
question with a cost, not a documentation fix. It is recorded as a known gap in
[disaster-recovery.md](../runbooks/disaster-recovery.md).

### Consequence for T-7.2 — cold rebuild has two timings, not one

This is the practical reason the snapshot's absence from the table mattered.

A "cold rebuild" is ambiguous once the snapshot is durable state, and the two readings differ by
minutes:

| Rebuild | What has to happen |
|---|---|
| **Snapshot present** — the normal case, including after `make down` | `terraform apply` provisions from the existing image |
| **Genuinely empty project** — a fork, or a lost snapshot | `make snapshot` first: a Packer build, measured at 322s under T-1.3 |

T-7.2 (#54) must publish **both**, labelled. A single figure would be quoted as the disaster-recovery
number while having been measured on the easier path — which is how a capacity fact becomes wrong
without anybody editing it. The root README's cold-rebuild cells are deliberately empty pending that
measurement, and should stay empty rather than be filled from the warm path.

### What it commits us to

Keeping a list current by discipline. Reversal is not the issue — the cost is that a table like this
degrades silently, and the only real defence is that the next omission is found the same way this
one was: by asking what `make down` does not touch, rather than what the cluster contains.
