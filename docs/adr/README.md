# Architecture decision records

An ADR records a choice that constrains future work, together with the reasoning that made it the
right choice at the time. The reasoning is the valuable part. Anyone can read the code and see
what was decided; only an ADR says why the alternatives were rejected, and therefore what would
have to change for the decision to be revisited.

## When to write one

Write an ADR when a choice:

- is expensive to reverse later (a database engine, an identity provider, a state boundary), or
- will be inherited by every project forked from this stemcell, or
- looks arbitrary from the outside and will be second-guessed in six months, or
- you find yourself explaining at length in a pull request description.

Do not write one for a choice that is obvious, local, or cheap to change. A reversible decision
inside one class is a code comment, not an ADR.

## Format

Copy [`template.md`](template.md). Number sequentially, four digits, never reuse a number.
File name is the number plus a kebab-case summary:

```
0003-secrets-management.md
```

Every ADR carries a **Status**:

| Status | Meaning |
|---|---|
| `Proposed` | Written, under discussion, not yet binding |
| `Accepted` | Binding. Code and infrastructure must comply |
| `Superseded by ADR-NNNN` | Replaced. Kept for the historical reasoning |
| `Deprecated` | No longer relevant, and nothing replaced it |

**ADRs are append-only.** An accepted ADR is never edited to say something different and never
deleted. When a decision changes, write a new ADR and mark the old one superseded, with a link in
both directions. The wrong decision plus the reason it was wrong is more useful to a future reader
than a clean file that hides the fact a mistake was ever made.

## Process

1. Open an issue using the *Architecture decision* template, which forces the criteria to be
   stated before the options are compared.
2. Write the ADR as `Proposed` in a pull request.
3. Discussion happens in review, on the actual text.
4. Merge flips it to `Accepted`.

## Index

| ADR | Title | Status |
|---|---|---|
| [0001](0001-service-topology.md) | Gateway plus one core service | Accepted |
| [0002](0002-ephemeral-cluster-and-durable-state.md) | Ephemeral cluster and the durable-state boundary | Accepted |
| [0003](0003-secrets-management.md) | Secrets encrypted in git with SOPS and age | Accepted |
| [0004](0004-gitops-engine.md) | Argo CD reconciles the cluster from git | Accepted |
