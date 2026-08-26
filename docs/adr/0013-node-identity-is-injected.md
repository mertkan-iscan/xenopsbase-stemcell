# ADR-0013: A node's identity is injected before any node exists, never discovered from one

- **Status:** Accepted (token half). Endpoint half withdrawn — see below.
- **Date:** 2026-08-26 (endpoint half corrected the same day, before implementation)
- **Task:** T-1.25 (#286)
- **Amends:** none. Constrains [ADR-0002](0002-ephemeral-cluster-and-durable-state.md) and
  [ADR-0006](0006-tailscale-node-transport.md).

## Context

T-1.23 moved static agents off kube-hetzner and onto the golden image. The terraform is small and
`terraform validate` passed. Two live builds failed, in two different ways, and neither failure was
in the code that was written.

`agents.tf` renders each node's bootstrap from two module outputs:

```hcl
server_url    = module.kube_hetzner.effective_node_join_endpoint
cluster_token = module.kube_hetzner.cluster_token
```

Terraform has no way to depend on part of a module. Those two references place every agent behind
the *entire* module, including the platform bootstrap the module runs at its end. So on a cold
build there is a window in which the cluster is one control plane and nothing else, and everything
the module deploys must fit on it.

**Build 1.** The control plane came up schedulable, because with both other node pools empty the
module's `is_single_node_cluster` reduces to the control-plane count and dev has one. Argo CD, the
autoscaler, alloy, node-exporter, cloudflared and metrics-server all landed on a cx23:

```
load average: 16.87, 7.06, 2.85      # two vCPU
argo-cd-argocd-repo-server ... 3 restarts
systemctl is-active k3s → activating
```

The API server went intermittently `ServiceUnavailable` and one of the two agents never managed to
register against it. Pods do not migrate once scheduled, so the agent that did join repaired
nothing. This is #133 again, which dev.tfvars already documents for two cx23 workers; this time it
was one.

**Build 2.** Two fixes were attempted and both were wrong. `allow_scheduling_on_control_plane =
false` is unreachable — the module resolves it as `is_single_node_cluster ? true : var...`, so on
dev the first arm always wins and the variable is never read (`"node-taint": []` on the live node
with the value set to false; the module's own default is false regardless). `bootstrap: true` on the
Argo CD HelmChart did grant its install Job the control-plane toleration, and also stopped the
cluster building: k3s holds the rest of `/var/lib/rancher/k3s/server/manifests` until bootstrap
charts are ready, Argo CD's install loops on failure, so `ccm.yaml` was never applied, nothing
removed `node.cloudprovider.kubernetes.io/uninitialized`, CoreDNS could not tolerate that taint, and
three applies died waiting 300s for a CRD that was never going to appear.

Both failures have the same shape. They are not scheduling bugs, or flag bugs. They are the
consequence of a node learning who it is *from* the cluster it is trying to join.

## Decision criteria

1. **Order-independence.** Can an agent be created without waiting for the control plane? *(Met by
   the token half only. See the deferral below — this criterion is not satisfied by this ADR alone,
   which is stated here rather than quietly dropped.)*
2. **Uses the module as documented**, rather than against its grain.
3. **Testable before the thing it changes**, so it can be proven while the current architecture
   still works.
4. **Does not make the control plane a special node**, since T-1.26 exists to remove exactly that.
5. **Survives a restore.** ADR-0002 rebuilds clusters routinely; a token that changes per build
   would break recovery of an existing cluster.

## Decision

The join token and the control-plane endpoint are **inputs to the system**, created before any node,
and handed to both the module and to every node this repository provisions.

- The token is a `random_password` in this repository's state, passed to the module as
  `cluster_token` (a documented module input) and into each node's cloud-init. It is never read back
  out of a running cluster.
- The endpoint is a stable address that exists before the nodes. **This half is not achievable
  today and is deferred to T-1.26 (#287)** — see below.

The token half stands on its own: it is what makes a rebuild reproducible and a restore possible,
and it is a prerequisite for the endpoint half rather than an optimisation of it.

### The endpoint half, and why it is deferred

This ADR originally said the endpoint would be passed as `control_plane_endpoint`, on the strength
of that variable's description — *"used as the k3s `server` value for agents and secondary control
planes"*. Under this project's transport mode it is not. `locals.tf:126`:

```hcl
k3s_endpoint = local.node_transport_tailscale_enabled
  ? local.tailscale_k3s_join_endpoint
  : (multinetwork ? control_plane_public_endpoint : control_plane_private_endpoint)
```

`node_transport_mode = "tailscale"` is set in every environment (ADR-0006), so the first arm always
wins and the override is never read. And that arm is not a tailscale address despite its name
(`locals.tf:121`): it is `module.control_planes[first].private_ipv4_address`.

Three ways to supply that address ahead of the nodes were considered and none is available:

- **Assign the control plane's private IP explicitly.** `control_planes.tf:88` hardcodes
  `private_ipv4 = null`; it is not a module input.
- **Put a load balancer in front.** `enable_control_plane_load_balancer` does produce a stable
  private IP, but it feeds `control_plane_private_host` (`locals.tf:109`) and not
  `tailscale_control_plane_join_host` (`locals.tf:121`). Under tailscale it is unused for joining.
- **Own the network and create the endpoint in it first.** `existing_network_id` was removed in
  module v3, so the network is the module's for as long as the module runs.

The remaining possibility is to assume the first control plane always receives the subnet's first
address — observed twice, `10.255.0.1`. It is rejected, and rejected specifically because of the
change this ADR exists to enable: with `private_ipv4 = null` Hetzner assigns the lowest free address
in the subnet, so the assumption holds only while the control plane is reliably attached first.
Making agents concurrent — the entire point — turns that into a race an agent can win.

So the endpoint stops being derived from another node at the same moment the network stops being
the module's — and T-1.26 (#287) has since been decided the other way. **The project stays on
kube-hetzner**, so the network stays the module's, and the endpoint half of this ADR is withdrawn
rather than pending.

That is a smaller loss than it looked when this was written. What the endpoint half was for was
letting agents be created concurrently with the control plane, and the problem that motivated it —
the platform applied before any agent existed — was solved instead by ADR-0014, with one dependency
edge and no module surgery. Agents still wait for the module; nothing depends on them not waiting.

What remains true and is why the token half stands on its own: the join secret is ours, so a rebuild
uses the same one by construction rather than by reading it out of the cluster being replaced.

Until then the join endpoint remains a module output. Two other module references stay as well —
`ssh_key_id` and `network_id` — and they are a different thing: infrastructure the servers attach
to, not identity a node presents. This ADR is about the second kind. Both move with T-1.26, for the
same reason the endpoint does.

This is what every mainstream bootstrap does: `kubeadm --token` is generated first, k3s reads
`K3S_TOKEN` from the environment, Talos writes it into the machine config, Cluster API's bootstrap
providers mint it ahead of the machine. The pattern here was the outlier.

## Consequences

### What this makes easy

The token stops being a value that must be extracted from a live cluster, so a rebuild uses the same
join secret by construction rather than by luck.

It removes one of the two `module.` references in `agents.tf`. Concurrency arrives when the second
one goes, with T-1.26 — this ADR gets the cluster half of the way there and does not pretend
otherwise.

T-1.26 becomes tractable: the token is no longer one of the things that has to be untangled at the
same time as the network, the endpoint and the servers.

### What this makes hard

The endpoint must be real before the control plane answers on it — a load balancer, or a name
resolvable ahead of the node. Under `node_transport_mode = "tailscale"` that address is on the
tailnet, and the module's own endpoint logic is tailscale-aware in ways this must not contradict
(see main.tf:287, the case where k3s and the CCM disagree about which address is the node's).

The token is now durable state in terraform state, which ADR-0003 would otherwise keep out of it.
It is not in a snapshot and not in git, but it is one more thing a state file loss makes expensive.

### What it commits us to

Owning the endpoint. Once the module is handed one, the module stops deciding it, and any future
change to how nodes reach the API is ours to get right.

Reversal is cheap while the module still provisions the control plane: drop both inputs and the
module resumes deriving them. Reversal after T-1.26 is not, because by then nothing else computes
them.

## Alternatives considered

### Keep deriving identity from module outputs — rejected

This is the status quo, and it is what both builds refuted. It cannot be fixed by ordering, because
terraform cannot depend on part of a module.

### `bootstrap: true` on the platform charts — rejected, with measurement

It grants the toleration and it stops the cluster building. The flag is for small infrastructure
charts the cluster cannot start without; an application chart in that queue makes k3s wait for the
application before it finishes becoming a cluster. Recorded in `manifests/10-argocd/helmchart.yaml.tpl`
so it is not re-proposed.

### Add tolerations to every platform workload instead — rejected

It would let the platform run on a lone control plane, which is the thing to avoid, not to enable.
It also has to be repeated for every chart the platform ever gains, and the failure when someone
forgets is a Pending pod on a cold build.

### Give the module back a small agent pool so it is never single-node — rejected

It reintroduces the second bootstrap path that T-1.23 exists to remove, and pays for a node whose
only purpose is to change a count.

## Revisit if

- #287 is reopened. The endpoint half comes back with it, and the groundwork is described here and
  in that card rather than sitting in the tree.
- The module gains a way to depend on the control plane separately from the platform bootstrap, at
  which point injection buys ordering we would already have.
- We move to Talos or Cluster API, where identity injection is the native model and this ADR
  describes the platform rather than a decision.
- A restore ever needs a token this repository did not generate — which would mean the assumption
  that we always own it is wrong.
