#!/usr/bin/env bash
#
# Creates the Terraform state bucket in Hetzner Object Storage.
#
# This is the chicken-and-egg step: Terraform cannot create the bucket that
# holds its own state. Rather than keeping a second Terraform configuration
# with local state (which becomes durable state living on a laptop, and so
# violates ADR-0002), the bucket is created by this idempotent script, which is
# itself version-controlled code.
#
# Safe to run repeatedly. Creates nothing that already exists.
#
# Usage:
#   export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
#   ./bootstrap-state-bucket.sh <bucket> [region]
#
set -euo pipefail

BUCKET="${1:-}"
REGION="${2:-fsn1}"
ENDPOINT="https://${REGION}.your-objectstorage.com"

if [ -z "$BUCKET" ]; then
  echo "usage: $0 <bucket> [region]" >&2
  echo "  region defaults to fsn1; one of fsn1, nbg1, hel1" >&2
  exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "error: the aws CLI is required (it speaks S3 to any compatible endpoint)" >&2
  echo "  https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
  exit 1
fi

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "error: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set" >&2
  echo "  generate these under Hetzner Cloud Console -> Object Storage -> Credentials" >&2
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

# Versioning is not optional. It is the only thing standing between a corrupted
# or truncated state write and a rebuild from nothing with no record of what
# exists. ADR-0002 puts Terraform state in the durable column; this is what
# makes that true rather than aspirational.
echo "==> enabling versioning"
s3 s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled >/dev/null

STATUS=$(s3 s3api get-bucket-versioning --bucket "$BUCKET" --query 'Status' --output text 2>/dev/null || echo "None")
if [ "$STATUS" != "Enabled" ]; then
  echo "error: versioning reports '$STATUS' rather than 'Enabled'" >&2
  echo "  do not proceed: unversioned state cannot be recovered from a bad write" >&2
  exit 1
fi
echo "    versioning Enabled"

echo
echo "Bucket ready. Next:"
echo "  cd infra/terraform"
echo "  cp backend.hcl.example backend.hcl   # set bucket=$BUCKET region=$REGION"
echo "  terraform init -backend-config=backend.hcl"
echo
echo "Then prove locking actually works before trusting it:"
echo "  make verify-locking"
