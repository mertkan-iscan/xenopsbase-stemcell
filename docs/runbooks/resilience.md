# Runbook: resilience

Every outbound call is bounded. Nothing waits forever, and a failing dependency degrades into a
described error rather than taking the caller down with it.

## The rule

**An unset timeout is not "the default". It is usually no timeout at all.**

That is true of Reactor Netty, of Postgres `statement_timeout`, and nearly true of the AWS SDK
(minutes, which is past the point where anyone is still waiting). Every value below is stated
explicitly for that reason — including the ones that happen to match a library default, because a
value nobody wrote down is a value nobody reviewed.

## Gateway → core

| | |
|---|---|
| `httpclient.connect-timeout` | 2s |
| `httpclient.response-timeout` | 10s |
| Circuit breaker | `resilience4j.circuitbreaker.instances.core` |
| Time limiter | 12s — **above** the response timeout on purpose |
| Bulkhead | 50 concurrent calls |
| Fallback | `forward:/fallback/core` → 503 + `Retry-After` |

The time limiter must be **greater than or equal to** the transport's response timeout. Set it
lower and it cancels the call before the transport has had its stated chance, so every slow
response is attributed to the wrong layer and the timeout you tuned never fires.

`slowCallRateThreshold` matters as much as `failureRateThreshold`. Without it, calls that time out
individually never trip the breaker: the downstream is unusable, every call is "succeeding" slowly,
and the gateway keeps queueing into it.

The bulkhead is what stops one bad downstream from consuming the whole gateway. That is the
failure this card exists to prevent — not "core is down", but "core is down and therefore
everything else is too".

### Retries are GET-only, deliberately

A `Retry` filter with no method restriction replays POSTs. The gateway **cannot** know whether the
first attempt reached core and committed, and it cannot see whether the client supplied an
`Idempotency-Key` — so retrying here would duplicate exactly the work that key exists to prevent
(see [http-contract.md](http-contract.md)).

Only 5xx and connect/timeout failures are retried. Retrying a 4xx re-sends a request the downstream
has already judged invalid.

## Core → object storage

| | |
|---|---|
| `apiCallTimeout` | 15s — the whole operation, retries included |
| `apiCallAttemptTimeout` | 5s — one attempt |
| connect / socket | 2s / 10s |
| max connections | 50 |

Both API timeouts are needed. Setting only the first lets one slow attempt consume the entire
budget with no room left to retry; setting only the second means three slow attempts still add up
to no limit at all.

`apache5-client` is declared explicitly in `pom.xml` rather than inherited as a runtime transitive.
The SDK renamed it — `ApacheHttpClient` is gone in 2.46, it is `Apache5HttpClient` — and leaving
the transport implicit means an upgrade can swap it without anything in this repository changing,
taking the timeout configuration with it.

## Core → Postgres

The important one has **no default at all**:

```yaml
options: "-c statement_timeout=30000 -c idle_in_transaction_session_timeout=60000"
```

Postgres runs a query until it finishes or the client disconnects. One pathological query holds its
connection indefinitely, and enough of them exhaust the pool while every health check still passes.

Applied as a **server-side** setting so it bounds the database's work. A JDBC socket timeout only
abandons the client side and leaves the query running — the connection is freed, the load is not.

`max-lifetime` is 10 minutes, under the typical 15-minute idle timeout of a cloud load balancer or
NAT, so the pool discards a connection before the network silently does. Otherwise the first query
on a reused connection hangs until the socket timeout, long after the request that owned it gave up.

## What the tests cover, and why there are two

`DeadDownstreamIT` points the route at a refused port and asserts the behaviour: 503 problem
document, `Retry-After`, breaker opens under sustained failure, later calls rejected outright
rather than forwarded, meters recorded.

`GatewayRouteConfigurationTest` reads the production `application.yml` and asserts the route
actually declares the breaker, names an instance that exists, restricts retries to idempotent
methods, sets both httpclient timeouts, and exposes `prometheus`.

**Neither is sufficient alone**, and the reason is a trap worth knowing:

> `src/test/resources/config/application.yml` **replaces** the main file on the test classpath. It
> does not merge with it.

So no integration test in the gateway ever loads the real routes, the real `resilience4j` block, or
the real actuator exposure. A behavioural test has to declare its own route — which proves the
mechanism works and says nothing about whether production uses it. Deleting the `CircuitBreaker`
filter from the production route would leave every integration test green.

That is why the static test exists, and why it asserts values are **present** rather than what they
are: the numbers are a default posture meant to be tuned per deployment, and pinning them would
turn ordinary tuning into a test failure and teach people to edit the assertion.

Three separate failures during this work traced back to that same shadowing:

| Symptom | Actual cause |
|---|---|
| 401 where 503 expected | `mockUser()` is inert without `.apply(springSecurity())` |
| 404 "No static resource" | no routes in the test config |
| Breaker never opened after 12 failures | no `resilience4j` block; library defaults need 100 calls |

Each reads as a broken feature and is missing configuration.

## Tuning

The numbers here are a **starting posture, not tuning**. Real tuning needs the latency distribution
of a real downstream, which a template does not have. When you have one:

- Set the response timeout above p99, not above the mean. Tuning to the mean guarantees the
  slowest legitimate requests are killed.
- Set `slowCallDurationThreshold` to where "slow" genuinely means "broken" for your callers.
- Size the bulkhead from measured concurrency, not from the connection pool.

## Known gaps

**No test of a hung downstream.** The dead-downstream test uses connection-refused, which is
immediate and deterministic; a hang test would wait out the real timeout on every run and still be
timing-dependent. The gateway path is the same once the timeout fires — what differs is only how
long the failure takes to arrive. A proper version belongs with the chaos drills in T-5.7 (#46),
where waiting is the point.

**Core has no circuit breaker around object storage.** Timeouts and a bounded pool are in place, so
a failing object store cannot hang the service, but repeated calls are still attempted. Adding one
means deciding what a degraded document API should do, which is an application decision rather than
a template default.

**Retry budgets are not implemented.** Two retries per request is bounded per-request but not in
aggregate: a broad outage means every client retrying three times, which is a thundering herd
against a service already struggling. The circuit breaker bounds this in practice — it opens and
stops the retries entirely — but a real budget is a separate mechanism.
