#!/usr/bin/env bash
#
# Proves that Terraform state locking actually works against Hetzner Object
# Storage. Acceptance criterion for T-1.1.
#
# WHY THIS EXISTS
#
# Terraform's S3-native locking (use_lockfile) works by writing a .tflock object
# with an If-None-Match conditional PUT. The second writer is supposed to get
# HTTP 412 and back off.
#
# Hetzner's documentation does not state whether conditional requests are
# supported. If they are not, the conditional PUT degrades into an ordinary PUT:
# BOTH applies acquire the "lock", both write state, and the result is silent
# corruption. Locking fails OPEN, with no error and no warning.
#
# So locking is treated as unproven until this script passes, and it is re-run
# whenever the Terraform version or the storage endpoint changes.
#
# WHAT IT DOES
#
# Holds a real lock with a slow apply, then tries a second operation against the
# same state and asserts it is refused. Uses a throwaway state key; it never
# touches real infrastructure state.
#
# Usage:
#   export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
#   ./verify-state-locking.sh [path/to/backend.hcl]
#
set -uo pipefail

BACKEND="${1:-infra/terraform/backend.hcl}"
HOLD_SECONDS=45
SETTLE_SECONDS=15

if [ ! -f "$BACKEND" ]; then
  echo "error: backend config not found: $BACKEND" >&2
  echo "  cp infra/terraform/backend.hcl.example infra/terraform/backend.hcl" >&2
  exit 2
fi

BACKEND_ABS="$(cd "$(dirname "$BACKEND")" && pwd)/$(basename "$BACKEND")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Separate state key so a failed run can never damage real state.
LOCK_KEY="_verification/state-locking.tfstate"

write_config() {
  cat > "$1/main.tf" <<'TF'
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
  backend "s3" {
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
    use_path_style              = true
    use_lockfile                = true
  }
}

variable "hold_seconds" {
  type    = number
  default = 45
}

# Holds the state lock long enough for a second process to collide with it.
resource "time_sleep" "hold" {
  create_duration = "${var.hold_seconds}s"
}
TF
}

init() {
  ( cd "$1" && terraform init -input=false -no-color \
      -backend-config="$BACKEND_ABS" \
      -backend-config="key=$LOCK_KEY" ) >"$1/init.log" 2>&1
}

mkdir -p "$WORK/holder" "$WORK/contender"
write_config "$WORK/holder"
write_config "$WORK/contender"

echo "==> initializing two working directories against key $LOCK_KEY"
if ! init "$WORK/holder" || ! init "$WORK/contender"; then
  echo "error: terraform init failed" >&2
  tail -25 "$WORK/holder/init.log" >&2
  exit 1
fi

echo "==> holder: apply that holds the lock for ${HOLD_SECONDS}s"
( cd "$WORK/holder" && terraform apply -auto-approve -input=false -no-color \
    -var "hold_seconds=$HOLD_SECONDS" ) >"$WORK/holder/apply.log" 2>&1 &
HOLDER_PID=$!

echo "    waiting ${SETTLE_SECONDS}s for the lock to be taken"
sleep "$SETTLE_SECONDS"

if ! kill -0 "$HOLDER_PID" 2>/dev/null; then
  echo "error: the holding apply exited early, so nothing held the lock" >&2
  tail -25 "$WORK/holder/apply.log" >&2
  exit 1
fi

echo "==> contender: plan against the same state, expecting refusal"
( cd "$WORK/contender" && terraform plan -input=false -no-color -lock-timeout=0 ) \
  >"$WORK/contender/plan.log" 2>&1
CONTENDER_RC=$?

echo "    contender exit code: $CONTENDER_RC"

echo "==> waiting for the holder to finish"
wait "$HOLDER_PID" || true

echo "==> cleaning up the verification state"
( cd "$WORK/holder" && terraform destroy -auto-approve -input=false -no-color \
    -var "hold_seconds=0" ) >"$WORK/holder/destroy.log" 2>&1 || \
  echo "    warning: cleanup failed; remove $LOCK_KEY from the bucket by hand"

echo
if [ "$CONTENDER_RC" -ne 0 ] && grep -qiE "state lock|lock.*held|ConditionalRequestConflict|PreconditionFailed" "$WORK/contender/plan.log"; then
  echo "PASS — the second operation was refused while the lock was held."
  echo "       Conditional writes are honoured. Locking is proven."
  exit 0
fi

echo "FAIL — locking did NOT hold."
echo
if [ "$CONTENDER_RC" -eq 0 ]; then
  echo "  The contender acquired the lock while it was already held. This is the"
  echo "  dangerous outcome: the storage endpoint is ignoring If-None-Match, so"
  echo "  concurrent applies will both write state and silently corrupt it."
  echo
  echo "  Do NOT run applies from more than one place until this is resolved."
  echo "  Options: serialize applies through a single CI job, or move the state"
  echo "  bucket to a provider with proven conditional-write support. Either way"
  echo "  it needs an ADR, because it changes the durable-state story."
else
  echo "  The contender failed, but not with a recognisable lock error, so this"
  echo "  test proved nothing either way. Read the log and rerun."
fi
echo
echo "  contender log: ---------------------------------------------------"
sed 's/^/  /' "$WORK/contender/plan.log" | tail -30
exit 1
