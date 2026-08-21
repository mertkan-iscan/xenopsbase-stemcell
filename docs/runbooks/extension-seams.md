# Runbook: extension seams

Four hooks that are cheap now and expensive later. None of them carry business semantics — they
are shapes, not decisions.

The reason a template carries them at all: adding audit columns to a populated table means deciding
what `created_by` holds for a million rows nobody recorded. Adding soft delete after code has been
written against hard delete means auditing every query. Adding a tenant column after go-live means
a migration that cannot be rolled back safely.

## 1. Audit

Two mechanisms, doing different jobs.

**Audit columns** — `created_by`, `created_date`, `last_modified_by`, `last_modified_date`, from
`AbstractAuditingEntity`. Answer: *who last touched this row, and when.*

**`audit_log`** — one row per insert, update and delete, with the before/after values of what
changed. Answers: *what happened to this row over its life.*

### The identifier is `sub`, not the username

`created_by`, `last_modified_by` and `audit_log.actor` hold the OIDC **`sub`**.

The generated `SpringSecurityAuditorAware` returned `preferred_username`, which Keycloak lets a user
change. An audit column holding a mutable value is not an audit column: rename a user and every row
they touched is attributed to a name that no longer exists — or, if the name is reused, to a
different person. Neither failure raises an error, and neither is detectable afterwards from the
data.

`sub` is unreadable to a human, and that cost is paid deliberately. `audit_log.actor_name` carries
a **point-in-time snapshot** of the display name for people to read, which is correct precisely
because it makes no claim to still be current.

### One generic table, not Hibernate Envers

Envers is the better-known answer and was considered. It was rejected on one specific ground: it
needs a new migration for every new entity, and forgetting that migration produces an entity with
**no audit trail and no error**. A seam that can be silently skipped is not a seam.

The cost is that the payload is JSON rather than typed columns, so "every row where status became
X" is a JSON query rather than a column predicate. For a template that is the right trade — the
mechanism stays uniform and impossible to forget.

### Written inside the transaction

`AuditLogWriter` buffers entries during the transaction and flushes them at `beforeCommit`, over
the transaction's own connection.

Writing them after commit would be simpler and would mean a crash between the commit and the audit
write loses the record of a change that really happened. **An audit log with holes in it is worse
than none, because it is trusted.** `auditEntriesRollBackWithTheChangeTheyDescribe` guards this.

`JdbcTemplate` rather than a repository, because this runs at a point in the transaction where
starting more JPA work is exactly what must not happen — persisting through the same
`EntityManager` during a flush either throws or triggers a nested flush.

### Hibernate events, not JPA `@EntityListeners`

JPA callbacks receive the entity but not what changed about it — no previous state, so an update
produces a snapshot with no way to tell which fields moved. `PostUpdateEvent` carries both
`getState()` and `getOldState()`, which is the difference between an audit log and a pile of copies.

They also apply to every entity without annotation. Anything requiring a per-entity opt-in is
something a new entity can silently miss.

**Outbox rows are excluded.** They are plumbing, not domain changes; auditing them fills the log
with entries about messages describing changes that already have their own entries.

## 2. Soft delete

`@SoftDelete(columnName = "deleted")` on `ExampleItem`. Hibernate rewrites `DELETE` into
`UPDATE ... SET deleted = true` and adds the predicate to every query, so ordinary repository code
needs no changes and **cannot forget it** — the reason to use the mapping rather than hand-written
`@SQLDelete` plus `@Where`.

The cost is real: deleted rows become invisible to JPA entirely. There is no "include deleted"
switch. Reading them back is a native query.

### `Document` is deliberately not soft-deleted

Its bytes live in object storage. A row marked deleted while the object still exists is a leak
wearing a tombstone — it still costs storage and is still readable by anyone holding a presigned
URL. Deletion there has to be real.

That asymmetry is the point. Soft delete is not a default to apply everywhere; it is a per-entity
decision, and the seam exists so the decision is cheap either way.

## 3. Multi-tenancy

A `@TenantId` discriminator column, present and **inert**. `TenantContext` returns `default` because
nothing populates it, so every row is written and queried under one tenant and the application
behaves exactly as a single-tenant application.

Hibernate sets the column on insert and adds it to every query automatically. That is the whole
reason to use `@TenantId` rather than an ordinary column: a column the application has to remember
to filter by is a column that will eventually not be filtered by, and the failure mode of
forgetting is one tenant reading another's data.

`NOT NULL` with a default, for a related reason. A nullable tenant column means one code path
forgets to set it, those rows match no tenant filter, and they become invisible to every tenant
**including the one that owns them**.

### Activating it

Write a filter that resolves the tenant and calls `TenantContext.set`, with a matching `clear` in a
`finally`.

- **The source must be something the caller cannot forge.** A tenant taken from a request header is
  a tenant the caller chooses, which is not a boundary at all. A claim in the verified JWT is the
  obvious source.
- **Clearing is not optional.** Threads are pooled; a leaked value shows up as data from the wrong
  tenant appearing intermittently under load, which is the worst way to discover it.
- `DefaultTenantResolver` implements `HibernatePropertiesCustomizer` as well as
  `CurrentTenantIdentifierResolver`. A bean alone is not enough — Hibernate reads the resolver from
  its own settings map, so without the customizer the resolver is constructed, never consulted, and
  the seam appears to work.

## 4. Transactional outbox

`OutboxService.record(...)` writes a message in the **same transaction** as the change it announces.

```java
@Transactional
public Order place(Order order) {
    Order saved = repository.save(order);
    outbox.record("order.placed", "Order", saved.getId().toString(), saved);
    return saved;
}
```

Both commit or neither does. Publishing to a broker directly from that method cannot offer this:
the commit and the publish are two systems, and every ordering of them leaves a window where one
happened and the other did not — an event announcing a change that was rolled back, or a change
nobody was told about.

- **`Propagation.MANDATORY`.** Calling `record` outside a transaction throws rather than quietly
  opening one of its own, which would commit the message independently of the change and silently
  remove the only guarantee this provides.
- **An unserialisable payload fails the whole transaction.** Committing the change and dropping the
  message would make the outbox best-effort.
- **The correlation id is carried through** (T-3.8), so a consumer's logs join back to the request
  that caused the event.

### Delivery is at-least-once

The relay can publish and then fail before marking the row, so a consumer can see the same message
twice and **must be idempotent**. That is a property of the pattern, not a gap: exactly-once would
require the broker and the database to share a transaction, which they cannot.

`claimUnpublished` uses `PESSIMISTIC_WRITE` with `SKIP LOCKED`. Without the lock, every replica
reads the same rows and publishes each message once per replica. Without `SKIP LOCKED`, replicas
queue behind each other and the throughput of N relays is the throughput of one.

A failure in one message does not abandon the batch — otherwise one permanently unpublishable
message blocks everything behind it forever, which looks like the relay being broken.

### Where messages go

`MessagePublisher` has one method and no broker concepts, because no broker has been chosen and an
interface shaped around one would encode assumptions the eventual choice may not share.

The default `LoggingMessagePublisher` writes a log line. Replace it by declaring your own
`MessagePublisher` bean — `@ConditionalOnMissingBean` means there is no flag to set and nothing to
delete.

**Nothing schedules `OutboxRelay.relayBatch()`.** As with the document reaper, a `@Scheduled` baked
into a template runs on every replica at once. Wire it to a CronJob or a `ShedLock`-guarded task.

## Known gaps

**Nothing prunes `audit_log`.** It grows with every write, forever. Retention is a compliance
question a template cannot answer, but a deployment must: partitioning by month and dropping old
partitions is the usual answer, and it is much easier to set up before the table is large.

**The audit payload is untyped JSON.** Values are rendered with `toString()`, so a `BigDecimal` and
its string form are indistinguishable in the log. Fine for reading, not for reconstructing state.

**Soft-deleted rows are invisible to JPA with no escape hatch.** Recovering one means a native
`UPDATE`. Adding a repository method for that is straightforward; it is left out because "undelete"
is a business decision.

**Tenancy is discriminator-based only.** Schema-per-tenant and database-per-tenant are different
mechanisms with different isolation guarantees, and switching later is a migration, not a
configuration change. If strong isolation is a requirement, decide before there is data.
