#!/usr/bin/env bash
#
# Deletes golden images nothing boots from (T-1.21, #253).
#
# WHY THIS EXISTS
#
# Once T-1.18 landed, a snapshot is produced for every k3s bump, every package
# pin change and every policy edit. Snapshots are billed per GB-month and
# nothing removed one. The per-image cost is small -- 1.6GB at EUR 0.0143/GB
# is about two cents a month -- and the number is not the problem. The problem
# is that nothing was watching, which is how ADR-0002's "near zero when idle"
# stops being true without anyone deciding to give it up.
#
# WHY IT IS DANGEROUS, AND WHAT STOPS IT
#
# A snapshot is DURABLE STATE (ADR-0008). `make down` does not remove it, and
# deleting the wrong one makes `terraform apply` fail before creating anything
# -- on a cold rebuild, which is exactly when nobody wants to discover it.
#
# So four things are never candidates, and each is checked rather than assumed:
#
#   1. Anything a RUNNING SERVER booted from. Read from the servers themselves,
#      not from terraform config, because config says what should be true and
#      the server says what is.
#   2. The newest golden image, whatever any age rule says. There must always
#      be something to boot.
#   3. Every BASE snapshot (leapmicro-snapshot=yes). Golden images are built
#      ON TOP of these; deleting one breaks `make golden-image` rather than
#      `make up`, which is a slower and more confusing failure.
#   4. Anything this project did not label. An unrecognised snapshot in the
#      account is somebody else's, and a retention policy that reaches outside
#      what it created is a retention policy that eventually deletes something
#      it never should have seen.
#
# A retention policy that can delete the only bootable image is worse than no
# retention policy, because it converts a small recurring cost into an outage.
#
# DRY RUN BY DEFAULT. Nothing is deleted without --delete.
#
# Usage:
#   source ~/.xenopsbase.env && ./prune-snapshots.sh            # show
#   source ~/.xenopsbase.env && ./prune-snapshots.sh --delete   # do it
#   KEEP=5 ./prune-snapshots.sh --delete                        # keep 5 goldens
#
set -uo pipefail

: "${HCLOUD_TOKEN:?HCLOUD_TOKEN is not set — run: source ~/.xenopsbase.env}"

# How many golden images to keep, newest first. Three because a rollback wants
# the previous one and T-7.9 wants the one before that while a replacement is
# in progress; beyond that they are history nobody boots.
KEEP="${KEEP:-3}"

DELETE=0
[ "${1:-}" = "--delete" ] && DELETE=1

api() {
  curl -sS -H "Authorization: Bearer ${HCLOUD_TOKEN}" "https://api.hetzner.cloud/v1/$1"
}

IMAGES="$(api 'images?type=snapshot&per_page=100')"
SERVERS="$(api 'servers?per_page=100')"

PY_BIN="$(python3 -c '' >/dev/null 2>&1 && echo python3 || echo python)"

export IMAGES SERVERS KEEP

# The decision lives in snapshot-plan.py, which has self-tests. A retention
# policy whose delete path has never run is one you find out about when it
# removes the wrong image, so the logic is somewhere it can be exercised
# without an account and without the possibility of deleting anything.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Proves the gate can still fail before it is trusted to delete anything.
if ! "$PY_BIN" "$ROOT/snapshot-plan.py" --self-test >/tmp/retention-selftest.$$ 2>&1; then
  echo "error: snapshot-plan.py self-tests FAILED — refusing to delete anything." >&2
  cat /tmp/retention-selftest.$$ >&2
  rm -f /tmp/retention-selftest.$$
  exit 1
fi
rm -f /tmp/retention-selftest.$$

PLAN="$("$PY_BIN" "$ROOT/snapshot-plan.py")"

if [ -z "$PLAN" ]; then
  echo "error: could not build a plan — is HCLOUD_TOKEN valid?" >&2
  exit 1
fi

echo "=================================================================="
echo " Snapshot retention  (keeping the newest ${KEEP} golden images)"
echo "=================================================================="
printf '%s' "$PLAN" | "$PY_BIN" -c '
import json, sys
p = json.load(sys.stdin)
for line in p["lines"]:
    print("  " + line)
print("")
print("  in use by a running server: %s" % (", ".join(str(i) for i in p["in_use"]) or "nothing"))
print("  snapshot storage total    : %.1f GB" % p["total_gb"])
'

TO_DELETE="$(printf '%s' "$PLAN" | "$PY_BIN" -c 'import json,sys; print(" ".join(str(i) for i in json.load(sys.stdin)["delete"]))')"

echo ""
if [ -z "$TO_DELETE" ]; then
  echo "Nothing to delete."
  exit 0
fi

if [ "$DELETE" -eq 0 ]; then
  echo "DRY RUN. Would delete: ${TO_DELETE}"
  echo "Re-run with --delete to actually remove them."
  exit 0
fi

FAILED=0
for id in $TO_DELETE; do
  printf '  deleting %s ... ' "$id"
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
    "https://api.hetzner.cloud/v1/images/${id}")"
  case "$code" in
    20*) echo "ok" ;;
    *)   echo "FAILED (HTTP ${code})"; FAILED=1 ;;
  esac
done

exit "$FAILED"
