#!/usr/bin/env bash
#
# Runs once, when the development container is created (T-4.4, #38).
#
# Two jobs: install the one tool devcontainer.json cannot pin (kubectl, whose
# version is derived rather than chosen), and refuse to hand over a container
# whose tools disagree with what the repository declares.
set -uo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# kubectl, at the minor the clusters actually run.
#
# infra/packer/versions.pkrvars.hcl is the single place this repository records
# its k3s version, and it says why: "ONE FILE, BECAUSE TWO WOULD DISAGREE".
# Naming a kubectl version in devcontainer.json would be the second file. So
# the k3s pin is read, the `+k3sN` suffix dropped, and the matching kubectl
# fetched -- an upgrade there moves this container with it, in the same commit,
# with nothing else to remember.
#
# The download is checksum-verified against the sha256 Kubernetes publishes
# beside the binary. Not decoration: this runs unattended on container create,
# including in Codespaces, and an unverified curl-to-disk is the one step here
# that could quietly install something else.
install_kubectl() {
  local k3s minor url tmp

  k3s="$(sed -n 's/^ *k3s_version *= *"\(v[0-9.]*\)+k3s[0-9]*".*/\1/p' \
    infra/packer/versions.pkrvars.hcl | head -1)"

  if [ -z "$k3s" ]; then
    echo "error: could not read k3s_version from infra/packer/versions.pkrvars.hcl." >&2
    echo "       That file is the source of truth for which kubectl belongs here." >&2
    return 1
  fi

  minor="${k3s%.*}"
  echo "==> kubectl ${k3s} (derived from k3s_version, cluster minor ${minor#v})"

  url="https://dl.k8s.io/release/${k3s}/bin/linux/amd64/kubectl"
  tmp="$(mktemp -d)"

  if ! curl -fsSL -o "$tmp/kubectl" "$url" ||
    ! curl -fsSL -o "$tmp/kubectl.sha256" "$url.sha256"; then
    echo "error: could not download kubectl ${k3s}." >&2
    rm -rf "$tmp"
    return 1
  fi

  # k8s publishes the bare digest, so the two-column form sha256sum wants is
  # assembled here rather than trusting the file's shape.
  if ! echo "$(cat "$tmp/kubectl.sha256")  $tmp/kubectl" | sha256sum --check --status; then
    echo "error: kubectl ${k3s} failed its checksum. Nothing installed." >&2
    rm -rf "$tmp"
    return 1
  fi

  sudo install -o root -g root -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl
  rm -rf "$tmp"
}

install_kubectl || exit 1

# ---------------------------------------------------------------------------
# Maven's dependencies, fetched once so the first `./mvnw verify` is not also
# the first download of half of Maven Central. Best-effort: a container that
# cannot warm a cache is still a usable container, so this does not fail it.
echo "==> warming the Maven cache (best effort)"
(cd services/core && ./mvnw -q -ntp dependency:go-offline) >/dev/null 2>&1 || true
(cd services/gateway && ./mvnw -q -ntp dependency:go-offline) >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# The pre-commit hook, which is otherwise a step everyone is told about in
# CONTRIBUTING.md and half of them skip. It formats and runs the secret scan.
make hooks >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
echo
bash .devcontainer/verify-versions.sh || exit 1

cat <<'EOF'

Ready. The inner loop is unchanged from docs/runbooks/local-development.md:

  make dev-up      Postgres, Keycloak, MinIO and both services  (~94s)
  make dev-down    stop it, remove the volumes
  make dev-logs    follow both services

What this container deliberately does NOT carry:

  sops / an age key   ADR-0003's key is a per-environment bootstrap secret. A
                      container that can decrypt this repository's secrets is a
                      container you would not want running on somebody else's
                      machine -- which is exactly what a Codespace is. Nothing
                      in the inner loop needs it; `make check-secrets` is a
                      grep, and it works.
  hcloud / packer     They act on real infrastructure and need real tokens.
  a kubeconfig        Reaching a cluster means being on the tailnet (ADR-0006),
                      which is a property of a machine, not of an image.

So `make up`, `make golden-image` and anything under infra/ that APPLIES rather
than validates are host operations, on purpose. `terraform fmt`, `validate` and
`tflint` all work here.
EOF
