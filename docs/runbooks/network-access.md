# Runbook: network access and exposure

The public surface is one load balancer on 80 and 443. Nothing else answers.

See [ADR-0006](../adr/0006-tailscale-node-transport.md) for why this shape and what it cost.

## The exposure model

| Address | Port | State | Why |
|---|---|---|---|
| Load balancer | 80, 443 | open | The only intended public entry point |
| Node public IP | 22 | **closed** | SSH is reachable over the tailnet only |
| Node public IP | 6443 | **closed** | There is no public Kubernetes API endpoint |
| Node public IP | 2379, 10250 | **closed** | etcd and kubelet are never public, under any transport |

Nodes **keep** public IPv4 and IPv6. The module needs them for Tailscale bootstrap and for direct
WireGuard paths. A public IP is not a public API: the addresses exist, the firewall answers nothing
on them.

## First-time Tailscale setup

Once per tailnet, not per cluster.

1. Create a Tailscale account at [tailscale.com](https://tailscale.com). The free tier covers this
   comfortably.
2. Install the client on the machine that runs Terraform, and sign in. **That machine must be on
   the tailnet** — it is how Terraform reaches the nodes.
3. Admin console → **Settings → Keys** → *Generate auth key*:

   | Field | Value | Why |
   |---|---|---|
   | Description | `xenopsbase-nodes` | The only way to identify it later for revocation |
   | **Reusable** | **on** | Every node authenticates with this one key. Off means only the first node joins and the rest hang waiting — which looks like a network fault rather than a key problem |
   | Expiration | 90 days (the maximum) | The key expires, not the nodes. **Record the date** in `tailscale_auth_key_expires_at`; `make preflight` is what remembers it, because diarising is the control this project keeps finding does not work |
   | **Ephemeral** | **on** | See below |
   | Tags | off | Requires `tagOwners` / `autoApprovers` in the tailnet ACL first. The module treats tags as optional; skip until there is a reason |

4. Admin console → **DNS** → note the **tailnet name**, e.g. `tail1a2b3c.ts.net`.

### Why Ephemeral, specifically for this design

Ephemeral devices are removed automatically once they go offline. That is a niche option in most
setups and close to essential here.

Clusters are destroyed and rebuilt as the normal operating mode, and every rebuild produces **new**
node names. Without Ephemeral, each teardown leaves its nodes in the tailnet permanently. The free
tier caps at 100 devices, so roughly thirty rebuild cycles would fill it with corpses — in a project
whose entire premise is rebuilding constantly.

kube-hetzner recommends ephemeral keys for autoscaler nodes for the same reason. Here the static
nodes are equally disposable.

The trade: a node offline long enough to be reaped must re-register on return. It still holds the
key in its cloud-init data so it can, but its tailnet address may change — and the kubeconfig points
at the control plane's tailnet address. In practice a rebuild regenerates the kubeconfig anyway
(`make kubeconfig`), so this is an annoyance rather than a trap.

Then:

```bash
export TF_VAR_tailscale_auth_key="tskey-auth-..."
```

Add it to `~/.xenopsbase.env` alongside the others, and set `tailscale_magicdns_domain` in
`infra/terraform/cluster/env/<env>.tfvars`.

The auth key is the **second bootstrap secret**, alongside the age key of
[ADR-0003](../adr/0003-secrets-management.md) — something that must exist before the cluster does.
Treat it the same way.

## SSH access policy

**There is no public SSH.** Reaching a node means being on the tailnet; there is no jump host and
no bastion, because an always-on jump box contradicts the near-zero-when-idle constraint that
ADR-0002 rests on. The tailnet *is* the jump path.

### Key management

| Rule | Reason |
|---|---|
| One key pair per project, not per person-per-project | This repo uses `~/.ssh/xenopsbase_ed25519`. Reusing a key across projects means one compromised host reaches both |
| ed25519, not RSA | Shorter, faster, and the module's default expectation |
| **No passphrase** | Terraform provisions non-interactively and cannot answer a prompt. This is a real weakening, and it is why the private key must never leave the machine |
| Never committed, never in a tfvars | `.gitignore` covers the usual names; the repository is public |
| The public key goes in `env/<env>.tfvars` as a *path*, never inline | Keeps the key file the single source of truth |

The passphrase exemption is the weak point of this policy. It is accepted because the key's only
route to the nodes is the tailnet, so possession of the key alone is not sufficient — an attacker
would also need tailnet membership.

### Rotating the SSH key

1. Generate the new pair.
2. Update `ssh_public_key_path` / `ssh_private_key_path` in the environment's tfvars.
3. `make cluster-apply ENV=<env>` — the module reconciles `authorized_keys` on every node.
4. Confirm access, then delete the old private key.

Note the module preserves keys it did not place, tracked in
`/root/.ssh/authorized_keys.kube-hetzner`. A key added by hand survives a reconcile — which is
convenient and is also exactly the kind of undocumented state ADR-0002 forbids. Do not add keys by
hand.

### Rotating the Tailscale auth key

Auth keys are used at join time only, so rotating one does not disconnect running nodes. Tailscale
is explicit about it — *"If an auth key expires, any device authorized by it remains authorized
until its node key expires"* — and revoking is no different: revoking a key does not deauthorize
the nodes that used it. So nothing degrades to warn you. A running cluster stays healthy right up
until somebody rebuilds it, and then no node joins at all (T-1.30, #350).

**The key lives in two places and both have to move.** Updating one and not the other produces a
cluster that builds locally and not in CI, or the reverse:

| copy | used by | how to set it |
|---|---|---|
| `TF_VAR_tailscale_auth_key` in `~/.xenopsbase.env` | local `make up` | edit the file, then `source ~/.xenopsbase.env` |
| the `TAILSCALE_AUTH_KEY` Actions secret | `plan (cluster)` in CI, which cannot run at all without it (T-1.17) | `bash infra/scripts/set-ci-secrets.sh`, which reads the environment you just sourced |

The procedure:

1. Admin console → **Settings → Keys** → *Generate auth key*, with the same settings as the
   first-time table above: **Reusable on, Ephemeral on**, 90 days.
2. Update `~/.xenopsbase.env`, then `source ~/.xenopsbase.env`.
3. `bash infra/scripts/set-ci-secrets.sh` — this is the copy that gets forgotten.
4. **Record the new expiry** in `tailscale_auth_key_expires_at` in
   `infra/terraform/cluster/env/<env>.tfvars`. Nothing recomputes this: the expiry is only visible
   in the console, and reading it from code would need a Tailscale API key the project does not
   hold (#290).
5. Revoke the old key. The next node to join uses the new one.

**What warns you.** `make preflight` (which `make up` runs first) compares the recorded date against
the clock: it prints the days remaining on every run, warns without blocking inside 30 days, and
refuses to apply once the date has passed. A date left stale by a rotation therefore reads as
expired and stops a build — the safe direction for a copy that nothing can verify against its
source. `TAILSCALE_KEY_WARN_DAYS` moves the warning window.

## Verifying what is actually exposed

A firewall that is *configured* is not the same as one that is *closed*. Reading the config back
proves what was requested, not what is true.

```bash
make verify-exposure
```

Raw TCP connects against every public address in the project. It asserts nodes answer nothing, and
that the load balancer answers only 80 and 443.

Until T-2.2 installs an ingress controller, `ingress_controller = "none"` and nothing serves 80/443.
Once it exists, require them rather than tolerate them:

```bash
make verify-exposure EXPECT_WEB=expect-web
```

Run from a machine that is **not** on the tailnet for the strongest result — a phone on mobile data
works. T-7.3 runs it from CI for exactly that reason.

## The escape hatch

Not in use. `dev` moved to tailscale transport on 2026-08-21; the hatch is kept for the outage it
was written for, not as the working configuration.

If Tailscale is unreachable and a cluster must be rebuilt, `node_transport_mode` can be switched
back to `hetzner_private`, which restores public API and SSH restricted to `firewall_source_cidrs`.

> **Only on a cluster you are building from nothing.** Changing `node_transport_mode` on a
> **running** cluster does not work and cannot be undone in place. Terraform replaces the firewall
> rules immediately but does **not** replace the servers, so 22 and 6443 close while no node has
> joined the tailnet — and there is no longer any path to the machines that are still running. The
> apply appears to succeed. Destroy and rebuild instead.

```hcl
node_transport_mode   = "hetzner_private"
firewall_source_cidrs = ["203.0.113.4/32"]
```

Validation refuses an empty list and refuses `0.0.0.0/0`, since an escape hatch as wide as no
firewall is not a hatch.

This exists because closing the front door introduces a dependency, and the alternative to a hatch
is waiting out someone else's outage. Two things to know:

- **It is a reviewable change, not a flag to flip casually.** It goes through a pull request like
  anything else.
- **Using it more than once is a signal.** ADR-0006 says to revisit the decision if that happens;
  needing the hatch repeatedly means the dependency is less reliable than the ADR assumed.

Switch back as soon as the outage ends, and re-run `make verify-exposure`.

## Troubleshooting

**The CCM crash-loops with `serverIsAttachedToNetwork ... context deadline exceeded`, and
only the control plane ever registers**

The cloud controller manager cannot reach the Hetzner metadata service:

```
Cloud provider could not be initialized: hcloud/newCloud:
checking if server is in Network not possible: serverIsAttachedToNetwork:
Get "http://169.254.169.254/hetzner/v1/metadata/private-networks": context deadline exceeded
```

The cause is routing, not the firewall. On the node:

```
$ ip route get 169.254.169.254
169.254.169.254 via 10.0.0.1 dev eth1 proto dhcp src 10.255.0.1 metric 30000
```

A DHCP-installed route sends metadata traffic over **eth1**, the Hetzner private network, where it
black-holes. Over **eth0** it answers immediately:

```
curl --interface eth0 http://169.254.169.254/hetzner/v1/metadata/private-networks  ->  200
curl                  (default route, eth1)                                       ->  timeout
```

The knock-on effects look nothing like a routing problem: the node keeps its
`node.cloudprovider.kubernetes.io/uninitialized` taint, nothing schedules,
`system-upgrade-controller` stays Pending, the kustomization step times out after 900s, and the
agents' k3s install never runs. Workers end up healthy but never joined.

Observed under **both** `tailscale` and `hetzner_private` transport, so it is not transport-specific.
Tracked in #84.

**Workers join the tailnet but never join Kubernetes, and the apply fails on
`system-upgrade-controller`**

Check `advertise_node_private_routes`. It must be `true`, which is the module default.

Setting it `false` looks harmless for a single-network cluster — `kube.tf.example` even suggests it
to avoid Tailnet route approvals. It also turns off the Hetzner network routing the cloud
controller manager depends on. The CCM then deploys with `HCLOUD_NETWORK_ROUTES_ENABLED=false` and
no `HCLOUD_NETWORK`, so it cannot match the private address the kubelet reports:

```
failed to get node address from cloud provider that matches ip: 10.255.0.1
```

From there the failure walks four steps away from its cause:

1. CCM refuses to initialise the node
2. The `node.cloudprovider.kubernetes.io/uninitialized` taint never lifts
3. Nothing can schedule, so `system-upgrade-controller` stays `Pending`
4. The kustomization step waits 900s for it, times out, and the **agents' k3s install never runs**

The visible symptom is workers sitting healthy on the tailnet having never joined the cluster, and
an error about an upgrade controller. Nothing in that mentions routing.

Confirm with:

```bash
kubectl -n kube-system get deploy hcloud-cloud-controller-manager \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'
```

`HCLOUD_NETWORK` must be present. If it is missing, this is the cause.

**Nodes boot but never become Ready, and Terraform hangs**
Almost always the Tailscale auth key. Check it is **reusable** and not expired — a single-use key
registers the first node and leaves the others waiting forever, and an expired one admits no node
at all. `make preflight cluster` answers the expiry half before an apply starts; the Tailscale admin
console shows which machines joined.

**`terraform apply` cannot reach nodes at all**
The machine running Terraform is not on the tailnet, or Tailscale is not running on it. There is no
public SSH to fall back to; that is the design.

**`kubectl` times out**
The kubeconfig points at the control plane's tailnet address. It only resolves on the tailnet, and
only while the cluster is up.

**`verify-exposure` reports a node port OPEN**
A real finding. Check whether `node_transport_mode` was left as `hetzner_private` from an escape
hatch that was never reverted.
