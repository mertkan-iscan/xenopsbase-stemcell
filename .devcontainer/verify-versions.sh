#!/usr/bin/env bash
#
# Asserts that the tools installed in the container are the versions this
# repository declares (T-4.4, #38).
#
# WHY THIS EXISTS
#
# devcontainer.json has to name JDK, Node and Terraform versions as literals --
# a feature is resolved at build time and cannot read a pom. So three numbers
# now exist in two places each, which is precisely the drift
# infra/packer/versions.pkrvars.hcl was written to prevent for k3s:
#
#   "Keeping the number here and repeating it in a .tfvars is how those drift,
#    and a node running a different k3s from the one its image was tested with
#    fails in ways that look like anything except a version mismatch."
#
# The same argument applies to a container that builds with a JDK the pom does
# not accept. It cannot be fixed by having one copy, so it is fixed by making
# the copies check each other: this reads the DECLARATIONS back out of the
# repository and compares them with what is on PATH.
#
# It runs on every container create, and can be run by hand:
#
#   bash .devcontainer/verify-versions.sh
#
# Exits non-zero on any mismatch, with the file that disagrees named. A silent
# devcontainer that builds with the wrong JDK is worse than one that refuses.
set -uo pipefail

cd "$(dirname "$0")/.."

FAILURES=0

# Reports one comparison. Kept as a function so the output is uniform: a wall of
# ad-hoc echoes is how the one failing line gets missed.
check() {
  local what="$1" declared="$2" installed="$3" where="$4"
  if [ "$declared" = "$installed" ]; then
    printf '  %-10s %-12s ok        (declared in %s)\n' "$what" "$installed" "$where"
  else
    printf '  %-10s %-12s MISMATCH  declared %s in %s\n' \
      "$what" "$installed" "$declared" "$where"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "Tool versions, against what the repository declares:"

# --------------------------------------------------------------------------
# JDK. The pom's <java.version> is what the compiler is given as --release, so
# a lower JDK fails the build outright and a higher one silently compiles
# against a newer API than CI has.
#
# The legacy `1.8.0` spelling is mapped to 8. It should never appear inside this
# container, and it is exactly what infra/scripts/java-home.sh was written for
# after a machine had Java 8 first on PATH -- so reporting "1" there would be a
# confusing answer to a question somebody is already confused by.
JAVA_DECLARED="$(sed -n 's|.*<java.version>\([0-9]*\)</java.version>.*|\1|p' services/core/pom.xml | head -1)"
JAVA_RAW="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9._]*\).*/\1/p')"
case "$JAVA_RAW" in
1.*) JAVA_INSTALLED="$(echo "$JAVA_RAW" | cut -d. -f2)" ;;
*) JAVA_INSTALLED="${JAVA_RAW%%.*}" ;;
esac
check "JDK" "$JAVA_DECLARED" "$JAVA_INSTALLED" "services/core/pom.xml"

# --------------------------------------------------------------------------
# Node. engines.node is a MINIMUM (">=24.18.0"), so this compares the major and
# then the full version against the floor -- an exact match would fail on every
# patch release, which is a check people learn to ignore.
NODE_FLOOR="$(sed -n 's/.*"node": ">=\([0-9.]*\)".*/\1/p' services/gateway/package.json | head -1)"
NODE_INSTALLED="$(node --version 2>/dev/null | tr -d 'v')"
if [ -n "$NODE_FLOOR" ] && [ -n "$NODE_INSTALLED" ] &&
  [ "$(printf '%s\n%s\n' "$NODE_FLOOR" "$NODE_INSTALLED" | sort -V | head -1)" = "$NODE_FLOOR" ]; then
  printf '  %-10s %-12s ok        (>= %s, services/gateway/package.json)\n' \
    "node" "$NODE_INSTALLED" "$NODE_FLOOR"
else
  printf '  %-10s %-12s TOO OLD   engines.node requires >= %s\n' \
    "node" "${NODE_INSTALLED:-none}" "${NODE_FLOOR:-?}"
  FAILURES=$((FAILURES + 1))
fi

# --------------------------------------------------------------------------
# Terraform. Exact, because CI pins an exact version and `terraform fmt` output
# can differ between minors -- a fmt check that passes locally and fails in CI
# is the failure this catches.
TF_DECLARED="$(sed -n "s/^ *TF_VERSION: *'\([0-9.]*\)'.*/\1/p" .github/workflows/terraform.yml | head -1)"
TF_INSTALLED="$(terraform version -json 2>/dev/null | sed -n 's/.*"terraform_version": *"\([^"]*\)".*/\1/p' | head -1)"
check "terraform" "$TF_DECLARED" "${TF_INSTALLED:-none}" ".github/workflows/terraform.yml"

# --------------------------------------------------------------------------
# kubectl, against the k3s the golden image installs. Compared on MINOR only:
# kubectl supports one minor either side of the server, so requiring the patch
# to match would fail for a difference that does not matter and cannot always
# be satisfied -- there is no kubectl patch release per k3s patch release.
K3S_DECLARED="$(sed -n 's/^ *k3s_version *= *"v\([0-9]*\.[0-9]*\).*/\1/p' infra/packer/versions.pkrvars.hcl | head -1)"
KUBECTL_INSTALLED="$(kubectl version --client -o json 2>/dev/null |
  sed -n 's/.*"gitVersion": *"v\([0-9]*\.[0-9]*\).*/\1/p' | head -1)"
check "kubectl" "$K3S_DECLARED" "${KUBECTL_INSTALLED:-none}" "infra/packer/versions.pkrvars.hcl (k3s_version, minor)"

echo
if [ "$FAILURES" -gt 0 ]; then
  cat >&2 <<'EOF'
error: the container does not match what the repository declares.

Fix the container, not the declaration: the pom, package.json,
terraform.yml and versions.pkrvars.hcl are the source of truth, and
.devcontainer/devcontainer.json holds copies of three of them. Change
the copy, rebuild the container ("Dev Containers: Rebuild Container"),
and run this again.
EOF
  exit 1
fi

echo "All four agree with the repository."
