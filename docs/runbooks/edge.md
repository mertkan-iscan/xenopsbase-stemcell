# Runbook: the edge (Cloudflare DNS and tunnel)

Traffic reaches the cluster through a **Cloudflare Tunnel**. `cloudflared` runs inside the cluster
and dials *out*; nothing listens publicly.

```
browser ──TLS──▶ Cloudflare edge ──mTLS tunnel──▶ cloudflared (in cluster) ──▶ ingress ──▶ app
```

## Why a tunnel rather than a load balancer

Three reasons, in order of how much they matter here:

**The DNS record never changes.** It is a CNAME to `<tunnel-id>.cfargotunnel.com`, and the tunnel
UUID is stable across cluster rebuilds. Pointing DNS at a Hetzner load balancer would mean
rewriting the record on every rebuild — and a propagation window on every one of them. In a design
whose normal operating mode is destroy-and-rebuild, that is a recurring outage rather than a
one-off.

**There is no load balancer to pay for.** An `lb11` bills continuously, including while the cluster
is destroyed. That is a direct hit on the near-zero-when-idle constraint ADR-0002 is built on.

**There is nothing public left to defend.** ADR-0006 closed the control plane; the tunnel closes
the application path. The cluster has no inbound listener at all.

The cost: Cloudflare is on the serving path, `cloudflared` becomes a platform component (T-2.2),
and the tunnel token becomes a third bootstrap secret alongside the age key (ADR-0003) and the
Hetzner credentials.

This is the pattern `hedportal-terraform` already runs in production; it is lifted rather than
invented.

## Hostname convention

| Environment | Hostname |
|---|---|
| prod | `app.xenopsoftware.com` |
| staging | `app-staging.xenopsoftware.com` |
| dev | `app-dev.xenopsoftware.com` |

Hyphens, not extra dots. Cloudflare's Universal SSL certificate covers the apex and `*.example.com`
— **one label only**. `dev.app.xenopsoftware.com` would need Advanced Certificate Manager, which is
paid. A variable validation rejects any hostname deeper than one label so this is caught at plan
time rather than as a certificate error in a browser.

## ⚠️ This is a shared company zone

`xenopsoftware.com` hosts a live company site. Two of T-1.6's original criteria — TLS mode and WAF —
are **zone-wide**: Cloudflare has no per-hostname TLS setting.

Both are therefore **off by default**:

| Variable | Default | Why |
|---|---|---|
| `manage_zone_settings` | `false` | Setting the zone to Full (strict) requires *every* origin in the zone to present a valid publicly-trusted certificate. If the company site runs on Flexible or Full-not-strict, flipping this breaks it immediately, for everyone |
| `manage_waf` | `false` | WAF rules are zone-scoped. A rule written for this project still evaluates against every request to the company site, and a wrong one blocks real customers |

**Tunnelled traffic does not need Full (strict) anyway.** `cloudflared` makes an outbound mTLS
connection to Cloudflare's edge, so the origin leg is already authenticated and encrypted whatever
the zone's TLS mode says. Full (strict) protects origins reached over the public internet — which a
tunnelled origin is not.

So for this project the setting is optional; for the rest of the zone it may be breaking. That
asymmetry is the whole reason it is opt-in.

If you do enable them, every WAF rule written here is explicitly anchored to `http.host eq
"<hostname>"` so it cannot affect anything else in the zone.

## First-time setup

You need a Cloudflare API token — **not** the R2 one, which is object-storage scoped and cannot
touch DNS. Create it under **My Profile → API Tokens**, scoped to this zone:

| Permission | Needed for |
|---|---|
| Zone / DNS / Edit | the CNAME |
| Account / Cloudflare Tunnel / Edit | creating the tunnel |
| Zone / Zone Settings / Edit | only if `manage_zone_settings = true` |

```bash
export TF_VAR_cloudflare_api_token="..."
```

Then the account and zone IDs, which are identifiers rather than secrets but still stay out of a
public repo:

```bash
cp infra/terraform/edge/env/secrets.tfvars.example infra/terraform/edge/env/dev.secrets.tfvars
```

Fill in `account_id` (dashboard sidebar) and `zone_id` (zone overview page), then:

```bash
make edge-init ENV=dev && make edge-plan ENV=dev
```

**Read that plan carefully.** It should create exactly three things: a tunnel, its config, and one
DNS record. If it proposes to touch zone settings or a ruleset, `manage_zone_settings` or
`manage_waf` is set when it should not be.

```bash
make edge-apply ENV=dev
```

## Handing the token to the cluster

`cloudflared` needs the connector token. It is a Terraform output, marked sensitive:

```bash
cd infra/terraform/edge && terraform output -raw tunnel_token
```

T-2.2 wires this into the cluster as a SOPS-encrypted secret (ADR-0003) rather than passing it
around by hand. Until then the tunnel exists but nothing connects to it, which is harmless — an
ingress rule is inert until something is on the other end.

## Checking it works

```bash
cd infra/terraform/edge && terraform output dns_target
```

Should be `<tunnel-id>.cfargotunnel.com`.

```bash
dig +short app-dev.xenopsoftware.com
```

Returns Cloudflare edge addresses, not the tunnel target — the record is proxied, which is what
makes a tunnel reachable at all and what terminates TLS for the client.

Before `cloudflared` is running, the hostname returns a Cloudflare error (usually 530). That is
correct: DNS points at a tunnel with no connector attached yet.

## Troubleshooting

**Terraform wants to recreate the tunnel on every plan**
`tunnel_secret` is generated by Cloudflare and cannot be read back. The resource carries
`ignore_changes = [tunnel_secret]` for this. If it was removed, every apply would produce a new
tunnel ID — and therefore a new DNS target and an outage.

**Hostname returns 530**
No connector attached. Expected until T-2.2 deploys `cloudflared`.

**Hostname returns 404**
The tunnel is connected but no ingress rule matched, so the catch-all answered. Check
`tunnel_service` points at a service that actually exists in the cluster.

**Certificate warning in the browser**
The hostname is probably more than one label below the apex, so Universal SSL does not cover it.
See the hostname convention above.
