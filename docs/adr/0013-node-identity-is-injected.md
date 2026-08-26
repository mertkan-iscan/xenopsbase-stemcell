# ADR-0013: A node's identity is injected before any node exists, never discovered from one

- **Status:** Proposed
- **Date:** 2026-08-26
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

1. **Order-independence.** Can an agent be created without waiting for the control plane?
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
- The endpoint is a stable address that exists before the nodes — passed to the module as
  `control_plane_endpoint`, which the module documents as "the k3s `server` value for agents and
  secondary control planes".

No node's configuration is derived from another node. `agents.tf` holds no `module.` reference for
identity.

This is what every mainstream bootstrap does: `kubeadm --token` is generated first, k3s reads
`K3S_TOKEN` from the environment, Talos writes it into the machine config, Cluster API's bootstrap
providers mint it ahead of the machine. The pattern here was the outlier.

## Consequences

### What this makes easy

Agents and control planes are created concurrently. The window in which the cluster is one node
closes, and with it both failures above.

T-1.26 becomes tractable: once no node's identity comes from another, "the control plane is just a
server that runs a different unit" is true rather than aspirational.

The token stops being a value that must be extracted from a live cluster to restore one.

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

- The module gains a way to depend on the control plane separately from the platform bootstrap, at
  which point injection buys ordering we would already have.
- We move to Talos or Cluster API, where identity injection is the native model and this ADR
  describes the platform rather than a decision.
- A restore ever needs a token this repository did not generate — which would mean the assumption
  that we always own it is wrong.
