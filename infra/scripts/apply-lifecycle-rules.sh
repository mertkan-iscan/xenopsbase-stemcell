#!/usr/bin/env bash
#
# Applies bucket lifecycle rules from infra/lifecycle/*.json, then verifies them
# by reading them back.
#
# WHY THIS IS NOT TERRAFORM
#
# `aws_s3_bucket_lifecycle_configuration` cannot be used against Hetzner. The
# PUT works fine; the provider's post-write stabilization is what fails.
#
# After writing, the provider polls GetBucketLifecycleConfiguration until the
# response matches what it sent. Both HCL forms -- `filter {}` and the
# deprecated `prefix = ""` -- normalize internally to a V2 `Filter`. Hetzner
# always returns the V1 form instead:
#
#   <Rule><ID>..</ID><Prefix></Prefix><Status>Enabled</Status>..</Rule>
#
# with no Filter element at all. The comparison therefore never converges, and
# every lifecycle resource burns its full 3 minute timeout and fails -- while
# having actually applied the rules correctly. Verified 2026-08-19 against
# aws provider v6.60.0: 21 polls, a correct response every time, never accepted.
#
# So the rules live in reviewable JSON and are applied directly. This is still
# code under review, not manual configuration: the ADR-0002 rule is that no
# state is created BY HAND, and nothing here is.
#
# Revisit if Hetzner starts returning Filter, or the provider gains a way to
# skip stabilization.
#
# Usage:
#   export TF_VAR_hetzner_s3_access_key=... TF_VAR_hetzner_s3_secret_key=...
#   ./apply-lifecycle-rules.sh <environment> [prefix] [region]
#
set -euo pipefail

ENVIRONMENT="${1:-}"
PREFIX="${2:-xenopsbase}"
REGION="${3:-fsn1}"

if [ -z "$ENVIRONMENT" ]; then
  echo "usage: $0 <environment> [prefix] [region]" >&2
  echo "  buckets are per environment: <prefix>-<environment>-<name>" >&2
  exit 2
fi
ENDPOINT="https://${REGION}.your-objectstorage.com"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RULES_DIR="$ROOT/infra/lifecycle"

if [ ! -d "$RULES_DIR" ]; then
  echo "error: no rules directory at $RULES_DIR" >&2
  exit 1
fi

# These buckets are on Hetzner. Terraform state is on R2 (ADR-0005) and uses
# different credentials, so take Hetzner's explicitly rather than inheriting
# whatever AWS_ACCESS_KEY_ID currently points at.
AK="${TF_VAR_hetzner_s3_access_key:-${AWS_ACCESS_KEY_ID:-}}"
SK="${TF_VAR_hetzner_s3_secret_key:-${AWS_SECRET_ACCESS_KEY:-}}"

if [ -z "$AK" ] || [ -z "$SK" ]; then
  echo "error: set TF_VAR_hetzner_s3_access_key and TF_VAR_hetzner_s3_secret_key" >&2
  exit 1
fi

s3() { AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" \
       aws --endpoint-url "$ENDPOINT" --region "$REGION" "$@"; }

echo "==> endpoint    $ENDPOINT"
echo "==> environment $ENVIRONMENT"
echo "==> prefix      $PREFIX"
echo

FAILED=0
APPLIED=0
SKIPPED=0

for f in "$RULES_DIR"/*.json; do
  short="$(basename "$f" .json)"
  bucket="${PREFIX}-${ENVIRONMENT}-${short}"

  printf '%-32s ' "$bucket"

  if ! s3 s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    echo "SKIP (bucket does not exist)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # The JSON is passed inline rather than as file://. On Windows the aws CLI is
  # a native binary and cannot read Git Bash paths like /c/Users/..., so a
  # file:// reference fails with "No such file or directory" on exactly the
  # machine this is developed on. Inline needs no path translation anywhere.
  if ! err="$(s3 s3api put-bucket-lifecycle-configuration \
        --bucket "$bucket" \
        --lifecycle-configuration "$(cat "$f")" 2>&1)"; then
    echo "FAILED to apply"
    echo "    ${err}" | tr '\n' ' ' | cut -c1-200
    echo
    FAILED=1
    continue
  fi

  # Read back and confirm every rule ID we asked for is present. A PUT that
  # returns 200 but stores nothing is exactly the kind of silent failure this
  # project keeps running into.
  got="$(s3 s3api get-bucket-lifecycle-configuration --bucket "$bucket" 2>/dev/null || echo '{}')"
  # IDs extracted with grep rather than a JSON parser, so the script depends on
  # nothing but bash and the aws CLI. Same portability reason as above.
  missing=""
  for id in $(grep -o '"ID"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" | sed 's/.*"ID"[[:space:]]*:[[:space:]]*"//; s/"$//'); do
    echo "$got" | grep -q "\"$id\"" || missing="$missing $id"
  done

  if [ -n "$missing" ]; then
    echo "MISMATCH — missing:$missing"
    FAILED=1
  else
    echo "ok ($(echo "$got" | grep -c '"ID"') rules verified)"
    APPLIED=$((APPLIED + 1))
  fi
done

echo
if [ "$FAILED" -ne 0 ]; then
  echo "One or more buckets did not end up with the rules they should have."
  exit 1
fi

# Skipping every bucket is not success. Reporting it as success is worse than
# failing: it means "no buckets exist for this environment" reads identically to
# "all rules verified", and the difference only surfaces when retention silently
# never applies.
if [ "$APPLIED" -eq 0 ]; then
  echo "NOTHING APPLIED — all $SKIPPED buckets missing for environment '$ENVIRONMENT'."
  echo "  Run: make storage-apply ENV=$ENVIRONMENT"
  exit 1
fi

if [ "$SKIPPED" -ne 0 ]; then
  echo "$APPLIED bucket(s) verified, $SKIPPED skipped as missing — that is a partial run."
  exit 1
fi
echo "All lifecycle rules applied and verified ($APPLIED buckets)."
