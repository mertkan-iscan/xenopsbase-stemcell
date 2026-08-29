#!/usr/bin/env bash
#
# Asserts that destroying the cluster left the durable side of ADR-0002 intact
# and no billable resources orphaned.
#
# This is the test of the whole premise. Everything else verifies a component;
# this verifies the claim the design rests on -- that the cluster can be thrown
# away at any moment without losing anything that matters, and without leaving
# anything behind that keeps charging.
#
# Two independent failure modes, both silent:
#
#   Something durable died.  Documents, backups or either snapshot are gone. The
#                            ephemeral model is unsafe and the boundary in
#                            ADR-0002 is wrong somewhere.
#
#   Something survived.      A volume, load balancer or placement group that
#                            Terraform no longer tracks. Nothing errors; the
#                            bill just never goes back down. Orphaned volumes
#                            are the most likely way this design leaks money.
#
# Run after `make cluster-destroy`. T-7.3's nightly drill runs it unattended.
#
# Usage:
#   export HCLOUD_TOKEN=... TF_VAR_hetzner_s3_access_key=... TF_VAR_hetzner_s3_secret_key=...
#   ./verify-teardown.sh <environment> [prefix] [region]
#
set -uo pipefail

ENVIRONMENT="${1:-}"
PREFIX="${2:-xenopsbase}"
REGION="${3:-fsn1}"

if [ -z "$ENVIRONMENT" ]; then
  echo "usage: $0 <environment> [prefix] [region]" >&2
  exit 2
fi
ENDPOINT="https://${REGION}.your-objectstorage.com"
FAILED=0

AK="${TF_VAR_hetzner_s3_access_key:-}"
SK="${TF_VAR_hetzner_s3_secret_key:-}"
if [ -z "$AK" ] || [ -z "$SK" ] || [ -z "${HCLOUD_TOKEN:-}" ]; then
  echo "error: HCLOUD_TOKEN, TF_VAR_hetzner_s3_access_key and TF_VAR_hetzner_s3_secret_key must be set" >&2
  exit 2
fi

s3() { AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" \
       aws --endpoint-url "$ENDPOINT" --region "$REGION" "$@"; }

# hcloud prints a header even when the list is empty, so counting raw lines
# reports 1 for "nothing". Counting IDs is unambiguous.
count_hcloud() { hcloud "$1" list -o columns=id 2>/dev/null | tail -n +2 | grep -c '[0-9]'; }

echo "=================================================================="
echo " MUST SURVIVE  (the durable column of ADR-0002)"
echo "=================================================================="

for short in documents pg-backups loki-chunks; do
  bucket="${PREFIX}-${ENVIRONMENT}-${short}"
  printf '  %-30s ' "$bucket"
  if ! s3 s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    echo "GONE  <-- durable data destroyed"
    FAILED=1
    continue
  fi
  rules=$(s3 s3api get-bucket-lifecycle-configuration --bucket "$bucket" 2>/dev/null | grep -c '"ID"')
  echo "present (${rules} lifecycle rules)"
  [ "$rules" -eq 0 ] && { echo "      ^ lifecycle rules lost; rerun make storage-lifecycle"; FAILED=1; }
done

# TWO SNAPSHOTS, NOT ONE (ADR-0008, T-1.18).
#
# This checked only the base OS image for as long as that was the only one, and
# kept checking only it after the golden image arrived -- so half the boundary
# it is the gate for went unasserted. preflight.sh has required both before
# every apply since #251; this required one after every destroy.
#
# The failure it could not see: `make down`, or an over-eager prune from T-1.21,
# takes the golden image with it. Terraform then fails at plan with "Resource
# (image) was not found using label selector: xenopsbase-golden=yes" -- a
# message that names the selector and not the two-hour packer build that
# produces one -- while the teardown that caused it printed TEARDOWN CLEAN.
#
#   leapmicro-snapshot=yes   base OS, control plane      bash infra/scripts/build-snapshot.sh
#   xenopsbase-golden=yes    agents and autoscaled nodes make golden-image
# NOTHING THE AUTOSCALER MADE MAY SURVIVE (T-7.12, #294).
#
# `make down` reaps them now, before the destroy. This asserts it worked, for
# the same reason every other line here does: a step that runs is not a step
# that succeeded. A leftover autoscaled node is not merely billing -- it holds
# the private network, so the NEXT teardown hangs on a subnet deletion whose
# message says nothing about servers.
check_no_autoscaled() {
  printf '  %-30s ' "autoscaled nodes"
  left="$(hcloud server list -o noheader -o columns=name -l "hcloud/node-group=${CLUSTER_NAME:-xenopsbase}-${ENVIRONMENT}-autoscaled" 2>/dev/null | grep -c . || true)"
  if [ "${left:-0}" -eq 0 ]; then
    echo "none"
  else
    echo "$left LEFT  <-- they hold the subnet; the next destroy will hang"
    FAILED=1
  fi
}

check_snapshot() {
  printf '  %-30s ' "$1"
  if hcloud image list --selector "$2" -o columns=id 2>/dev/null | tail -n +2 | grep -q '[0-9]'; then
    echo "present"
  else
    echo "GONE  <-- rebuild it before the next apply: $3"
    FAILED=1
  fi
}

check_snapshot "base OS snapshot" "leapmicro-snapshot=yes" "bash infra/scripts/build-snapshot.sh"
check_snapshot "golden image" "xenopsbase-golden=yes" "make golden-image"
check_no_autoscaled

# REPORTED, NOT ASSERTED (T-1.29, #290).
#
# A destroyed node leaves the tailnet with it, but NOT IMMEDIATELY (T-1.29,
# #290). The auth key is reusable AND ephemeral -- verified in the admin console
# on 2026-08-29, where it has been since 2026-08-19 -- and an ephemeral device is
# reaped after the node stops heartbeating rather than when it dies.
#
# So a non-zero count here, straight after a destroy, is the NORMAL reading. It
# is what a teardown looks like from the outside for the next few minutes.
#
# This comment previously said the key was not ephemeral and told the reader to
# reissue it. That was #290's diagnosis and it was wrong: the offline devices it
# found were inside the reap window, and they went. The defect that survives is
# the NAME -- Tailscale appends `-1` when a name is still taken, and a rebuild
# faster than the reap window gives the new node a suffixed name it then keeps
# for life. verify-node-provenance resolves through `tailscale status` for that
# reason, permanently.
#
# It does not fail the teardown, and now for a better reason than "nothing here
# can fix it": a count taken seconds after a destroy is measuring a clock, not a
# leak. What is worth a human's attention is a count that is still there long
# afterwards, which no single run of this can tell you.
if command -v tailscale >/dev/null 2>&1; then
  printf '  %-30s ' "tailnet, reaping"
  stale="$(tailscale status 2>/dev/null | grep "${CLUSTER_NAME:-xenopsbase}-${ENVIRONMENT}" | grep -c offline || true)"
  if [ "${stale:-0}" -eq 0 ]; then
    echo "none pending"
  else
    echo "$stale device(s) awaiting reaping (expected; see #290 if still there in an hour)"
  fi
fi

echo
echo "=================================================================="
echo " MUST BE GONE  (anything still here bills forever)"
echo "=================================================================="

# primary-ip and floating-ip are in this list for a reason that is easy to miss:
# Hetzner bills an IPv4 address while it is UNASSIGNED, so the one that outlives
# its server is the one that costs money silently. A primary IP left behind is
# cheaper than an orphaned volume and just as permanent.
#
# Networks and firewalls are deliberately absent: they are free, and failing a
# teardown check over something that costs nothing trains people to ignore it.
for kind in server volume load-balancer placement-group primary-ip floating-ip; do
  n=$(count_hcloud "$kind")
  printf '  %-30s %s\n' "${kind}s" "$n"
  if [ "$n" -ne 0 ]; then
    echo "      ^ ORPHANED. Terraform no longer tracks these; they will not"
    echo "        disappear on their own and no future destroy will reach them."
    hcloud "$kind" list 2>/dev/null | tail -n +2 | sed 's/^/        /'
    FAILED=1
  fi
done

echo
if [ "$FAILED" -ne 0 ]; then
  echo "TEARDOWN VERIFICATION FAILED"
  echo "  Either the durable boundary is wrong, or resources were orphaned."
  echo "  Both are load-bearing for ADR-0002 and neither reports itself."
  exit 1
fi
echo "TEARDOWN CLEAN — durable state intact, nothing left billing."
