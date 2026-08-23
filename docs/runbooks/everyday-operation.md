# Runbook: everyday operation

Two commands. Everything else on this page is what to do when one of them says something
unexpected.

```bash
source ~/.xenopsbase.env      # once per terminal — nothing works without it
make up ENV=dev               # build the cluster and wait until it serves
make down ENV=dev             # destroy everything billable, and prove it
```

Run them from the repository root, in **Git Bash** — not PowerShell and not cmd. The Makefile is a
POSIX makefile and the scripts it calls are bash.

`ENV=dev` is the default, so `make up` alone does the same thing. Write it out anyway: the day you
have a staging environment, the habit is what stops you destroying the wrong one.

## Before the first command of the day

`~/.xenopsbase.env` holds every credential the Makefile needs — the Hetzner token, the R2 keys that
reach Terraform state, the per-bucket S3 keys, the SMTP key. It is **not** in the repository and
never will be.

`source` it. Do not run it, do not `bash` it: sourcing is what puts the variables into *this*
shell, and a subshell would take them away again.

Environment variables do not survive closing the terminal. If a command fails with something about
a missing token or a bucket it cannot reach, the first thing to check is whether you sourced the
file in this window.

## `make up`

Roughly **5–8 minutes**. What it does, in order:

1. `terraform init` on the cluster module
2. `terraform apply`, **retried up to three times** — provisioning fetches the k3s installer over
   the internet and that has returned a 504 mid-build. Apply is idempotent, so a retry continues
   rather than restarting. A real error fails the same way three times and then stops, so a repeat
   is information rather than noise.
3. Writes the kubeconfig out of Terraform state
4. Waits, up to 20 minutes, for the stack to actually serve — not for Terraform to finish, which is
   a different and much weaker claim

It prints its own elapsed time at the end. The measured rebuild baseline is ~305 s of Terraform on
dev sizing; the rest is Argo CD reconciling the platform.

**You do not need to wait for it to use the repository.** Building, testing and the whole local
stack work with no cluster at all — see below.

## `make down`

Roughly **8–10 minutes**, and most of that is one wait worth understanding.

1. **Backup check.** Reads the *bucket* and refuses to continue unless a base backup and current
   WAL are both there. Not the cluster's own status field, which reports success whether the last
   backup was an hour ago or never happened (#145).
2. **Releases the PVC-backed volumes.** These are created by the CSI driver, not by Terraform, so
   `terraform destroy` neither tracks nor removes them — it would report success and leave them
   billing forever. The driver runs *inside* the cluster, so this has to happen while the nodes are
   still alive. It has a **300-second budget**, and that budget is most of the wall clock.
3. `terraform destroy`
4. **Proves it worked.** Asserts the durable state survived and nothing billable is left.

The last line you want to see:

```
TEARDOWN CLEAN — durable state intact, nothing left billing.
```

### If it says TEARDOWN VERIFICATION FAILED

Read the `volumes` count. This is a **known bug**, [#159](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/159), and it happened on 2026-08-23: the Prometheus volume did not release inside the 300 s budget, `terraform destroy` succeeded anyway, and a 10 GB volume was left behind that no future destroy would ever reach.

The failure is the safety net working. Fix it by hand:

```bash
hcloud volume list                 # anything here is billing
hcloud volume delete <ID>
make verify-teardown ENV=dev       # confirm clean
```

**Do not ignore a failed teardown.** An orphaned volume is invisible and permanent — it does not
appear in Terraform state, and nothing will remind you.

## You probably do not need the cluster

This is the part worth internalising, because it is where the money and the waiting go.

For anything that is not infrastructure or platform work — writing endpoints, fixing tests,
touching the frontend, changing security rules — the local stack is faster and free:

```bash
make dev-up        # Postgres, Valkey, MinIO, Keycloak in Docker; both services from Maven
make dev-logs      # follow both service logs
make dev-down      # stop and remove everything, including volumes
```

It needs only Docker and a JDK — no cloud credentials, no cluster. Keycloak is loaded from the
*same* realm file the cluster uses, so `smoke` / `smoke-dev-only` logs in locally exactly as it
does on `app-dev`. Details in [local-development.md](local-development.md).

The integration tests need Docker too, and also no cluster:

```bash
cd services/core && ./mvnw verify -DskipITs=false
```

Bring the cluster up when you need to see something *deployed* — Argo CD reconciling, the ingress,
Cloudflare in front, the observability stack, or a real teardown/rebuild.

## Checking on a running cluster

| Question | Command |
|---|---|
| Is anything billing right now? | `hcloud server list` and `hcloud volume list` |
| Is the database actually recoverable? | `make backup-status ENV=dev` |
| Is anything exposed that should not be? | `make verify-exposure ENV=dev` |
| Can I talk to the cluster? | `make kubeconfig ENV=dev` then `kubectl get nodes` |
| What targets exist? | `make help` |

`hcloud server list` is the honest answer to "did I remember to tear it down". It talks to Hetzner,
not to any local state, so it is right even when something else is wrong.

## Cost

Three `cx23` servers in `fsn1`, billed by the hour, plus any volumes. Nothing here is free while it
is running, and the whole design assumes you destroy it between sessions —
[ADR-0002](../adr/0002-ephemeral-cluster-and-durable-state.md) makes that an everyday operation
rather than an exceptional one.

Actual figures are not recorded anywhere in this repository yet. That is T-8.4
([#62](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/62)), which adds cost guardrails
and an auto-destroy, and until it lands the only guard is remembering.

## What a destroy does *not* touch

Destroying the cluster is safe. It is designed to be routine, and these survive every time:

| Survives | Holds |
|---|---|
| `xenopsbase-dev-documents` | uploaded files |
| `xenopsbase-dev-pg-backups` | base backups and WAL — the database |
| `xenopsbase-dev-loki-chunks` | logs |
| The OS snapshot | what nodes are provisioned from; rebuilding it is the slow path |
| Terraform state in R2 | untouched by the cluster module |

What does **not** survive: anything written into the cluster by hand. That is the point of
[the rule in CONTRIBUTING](../../CONTRIBUTING.md) — if you cannot express a change as code in this
repository, it disappears at the next destroy, and it will.

## When something goes wrong

**`make up` failed three times.** Not transient. Read the last error rather than retrying; three
identical failures is the signal the retry loop exists to give you.

**`make down` failed the backup check.** The database may not be recoverable. Fix that first. If
you need to tear down anyway — a cluster with broken backups is exactly one you may still need to
destroy — `SKIP_BACKUP_CHECK=1 make down ENV=dev`, deliberately.

**Terraform says the state is locked.** Something else holds it, or a previous run died mid-flight.
See [terraform-state.md](terraform-state.md); do not force-unlock without reading it.

**Everything looks fine but nothing serves.** `make up` already waited for the stack, so this means
the wait timed out or something regressed after. Start with `kubectl get pods -A | grep -v Running`.

Deeper reference for the cluster itself — first-time setup, the Packer snapshot, CCM and CSI
verification, upgrades — is in [cluster.md](cluster.md). This page is the everyday subset.
