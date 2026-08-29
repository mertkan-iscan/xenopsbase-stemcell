# ADR-0009: Valkey is the in-memory store, and it is disposable

- **Status:** Accepted, **amended by [ADR-0011](0011-valkey-as-a-business-cache.md)**
- **Date:** 2026-08-22
- **Task:** T-2.11

## Context

The gateway is a backend-for-frontend (T-3.5, T-3.13). It is a confidential OIDC client that holds
the session in a cookie and relays the access token downstream. Spring's default for that shape is
`WebSessionServerOAuth2AuthorizedClientRepository` over an `InMemoryWebSessionStore`, so **the
access and refresh tokens live in one JVM's heap.**

`replicas: 1` on the gateway is therefore load-bearing rather than a sizing choice. A second
replica would serve requests that land on the pod without the session, so users would be signed out
at random — intermittently, unreproducibly, and with nothing logged. The single-replica version of
the same fault is already visible: every gateway rollout ends every logged-in session.

Two other things want shared state, and are named because "we should have Redis" is not a
requirement:

- **Rate limiting** (T-8.3). Spring Cloud Gateway's `RequestRateLimiter` is Redis-backed. Per-replica
  counters mean the real limit is `limit × replicas`.
- **Short-lived locks.** Nothing schedules `OutboxRelay.relayBatch()` yet; the runbook says to wire
  it to a CronJob or a `ShedLock`-guarded task, and the guard needs somewhere to live.

Two things that were expected to want it and do not:

- **Idempotency keys.** T-3.10 put these in Postgres — `IdempotencyRecord` against the
  `idempotency_record` table, written inside the request transaction. Postgres is already shared
  across replicas, so this is answered correctly today and moving it to an in-memory store would
  make it less reliable.
- **Keycloak sessions.** Keycloak clusters through Infinispan on its own.

Caching is deliberately not a driver. Caching without a measured bottleneck is guesswork, and a
wrong cache is worse than none: it serves stale data and hides the problem it was added for.
T-5.6's load baseline comes first.

## Decision criteria

Set down before comparing, so they are not retrofitted:

1. **Licence.** The stemcell exists to be forked, including into work that may be distributed or
   sold. A licence that constrains the fork is inherited by every project built on this.
2. **Spring integration.** Session storage and `RequestRateLimiter` must work without custom glue.
3. **Which side of the ADR-0002 boundary.** The answer must be explicit, because the failure mode
   is drifting from cache to database without noticing.
4. **Blast radius when it is lost.** Whatever is stored must be something the system can lose.
5. **Operational cost.** One more stateful component to run, bound and watch.

## Decision

**Valkey**, deployed via GitOps, and it sits on the **disposable** side of ADR-0002.

Redis changed licence in 2024 to RSALv2/SSPLv1 and later AGPLv3. Valkey is the Linux Foundation
fork of the last BSD-licensed Redis, is protocol-compatible, and is what several distributions now
ship as their default. Criterion 1 decides this on its own: a template whose forks may be sold
should not carry a copyleft dependency by default, and there is no functional cost to avoiding it.

**Disposable, not durable**, and ADR-0002's own table already says so — "issued sessions and
tokens" are listed as living inside the cluster. Losing Valkey signs everyone out and resets rate
limit counters. Both are recoverable by the user logging in again, which is the definition of
something the system can lose.

> **Amended by [ADR-0011](0011-valkey-as-a-business-cache.md) (T-0.11).** "Disposable" is stated
> here without a condition, and at the time it needed none: Valkey held sessions and nothing else,
> so losing it signed everyone out and lost nothing. Once `core` caches business data, losing Valkey
> additionally means every read reaching Postgres at once, and the claim holds **only while the
> fallback path works** — reads falling through to the database, and startup and readiness surviving
> an absent Valkey. ADR-0011 states that condition and the constraints that keep it true. Read the
> two together; where they differ on caching, ADR-0011 is authoritative. The rule in the next
> paragraph is **not** relaxed by it.

That constrains what may be put in it. **Nothing may be stored in Valkey that cannot be
reconstructed by a user retrying.** Rate limit counters qualify. Idempotency records do not, which
is why they are in Postgres and stay there.

## Consequences

### What this makes easy

- The gateway can run more than one replica, which is the point.
- A gateway rollout stops ending every session, because the session is no longer in the pod.
- T-8.3's rate limiting gets its store without another decision.
- `ShedLock` has somewhere to put a lock when the outbox relay is scheduled.

### What this makes hard

- One more component to pin, monitor, bound and upgrade.
- Memory must be capped with an explicit eviction policy. An unbounded in-memory store on a shared
  node takes the **node** down, not just itself, and it takes down whatever else was scheduled
  there.
- The disposable boundary has to be defended in review. The pressure to store "just one thing" that
  matters will arrive, and the moment it does this becomes a database that nobody backs up.

### What it commits us to

Little, and reversing is cheap. Valkey is protocol-compatible with Redis, so the client library and
Spring integration are unchanged if this is ever revisited; the change is which image the chart
pulls. Moving *off* an in-memory store entirely is harder — it would mean returning the gateway to
one replica, or moving sessions into Postgres, which trades a fast store for a slow one on the
request path.

## Alternatives considered

### Redis — rejected on licence

Functionally equivalent and better known. Rejected because RSALv2/SSPLv1/AGPLv3 is inherited by
every fork of this template, including any that is later distributed. That is a constraint imposed
on other people's projects to gain nothing, since Valkey is protocol-compatible.

### Encrypted cookie sessions, no server-side store at all — rejected, narrowly

Genuinely stateless: put the session in an encrypted cookie and the gateway needs no store. This
was the closest call.

Rejected because the payload is an access token plus a refresh token, and 4 KB of cookie is tight
for both once headers are counted. Refresh-token rotation also becomes awkward — the rotated token
has to reach the browser on the same response, and a lost response means a session that cannot be
refreshed. It remains the right answer for a design carrying a small session, and is worth
reconsidering if the token payload ever shrinks.

### Sticky sessions at the ingress — rejected

Routes a browser back to the replica holding its session, which appears to solve it. It does not:
a pod restart, a rollout or an eviction still loses the session, and it makes replicas
non-interchangeable, which is the property scaling depends on. It hides the fault rather than
removing it.

### Postgres as the session store — rejected

No new component, and it is already backed up. Rejected because it puts a read and a write on the
database in the hot path of every authenticated request, to store data that is explicitly allowed
to be lost. It would also blur ADR-0002's boundary in the wrong direction, making disposable data
durable and backed up for no benefit.

### Hazelcast or Infinispan embedded in the gateway — rejected

Removes the separate component by clustering the JVMs. Rejected because it couples replica
lifecycle to cluster membership: rolling deployments become a partition-and-rejoin problem, and the
failure modes are subtle and specific to that library. A separate store keeps the application
replicas genuinely stateless, which is the goal.

## Revisit if

- **Anything authoritative is proposed for it.** That is the boundary crossing this ADR exists to
  make visible. It then needs persistence, backup and a row in ADR-0002's durable table — at which
  point it is a database, and the choice should be re-argued as one.
- **The session payload shrinks** enough to fit an encrypted cookie comfortably. The stateless
  option becomes clearly better and removes a component.
- **Valkey's stewardship changes.** The licence is the reason it was chosen; if that stops being
  true, the reason is gone.
- **A measured bottleneck appears in Postgres** (T-5.6). Caching becomes a real driver rather than
  a speculative one, and the sizing and eviction decisions here should be revisited against actual
  load.
