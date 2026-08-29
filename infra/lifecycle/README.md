# Bucket lifecycle rules, per environment

**Task:** T-1.14 (#151)

```
infra/lifecycle/<environment>/<bucket>.json
```

The directory is the environment. `dev/documents.json` is applied to
`xenopsbase-dev-documents` and to nothing else, and the only way to write a rule that reaches prod
is to put a file in `prod/`.

Applied and verified by [`apply-lifecycle-rules.sh`](../scripts/apply-lifecycle-rules.sh):

```bash
make storage-lifecycle ENV=dev
```

## Why one flat set of rules did not work

The rules used to live in `infra/lifecycle/*.json`, one set read by every environment.
`make storage-lifecycle` took an `ENV`, used it to build the bucket *name*, and then applied the
same file whichever environment it was given.

That made the obvious safety measure unavailable. An expiry rule on `documents` — the one thing that
caps how much a bucket can accumulate — would have deleted production user data on the same
schedule. Dev was unbounded not because nobody thought about it, but because the mechanism could not
express "dev only".

## Why there is no shared layer, and why the duplication is deliberate

The tempting design is a `common/` directory plus per-environment overrides, so the rules that are
the same everywhere are written once.

That is the mechanism this card exists to remove. A shared layer is precisely a place where a rule
written while thinking about one environment silently applies to another — which is the failure
mode, not an implementation detail of it. The whole point of this change is that **dev's rules
differ from prod's on purpose**, so "keep them the same" is not a property worth building for.

The cost is real and is accepted: four files repeated three times, which can drift. Drift between
environments is visible in a diff and is usually the intended state. A rule that reaches an
environment nobody was thinking about is neither.

## What differs today, and why

| bucket | dev | staging / prod |
|---|---|---|
| `documents` | current versions expire at **30d**, noncurrent at 7d | no expiry on current versions; noncurrent at 90d |
| `loki-chunks` | 30d | 30d |
| `pg-backups` | 35d | 35d |
| `tempo-traces` | as committed | as committed |

**`documents` is the whole reason for this change.** In prod it holds user data and nothing may
expire it on a timer; the bucket is in ADR-0002's durable column and stays there. In dev it holds
whatever the smoke suite and manual testing uploaded, so an age bound is the aggregate cap that
`application.storage.max-upload-bytes` (50 MB) cannot provide on its own — per-object is capped,
total volume was not.

**30 days rather than something shorter** because `make cold-rebuild` proves a document survives a
teardown (T-7.2), and a retention window shorter than the gap between drills would make that
document disappear for a reason unrelated to the thing being tested.

Nothing here is the primary retention policy. See
[the object-storage runbook](../../docs/runbooks/object-storage.md#retention-is-layered-and-the-order-matters):
each component enforces a shorter retention of its own, and these are backstops. Change the
component first and the bucket second.

## Adding an environment

Create the directory and the rule files. The script refuses an environment it has no directory for,
by name, rather than applying nothing and reporting success.
