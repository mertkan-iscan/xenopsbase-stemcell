-- V7 — drop the demo domain (T-9.2).
--
-- `document` and `example_item` were a business domain in a template that
-- claims to have none. `platform_probe` (V8) replaces both: one table that
-- exercises every seam the stemcell ships, named for what it is.
--
-- ADDED, NOT EDITED, AND THIS IS THE POINT OF THE FILE.
--
-- The obvious way to remove a table is to delete the migration that created
-- it. That is wrong here and would be wrong in any environment that has
-- already run. V2, V3 and V6 are APPLIED in the dev cluster's database, and
-- Flyway validates on every start by comparing the checksums of what it finds
-- on the classpath against what is recorded in flyway_schema_history. Deleting
-- an applied migration makes that comparison fail, in every environment at
-- once, with "Detected applied migration not resolved locally" -- and the
-- application refuses to start. Nothing about that failure would say "somebody
-- deleted a file".
--
-- So the history stays intact and the change goes forward. Squashing the
-- baseline is a FORK-TIME action against an empty database, documented in
-- docs/forking.md, not something this repository does to a live one.
--
-- THIS IS ONE-WAY. There is no down migration, by design (see
-- docs/runbooks/schema-migrations.md), and the data in these tables is gone
-- when it runs. In the dev cluster that is uploaded test files and nothing
-- else. Take the CNPG backup checkpoint before deploying it anyway, and
-- confirm `make restore-verify` passes afterwards: the value of a backup you
-- have never restored is unknown, and the deploy that drops two tables is the
-- wrong moment to find that out.

-- The index goes with the table, but naming it is not redundant: DROP TABLE
-- takes its indexes with it, and stating the one V6 added makes the reversal of
-- V6 visible in the history rather than implied by it.
DROP INDEX IF EXISTS ix_document_owner_status_created_at;
DROP INDEX IF EXISTS ix_document_pending_created_at;

DROP TABLE IF EXISTS document;

DROP INDEX IF EXISTS ix_example_item_tenant;
DROP INDEX IF EXISTS ix_example_item_live;

DROP TABLE IF EXISTS example_item;

-- audit_log rows referring to these tables are deliberately LEFT. The audit log
-- is a record of what happened, and what happened is that those rows existed
-- and were then removed. Deleting the audit trail because the audited table is
-- gone would be the log editing itself, which is the one thing an audit log
-- must not do. It has no foreign key to either table precisely so that this
-- stays possible -- see V5.
