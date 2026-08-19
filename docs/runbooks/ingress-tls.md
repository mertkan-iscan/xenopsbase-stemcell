# Runbook: ingress and TLS

How a request from the internet reaches a pod, and how certificates are issued.

## The serving path

```
browser
  -> Cloudflare edge          terminates the client's TLS, using Cloudflare's cert
  -> tunnel                   no inbound port; cloudflared dialled OUT to establish this
  -> cloudflared (in cluster) 2 replicas, ingress-nginx namespace
  -> ingress-nginx            routes by Host header to a Service
  -> your pod
```

**Nothing listens publicly.** There is no load balancer, no public port, and no inbound firewall
rule for application traffic. Cloudflare receives the request and hands it down a connection the
cluster itself opened. That is [ADR-0006](../adr/0006-network-exposure.md) applied to application
traffic rather than to the control plane, and it is why `make verify-exposure` expects the nodes to
answer nothing.

DNS is a CNAME to `<tunnel-uuid>.cfargotunnel.com`. The UUID belongs to the tunnel, not the
cluster, so **rebuilding the cluster does not change DNS**.

## Reading the response codes

This is the part that misleads. Both a working path and a broken one can return 404.

| What you see | What it means |
|---|---|
| `404` with a body ending `<hr><center>nginx</center>` | **Working.** Reached ingress-nginx, which has no Ingress for that host yet. |
| `404` with a short Cloudflare body | Reached the tunnel, but its ingress rules did not match — served by the tunnel's own catch-all. |
| `530` | Cloudflare has DNS for the host but the tunnel does not route it, or no connector is registered. |
| `502` / `504` | Reached ingress-nginx, which could not reach the backend Service. |

**The status code alone does not tell you whether traffic entered the cluster**, because the tunnel's
required catch-all rule is itself `http_status:404`. Only the body distinguishes them. Check it:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://app-dev.xenopsoftware.com
curl -sS https://app-dev.xenopsoftware.com | tail -3     # the part that actually decides
```

An unrouted hostname returning 530 while the real one returns an nginx 404 is the cheapest proof the
whole chain is live.

## cloudflared needs outbound UDP 7844

cloudflared reaches Cloudflare over **QUIC on UDP 7844**, with **TCP 7844** as the documented
fallback. Both are opened in `infra/terraform/cluster/env/<env>.tfvars` via `extra_firewall_rules`.

On Hetzner, defining **any** outbound rule denies everything not listed, and the module's defaults
cover only 80, 443, DNS, NTP and ICMP. So QUIC is blocked unless it is named explicitly.

The failure does not look like a firewall:

```
Failed to dial a quic connection: timeout: no recent network activity
```

cloudflared **retries with backoff rather than exiting**, so the pods stay `Running`, Argo CD reports
the Application `Healthy`, and the site simply never comes up. Nothing goes red. If connectors never
register, check the firewall before anything else:

```bash
kubectl -n ingress-nginx logs -l app.kubernetes.io/name=cloudflared --tail=20
hcloud firewall describe xenopsbase-dev
```

## Certificates

cert-manager issues over **DNS-01 through Cloudflare**, not HTTP-01. DNS-01 is required here: HTTP-01
needs Let's Encrypt to reach an inbound listener, and there isn't one. DNS-01 also permits wildcards.

The Cloudflare API token is SOPS-encrypted in `platform/envs/dev/secrets/cloudflare-api-token.yaml`
([ADR-0003](../adr/0003-secrets-management.md)).

Two ClusterIssuers:

| Issuer | Use |
|---|---|
| `letsencrypt-staging` | dev. Untrusted by browsers, but effectively no rate limit. |
| `letsencrypt-prod` | staging and prod. **5 duplicate certificates per week.** |

**Dev uses staging on purpose.** A rebuild loop against the production endpoint exhausts the weekly
limit in an afternoon, and the lockout outlasts the mistake.

Issue one:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example
  namespace: default
spec:
  secretName: example-tls
  issuerRef:
    name: letsencrypt-staging      # prod only outside dev
    kind: ClusterIssuer
  dnsNames:
    - example.xenopsoftware.com
```

Watch it, and confirm who signed it rather than trusting `Ready`:

```bash
kubectl get certificate example -w
kubectl get secret example-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -dates
```

Issuance takes **60-120 seconds**, most of it DNS propagation. `Issuing certificate as Secret does
not exist` is the normal in-progress message, not an error.

### Debugging a stuck certificate

Work down the chain — each object explains the one above it:

```bash
kubectl describe certificate <name>
kubectl describe certificaterequest        # created by the Certificate
kubectl describe order                     # created by the CertificateRequest
kubectl describe challenge                 # where DNS-01 actually fails
kubectl -n cert-manager logs -l app=cert-manager --tail=50
```

Almost every real failure is at the challenge: the API token lacks `Zone:DNS:Edit`, or it is scoped
to the wrong zone.

## Certificates and rebuilds

Certificates live in etcd, which **a cluster rebuild destroys**. cert-manager reissues them
automatically from the `Certificate` resources in git, so nothing needs restoring — this is
[ADR-0002](../adr/0002-durable-state-boundary.md) working as intended: the cluster is disposable
because nothing durable is kept only inside it.

The cost is rate limit, not data. In dev that is free, because dev uses the staging issuer. **In
production, repeated rebuilds within a week can exhaust the 5-duplicate-certificate limit** and leave
the site serving an expired or missing certificate until the window rolls. If prod rebuilds are ever
expected to be routine, the certificate Secret must be backed up and restored rather than reissued.

Tracked as part of the cold-rebuild drill (T-7.2), which is where rebuild timing is measured properly.

## Known gaps

**No origin certificate yet.** Cloudflare terminates the client's TLS with its own certificate, so the
hop from cloudflared to ingress-nginx is currently plain HTTP inside the cluster network. That is
acceptable while the cluster is a trust boundary, and stops being acceptable under T-8.2's
default-deny and any real multi-tenancy.

**No Ingress resources exist.** The path is verified, but nothing is served — a 404 from nginx is the
correct answer until the first application lands (T-3.3).
