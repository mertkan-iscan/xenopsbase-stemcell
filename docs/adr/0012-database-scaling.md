# ADR-0012: How the database scales, and the evidence required before it does

- **Status:** Accepted
- **Date:** 2026-08-25
- **Task:** T-0.12 (#266)

## Context

Three changes were proposed together: a connection pooler (#259), read routing to the standby
(#260), and storage growth (#267). Each is individually reasonable. The combination has failure
modes none of them has alone — a pooler changes what the connection budget means, read routing
changes what a transaction boundary means, and both change what a failover does.

This ADR exists to decide the **order**, and more importantly to write down what evidence justifies
each step. Scaling work that is not justified by a measurement is not free: it adds components,
failure modes and maintenance permanently, in exchange for capacity nobody needed.

## What the database is actually doing

Measured on the running dev cluster, 2026-08-25:

| | |
|---|---|
| Buffer cache hit ratio | **99.92%** |
| Backends waiting on a lock | **0** |
| Temp files written (all time) | **1**, 344 kB |
| Longest running statement | the walsender, streaming to `postgres-2` — healthy |
| Connections in use | 18 of 100 |
| `postgres-2` application connections | **0** — it is a failover target only |

There is no measured pressure of any kind. Not on memory, not on locks, not on sort space.

## The correction this ADR exists to record

The obvious first recommendation was "tune before you add", and specifically that
`shared_buffers: 128MB` looked an order of magnitude too small for a node with 8 GB of RAM.

**That reasoning was wrong.** Postgres does not get the node. The container has:

```
limits:   memory 512Mi
requests: memory 256Mi
shared_buffers 128MB  =  25% of the limit
```

25% is the standard guidance, so `shared_buffers` is already correctly sized — against the number
that governs it, which is the container limit and not the machine. Combined with a 99.92% cache hit
ratio, there is no evidence memory is a constraint at all.

The lever that looked cheapest and most obvious turned out to be already pulled, and the error was
comparing against the wrong denominator. That is worth recording, because the same mistake is
available to anyone who reads `kubectl get nodes` before `kubectl get pod -o jsonpath='{...resources}'`.

## Decision criteria

What must be true before each lever is pulled. Stated in advance so they cannot be retrofitted to a
conclusion already reached.

| Lever | Justified when |
|---|---|
| **Fix configuration defects** | Always. A wrong number is not a capacity problem |
| **Vertical: more memory** | Buffer cache hit ratio falls meaningfully below ~99%, or temp files grow, indicating work spilling to disk |
| **Connection pooler** | Connection demand approaches the budget for reasons that are not a misconfigured pool |
| **Read routing** | Read volume the primary cannot comfortably serve, shown by T-5.6 numbers |
| **More storage** | #267's alerts fire, and the cause is data rather than a stalled archive |

## Decision

**The order is: fix defects, then measure, then add components. Nothing beyond the first step is
justified today.**

### 1. Configuration defects — done, and this was the whole finding

The only real constraint discovered was connections, and it was **not** a capacity problem. It was
two unpinned numbers:

```
core       3 × 20  =  60     HPA maxReplicas × Hikari maximum-pool-size
keycloak           = 100     no pool size set anywhere, so the Quarkus default
system, repl, CNPG =  11     measured
                     ────
                     171     against max_connections 100
```

Keycloak alone was entitled to every connection the database has. It never bit because the HPA has
never scaled and neither pool ever filled — the relationship held by luck and reported nothing while
it held.

Fixed in T-2.18: core to 12, Keycloak pinned to 15, and `check-connection-budget.sh` asserts the
arithmetic in CI. Now **65 of 100**.

**A misconfiguration that looks like a capacity limit is the most expensive kind**, because the
obvious response — add a pooler, raise `max_connections`, buy a bigger instance — treats the symptom
and leaves the defect in place, now hidden behind a component nobody wanted.

### 2. A pooler is deferred, and `max_connections` stays where it is

Deferred, not rejected. With the budget at 65 of 100 and no waiting backends, a pooler today would
add a component, a failure mode during failover, and a set of transaction-mode constraints
(#259 lists them) in exchange for headroom nothing is consuming.

When it is justified, it is **CNPG's `Pooler` CRD** rather than a hand-rolled PgBouncer, because the
`Pooler` follows the primary across a failover and a hand-rolled Deployment can keep pointing at a
demoted one — a very confusing outage. Mode will be **transaction**, since session mode multiplexes
almost nothing, and the session-state consequences are enumerated in #259 rather than discovered.

Raising `max_connections` is explicitly **not** the lever. Every connection is a backend process
against 512Mi; raising the limit trades a refused connection for a slower database and moves the
failure from something visible to something diffuse.

### 3. Read routing is deferred, and the bar is deliberately high

`postgres-2` serves zero application traffic. That is not waste to be eliminated — it is a failover
target, and sending everything to the primary is what makes read-your-writes free.

Routing reads buys idle capacity and pays in a bug class that is intermittent, load-dependent, and
reproduces on nobody's machine. `@Transactional(readOnly = true)` **routes but does not wait**, so it
provides no protection on its own; an explicit mechanism is required (#260).

Two further costs, both specific to this cluster: `instances: 2` means routing removes read capacity
at the same moment a failover promotes, and replication is asynchronous, so a lag ceiling and a
circuit-breaker back to the primary are mandatory rather than optional.

### 4. Never routed to a replica, whenever routing happens

- anything read after a write in the same request
- anything feeding an authorization decision — stale permissions are a security bug, not a stale read
- Keycloak's datasource, outright

### 5. Session settings belong server-side

`core` passes `statement_timeout` and `idle_in_transaction_session_timeout` as JDBC `options`. Under
a transaction-mode pooler, `options` becomes part of the pool key: different options mean different
server pools, and some PgBouncer versions reject it outright. They move to `postgresql.parameters`
or `ALTER ROLE ... SET` **before** any pooler lands, not after it starts behaving oddly.

## Consequences

### What this makes easy

There is now a written answer to "should we add a pooler", and it is evidence-shaped rather than
preference-shaped. The next person proposing one has a bar to clear and a measurement that clears it.

### What this makes hard

Deferring means the levers are pulled under pressure rather than in advance, and #259's constraints
will be read in a hurry. The mitigation is that they are already written down.

### What it commits us to

Measuring before scaling, which is slower than scaling. The trade is deliberate: this database is
serving 18 connections with a 99.92% cache hit ratio, and the cost of being wrong in the other
direction — components added for capacity nobody needed — is paid every day afterwards rather than
once.
