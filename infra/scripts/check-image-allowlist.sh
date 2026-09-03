#!/usr/bin/env bash
#
# Every third-party image an enrolled namespace runs is in the digest allowlist
# (T-6.2, #49).
#
# WHY THIS IS THE PRICE OF CHOOSING A DIGEST ALLOWLIST
#
# `third-party-allowlist.yaml` names exact digests, so the digest IS the
# identity. That is the property that makes it a real control -- one artefact,
# byte for byte, rather than "anything that publisher ever signs".
#
# The cost is that repinning an image without editing the policy denies the
# workload. And it does not fail at deploy time: the manifest applies cleanly,
# the Deployment updates, and admission refuses the pod only when one is next
# created. A rollout, a node replacement, or an HPA scale-up hours later is where
# it surfaces.
#
# So this runs in CI, against the manifests rather than the cluster, and fails
# BEFORE the change lands.
#
# WHAT IT DOES NOT CHECK
#
# Images matching this project's own registry path. Those are covered by
# `xenopsbase-images-are-signed`, which verifies a Fulcio identity rather than a
# digest, and listing them here would assert the weaker claim about images for
# which the stronger one already holds.
#
# Usage:
#   ./check-image-allowlist.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

POLICY="platform/envs/dev/policy/third-party-allowlist.yaml"
# The namespaces enrolled in policy enforcement. Kept here rather than derived,
# because enrolling one is a deliberate act and this check should fail loudly if
# it is enrolled without its images being accounted for.
ENROLLED_DIRS="platform/envs/dev/services"

PY_BIN=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import re,sys' >/dev/null 2>&1; then
    PY_BIN="$candidate"
    break
  fi
done
[ -n "$PY_BIN" ] || {
  echo "error: a working python3 (or python) is required" >&2
  exit 1
}

echo "=================================================================="
echo " Third-party images in enrolled namespaces are allowlisted"
echo "=================================================================="
echo ""

"$PY_BIN" - "$POLICY" $ENROLLED_DIRS <<'PY'
import os
import re
import sys

policy_path = sys.argv[1]
dirs = sys.argv[2:]

OURS = "ghcr.io/mertkan-iscan/xenopsbase-stemcell/"

if not os.path.exists(policy_path):
    print("  error: no allowlist at %s" % policy_path)
    sys.exit(1)

with open(policy_path, encoding="utf-8") as handle:
    policy = handle.read()

# The globs, from the policy's own text. Parsed rather than YAML-loaded so this
# has no dependency beyond the standard library, and because the field is a
# simple list of strings.
allowed = set(re.findall(r'-\s+glob:\s*"([^"]+)"', policy))

images = {}
for directory in dirs:
    for root, _dirs, files in os.walk(directory):
        for name in files:
            if not name.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(root, name)
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    match = re.search(r"^\s*(?:-\s*)?image:\s*(\S+)", line)
                    if match:
                        images.setdefault(match.group(1).strip("\"'"), set()).add(path)

third_party = {img: where for img, where in images.items() if not img.startswith(OURS)}

if not third_party:
    print("  No third-party images in the enrolled namespaces.")
    print("  Nothing to allowlist, which is the strongest position to be in.")
    sys.exit(0)

missing = []
print("  %-72s %s" % ("image", "verdict"))
for image in sorted(third_party):
    ok = image in allowed
    print("  %-72s %s" % (image[:72], "allowlisted" if ok else "NOT ALLOWLISTED"))
    if not ok:
        missing.append(image)

print("")

# A digest-less reference cannot be allowlisted meaningfully: the tag can move
# under it, which is the whole reason this project pins.
untagged = [i for i in third_party if "@sha256:" not in i]
if untagged:
    print("  FAILED - %d third-party image(s) are not digest-pinned:" % len(untagged))
    for image in untagged:
        print("    %s" % image)
    print("")
    print("  A digest allowlist cannot cover a moving tag. Pin it first.")
    sys.exit(1)

if missing:
    print("  FAILED - %d third-party image(s) are not in the allowlist." % len(missing))
    print("")
    print("  Admission will DENY these, and not at deploy time -- the manifest applies")
    print("  cleanly and the refusal appears the next time a pod is created, which may")
    print("  be hours later during a rollout or a scale-up.")
    print("")
    print("  Add to %s:" % policy_path)
    for image in missing:
        print('    - glob: "%s"' % image)
        if "/" in image and not image.startswith(("ghcr.io/", "quay.io/", "index.docker.io/", "registry.k8s.io/")):
            print('    - glob: "index.docker.io/%s"' % image)
    sys.exit(1)

print("  PASSED - every third-party image in an enrolled namespace is allowlisted by digest.")
sys.exit(0)
PY
