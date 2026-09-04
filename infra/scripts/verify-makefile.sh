#!/usr/bin/env bash
#
# Smoke-checks the Makefile itself.
#
# WHY THIS EXISTS
#
# The Makefile is the interface every other one of these commands goes through,
# and until now nothing in CI read it. The Terraform workflow's path filter
# watches `infra/terraform/`, the services workflow watches the service trees,
# and `Makefile` matches neither -- so a change to it merged having been run by
# nobody. The one workflow that does invoke `make up` (cluster-lifecycle) is
# workflow_dispatch and schedule only, because it builds and destroys real
# Hetzner resources. It will never gate a pull request.
#
# What that let through (#427): `make kubeconfig` redirected terraform's output
# straight into the file it was writing, so the shell truncated the target to
# zero bytes BEFORE terraform ran, and any failed read left an EMPTY kubeconfig
# behind. kubectl treats an empty kubeconfig as no kubeconfig and falls back to
# its built-in http://localhost:8080 -- so the symptom is "connection refused to
# localhost:8080", which reads as a dead cluster rather than a missing file.
# That target also called neither check_env nor check_creds, so the guard
# written for exactly that mistake never ran on a target that makes it.
#
# Three checks, cheapest first:
#
#   parse        the Makefile still evaluates
#   guards       every target that runs terraform against REMOTE state reaches
#                check_creds, directly or through check_env
#   kubeconfig   a failed read leaves the previous kubeconfig intact
#
# The middle one is the point of the file. The reported defect was one target's;
# auditing the rest found the identical hole in three more (the mail-dns
# targets, which had only `preflight` -- and preflight verifies the CLOUDFLARE
# token's scope, never the AWS_* names the R2 backend actually uses). A check
# that only asserted the one fixed bug would have caught none of those. This is
# what notices the next one.
#
# Needs no credentials, no network and no cluster: it reads the Makefile, and
# for the last check runs make against a stub terraform in a temp directory.
#
# Usage: ./verify-makefile.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAKEFILE="$ROOT/Makefile"

fail=0
ok()   { printf 'ok    %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }
note() { printf '        %s\n' "$*"; }

test -f "$MAKEFILE" || { echo "no Makefile at $MAKEFILE"; exit 1; }

# ------------------------------------------------------------------------------
# 1. It still parses.
#
# `help` and not the default goal by name: help's recipe is grep, awk and echo,
# so a dry run of it cannot touch anything. Deliberately NOT `make -n` over
# every target -- `up` and `down` build their whole body as one shell command
# containing $(MAKE), and make EXECUTES a recipe line containing $(MAKE) even
# under -n. Dry-running those would really run wait-for-stack.sh.
# ------------------------------------------------------------------------------
if err="$(make -C "$ROOT" -n help 2>&1 >/dev/null)"; then
  ok "Makefile parses"
else
  bad "Makefile does not parse"
  note "$err"
fi

# ------------------------------------------------------------------------------
# 2. Every target that reaches remote state reaches the credential guard.
#
# Read statically rather than by dry-running each target, for the $(MAKE) reason
# above. A target's recipe is its tab-indented lines; recipe COMMENTS are
# skipped, because several of them discuss terraform without running it.
#
# Two deliberate exemptions, both of which genuinely need no credentials:
#   terraform fmt        rewrites files on disk, never opens a backend
#   -backend=false       what `validate` uses, precisely so it needs none
# ------------------------------------------------------------------------------
unguarded="$(awk '
  # A target line: unindented, name followed by a colon, not a variable.
  /^[A-Za-z0-9_.\/-]+[ ]*:([^=]|$)/ {
    flush()
    target = $0
    sub(/[ ]*:.*$/, "", target)
    in_recipe = 1
    has_tf = 0
    has_guard = 0
    next
  }

  # Anything else unindented and non-blank ends the recipe.
  /^[^\t]/ { flush(); in_recipe = 0; next }

  in_recipe && /^\t/ {
    line = $0
    stripped = line
    sub(/^\t+/, "", stripped)
    if (stripped ~ /^@?#/) next            # a recipe comment, not a command

    if (line ~ /terraform[ ]/ &&
        line !~ /terraform[ ]+fmt/ &&
        line !~ /-backend=false/) has_tf = 1

    if (line ~ /check_creds/ || line ~ /check_env/) has_guard = 1
  }

  END { flush() }

  function flush() {
    if (in_recipe && has_tf && !has_guard) print target
    has_tf = 0; has_guard = 0
  }
' "$MAKEFILE")"

if [ -z "$unguarded" ]; then
  ok "every terraform target reaches check_creds"
else
  bad "targets run terraform against remote state with no credential guard:"
  while IFS= read -r t; do note "$t"; done <<EOF
$unguarded
EOF
  note "add \$(call check_creds) -- or \$(call check_env,<dir>), which calls it."
  note "preflight is NOT a substitute: it checks a Cloudflare token's scope,"
  note "not the AWS_* names the R2 backend reads."
fi

# ------------------------------------------------------------------------------
# 3. A failed kubeconfig read must not destroy the kubeconfig.
#
# The regression test for #427. Runs the real target against a stub terraform in
# a temp tree, so it exercises the recipe rather than asserting on its text.
# ------------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/infra/terraform/cluster" "$TMP/bin"
cp "$MAKEFILE" "$TMP/Makefile"

cat > "$TMP/bin/terraform" <<'STUB'
#!/bin/sh
# Stands in for terraform. FAKE_TF picks which of the three outcomes to produce.
case "${FAKE_TF:-}" in
  fail)  echo "Error: Credential access key has length 20, should be 32" >&2; exit 1 ;;
  empty) exit 0 ;;                        # exits 0, writes nothing
  *)     echo "apiVersion: v1"; echo "clusters: []" ;;
esac
STUB
chmod +x "$TMP/bin/terraform"

KC="$TMP/infra/terraform/cluster/kubeconfig"
SENTINEL="PREVIOUS-GOOD-KUBECONFIG"

run_kubeconfig() {
  # A valid-looking R2 key (32 chars), so check_creds passes and the write
  # itself is what is under test.
  env PATH="$TMP/bin:$PATH" \
      FAKE_TF="$1" \
      AWS_ACCESS_KEY_ID="0123456789abcdef0123456789abcdef" \
      AWS_SECRET_ACCESS_KEY="stub" \
      make -C "$TMP" kubeconfig >/dev/null 2>&1
}

for scenario in fail empty; do
  printf '%s\n' "$SENTINEL" > "$KC"
  run_kubeconfig "$scenario"
  rc=$?

  if [ "$rc" -eq 0 ]; then
    bad "kubeconfig ($scenario): reported success on a read that produced nothing"
  elif [ ! -s "$KC" ]; then
    bad "kubeconfig ($scenario): left the kubeconfig EMPTY"
    note "kubectl reads an empty kubeconfig as none at all and falls back to"
    note "http://localhost:8080, which reads as a dead cluster, not a bad write."
  elif ! grep -q "$SENTINEL" "$KC"; then
    bad "kubeconfig ($scenario): overwrote the previous kubeconfig"
  else
    ok "kubeconfig ($scenario): previous kubeconfig left intact"
  fi

  if [ -e "$KC.tmp" ]; then
    bad "kubeconfig ($scenario): left kubeconfig.tmp behind"
  fi
done

# And the success path still actually writes.
printf '%s\n' "$SENTINEL" > "$KC"
if run_kubeconfig ok && grep -q "apiVersion" "$KC" && [ ! -e "$KC.tmp" ]; then
  ok "kubeconfig (success): written, no temp file left"
else
  bad "kubeconfig (success): did not write the kubeconfig cleanly"
fi

# The guard is reachable from this target at all -- the #427 defect exactly.
printf '%s\n' "$SENTINEL" > "$KC"
if env PATH="$TMP/bin:$PATH" FAKE_TF=ok \
       AWS_ACCESS_KEY_ID="ABCDEFGHIJ0123456789" \
       make -C "$TMP" kubeconfig >/dev/null 2>&1; then
  bad "kubeconfig: a 20-char Hetzner key in the R2 slot was accepted"
  note "that is the mistake check_creds exists to name."
else
  ok "kubeconfig: rejects a Hetzner key in the R2 slot"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "verify-makefile: FAILED"
  exit 1
fi
echo "verify-makefile: all checks passed"
