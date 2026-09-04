# The restore drill's anchor

`restore-anchor.json` is what the nightly drill (T-7.3, #55) asserts a rebuilt cluster must still be
able to serve.

## Why this one is committed when `restore-state.json` is gitignored

They are different claims and it matters.

`restore-state.json` is a **snapshot**, written by `make restore-record` immediately before a
specific rebuild and compared immediately after it. Committing one would mean asserting a moment
against a rebuild it never saw, so it stays out of the repository.

This file is an **anchor**: one deliberately chosen, long-lived document that the drill re-checks
every night. It is not a picture of current state and does not go stale when the document set
changes.

## What it deliberately does not contain

A `total`. The document set moves legitimately between runs — every smoke run creates one and
deletes it — so asserting a count here would fail nightly for a reason that has nothing to do with
restore. `restore-verify.sh` treats a missing `total` as "assert ownership and bytes only", which is
exactly the claim T-7.8 (#147) asked for:

> A document uploaded **before** a rebuild is downloadable by its owner **after** one.

## What makes this document a good anchor

- **Created 2026-08-21**, so it already predates many full destroy-and-rebuild cycles.
- **Owned by a pinned sub.** `smoke` carries an explicit `id` in `realm-import.yaml` (ADR-0010), so
  a realm re-import restores the same `sub` and the ownership assertion means something. A user
  created at runtime would get a new sub on every rebuild and the drill would fail for the wrong
  reason.
- **Nothing deletes it.** The smoke suite cleans up after itself and only touches what it created.

## When it legitimately needs updating

If this document is ever deleted, or the realm's pinned ids change. Both are deliberate acts. Update
it by running:

```bash
make restore-record ENV=dev STATE=infra/drill/restore-anchor.json
```

then removing the `total` and `recorded_at` fields, which are snapshot properties rather than anchor
properties.

**If you find yourself updating this because the drill failed, stop.** That is the drill working: it
is telling you a rebuild did not restore what it should have, and editing the expectation to match
is how a check stops being one.
