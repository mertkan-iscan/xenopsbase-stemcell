# Runbook: promotion

Moving a build from one environment to the next. **Promotion is a git operation** — nothing here
builds, pushes an image, or connects to a cluster.

```bash
make promote SERVICE=all FROM=dev TO=staging
```

or from the Actions tab, **Promote** → pick service, from, to. The workflow does the same thing and
adds the approval gate.

## What actually moves

One line per service:

```yaml
# platform/envs/<env>/services/kustomization.yaml
images:
  - name: ghcr.io/mertkan-iscan/xenopsbase-stemcell/gateway
    digest: sha256:b660717dc35fd8e4ce8ec77a66b146dab81dcbdcad3feb45655cd63fcfc0408b
```

An environment **is** a directory. Terraform bootstraps an Argo CD root Application pointing at
`platform/envs/${environment}`, so promoting a build between environments is copying a digest
between two files and committing it. The target cluster's Argo CD applies it when the commit
reaches `main`.

**A digest, never a tag.** `main` moves, and even a commit-SHA tag can be overwritten by a re-run.
The digest is the only reference that names the exact bytes that passed the tests. Promoting a tag
promotes whatever it points at when the target next pulls, which is not the thing that was
verified.

This also means **rollback is `git revert`** on the promotion commit — the same mechanism, run
backwards, with no separate procedure to remember (T-6.4).

## The gate before production

| Environment | Approval | Configured |
|---|---|---|
| `dev` | none | images land automatically on merge to `main` |
| `staging` | none | promotion is the deliberate act |
| `prod` | **required reviewer** | `can_admins_bypass: false`, protected branches only |

A dispatch aimed at `prod` pauses before it does anything and waits for a person. GitHub records
who approved it against the deployment, so a production deploy is traceable to a commit *and* an
approver.

`can_admins_bypass` is **false** for the same reason `enforce_admins` is true on branch protection
(T-0.7): on a one-person project, the only person who could route around the gate is the person who
built it, and a gate that its author can wave through is a note-to-self.

**`dev` → `prod` is refused.** Not a shortcut — a build that never ran in staging being sent to
production. If that is genuinely wanted it is two deliberate dispatches, each with its own record.

## Why the workflow pushes a branch instead of opening a pull request

A pull request opened with `GITHUB_TOKEN` does not trigger workflows. GitHub suppresses that to
prevent recursion, and the consequence here is specific: the required status checks would never
report, so the promotion pull request would sit at *"Expected — waiting for status"* forever and
could never merge. Exactly the deadlock T-0.7 had to design around.

So the workflow pushes `promote/<env>-<timestamp>` and prints the compare link. Opening the pull
request is one click, by a human, and the checks run normally.

## Confirming it landed

```bash
make rollout-status ENV=dev
make rollout-status ENV=dev SHA=2e44a9e     # and that it is running THAT commit
```

Synced and Healthy only says the cluster matches *some* revision. Passing `SHA` is what
distinguishes a healthy cluster from a healthy cluster that never received the promotion.

Argo CD polls rather than being notified, so a few minutes of lag after a merge is normal. It is a
failure only if it persists.

### Two things to know before you trust it

**It is not in CI, and it cannot be.** The Kubernetes API is a tailnet address with 6443 closed on
every public IP (T-1.5), so no GitHub-hosted runner can reach it. Nothing automatic fails when a
deploy does not land — somebody has to run the command and look. **The loop is open**, deliberately
recorded as [#195](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/195).

**`postgres` currently reports OutOfSync on a healthy cluster**, so `rollout-status` fails against
dev today. That is the check working — the drift is real — but a check that always fails is one
people learn to skip. Tracked as
[#193](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/193).

## There is nothing to promote into yet

`platform/envs/` contains one directory: `dev`.

```
$ make promote TO=staging
error: platform/envs/staging/services/kustomization.yaml does not exist.
```

That is the correct answer, and it is why this runbook describes a mechanism you cannot yet
exercise end to end. The blocker is not the directory — it is that a platform tree needs its own
secrets, and `.sops.yaml` requires staging and prod to have their **own** age keys so a leaked dev
key cannot decrypt production. That means real credentials for real infrastructure that has to be
paid for.

Tracked as [#194](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/194), including the
cost decision it forces: ADR-0002 sets idle cost at zero and assumes one environment torn down
between sessions. A second standing cluster changes that.

## Traceability

Every promotion commit records where the build came from, not merely that something moved:

```
chore(platform): promote all from dev to staging

  gateway:
      was sha256:be372cca…
      now sha256:b660717d…

Promoted by: mertkan-iscan
Source env:  dev
Source ref:  2e44a9e0d7ebc7b60b7bbce5dbfbb5fce9682e93
Workflow:    https://github.com/…/actions/runs/…
```

Source ref is the commit the source environment was on when the digest was read — so a production
deploy leads back to the exact tree that was tested, through staging, without depending on anyone's
memory.

---

# Rollback

```bash
make rollback ENV=dev SERVICE=gateway
```

or Actions → **Rollback** → pick environment and service. Either way it edits one line and leaves a
diff; merging it is the deploy.

## What it rolls back to

The digest this environment ran **before** the current one, found by walking the git history of
`platform/envs/<env>/services/kustomization.yaml` **per image**.

Per image matters: core and gateway are promoted independently, so the last commit touching that
file may have moved the other service and left this one alone. "The commit before HEAD" would roll
back the wrong thing, and would look like it worked.

"Known-good" here means *it was actually running in this environment and nobody was rolling back
from it*. That is deliberately weaker than "passed the test suite" — a target chosen by test
results can be a build that never ran here; a target chosen by history is the state you were in
when things were fine.

## Rollback is not gated, and that is a decision

Promotion to production requires a reviewer. Rollback requires none, in any environment.

Promotion puts code into production that nobody approved for it. Rollback does the opposite: it
returns to a digest that was already approved, already promoted, and already running until the
change being undone. There is nothing new for a reviewer to assess, and the entire cost of gating
it would be paid during an incident — the one time nobody should be waiting for a second person.

The merge to `main` still requires green checks. Rollback is **ungated, not unreviewed**.

## ⚠️ Rollback does not undo a database migration

This is the limit that turns a calm rollback into an outage, so it is worth being blunt.

Flyway migrations are **forward-only** and have already been applied by the time you are rolling
back. Reverting the image runs **older code against a newer schema**:

| The migration you are undoing | Rolling the image back is |
|---|---|
| Added a table, column, or index | **Safe.** Old code ignores what it does not know about |
| Widened a type, added a nullable column | **Safe.** |
| Dropped or renamed a column | **Not safe.** Old code queries something that no longer exists |
| Backfilled or transformed data | **Not safe**, and not visible — the data is already changed |

For the unsafe cases the recovery is a **point-in-time restore**, not this
([disaster-recovery.md](disaster-recovery.md)). PITR was drilled under T-7.4: restore took 107s,
worst-case RPO 301s.

Check what shipped before assuming:

```bash
git diff <rollback-target>..HEAD -- services/core/src/main/resources/db/migration
```

Empty output means the rollback is a pure image change. Anything else, read it before merging.

## Measured

Drilled on dev, 2026-08-23. The gateway rolled back one digest and forward again, against the
running cluster.

| Step | Time |
|---|---|
| `make rollback` to a reviewable diff | seconds — a local file edit |
| Pull request checks | **12 s** |
| Merge → Argo CD applied the change | 10 s |
| Argo CD applied → pods Running on the previous digest | 23 s |
| **Total, merge to healthy** | **33 s** |
| Roll forward again, same measurement | 36 s |

**Against the five-minute target: 33 seconds.** The target was set against roughly three minutes
elsewhere; the difference is that nothing is built or pushed — a rollback here is one line of YAML
and a pull of an image that is already in the registry and already in the node's image cache,
because it was running an hour ago.

The 12-second check time is not luck. T-0.7 moved path filtering from the workflow triggers into
the jobs, so a change touching only `platform/` skips both Maven builds and every Terraform job.
A rollback does not wait on a full build of the code it is rolling away from.

### The drill actually verified behaviour, not just labels

A digest changing in `kubectl get deploy` proves a manifest was applied, not that anything is
different. So the drill asked the rolled-back gateway a question only the newer image answers
correctly — `smoke-admin` reaching an admin endpoint, which is the T-3.20 (#186) fix:

```
on the rolled-back digest   smoke-admin -> /management/loggers   403
after rolling forward       smoke-admin -> /management/loggers   200
                            smoke       -> /management/loggers   403
```

The 403 is the #186 defect returning exactly as it should on that digest. Without this step the
drill would have measured how fast Kubernetes can replace a pod, which was never the question.

### Rolling forward is `git revert`

The roll-forward was not a second mechanism. It was `git revert` on the rollback commit — the same
operation run backwards, which is the whole reason promotion is a digest in a file rather than a
procedure.

## Confirming

```bash
make rollout-status ENV=dev
```

Argo CD polls, so allow a few minutes of lag before treating a stale revision as a failure.
