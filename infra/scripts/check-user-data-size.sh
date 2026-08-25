#!/usr/bin/env bash
#
# The node bootstrap must fit, with room to spare (T-1.19, #251).
#
# WHY A CHECK AND NOT A COMMENT
#
# #22 was open for months because nothing measured this. kube-hetzner's
# generated cloud-init grew past Hetzner's 32,768-byte user_data limit, and the
# only symptom was that autoscaled nodes were never created -- which looks
# exactly like "no scale-up was needed". The autoscaler decided correctly,
# called the API, was refused, and backed off. Everything reported success
# except the thing that mattered.
#
# So the size is now a number this repository asserts, and the assertion has a
# margin: the target is 2 KB against a 32 KB limit, so the bootstrap can grow
# by a factor of sixteen before it is a problem again. That margin is the point.
# Passing at 31 KB would be "correct" and would put us back where we started.
#
# WHICH SIZE
#
# The ENCODED length. The hcloud autoscaler passes `cloudInit` to the Hetzner
# API exactly as stored, without decoding it -- established by measurement, not
# assumption: the module's payload decoded to 26,499 bytes, comfortably inside
# the limit, and was rejected anyway, because the 35,332-character encoded form
# is what went over the wire.
#
# Measuring the decoded form would give a check that passes while the thing it
# measures fails. That is the failure mode this whole card exists to remove, so
# it would be a poor one to reintroduce here.
#
# Usage:
#   ./check-user-data-size.sh [env]
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

ENVIRONMENT="${1:-dev}"
TF_DIR="infra/terraform/cluster"
TEMPLATE="$TF_DIR/templates/node-bootstrap.yaml.tpl"

# Hetzner's hard limit, and the budget this project holds itself to.
HARD_LIMIT=32768
TARGET=2048

FAIL=0
note() { printf '  %-6s %s\n' "$1" "$2"; }

echo "=================================================================="
echo " Node bootstrap size — $ENVIRONMENT"
echo "=================================================================="

# ---------------------------------------------------------------------------
# 1. NO INSTALLER TEXT. Checked against the template, which is in git and holds
#    no secrets, so this half runs anywhere -- including CI, with no cluster and
#    no Hetzner token.
#
#    This is the criterion that actually keeps the size down. A payload can be
#    shrunk once; what stops it growing back is that nothing may reintroduce a
#    download-and-install step into the boot path. Everything static belongs in
#    the image (T-1.18), where it is built once and boot-tested (T-1.20).
if [ ! -f "$TEMPLATE" ]; then
  note FAIL "no $TEMPLATE"
  FAIL=1
else
  banned='get\.k3s\.io|INSTALL_K3S|KH_INSTALLER|k3s-selinux|checkmodule|semodule_package|curl .*releases/download|rpm -i|zypper (in|install)'
  hits="$(grep -nEi "$banned" "$TEMPLATE" || true)"
  if [ -n "$hits" ]; then
    note FAIL "the bootstrap installs something — that belongs in the image"
    printf '%s\n' "$hits" | sed 's/^/         /'
    FAIL=1
  else
    note ok "no installer, no download, no package manager in the boot path"
  fi
fi

# ---------------------------------------------------------------------------
# 2. THE SIZE ITSELF, from terraform, because only terraform knows what the
#    rendered bootstrap actually is once the token, the endpoint and the
#    Tailscale key are substituted in.
#
#    Terraform exports the LENGTH rather than the payload: the bootstrap carries
#    a cluster join token and a Tailscale auth key, and an output is written to
#    state and printed by anyone running `terraform output`.
if [ ! -d "$TF_DIR/.terraform" ]; then
  note skip "terraform is not initialised — size not measured"
  echo ""
  echo "  Run 'make up ENV=$ENVIRONMENT' first, or:"
  echo "    cd $TF_DIR && terraform init -backend-config=backend.hcl \\"
  echo "        -backend-config=key=$ENVIRONMENT/cluster.tfstate"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

bytes="$(cd "$TF_DIR" && terraform output -raw node_bootstrap_bytes 2>/dev/null)"

if ! printf '%s' "$bytes" | grep -qE '^[0-9]+$'; then
  # Almost always credentials rather than a missing output: `terraform output`
  # reads state from R2, so without AWS_ACCESS_KEY_ID it reports nothing and
  # looks exactly like an environment that was never applied.
  if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
    note skip "cannot read state — run: source ~/.xenopsbase.env"
  else
    note skip "no node_bootstrap_bytes output — has $ENVIRONMENT been applied?"
  fi
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

echo ""
printf '  bootstrap, as sent to Hetzner : %6d bytes\n' "$bytes"
printf '  budget                        : %6d bytes\n' "$TARGET"
printf '  Hetzner hard limit            : %6d bytes\n' "$HARD_LIMIT"
printf '  headroom to the hard limit    : %6dx\n' "$((HARD_LIMIT / (bytes > 0 ? bytes : 1)))"
echo ""

if [ "$bytes" -gt "$HARD_LIMIT" ]; then
  note FAIL "over Hetzner's limit — every node creation will be refused with"
  echo "         invalid input in field 'user_data' (invalid_input)"
  FAIL=1
elif [ "$bytes" -gt "$TARGET" ]; then
  note FAIL "over the $TARGET-byte budget"
  echo ""
  echo "         It would still be accepted today. The budget exists because"
  echo "         #22 was not a payload that was suddenly too big — it was one"
  echo "         that grew, unmeasured, until it was. Move whatever was added"
  echo "         into the golden image (make golden-image) rather than raising"
  echo "         this number."
  FAIL=1
else
  note ok "within budget"
fi

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASSED"
