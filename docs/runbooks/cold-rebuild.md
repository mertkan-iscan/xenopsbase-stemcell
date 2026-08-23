# Runbook: cold rebuild

Destroying everything and building it back. In an ephemeral model this one path is the deploy path,
the disaster-recovery procedure, and the only evidence that ADR-0002's durable-state boundary is
real rather than asserted.

```bash
make cold-rebuild ENV=dev
```

That is the drill, not the procedure. It seeds a document, verifies backups, destroys, rebuilds,
smokes, and then reads the document back byte for byte. The procedure underneath it is two
commands:

```bash
make down ENV=dev
make up ENV=dev
```

## Measured

Drilled 2026-08-23 against dev, with the OS snapshot present (the warm path, and the everyday one):

| Step | Time |
|---|---|
| Destroy — including the WAL flush and the volume sweep | 513 s |
| Rebuild to serving — Terraform, then Argo CD converging 14 applications | 813 s |
| Smoke suite | 9 s |
| **Destroy to verified, data proven intact** | **1335 s — 22 min** |

Against ADR-0002's targets:

| | Target | Measured |
|---|---|---|
| Cold rebuild — to serving, data restored | ≤ 60 min | **22 min**, 38 min of headroom |
| Warm start — `make up` on unchanged code | ≤ 20 min | 13.5 min |

Add ~5.5 min for the Packer snapshot build if the Hetzner project is genuinely empty
(322 s measured under T-1.3), which still lands around 28 minutes.

The headroom is the point rather than the number. ADR-0002 says a rebuild path that is slow stops
being exercised, and an unexercised recovery path does not work.

## What survives, and what the drill actually proves

`smoke.sh` creates a document and deletes it inside one run. It would pass perfectly against an
environment that had just lost every document it ever held. So the drill seeds a document **before**
the destroy and reads it back **after** the rebuild.

The subtle half is ownership. Documents are owned by the Keycloak `sub`, and the realm is rebuilt
from a file on every cold start. If Keycloak minted new user ids, the rows would survive and become
unreachable — intact, owned by nobody, and invisible to every health check. ADR-0010 pins the ids
for exactly that reason, and this drill is what tests that they are pinned.

| Survives a destroy | Why |
|---|---|
| `xenopsbase-<env>-documents` | separate Terraform root module, unreachable from the cluster destroy |
| `xenopsbase-<env>-pg-backups` | base backups and WAL — the database itself |
| `xenopsbase-<env>-loki-chunks` | logs |
| The OS snapshot | durable in ADR-0002's sense; `make down` does not touch it |
| Terraform state in R2 | separate backend |
| Both age private keys | not in the project at all (T-0.8) |

The snapshot is why there are two numbers. A rebuild with it present is the **warm path** and the
everyday one; a rebuild into a genuinely empty Hetzner project pays the Packer build as well. The
drill measures the warm path by default and `SNAPSHOT=1` includes the build, rather than collapsing
them into one figure that describes neither case.

---

# When the automation fails

Everything below has actually happened.

## `make down` fails teardown verification

```
volumes                        1
    ^ ORPHANED. Terraform no longer tracks these
TEARDOWN VERIFICATION FAILED
```

Known bug, [#159](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/159). The CSI driver
creates PVC-backed volumes; Terraform never tracks them, so `terraform destroy` reports success and
leaves them billing. The release step has a 300-second budget and the Prometheus volume regularly
exceeds it.

**The failure is the safety net working.** Delete by hand:

```bash
hcloud volume list
hcloud volume delete <ID>
make verify-teardown ENV=dev
```

Never ignore it. An orphaned volume is invisible and permanent.

## `make down` refuses to start

```
BACKUP CHECK FAILED
```

The database is not provably recoverable and you are about to destroy it. Fix that first. If you
genuinely need to tear down a cluster whose backups are broken — which is a real situation —

```bash
SKIP_BACKUP_CHECK=1 make down ENV=dev
```

deliberately, and understand that the data is gone.

## `make up` fails once or twice and then works

Expected. Provisioning fetches the k3s installer over the internet and that has returned 504
mid-build. `terraform apply` is idempotent, so the retry continues rather than restarting.

**Three identical failures is information**, not noise — the loop stops there because a real error
fails the same way every time. Read the last error rather than running it again.

## `make up` fails with "no image found"

The OS snapshot is missing. It is durable state, so this means it was deleted, or this is a genuinely
empty Hetzner project.

```bash
make snapshot
```

Packer must be **exactly 1.16.0** — the kube-hetzner template pins `required_version = "= 1.16.0"`,
so newer is rejected as firmly as older. And it must build the **Leap Micro** template, not MicroOS:
kube-hetzner 3.1.0 defaults new node pools to Leap Micro and looks for a snapshot labelled
`leapmicro-snapshot=yes`. Building MicroOS produces a snapshot the module never looks for, and apply
fails with the same "no image found".

## `make up` fails on a variable

```
Error: Invalid value for variable
node_transport_mode = tailscale needs TF_VAR_tailscale_auth_key
```

Every environment runs Tailscale transport. The key must be **reusable** — a single-use key
registers the first node and the rest hang forever waiting to join, which presents as a rebuild that
never converges rather than as an error.

CI cannot do this at all today:
[#183](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/183).

## `make up` finishes but nothing serves

`make up` already waits for the stack, so this means the wait timed out. Start with what has not
converged:

```bash
export KUBECONFIG=$PWD/infra/terraform/cluster/kubeconfig
kubectl get pods -A | grep -v Running
kubectl -n argocd get applications
```

**Set `KUBECONFIG` explicitly.** A user-level `KUBECONFIG` pointing at another project's cluster
will answer these questions about the wrong cluster, and `wait-for-stack.sh` carries a comment about
the twenty minutes that cost once.

If an Application reports `OutOfSync` while `Healthy`, check whether an operator owns the resource
before treating it as a failed rebuild — `postgres` did exactly that until T-2.14 (#193), because
CloudNativePG defaults the Cluster it is given and Argo's default diff read that as drift. The fix
was `ServerSideDiff=true` on that Application, and the same annotation is the first thing to reach
for if another operator-managed Application starts doing it.

## The rebuild works but the last few minutes of data are missing

Found by the first drill, 2026-08-23, and fixed — but worth knowing, because it is the failure that
looks most like success.

WAL reaches the archive when a segment fills or when `archive_timeout` expires, which is **300
seconds** here. A transaction committed inside that window is durable in Postgres and absent from
the archive. Destroy the cluster and it is gone, with no error anywhere: the write returned 200, the
row committed, backups were verified recoverable, and the teardown reported clean.

Measured. Segments shipped exactly on the timer:

```
...92  14:46:19
...93  14:51:18
...94  14:56:18
...95  15:01:19   <- the last one
```

The drill's seeded document was created at **15:01:38**, nineteen seconds later. Segment `...96` was
due at ~15:06 and the cluster was destroyed at ~15:03. The document did not come back.

**The 301s RPO in [disaster-recovery.md](disaster-recovery.md) is the number for a disaster** — what
you lose when the cluster disappears without warning. `make down` is not a disaster; it is a
planned, everyday operation, and losing five minutes of committed data to one is avoidable. The
distinction was never drawn, so the disaster number had quietly become the everyday one.

`cluster-destroy` now runs `flush-wal.sh` first, which does `pg_switch_wal()` on the primary and
waits for `pg_stat_archiver` to confirm the segment shipped. Waiting matters: the switch closes the
segment, the archiver ships it afterwards, and destroying between the two loses exactly what the
switch was for.

If a teardown ever reports

```
WAL did not archive within 120s.
```

**do not destroy.** Everything committed since the last successful archive will be lost. Check
`make backup-status ENV=dev` and fix the archiver first.

## The rebuild works but the database is empty

The most dangerous outcome, because everything looks healthy.

CloudNativePG bootstraps by **recovery**, not by starting an empty cluster — that is what makes a
rebuild restore rather than reset. If the database came up empty, the bootstrap chose the wrong
path. Check what it did:

```bash
kubectl -n database get cluster postgres -o jsonpath='{.spec.bootstrap}' | head -c 400
kubectl -n database logs -l cnpg.io/cluster=postgres --tail=100 | grep -i recover
```

Do **not** let it archive over the lineage you still need. Confirm the bucket still holds what you
expect before touching anything:

```bash
make backup-status ENV=dev
```

Recovery from here is [disaster-recovery.md](disaster-recovery.md), not another rebuild.

## The rebuild works but every login fails

The realm is imported by the Keycloak operator from
`platform/envs/<env>/keycloak/realm-import.yaml`. On a rebuild where the Keycloak *database*
survived, the import logs:

```
Realm 'xenopsbase' already exists. Import skipped
```

which is correct and is why user ids are stable. If logins fail after a rebuild where the database
did **not** survive, the realm was recreated — check that the declared users still carry their
pinned `id:` fields (ADR-0010). Without them, every document in the system is orphaned even though
the rows are intact.

## Nothing decrypts

```
Error: Failed to get the data key required to decrypt the SOPS file
```

Argo CD cannot decrypt the secrets, so nothing downstream of it starts. Either `TF_VAR_sops_age_key`
was not set when the cluster was built, or the value is wrong.

Two keys can decrypt everything since T-0.8. If the everyday key is unavailable, use the escrow one:

```bash
export TF_VAR_sops_age_key="$(cat /path/to/escrow.age)"
make up ENV=dev
```

Details in [secrets.md](secrets.md).

## The drill reports the document did not survive

Read which way it failed:

- **404 on download** — the row's owner is gone. The realm minted new user ids; see ADR-0010 and the
  login section above. The bytes are still in the bucket.
- **Wrong bytes** — object storage returned something else. This has never happened; check the
  bucket directly before assuming the drill is wrong.
- **Cannot log in at all** — not a data problem yet. Fix the login first, then re-verify.

The drill deletes its seeded document at the end. If it exited early, one is left behind with a
`cold-rebuild-` prefix and can be deleted through the API or left to the lifecycle rules.

## `make up` fails three times with "error during placement"

```
Error: error during placement (resource_unavailable, eae9122c…)
  with module.kube_hetzner.module.agents["0-0-worker"].hcloud_server.server
cluster-apply failed 3 times. Not a transient fault; read the error above.
```

**The message is wrong in this case and it is worth knowing why.** The retry loop stops after three
attempts on the reasoning that a real error fails identically every time. A Hetzner capacity
shortage does exactly that — it is transient, but on a timescale of minutes to hours rather than the
twenty seconds between retries.

Observed on 2026-08-23: the control plane and one worker were created, the second worker could not
be placed. `resource_unavailable` from the placement step means Hetzner could not satisfy the
request in that location — either the server type is exhausted there, or the placement group's
anti-affinity cannot be honoured because the hosts that could take it are full.

This is not a broken rebuild. It is a partial one, and `terraform apply` is idempotent:

```bash
make up ENV=dev          # continues; it does not start over
```

If it keeps failing, the options in order of preference:

1. **Wait.** Capacity in a location comes back. This is the common case.
2. **Change location** in `infra/terraform/cluster/env/<env>.tfvars` — `nbg1` and `hel1` are the
   usual alternatives to `fsn1`. Note the durable buckets are region-scoped, so moving the cluster
   away from its data costs latency on every database and object-storage call.
3. **Change server type.** A different type has separate capacity. It also changes the sizing
   baselines recorded in [cluster.md](cluster.md).

Do **not** respond by deleting and re-creating everything. The partial state is fine, Terraform
knows about it, and destroying to start clean throws away the nodes that *did* get capacity — which
in a shortage is the hardest part to get back.
