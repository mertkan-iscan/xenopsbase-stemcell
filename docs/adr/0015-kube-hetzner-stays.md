# ADR-0015: The cluster stays on kube-hetzner, as a hybrid with a chosen boundary

- **Status:** Accepted
- **Date:** 2026-08-27. The decision itself was made 2026-08-26, in #287; this ADR is where it
  lives, because a decision that constrains every fork should not be findable only by knowing
  which of three hundred closed cards to open.
- **Task:** T-0.13 (#301)
- **Relates to:** [ADR-0002](0002-ephemeral-cluster-and-durable-state.md),
  [ADR-0013](0013-node-identity-is-injected.md),
  [ADR-0014](0014-provisioning-and-platform-are-separate-phases.md). Resolves the control-plane
  row of ADR-0008's provenance table — "not yet, T-1.24 and T-1.26" — to **no, by decision**.
  ADR-0008 is append-only and is not edited; this line is the correction.

## Context

The golden-image line of work (#250, #251) moved static agents and autoscaled nodes off
kube-hetzner's boot-time installer and onto a Packer snapshot, forced by a measured limit — the
module's cloud-init exceeded Hetzner's 32 KB `user_data` cap, so no autoscaled node could ever be
created (#22). #282 finished that conversion by taking agent provisioning away from the module
entirely.

That produced a hybrid nobody had chosen: the repository owned every worker, while the module still
owned the control plane, the network, the firewall — and, fatally, the platform bootstrap, which it
ran at the end of its own apply against a cluster whose only node was a lone cx23. Three builds
failed on that (documented in ADR-0013, ADR-0014 and #298). T-1.26 (#287) — originally "the control
plane boots the golden image" — became, for a while, the only apparent way out.

ADR-0014 removed that pressure with one dependency edge: the module provisions machines, this
repository bootstraps the platform after the agents exist. With the forcing problem gone, #287 was
re-asked as the question it actually was — **do we stay on kube-hetzner at all** — and answered on
its own merits.

## Decision criteria

Stated in #287 before the answer, and repeated here:

1. **Evidence over projection.** A working, measured configuration beats a designed, unapplied one.
2. **Total cost of ownership for one operator**, not elegance of the boundary.
3. **What the alternative buys, quantified** — not "one bootstrap path" as a slogan.
4. **Reversibility**: whichever way it goes, the way back must be written down.

## Decision

**The project stays on kube-hetzner.** The module provisions the control plane and the ground it
stands on — network, subnet, firewall, placement groups, CCM, CSI, and everything it writes into
`/var/lib/rancher/k3s/server/manifests`. This repository provisions every node that runs workloads
(static agents and the autoscaler's node definition, on the golden image), the join token
(ADR-0013), the control-plane taint (#298), and — per ADR-0014 — everything above the machines.

The control plane never boots the golden image. That is not pending; it is declined.

## The evidence it was decided on

Measured on dev, 2026-08-26, on the hybrid as it stands:

| | |
|---|---|
| `make up` from nothing | 45 resources, first attempt, `STACK SERVING` in 442s |
| platform | 14/14 applications Healthy |
| control-plane load | 1.16 — was 16.87 when the platform landed on it |
| `make up` twice in a row | `No changes.` — idempotent |
| `make cold-rebuild` | 22 min against a 60 min target, document byte-for-byte |

Against that, converting the control plane buys ~26 seconds of boot (golden-image node Ready in
29.9–33.3s, module-built control plane in 59.3s) on one node in dev and three in prod — nodes that
are rarely replaced and never on a scaling path. Version skew is already closed structurally:
`k3s_version` is read off the golden image's own label (`main.tf`), so the module installs the
version the image carries.

The honest counter-argument was the defect record: five boundary problems surfaced while #282 and
#289 landed. It lost because all five were one-time consequences of the boundary being in the
*wrong place* — half the nodes moved, the platform not — and ADR-0014 moved the line to a coherent
one, with a check standing where each defect was. And because the alternative was never applied:
`cluster-v2` validated but never built a cluster, so choosing it would have been a bet against a
measurement.

## Consequences

### What this makes easy

Nobody maintains a bespoke Kubernetes installer. The k3s server bootstrap, kubeconfig retrieval,
cluster networking, CCM and CSI remain the module's problem, reviewed upstream by more operators
than this project has.

#285 and #286 stop hanging open against a decision already made. Both closed as completed, and the
distinction matters: their *work* is merged — #292 baked both k3s units into the image, the server
unit byte-identical to a running control plane's and boot-tested, and the join token is ours
(ADR-0013) — while their *purpose*, preparing the control-plane conversion, is what this decision
declines. The record says the work exists and the road it was paving is closed.

### What this makes hard

The hybrid depends on module **internals**, not its interface, resolved against the pinned version
(3.1.0). This is the standing inventory; each entry names what breaks it:

| Workaround | Where | Breaks if |
|---|---|---|
| Repo-applied control-plane taint, because `is_single_node_cluster` reduces to the control-plane count with `agent_nodepools = []` and leaves it schedulable | #298; bootstrap ordering in `bootstrap.tf` | the module changes its single-node detection or starts tainting |
| `allow_scheduling_on_control_plane` is set and **never read** — the module's ternary short-circuits it | recorded in #282/#298 | the module fixes the ternary, at which point the variable starts mattering again |
| Join endpoint derived through the module's tailscale-aware locals; the token is ours, the endpoint is not | ADR-0013 (endpoint half, withdrawn) | the module reworks `k3s_endpoint` resolution |
| `kustomize_options_dir` pre-creates a directory to dodge an upstream race | `main.tf` | harmless if fixed upstream; load-bearing until then |
| Agent `labels`/`taints` moved into our bootstrap after the module silently dropped them with the empty pool | `main.tf` node_groups | the module changes what it writes to `/etc/rancher/k3s/config.yaml` |

### What it commits us to

**A module version bump is a cold-rebuild-verified event, not a dependency update.** Every entry in
the table above was found by a failed build, not a changelog. The procedure is: read the release
diff against the inventory, bump, `make up ENV=dev` from nothing, `make verify-node-provenance`,
confirm the control-plane taint survived, `make cold-rebuild`. An automated dependency PR that
bumps this pin must not merge on green checks alone, because no check exercises a live build.

Reversal is what #286 sized: "not a nodepool change — removing kube-hetzner from node
provisioning." The way back is written down: the comparison discipline in #286 (stand each
primitive up while the module is authoritative, assert equality before depending on it) and the
address-per-role network design recorded in ADR-0013 and #287.

## Alternatives considered

### Own node provisioning entirely (`cluster-v2`) — rejected

122 lines where the subnet is ours and every node address is reserved by role, so the API endpoint
is a literal known before terraform creates anything. It validated and was never applied; removed
from the tree in `ee3fd2a` when CI began linting every root module and a half-built one failed by
construction. The design that mattered is preserved in ADR-0013 and #287's closing comment. It
lost on cost: owning CCM, CSI, the server bootstrap, kubeconfig, the firewall and the autoscaler
permanently, per release, for one operator — to save half a minute on a node nobody waits for.

### Convert only the control plane to the golden image (the original T-1.26) — rejected

The smaller-looking version is the same commitment: #286 established that taking the control plane
from the module means the module provisions nothing, so all of its primitives become ours. There
is no partial exit on the control-plane side; the boundary that does support a partial exit —
workers ours, ground theirs — is the one chosen.

## Revisit if

Carried from #287, with two added by this ADR:

- A kube-hetzner release breaks something we cannot patch around, or blocks a node change we need.
- The boundary produces defects at a **steady rate** after ADR-0014, rather than the one-time five
  that came from moving the line. As a threshold: three new entries in the workaround inventory
  above, and the line is in the wrong place again.
- The project moves toward Talos or Cluster API, where owning node lifecycle is the native model.
- **Staging arrives with a three-node control plane.** `is_single_node_cluster` stops reducing to
  one, which changes the premise of the taint workaround and the schedulability arithmetic — the
  inventory must be re-verified at that count, not assumed.

If it reopens: the groundwork is further along than a closed backlog suggests — the image already
carries a boot-tested server unit (#292, #285) and the token is injected (ADR-0013, #286). What
remains is #286's other four primitives — endpoint, network, SSH key, kubeconfig — recovered by
the comparison discipline that card describes, and `cluster-v2`'s design starts from the record in
ADR-0013 rather than from the deleted tree.
