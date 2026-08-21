# ADR-0006: Tailscale is the node transport, and the public API is closed

- **Status:** Accepted — **in effect** in `dev` since 2026-08-21
- **Date:** 2026-08-19
- **Task:** T-1.5

## Implementation status, 2026-08-21

**In effect.** `dev` was rebuilt from nothing with `node_transport_mode = "tailscale"` and
converged: one control plane and two agents, all `Ready`, all reachable only over the tailnet.

### What blocked it, and what fixed it

Tailscale itself always did what this ADR describes. What failed was the Hetzner CCM, because
kube-hetzner v3.1.0 gates two related things on two *different* conditions:

```
node-ip         multinetwork_overlay_enabled
CCM networking  cross_network_transport_enabled
                  = multinetwork_overlay_enabled || node_transport_tailscale_enabled
```

Under tailscale alone the two disagree. k3s keeps advertising the **private** address, while the
CCM is rendered with `networking.enabled: false` and so is given no network to resolve that
address against. It cannot match the node, never removes the `uninitialized` taint, nothing
schedules, and the agents' k3s install never runs.

The fix is to re-enable CCM networking under tailscale
(`ccm_restore_networking_under_tailscale`, default `true`). It is sound **only** for a cluster
whose nodes are all on the one primary network — which is the case the module disabled it to
protect — and a `check` block refuses the combination it is not safe for. Routes stay off;
flannel's vxlan backend carries pod traffic.

### Evidence, not inference

The taint clearing is the outcome, and an outcome can be right for the wrong reason. What was
checked:

| Claim | Evidence |
| --- | --- |
| The CCM has the network | `HCLOUD_NETWORK` present on the deployment, from the `hcloud` secret's `network` key |
| Routes remained off | `HCLOUD_NETWORK_ROUTES_ENABLED=false` |
| The CCM matched the node | `providerID: hcloud://163008021` and an `ExternalIP` — neither is set for an unmatched node |
| Agents could then join | both workers `Ready`, which never happened under the failure |
| Nothing is publicly exposed | `verify-exposure`: 22, 6443, 2379, 10250 all `closed` on all three nodes |
| The firewall has no inbound path | the only inbound rule is UDP 41641, Tailscale WireGuard |
| The jump path is real | `kubectl` reaches `https://…​.tail894b71.ts.net:6443`, and there is no public endpoint to fall back to |

### The escape hatch is no longer in use

`dev` ran on `hetzner_private` from 2026-08-19 to 2026-08-21. It is now on tailscale, and the
allowlist's known weaknesses — a dynamic home IP, CI ranges too broad to allowlist — stop being
live problems.

The hatch itself stays. It was used once, for a real blocker, and removing the only recovery path
for "Tailscale is down and the cluster must be rebuilt" would trade a fixed problem for an
unfixable one. See *Revisit if* below: it is the *repeated* use of the hatch that would be the
signal, and that has not happened.

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
