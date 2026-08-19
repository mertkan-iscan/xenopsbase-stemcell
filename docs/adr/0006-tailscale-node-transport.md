# ADR-0006: Tailscale is the node transport, and the public API is closed

- **Status:** Accepted — **not yet in effect**, blocked by a module limitation (see below)
- **Date:** 2026-08-19
- **Task:** T-1.5

## Implementation status, 2026-08-19

The decision stands. It does not work yet.

Tailscale itself did exactly what this ADR describes: all nodes joined the tailnet with direct
WireGuard paths, Terraform reached them by MagicDNS name, and `verify-exposure` confirmed nodes
answered nothing on 22, 6443, 2379 or 10250 while being provisioned.

The cluster still failed to converge, because enabling Tailscale disables the Hetzner CCM's network
awareness:

```
hetzner_ccm_networking_enabled  = cluster_has_ipv4 && !cross_network_transport_enabled
cross_network_transport_enabled = multinetwork_overlay_enabled || node_transport_tailscale_enabled
```

The CCM then cannot match the private node IP k3s advertises, so the node keeps its
`uninitialized` taint, nothing schedules, and the agents' k3s install never runs.

`dev` therefore runs on the **escape hatch** below — `hetzner_private` with an IP allowlist — which
is precisely the situation the hatch was written for. Tracked as a follow-up; this ADR is not
superseded, and the escape hatch is not the decision.

Two things this does not change: the reasoning for preferring Tailscale over an IP allowlist stands
unaltered, and the allowlist's known weaknesses — a dynamic home IP, and CI ranges too broad to
allowlist — are now live problems rather than hypothetical ones.

## Context

T-1.5 requires nodes on a private network with **no public API server endpoint**, and a public
surface reduced to the ingress load balancer.

The private network part is already true: kube-hetzner puts every node on a Hetzner private network
and the module creates a firewall. The hard part is the second half, because closing the public
Kubernetes API and SSH also closes the door Terraform itself comes through. kube-hetzner provisions
nodes over SSH, so whatever locks the front door has to let the builder back in.

That collides with something [ADR-0005](0005-terraform-state-backend.md) deliberately protected. It
chose Cloudflare R2 over serializing applies through CI specifically to keep `make up` and
`make down` ordinary local commands, on the grounds that a rebuild path which is slow or awkward
stops being exercised — and an unexercised recovery path does not work. Any hardening that makes
local applies impossible would quietly undo that.

kube-hetzner's own documentation settles the available shape: closing public API and SSH
(`firewall_kube_api_source = null`, `firewall_ssh_source = null`) is documented **only** in the
context of `node_transport_mode = "tailscale"`. It is not a firewall setting; it is an access
architecture.

## Decision criteria

- **Does Terraform still reach the nodes?** A design that only a CI runner can apply fails ADR-0005.
- **Does it survive a changing source IP?** A home connection's address is not stable, and the
  module warns that a stale allowlist makes provisioning *hang* rather than fail.
- **Can CI use the same path?** T-6.x and T-7.3 need automated applies.
- **What does it add to the rebuild path**, and what happens when that thing is down?

## Decision

**Tailscale is the node transport.** `node_transport_mode = "tailscale"`, with
`firewall_kube_api_source` and `firewall_ssh_source` both `null`.

Nodes join the tailnet at first boot via `bootstrap_mode = "cloud_init"` — not `remote_exec`, which
would need public SSH open during provisioning and so defeat the purpose. Terraform then reaches
them over the tailnet (`ssh.use_tailnet_for_terraform`, default true), and the kubeconfig points at
the control plane's tailnet address rather than a public IP.

The machine running Terraform must therefore be on the tailnet. That is the whole trade: a
membership requirement replaces an IP allowlist.

Nodes keep their public IPv4/IPv6, per the module's guidance — they are needed for Tailscale
bootstrap and for direct WireGuard paths. **Public IP is not the same as public API**: the
addresses exist, but the firewall answers nothing on them.

## Consequences

### What this makes easy

- The criterion is met literally: there is no public Kubernetes API endpoint, not merely a filtered
  one.
- Access works from any network. Nothing breaks when a home IP changes, and there is no allowlist
  to maintain.
- CI joins the tailnet with an ephemeral auth key. The alternative — allowlisting GitHub Actions
  ranges — is close to allowlisting the internet, so this is the only option that hardens CI rather
  than exempting it.
- Local `make up` / `make down` survives intact, which is what ADR-0005 was protecting.

### What this makes hard

- **A third vendor on the rebuild path**, after Hetzner and Cloudflare. If Tailscale is unreachable,
  a rebuild cannot complete — nodes cannot join, and Terraform cannot reach them. This is a harder
  dependency than R2, which only gates state access.
- **A second bootstrap secret.** The Tailscale auth key joins the age key (ADR-0003) as something
  that must exist before the cluster does. It must be **reusable**, since a single-use key registers
  only the first node.
- Debugging a node that failed to join the tailnet is harder than debugging one you can SSH to,
  precisely because the fallback path is closed.
- The module enforces constraints at plan time: `magicdns_domain` must be set, agent nodepools need
  an explicit `network_scope`, autoscaler pools must use `cloud_init`, and CNI must stay `flannel`
  unless Cilium is explicitly enabled as experimental.

### The escape hatch, and why it exists

`node_transport_mode` stays a variable. Setting it to `hetzner_private` restores public SSH and API
with an IP allowlist.

This is not indecision. It is the recovery path for the failure this decision introduces: if
Tailscale is down and the cluster must be rebuilt, the alternative to an escape hatch is waiting for
someone else's outage to end. The hatch is documented in the runbook and is a deliberate,
reviewable change — not a flag anyone flips casually.

## Alternatives considered

### IP allowlist, endpoint stays public — rejected

`firewall_kube_api_source` and `firewall_ssh_source` set to known CIDRs. No new vendor, no new
bootstrap secret, and no new failure mode on the rebuild path.

Rejected on two grounds. It does not meet the criterion — the endpoint remains public, merely
filtered — and more practically, CI cannot be allowlisted without effectively allowlisting the
internet, so the hardening would apply to the laptop and exempt the automation. The module also
warns that a stale allowlist causes provisioning to hang rather than fail, which is the worst kind
of breakage.

### Cloudflare Zero Trust in front — rejected for now

Consolidating on Cloudflare, already present for R2, is genuinely attractive: no new vendor. But the
module treats Access/Tunnel as a user-managed layer rather than integrating it, so it is the most
setup and the least trodden path with kube-hetzner. Its own note recommends *combining* Cloudflare
Access with Tailscale rather than substituting it, which is a reasonable later addition for
human access rather than a replacement for node transport.

### SSH bastion — rejected

An always-on jump host contradicts the near-zero-when-idle constraint that ADR-0002 is built on. It
would be the only server billing while the cluster is destroyed.

## Revisit if

- Tailscale's free tier stops covering this, or an outage blocks a rebuild in practice rather than
  in theory. That would make the dependency concrete rather than acceptable.
- Hetzner offers a private API endpoint natively, which would remove the need for a transport vendor.
- The escape hatch gets used more than once. Needing it repeatedly means the dependency is not as
  reliable as this decision assumes.
