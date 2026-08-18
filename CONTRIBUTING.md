# Contributing

The stemcell is a template other projects are forked from. Conventions here are inherited by
every fork, so they are worth being strict about.

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

## Architecture decisions

Anything that constrains future work gets an ADR before the code. See
[docs/adr/README.md](docs/adr/README.md). If you find yourself explaining a choice in a PR
description at length, it wanted an ADR.

## The rule that matters most

Nothing may be configured by hand. Not a `kubectl apply` against a live cluster, not a click in
the Hetzner console, not a realm edited in the Keycloak admin UI. The cluster is rebuilt from
nothing on a routine basis, and anything created by hand disappears when it is.

If you cannot express a change as code in this repository, that is the bug.
