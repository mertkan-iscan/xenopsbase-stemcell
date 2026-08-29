#!/usr/bin/env bash
#
# Copies every Terraform state object from R2 into the versioned Hetzner
# `tfstate` bucket, and verifies what is there (T-1.9, #71).
#
# WHY THIS EXISTS
#
# ADR-0005 moved state to R2 because Terraform's locking silently did nothing on
# Hetzner: `use_lockfile` needs conditional writes, and Hetzner does not
# implement them. R2 does. The trade recorded in that ADR is that R2 has no
# bucket versioning, so the move bought locking and sold version history.
#
# This is the compensating control for the half that was sold.
#
# Locking prevents two writers corrupting each other. It does nothing about ONE
# writer making a bad write -- a botched `terraform state rm`, a bad import, an
# upload truncated by a dropped connection. Until this existed, the recovery
# section of docs/runbooks/terraform-state.md said so in as many words: "There
# is currently no rollback."
#
# WHY A COPY RATHER THAN A SECOND BACKEND
#
# State can only live in one place; a second backend would be a second thing
# Terraform writes to, which reintroduces the concurrent-write problem ADR-0005
# solved. This is a one-way copy taken on a schedule. It is a backup, and it is
# read by a human during a recovery, never by Terraform.
#
# WHY THE DESTINATION IS NOT MANAGED BY TERRAFORM
#
# Same chicken-and-egg as infra/scripts/bootstrap-state-bucket.sh, plus a
# sharper edge: `make down` runs `terraform destroy` as an everyday operation.
# A bucket holding the backups of Terraform's own state must not be reachable
# by that. So this script creates it, idempotently, the way the bootstrap script
# creates the state bucket -- version-controlled code, not console clicking, so
# ADR-0002's "no state created by hand" still holds.
#
# Usage:
#   export R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... R2_ENDPOINT=https://<acct>.r2.cloudflarestorage.com
#   export HETZNER_S3_ACCESS_KEY=... HETZNER_S3_SECRET_KEY=...
#   ./backup-state.sh              # copy, then verify what landed
#   ./backup-state.sh --verify     # verify only; writes nothing anywhere
#
# --verify is the restore rehearsal. It reads the newest version of every object
# out of the Hetzner bucket and checks it against what R2 currently holds, which
# is every step of a real restore except the `terraform state push` at the end.
# It never writes to R2, so it is safe to run at any time, including while an
# apply is in flight.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKEND_HCL="$ROOT/infra/terraform/cluster/backend.hcl"

# WHERE THE SOURCE COMES FROM
#
# backend.hcl is what Terraform actually initializes against, so when it is
# there it decides: a bucket or endpoint that changes there brings the backup
# with it, rather than the backup keeping its own opinion about where state
# lives. The day those two disagree is the day somebody restores from a bucket
# nothing has written to in a year.
#
# It is GITIGNORED, so it exists on a developer's machine and never in CI. That
# is why this is a preference and not a requirement: the workflow passes
# R2_ENDPOINT from a secret instead, and the check below refuses to run with
# neither.
hcl_value() {
  [ -f "$BACKEND_HCL" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$BACKEND_HCL" | head -1
}

SOURCE_BUCKET="${STATE_BUCKET:-$(hcl_value bucket)}"
SOURCE_BUCKET="${SOURCE_BUCKET:-xenopsbase-tfstate}"

if [ -z "${R2_ENDPOINT:-}" ] && [ -f "$BACKEND_HCL" ]; then
  R2_ENDPOINT="$(sed -n 's|.*s3 *= *"\(https://[^"]*\)".*|\1|p' "$BACKEND_HCL" | head -1)"
fi
R2_ENDPOINT="${R2_ENDPOINT:-}"

# The credential names differ between here and CI, so both spellings work.
# Locally the repo's convention (docs/runbooks/terraform-state.md, and every
# other script) is AWS_* for R2 and TF_VAR_hetzner_s3_* for Hetzner; the
# workflow passes the explicit names because a job with two credential sets
# should not have either of them sitting in AWS_*.
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
HETZNER_S3_ACCESS_KEY="${HETZNER_S3_ACCESS_KEY:-${TF_VAR_hetzner_s3_access_key:-}}"
HETZNER_S3_SECRET_KEY="${HETZNER_S3_SECRET_KEY:-${TF_VAR_hetzner_s3_secret_key:-}}"

DEST_BUCKET="${STATE_BACKUP_BUCKET:-xenopsbase-tfstate}"
DEST_REGION="${HETZNER_S3_REGION:-fsn1}"
DEST_ENDPOINT="${HETZNER_S3_ENDPOINT:-https://${DEST_REGION}.your-objectstorage.com}"

# How old the newest backup may be before this reports a problem. The schedule
# is daily; two days allows one missed run without crying wolf, and catches a
# schedule that has stopped firing altogether -- which is not hypothetical:
# GitHub disables scheduled workflows in a repository after 60 days without
# activity, and it does so silently.
MAX_AGE_HOURS="${STATE_BACKUP_MAX_AGE_HOURS:-48}"

VERIFY_ONLY=0
[ "${1:-}" = "--verify" ] && VERIFY_ONLY=1

command -v aws >/dev/null 2>&1 || {
  echo "error: the aws CLI is required (it speaks S3 to any compatible endpoint)" >&2
  exit 1
}

# python3 on Linux and in CI; `python` is what a Windows install puts on PATH,
# and this repository is developed on one.
#
# Each candidate is RUN, not merely located. Windows ships an App Execution
# Alias at ~/AppData/Local/Microsoft/WindowsApps/python3 which exists, is
# executable, satisfies `command -v`, and does nothing except print an
# advertisement for the Microsoft Store. A `command -v` check picks it and every
# state file then reads as unparseable -- a real failure reported for a reason
# that has nothing to do with the state.
PY_BIN=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 &&
    "$candidate" -c 'import json,sys' >/dev/null 2>&1; then
    PY_BIN="$candidate"
    break
  fi
done
if [ -z "$PY_BIN" ]; then
  echo "error: a working python3 (or python) is required to read the state files" >&2
  exit 1
fi

for var in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT \
  HETZNER_S3_ACCESS_KEY HETZNER_S3_SECRET_KEY; do
  if [ -z "$(eval echo "\${$var:-}")" ]; then
    echo "error: $var is not set." >&2
    echo "  The R2 credentials are the state backend's; the Hetzner ones are the" >&2
    echo "  object-storage keys. They are different accounts and are not" >&2
    echo "  interchangeable -- see docs/runbooks/terraform-state.md." >&2
    exit 1
  fi
done

# Two endpoints, two credential sets, in one script. Each call names which it
# is using rather than relying on exported AWS_* variables, because the failure
# mode of getting that wrong is writing one provider's state into the other's
# bucket with a plausible-looking success message.
r2() {
  AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    aws --endpoint-url "$R2_ENDPOINT" --region auto "$@"
}

hetzner() {
  AWS_ACCESS_KEY_ID="$HETZNER_S3_ACCESS_KEY" \
    AWS_SECRET_ACCESS_KEY="$HETZNER_S3_SECRET_KEY" \
    aws --endpoint-url "$DEST_ENDPOINT" --region "$DEST_REGION" "$@"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

FAILED=0
COPIED=0
CHECKED=0

echo "=================================================================="
echo " Terraform state backup"
echo "=================================================================="
echo "  from  $SOURCE_BUCKET   $R2_ENDPOINT"
echo "  to    $DEST_BUCKET   $DEST_ENDPOINT"
echo "  mode  $([ "$VERIFY_ONLY" = 1 ] && echo "verify only, writes nothing" || echo "copy, then verify")"
echo ""

# ---------------------------------------------------------------------------
# The destination, and the property that makes it worth having.
if [ "$VERIFY_ONLY" = 0 ]; then
  if hetzner s3api head-bucket --bucket "$DEST_BUCKET" >/dev/null 2>&1; then
    echo "==> destination bucket exists"
  else
    echo "==> creating destination bucket"
    hetzner s3api create-bucket --bucket "$DEST_BUCKET" >/dev/null || {
      echo "error: could not create $DEST_BUCKET" >&2
      exit 1
    }
  fi

  hetzner s3api put-bucket-versioning --bucket "$DEST_BUCKET" \
    --versioning-configuration Status=Enabled >/dev/null 2>&1 || true
fi

# Checked every run, not only at creation. Versioning is the entire reason this
# destination was chosen over any other; a bucket that stopped reporting Enabled
# would still accept every copy and still look like a working backup, while
# each write quietly overwrote the last. That is a backup with one version in
# it, which is what R2 already is.
STATUS="$(hetzner s3api get-bucket-versioning --bucket "$DEST_BUCKET" \
  --query 'Status' --output text 2>/dev/null || echo "None")"

if [ "$STATUS" != "Enabled" ]; then
  echo "error: versioning on $DEST_BUCKET reports '$STATUS', not 'Enabled'." >&2
  echo "  Without it this copies over itself and keeps exactly one version," >&2
  echo "  which restores nothing that a bad write destroyed. Refusing to" >&2
  echo "  report a backup that cannot roll back." >&2
  exit 1
fi
echo "    versioning Enabled"
echo ""

# ---------------------------------------------------------------------------
# Which objects. Enumerated, never listed: a hardcoded set of state keys is one
# more thing to update when an environment or a root module is added, and the
# failure of forgetting is a state file nobody is backing up and nobody is told
# about. Adding a module now brings it into this automatically.
mapfile -t KEYS < <(
  r2 s3api list-objects-v2 --bucket "$SOURCE_BUCKET" \
    --query 'Contents[].Key' --output text 2>/dev/null |
    tr '\t' '\n' | grep -v '^$' | sort
)

if [ "${#KEYS[@]}" -eq 0 ]; then
  echo "error: no objects found in $SOURCE_BUCKET." >&2
  echo "  Never pass by finding nothing: an empty state bucket is either a" >&2
  echo "  credential pointing somewhere unexpected or a very bad day." >&2
  exit 1
fi

printf '%-42s %8s %10s  %s\n' "key" "serial" "bytes" "result"
printf '%-42s %8s %10s  %s\n' "------------------------------------------" "--------" "----------" "------"

for KEY in "${KEYS[@]}"; do
  # Lock objects are transient and are not state. Copying one would put a lock
  # into the backup history, and restoring it later would block the very apply
  # somebody is trying to run during a recovery.
  case "$KEY" in
  *.tflock)
    printf '%-42s %8s %10s  %s\n' "$KEY" "-" "-" "skipped (lock, not state)"
    continue
    ;;
  esac

  LOCAL="$WORK/$(echo "$KEY" | tr '/' '_')"

  if ! r2 s3api get-object --bucket "$SOURCE_BUCKET" --key "$KEY" "$LOCAL" >/dev/null 2>&1; then
    printf '%-42s %8s %10s  %s\n' "$KEY" "?" "?" "FAILED to read from R2"
    FAILED=$((FAILED + 1))
    continue
  fi

  # What a state file is, asserted rather than assumed. A zero-byte or
  # half-written object is exactly what this exists to recover FROM, so it is
  # still copied -- the history should contain the bad write, or the version
  # before it cannot be identified -- but it is reported rather than counted
  # as a healthy backup.
  READ="$("$PY_BIN" - "$LOCAL" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        state = json.load(fh)
    print("%s\t%s\t%s" % (state.get("serial", "?"),
                          str(state.get("lineage", "?"))[:8],
                          "ok"))
except Exception as exc:
    print("?\t?\tUNPARSEABLE: %s" % type(exc).__name__)
PY
  )"
  SERIAL="$(echo "$READ" | cut -f1)"
  LINEAGE="$(echo "$READ" | cut -f2)"
  HEALTH="$(echo "$READ" | cut -f3)"
  BYTES="$(wc -c <"$LOCAL" | tr -d ' ')"

  if [ "$VERIFY_ONLY" = 0 ]; then
    if ! hetzner s3api put-object --bucket "$DEST_BUCKET" --key "$KEY" \
      --body "$LOCAL" >/dev/null 2>&1; then
      printf '%-42s %8s %10s  %s\n' "$KEY" "$SERIAL" "$BYTES" "FAILED to write to Hetzner"
      FAILED=$((FAILED + 1))
      continue
    fi
    COPIED=$((COPIED + 1))
  fi

  # Read back what is actually there. An upload that returned 200 and stored
  # something else is the failure a backup cannot afford, and it is cheap to
  # rule out: these objects are kilobytes.
  BACK="$WORK/back"
  if ! hetzner s3api get-object --bucket "$DEST_BUCKET" --key "$KEY" "$BACK" >/dev/null 2>&1; then
    # In verify mode this is the finding rather than a plumbing error: an object
    # R2 holds has never been backed up at all.
    MISSING="FAILED to read back"
    [ "$VERIFY_ONLY" = 1 ] && MISSING="NOT IN BACKUP"
    printf '%-42s %8s %10s  %s\n' "$KEY" "$SERIAL" "$BYTES" "$MISSING"
    FAILED=$((FAILED + 1))
    continue
  fi

  if [ "$(sha256sum <"$LOCAL" | cut -d' ' -f1)" != "$(sha256sum <"$BACK" | cut -d' ' -f1)" ]; then
    printf '%-42s %8s %10s  %s\n' "$KEY" "$SERIAL" "$BYTES" "MISMATCH against R2"
    FAILED=$((FAILED + 1))
    continue
  fi

  CHECKED=$((CHECKED + 1))
  RESULT="lineage $LINEAGE, verified"
  [ "$HEALTH" != "ok" ] && RESULT="$HEALTH (copied anyway)"
  printf '%-42s %8s %10s  %s\n' "$KEY" "$SERIAL" "$BYTES" "$RESULT"
done

# ---------------------------------------------------------------------------
# How old the newest copy is. This is what turns "the job is green" into "there
# is a recent backup" -- they are not the same statement, and only the second
# one is what somebody in a recovery needs.
echo ""
NEWEST="$(hetzner s3api list-objects-v2 --bucket "$DEST_BUCKET" \
  --query 'max_by(Contents, &LastModified).LastModified' --output text 2>/dev/null || echo "None")"

if [ "$NEWEST" = "None" ] || [ -z "$NEWEST" ]; then
  echo "error: the destination bucket reports no objects at all." >&2
  FAILED=$((FAILED + 1))
else
  AGE="$("$PY_BIN" - "$NEWEST" "$MAX_AGE_HOURS" <<'PY'
import datetime, sys
newest = sys.argv[1].replace("Z", "+00:00")
stamp = datetime.datetime.fromisoformat(newest)
hours = (datetime.datetime.now(datetime.timezone.utc) - stamp).total_seconds() / 3600
print("%.1f\t%s" % (hours, "stale" if hours > float(sys.argv[2]) else "fresh"))
PY
  )"
  HOURS="$(echo "$AGE" | cut -f1)"
  VERDICT="$(echo "$AGE" | cut -f2)"
  echo "newest object in $DEST_BUCKET is ${HOURS}h old ($VERDICT, limit ${MAX_AGE_HOURS}h)"
  if [ "$VERDICT" = "stale" ]; then
    echo "error: the most recent backup is older than ${MAX_AGE_HOURS}h." >&2
    echo "  The schedule has not been running. GitHub disables scheduled" >&2
    echo "  workflows after 60 days without repository activity, silently," >&2
    echo "  and that is the way this stops without anything going red." >&2
    FAILED=$((FAILED + 1))
  fi
fi

echo ""
echo "=================================================================="
if [ "$FAILED" -gt 0 ]; then
  echo " FAILED — $FAILED problem(s). $CHECKED object(s) verified."
  echo "=================================================================="
  exit 1
fi

if [ "$VERIFY_ONLY" = 1 ]; then
  echo " VERIFIED — $CHECKED state object(s) in the backup match what R2 holds."
else
  echo " OK — $COPIED state object(s) copied and read back byte-for-byte."
fi
echo "=================================================================="
