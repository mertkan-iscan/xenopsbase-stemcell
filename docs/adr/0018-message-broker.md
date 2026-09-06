# ADR-0018: NATS is the message broker, and its JetStream state is disposable

- **Status:** Accepted
- **Date:** 2026-09-06
- **Task:** T-9.6

## Context

The transactional outbox has existed since T-3.10 and has never delivered anything. `OutboxService`
writes a message in the same transaction as the change it announces — that half is real and tested —
and then `MessagePublisher` defaults to writing a log line, because no broker had been chosen. Worse,
nothing ever calls `OutboxRelay.relayBatch()`, so even the log line only appears if a test invokes
the method directly.

That is an entire mechanism that reports success while doing nothing, which is the exact failure this
repository keeps finding and this ADR is the last instance of.

Choosing a broker is a genuine decision because it adds a stateful component to a cluster whose whole
design (ADR-0002) is that state lives outside it.

## Decision criteria

1. **It must fit ADR-0002.** The cluster is ephemeral. A broker whose messages are the only copy
   would make the cluster durable state by the back door.
2. **It must fit the workers.** The measured free memory on the fixed workers is small enough that a
   broker's footprint is a real constraint, not a rounding error. See the arithmetic below.
3. **One process, not a subsystem.** A fork should be able to read the whole thing.
4. **The client must not force a programming model.** These services are servlet-and-JDBC by choice
   (ADR-0017); a broker whose Java client only works reactively would pull that decision sideways.
5. **It must be optional.** A fork that wants no broker must still build, start and pass its tests.

## Decision

**NATS with JetStream**, one replica in its own namespace, deployed by Argo CD like every other
platform component.

**JetStream's file store sits on a disposable PVC, and the Postgres outbox is the durable record.**
That is the sentence the whole ADR exists for. A cluster rebuild recreates the streams empty; the
relay then republishes everything it has not marked published, because `outbox_message.published_at`
lives in Postgres, which ADR-0002 already makes durable. Nothing is lost that the database did not
already lose.

> **Correction, 2026-09-07 (T-9.9).** When this ADR was accepted, the paragraph above was not true
> and neither was "a fork that adds a consumer gets messages rather than log lines" further down.
> **No stream existed.** JetStream was enabled on the server and nothing was bound to any subject,
> and `NatsPublisher` used a core NATS publish — which is fire-and-forget, and to which a subject
> with no stream is not an error but a message nobody kept. So the relay set `published_at` on rows
> the broker had dropped, and a rebuild would not republish them, because they were marked.
>
> Measured on dev the day the broker went in: `in_msgs 2`, JetStream storage `0`, zero streams,
> `published_at` set on both rows. A mechanism reporting success while delivering nothing, which is
> the thing this ADR exists to end, one layer further out than where it was looking.
>
> Two changes make the claims hold. `Streams` declares the stream in code and applies it on every
> connect and reconnect — borrowed from xenopsbase-learn, which had solved this first. And the
> publish is now acknowledged (`jetStream().publish`), so a missing stream, a full stream or an
> absent broker is an exception the relay retries rather than a row marked published. See the
> reversal recorded on `NatsPublisher` itself.

The consequence is at-least-once delivery, which is not a new obligation: the outbox pattern was
already at-least-once — the relay can publish and fail before recording that it did — and
`MessagePublisher`'s contract has said "implementations must be safe to call twice with the same
message" since T-3.10. **Consumers must be idempotent.** That was true before this ADR and is now
also true for a reason somebody can point at.

**ADR-0002's durable-state table is unchanged.** NATS is not durable state. It is a transport whose
contents are reconstructible from state that is.

### The relay is scheduled, and holds a Postgres advisory lock

`OutboxRelay.relayBatch()` is now driven by `@Scheduled`. `extension-seams.md` already said why a bare
`@Scheduled` in a template is wrong — it runs on every replica at once — so the schedule is guarded.

**A Postgres advisory lock, not ShedLock.** `pg_try_advisory_lock` is one round trip against a
database every replica already holds a connection to. It needs no lock table, no migration and no new
dependency, and it releases automatically when the session ends — including when the pod is killed,
which is the case a lock table gets wrong by leaving a stale row that blocks the relay until somebody
notices. ShedLock would be a third coordination mechanism for a problem two lines of SQL solve.

## Consequences

### What this makes easy

- The outbox delivers. A fork that adds a consumer gets messages rather than log lines — and gets
  the ones published before it subscribed, because the stream retains them for seven days. That was
  the point of a broker with persistence rather than a bare pub/sub, and it only became true with
  T-9.9; see the correction above.
- `NatsPublisher` is the only broker-aware class, behind `@ConditionalOnProperty`. Replacing NATS
  means writing one `MessagePublisher`.
- A rebuild needs no broker-side recovery procedure, because there is nothing on the broker worth
  recovering.

### What this makes hard

- **A pod on already-tight workers.** See the arithmetic; it fits, and it is not free.
- **At-least-once is now a live constraint rather than a note.** A consumer that assumes exactly-once
  will double-process after any relay restart mid-batch.
- **Messages in flight at teardown are lost.** By design — they are re-derived from the outbox — but
  a fork that publishes something NOT recorded in the outbox has silently opted out of that
  guarantee. Publish through `OutboxService`, not through `NatsPublisher` directly.

### What it commits us to

The outbox as the source of truth for anything published. Reversing that means making the broker
durable, which means making the cluster durable, which is ADR-0002.

## The headroom arithmetic, done before the sync rather than after it

The plan for this work quoted "~4.7GB free on the workers" from **xenopsbase-learn's ADR-0109**. That
is a different repository's measurement of a different question and is not used here. This
repository's own figure, in the header of `infra/scripts/check-worker-headroom.sh`, measured
2026-09-03:

```
memory   floor 2112Mi   ceiling 5056Mi   +2944Mi   free on fixed workers 1836Mi
cpu      floor  2700m   ceiling  6100m   +3400m    free on fixed workers  1390m
```

NATS books `64Mi` / `50m` and is limited to `256Mi` / `500m`. Against 1836Mi that is 3.5% of the
booked headroom, and the gate that actually matters — `check-worker-headroom.sh` requires **256Mi
schedulable per fixed worker** — has 1836Mi of slack to absorb it on whichever worker it lands.

**Two things that figure does not account for, stated rather than discovered:**

- It was measured on 2026-09-03. xenopsbase-learn was deployed here in #426, and whether its three
  services are inside that 1836Mi depends on whether they had converged when it was taken. Treat the
  number as an upper bound.
- Learn's own gateway does not exist yet and is budgeted elsewhere at `2 × 533Mi`. When it lands it
  competes with this pod.

So: the arithmetic says it fits with room, and `make verify-headroom` after the first sync is what
confirms it — in that order, which is the point. It is the check that caught worker-0 dropping to
87Mi schedulable after a routine rollout (T-2.29, #368).

## Alternatives considered

### Kafka — rejected

The right answer at a scale this template does not have. It is a multi-broker system with its own
storage model, its own operator and a memory footprint measured against the whole free budget above
rather than against a few percent of it. Choosing it here would make the broker the largest component
in the cluster and would make ADR-0002 a much harder argument: Kafka's log is not obviously
reconstructible from anywhere else.

### RabbitMQ — rejected

Closer in size, and a reasonable choice. It loses on the durability story rather than on resources: a
RabbitMQ queue is the kind of thing people put messages in and expect to keep, so shipping it while
declaring its state disposable invites exactly the misuse this ADR is trying to prevent. NATS core is
explicitly at-most-once and JetStream is an addition on top of it, which makes "the stream is a cache
of the outbox" a natural reading rather than a surprising one.

### Postgres as the queue (LISTEN/NOTIFY, or a polling table) — rejected

Tempting, because the durable record is already there and it adds no pod. Rejected because it makes
the database the fan-out point: every consumer holds a connection, and connection count is already
the constraint this cluster manages most carefully (`make connection-budget`). It also gives a fork
nothing to grow into — the moment a consumer wants replay, ordering or a second consumer group, the
answer is a broker, and the migration is worse than starting with one.

### No broker, keep `LoggingMessagePublisher` — rejected

The status quo. It is a mechanism that reports success while delivering nothing, and it is what this
ADR exists to end.

## Revisit if

- A fork needs partitioned ordering or compacted topics. NATS has neither in the form Kafka does, and
  wanting both is the signal that the scale changed.
- The stream stops being reconstructible from the outbox — for example if something publishes
  directly rather than through `OutboxService`. At that point the broker IS durable state and
  ADR-0002 needs amending, not this one.
- `make verify-headroom` starts failing. The answer is carrying less or a third fixed worker, not a
  smaller floor.
