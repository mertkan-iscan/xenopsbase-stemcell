# ADR-0003: Secrets are encrypted in git with SOPS and age

- **Status:** Accepted
- **Date:** 2026-08-18
- **Task:** T-0.4

## Context

ADR-0002 makes the cluster disposable and forbids state created by hand. That reframes secrets
management away from the usual question. The usual question is "where do secrets live and how are
they rotated". The question here is narrower and harder:

> **What must already exist before the cluster does, and how small can that set be made?**

Every rebuild has to cross the same gap. Nothing inside the cluster is available yet — no operator,
no service account, no secret store — and yet the very first reconciliation needs credentials. Any
solution that assumes a running cluster is solving the wrong problem, because it cannot bootstrap
itself.

This bootstrap set is also the thing that gets lost. It cannot live in the cluster, it must not
live in a wiki, and it is the one artefact whose loss makes the durable-state boundary
meaningless: object storage full of intact backups is worthless if nothing can decrypt the
credentials needed to reach it.

A secondary force: the repository is public. Encrypted-in-git is only acceptable if the encryption
is genuinely load-bearing, not an obfuscation that assumes nobody is looking.

## Decision criteria

- **Size of the bootstrap set.** Fewer pre-existing secrets is strictly better, and one is the floor.
- **Rebuild without external dependencies.** A rebuild that fails because a third-party SaaS is
  down is a rebuild path that will fail on the day it is most needed.
- **Cost while idle.** Must be zero, per ADR-0002.
- **Reviewability.** A secret changing should be visible in a diff, even if its value is not.
- **Blast radius** if the bootstrap secret leaks.

## Decision

Secrets are stored **encrypted in this repository** using [SOPS](https://github.com/getsops/sops)
with [age](https://github.com/FiloSottile/age) keys, and decrypted inside the cluster by Argo CD
(ADR-0004) via the KSOPS plugin.

The bootstrap set is exactly **one secret per environment**: the age private key.

### The bootstrap chain

```
age private key (password manager, and a GitHub Actions secret for CI)
  -> Terraform variable, never written to state in plaintext
    -> Kubernetes Secret in the argocd namespace
      -> KSOPS in argocd-repo-server decrypts manifests at render time
        -> every other secret in the platform
```

Everything downstream of that first key is code in this repository. There is one thing to keep
safe, one thing to rotate carefully, and one thing whose loss is unrecoverable — and it is written
down here so it cannot be discovered during an incident.

### Rules

- **One age key pair per environment.** dev, staging and prod do not share a key; a leaked dev key
  must not decrypt production.
- **Public keys are committed** in `.sops.yaml`. Private keys never touch the repository.
- **`.sops.yaml` encrypts values, not keys.** Secret *names* stay readable so a diff shows that a
  secret changed and which one, without revealing what it changed to.
- **Rotation rotates the underlying credential, never only the ciphertext.** Git history is
  permanent and public: re-encrypting an unchanged value protects nothing, because the old
  ciphertext and the old key are forever recoverable together. A leaked key means every secret it
  ever encrypted is compromised, including in past commits, and all of them must be reissued at
  their source.
- **Every secret is encrypted to two recipients**, and both must be able to decrypt every file. See
  the amendment below — this bullet used to claim an escrow that did not exist.

## Consequences

### What this makes easy

- A rebuild needs one input. `make up` with the age key present regenerates every credential in
  the platform from git, with no external service in the path.
- Zero idle cost and zero additional running components.
- Secrets are reviewed like everything else: a pull request shows which secret changed, when and
  by whom.
- Works identically on a laptop, in CI, and in-cluster, so local development and production share
  one mechanism.

### What this makes hard

- **Rotation is a commit, not an API call.** Acceptable at this scale; genuinely painful with many
  secrets or a compliance-driven rotation schedule.
- **Git history is permanent and now public.** This is the sharpest edge of the decision. The
  mitigation is the rotation rule above, and it depends on discipline rather than tooling.
- **No audit trail of reads.** Git records who changed a secret, never who decrypted one.
- **Argo CD needs KSOPS wiring** — a plugin sidecar on `argocd-repo-server`, which Flux would have
  provided natively. ADR-0004 accepts this cost knowingly; it is a fixed, one-time setup, not
  ongoing work.

### What it commits us to

T-2.3 implements this chain, and every later component that needs a credential inherits it. Moving
to External Secrets later is a contained migration — the consumers see a Kubernetes Secret either
way — so this is not a one-way door.

## Alternatives considered

### External Secrets Operator with a hosted manager — rejected for now

Infisical, Bitwarden Secrets Manager or Doppler with ESO pulling into the cluster. Real rotation,
a read audit trail, and nothing sensitive in git — genuinely better on three criteria.

Rejected because it fails the two that dominate here. It puts a third-party service on the
critical path of every rebuild, so their outage becomes an inability to recover. And it does not
actually shrink the bootstrap set: ESO still needs one credential to authenticate, so the pre-existing
secret count stays at one while the dependency count rises.

The honest summary is that this is the better choice at a team scale with a compliance requirement,
and the worse choice for a solo, cost-floored, rebuild-constantly project. **Revisit when a second
person needs access**, at which point the audit trail starts earning its cost.

### Self-hosted Vault — rejected

The most capable option and the worst architectural fit. Vault needs durable storage and unseal
keys, so an ephemeral cluster would have to externalize Vault's own state and manage its unseal
material — solving ADR-0002 a second time, for a component that exists only to solve it once.

### Sealed Secrets — rejected

Encrypts to a controller-held key, which is a good fit for a long-lived cluster. Wrong here: the
sealing key lives *in* the cluster, so either it becomes durable state that must be externalized
anyway, or every rebuild invalidates every sealed secret in the repository.

## Revisit if

- A second person needs access to secrets, making the missing read audit trail material.
- Rotation frequency rises to where commit-based rotation is a genuine burden.
- The age key is ever leaked, which forces a full reissue and is the moment to reconsider whether
  permanent public git history is the right store.

## Amendment, 2026-08-23 — key custody (T-0.8, #163)

This ADR chose SOPS and reasoned about its operational cost. It never discussed **custody**, and
the rules above asserted that the private key was "escrowed in a password manager plus one offline
copy". That was not true and had never been true. There was one recipient:

```
age1sgwm6ckyjns0grwu6hsc6zhh2esh3ja7xmwynkw9ukc3ygq8tf8qsgusx5
```

and its private half existed in exactly one place — `TF_VAR_sops_age_key` in `~/.xenopsbase.env`,
on one machine. No second recipient, no escrow, no documented recovery. The single-recipient setup
is what the first `.sops.yaml` happened to contain and was never revisited; the escrow sentence was
written as intent and read ever after as fact.

### Why this outranked the rest of the disaster recovery plan

Every RTO in `docs/runbooks/disaster-recovery.md` was conditional on one file surviving, and none
of them said so. The cluster rebuilds from nothing, Postgres restores from the WAL archive, the
documents were never at risk — and none of it comes up, because the database credentials, the
gateway client secret, the Hetzner S3 keys and the Cloudflare token are all ciphertext nothing can
read. **Backups you cannot decrypt are not backups.**

It is also the failure with no warning. A disk dies or a laptop is replaced and everything keeps
working until the next time something needs decrypting — which is during a recovery.

### Decision

A **second age recipient, held offline**, added as of this amendment:

```
age16y5yn6mddywkr8vwf5xjuukw6c33vy3yp2gtpmafr09fltlw3qfq7repy8
```

Every file under `platform/envs/*/secrets/` is encrypted to both. Either key alone decrypts
everything; neither is required.

**Offline rather than a cloud KMS recipient**, deliberately. KMS is recoverable through an account
rather than an object, which is genuinely stronger against losing hardware — and it makes recovery
depend on a provider being reachable at exactly the moment you are recovering, adds a credential to
manage, and adds a bill. An offline copy has no dependency and no recurring cost, and is only as
good as the discipline storing it.

That trade is not free and the weakness is real, so KMS is not rejected — it is **deferred as a
second layer** (T-0.9, #191). Two independent mechanisms beat choosing between them; doing the
cheap one immediately beats debating the expensive one while a single point of failure stands.

**A second person's key** was not an option: this is a one-person project, so it would name the
same human twice.

### What enforces it

Adding a recipient to `.sops.yaml` changes what *new* files are encrypted to. It does **nothing**
to files that already exist, and sops reports no error — so the escrow key can be present in the
configuration and absent from every secret it exists to rescue, with nothing to show for the
difference until a recovery. That is the same shape as every other defect this project has found: a
mechanism reporting success while doing nothing.

Two things close it:

- `make secrets-rekey` re-encrypts every secret to the current recipient list.
- `make secrets-verify` compares the recipients `.sops.yaml` names against the recipients each file
  actually carries, and fails if any is missing. It needs **no key** — recipients are public
  metadata — so it runs on every pull request in `secrets.yml`, with no credential near CI.

### What this does not solve

Both halves of both keys are still material a single person holds. This removes the single *object*
whose loss is unrecoverable; it does not remove the single *person*. On a team, a colleague's key
would be the natural third recipient and the right answer.
