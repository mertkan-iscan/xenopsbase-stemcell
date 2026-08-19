# Runbook: secrets

Secrets live **encrypted in this public repository**, using SOPS with age keys
([ADR-0003](../adr/0003-secrets-management.md)).

That sounds alarming until the arithmetic is clear: the encryption is load-bearing, and the
alternative — a secrets service on the critical path of every rebuild — means their outage becomes
your inability to recover.

## The bootstrap set is one key

The whole point of this choice is how small the "must exist before the cluster does" set is:

```
age private key (password manager + one offline copy)
  -> Terraform variable, never in a file
    -> Kubernetes Secret in the argocd namespace
      -> Argo CD decrypts every other secret at render time
```

Everything downstream of that one key is code in this repository. **There is one thing to keep
safe, one thing to rotate carefully, and one thing whose loss is unrecoverable.**

### ⚠️ Escrow the private key now

```
~/.config/sops/age/keys.txt
```

Losing it does not lose the cluster — that rebuilds. It loses the ability to decrypt every secret
in git, which means reissuing each one at its source: Hetzner credentials, the Cloudflare token,
the Tailscale key, database passwords.

Put it in a password manager **and** one offline copy. Neither alone is enough: a password manager
you are locked out of and a laptop that died are the same problem.

The public half is safe to publish and is committed in `.sops.yaml`:

```
age1sgwm6ckyjns0grwu6hsc6zhh2esh3ja7xmwynkw9ukc3ygq8tf8qsgusx5
```

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
