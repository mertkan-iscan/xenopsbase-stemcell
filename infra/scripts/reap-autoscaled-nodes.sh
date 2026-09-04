#!/usr/bin/env bash
#
# Delete the nodes the autoscaler created, before terraform destroys the rest
# (T-7.12, #294).
#
# WHY THE TEARDOWN CANNOT SKIP THIS
#
# `make down` destroys what terraform created. The cluster-autoscaler's nodes
# are not that -- it creates them through the Hetzner API from a config secret,
# outside any state file -- so they survive the destroy. And because they are
# attached to the private network, the SUBNET cannot be deleted while they
# exist. The destroy does not fail; it hangs:
#
#   module.kube_hetzner.hcloud_network_subnet.control_plane[0]: Still destroying...
#     [id=12582870-10.255.0.0/16, 08m50s elapsed]
#
# on a message three levels away from two servers nobody is looking at. That is
# strictly worse than the case #159 fixed: an orphaned VOLUME is invisible and
# bills, an orphaned SERVER stops the teardown.
#
# It is not a rare path. The nodes exist precisely because something went wrong
# -- pods went unschedulable, the autoscaler did its job -- so the teardown most
# likely to hit this is the one cleaning up after a bad day.
#
# SCALE THE AUTOSCALER DOWN FIRST, AND WHY THAT IS NOT OPTIONAL
#
# Deleting its nodes while it is running is a race it wins: it sees the pods go
# unschedulable again and creates replacements, and the teardown deletes servers
# for as long as the controller is alive.
#
# WHAT IT WILL NOT DELETE
#
# Only servers carrying `hcloud/node-group=<cluster>-autoscaled`, the label the
# autoscaler stamps on what it creates (manifests/30-cluster-autoscaler). A
# static agent or a control plane carries a different group and is terraform's
# to remove, so a bug here cannot take one.
#
# Usage:
#   ./reap-autoscaled-nodes.sh [env]
#
set -uo pipefail

ENVIRONMENT="${1:-dev}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_DIR="$ROOT/infra/terraform/cluster"
CLUSTER="${CLUSTER_NAME:-xenopsbase}-${ENVIRONMENT}"
NODE_GROUP="${CLUSTER}-autoscaled"

# THESE USED TO exit 0, AND THAT IS HOW THE GATE WENT BLIND.
#
# A skip here is announced on stderr and then buried under ten minutes of
# terraform output, and the only thing downstream that would have caught it --
# verify-teardown.sh -- was counting zeros for the same missing binary. A
# skipped sweep followed by a gate that cannot see is a teardown that reports
# success having done neither.
#
# The objection to failing is that a teardown gets blocked when there was
# probably nothing to reap. It does not survive: verify-teardown.sh now exits 2
# without this binary, and has always exited 2 without this token, so `make
# down` cannot reach a clean exit either way. The choice is only whether it
# stops here, before the destroy, or ten minutes later after one. Here is
# cheaper and the message is about the actual cause.
#
# `make down` is the only caller, and it needs both of these for the destroy
# itself, not merely for this sweep.
command -v hcloud >/dev/null 2>&1 || {
  echo "  error: hcloud CLI not found — cannot reap autoscaled nodes." >&2
  echo "         They hold the private network: without them removed the destroy" >&2
  echo "         does not fail, it hangs on a subnet deletion (#294)." >&2
  exit 1
}
[ -n "${HCLOUD_TOKEN:-}" ] || {
  echo "  error: HCLOUD_TOKEN is not set — cannot reap autoscaled nodes." >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Stop the controller before touching what it manages. Best effort: a cluster
# too broken to answer kubectl is exactly the one being torn down, and the
# delete below still has to happen.
KUBECONFIG_FILE="$(mktemp -t khcfg.XXXXXX)"
cleanup() { rm -f "$KUBECONFIG_FILE"; }
trap cleanup EXIT

if (cd "$CLUSTER_DIR" && terraform output -raw kubeconfig) > "$KUBECONFIG_FILE" 2>/dev/null; then
  export KUBECONFIG="$KUBECONFIG_FILE"
  if timeout 30 kubectl -n kube-system scale deployment/cluster-autoscaler --replicas=0 >/dev/null 2>&1; then
    echo "  stopping the cluster-autoscaler so it stops replacing what we delete…"
    # It is the pod that calls the API, not the Deployment, so wait for it to
    # actually be gone rather than for the replica count to be written.
    for _ in $(seq 1 20); do
      timeout 10 kubectl -n kube-system get pods -l app.kubernetes.io/name=cluster-autoscaler \
        --no-headers 2>/dev/null | grep -q . || break
      sleep 3
    done
  else
    echo "  could not scale the autoscaler down (cluster unreachable) — deleting anyway." >&2
  fi
else
  echo "  no kubeconfig — cannot stop the autoscaler, deleting anyway." >&2
fi

# ---------------------------------------------------------------------------
# A failed call and an empty list look identical once stderr is discarded, and
# reading the first as the second is precisely how a node survives to hold the
# subnet the destroy then waits nine minutes on.
servers="$(hcloud server list -o noheader -o columns=id,name -l "hcloud/node-group=${NODE_GROUP}" 2>&1)" || {
  echo "  error: \`hcloud server list\` failed, so nothing was reaped: ${servers}" >&2
  exit 1
}

if [ -z "$servers" ]; then
  echo "  no autoscaled nodes to reap (${NODE_GROUP})."
  exit 0
fi

echo "  reaping autoscaled nodes (${NODE_GROUP})…"
REAPED=0
LEFT=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  id="$(echo "$line" | awk '{print $1}')"
  name="$(echo "$line" | awk '{print $2}')"
  if hcloud server delete "$id" >/dev/null 2>&1; then
    echo "    reaped ${id} ${name}"
    REAPED=$((REAPED + 1))
  else
    echo "    FAILED to delete ${id} ${name} — the subnet will not delete until it is gone" >&2
    LEFT=$((LEFT + 1))
  fi
done <<< "$servers"

echo "  reaped ${REAPED} autoscaled node(s); ${LEFT} left."
[ "$LEFT" -eq 0 ] || exit 1
