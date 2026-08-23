# Service level objectives

**Task:** T-5.6 (#45)

Numbers to regress against, rather than opinions about performance. Every figure here was
measured; nothing is aspirational.

```bash
make load ENV=dev
```

k6 runs **inside the cluster** against the gateway Service. The thresholds live in
`infra/load/baseline.js` and k6 exits non-zero when one is breached, so these objectives are a gate
rather than a paragraph. A load test whose result is a number somebody reads is a load test nobody
reads.

## The objectives

| Path | p95 | p99 | Error rate |
|---|---|---|---|
| **Gateway only** — `/api/auth-info`, no downstream call | < 50 ms | < 100 ms | < 1% |
| **Through core** — `/services/core/api/documents`, gateway → core → Postgres | < 200 ms | < 400 ms | < 1% |

Set at roughly **2.5× the measured p95 and 3× the measured p99**. Tight enough that a doubling
fails; loose enough to survive a noisy afternoon. A threshold set at the measured value fails on a
quiet Tuesday and then gets deleted, which is worse than not having one.

## Measured baseline

2026-08-23, dev sizing: 1 control plane (2 vCPU) and 2 workers (4 vCPU each), gateway at 2
replicas, core at 1.

```
run 1 (cold)   122,255 requests   0 failed   568 req/s
run 2 (warm)   164,813 requests   0 failed   766 req/s
```

| Run | | avg | med | p95 | p99 | max |
|---|---|---|---|---|---|---|
| 1, cold | Gateway only | 7.6 ms | 5.7 ms | **19.8 ms** | **34.3 ms** | 162 ms |
| 1, cold | Through core | 48.4 ms | 43.7 ms | **92.2 ms** | **129.6 ms** | 1.23 s |
| 2, warm | Gateway only | 5.6 ms | 4.2 ms | 14.2 ms | 23.8 ms | 89 ms |
| 2, warm | Through core | 34.3 ms | 30.9 ms | 65.2 ms | 91.8 ms | 271 ms |

Two runs, twenty minutes apart, same cluster and same sizing. The second was **35% faster at p95
and 30% higher in throughput** — 766 req/s against 568 — purely from the JVMs being warm and the
connection pools full.

That spread is why the thresholds are set against the **cold** run. A gate calibrated to the warm
numbers would fail every time the pods had recently restarted, which is exactly when someone is
already looking at something else.

**The gap between the two scenarios is the whole point.** The gateway answers in ~20 ms at p95
cold; adding core, Hibernate and Postgres costs ~72 ms more. That is why there are two scenarios and not one —
a single aggregate number cannot tell you whether a slowdown is the gateway or the database, and
that is the first question anyone asks.

The 1.23 s maximum on `through_core` is the first request of the run: JIT warmup and a cold
connection pool. It is not in p99 and it is not a defect, but it is the reason a readiness probe
should not be the first thing to hit a fresh pod.

Resource cost at that rate:

| | Peak CPU | Peak heap |
|---|---|---|
| gateway pod 1 | 1.99 cores | — |
| gateway pod 2 | 1.50 cores | 199 MiB (both) |
| core | 1.72 cores | 115 MiB |
| k6 itself | 0.63 cores | — |

## What this says about autoscaling (T-2.8, #22)

This is the number #22 has been waiting for, and it is not the one anyone expected.

**CPU requests are 200m. Real usage under load is 1.5–2.0 cores.** That is a 7–10× overshoot, and
there are **no CPU limits at all**, so pods burst freely into whatever the node has spare.

A HorizontalPodAutoscaler targeting CPU utilisation computes `usage / request`. At these values:

```
1990m / 200m  =  995% utilisation
```

An HPA with the conventional 70% target would see 995% and scale to its maximum instantly, on load
the current two replicas absorb comfortably. **CPU-based autoscaling is meaningless here until the
requests describe reality**, and fixing the requests is a prerequisite for #22 rather than part of
it.

Two workers with 4 vCPU each is 8 cores total. Peak observed demand across gateway, core and the
load generator was about 5.8 cores, so this run was using most of the cluster — worth knowing
before anyone reads 568 req/s as headroom.

The honest recommendation for #22: **set requests from these measurements first**, then pick an HPA
target, then re-measure. Do not pick a target against requests that are wrong by an order of
magnitude.

## What is deliberately not measured

**The edge.** Cloudflare, the tunnel and ingress-nginx are excluded. `smoke.sh` asserts that path
works; nobody has measured what it costs. Two reasons: the number this exists to produce is an
autoscaling threshold, and an HPA scales on pod CPU — measuring through Cloudflare answers a
different question and answers it worse, because the edge's variance swamps the application's. And
sustained load through Cloudflare's free tier to benchmark our own pods would eventually, fairly,
be treated as abuse.

**Writes.** Both scenarios are reads. The upload path ends in a presigned PUT straight to Hetzner
object storage, so a write benchmark would mostly measure Hetzner's latency from a Hetzner node and
attribute it to this application. Worth doing deliberately, as its own scenario, with that caveat
stated.

**Sustained load.** 105 seconds per scenario. Long enough for JIT and the connection pool to settle,
far too short to say anything about memory growth, connection leaks or anything else that appears
in hour four.

**Anything but dev.** Staging and prod do not exist (#194), and these numbers are specific to this
sizing.

## Scheduled regression runs

Not yet, and the reason is structural rather than a missing workflow.

`make load` drives k6 **inside** the cluster, and CI cannot reach the cluster: the Kubernetes API is
a tailnet address with 6443 closed on every public IP (T-1.5). That is the same constraint that
stops `rollout-status` running in CI, recorded as
[#195](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/195), and a scheduled load run
lands the moment that is solved.

Running it from a GitHub runner through the public edge would work today and would measure the
wrong thing, for the reasons above. Tracked as
[#207](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/207).

## What these numbers unblock

- **#22 — autoscaling.** See above; the finding is that requests must be fixed first.
- **#127 — caching.** Deferred on the grounds that nobody should size a cache without a baseline.
  There is one now: reads through core cost ~92 ms at p95, of which ~72 ms is behind the gateway.
- **#32 — resilience.** Its timeouts — 2 s connect, 10 s response, a 12 s time limiter, a bulkhead
  of 50 — were reasoned rather than measured, and recorded as such. Against a p99 of 130 ms, a 10 s
  response timeout is roughly 75× the observed worst case: safe, and so far from reality that it
  would not shed load before something else fell over. Worth revisiting with these numbers.
