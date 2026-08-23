# Runbook: secrets

Secrets live **encrypted in this public repository**, using SOPS with age keys
([ADR-0003](../adr/0003-secrets-management.md)).

That sounds alarming until the arithmetic is clear: the encryption is load-bearing, and the
alternative — a secrets service on the critical path of every rebuild — means their outage becomes
your inability to recover.

## The bootstrap set is one key, held twice

The whole point of this choice is how small the "must exist before the cluster does" set is:

```
an age private key (either of two)
  -> Terraform variable, never in a file
    -> Kubernetes Secret in the argocd namespace
      -> Argo CD decrypts every other secret at render time
```

Everything downstream of that one key is code in this repository. **There is one thing to keep
safe, one thing to rotate carefully, and one thing whose loss is unrecoverable** — which is why it
is now held in two places rather than one.

### The two recipients

Every file under `platform/envs/*/secrets/` is encrypted to both. **Either alone decrypts
everything; neither is required.** Both public halves are safe to publish and are committed in
`.sops.yaml`:

| Recipient | Private half lives | Used for |
|---|---|---|
| `age1sgwm6cky…q8tf8qsgusx5` | `TF_VAR_sops_age_key` in `~/.xenopsbase.env`, and the `SOPS_AGE_KEY` GitHub Actions secret | everyday work and CI |
| `age16y5yn6md…tlw3qfq7repy8` | **offline only** — see below | recovery, and nothing else |

The everyday key is the one on this machine. The escrow key exists so that losing this machine is
survivable, and it earns that only by living somewhere this machine is not.

### ⚠️ Where the escrow key must live

Generated on 2026-08-23 (T-0.8) and written to:

```
~/.xenopsbase-escrow.age
```

**That location is a staging post, not the escrow.** A second key sitting on the same disk as the
first is not redundancy — it is two copies of the same failure. Move it and delete the local copy:

```bash
cat ~/.xenopsbase-escrow.age        # paste into a password manager, or print it
rm ~/.xenopsbase-escrow.age
```

A password manager **and** one offline copy is the standard advice and it is right here too: a
password manager you are locked out of and a laptop that died are the same problem.

Do **not** put it in `~/.xenopsbase.env`. That file is sourced into every shell that runs `make`,
which is exactly the exposure the second key exists to be free of.

### Recovering with the escrow key

The key that decrypts is chosen by the environment, so recovery is a matter of pointing sops at the
other file:

```bash
SOPS_AGE_KEY_FILE=/path/to/escrow.age sops decrypt platform/envs/dev/secrets/core-db.yaml
```

or, to bring the whole platform up on a machine that has only the escrow key, export it the way the
everyday key is exported:

```bash
export TF_VAR_sops_age_key="$(cat /path/to/escrow.age)"
```

Everything from there is the ordinary path — `make up`, Argo CD, the rest.

**Exercise this.** A second key nobody has ever decrypted with is the same class of belief as an
untested restore. Verified once on 2026-08-23 by decrypting with the primary removed from the
environment; the control — neither key present — correctly refused.

### Keeping both recipients on every file

Adding a recipient to `.sops.yaml` changes what **new** files are encrypted to. It does nothing to
files that already exist, and sops reports no error. So the escrow key can be in the configuration
and in none of the secrets it exists to rescue, with nothing to show for the difference until a
recovery.

```bash
make secrets-verify    # does every file carry every recipient?
make secrets-rekey     # re-encrypt everything to the current list
```

`secrets-verify` needs **no key** — recipients are public metadata — so it runs on every pull
request in `secrets.yml` with no credential anywhere near CI.

## Working with secrets

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

Create or edit:

```bash
sops platform/envs/dev/secrets/example.yaml
```

Encrypt a file written by something else:

```bash
sops --encrypt --in-place platform/envs/dev/secrets/example.yaml
```

Read one without editing:

```bash
sops --decrypt platform/envs/dev/secrets/example.yaml
```

### What a diff shows

Only **values** are encrypted, not keys:

```yaml
metadata:
  name: cloudflare-api-token      # readable
stringData:
  api-token: ENC[AES256_GCM,data:...,type:str]   # not
```

That is deliberate. A pull request shows *which* secret changed, when, and by whom, without
revealing what it changed to. Encrypting whole files would turn every secret change into an opaque
blob that nobody can review.

## Rotation

**Rotate the credential at its source, never merely re-encrypt.**

Git history is permanent and this repository is public. Re-encrypting an unchanged value protects
nothing: the old ciphertext and the old key remain recoverable together forever. If the age key
leaks, every secret it ever encrypted is compromised **including in past commits**, and all of them
must be reissued where they were created.

Per environment, so a leaked dev key cannot decrypt production. `staging` and `prod` get their own
keys as those environments are built; until then a secrets file under those paths fails to encrypt
rather than silently using the dev key — the safe way round.

## The CI check

```bash
make check-secrets
```

Runs on **every** pull request, with no path filter — a secret can be committed anywhere, and the
one place it will be is the file nobody thought to watch.

Two independent checks:

1. **Every file under `secrets/` must actually be SOPS-encrypted.** This catches the common
   failure: edit a secret, forget to re-encrypt, commit the plaintext. The file looks right and the
   diff looks plausible.
2. **Credential shapes anywhere in tracked files** — age private keys, Tailscale auth keys, PEM
   private key blocks, and assignment forms for the tokens this project uses. Deliberately narrow:
   broad heuristics produce false positives, and a check people routinely override is not a check.

Verified to fail on a planted plaintext secret, not merely to pass on a clean tree.

### If a secret does reach the repository

**Rewriting history is not sufficient.** The repository is public; assume it was fetched the moment
it was pushed. Rotate the credential at its source, then clean history if you like — in that order.

## Known gaps

**No audit trail of reads.** Git records who *changed* a secret, never who *decrypted* one. ADR-0003
accepted this: it is the cost of not depending on a secrets service, and it starts to matter when a
second person needs access.

**Rotation is a commit, not an API call.** Fine at this scale, genuinely painful with many secrets
or a compliance-driven schedule.

**Both keys are held by one person.** Two recipients remove the single *object* whose loss is
unrecoverable. They do not remove the single *person*. On a team a colleague's key would be the
natural third recipient; a cloud KMS recipient is the alternative for a solo project and is tracked
as T-0.9 (#191).
