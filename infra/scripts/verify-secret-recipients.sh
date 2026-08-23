#!/usr/bin/env bash
#
# Every encrypted file must decrypt with EVERY recipient .sops.yaml names for it.
#
# Adding a recipient to .sops.yaml changes what NEW files are encrypted to. It
# does nothing to files that already exist -- they keep whatever recipients they
# were written with, and sops reports no error, because from its point of view
# nothing is wrong. So the escrow key can be present in the configuration, and
# absent from every secret it is supposed to rescue, with nothing to show for
# the difference until a recovery.
#
# That is the failure this exists to make visible (T-0.8). It is the same shape
# as the whole class this repository keeps hitting: a mechanism reporting
# success while doing nothing.
#
# Fix a failure here with:
#   make secrets-rekey
#
# Usage:
#   ./verify-secret-recipients.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

SOPS_CONFIG=".sops.yaml"
FAILED=0

echo "=================================================================="
echo " Every encrypted file carries every recipient .sops.yaml names"
echo "=================================================================="

[ -f "$SOPS_CONFIG" ] || {
  echo "  error: $SOPS_CONFIG is missing." >&2
  exit 1
}

# The recipients this repository encrypts to, read from the config rather than
# listed here. A list in this file would be a second place to update, and the
# one certainty about a second place is that it will disagree.
#
# Commented-out placeholders for staging and prod must not count, hence the
# leading-hash filter.
RECIPIENTS="$(grep -v '^[[:space:]]*#' "$SOPS_CONFIG" | grep -oE 'age1[a-z0-9]{58}' | sort -u)"

if [ -z "$RECIPIENTS" ]; then
  echo "  error: no age recipients found in $SOPS_CONFIG." >&2
  exit 1
fi

RECIPIENT_COUNT="$(echo "$RECIPIENTS" | wc -l | tr -d ' ')"
echo ""
echo "  recipients configured: $RECIPIENT_COUNT"
echo "$RECIPIENTS" | sed 's/^/    /'
echo ""

# One recipient is not an error -- it is how this repository started -- but it
# is the condition T-0.8 exists to remove, so say so rather than passing
# quietly.
if [ "$RECIPIENT_COUNT" -lt 2 ]; then
  echo "  WARNING: only one recipient. Losing its private half makes every"
  echo "  secret here permanently unreadable, and every RTO in the disaster"
  echo "  recovery runbook is conditional on that one file surviving."
  echo ""
fi

ENCRYPTED_FILES="$(grep -rl '^sops:' --include='*.yaml' --include='*.yml' platform/ 2>/dev/null | sort)"

if [ -z "$ENCRYPTED_FILES" ]; then
  echo "  error: no SOPS-encrypted files found under platform/." >&2
  echo "  Either the layout moved or this check is looking in the wrong place;" >&2
  echo "  passing with nothing to inspect would be worse than failing." >&2
  exit 1
fi

CHECKED=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  CHECKED=$((CHECKED + 1))
  missing=""

  while IFS= read -r recipient; do
    [ -n "$recipient" ] || continue
    grep -q "$recipient" "$file" || missing="$missing $recipient"
  done <<< "$RECIPIENTS"

  if [ -n "$missing" ]; then
    echo "  MISSING  $file"
    for r in $missing; do
      echo "             $r"
    done
    FAILED=1
  else
    echo "  ok       $file"
  fi
done <<< "$ENCRYPTED_FILES"

echo ""
echo "=================================================================="
if [ "$FAILED" -eq 0 ]; then
  echo "PASSED — $CHECKED file(s), each readable by all $RECIPIENT_COUNT recipient(s)."
else
  echo "FAILED — at least one file cannot be decrypted by a recipient that"
  echo "         .sops.yaml says it should be. Run: make secrets-rekey"
fi
echo "=================================================================="

exit "$FAILED"
