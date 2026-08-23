#!/usr/bin/env bash
#
# Deletes PVC-backed volumes that outlived the cluster (T-1.16, #159).
#
# WHY THIS EXISTS AS A SEPARATE, AFTER-THE-FACT STEP
#
# release-cluster-volumes.sh deletes the PersistentVolumeClaims and waits for
# the CSI driver to remove the underlying volumes. That is the right order and
# it is the only order that can work, because the driver runs INSIDE the
# cluster and stops existing the moment the nodes do.
#
# It has a 300-second budget, and the Prometheus volume routinely exceeds it.
# Measured across two teardowns on 2026-08-23: one volume released in 20s,
# another took 210s, and a third had not released when the budget ran out --
# both times. So `terraform destroy` proceeded, reported success, and left a
# 10 GB volume that Terraform no longer tracks and no future destroy will ever
# reach. Invisible, permanent, and billing.
#
# verify-teardown.sh already finds them precisely. Until now it only reported
# them, which meant `make down` exited non-zero and a human had to run two
# hcloud commands -- fine when someone is watching, and fatal to the claim in
# T-7.2 that a cold rebuild is fully automated. The cold-rebuild drill stopped
# dead on exactly this.
#
# So this reaps what the in-cluster path could not, from outside, after the
# cluster is gone.
#
# WHAT IT WILL NOT DELETE
#
# Only DETACHED volumes whose name looks like a Kubernetes PVC (`pvc-<uuid>`).
# A volume created by hand, or one still attached to something, is reported and
# left alone -- deleting storage is not the kind of thing to be clever about,
# and a name pattern is a weaker claim of ownership than Terraform state.
#
# Usage:
#   ./reap-orphaned-volumes.sh [env]
#
set -uo pipefail

ENVIRONMENT="${1:-dev}"

command -v hcloud >/dev/null 2>&1 || {
  echo "  hcloud CLI not found — cannot reap orphaned volumes." >&2
  exit 0
}

[ -n "${HCLOUD_TOKEN:-}" ] || {
  echo "  HCLOUD_TOKEN is not set — skipping the orphaned-volume sweep." >&2
  exit 0
}

volumes="$(hcloud volume list -o noheader -o columns=id,name,server 2>/dev/null)"

if [ -z "$volumes" ]; then
  exit 0
fi

echo "  sweeping for volumes the CSI driver could not release (${ENVIRONMENT})…"

REAPED=0
LEFT=0

while IFS= read -r line; do
  [ -n "$line" ] || continue
  id="$(echo "$line" | awk '{print $1}')"
  name="$(echo "$line" | awk '{print $2}')"
  server="$(echo "$line" | awk '{print $3}')"

  # Attached to something. Not ours to remove, and if a server still exists the
  # destroy did not finish -- which is a different problem that deleting a
  # volume would obscure.
  if [ -n "$server" ] && [ "$server" != "-" ]; then
    echo "    LEFT   ${id} ${name} — still attached to ${server}"
    LEFT=$((LEFT + 1))
    continue
  fi

  case "$name" in
    pvc-*)
      if hcloud volume delete "$id" >/dev/null 2>&1; then
        echo "    reaped ${id} ${name}"
        REAPED=$((REAPED + 1))
      else
        echo "    FAILED to delete ${id} ${name} — delete it by hand, it is billing" >&2
        LEFT=$((LEFT + 1))
      fi
      ;;
    *)
      echo "    LEFT   ${id} ${name} — not a PVC-shaped name, not touching it"
      LEFT=$((LEFT + 1))
      ;;
  esac
done <<< "$volumes"

if [ "$REAPED" -gt 0 ]; then
  echo "  reaped ${REAPED} orphaned volume(s) the 300s release budget did not reach."
fi
if [ "$LEFT" -gt 0 ]; then
  echo "  ${LEFT} volume(s) left in place — verify-teardown will report them."
fi

exit 0
