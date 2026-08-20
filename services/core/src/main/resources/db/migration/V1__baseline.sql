-- V1 — baseline.
--
-- Deliberately empty of domain tables. This stemcell ships a database that is
-- READY, not one that is populated: T-3.3 specifies a core service with no
-- domain entities, so there is nothing here to create yet.
--
-- It exists anyway, and is not optional. Flyway records this as version 1, which
-- is what gives every forked project a known starting point to migrate FORWARD
-- from. Without a V1, the first developer to add a table writes the migration
-- that also implicitly defines what "empty" meant, and that definition differs
-- per fork.
--
-- Paired with spring.jpa.hibernate.ddl-auto=validate (T-3.6): Hibernate is never
-- allowed to create or alter a table. Every schema change arrives as a file in
-- this directory, reviewed like any other code. The failure mode this prevents
-- is the one where production drifts from the migrations because ddl-auto
-- quietly fixed something in staging.
--
-- Naming: V<n>__<description>.sql, two underscores. Flyway ignores a file with
-- one underscore rather than failing, so a typo here means a migration that
-- silently never runs.

-- A marker table, so the baseline applies something rather than being a no-op,
-- and so `flyway_schema_history` has a verifiable first entry.
CREATE TABLE IF NOT EXISTS schema_baseline (
    applied_at  timestamptz NOT NULL DEFAULT now(),
    description text        NOT NULL
);

INSERT INTO schema_baseline (description)
VALUES ('xenopsbase stemcell baseline - no domain tables by design');
