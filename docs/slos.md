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

This is the number #22 was waiting for, and it was not the one anyone expected.

**Real usage under load is 1.5–2.0 cores per pod.** There are **no CPU limits at all**, so pods
burst freely into whatever the node has spare, and the requests are a scheduling floor rather than
an estimate of demand.

A HorizontalPodAutoscaler computes `usage / request`. When this was first measured the requests
were 200m, which made the arithmetic absurd:

```
1990m / 200m  =  995% utilisation
```

An HPA with the conventional 70% target would have seen 995% and pinned itself to maxReplicas on
load that two replicas absorbed comfortably.

**Requests were raised to 500m in T-2.15**, which changes the arithmetic but not the shape of the
problem:

```
1990m / 500m  =  398% utilisation
```

Still nothing like 70%. The conclusion that mattered survived the change: **the request is a floor,
not a forecast, so an HPA target expressed as a percentage of it cannot use a conventional number.**

### What #22 did with this

Targets are set at **`averageUtilization: 200`** — 200% of a 500m request is 1 core, about half of
what one pod was measured sustaining. A replica is added while the existing ones still have headroom
to cover the ~15 s a new JVM needs before it is worth having.

The ceilings come from this page too. Two workers with 4 vCPU each is 8 cores total, and peak
observed demand across gateway, core and the load generator was about 5.8 — so this run was already
using most of the cluster. `maxReplicas` is 4 for the gateway and 3 for core because beyond that the
useful lever is cluster-autoscaler adding a node, not more pods contending for the same ones.

**These targets are a ratio to a 500m request and nothing enforces that relationship.** If the
requests change again, re-derive them from a fresh run of this page rather than scaling the number
by eye. That is the mistake this section exists to prevent, and it has now nearly been made twice.

**Done, in T-2.15 (#209).** gateway and core now request `500m` — about 55 req/s of booked capacity
each, at the measured ~110 req/s per core. Not the idle figure, which would have the scheduler treat
a serving pod as free, and not the synthetic peak, which would reserve half the cluster for pods
that spend most of their life at 6 millicores. The measured peak now reads as ~400% rather than
995%, which is a number an HPA target can be chosen against.

Memory requests went up too, and that was the sharper problem: the gateway requested 512Mi while
using **490 MiB**, so the scheduler was booking less than the pod actually needs and could evict it
for using exactly that.

## Scalability — where it stops (T-5.10)

```bash
make scale-test ENV=dev
```

`make load` uses a closed model — 10 fixed VUs, so a slow response slows the generator with it and
the offered rate collapses to whatever the system can serve. A closed model cannot overload
anything. `make scale-test` offers a fixed req/s regardless of latency, which is the only way a
ceiling becomes visible. It also samples replica counts, HPA utilisation and CPU from outside the
cluster and joins the two timelines; charts land in `report.html` beside the text report.

### A retraction, and what it cost

**The first run of this test, on 2026-08-27, reported a collapse to zero throughput above 800 req/s
and blamed the gateway's circuit breaker. That finding was wrong and has been withdrawn.**

The harness fetched one access token in `setup()` and reused it for a 26-minute run against a realm
whose `accessTokenLifespan` is 300s. From roughly t+360s — the nominal expiry plus Spring's 60s
clock-skew tolerance — every authenticated request was a **401**. The gateway's own counters settle
it: 276,535 401s against 3,967 `/fallback/core` 503s on a single pod.

**An expired credential is indistinguishable from saturation in every aggregate metric**, and it
lies in the reassuring direction:

| what a reader sees | what it looked like | what it was |
|---|---|---|
| throughput to zero | the system stopped coping | requests rejected at the security filter |
| p95 *improving* to 1.2 ms | nothing left to be slow | a 401 is cheap |
| core CPU at 16m across 3 replicas | the breaker cut traffic off | the gateway never forwarded any |
| Postgres connections falling | pools drained | no queries were issued |

The corroborating detail nobody looked for at the time: the `gateway_only` scenario ran *after* the
expiry and showed **0% errors throughout**, because `/api/auth-info` is `permitAll` and carries no
token. One path failing totally while an unauthenticated path on the same pods stayed clean was
already the answer.

Two changes make the failure structural rather than a thing to remember. The harness now holds one
refresh token and each VU redeems it independently, so a run of any length keeps valid credentials —
and it must be a *refresh* grant, because the realm sets `bruteForceProtected: true` and Keycloak's
quick-login check treats concurrent password grants for one user as an attack, answering correct
credentials with `invalid_grant`. And the report now counts 401/403 separately from 5xx and
**refuses to call an auth-failed step saturated**, printing `NOT A CAPACITY RESULT` against it.

### The measured curve

Measured 2026-08-27 with the corrected harness. Dev sizing: 1 control plane (cx23), 2 workers
(cx33, 3700m allocatable each), gateway floor 2, core floor 1.

| offered | **served** | p50 | p95 | p99 | 5xx | auth | replicas gw/core |
|---:|---:|---:|---:|---:|---:|---:|---|
| 400 | **400** | 6.2 ms | 13.7 ms | 23.7 ms | 0% | 0% | 2 / 1 |
| 800 | **757** | 9.0 ms | 35.7 ms | 74.1 ms | **5.4%** | 0% | 2 / 1→3 |
| 1200 | **584** | 7.3 ms | 70.6 ms | 141.8 ms | **51.3%** | 0% | 2 / 1→3 |
| 1600 | **154** | 3.9 ms | 57.5 ms | 148.1 ms | **90.4%** | 0% | 2→3 / 3 |
| 2000 | **318** | 5.7 ms | 67.2 ms | 129.7 ms | **84.1%** | 0% | 3 / 3 |

**Clean read capacity is 400 req/s. The knee is at 800.** `auth` is 0% at every step, which is the
column that makes the rest of the table trustworthy.

**Throughput goes backward past the knee, and that is the finding.** 400 offered serves 400. 1600
offered serves **154** — offering four times the load produces less than half the useful work the
system does when it is not overloaded. That is congestion collapse, not a ceiling. A ceiling would
hold 400 req/s and reject the rest.

Latency looks *better* at 1600 than at 1200 (p95 57 ms against 70 ms) for the reason the report
prints in capitals: 90% of those responses are errors, and an error is quick.

### Why no node was ever added

The cluster-autoscaler is enabled and never fired. Pending pods peaked at **0** and the node count
stayed at 3 for the whole run — and that is structural rather than bad luck:

| | |
|---|---|
| pod CPU **request** | 500m — a scheduling floor, deliberately below real usage (T-2.15) |
| pod CPU **actual** under load | 1000–2000m |
| booked at full HPA scale-out | 3500m app + ~2145m platform + 1000m k6 = **6645m of 7400m** |

Every replica the HPA asked for fit, so no pod was ever unschedulable, so nothing asked for a node.
**The cluster-autoscaler reacts to bookings; the saturation is in usage. The two never meet.** At
the knee the useful lever is a new node — exactly as the HPA ceiling comment in `hpa.yaml` says —
and there is no path by which anything in this system requests one.

That is worth stating plainly because the comment in `hpa.yaml` assumes the handoff works:
"beyond this the useful lever is cluster-autoscaler adding a node, not more pods contending for the
same ones." The lever exists. Nothing pulls it.

### What a request costs

| path | CPU per request | req/s per core |
|---|---:|---:|
| gateway alone, `permitAll` | 1.17m | **~850** |
| full read path at 400 req/s | 4.95m | **~200** |

The absolute 400 req/s is a property of this cluster — 2 workers, 7400m allocatable, shared with
Postgres, Keycloak, the LGTM stack, Argo and ingress. **~200 req/s per core is the portable number,
and it is the floor rather than the result: there is no business logic in this repository yet.**
Every feature added comes out of that budget.

### Why throughput goes backward: measured, not inferred

Three hypotheses were tested against this cluster. **Two were wrong**, and they are recorded here
because the wrong ones cost more time than the right one.

**Tracing overhead — DISPROVEN.** `TRACING_SAMPLE_PROBABILITY` defaults to `1.0` in
`application-prod.yml` for both services and nothing in `platform/` overrides it, so every request
does produce spans in both services. It costs nothing measurable. An A/B at 400 req/s, both arms
rolled out fresh and warmed by a preceding 200 req/s step, at identical replica counts:

| arm | gateway | core | total | per request |
|---|---:|---:|---:|---:|
| sampling `1.0` | 1177m | 761m | 1939m | **4.85m** |
| sampling `0.01` | 1191m | 843m | 2034m | **5.08m** |

Mean CPU across the measured window, not peak. The 1% arm used *more*, which means the difference is
noise. (This says nothing about the OTLP exporter *failing* under overload, which was observed and
is a separate cost.)

**Retry amplification — DISPROVEN.** The `core` route retries GETs twice on `SERVER_ERROR`, so the
obvious theory is that errors triple the downstream load. They do not. Over a run offering 209,740
requests, core received **84,350** — 0.40x, not 3x. The gateway was rejecting most traffic without
forwarding it, so retries never got the chance to amplify anything.

**The circuit breaker's window is sized for a different service — CONFIRMED.** The gateway's own
Resilience4j counters over that same run:

| | count |
|---|---:|
| forwarded to core, successful | 84,350 (matches core's own counter exactly) |
| **short-circuited, never forwarded** | **133,931** |
| actually failed | 457 |
| **slow calls (>5s)** | **0** |

**457 real failures produced 133,931 rejections — 293 requests discarded per failure.**

The mechanism is the window, not the thresholds. `slidingWindowType: COUNT_BASED` with
`slidingWindowSize: 20` was chosen for a stated and correct reason: a time-based window on a
low-traffic service never accumulates enough calls to decide anything. But **at 1200 req/s, 20 calls
is 17 milliseconds of traffic.** One GC pause fills it, the failure rate crosses 50%, and the
breaker opens for `waitDurationInOpenState: 10s` — six hundred times the span of traffic that made
the decision. `permittedNumberOfCallsInHalfOpenState: 5` then probes a service that is still busy,
half of them fail, and it reopens.

That is the collapse. The system oscillates between serving and serving *nothing*, and the average
lands at the 22% seen at 1200 req/s. It is not that core cannot cope — core failed 457 times out of
219,000 and `slow` never incremented once. **The gateway discarded 134,000 requests to protect a
downstream that was very nearly fine.**

The bulkhead that might have shed load proportionally instead of all-or-nothing is the one described
below: it is inert and has never limited anything.

### The window fix, and what it did not fix

The breaker was re-tuned on the strength of the measurement above — `TIME_BASED` over 10s,
`minimumNumberOfCalls: 20`, `waitDurationInOpenState: 2s`,
`permittedNumberOfCallsInHalfOpenState: 20`, `slowCallDurationThreshold: 1s`. Verified live by
`resilience4j_circuitbreaker_buffered_calls` reading **1763** where the old `COUNT_BASED` config
caps it at 20.

| offered | served **before** | served **after** | 5xx before | 5xx after |
|---:|---:|---:|---:|---:|
| 400 | 400 | 400 | 0% | 0% |
| 800 | 757 | 768 | 5.4% | 3.9% |
| 1200 | 584 | 580 | 51.3% | 51.6% |
| 1600 | **154** | **901** | 90.4% | 43.5% |
| 2000 | 318 | 570 | 84.1% | 71.4% |

**The pathology is gone.** Throughput no longer runs backward: 1600 req/s served 154 before and
serves 901 now, a 5.8x recovery, and the diagnosis that the window was the mechanism is confirmed.

**Graceful degradation is not achieved, and it would be dishonest to file this as fixed.** Above the
knee the stack still fails 43-71% of requests, 1200 req/s is unchanged within noise (584 -> 580),
and the knee itself has not moved off 800.

**Latency at the knee got worse, which is the trade this fix makes:**

| at 800 req/s | before | after |
|---|---:|---:|
| p95 | 35.7 ms | 186.3 ms |
| p99 | 74.1 ms | **715.8 ms** |

A breaker that sheds less queues more. The p99 at 800 req/s now breaches the 400 ms objective — but
800 is already double the supported 400 req/s, where p95 is 17 ms and the objectives hold
comfortably. The composition of calls moved the same way: short-circuited fell from 61% to 37% of
traffic while **real failures rose from 0.2% to 8.6%**. The old config over-protected core; this one
under-protects it at extreme overload.

**What is actually missing is a concurrency limit, and it is missing because the bulkhead is
inert** (see below). A circuit breaker is a binary control -- all traffic or none -- so it can only
ever choose between over- and under-protecting. Nothing in the gateway caps in-flight calls, so
there is no mechanism that serves the ~750 req/s the stack can handle and rejects only the excess.
That is the shape graceful degradation needs, and no amount of re-tuning a breaker produces it.

### Gateway only — no downstream call

This scenario was never affected by the token problem and its numbers stood through the retraction:

| offered | **served** | p50 | p95 | p99 | errors | gw replicas |
|---:|---:|---:|---:|---:|---:|---|
| 500 | **500** | 1.4 ms | 2.9 ms | 5.1 ms | 0% | 2 |
| 1500 | **1500** | 1.2 ms | 2.9 ms | 6.2 ms | 0% | 2 |
| 3000 | **3000** | 1.4 ms | 6.3 ms | 13.4 ms | 0% | 2→3 |
| 4500 | **4468** | 4.6 ms | 27.9 ms | 53.6 ms | 0% | 3→4 |

The gateway on its own serves **3000 req/s at a 6 ms p95 with no errors**, and still serves 99.3% of
4500. It is not the constraint. A caveat that is not a footnote: k6 peaked at **1371m** on a worker
under test, so the top step is a lower bound — some of that 27.9 ms is contention with the generator.

### Autoscaling, observed rather than derived

T-2.8's targets were arithmetic against a T-5.6 measurement, rehearsed on a throwaway local k3s.
This is the first time either HPA has been watched governing this cluster under real traffic, and
this part of the first run is unaffected by the token problem — replica counts were sampled from the
cluster, not inferred from the load.

| | |
|---|---|
| core scale-up | 1→2 at t+302s, 2→3 at t+383s, peak utilisation 256% |
| core scale-down | 3→2 at t+998s, 2→1 at t+1185s — the 600s window, honoured |
| gateway scale-up | 2→3 at 3000 req/s, 3→4 at 4500, peak utilisation 290% |
| Pending pods | **0** at every point — every replica the HPA asked for was schedulable |
| nodes | 3 throughout; the cluster-autoscaler was never needed |

### The connection budget, measured for the first time

`make connection-budget` adds up declared ceilings and says outright that it does not measure. Under
load, at core's HPA ceiling of 3 replicas:

| | declared | **observed peak** |
|---|---:|---:|
| core (3 × pool of 12) | 36 | **27** |
| keycloak | 15 | **2** |
| total against `max_connections: 100` | 62 | **40** |

The arithmetic holds, with room.

### Two findings that survived verification

**The bulkhead has never limited anything.** `resilience4j.bulkhead.instances.core` declares
`maxConcurrentCalls: 50` and carries a comment about preventing one slow service from consuming the
gateway. The pod's own metrics say it has never been asked for a permit:
`resilience4j_bulkhead_available_concurrent_calls` sat at **50.0 of 50.0** through a run that pushed
2000 req/s at it.

> **The mechanism given for this was wrong, and is retracted (T-5.11).** T-5.10 attributed it to
> "the reactive Spring Cloud CircuitBreaker implementation does not apply Resilience4j bulkheads at
> all". It does. See [the retraction below](#the-bulkhead-was-never-unwired-t-511).

**The fallback tells the caller something it cannot know.** `FallbackResource` returns a fixed
message — "its circuit is open. The request was not forwarded, so it had no effect" — for every
reason the CircuitBreaker filter falls back, including the 12s TimeLimiter firing. A timed-out
request may well have reached core and committed. "It had no effect" is the one part of that body a
caller acts on, and it is not always true.

> **Fixed in T-5.11.** The body is now derived from the actual cause, and `BulkheadIT` asserts that
> a timed-out request is not described as having had no effect.

## Concurrency limiting (T-5.11)

T-5.10 ended with the right target and the wrong reason for it. The breaker re-tuning stopped
throughput running backward but left 43–71% errors above the knee, and the conclusion was that a
binary control cannot do better: a circuit breaker serves everything or nothing, so it can only
choose between over- and under-protecting core. What is needed is a limit on **calls in flight**,
which serves what the stack can handle and refuses only the excess. That is the bulkhead's job.

### The bulkhead was never unwired

**Retracted:** *"Spring Cloud Gateway is reactive, and the reactive Spring Cloud CircuitBreaker
implementation does not apply Resilience4j bulkheads at all."*

It applies them. On the pinned spring-cloud 2025.1.3,
`ReactiveResilience4JCircuitBreaker.run()` calls
`ReactiveResilience4jBulkheadProvider.decorateMono(groupName, …)`, and
`ReactiveResilience4JCircuitBreakerFactory.create(id)` sets the group name **to the id** — so the
route filter's `name: core` resolves the bulkhead instance named `core`, which is the one declared
in `application.yml`. `ReactiveBulkheadWiringTest` asserts that whole path against the real upstream
classes, so the correction is re-checked on every build rather than resting on a reading of the
source.

The metric was not lying; the inference from it was. **50 concurrent calls per pod is above any
concurrency this stack has ever reached.** Little's Law on the T-5.10 curve — `N = throughput ×
latency`:

| step | served | p50 | in-flight, whole tier |
|---:|---:|---:|---:|
| 400 req/s | 400 | 7.2 ms | ~4 |
| 800 req/s | 768 | 24.8 ms | ~40 |

At the three gateway replicas the run settled on, the old value budgeted **150 tier-wide against a
peak of ~40**. It read `50.0 of 50.0` because nothing ever asked it for a permit.

Two things kept that invisible. `resilience4j-bulkhead` arrives at **runtime scope only**, so the
autoconfiguration binds the YAML and publishes the meters while no code in the service can so much
as name `BulkheadFullException` — no test, no fallback branch, no compile-time reference of any
kind. And nothing distinguished a shed request from an open circuit in the response, because the
fallback body was a constant.

### What changed

| setting | was | now | why |
|---|---:|---:|---|
| `bulkhead.maxConcurrentCalls` | 50 | **50** | tried at 8 and 16, both worse — see below. Left at its unmeasured default rather than at a new guess |
| `bulkhead.maxWaitDuration` | 0 | 0 | unchanged, and now commented: a non-zero wait makes `SemaphoreBulkhead` block a Netty event loop |
| `circuitbreaker.ignoreExceptions` | — | `BulkheadFullException` | see below |
| `resilience4j-bulkhead` | runtime | **compile** | so the service can name the exception it now handles |

**`ignoreExceptions` is the load-bearing line.** The runtime composes the controls as
`fallback(timeLimiter(circuitBreaker(bulkhead(call))))` — **the breaker is outside the bulkhead**.
Every request the bulkhead refuses therefore raises `BulkheadFullException` *inside* the breaker's
window, and uncounted-for it reads as a 100% failure rate from core. Without this line, switching
the bulkhead on recreates T-5.10's outage by a new route: concurrency rises, the gateway sheds, the
shedding opens the breaker, and a downstream that was merely busy is cut off entirely.

`BulkheadIT` is that failure written as a test: 20 rejections against a breaker whose window needs
5, asserting it stays `CLOSED` with zero recorded failures.

### Measured: the mechanism holds, the number was wrong

Run against dev with `maxConcurrentCalls: 8` applied as an env override, binding verified before the
ramp (`resilience4j_bulkhead_max_allowed_concurrent_calls` reading **8.0**, not 50.0).

**The prediction failed.** Served throughput did not plateau near capacity — it was *capped far
below* it, at every step:

| offered | served (baseline) | served (limit 8) | 5xx (baseline) | 5xx (limit 8) |
|---:|---:|---:|---:|---:|
| 200 | 200 | 195 | 0% | 2.7% |
| 400 | 400 | **186** | 0% | **53.5%** |
| 800 | 768 | **227** | 3.9% | **71.6%** |
| 1200 | 580 | 284 | 51.6% | 75.8% |
| 1600 | 901 | **266** | 43.5% | **81.9%** |
| 2000 | 570 | 255 | 71.4% | 85.0% |

**But the mechanism it was testing is confirmed, cleanly.** One gateway pod's counters over the core
ramp:

| | count |
|---|---:|
| forwarded to core, successful | 37,449 |
| **ignored** (`BulkheadFullException`, excluded from the window) | **109,195** |
| **failed** | **0** |
| **not_permitted** (circuit open) | **0** |
| 503s served from `/fallback/core` | 109,195 — matches `ignored` exactly |

Every one of the three things the fix depends on held. The bulkhead **is** applied to the route, so
T-5.10's "reactive Spring Cloud Gateway does not apply Resilience4j bulkheads" is disproven on the
cluster as well as in a test. `ignoreExceptions` **did** bind and did its job: 109,195 rejections,
`failed` still zero, and **the circuit never opened once** — against a baseline run in which the
breaker short-circuited 133,931 requests. And core never failed: its CPU fell to **891m** at the
2000 req/s step, close to idle, because the gateway was refusing work rather than drowning it.

**Where the sizing went wrong.** Little's Law was applied with the wrong latency. The derivation
assumed a permit is held for about as long as a healthy request takes (~7–25 ms). Measured, one pod
sustained 37,449 successes across ~760 s on 8 permits — 49 req/s per pod, so **a permit was held for
~163 ms**, an order of magnitude longer than assumed. A limit of 8 therefore bound at roughly a
tenth of the intended rate, and admitted 25.5% of offered traffic.

Two mechanisms inflate the hold time, and the second is a finding in its own right:

1. The permit spans the whole downstream filter chain — retries, the proxy hop, and writing the
   response back to the client — not core's service time.
2. **Rejection is not free.** `fallbackUri: forward:/fallback/core` is a full `DispatcherHandler`
   forward with request-body caching enabled. At 85% shed rate the gateway sat pinned near its HPA
   ceiling (~4,000 m across 4 replicas) *manufacturing 503s*, which slowed the admitted calls, which
   held permits longer, which shed more. A tight limit converts an overload into a rejection-cost
   problem.

**Caveat on comparability.** The `gateway_only` scenario, which never touches core or the bulkhead,
also came in below its baseline (2,665 of 3,000 at p95 171.6 ms, against 2,996 at 16.6 ms), and k6
peaked at 1,617 m against 1,036 m. Some of the degradation above is generator and cluster
contention, not the limit. The per-pod counters are not affected by that and are what the mechanism
conclusion rests on.

### A second size, and the point at which guessing stopped

`maxConcurrentCalls: 16`, same ramp, same cluster:

| offered | served @8 | **served @16** | served (baseline) |
|---:|---:|---:|---:|
| 400 | 186 | **397** | 400 |
| 800 | 227 | **669** | 768 |
| 1200 | 284 | 492 | 580 |
| 1600 | 266 | **55** | 901 |
| 2000 | 255 | 60 | 570 |

16 repaired the low end exactly as the arithmetic said it would, and then fell off a cliff between
1200 and 1600 req/s that no sizing argument predicted. Counters again: `failed` **0**,
`not_permitted` **0**, on every pod. The breaker still never opened. What changed is the permit hold
time, derived from the counters:

| step | permits (tier) | served | implied hold time |
|---|---:|---:|---:|
| 800 | 48 | 669 | 72 ms |
| 1200 | ~56 | 492 | 114 ms |
| 1600 | 64 | 55 | **1,160 ms** |

**A permit is held for the whole gateway-side request, so its hold time includes waiting for gateway
CPU.** Above 1200 req/s the gateway is CPU-bound, hold time goes up tenfold, and a fixed concurrency
limit therefore tightens hardest at precisely the moment it should loosen. That is a property of the
host, not of the number, and it is why no third value was tried:

> **A concurrency limit cannot be sized against a saturated host.** `maxConcurrentCalls` is back at
> 50 — its unmeasured default — rather than at a better guess. What survives from T-5.11 is what was
> *verified*: the bulkhead is wired (retraction above), `ignoreExceptions` prevents shedding from
> opening the breaker (109,195 and 337,679 rejections, zero recorded failures, zero short-circuits
> across two runs), and the fallback now tells the caller the truth.

## The host, not the config (T-5.12)

Every number above was collected from outside the cluster. Read from inside it, at the 1200 req/s
step:

### USE — where the saturation actually is

| | |
|---|---|
| **Utilization** | node CPU **100%**, **98.4%**, **97.3%** — all three nodes |
| **Saturation** | load average **30.07** and **22.87**, on **four** cores each |
| **Saturation** | no CFS throttling anywhere: the app pods declare no CPU limit, so contention appears as run-queue delay, which no container metric names |
| **Errors** | `tempo-0` OOMKilled **16 times**; 2 of 3 `alloy` pods not Ready |

CPU by namespace at that moment: `apps` 6,180m (including k6 at 798m), **`observability` 1,442m**,
peaking at **2,234m** during the 800 req/s step. The telemetry stack costs a quarter to a third of
the application tier, on the same two saturated workers.

### There is no APM data, and there never was

The tracing analysis this section was supposed to contain cannot be produced. **Tempo has never once
been Ready on this cluster.**

```
tempo-0   0/1 Running   16 restarts
lastState: terminated, exitCode 137, reason OOMKilled
memory 507Mi against a 512Mi limit; cpu 1654m against a 100m request
Liveness probe failed: /ready context deadline exceeded
```

It is killed roughly every 90 seconds, replays a WAL it never finished writing, and is killed again.
**No span reached storage during any run in T-5.10 or T-5.11.** The
`Failed to export spans ... InterruptedIOException: timeout` that T-5.10 recorded and filed as a
tracing *cost* was this pod dying — the exporter was not slow, its destination was absent.

Two under-provisions cause it, and the second is the less obvious:

1. **Memory.** 512Mi is below the working set of a single-binary Tempo ingesting from two services
   at `TRACING_SAMPLE_PROBABILITY: 1.0`.
2. **CPU request.** A request is not only a scheduling reservation — it is the weight the kernel
   arbitrates by when a node is contended. At 100m against the app tier's 500m-per-pod, on nodes at
   100% CPU, Tempo was handed roughly 3% of a node while demanding 1,650m. It was starved past its
   probe timeout and killed **for being slow, because it had been told it was unimportant.**
   `alloy`, at a 50m request against a measured 993–1,197m, has the same defect and the same
   symptom.

### Requests that describe nothing

| workload | request | measured under load | ratio |
|---|---:|---:|---:|
| gateway | 500m | 1,068–1,255m | **2.1–2.5×** |
| core | 500m | 648–658m | 1.3× |
| alloy | 50m | 993–1,197m | **~20×** |
| tempo | 100m | ~1,650m | **~17×** |

While the nodes ran at 97–100% CPU, they read as **55% and 56% requested**, and **zero app pods were
ever Pending**. The cluster-autoscaler wakes only for Pending pods, so it has never been asked for a
node under real traffic. T-5.10 recorded that symptom — "no new servers came up because nothing ever
asked for one" — without naming the cause.

### What changed

Requests are now the measured draw at the point the HPA acts, and the HPA targets are re-derived so
the **absolute** trigger does not move:

| | request | HPA target | trigger |
|---|---:|---:|---:|
| gateway | 500m → **1000m** | 200% → **100%** | 1 core/pod, unchanged |
| core | 500m → **700m** | 200% → **145%** | 1015m/pod, was 1000m |
| tempo | 100m → **500m**, limit 512Mi → **1536Mi** | — | — |
| alloy | 50m → **300m**, limit 256Mi → **512Mi** | — | — |

The arithmetic that makes the autoscaler reachable, against 7,400m of worker allocatable:

| state | booked | |
|---|---:|---|
| platform floor (after the change) | 3,025m | |
| min replicas — 2 gateway + 1 core | 5,725m | **77%** — fits |
| max replicas — 4 gateway + 3 core | 9,125m | **123%** — 1,725m over |

At full HPA scale-out the scheduler now runs out of room, pods go Pending, and the autoscaler is
asked for a node — the `autoscaled` pool is `cx33`, min 0, max 2, so one node absorbs the overflow.

### Sampling

`TRACING_SAMPLE_PROBABILITY` is now **0.1** in both services' `application-prod.yml`, down from
`1.0`. The old value carried a comment saying 1.0 was "wrong for a busy production service —
overridden by `TRACING_SAMPLE_PROBABILITY` rather than by editing this"; nothing ever overrode it,
and the prod profile is what dev runs.

T-5.10's A/B of 1.0 against 0.01 was not wrong, it was too narrow: it measured **4.85m vs 5.08m CPU
per request inside the services** and correctly called that noise. It never measured the collectors,
which is where the cost is — Alloy at ~1,200m against a 50m request, Tempo at ~1,650m against 100m
and dead the whole time. The tracing was expensive *and* absent.

Tempo's new sizing deliberately still reserves for the old volume. Nobody has yet watched it stay up
through a load run, and shrinking it on arithmetic is how it reached 100m in the first place.

### Measured, after

Deployed through #307 and #308 and re-run on the same ramp. Against the T-5.10 post-window-fix
baseline, which is the last measurement taken before any of this changed:

| offered | served (before) | **served (after)** | 5xx before | **5xx after** |
|---:|---:|---:|---:|---:|
| 200 | 200 | 196 | 0% | 0.8% |
| 400 | 400 | 400 | 0% | 0% |
| 800 | 768 | 757 | 3.9% | 5.2% |
| 1200 | 580 | **757** | 51.6% | **36.9%** |
| 1600 | 901 | **1037** | 43.5% | **35.2%** |
| 2000 | 570 | **1347** | 71.4% | **31.9%** |

**Throughput no longer runs backward anywhere.** 400 → 757 → 757 → 1037 → 1347 is monotonic; the
old curve peaked at 901 and fell to 570. At 2000 req/s offered the stack now serves **2.4× more**
with **less than half** the error rate. `gateway_only` recovered to 2999 of 3000 with zero errors.

No resilience4j value was touched to get this. The circuit-breaker config is exactly what T-5.10
left, and `maxConcurrentCalls` is back at the 50 it always was.

### The cluster-autoscaler ran, for the first time

```
13:59:22  Final scale-up plan: [{xenopsbase-dev-autoscaled 0->1 (max: 2)}]
14:00:01  node xenopsbase-dev-autoscaled-8b88067268fab6d created, 4 vCPU
```

The 1000m gateway request made the HPA's fourth replica genuinely unschedulable, it went Pending,
and the autoscaler was asked for a node — which is what T-2.8 and #22 always claimed would happen
and what T-5.10 observed never happening. Note the sampler reports `peak Pending app pods 0` for
the run itself: the node arrived during the rollout that preceded it, so by the time load started
there was already room.

### Tempo stayed up, and there are traces

`tempo-0`: **Ready, 0 restarts**, 399Mi through a ramp that peaked at 2000 req/s — against 24
restarts and never once Ready before.

Getting there needed the pod deleted by hand, which is worth writing down: **a StatefulSet
RollingUpdate will not replace a pod that has never become Ready**, so the fix for a crash-loop
cannot roll out *through* the crash-loop. `currentRevision` sat on the old 512Mi spec with
`availableReplicas: 0` while `updateRevision` went unused.

### Where the latency actually is

The profiling breakdown that was impossible before. 59 traces over 800ms, sampled at the knee:

| | median | p90 | max |
|---|---:|---:|---:|
| gateway root span, end to end | 953.3 ms | 1269.2 ms | 1640.2 ms |
| gateway's client span to core | 502.1 ms | 838.0 ms | 1207.8 ms |
| **core's server span** | **5.5 ms** | **12.7 ms** | **23.4 ms** |

**Core accounts for a median 0.51% of end-to-end latency, and never more than 2.32%.** One trace,
laid out:

```
+   0.0   2717.7ms  gateway  http get                     <- whole request
+   2.9     32.5ms  gateway  security filterchain before
+  35.4   2681.0ms  gateway  secured request
+ 725.1   1469.6ms  gateway  HTTP GET                     <- the call to core
+1977.4     11.6ms  core     http get /api/documents      <- core's entire work
+2716.5      0.5ms  gateway  security filterchain after
```

690 ms elapse before the outbound call is even issued. Inside the 1469.6 ms client span, 1252 ms
pass before core receives anything, core spends 11.6 ms, and 523 ms pass after its answer returns.
None of that is core, none of it is Postgres, and none of it is a downstream dependency of any kind
— it is the gateway's own request handling waiting for CPU.

This is the same run-queue delay the USE section describes, now attributed to a span rather than
inferred. It is also the direct explanation of T-5.11's bulkhead result: a permit is held for that
whole 2.7 s, of which the downstream it exists to protect uses 11 ms.

### USE, after

At the 2000 req/s step:

| | before | after |
|---|---:|---:|
| `observability` CPU | 1,442m | **256m** |
| `apps` CPU | 6,180m | 8,568m |
| node CPU | 100% / 98.4% / 97.3% | 98.1% / 80.0% / 77.9% |
| load average | 30.07, 22.87 | 27.69, 9.31, 8.42 |

The telemetry stack costs **5.6× less** and delivers traces instead of nothing. The app tier gets
2.4 more cores and converts them into 2.4× the throughput.

**What is still wrong, stated:** the load is not evenly spread. One worker sits at 98% with a load
average of 27.69 while the other two are at ~78% and load ~9. Adding a node relieved the cluster
without balancing it. That is addressed below.

## One replica per node (T-5.13)

The imbalance above was not uneven traffic. At the 2000 req/s step the four gateway pods served
within 12% of each other — 451, 501, 508 and 513 req/s — while spending very different amounts of
CPU to do it:

| pod | node | req/s | CPU | **m/req** |
|---|---|---:|---:|---:|
| pcwz7 | autoscaled | 501 | 978m | **1.95** |
| xgdh2 | worker-0 | 451 | 1220m | 2.71 |
| 4t9zz | worker-1 | 508 | 1683m | **3.31** |
| 2jzqq | worker-1 | 513 | 1714m | **3.34** |

**The same work cost 1.7× the CPU on the node holding two replicas.** That is the node at 98% with
a run queue of 27.69 on four cores: threads descheduled mid-request, cache locality gone with them.
The two pods then made their own node worse, which is a loop the HPA cannot break by adding a fifth
pod to the same three nodes.

Nothing in the deployment expressed any opinion about where replicas go, so the scheduler packed by
request. The gateway now declares `requiredDuringSchedulingIgnoredDuringExecution` anti-affinity on
`kubernetes.io/hostname` — one replica per node or Pending, and Pending is the one signal the
cluster-autoscaler listens to.

### What it measured

| offered | T-5.10 baseline | T-5.12 | **T-5.13** | 5xx baseline | **5xx now** |
|---:|---:|---:|---:|---:|---:|
| 400 | 400 | 400 | **400** | 0% | **0%** |
| 800 | 768 | 757 | **795** | 3.9% | **0.6%** |
| 1200 | 580 | 757 | **1199** | 51.6% | **0.0%** |
| 1600 | 901 | 1037 | **1578** | 43.5% | **1.3%** |
| 2000 | 570 | 1347 | **1823** | 71.4% | **8.7%** |

> ### These three columns are not the same cluster (T-5.15)
>
> | run | nodes at start | peak |
> |---|---:|---:|
> | T-5.10 baseline, and every T-5.11 run | **3** | 3 |
> | T-5.12 | **4** | 4 |
> | T-5.13 | **4** | 5 |
>
> A node is 3,700m of schedulable CPU here, so T-5.12 opened with **50% more
> hardware** than the baseline it is reported against, and T-5.13 with more again.
> **Part of every improvement in the table above is a server rather than a change,
> and the amount is not separated out.** Nothing in the tooling said so at the
> time; `scalability-test.sh` now refuses to start above the node floor and the
> report prints `started on N`.
>
> It happened because the autoscaler's scale-down chain is long — the HPA's own
> stabilisation window has to expire before a node falls under a 50%-of-requests
> threshold, and only then does a 10-minute unneeded timer start — so a run
> launched twenty minutes after the previous one silently inherits its hardware.
>
> **What this does and does not put in doubt.** The throughput comparisons above
> are confounded and should be read as "this configuration on this cluster",
> not as the effect of the config change alone. The mechanism findings are not:
> the trace breakdown (core at 0.51% of end-to-end), the per-request CPU penalty
> from co-location (1.7x), Tempo's OOM loop, and the autoscaler firing on Pending
> are each internally consistent measurements that do not rest on comparing two
> runs. Re-measuring the throughput curve from a cold 3-node start is owed.

### Re-measured from a cold 3-node start

Owed, and now done. Same ramp, same parameters, cluster verified back at its floor —
`started on 3`, gateway 2, core 1 — against the T-5.10 baseline, which started the same way:

| offered | baseline (3 nodes) | **cold3 (3 nodes)** | 5xx baseline | **5xx now** |
|---:|---:|---:|---:|---:|
| 200 | 200 | 200 | 0% | 0% |
| 400 | 400 | 400 | 0% | 0% |
| 800 | 768 | **799** | 3.9% | **0.1%** |
| 1200 | 580 | **1110** | 51.6% | **7.3%** |
| 1600 | 901 | 996 | 43.5% | 36.3% |
| 2000 | 570 | **1263** | 71.4% | **35.8%** |

**The improvement is real and it is smaller than reported.** At 2000 req/s offered the honest
figure is **2.2×**, not the 3.2× taken from a run that opened on extra hardware. At 1200 req/s it
is 1.9× with errors down from 51.6% to 7.3%.

### The cost of one-replica-per-node, which had not been measured

The 1600 req/s step served **996** — *below* the 1200 step's 1110. That dip is not noise and it is
not the application:

| t | nodes | Pending | gw | core |
|---:|---:|---:|---:|---:|
| 199s | 3 | **1** | 3 | 1 |
| 340s | 3 | **2** | 3 | 2 |
| 410s | 3 | **3** | 3 | 2 |
| 481s | 3 | **3** | 4 | 2 |
| **551s** | **5** | 1 | 4 | 2 |
| 622s | 5 | 0 | 4 | 2 |

From the first Pending pod at ~t+190s to nodes arriving at t+551s is **six minutes short-handed**,
and the 1600 req/s step ran t+490–600 — squarely inside that window. By the 2000 step the nodes
were in and throughput recovered to 1263.

**T-5.13's anti-affinity converts an HPA scale-up into a node provisioning wait.** Before it, a new
replica needed a scheduling slot and appeared in seconds; now it needs a whole node, and a Hetzner
server takes minutes to boot, join, pull and start a JVM. That is the correct steady-state
behaviour — a replica is worth a node's capacity or it is not worth having — and it is a materially
worse burst response, which the T-5.13 numbers could not show because those nodes were already
running.

Both halves are now on the record. Nothing is changed on the strength of this: options exist
(a warm `min_nodes: 1` in the autoscaled pool, or `preferred` anti-affinity plus a topology spread
constraint) and each trades standing cost or steady-state efficiency for burst response. None has
been measured, and the pattern this document keeps recording is what happens when one is picked
before it has been.

**1200 req/s is now served in full with zero errors**, against 580 and 51.6% at the start of this
work. At 2000 offered the stack serves **3.2× what it did** with errors down from 71.4% to 8.7%,
and p95 at 1200 req/s is 72.1 ms against 393.7 ms.

The autoscaler behaved exactly as designed: `peak Pending app pods 1`, nodes 4 → 5, four gateway
replicas on four distinct nodes. Node saturation fell with it — load averages 17.25 / 6.86 / 4.47 /
2.79, against 27.69 / 9.31 / 8.42.

### The imbalance that is now visible underneath it

Fixing placement exposed a different one. At the 1600 req/s step the four pods no longer serve
equal traffic:

| pod | req/s |
|---|---:|
| 4gflb | 669 |
| pc4hh | 497 |
| zvhc2 | 128 |
| wbpcc | 72 |

A **9× spread**, and it maps to pod age: the two replicas the HPA added mid-run carry the least.
The per-request CPU figures above are not comparable across pods in this state, because a pod at 72
req/s is mostly paying fixed overhead.

**Hypothesis:** k6 reaches the gateway through its ClusterIP Service, so kube-proxy picks a backend
**per connection**, not per request. With HTTP keep-alive one connection carries many requests for
its whole life, and replicas that appear after the connections were established only ever receive
new ones. If that is right, the effect is worst exactly when the HPA has just acted, which is when
the new capacity is most needed.

## The Service balances connections, not requests (T-5.17)

**Confirmed.** Two runs, both from a verified cold 3-node start, same ramp, same pods, one variable
changed: `NO_CONN_REUSE=true` makes every request its own connection, which turns the Service's
per-connection balancing into per-request balancing.

Per-pod request rate at the 1600 req/s step:

| | pods | spread |
|---|---|---:|
| keep-alive **on** | 669 / 497 / 128 / 72 | **9.3×** |
| keep-alive **off** | **404 / 399 / 396 / 396** | **1.0×** |

Nothing else could produce that. Not warmup — the pods are the same age in both runs. Not
readiness — they were in Endpoints throughout. Not a broken Service — it distributes perfectly once
the connections stop being sticky.

The corroborating detail from the earlier run is exact: the two replicas were **Ready at t+67s and
served ~0 req/s until t+340s**, while k6 sat on its 120 `preAllocatedVUs` creating no new
connections. The pool first grew past 120 at **t+320s**, and their share then climbed as it grew to
127, 154, 231, 303. Ready pods received nothing for **four and a half minutes** because no client
had a reason to open a socket.

### What it costs

| offered | keep-alive on | **keep-alive off** | 5xx on | **5xx off** |
|---:|---:|---:|---:|---:|
| 800 | 799 | 796 | 0.1% | 0.1% |
| 1200 | 1110 | **1168** | 7.3% | **0.1%** |
| 1600 | **996** | **1571** | 36.3% | **1.6%** |
| 2000 | 1263 | **1560** | 35.8% | **11.0%** |

The 1600 step is the tell: **996 → 1571, errors 36.3% → 1.6%.** That step runs inside the
node-provisioning window (T-5.16), so the cluster was short-handed *and* unable to use the replicas
it did have. The two defects compound.

### This is not a recommendation to turn keep-alive off

A handshake per request is not how any real client behaves, and it is not free: gateway peak CPU
went from 3,229m to 6,248m at the 800 req/s step for the same served rate. `NO_CONN_REUSE` is a
diagnostic that isolates one variable, and it has now done its job.

**The finding is about the HPA, not about k6.** Horizontal scale-out is far less effective than the
replica count suggests for any client holding long-lived connections — which is every service mesh
sidecar, every connection-pooling client, and the ingress itself. A replica that receives no
traffic is capacity that was paid for and not delivered.

**Unmeasured, and deliberately not chosen here:** periodic connection recycling at the client, an
L7 proxy that balances per request rather than per connection, or `ingress-nginx` upstream
keepalive tuning for traffic arriving from outside. Each is a different trade and this document's
recurring lesson is what happens when one is picked before it is measured.

### What this does not cover

**Writes.** Both scenarios are reads, for the reason already stated above.

**Recovery.** Whether an open breaker closes on its own once load falls below the knee is untested.

**Sustained load.** 110 seconds per step. Long enough for an HPA to act, far too short for heap
growth or pool leaks.

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
