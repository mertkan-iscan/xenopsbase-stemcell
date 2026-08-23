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
