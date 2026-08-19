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
3. Admin console → **Settings → Keys** → *Generate auth key*. It must be **Reusable**. A single-use
   key registers only the first node; the rest hang waiting to join, which looks like a network
   fault rather than a key problem.
4. Admin console → **DNS** → note the **tailnet name**, e.g. `tail1a2b3c.ts.net`.

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

Auth keys are used at join time only, so rotating one does not disconnect running nodes. Generate a
new reusable key, update `TF_VAR_tailscale_auth_key`, and revoke the old one. The next node to join
uses the new key.

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

If Tailscale is unreachable and a cluster must be rebuilt, `node_transport_mode` can be switched
back to `hetzner_private`, which restores public API and SSH restricted to `firewall_source_cidrs`.

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

**Nodes boot but never become Ready, and Terraform hangs**
Almost always the Tailscale auth key. Check it is **reusable** and not expired — a single-use key
registers the first node and leaves the others waiting forever. The Tailscale admin console shows
which machines joined.

**`terraform apply` cannot reach nodes at all**
The machine running Terraform is not on the tailnet, or Tailscale is not running on it. There is no
public SSH to fall back to; that is the design.

**`kubectl` times out**
The kubeconfig points at the control plane's tailnet address. It only resolves on the tailnet, and
only while the cluster is up.

**`verify-exposure` reports a node port OPEN**
A real finding. Check whether `node_transport_mode` was left as `hetzner_private` from an escape
hatch that was never reverted.
