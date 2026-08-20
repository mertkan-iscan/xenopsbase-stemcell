#!/usr/bin/env bash
#
# Deletes PersistentVolumeClaims BEFORE Terraform destroys the cluster, so the
# CSI driver releases the Hetzner volumes behind them.
#
# WHY THIS EXISTS. Terraform does not create these volumes -- the Hetzner CSI
# driver does, in response to a PVC. So Terraform does not track them and
# `terraform destroy` does not touch them. It reports success, exits 0, and
# leaves volumes behind that no future destroy will ever reach:
#
#   Destroy complete! Resources: 61 destroyed.
#   $ hcloud volume list
#   106655948  pvc-27d6612a-...  10 GB  (unattached, billing)
#
# Nothing surfaces them. They simply bill until somebody notices.
#
# ORDER MATTERS AND IS NOT RECOVERABLE. The CSI driver runs INSIDE the cluster.
# Once the nodes are gone there is nothing left to delete the volumes, so this
# must run while the cluster is still alive. Destroy first and the only remaining
# option is deleting them by hand.
#
# THIS DELETES DATA. Every PVC in the cluster goes, because the storage class is
# reclaimPolicy=Delete. That is the intended behaviour under ADR-0002: Postgres
# is continuously archived to object storage and metrics are not durable state.
# Set KEEP_VOLUMES=1 to skip, which leaves the orphans for you to handle.
#
# Usage:
#   ./release-cluster-volumes.sh <env>
#
set -uo pipefail

ENV="${1:-}"
[ -n "$ENV" ] || { echo "usage: $0 <env>" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_DIR="$ROOT/infra/terraform/cluster"

if [ "${KEEP_VOLUMES:-0}" = "1" ]; then
  echo "KEEP_VOLUMES=1 -- skipping volume release."
  echo "Any PVC-backed volumes will survive the destroy and keep billing."
  echo "Check afterwards with: hcloud volume list"
  exit 0
fi

echo "=================================================================="
echo " Releasing PVC-backed volumes before destroy ($ENV)"
echo "=================================================================="

KUBECONFIG_FILE="$(mktemp -t khcfg.XXXXXX)"
cleanup() { rm -f "$KUBECONFIG_FILE"; }
trap cleanup EXIT INT TERM

if ! (cd "$CLUSTER_DIR" && terraform output -raw kubeconfig) > "$KUBECONFIG_FILE" 2>/dev/null; then
  echo "  no kubeconfig in Terraform state -- nothing to clean up."
  echo "  (Normal when the cluster was already destroyed.)"
  exit 0
fi
export KUBECONFIG="$KUBECONFIG_FILE"

# The cluster may be gone, unreachable, or half-destroyed. None of those should
# stop a destroy: refusing to proceed would leave the operator unable to tear
# down a broken cluster, which is worse than a leaked volume.
if ! kubectl get nodes >/dev/null 2>&1; then
  echo "  cluster is not reachable -- skipping."
  echo
  echo "  WARNING: if it had PVCs, their volumes will be orphaned by the destroy."
  echo "  'make verify-teardown ENV=$ENV' will list any that survive, and they"
  echo "  then have to be removed with 'hcloud volume delete <id>'."
  exit 0
fi

PVCS="$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "  PersistentVolumeClaims found: $PVCS"
if [ "$PVCS" -eq 0 ]; then
  echo "  nothing to release."
  exit 0
fi
kubectl get pvc -A --no-headers 2>/dev/null | awk '{printf "    %-16s %s\n", $1, $2}'

# STOP ARGO CD FIRST. This is the step whose absence made the first attempt
# fail: selfHeal is on for every Application, so scaling a StatefulSet to zero
# or deleting a CNPG Cluster is undone within seconds. The PVCs stay bound, the
# volumes are never released, and the loop below counts down to a timeout
# against an opponent that is actively putting everything back.
#
# Nothing here needs Argo: the cluster is about to cease existing.
echo
echo "  stopping the Argo CD application controller so it stops self-healing..."
kubectl -n argocd scale statefulset --all --replicas=0 >/dev/null 2>&1
for i in $(seq 1 12); do
  RUNNING="$(kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-application-controller --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "$RUNNING" -eq 0 ] && break
  sleep 5
done

# Now the scale-down sticks. A StatefulSet whose pod is still running holds its
# volume attached, and the PVC then sits Terminating until the pod goes --
# which looks like a hang rather than a dependency.
echo "  scaling down workloads that hold volumes..."
kubectl -n database delete cluster --all --wait=false >/dev/null 2>&1
kubectl scale statefulset --all --replicas=0 -A >/dev/null 2>&1
kubectl scale deployment --all --replicas=0 -A >/dev/null 2>&1
sleep 15

echo "  deleting PersistentVolumeClaims..."
kubectl delete pvc --all -A --wait=false >/dev/null 2>&1

# Wait for the CSI driver to actually delete the volumes. The PVC object
# disappearing is not the same as the volume being gone: deletion is
# asynchronous, and destroying the nodes mid-flight strands whatever is left.
echo "  waiting for the CSI driver to delete the underlying volumes..."
for i in $(seq 1 30); do
  LEFT="$(kubectl get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  printf '    %2ds  persistent volumes remaining: %s\n' "$((i*10))" "$LEFT"
  [ "$LEFT" -eq 0 ] && break
  sleep 10
done

LEFT="$(kubectl get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "$LEFT" -ne 0 ]; then
  echo
  echo "  WARNING: $LEFT persistent volume(s) did not release in time."
  echo "  The destroy will continue and may orphan them. Check with:"
  echo "    make verify-teardown ENV=$ENV"
  exit 0
fi

echo
echo "  all volumes released."
