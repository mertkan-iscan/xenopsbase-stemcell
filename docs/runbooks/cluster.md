# Runbook: the K3s cluster

The cluster is the cattle side of [ADR-0002](../adr/0002-ephemeral-cluster-and-durable-state.md).
It is built by Terraform, destroyed routinely, and holds nothing worth keeping.

Provisioned by [kube-hetzner](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner),
pinned to **v3.1.0**.

## What is durable here, and what is not

Almost nothing in this module survives a destroy — that is the design. Two things do, and both are
easy to forget:

| Survives destroy | Why |
|---|---|
| **The OS snapshot** | Built by Packer (Leap Micro), lives in the Hetzner project, never touched by Terraform |
| **The SSH key pair** | Yours, on your machine. Lose it and you cannot reach nodes |

The snapshot is the one addition this task makes to ADR-0002's durable list. It is the same
category as a container image: built once, reused by every rebuild, and rebuilding it is the
slowest single step in a genuinely cold start.

## Prerequisites

| Tool | For |
|---|---|
| Terraform ≥ 1.10 | Everything |
| Packer **exactly 1.16.0** | Building the OS snapshot, once per project |
| hcloud CLI | Verifying the snapshot exists |
| kubectl | Talking to the cluster afterwards |
| An SSH key pair | Node access. `ssh-keygen -t ed25519` if you have none |

The Packer version is an **exact** pin, not a minimum. The kube-hetzner template declares
`required_version = "= 1.16.0"`, so both older and newer Packer are rejected outright:

```
Error: Unsupported Packer Core version
  This configuration does not support Packer version 1.15.1.
```

On Windows: `scoop install main/packer` then `scoop update packer`. If the update reports
`Running process detected, skip updating`, a Packer process from a failed run is still alive —
`taskkill //PID <pid> //F` and retry.

The pin moves with the module version, so bumping kube-hetzner may require a matching Packer bump.
Check the template's `required_version` before upgrading either.

```bash
export HCLOUD_TOKEN=<hetzner cloud api token>     # for packer and the hcloud CLI
export TF_VAR_hcloud_token="$HCLOUD_TOKEN"        # for terraform
```

## First time in a new Hetzner project

```bash
bash infra/scripts/build-snapshot.sh
```

Several minutes. It creates a temporary billable server and removes it when finished. Confirm:

```bash
hcloud image list --selector leapmicro-snapshot=yes
```

**No snapshot means `terraform apply` fails before creating anything.** kube-hetzner does not
install an operating system; it provisions every node from this image.

### Leap Micro, not MicroOS

kube-hetzner 3.1.0 defaults **new** node pools to Leap Micro
(`locals.tf: control_plane_nodepool_default_os -> "leapmicro"`), and then looks for a snapshot
labelled:

```
leapmicro-snapshot=yes,kube-hetzner/os=leapmicro,kube-hetzner/k8s-distro=<distro>
```

Building the MicroOS template instead produces a snapshot the module never looks for, and apply
fails with a no-image-found error that gives no hint the wrong OS was built. Most tutorials and
older docs still say `microos-snapshot=yes`, which is where the confusion comes from.

To use MicroOS instead, set `os = "microos"` per nodepool **and** build the matching template:
`bash infra/scripts/build-snapshot.sh 3.1.0 microos`.

## Windows: line endings will break the apply

Git for Windows ships `core.autocrlf=true` at **system** level. Terraform fetches registry modules
with `git clone`, so that setting rewrites every file in the module to CRLF -- including the shell
heredocs kube-hetzner uploads to nodes. They then fail on Linux:

```
/tmp/terraform_1990458969.sh: line 14: syntax error near unexpected token $'
'
Error: remote-exec provisioner error ... Process exited with status 2
```

The symptom is misleading: SSH connects, the `file` provisioners deliver correctly, nodes boot and
show as `running`. Only the inline scripts fail, and the error names a temp file that has already
been deleted.

This is neither a kube-hetzner bug nor a Terraform bug, and nothing in this repository can prevent
it -- `.gitattributes` does not apply to a checkout Terraform performs itself into `.terraform/`.

The `make` targets scope the override to the Terraform invocation:

```
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false terraform init ...
```

Deliberately **not** a change to the global git config, which would affect every other repository
on the machine. Harmless on Linux and macOS, where `autocrlf` is already off.

Running `terraform init` by hand on Windows needs the same prefix. To check an existing checkout:

```bash
grep -qU $'
' infra/terraform/cluster/.terraform/modules/kube_hetzner/locals.tf && echo "CRLF - reinit needed"
```

The fix is `rm -rf .terraform` and init again with the override. Editing the fetched files is not a
fix; the next `init` undoes it.

## Building the cluster

```bash
cp infra/terraform/cluster/backend.hcl.example infra/terraform/cluster/backend.hcl
cp infra/terraform/cluster/terraform.tfvars.example infra/terraform/cluster/terraform.tfvars
```

Edit both, then:

```bash
cd infra/terraform/cluster && terraform init -backend-config=backend.hcl && terraform apply
```

Then retrieve the kubeconfig — it is not written automatically, because a cluster-admin credential
sitting next to the Terraform code is a credential that eventually gets committed:

```bash
terraform output -raw kubeconfig > kubeconfig    # gitignored
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
```

## Verifying CCM and CSI

The module installs both. CCM wires Hetzner load balancers to Kubernetes Services; CSI makes a PVC
provision a real Hetzner volume. Neither is much use unverified:

```bash
kubectl -n kube-system get pods | grep -E 'hcloud|csi'
```

### The PVC test needs a pod

`hcloud-volumes` uses `volumeBindingMode: WaitForFirstConsumer`, so **a PVC on its own stays
`Pending` forever, by design**. That is not a CSI failure, and treating it as one is the obvious
way to misdiagnose a perfectly healthy cluster. The volume is only provisioned once a pod that
mounts it is scheduled, so that the volume lands in the same location as the node.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: csi-smoke-test
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: hcloud-volumes
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: csi-smoke-test
spec:
  containers:
    - name: probe
      image: busybox:1.36
      command: ["sh","-c","echo csi-ok > /data/probe && sleep 3600"]
      volumeMounts:
        - name: vol
          mountPath: /data
  volumes:
    - name: vol
      persistentVolumeClaim:
        claimName: csi-smoke-test
EOF
```

```bash
kubectl wait --for=condition=Ready pod/csi-smoke-test --timeout=180s
```

Then the PVC must be `Bound` and a matching volume must appear:

```bash
kubectl get pvc csi-smoke-test && hcloud volume list
```

Confirm the data actually reached the volume — but note the Git Bash trap:

```bash
kubectl exec csi-smoke-test -- sh -c 'cat /data/probe'
```

**Wrap the command in `sh -c`.** Without it, MSYS rewrites `/data/probe` into a Windows path before
kubectl sees it, and the pod reports:

```
ls: C:/Program Files/Git/data: No such file or directory
```

which looks exactly like a broken mount and is not. `MSYS_NO_PATHCONV=1` also works but breaks the
`KUBECONFIG` path at the same time, so `sh -c` is the one to use.

### Clean up, and check the volume actually went

```bash
kubectl delete pod csi-smoke-test && kubectl delete pvc csi-smoke-test
```

```bash
hcloud volume list
```

This must come back empty. A volume that outlives its PVC bills indefinitely, and orphaned volumes
are the most likely way this design leaks money — they survive `make down` because Terraform never
knew about them.

Verified 2026-08-19: PVC `Bound`, volume `106649780` created and attached to a worker, removed
within seconds of the PVC being deleted.

## What this module deliberately does not install

kube-hetzner can install an ingress controller, cert-manager, and etcd backups to S3. All three
are off.

**Ingress and cert-manager**: ADR-0004 makes Argo CD the single owner of everything above the
cluster. Two systems installing ingress means drift with no clear owner, and Argo reverting a
change kube-hetzner just made. T-2.2 installs both through GitOps.

**etcd backup to S3**: the cluster holds nothing worth restoring. Postgres archives itself to
object storage (T-2.4) and every manifest is in git. An etcd backup would restore a cluster we
would rather rebuild, and would quietly become durable state ADR-0002 does not account for.

## Measured baselines

First real destroy/rebuild cycle, 2026-08-19, dev sizing (1 control plane + 2 workers, cx23, fsn1):

| Step | Time | ADR-0002 target |
|---|---|---|
| `terraform destroy` (53 resources) | ~2 min | — |
| `terraform apply` rebuild, snapshot present | **305 s** | 20 min warm start |
| Packer snapshot build (only on a new project) | 322 s | part of the 60 min cold path |

The rebuild is well inside target, which matters more than the margin suggests: a rebuild path that
is slow stops being exercised, and an unexercised recovery path does not work.

Note the snapshot build is a *separate* number. A rebuild with the snapshot present is the everyday
path; a rebuild into a genuinely empty Hetzner project pays both. T-7.2 should measure and record
both rather than collapsing them into one figure.

Verified in the same cycle: an object written to the documents bucket before the destroy read back
byte-identical afterwards, and the storage module's Terraform state was untouched — 12 resources,
unreachable from the cluster destroy by design.

## High availability

The dev default is **one** control plane node. That is not an oversight: the cluster is destroyed
between working sessions, so an hour of downtime costs nothing because nobody is using it. Paying
for HA on something torn down nightly buys availability with no consumer.

For anything real, set `count = 3`. **Never 2.** etcd needs a quorum of more than half, so a
two-node cluster tolerates zero failures while costing twice as much — strictly worse than one
node. The variable validation rejects even totals for this reason.

```bash
terraform output is_highly_available
```

## Upgrading the pinned module version

The version is pinned exactly, because a floating version means a rebuild can differ from the last
for reasons nobody chose — which breaks the central promise of ADR-0002.

1. Read the [release notes](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/releases)
   between the current version and the target. Breaking changes are called out there.
2. Bump `version` in `infra/terraform/cluster/main.tf`.
3. Rebuild the snapshot with the matching version, since template and module are expected to match:
   `bash infra/scripts/build-snapshot.sh <new-version>`
4. `terraform plan` and read it properly. A node pool being **replaced** rather than updated means
   every node is recreated.
5. Apply in dev. Destroy and rebuild from nothing to confirm the cold path still works — that is
   the path that matters, and the one an upgrade is most likely to break.
6. Only then promote.

Do this as its own change. An upgrade bundled with a feature makes a bisect impossible when a
rebuild starts failing a week later.

## Troubleshooting

**`terraform apply` fails immediately with no snapshot found**
The snapshot is missing, or it is the wrong OS.
`hcloud image list --selector leapmicro-snapshot=yes` must return a row. If a MicroOS snapshot was
built by mistake it will not match, and the error does not say so — see Leap Micro, not MicroOS
above.

**Nodes never become Ready**
Almost always SSH. The module provisions over SSH, so `ssh_private_key_path` must match the public
key, and the key must not have a passphrase Terraform cannot answer.

**Apply hangs on node provisioning**
Hetzner occasionally fails to allocate a server type in a location. Try another `server_type` or
`location`. The module retries, so give it a few minutes before concluding it is stuck.

**Destroy leaves resources behind**
Check for orphaned volumes, load balancers and placement groups:

```bash
hcloud volume list && hcloud load-balancer list && hcloud placement-group list
```

These bill independently of servers. T-8.4 automates this check; until then it is worth running
after any failed destroy.

## Tearing down

```bash
make cluster-destroy ENV=dev
```

This does three things in a fixed order, and the order is not optional:

1. **Releases PVC-backed volumes.** The Hetzner CSI driver creates these in response to a
   PersistentVolumeClaim, so Terraform never tracks them and `terraform destroy` never removes them.
   It reports success and leaves them billing forever. **The CSI driver runs inside the cluster**, so
   this must happen while the nodes are alive — afterwards nothing is left to do it and the volumes
   can only be removed by hand.
2. **Destroys the cluster.**
3. **Verifies the durable boundary held** — buckets and OS snapshot still present, no servers,
   volumes, load balancers or placement groups left. A leak here is invisible and permanent, so it
   fails the target rather than waiting to be noticed.

**Step 1 deletes data.** Every PVC goes, because the storage class is `reclaimPolicy=Delete`. That
is intended under [ADR-0002](../adr/0002-ephemeral-cluster-and-durable-state.md): Postgres is
continuously archived to object storage, and metrics are not durable state. To skip it:

```bash
KEEP_VOLUMES=1 make cluster-destroy ENV=dev
```

which leaves the volumes — and therefore the orphans — for you to deal with.

### If the cluster is already gone

The release step skips cleanly when there is no kubeconfig or the API does not answer. It warns
rather than failing, because refusing to proceed would leave you unable to tear down a broken
cluster — worse than a leaked volume. Check afterwards:

```bash
make verify-teardown ENV=dev
hcloud volume delete <id>     # for anything it lists
```
