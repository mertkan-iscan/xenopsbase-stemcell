#!/usr/bin/env bash
#
# Creates the Terraform state bucket.
#
# This is the chicken-and-egg step: Terraform cannot create the bucket that
# holds its own state. Rather than keeping a second Terraform configuration
# with local state (which becomes durable state living on a laptop, and so
# violates ADR-0002), the bucket is created by this idempotent script, which is
# itself version-controlled code.
#
# The state bucket lives in CLOUDFLARE R2, not Hetzner (ADR-0005). Hetzner does
# not implement conditional writes, so Terraform's state locking silently did
# nothing there. Only state moved; the durable buckets are still Hetzner and are
# managed by Terraform in infra/terraform/storage/.
#
# Safe to run repeatedly. Creates nothing that already exists.
#
# Usage:
#   export AWS_ACCESS_KEY_ID=<r2 access key> AWS_SECRET_ACCESS_KEY=<r2 secret>
#   ./bootstrap-state-bucket.sh <bucket> <endpoint-url> [region]
#
# Example:
#   ./bootstrap-state-bucket.sh xenopsbase-tfstate \
#       https://<account_id>.r2.cloudflarestorage.com auto
#
set -euo pipefail

BUCKET="${1:-}"
ENDPOINT="${2:-}"
REGION="${3:-auto}"

if [ -z "$BUCKET" ] || [ -z "$ENDPOINT" ]; then
  echo "usage: $0 <bucket> <endpoint-url> [region]" >&2
  echo >&2
  echo "  R2:      $0 xenopsbase-tfstate https://<account_id>.r2.cloudflarestorage.com auto" >&2
  echo "  Hetzner: $0 <bucket> https://fsn1.your-objectstorage.com fsn1" >&2
  exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "error: the aws CLI is required (it speaks S3 to any compatible endpoint)" >&2
  echo "  https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
  exit 1
fi

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "error: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set" >&2
  echo "  for R2 these are the R2 API token credentials, NOT the Hetzner ones" >&2
  echo "  Cloudflare dashboard -> R2 -> API -> Manage API tokens" >&2
  exit 1
fi

s3() { aws --endpoint-url "$ENDPOINT" --region "$REGION" "$@"; }

echo "==> endpoint $ENDPOINT"
echo "==> bucket   $BUCKET"

if s3 s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "    bucket already exists, leaving it alone"
else
  echo "==> creating bucket"
  s3 s3api create-bucket --bucket "$BUCKET" >/dev/null
  echo "    created"
fi

# Versioning is what makes a corrupted or truncated state write recoverable.
#
# R2 does not implement it: PutBucketVersioning and GetBucketVersioning are
# both unsupported. That is the cost recorded in ADR-0005 — locking was chosen
# over version history, because locking prevents the failure this design
# actually provokes (an automated nightly writer alongside a human one) while
# versioning only recovers afterwards.
#
# So a failure here is expected on R2 and is not fatal. It IS reported loudly,
# because it means one recovery path in the runbook does not exist.
echo "==> enabling versioning"
if s3 s3api put-bucket-versioning \
     --bucket "$BUCKET" \
     --versioning-configuration Status=Enabled >/dev/null 2>&1; then

  STATUS=$(s3 s3api get-bucket-versioning --bucket "$BUCKET" --query 'Status' --output text 2>/dev/null || echo "None")
  if [ "$STATUS" != "Enabled" ]; then
    echo "error: versioning was accepted but reports '$STATUS'" >&2
    echo "  that inconsistency is worse than no versioning; do not proceed" >&2
    exit 1
  fi
  echo "    versioning Enabled"
else
  echo
  echo "    ⚠️  versioning NOT available on this endpoint (expected on R2)"
  echo
  echo "    A bad state write cannot be rolled back from bucket history. The"
  echo "    'State is corrupted' recovery in docs/runbooks/terraform-state.md"
  echo "    does not apply until the scheduled copy into the versioned Hetzner"
  echo "    bucket exists. See ADR-0005."
  echo
fi

echo
echo "Bucket ready. Next:"
echo "  cp infra/terraform/storage/backend.hcl.example infra/terraform/storage/backend.hcl"
echo "    then set bucket=$BUCKET and the endpoint in it"
echo "  cd infra/terraform/storage && terraform init -backend-config=backend.hcl"
echo
echo "Then prove locking actually works before trusting it:"
echo "  bash infra/scripts/verify-state-locking.sh infra/terraform/storage/backend.hcl"
