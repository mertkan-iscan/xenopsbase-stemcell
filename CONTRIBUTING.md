# Contributing

The stemcell is a template other projects are forked from. Conventions here are inherited by
every fork, so they are worth being strict about.

## The board

Every task moves through all five columns. Skipping straight from Backlog to Done hides what is
actually being worked on, which is the one question a board exists to answer.

| Column | Means |
|---|---|
| **Backlog** | Not started, and not necessarily startable — may be blocked by another task |
| **Ready** | Unblocked and specified well enough to begin without asking anything first |
| **In progress** | Someone is working on it *right now*. Move it here **before** the first commit, not after |
| **In review** | The work is done but a criterion cannot be verified yet — usually because it needs a credential, a decision, or something only a human can do. The reason belongs in a comment on the issue |
| **Done** | Every acceptance criterion met and verified, or explicitly superseded with the reason recorded |

**In review is not a waiting room for finished work.** If everything is verified, it is Done. If
something is genuinely outstanding, the issue must say what, and who has to do it.

**A task that cannot close because the remainder is a different piece of work** should have that
remainder split into its own issue, and the original closed. Carrying a half-finished task forever
is how a board stops reflecting reality.

## Branching

`main` is protected. No direct pushes. Work happens on a branch and lands through a pull request
with green checks.

Branch names carry the task ID from the [project board](https://github.com/users/mertkan-iscan/projects/5):

```
t-0.1/repo-hygiene
t-2.4/cloudnativepg-wal-archiving
```

## Commits

[Conventional Commits](https://www.conventionalcommits.org/). The **pull request title** is what
gets linted and what ends up in the squashed commit, so it is the one that must be correct.

```
feat(gateway): relay OIDC token to the core service
fix(flyway): fail startup when a migration checksum drifts
docs(adr): record the durable-state boundary
chore(deps): bump spring-boot to 3.5.13
```

Allowed types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `build`, `ci`, `perf`, `revert`.

Scopes follow the component: `gateway`, `core`, `infra`, `platform`, `ci`, `adr`, `docs`.

A `!` after the scope, or a `BREAKING CHANGE:` footer, marks a breaking change and drives the
major version bump.

## Pull requests

- One task per PR wherever possible. Link the issue with `Closes #N`.
- Squash merge. The PR title becomes the commit message.
- The PR body says what changed and, more importantly, **why**, plus how it was verified.

## Tests

What each layer is for, what it deliberately does not cover, and the coverage target with the
reasoning behind the number: [docs/testing.md](docs/testing.md). Read it before adding a test at a
new level — the boundaries exist so layers do not quietly duplicate each other.

## Architecture decisions

Anything that constrains future work gets an ADR before the code. See
[docs/adr/README.md](docs/adr/README.md). If you find yourself explaining a choice in a PR
description at length, it wanted an ADR.

## The rule that matters most

Nothing may be configured by hand. Not a `kubectl apply` against a live cluster, not a click in
the Hetzner console, not a realm edited in the Keycloak admin UI. The cluster is rebuilt from
nothing on a routine basis, and anything created by hand disappears when it is.

If you cannot express a change as code in this repository, that is the bug.
