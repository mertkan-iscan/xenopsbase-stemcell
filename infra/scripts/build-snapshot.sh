#!/usr/bin/env bash
#
# Builds the OS snapshot that kube-hetzner provisions nodes from.
#
# WHY THIS IS A SEPARATE STEP
#
# kube-hetzner does not install an operating system. It expects a snapshot to
# already exist in the Hetzner project, labelled microos-snapshot=yes, and
# provisions every node from it. No snapshot means `terraform apply` fails
# before creating anything.
#
# The snapshot is DURABLE STATE in the sense of ADR-0002. It lives in the
# Hetzner project, `make down` does not remove it, and it is the same category
# as a container image: built once, reused by every rebuild.
#
# That distinction matters for the cold-rebuild target. A rebuild with the
# snapshot present is the 20 minute warm path. A rebuild into a genuinely empty
# Hetzner project has to build this first, which is the slowest single step in
# the whole sequence.
#
# Rerun this when: the project is new, the snapshot was deleted, or a Leap Micro
# or MicroOS update is wanted. Not needed for an ordinary `make up`.
#
# Usage:
#   export HCLOUD_TOKEN=<hetzner cloud api token>
#   ./build-snapshot.sh [module_version]
#
set -euo pipefail

MODULE_VERSION="${1:-3.1.0}"
TEMPLATE="hcloud-microos-snapshots.pkr.hcl"
RAW_BASE="https://raw.githubusercontent.com/kube-hetzner/terraform-hcloud-kube-hetzner"

if ! command -v packer >/dev/null 2>&1; then
  echo "error: packer is required" >&2
  echo "  https://developer.hashicorp.com/packer/install" >&2
  exit 1
fi

if [ -z "${HCLOUD_TOKEN:-}" ]; then
  echo "error: HCLOUD_TOKEN must be set" >&2
  echo "  Hetzner Cloud Console -> Security -> API tokens (read/write)" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Pinned to the same version as the Terraform module in
# infra/terraform/cluster/main.tf. A snapshot built from a different version of
# the template than the module expects is exactly the kind of drift that makes
# one rebuild differ from the last for reasons nobody chose.
URL="${RAW_BASE}/v${MODULE_VERSION}/packer-template/${TEMPLATE}"

echo "==> module version : $MODULE_VERSION"
echo "==> template       : $URL"

if ! curl -fsSL "$URL" -o "$WORK/$TEMPLATE"; then
  echo "error: could not download the packer template for v${MODULE_VERSION}" >&2
  echo "  check that the tag exists: https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/releases" >&2
  exit 1
fi

echo "==> initializing packer plugins"
packer init "$WORK/$TEMPLATE"

echo "==> building snapshot (this takes several minutes and creates a"
echo "    temporary billable server, which packer removes when it finishes)"
packer build "$WORK/$TEMPLATE"

echo
echo "Snapshot built. Verify it is labelled correctly:"
echo "  hcloud image list --selector microos-snapshot=yes"
echo
echo "This does not need running again for an ordinary rebuild. It is only"
echo "needed for a new Hetzner project, or to pick up an OS update."
