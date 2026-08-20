# Runbook: schema migrations

Flyway owns the schema. Hibernate reads it and never writes to it.

That single rule is what makes the schema reviewable, replayable and recoverable. Everything below
follows from it.

## Where things live

| | |
|---|---|
| Migrations | `services/core/src/main/resources/db/migration` |
| History table | `flyway_schema_history` in the `app` database |
| Hibernate mode | `ddl-auto: validate` (`services/core/src/main/resources/config/application.yml`) |
| The guard | `SchemaOwnershipTest` in `services/core/src/test/java/com/xenopsoftware/core/config` |

`spring-boot-flyway` must stay in `services/core/pom.xml`. Spring Boot 4 moved the autoconfiguration
out of the starter into per-module artifacts, so `flyway-core` on its own gives you the library and
no migration run — silently. The symptom is not a Flyway error, it is Hibernate reporting a missing
table at startup.

## Naming

```
V<version>__<snake_case_description>.sql
```

- **Two underscores** between version and description. One underscore is not a migration and Flyway
  will not tell you it skipped the file.
- **Sequential integers**, no gaps, no dates, no dots. `V3__add_item_owner.sql`.
- **Never renumber or rename an applied migration.** Flyway keys history on the version, so a rename
  reads as "a new migration appeared" and "an applied one vanished" at the same time.
- **Never edit an applied migration.** `validate-on-migrate: true` compares checksums and refuses to
  start. That refusal is the feature — it means every environment ran the same SQL. Fix a mistake
  with a new migration.

Two branches that both add `V3` will merge cleanly in git and fail at deploy, because `out-of-order`
is off by default and the second `V3` is a duplicate version. Renumber the later one **before**
merging, while it has not been applied anywhere.

## Review conventions

A migration is reviewed for what it does to a *running* database, not just for whether the SQL is
valid.

- **What lock does it take, and for how long?** `ALTER TABLE ... ADD COLUMN` with a non-volatile
  default is cheap in modern Postgres. A type change rewrites the table and holds `ACCESS EXCLUSIVE`
  for the duration, blocking every reader.
- **Indexes on a populated table use `CREATE INDEX CONCURRENTLY`**, which cannot run inside a
  transaction — mark the migration accordingly rather than letting it deadlock the deploy.
- **`NOT NULL` on an existing column is three migrations, not one**: add nullable, backfill, then
  constrain. One migration that does all three locks the table for the length of the backfill.
- **Destructive changes are separated from the deploy that stops using the column.** Drop it a
  release later, once nothing rolled back needs it.
- **Entity and migration land in the same commit**, migration written first. `ddl-auto: validate`
  turns a mismatch into a startup failure, which is where you want to find it.

## Rollback strategy

**Migrations are forward-only. There are no undo scripts.**

This is a decision, not an omission. An undo script is written when the schema is empty and run when
it is not, so it is the least-tested code in the system at the exact moment it matters most. A
`DROP COLUMN` that undoes a deploy also destroys everything written since the deploy, and no amount
of review catches that in advance.

Recovery is split by what actually went wrong:

| What broke | How to recover |
|---|---|
| Bad application code, schema fine | Roll back the image. The schema is additive, so the old code still runs against it. |
| Bad migration, data intact | Write `V<n+1>` that corrects it. Forward, always. |
| Migration destroyed or corrupted data | **Point-in-time recovery** to the moment before it ran — see [database.md](database.md). |

The third row is why the additive conventions above matter: they keep the first two rows viable, so
PITR stays the rare case rather than the routine one. PITR restores the whole cluster to a timestamp
and loses everything written after it, which is a real cost, not a free undo.

Flyway runs each migration in a transaction where the DDL allows it, so a migration that fails
mid-statement rolls back that statement. It does **not** roll back earlier migrations in the same
run. After a failed run, check `flyway_schema_history` for the last successful version before
deciding what `V<n+1>` has to assume.

## Adding a migration

```bash
cd services/core
# 1. write src/main/resources/db/migration/V<n>__<description>.sql
# 2. write or change the entity to match
./mvnw test
```

`SchemaOwnershipTest` runs as an ordinary unit test and needs no database. It fails the build if any
configuration file — including a profile no test activates — sets `ddl-auto` or `hibernate.hbm2ddl.auto`
to a value that lets Hibernate issue DDL, and if production ever turns on `baseline-on-migrate`,
which would stamp an unknown schema as version 1 instead of refusing to start.

## Known gaps

**Migrations run as the application's own database user.** That user therefore holds DDL rights at
runtime, which a compromised application inherits. Splitting into a migration role and a runtime
role belongs with the hardening work in T-8.2 (#60).

**Test profiles use `ddl-auto: none`, not `validate`.** The generator's `DateTimeWrapper` test entity
has no migration behind it, so validation fails on a table the application does not own. Until that
is resolved, integration tests do not catch entity/schema drift — only the deployed profiles do.
Tracked separately; the `hibernate.hbm2ddl.auto: none #TODO` in `application-testdev.yml` is the
marker.
