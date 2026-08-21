#!/usr/bin/env bash
#
# Builds the OS snapshot that kube-hetzner provisions nodes from.
#
# WHY THIS IS A SEPARATE STEP
#
# kube-hetzner does not install an operating system. It expects a snapshot to
# already exist in the Hetzner project and provisions every node from it. No
# snapshot means `terraform apply` fails before creating anything.
#
# The snapshot is DURABLE STATE in the sense of ADR-0002. It lives in the
# Hetzner project, `make down` does not remove it, and it is the same category
# as a container image: built once, reused by every rebuild.
#
# That distinction matters for the cold-rebuild target. A rebuild with the
# snapshot present is the warm path. A rebuild into a genuinely empty Hetzner
# project has to build this first, which is the slowest single step.
#
# WHICH OS
#
# kube-hetzner 3.1.0 defaults NEW node pools to Leap Micro, not MicroOS
# (locals.tf: control_plane_nodepool_default_os -> "leapmicro"). The module then
# looks for a snapshot labelled:
#
#   leapmicro-snapshot=yes,kube-hetzner/os=leapmicro,kube-hetzner/k8s-distro=<distro>
#
# Building the microos template instead produces a snapshot the module never
# looks for, and apply fails with no image found. Override with the `os` field
# per nodepool if you want MicroOS, and pass microos below to match.
#
# Rerun this when: the project is new, the snapshot was deleted, or an OS update
# is wanted. Not needed for an ordinary `make up`.
#
# Usage:
#   export HCLOUD_TOKEN=<hetzner cloud api token>
#   ./build-snapshot.sh [module_version] [leapmicro|microos] [x86|arm|both]
#
set -euo pipefail

MODULE_VERSION="${1:-3.1.0}"
OS_VARIANT="${2:-leapmicro}"
ARCH="${3:-x86}"
REPO="https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner"

case "$OS_VARIANT" in
  leapmicro) TEMPLATE="hcloud-leapmicro-snapshots.pkr.hcl" ;;
  microos)   TEMPLATE="hcloud-microos-snapshots.pkr.hcl" ;;
  *) echo "error: os variant must be leapmicro or microos, got '$OS_VARIANT'" >&2; exit 2 ;;
esac

if ! command -v packer >/dev/null 2>&1; then
  echo "error: packer is required" >&2
  echo "  https://developer.hashicorp.com/packer/install" >&2
  exit 1
fi

# The template pins Packer EXACTLY (`required_version = "= 1.16.0"` for module
# 3.1.0), so both older and newer are rejected. Checked here rather than letting
# packer fail with a less obvious message after the download.
WANT_PACKER="$(printf '%s' "1.16.0")"
HAVE_PACKER="$(packer version 2>/dev/null | head -1 | sed 's/^Packer v//')"
if [ "$HAVE_PACKER" != "$WANT_PACKER" ]; then
  echo "warning: template for module $MODULE_VERSION expects packer $WANT_PACKER, found $HAVE_PACKER" >&2
  echo "  on Windows: scoop update packer" >&2
  echo "  if that reports 'Running process detected', kill the stale packer.exe first" >&2
  echo "  continuing anyway; packer will refuse if the constraint is not met" >&2
fi

if [ -z "${HCLOUD_TOKEN:-}" ]; then
  echo "error: HCLOUD_TOKEN must be set" >&2
  echo "  Hetzner Cloud Console -> Security -> API tokens (read/write)" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The whole packer-template directory is needed, not just the .pkr.hcl file.
# The template calls filebase64 on sibling paths (keys/*.asc, scripts/), so
# downloading the single file fails at build time with a missing-file error.
#
# Only that directory is extracted: the repository root contains a symlink
# (AGENTS.md -> CLAUDE.md) that tar cannot create on Windows, which would abort
# a full extraction.
echo "==> module version : $MODULE_VERSION"
echo "==> os variant     : $OS_VARIANT"
echo "==> downloading    : $REPO @ v$MODULE_VERSION"

if ! curl -fsSL "$REPO/archive/refs/tags/v${MODULE_VERSION}.tar.gz" -o "$WORK/src.tar.gz"; then
  echo "error: could not download v${MODULE_VERSION}" >&2
  echo "  check the tag exists: $REPO/releases" >&2
  exit 1
fi

tar -xzf "$WORK/src.tar.gz" -C "$WORK" --strip-components=1 \
    "terraform-hcloud-kube-hetzner-${MODULE_VERSION}/packer-template"

TPL_DIR="$WORK/packer-template"
if [ ! -f "$TPL_DIR/$TEMPLATE" ]; then
  echo "error: $TEMPLATE not found in the downloaded template directory" >&2
  ls -1 "$TPL_DIR" >&2
  exit 1
fi

echo "==> initializing packer plugins"
packer init "$TPL_DIR/$TEMPLATE"

# The template builds x86 AND ARM snapshots by default. Only the architecture
# actually used is built here, for two reasons:
#
#   1. It halves the time and the temporary server cost.
#   2. The ARM build fails outright where the ARM server type is unavailable in
#      the chosen location ("unsupported location for server type"). Packer then
#      exits non-zero even though the x86 snapshot built perfectly, which makes
#      a successful run look like a failed one.
#
# Pass "arm" as the third argument for ARM node pools (cax*), or "both".
case "$ARCH" in
  x86)  ONLY="-only=hcloud.${OS_VARIANT}-x86-snapshot" ;;
  arm)  ONLY="-only=hcloud.${OS_VARIANT}-arm-snapshot" ;;
  both) ONLY="" ;;
  *) echo "error: arch must be x86, arm or both, got '$ARCH'" >&2; exit 2 ;;
esac

echo "==> architecture   : $ARCH"
echo "==> building snapshot (several minutes; creates a temporary billable"
echo "    server, which packer removes when it finishes)"
# shellcheck disable=SC2086
packer build $ONLY "$TPL_DIR/$TEMPLATE"

echo
echo "Snapshot built. Verify it is labelled as the module expects:"
if [ "$OS_VARIANT" = "leapmicro" ]; then
  echo "  hcloud image list --selector leapmicro-snapshot=yes"
else
  echo "  hcloud image list --selector microos-snapshot=yes"
fi
echo
echo "This does not need running again for an ordinary rebuild. It is only"
echo "needed for a new Hetzner project, or to pick up an OS update."
