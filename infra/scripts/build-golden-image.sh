#!/usr/bin/env bash
#
# Builds the golden image every node boots from (T-1.18, #250).
#
# WHERE THIS SITS
#
#   make snapshot       kube-hetzner's base Leap Micro image. Rarely rebuilt --
#                       only for an OS update or a new Hetzner project.
#   make golden-image   THIS. Boots the base, installs pinned k3s, pinned
#                       Tailscale and the compiled SELinux policy, and
#                       snapshots the result.
#
# The split is deliberate. The base is upstream's problem and gets their
# verified download and signature checking for free; this layer is ours and is
# small enough to read in one sitting. Forking their template to add two
# binaries would mean owning all of it.
#
# WHY THE .te FILES ARE EXTRACTED RATHER THAN VENDORED
#
# The SELinux policy sources are kube-hetzner's, and they change with the
# module version. Copying them into this repository would mean a second place
# that must be updated when the module is bumped, and a silent divergence when
# it is not -- the image would enforce a policy the running cluster no longer
# uses. So they are pulled from the SAME module version terraform pins, at
# build time, and the version is recorded on the snapshot.
#
# Usage:
#   source ~/.xenopsbase.env && ./build-golden-image.sh [module_version]
#
set -euo pipefail

MODULE_VERSION="${1:-3.1.0}"
REPO="https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKER_DIR="$ROOT/infra/packer"
VARS_FILE="$PACKER_DIR/versions.pkrvars.hcl"

if [ -z "${HCLOUD_TOKEN:-}" ]; then
  echo "error: HCLOUD_TOKEN is not set — run: source ~/.xenopsbase.env" >&2
  exit 1
fi

if ! command -v packer >/dev/null 2>&1; then
  echo "error: packer is required — https://developer.hashicorp.com/packer/install" >&2
  exit 1
fi

# Same exact pin as the base template. Packer refuses a mismatch anyway; saying
# so here is clearer than a constraint error after a download.
WANT_PACKER="1.16.0"
HAVE_PACKER="$(packer version 2>/dev/null | head -1 | sed 's/^Packer v//')"
if [ "$HAVE_PACKER" != "$WANT_PACKER" ]; then
  echo "warning: this template pins packer $WANT_PACKER, found $HAVE_PACKER" >&2
  echo "  on Windows: scoop update packer" >&2
fi

# ---------------------------------------------------------------------------
# The base image must exist. Without it there is nothing to layer onto, and the
# error from packer's image_filter is a good deal less obvious than this.
echo "==> checking for the base snapshot"
if ! curl -sS -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
     "https://api.hetzner.cloud/v1/images?type=snapshot&label_selector=leapmicro-snapshot%3Dyes" \
     | grep -q '"id"'; then
  echo "error: no snapshot labelled leapmicro-snapshot=yes in this project." >&2
  echo "       run: make snapshot" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> module version : $MODULE_VERSION  (SELinux policy sources)"
if ! curl -fsSL "$REPO/archive/refs/tags/v${MODULE_VERSION}.tar.gz" -o "$WORK/src.tar.gz"; then
  echo "error: could not download module v${MODULE_VERSION}" >&2
  exit 1
fi

# Only the templates directory: the repository root carries a symlink that tar
# cannot create on Windows, which aborts a full extraction.
tar -xzf "$WORK/src.tar.gz" -C "$WORK" --strip-components=1 \
    "terraform-hcloud-kube-hetzner-${MODULE_VERSION}/templates"

POLICY_DIR="$WORK/selinux"
mkdir -p "$POLICY_DIR"
# Renamed to underscores on the way out, and that is not cosmetic:
# `checkmodule` refuses to compile unless the OUTPUT BASENAME matches the
# module name declared on the first line of the .te --
#
#   module kube_hetzner_selinux 1.0;
#   module k8s_custom_policies 1.0;
#
# The module ships them hyphenated as templates and writes them underscored
# into cloud-init, so the underscored names are also what a node built the
# normal way ends up with. Using the same names means `semodule -l` reads
# identically on a golden-image node and a conventionally built one.
copy_policy() {
  src="$WORK/templates/$1"
  if [ ! -f "$src" ]; then
    echo "error: $1 not found in module v${MODULE_VERSION}." >&2
    echo "       The module reorganised its templates; this script needs updating." >&2
    exit 1
  fi
  cp "$src" "$POLICY_DIR/$2"
}
copy_policy kube-hetzner-selinux.te kube_hetzner_selinux.te
copy_policy k8s-custom-policies.te  k8s_custom_policies.te
echo "==> selinux policy : $(wc -c < "$POLICY_DIR/kube_hetzner_selinux.te") + $(wc -c < "$POLICY_DIR/k8s_custom_policies.te") bytes"

# ---------------------------------------------------------------------------
echo "==> initializing packer plugins"
packer init "$PACKER_DIR/golden-image.pkr.hcl"

echo "==> building (several minutes; creates one temporary billable server,"
echo "    which packer removes when it finishes)"
packer build \
  -var-file="$VARS_FILE" \
  -var "selinux_policy_dir=$POLICY_DIR" \
  "$PACKER_DIR/golden-image.pkr.hcl"

# python3 on Linux, python on Windows -- resolved by RUNNING each candidate,
# because Windows ships a python3 App Execution Alias that satisfies `command -v`
# and then exits 49 printing an advert for the Microsoft Store.
PY_BIN="$(python3 -c '' >/dev/null 2>&1 && echo python3 || echo python)"

echo ""
echo "=================================================================="
echo " Golden image built"
echo "=================================================================="
curl -sS -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
  "https://api.hetzner.cloud/v1/images?type=snapshot&label_selector=xenopsbase-golden%3Dyes" \
  | "$PY_BIN" -c '
import json, sys
images = json.load(sys.stdin).get("images", [])
images.sort(key=lambda i: i["created"], reverse=True)
for i in images[:5]:
    labels = i.get("labels", {})
    print("  %-12s %-34s k3s=%s tailscale=%s  %.1fGB  %s" % (
        i["id"], (i.get("description") or "")[:34],
        labels.get("k3s-version", "?"), labels.get("tailscale-version", "?"),
        i.get("image_size") or 0, i["created"][:19]))
print("")
print("  Point terraform at the newest id, and keep the old one until the")
print("  replacement has been proven (T-7.9). Retention is T-1.21.")
' 2>/dev/null || echo "  (built; could not list snapshots)"
