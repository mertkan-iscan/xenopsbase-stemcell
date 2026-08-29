# ADR-0011: Valkey caches business data under cache-aside, and every key names its owner

- **Status:** Accepted
- **Date:** 2026-08-29
- **Task:** T-0.11 (#261)
- **Amends:** [ADR-0009](0009-in-memory-store.md)

## Context

[ADR-0009](0009-in-memory-store.md) chose Valkey and put it on the **disposable** side of
[ADR-0002](0002-ephemeral-cluster-and-durable-state.md). That claim is currently true in the
strongest possible sense, because Valkey holds sessions and nothing else. Verified 2026-08-24 and
still true today:

```
hibernate.cache.use_second_level_cache: false
hibernate.cache.use_query_cache: false
```

no `@Cacheable` anywhere in `core`, and `core` does not ship a Redis client at all — the dependency
is in the gateway, for sessions. Wiping Valkey today signs everyone out and loses nothing.

Caching business data does not make "disposable" false. It makes it **conditional on fallback
working.** The consequence of a wipe changes from *log in again* to *every read goes to Postgres at
once*, and the difference between those two is entirely a matter of whether the application handles
an absent cache — which is a property of code that does not exist yet, on a path nobody has
exercised.

A decision record that still reads "disposable" without stating that condition is a claim that has
quietly stopped being complete. That is the exact shape [ADR-0008](0008-durable-state-outside-terraform.md)
was written to fix for ADR-0002, and it is why this is an ADR and not a ticket.

ADR-0009 also anticipated this in its own **Revisit if**: *"A measured bottleneck appears in
Postgres (T-5.6). Caching becomes a real driver rather than a speculative one."* This ADR does not
claim that measurement has happened. It fixes the constraints **before** anything caches, so that
the cards which do the work (T-2.19, T-3.22, T-3.23) inherit a decision rather than each making one.

### What is actually cacheable here, and the trap in it

`core` owns four entities. The interesting one is `Document`, and its repository is the whole
argument for the key rule below:

```java
Optional<Document> findByIdAndOwner(Long id, String owner);
Page<Document> findByOwnerAndStatus(String owner, Document.Status status, Pageable pageable);
```

The owner is a **query parameter**, not a filter applied afterwards. Authorisation is enforced by
the row not being returned. A cache keyed on `id` alone would therefore answer a request that the
database itself would have refused — with another user's document, not with stale data.

That is not a worse version of a stale read. It is a different severity class, and the reason the
owner rule below is a rule rather than a review habit.

## Decision criteria

Written down before the options are compared:

1. **Losing Valkey must not fail a request.** ADR-0009's disposability is the thing being amended,
   not abandoned. Any pattern that puts the cache on the write path fails here.
2. **A cache defect must not be able to change severity class.** A stale read is a bug. A read
   belonging to somebody else is an incident. The design must make the second impossible, not
   unlikely.
3. **Staleness must be bounded, and the bound must be stated.** "There is no option where Postgres
   and Valkey never disagree" is the premise; the question is only what the maximum disagreement is
   and who chose it.
4. **A deploy that changes a cached shape must not throw.** It may miss. Missing is a slow request;
   throwing is a broken endpoint, and it breaks on the deploy rather than on the change.
5. **The behaviour must be observable.** A cache that cannot be seen working is one that can be 4%
   effective for a year (T-2.20, #263).
6. **It must not weaken what already works.** Sessions work today. Nothing here may make a logged-in
   user's session the thing that gets thrown away first (T-2.19, #262).

## Decision

### Cache-aside, on the read path only

`core` reads through the cache and writes through the database. The cache is populated on a miss and
**invalidated** — never updated — on a write.

Write-through and write-behind are rejected under criterion 1: both put Valkey in the write path, so
an unreachable cache becomes a failed or lost write, and ADR-0009's "the system can lose this"
stops being true the moment the pattern is adopted rather than the moment something goes wrong.

Mixing patterns per entity is also rejected, and more firmly. Two caches of the same data under two
patterns is how they come to disagree, and the disagreement is discovered by a user.

### Invalidate on write, after commit, with a TTL as the bound

Three parts, and the third is the one that makes the first two honest.

**Evict, do not update.** A write path knows what it *sent*; it does not know what the database
*holds* after defaults, triggers, and a concurrent writer. Writing that value into the cache
(`@CachePut`) publishes the application's belief. Evicting publishes nothing and costs one miss.

**After commit, not inside the transaction.** An eviction that fires before the commit opens a
window in which a concurrent reader repopulates the cache from the pre-commit state, and that entry
then survives the commit — a stale entry created *by* the invalidation. Evictions therefore run on
transaction synchronisation after commit (`@TransactionalEventListener(AFTER_COMMIT)` or an explicit
`TransactionSynchronization`), never as a bare `@CacheEvict` on a `@Transactional` method.

**A TTL on every entry, because the eviction can be lost.** Moving the eviction after the commit
means a crash — or an unreachable Valkey — between commit and evict leaves a stale entry with
nothing to remove it. This is accepted, and the TTL is what bounds it. The TTL is not a performance
knob here; it is the **stated maximum time Postgres and Valkey may disagree** after a write whose
invalidation was lost.

The accepted failure mode, named as criterion 3 requires: *a write whose eviction did not run
serves stale reads for up to one TTL.* Not "the cache is consistent".

### TTLs are mandatory, defaulted, and jittered

- **Default 5 minutes**, chosen as a bound rather than measured — nothing has measured anything yet.
  A card that caches something is free to choose a different value **and record why**.
- **No entry may be written without one.** "Until evicted" is not a TTL: under `allkeys-lru` it
  means an entry lives exactly as long as nothing else needs the memory, which is not a policy
  anybody chose. It is also the failure T-2.19 exists to prevent, seen from the other side.
- **Enforced at startup, not in review.** A cache name configured without a TTL fails the context
  rather than inheriting an unbounded default. A rule with no enforcement point is a convention, and
  this repository has now found several controls that reported success while governing nothing.
- **Jitter.** Entries written together must not expire together, or the TTL becomes a scheduled
  stampede (T-3.23, #265).

### JSON, typed per cache, no polymorphic type information

Java serialization is rejected outright: it couples every cached entry to the exact class shape, so
adding a field in a deploy makes existing entries **throw** rather than miss — failing criterion 4,
and failing it at the worst moment, on rollout.

JSON, with unknown properties ignored, so an entry written by the previous version deserialises into
the new shape or is skipped.

Two specifics that a later card would otherwise get wrong:

- **No `@class` type headers.** Jackson's default polymorphic handling for Redis embeds the class
  name in the payload, which reintroduces exactly the class-shape coupling this decision rejects,
  and turns cache contents into an instantiation surface. Each cache declares its type and uses a
  serializer bound to it.
- **DTOs, never JPA entities.** An entity carries lazy proxies, identity semantics and a persistence
  context it cannot be separated from. Serialising one either fails or silently caches an object
  that is not equivalent to a loaded one.

### The key format

```
xob:c:v<schema>:<cache>:<owner>:<discriminator>
```

Example: `xob:c:v1:document:8f3c…-sub:4711`

- **`xob:c:`** — the namespace. It cannot collide with `spring:session:*`, which is the gateway's and
  is not this decision's to touch.
- **`v<schema>`** — a schema version, bumped whenever a cached DTO changes shape. Old entries then
  become **unreachable** rather than misread: the safe failure, since nothing reads them at all.
  Expect one visible hit-ratio collapse per bump; T-2.20 (#263) says the same from the metrics side,
  and an alert on hit-ratio collapse must not treat this as an incident.
- **`<owner>`** — the Keycloak `sub` ([ADR-0010](0010-user-identity-durability.md)), **always
  present, no exceptions.** See the `findByIdAndOwner` trap above. A cache of data that genuinely
  has no owner uses the literal `shared`, so that the absence is written into the key rather than
  inferred from its length.
- **`<discriminator>`** — the id, or a stable encoding of the query arguments for a list.

### What must never be cached

A list, with the reason for each, because "use judgement" is not a control:

| Never cached | Why |
|---|---|
| **Idempotency records** | `IdempotencyRecord` is in Postgres, written inside the request transaction (T-3.8, the cross-cutting HTTP contract — ADR-0009 attributes this to T-3.10, but the entity and the commit that added it both say T-3.8). A miss makes a replayed request execute **twice**. Staleness here is a correctness bug, not a slow path. ADR-0009 already refused to move these into Valkey; this is the same refusal from the caching side. |
| **Authorisation decisions and token introspection** | Stale means access after revocation. The window this ADR accepts for reads is unacceptable for a permission. |
| **Anything whose only copy would be in Valkey** | ADR-0009's boundary, unchanged. A cache holds a second copy of something Postgres or object storage already holds. The moment it holds the only copy, it is a database nobody backs up. |
| **Presigned URLs and credentials** | They carry their own expiry. Caching one extends it past what the issuer chose, and the extension is invisible. |
| **Document bytes** | The bytes are in object storage; only metadata is a candidate. Multi-megabyte values against a 192 MB store is an eviction engine, and it puts user file content in a store with no encryption at rest and no backup. |
| **Rate-limit counters and sessions** | Not caches. They are authoritative in Valkey by ADR-0009's design, and they are what T-2.19 must stop a cache from evicting. |

### What this does not decide

**Isolation between cache and sessions is T-2.19's (#262).** This ADR states only the requirement it
must satisfy: *a cached entry must never be able to cause the eviction of a session.* Which
mechanism achieves that — a second Valkey, a policy change, more memory — is that card's decision,
and it explicitly is **not** a separate logical DB, which isolates key space and not memory.

## Consequences

### What this makes easy

- T-3.22 (#264) and T-3.23 (#265) inherit the pattern, the key format, the TTL rule and the
  never-cache list, rather than each re-deciding them and disagreeing.
- A cross-tenant cache leak requires violating a written key format, not merely forgetting a filter.
- A DTO shape change is a prefix bump, which is a one-line change with a predictable, visible cost.

### What this makes hard

- Every write path that touches a cached entity now has an after-commit eviction to get right, and
  getting it wrong is invisible until someone reads stale data.
- Read-your-writes is not free. A user who writes and immediately reads must be served from a path
  that has been invalidated, which is why the eviction ordering above is specified rather than left
  to the framework's default.
- The fallback path — every read working with Valkey absent — has to be **tested**, not asserted.
  That is T-3.22's criterion, and the amendment below is only true if it holds.

### What it commits us to

Cache-aside with after-commit invalidation is a pattern, not a dependency: reversing it means
deleting annotations and a serializer configuration. The commitment that is expensive to reverse is
the **key format**, because every entry written under it is unreachable after a change — which is by
design, and is why the schema version exists.

The heavier commitment is cultural. Once `core` depends on a cache for its read latency, "Valkey is
disposable" is true only while the fallback path works, and nobody finds out that it has rotted
except during an incident.

## Alternatives considered

### Write-through — rejected

Keeps the cache authoritative-looking and removes the invalidation problem: the write updates both.
Rejected under criterion 1 — Valkey moves onto the write path, so its loss becomes a failed write.
It also caches what the application sent rather than what the database holds, which is the
`@CachePut` objection above, applied to every write instead of some of them.

### TTL only, no invalidation — rejected

Simplest possible design: entries expire, nothing evicts. Rejected because the staleness window
after a user's *own* write is unbounded by anything they can perceive — they change a document, read
it back, and see the old one for five minutes. That is the report that arrives as "the site is
broken", and it is the read-your-writes problem T-3.21 (#260) already has to solve for read
replicas. Paying for it twice, in a system where the eviction is nearly free, is not a trade.

### Event-driven invalidation through the outbox — rejected, for now

The right answer at a larger size, and probably the eventual one: the write emits an event, a relay
invalidates. Rejected today because ADR-0009 records that nothing schedules `OutboxRelay.relayBatch()`
yet, so this would make cache correctness depend on a mechanism that does not run. It also widens the
window rather than closing it — the relay's latency is added to the staleness — while adding moving
parts. Revisit when the relay is scheduled and when more than one service writes the same entity.

### Hibernate second-level cache — rejected

Available, off, and one property away from being on. Rejected because it caches at the entity level,
below the point where the owner is known: the second-level cache is keyed by entity id, which is
precisely the key this ADR forbids. It would also make the cached shape the persistence model, tying
the cache to the schema and pulling entities across the network — everything the DTO rule exists to
prevent.

### No cache at all — rejected, but nearly right

The honest position remains ADR-0009's: caching without a measured bottleneck is guesswork, and
T-5.6's baseline is what should drive this. Nothing here overrides that, and **this ADR does not
authorise caching anything.** It settles the constraints so that when a measurement does arrive, the
work is implementation rather than five decisions taken under time pressure. If no measurement ever
arrives, the correct outcome is that T-3.22 is never done, and this record explains what would have
been required.

## Amendment to ADR-0009

ADR-0009's decision stands. One claim in it becomes conditional, and this is the condition:

> **Amended by ADR-0011 (T-0.11).** ADR-0009 states that Valkey is disposable because everything in
> it can be reconstructed by a user retrying. That remains true of what is *stored*. Once `core`
> caches business data, losing Valkey additionally means every read reaching Postgres at once, so the
> claim holds **only while the fallback path works** — reads falling through to the database, and
> startup and readiness surviving an absent Valkey. Untested fallback makes "disposable" an
> assumption rather than a property. T-3.22 (#264) owns the tests that keep it true, and T-3.23
> (#265) owns the stampede that follows a cold start.

ADR-0009's rule — *nothing may be stored in Valkey that cannot be reconstructed by a user retrying*
— is **not** relaxed. A cache entry is by definition reconstructible; that is what distinguishes it
from the durable state ADR-0002 protects.

## Revisit if

- **The measurement never arrives.** If T-5.6's baseline shows no Postgres bottleneck, the correct
  action is not to cache carefully — it is not to cache. Revisit this record to say so.
- **Read replicas make it redundant.** T-3.21 (#260) routes reads to `postgres-ro`. If that removes
  the pressure a cache was for, the cache is a second consistency problem bought for nothing, and
  the two decisions should be re-argued together.
- **A second service wants the same cached data.** The key format assumes one owner of each cache
  name. Two writers invalidating each other's entries is a different design, and event-driven
  invalidation becomes the right answer rather than the deferred one.
- **The eviction rate stops being ~zero** (T-2.20). Entries disappearing before their TTL means the
  memory bound, not the TTL, is deciding the cache's behaviour — and under `allkeys-lru` that is
  also the moment sessions are at risk.
- **Anything on the never-cache list is proposed for caching.** The list is the boundary this record
  exists to make visible. Crossing it should require rewriting this ADR, which is the point.
