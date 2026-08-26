# ADR-0008: The durable-state boundary includes things Terraform does not create

- **Status:** Accepted
- **Date:** 2026-08-24
- **Task:** T-0.6 (#69)
- **Amends:** [ADR-0002](0002-ephemeral-cluster-and-durable-state.md)
- **Amended:** 2026-08-26, for the golden image — see [Amendment](#amendment-2026-08-26--the-second-packer-artefact)

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
| **Base OS snapshot** — Hetzner, built by Packer (`make snapshot`), labelled `leapmicro-snapshot=yes` | The control plane is provisioned from it. `apply` fails before creating anything without it. Not Terraform-managed at all |
| **Golden image** — Hetzner, built by Packer (`make golden-image`), labelled `xenopsbase-golden=yes` | Every agent and every autoscaled node boots it, with k3s, Tailscale and the SELinux policy already on disk (T-1.18). `data.hcloud_image.golden` selects it by label, so `plan` fails without one. Not Terraform-managed either, and rebuilding it is the slowest step in a genuinely cold start |
| **Cloudflare edge** — tunnel, tunnel config, DNS records, Access application, policies and service token, WAF and request-header rulesets, zone settings | The `edge` module, separate state. It is *why* DNS is stable across rebuilds — the property the README advertises — and that property is exactly durability |
| **Object storage buckets themselves** — not only their contents | The `storage` module. Bucket policy, versioning and lifecycle rules are state; `verify-teardown.sh` already fails when lifecycle rules go missing |
| **Mail DNS** — Brevo DKIM, SPF, tracking and verification records, DMARC | The `mail-dns` module. Deliverability reputation is earned slowly and cannot be rebuilt on demand |
| **The age private keys** — offline, and a KMS recipient once T-0.9 lands | The most consequential row here. Every secret in git is encrypted to them. Lose them all and the repository still builds nothing: no secret decrypts, so no environment comes up |

### Amendment, 2026-08-26 — the second Packer artefact

This ADR was written when there was one Packer-built image and it said so: *"every node is
provisioned from it."* T-1.18 (#250) added a second, and T-1.23 (#282) moved every agent onto it, so
the sentence stopped being true in both halves — the base snapshot no longer provisions every node,
and the image that does had no row.

The table above is corrected rather than annotated, because it is the authoritative one and a
durable-state table that is wrong about durable state is the failure this ADR exists to prevent.
What changed:

| | Boots the base OS snapshot | Boots the golden image |
|---|---|---|
| Control plane | yes, via kube-hetzner | not yet — T-1.24 (#285) and T-1.26 (#287) |
| Static agents | no, since #282 | yes |
| Autoscaled nodes | no, since #251 | yes |

Both images meet all three criteria above unchanged: `make down` does not touch either, a rebuild
fails without either, and nothing in the cluster recreates either.

**This amendment also closes a control that was only half-implemented.** The Context section praises
`verify-teardown.sh` for asserting the snapshot's survival, and the praise was accurate when it was
written; the check kept asserting one selector after there were two. `preflight.sh` has required
both before every apply since #251, so the two gates disagreed about what durable meant. The
teardown check now asserts both, which is what makes this table's second row real rather than
stated.

That is the same failure mode the Context describes — a control that is right by accident — arriving
a second time by a different route. Worth recording, because the lesson from the first occurrence
was "state the boundary", and stating it turned out not to be enough on its own.

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
| **Both images present** — the normal case, including after `make down` | `terraform apply` provisions from the existing images |
| **Genuinely empty project** — a fork, or a pruned image | `make snapshot` *and* `make golden-image` first. The base snapshot was measured at 322s under T-1.3; the golden image builds on top of it and boot-tests before publishing (T-1.20), so it is the longer of the two |

T-7.2 (#54) must publish **both**, labelled. A single figure would be quoted as the disaster-recovery
number while having been measured on the easier path — which is how a capacity fact becomes wrong
without anybody editing it. The root README's cold-rebuild cells are deliberately empty pending that
measurement, and should stay empty rather than be filled from the warm path.

### What it commits us to

Keeping a list current by discipline. Reversal is not the issue — the cost is that a table like this
degrades silently, and the only real defence is that the next omission is found the same way this
one was: by asking what `make down` does not touch, rather than what the cluster contains.
