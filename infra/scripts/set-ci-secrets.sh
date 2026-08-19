#!/usr/bin/env bash
#
# Sets the GitHub Actions secrets the Terraform CI plan job needs.
#
# Reads every value from the local environment — the same ~/.xenopsbase.env used
# for local applies — and pipes each one straight to `gh secret set`. Nothing is
# echoed, nothing is written to a file, and no value is ever pasted anywhere.
#
# Safe to re-run: setting a secret that exists overwrites it.
#
# Usage:
#   source ~/.xenopsbase.env
#   ./set-ci-secrets.sh
#
set -uo pipefail

REPO="${REPO:-mertkan-iscan/xenopsbase-stemcell}"

# Values that are identifiers rather than credentials. They are already in the
# repository's docs or in public DNS, so they are set here as literals.
CLOUDFLARE_ACCOUNT_ID_VALUE="5c35fb76276c7f2f8a6a5e0c706cd9e5"
CLOUDFLARE_ZONE_ID_VALUE="fd240e410e37e62bf59871037877fcfe"
R2_ENDPOINT_VALUE="https://${CLOUDFLARE_ACCOUNT_ID_VALUE}.r2.cloudflarestorage.com"

if ! command -v gh >/dev/null 2>&1; then
  echo "error: the gh CLI is required" >&2
  exit 1
fi

MISSING=0
need() {
  local var="$1"
  if [ -z "${!var:-}" ]; then
    echo "  missing from the environment: $var" >&2
    MISSING=1
  fi
}

need AWS_ACCESS_KEY_ID
need AWS_SECRET_ACCESS_KEY
need TF_VAR_hetzner_s3_access_key
need TF_VAR_hetzner_s3_secret_key
need HCLOUD_TOKEN
need TF_VAR_cloudflare_api_token
need TF_VAR_firewall_source_cidrs

if [ "$MISSING" -ne 0 ]; then
  echo >&2
  echo "run: source ~/.xenopsbase.env" >&2
  exit 1
fi

set_secret() {
  local name="$1" value="$2"
  printf '%s' "$value" | gh secret set "$name" --repo "$REPO" >/dev/null 2>&1 \
    && printf '  %-26s set\n' "$name" \
    || printf '  %-26s FAILED\n' "$name"
}

echo "==> repository $REPO"
echo

# Terraform state (R2, ADR-0005)
set_secret R2_ACCESS_KEY_ID       "$AWS_ACCESS_KEY_ID"
set_secret R2_SECRET_ACCESS_KEY   "$AWS_SECRET_ACCESS_KEY"
set_secret R2_ENDPOINT            "$R2_ENDPOINT_VALUE"

# Hetzner Object Storage (the durable buckets)
set_secret HETZNER_S3_ACCESS_KEY  "$TF_VAR_hetzner_s3_access_key"
set_secret HETZNER_S3_SECRET_KEY  "$TF_VAR_hetzner_s3_secret_key"

# Hetzner Cloud (the cluster)
set_secret HCLOUD_TOKEN           "$HCLOUD_TOKEN"
set_secret FIREWALL_SOURCE_CIDRS  "$TF_VAR_firewall_source_cidrs"

# Cloudflare (DNS and tunnel)
set_secret CLOUDFLARE_API_TOKEN   "$TF_VAR_cloudflare_api_token"
set_secret CLOUDFLARE_ACCOUNT_ID  "$CLOUDFLARE_ACCOUNT_ID_VALUE"
set_secret CLOUDFLARE_ZONE_ID     "$CLOUDFLARE_ZONE_ID_VALUE"

# Bucket policy inputs. Read from the gitignored tfvars so there is one source
# of truth rather than a second copy that can drift.
SECRETS_TFVARS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/infra/terraform/storage/env/dev.secrets.tfvars"
if [ -f "$SECRETS_TFVARS" ]; then
  val() { grep -oE "^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"[^\"]*\"" "$SECRETS_TFVARS" \
          | head -1 | sed 's/.*"\(.*\)"/\1/'; }
  set_secret HETZNER_PROJECT_ID "$(val project_id)"
  set_secret HETZNER_KEY_INFRA  "$(val infra)"
  set_secret HETZNER_KEY_APP    "$(val app)"
  set_secret HETZNER_KEY_DB     "$(val db)"
  set_secret HETZNER_KEY_OBS    "$(val observability)"
else
  echo
  echo "  note: $SECRETS_TFVARS not found, so the bucket-policy secrets were"
  echo "        skipped. Only the storage module's plan needs them."
fi

echo
echo "Done. Verify with:"
echo "  gh secret list --repo $REPO"
echo
echo "Then open any pull request touching infra/terraform/ and the plan job will"
echo "post a comment instead of warning that credentials are missing."
