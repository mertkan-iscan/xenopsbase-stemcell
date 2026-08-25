# Forking the stemcell into a new project

**Task:** T-4.5 (#39)

This repository is a template. Everything in it works, and almost all of it is generic — but a
handful of identifiers are specific to *this* project, and a fork that misses one fails at a
different and less obvious moment than the fork itself.

The list below is derived from the repository rather than remembered: every count is a `git grep`.

## What is actually project-specific

| What | Where | Occurrences |
|---|---|---|
| Java package `com.xenopsoftware.*` | `services/*/src` | 192 files |
| Domain `xenopsoftware.com` | hostnames, realm, edge module, docs | 219 files |
| Resource prefix `xenopsbase` | buckets, cluster name, Keycloak realm, tfvars | 85 files |
| GitHub owner and repo `mertkan-iscan/xenopsbase-stemcell` | image paths, Argo `repoURL`, docs | 28 files |
| Tailnet `tail894b71.ts.net` | cluster tfvars, ADR-0006 | 5 files |
| age recipients | `.sops.yaml`, plus every encrypted secret | 1 + 16 |

Nothing else has to change. In particular the ADRs, runbooks, scripts, workflows, test strategy and
Makefile are generic, and rewriting them is how a fork loses the reasoning it was forked for.

---

## Before you touch the code

Four accounts, and the order matters because two of them gate the rest.

1. **A Hetzner Cloud project.** Gives you a project ID and an API token.
2. **A Hetzner Object Storage** set of credentials — separate from the cloud token, and per-bucket
   keys rather than one. See [object-storage.md](runbooks/object-storage.md); the least-privilege
   claim in T-1.2 depends on that separation.
3. **A Cloudflare account with a zone you control.** Gives you an account ID, a zone ID and an API
   token. The token's permissions are the single most common thing to get wrong — `preflight.sh`
   names each one it needs, and since T-1.15 it proves Edit rather than assuming it.
4. **A Cloudflare R2 bucket** for Terraform state (ADR-0005), with its own access key.

Also: a **Tailscale** account, because every environment runs `node_transport_mode = "tailscale"`
and the cluster has no public API endpoint (T-1.5). You need a **reusable** auth key — a single-use
key registers the first node and the rest hang forever waiting to join, which presents as a rebuild
that never converges rather than as an error.

---

## Step 1 — rename the package

```bash
# From the repository root. Adjust the target package.
git grep -l 'com\.xenopsoftware' -- services | xargs sed -i 's/com\.xenopsoftware/com\.yourcompany/g'
find services -type d -path '*/com/xenopsoftware' | while read -r d; do
  git mv "$d" "$(dirname "$d")/yourcompany"
done
```

Then check nothing was missed, because a stale package name compiles fine until Spring cannot find
a bean:

```bash
git grep -n 'xenopsoftware' -- services | grep -v '\.md:'
```

The ArchUnit rules in `TechnicalStructureTest` are written against the package root, so a partial
rename fails there rather than at runtime — which is the good outcome.

## Step 2 — rename the resource prefix

`xenopsbase` is the prefix for bucket names, the cluster name, the Keycloak realm and the Terraform
workspace keys.

```bash
git grep -l 'xenopsbase' -- ':!docs' ':!*.md' | xargs sed -i 's/xenopsbase/yourproject/g'
```

**Bucket names are global to the provider**, so pick something unlikely to collide. They are also
per-environment on purpose — `yourproject-dev-documents`, `yourproject-prod-documents` — because
bucket policies are the only isolation Hetzner offers and one shared bucket would mean allowlisting
both environments' keys on it.

Two things this touches that are easy to overlook:

- **The Keycloak realm name**, in `platform/envs/dev/keycloak/realm-import.yaml` and in both
  services' `application*.yml` issuer URIs. They must agree, or login fails after a redirect that
  looked fine.
- **The Terraform state keys**, derived from the environment in the Makefile. Changing the prefix
  without changing them means planning one project's config against another's state — the failure
  [environments.md](runbooks/environments.md) exists to prevent.

## Step 3 — point it at your GitHub repository

```bash
git grep -l 'mertkan-iscan/xenopsbase-stemcell' | xargs sed -i 's|mertkan-iscan/xenopsbase-stemcell|youruser/yourrepo|g'
```

This covers two things that fail very differently:

- **`ghcr.io/...` image paths** in `platform/envs/dev/services/kustomization.yaml`. Wrong here and
  the pods `ImagePullBackOff`, which is loud.
- **`repoURL`** in every Argo CD `Application`. Wrong here and Argo CD happily reconciles *this*
  repository into *your* cluster, which is quiet and much worse. The chart `repoURL`s pointing at
  `charts.jetstack.io` and similar are upstream and must not be changed.

## Step 4 — your own domain

Replace `xenopsoftware.com` and the `app-dev` / `auth-dev` hostnames. They appear in the edge
module, the ingress manifests, the realm's redirect URIs and both services' configuration.

The realm's `redirectUris` and `webOrigins` are matched by Cloudflare and Keycloak **by exact
string**, and Keycloak answers `400 Invalid parameter: redirect_uri` on any difference. That is the
single most common post-fork login failure.

## Step 5 — your own secrets

This is the step that cannot be scripted, and the one where a shortcut is permanent.

Every file under `platform/envs/*/secrets/` is encrypted to **this project's** age keys. You cannot
decrypt them and you should not want to: they are live credentials for infrastructure that is not
yours.

```bash
# NOT `rm *.yaml` — kustomization.yaml and secret-generator.yaml live here too
# and are not secrets.
cd platform/envs/dev/secrets
ls | grep -vE '^(kustomization|secret-generator)\.yaml$' | xargs rm --
```

Then generate your own key, put its public half in `.sops.yaml`, and create each secret from the
example. [secrets.md](runbooks/secrets.md) lists what each one holds.

**Generate two recipients, not one.** T-0.8 exists because this project ran for weeks with a single
age key whose private half lived in one file on one machine — every recovery path in the disaster
recovery plan was conditional on it and said so nowhere. `make secrets-verify` enforces that every
file carries every recipient.

`*.secrets.tfvars` is gitignored and only the `.example` files are tracked — verified, none has ever
been committed. Copy each example and fill in your own account and zone IDs.

## Step 6 — CI and repository settings

None of these live in the repository, so a fork gets none of them:

```bash
source ~/.yourproject.env && bash infra/scripts/set-ci-secrets.sh
```

Then, and these are the ones people forget because nothing fails without them:

- **Branch protection.** T-0.7 found that `main` required no status check at all while CONTRIBUTING
  claimed otherwise. Require `no unencrypted secrets`, `Conventional Commits title` and `services`,
  and set `enforce_admins`.
- **`squash_merge_commit_title: PR_TITLE`.** The default uses the *commit* title on a single-commit
  branch, so the linted string and the landed string differ (T-0.10).
- **Secret scanning, push protection, Dependabot alerts and security updates.** All free on a public
  repository and all off by default (T-5.8).
- **A `prod` environment** with a required reviewer, if you want the promotion gate (T-6.3).

## Step 7 — bring it up

```bash
make snapshot                 # once per Hetzner project; Packer must be exactly 1.16.0
make golden-image             # the image nodes boot; boot-tests before publishing
make storage-apply ENV=dev
make edge-apply ENV=dev
make up ENV=dev
make smoke ENV=dev
```

[cold-rebuild.md](runbooks/cold-rebuild.md) carries the measured timings for that sequence, and
is the only place they are stated — a second copy here would be a second thing to go stale, and a
stale build time gets quoted as a capacity fact.

[everyday-operation.md](runbooks/everyday-operation.md) is the daily page after that.

---

## What to delete

**The board references.** Comments throughout say things like *"T-3.20, #186"*. They are pointers
into this repository's issues and mean nothing in a fork.

Deleting them is tempting and mostly wrong. Each one is attached to a paragraph explaining why the
code is the way it is, and those paragraphs are the reason to fork this rather than start from a
generator. A stale issue number next to a real explanation costs a moment of confusion; deleting the
explanation costs the next person a day.

Delete instead:

- `docs/spikes/` — investigations specific to decisions already made here.
- The measured numbers, once yours differ. `docs/slos.md`, the baselines in
  [cluster.md](runbooks/cluster.md) and the timings in
  [cold-rebuild.md](runbooks/cold-rebuild.md) are all measurements of *this* hardware. Keeping
  someone else's numbers is worse than having none, because they look like yours.
- `platform/envs/dev/secrets/*.yaml`, as above.

## What to keep

- **The ADRs.** They are the argument, not the outcome. `docs/adr/0002` in particular is what makes
  the rest coherent.
- **The runbooks**, including the "when the automation fails" half of
  [cold-rebuild.md](runbooks/cold-rebuild.md). Every entry there is something that actually
  happened.
- **The scripts and their comments.** `preflight.sh`, `verify-teardown.sh`, `verify-backup.sh` and
  `flush-wal.sh` each exist because something failed silently once. The comments say what.
- **[testing.md](testing.md)**, and specifically its *does not cover* sections. A test strategy
  without stated boundaries grows until each layer duplicates the one above it.

---

## The thing most likely to bite you

Not any of the renames — those fail loudly.

It is that **several safety properties in this repository are accidents of layout that nothing
states as requirements**, and a fork that reorganises will undo them without noticing:

- Valkey lives in the `cache` namespace, not `apps`. Move it and the gateway crash-loops on an
  injected `VALKEY_PORT` (T-2.17 — now defended with `enableServiceLinks: false`, but the
  namespace split is still load-bearing for anything else).
- The storage and cluster Terraform modules have **separate state**. That separation is what stops
  a cluster teardown reaching the durable buckets (ADR-0002). Collapsing them into one module for
  tidiness removes the boundary the whole design rests on.
- `auth-*` is deliberately **not** behind Cloudflare Access, while `app-*` is. Putting the identity
  provider behind another identity provider breaks the login it exists to serve.

Each of those is written down where it matters. This is the list of places where "that looks
untidy" is the wrong instinct.
