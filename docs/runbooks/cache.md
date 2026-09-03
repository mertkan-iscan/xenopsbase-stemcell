# Runbook: the business cache

Two Valkey instances, and they are not interchangeable. One holds **sessions** and is authoritative;
the other holds a **cache** and holds nothing that is not also in Postgres.

| | `valkey` | `valkey-cache` |
|---|---|---|
| Holds | gateway sessions | `core`'s document pages |
| Authoritative? | yes — losing it signs everyone out | no — losing it costs a database read |
| `maxmemory` | 64mb | 128mb |
| Policy | `allkeys-lru` | `allkeys-lru` |
| Persistence | none | none |
| Consumer | `gateway` | `core` |

They are separate processes because `allkeys-lru` evicts **any** key: sharing one instance means a
cached row can evict a session, and the symptom is users logged out at random under cache load,
looking like an authentication bug. That was reproduced before the split (T-2.19, #262) — filling a
shared instance to 218M left `dbsize 0`, every session gone.

**If you change one thing in this runbook, never point `CACHE_VALKEY_HOST` at `valkey`.** It is the
one configuration mistake that rebuilds a failure this project has already paid for.

## What happens when Valkey restarts

Neither instance persists (`save ""`, `appendonly no`), so a restart, rollout, node move or eviction
storm leaves a **completely cold** store. This is by design — ADR-0009 puts Valkey on the disposable
side of ADR-0002 — and the consequences differ per instance.

### Sessions (`valkey`)

Everyone is signed out and logs in again. Nothing is lost: identity lives in Keycloak, and document
ownership is the Keycloak `sub`, which is pinned in the realm (ADR-0010).

### Cache (`valkey-cache`)

Nothing is lost, and the next request for each key goes to Postgres. What to expect, in order:

1. **A hit-ratio collapse to zero**, recovering as keys are re-read. This is the expected shape
   after a restart and is not an incident on its own.
2. **A step up in Postgres reads** for as long as the working set takes to repopulate. Bounded — see
   below.
3. **No user-visible errors.** A miss on an unreachable cache falls through to the database, and a
   failed eviction after a committed write is logged and swallowed.

Nothing needs to be done. There is no warm-up step, and priming it by hand is not useful: the TTL is
five minutes, so a primed cache is indistinguishable from a cold one within one TTL.

## Why a cold cache does not become a stampede

Three mechanisms, and each covers a case the others do not (T-3.23, #265).

**Per-replica single-flight.** Concurrent misses on one key produce **one** load per replica;
everyone else waits for it and shares the result. `SingleFlight` does this in the JVM, keyed on the
cache key. So the load reaching Postgres for one key is bounded by the replica count:

```
without   one load per concurrent REQUEST     unbounded, up to the Tomcat thread pool
with      one load per REPLICA per key        3 at the HPA ceiling (T-2.8)
```

Waiters hold no transaction and therefore no connection — `listAvailableCached` is deliberately not
`@Transactional`, because the annotation would take a Hikari connection for every waiting thread
before the coalescing could stop it.

**Jittered TTLs.** Every entry expires at its configured TTL ±20%, drawn per entry. Without jitter,
entries written together expire together and the stampede is not prevented, only scheduled — which
matters here because a repopulating cache writes its whole working set in one burst.

**The connection budget.** Even the worst case is inside it:

```
make connection-budget ENV=dev
core 3 x 12 = 36, keycloak 15, system 11, reserved 3   ->   65 of 100, 35 spare
```

### Why the lock is not distributed, which is a decision

A distributed lock lives in Valkey, and **Valkey is what just failed** in the scenario the lock
exists for. It is missing exactly when it is needed, and the failure mode it introduces —
"nobody serves anything" — is worse than the one it prevents.

Spring Data Redis's own option does not help either: `lockingRedisCacheWriter` takes its lock on the
**cache name**, not the key (`DefaultRedisCacheWriter.lock(String name)`), so it serialises every
key against every other and exists to make `clear()` safe rather than to coalesce loads. And
`@Cacheable(sync = true)` on the default non-locking writer coalesces **nothing**, which would read
as protection while providing none.

So the residual duplication is one load per replica per key, and buying the last factor of three
would cost a lock that is absent in the case it was bought for.

## Keys

```
xob:c:v<schema>:<cache>:<owner>:<discriminator>

xob:c:v1:document-list:6b0c1f2e-9d34-4a71-b8c5-2f7e1a4d3c88:0-20-createdAt: DESC
```

- `xob:c:` cannot collide with `spring:session:*`, which is the gateway's.
- `v1` is a **schema version**. Bump it when a cached DTO changes shape in a way
  `ignoreUnknown` cannot absorb; old entries become unreachable rather than misread, and age out
  under their TTL. Expect one hit-ratio collapse per bump — do not treat it as an incident.
- The **owner** is always present. `findByOwnerAndStatus` enforces authorisation by not returning
  the row, so a key without the owner would answer a request the database itself would refuse, with
  another user's documents. That is a leak, not a stale read.

## What is never cached

Presigned URLs and credentials (they carry their own expiry, and caching one extends it invisibly),
idempotency records (a miss makes a replayed request execute twice), authorisation decisions,
document bytes, and anything whose only copy would be in Valkey. Full list and reasoning in
[ADR-0011](../adr/0011-valkey-as-a-business-cache.md).

## Operating it

Caching is **opt-in**. Without `CACHE_ENABLED=true` there is no cache manager and no eviction
listener, and the read path is a plain query — which is a supported state, not a degraded one.

```bash
K="$PWD/infra/terraform/cluster/kubeconfig"
P=$(KUBECONFIG=$K kubectl -n cache get pod -l app.kubernetes.io/name=valkey-cache -o name)

# what is in it, and does it expire
KUBECONFIG=$K kubectl -n cache exec "$P" -c valkey -- sh -c \
  'export REDISCLI_AUTH=$(sed -n "s/^requirepass //p" /etc/valkey/secret/auth.conf); \
   valkey-cli --no-auth-warning dbsize; \
   valkey-cli --no-auth-warning --scan --pattern "xob:c:*"'

# pressure and evictions, per instance -- the label is what makes this diagnostic
# redis_evicted_keys_total{service="valkey"}        should stay 0
# redis_evicted_keys_total{service="valkey-cache"}  may rise; that is the cache working
```

**Reading `evicted_keys` on `valkey` above zero is the alarming one.** It means something is
evicting sessions, and the first thing to check is whether `core` is pointed at the wrong instance.

### Dropping the cache deliberately

Safe at any time, and the honest way to test a cold start:

```bash
KUBECONFIG=$K kubectl -n cache rollout restart deploy/valkey-cache
```

Do **not** use `FLUSHALL` from a shell against `valkey` by habit — same command, different instance,
and on that one it signs out every user.
