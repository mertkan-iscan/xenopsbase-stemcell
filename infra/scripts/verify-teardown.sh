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
#   Something durable died.  Documents, backups or the snapshot are gone. The
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

printf '  %-30s ' "OS snapshot"
if hcloud image list --selector leapmicro-snapshot=yes -o columns=id 2>/dev/null | tail -n +2 | grep -q '[0-9]'; then
  echo "present"
else
  echo "GONE  <-- next build must run packer again"
  FAILED=1
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
