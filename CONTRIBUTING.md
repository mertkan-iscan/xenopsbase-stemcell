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

That is enforced, not a convention. Three status checks are required, and a pull request cannot be
merged until all three are green:

| Required check | Comes from | Covers |
| --- | --- | --- |
| `no unencrypted secrets` | `secrets.yml` | Every pull request, no path filter |
| `Conventional Commits title` | `pr-conventions.yml` | The PR title, which becomes the squashed commit |
| `services` | `services.yml` | `core`, `gateway` and `generated client`, aggregated |

`services` is one aggregate context rather than the three job names, so renaming a matrix entry
cannot silently make a required check stop existing. It reports success when nothing under
`services/`, `clients/` or `docs/api/` changed, so a docs-only pull request is not held up by a
Maven build it does not need.

`terraform` exists as the same kind of aggregate and is **deliberately not required yet**:
`plan (cluster)` has been failing since 2026-08-21 for a reason that predates this rule
([#183](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/183)). Requiring it today
would block every infrastructure change rather than review it. It goes on the required list when
#183 closes.

Administrators are not exempt. `enforce_admins` is on, which on a one-person repository is the
whole point — the only person who could route around the checks is the person who wrote them.

Reviews are **not** required, because a single maintainer cannot approve their own pull request
and requiring one would make the repository unusable. Green checks are the gate; review is the
convention.

Branch names carry the task ID from the [project board](https://github.com/users/mertkan-iscan/projects/5):

```
t-0.1/repo-hygiene
t-2.4/cloudnativepg-wal-archiving
```

## Commits

[Conventional Commits](https://www.conventionalcommits.org/). The **pull request title** is what
gets linted and what ends up in the squashed commit, so it is the one that must be correct.

That second clause was untrue until 2026-08-23. `squash_merge_commit_title` was
`COMMIT_OR_PR_TITLE`, which means GitHub uses the *branch's* commit title whenever the branch has
one commit — and most do. So the string that was linted and the string that landed were different
strings, and only one of them had been checked. Six commits on `main` carry titles the check would
reject; they predate the fix and are left alone, because history is public and already pushed.

The setting is now `PR_TITLE`, so the linted string is the one that lands, whatever the commit
count.

```
feat(gateway): relay OIDC token to the core service
fix(core): fail startup when a migration checksum drifts
docs(adr): record the durable-state boundary
chore(deps): bump spring-boot to 3.5.13
```

Allowed types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `build`, `ci`, `perf`, `revert`.

Scopes follow the component. The full list is the one `pr-conventions.yml` enforces, and now that
the check is binding a scope missing from here is a blocked merge rather than a wrong document:
`gateway`, `core`, `services`, `infra`, `platform`, `secrets`, `ci`, `adr`, `docs`, `deps`.

**One scope, never a comma list.** Conventional Commits allows exactly one, so `fix(gateway,core)`
is rejected. A change spanning components takes the broader scope — `services` for both
applications, `platform` for the deployed manifests — or no scope at all, which is allowed. The
comma form kept being written, which is why `services` exists: the list was missing something.

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

## Code style

Settled mechanically, so it is never an argument in review.

```bash
make format          # reformat every Java file
make format-check    # fail if anything is unformatted (what the build runs)
make hooks           # install the pre-commit hook, once per clone
```

The formatter is **prettier** with `prettier-plugin-java`, driven by Spotless. Prettier rather than
a native Java formatter because the code was already in that style — only 25 of core's 99 files had
drifted — so adopting it cost a 42-file diff instead of rewriting all 174 and making `git blame`
useless.

`spotless:check` is bound to Maven's `validate` phase, so **any** build fails on a formatting
violation. It is `check`, never `apply`: a formatter that rewrites your tree during a build makes a
dirty checkout look like your own change. `make format` is the only thing that rewrites.

The pre-commit hook runs the secret scan and, when Java is staged, the formatter check. It is a
convenience, not the enforcement — both checks run in CI whether or not anyone installed it. Bypass
a single commit with `git commit --no-verify`; CI will still run them.

Two style files exist and both are needed. `.prettierrc` is the repository-wide config;
`.prettierrc-java` is what Spotless reads, because Spotless's prettier bridge does not apply
`.prettierrc`'s `overrides` section and would otherwise format Java at tabWidth 2. Each file says so
at the top. They must agree on Java: `printWidth 140`, `tabWidth 4`.

## Releases

```bash
bash infra/scripts/next-version.sh --explain   # what would be cut, and why
bash infra/scripts/release-notes.sh v1.2.3     # what the notes would say
```

Cutting one is the **Release** workflow, run by hand from the Actions tab. It defaults to a dry run;
uncheck `dry_run` to actually tag and publish.

Nothing releases on a push, deliberately. A release is a judgement about what is fit to depend on,
and the commit at the head of `main` on a Tuesday afternoon is not that judgement. The mechanics are
automated so they are repeatable; the decision is not.

The version comes from the commit messages: `feat` → minor, `fix`/`perf` → patch, `!` or
`BREAKING CHANGE` → major. `docs`, `ci`, `chore`, `test`, `build` and `refactor` cut nothing at all,
because a version number that increments for a typo carries no information. While the major version
is 0, a breaking change bumps the minor instead (semver clause 4) — the move to 1.0.0 is a decision,
and it is [#63](../../issues/63).

That derivation is only trustworthy because two other controls make the history trustworthy: PR
titles are linted, and `squash_merge_commit_title` is `PR_TITLE`, so the linted string is the one
that lands. Without both, a version derived from commit messages looks authoritative and is
arbitrary.

**`CHANGELOG.md` is written by hand and stays that way.** The release body carries the generated
list of what changed; the file explains what it means for a fork, which no generator produces. The
workflow does not touch it — it cannot push to protected `main`, and a PR opened with
`GITHUB_TOKEN` never triggers its own required checks, so it could never merge.

## Dependencies

Dependabot opens grouped PRs on Mondays — Spring as one PR rather than forty, tests as another,
everything else as a third. Configured in `.github/dependabot.yml`, which also records why this is
Dependabot and not the Renovate the card asked for.

Its PRs face exactly the same required checks as yours: verified on the live one, which ran the full
`core`, `gateway` and `generated client` jobs before it could merge.

## Architecture decisions

Anything that constrains future work gets an ADR before the code. See
[docs/adr/README.md](docs/adr/README.md). If you find yourself explaining a choice in a PR
description at length, it wanted an ADR.

## The rule that matters most

Nothing may be configured by hand. Not a `kubectl apply` against a live cluster, not a click in
the Hetzner console, not a realm edited in the Keycloak admin UI. The cluster is rebuilt from
nothing on a routine basis, and anything created by hand disappears when it is.

If you cannot express a change as code in this repository, that is the bug.
