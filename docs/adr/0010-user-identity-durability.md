# ADR-0010: User identity is durable state, and declared users carry explicit ids

- **Status:** Accepted
- **Date:** 2026-08-22
- **Task:** T-7.8 (#147)

## Context

Documents are owned by the Keycloak `sub` — `DocumentResource#currentOwner` — and that is
deliberate. A username can be changed in Keycloak, and ownership keyed to `preferred_username`
would strand every document the moment somebody renamed an account.

That makes `sub` an ownership key, which makes its stability a data-integrity property rather than
an identity detail. Nothing said so anywhere. ADR-0002's durable-state table lists *"Keycloak
realm, clients, roles — JSON in git"* and says nothing about users, which are not in git and never
were: they live in Keycloak's own Postgres schema.

T-7.8 was raised on the belief that a cluster rebuild regenerated every `sub` and silently orphaned
the whole document store. That belief was worth taking seriously — under ADR-0002 a rebuild is an
everyday operation, so a rebuild that quietly destroys ownership would be a standing hazard.

## What is actually true

Measured on 2026-08-22 across a full `make down` / `make up` of dev.

A rebuild does **not** regenerate `sub`. Two mechanisms combine:

1. The Postgres cluster bootstraps with `bootstrap.recovery` from the WAL archive, not `initdb`
   (ADR-0007). Keycloak's database rides on that cluster, so its `user_entity` rows are **restored**
   rather than recreated.
2. The realm import job then finds the realm already present and does nothing:

   ```
   Full importing from file /mnt/realm-import/xenopsbase-realm.json
   Realm 'xenopsbase' already exists. Import skipped
   ```

Verified end to end rather than inferred: after the rebuild, the document owner
`af70f9df-8441-4259-9d56-ebb6d1868ac4` still existed in `user_entity` as `smoke`, and signing in as
that user returned `X-Total-Count: 13` with a pre-rebuild document downloading intact through the
presigned redirect.

So the everyday operation is safe, and it is safe by consequence rather than by intent — nothing in
the configuration expresses that user identity must survive, and nothing would fail if it stopped.

## The exposure that is real

`KeycloakRealmImport` cannot update a realm in place. The documented way to apply a realm change in
dev is therefore to delete the realm and let the import recreate it
(`docs/runbooks/authorization.md`). **That** regenerates every `sub`.

The runbook called this acceptable because *"the only users are the two throwaway test accounts"*.
That was true when it was written. Those accounts now own 13 documents, so the procedure had become
a way to destroy data while reading as routine maintenance — the same shape as T-8.6 (#149), where
a comment went on describing a situation that had changed underneath it.

## Decision

**1. User identity is durable state, and ADR-0002's table says so.**

`sub` is an ownership key. It belongs in the durable column, alongside the objects it controls
access to, so that the next person reasoning about what survives a rebuild is told rather than left
to deduce it from a bootstrap mode two files away.

**2. Every user declared in a realm import carries an explicit `id`.**

The ids committed are the ones the realm already held, read out of `user_entity`. This matters more
than it looks: inventing fresh UUIDs would have orphaned the very documents this decision exists to
protect, the first time anyone followed the runbook. A fix that causes the failure it prevents is
not a fix.

With ids pinned, deleting and re-importing the realm restores the same subs, and the documented
procedure stops being destructive.

**3. Runtime-created users are out of scope, knowingly.**

Pinned ids cover only what the import declares. A user created through the admin API or self
registration still gets a generated id, and a realm delete still loses them. The stemcell ships with
`registrationAllowed: false` and two declared accounts, so this is not a gap in what it ships — it is
a gap any fork inherits the moment it has real users.

## Consequences

The routine path is unchanged, because it was already safe. What changes is that it is now safe on
purpose, and the destructive path is not destructive.

**The limit is worth stating plainly.** Ownership is still the raw `sub`, with no indirection. A
fork that acquires real users and then needs a realm change is back where this started, and pinning
ids will not help it. The durable fix is a local user record keyed to `sub` on first sight, so that
identity has one level of indirection and a re-keying becomes a migration instead of data loss.
That is a schema change with a backfill, it is not needed by anything the stemcell ships today, and
doing it now would be building for a user that does not exist. It is recorded as the known
successor to this decision rather than pretended away.

**A restore drill would not currently catch a regression.** T-7.3's nightly drill checks the
database. Ownership spans the database and the realm, so a drill that restores Postgres and never
signs in would report success against exactly the failure this ADR is about. T-7.2 and T-7.3 should
assert that a document uploaded before a rebuild is downloadable by its owner after one — which is
the check performed by hand here.

## Alternatives considered

**Treat the realm as durable and never re-import.** Closest to how it already behaves, and it
removes the mechanism entirely. Rejected because it makes the realm unmanageable: the only way to
change it becomes the admin API, which is the hand-configuration ADR-0002 exists to forbid.

**Own documents by a local user record now.** The right long-term answer, and the successor named
above. Rejected for now as building machinery for a user the stemcell does not have, when a
one-line-per-user change removes the actual hazard.

**Do nothing and document the trap.** Rejected. The trap was already documented, in a runbook whose
justification had gone stale without anyone noticing. Another paragraph would not have helped.
