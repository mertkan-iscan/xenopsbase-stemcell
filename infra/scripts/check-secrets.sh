#!/usr/bin/env bash
#
# Refuses to let an unencrypted secret reach the repository.
#
# Two independent checks, because they catch different mistakes:
#
#   1. Every file under a secrets/ directory must actually be SOPS-encrypted.
#      This catches the common failure: editing a secret, forgetting to
#      re-encrypt, and committing the plaintext. The file looks right, the diff
#      looks plausible, and the secret is public forever.
#
#   2. Obvious credential shapes anywhere in tracked files. Narrow on purpose --
#      broad heuristics produce false positives, and a check people routinely
#      override is not a check.
#
# This repository is PUBLIC. A secret committed here is disclosed the moment it
# is pushed, and rewriting history does not undo that: it must be rotated.
#
# Usage:
#   ./check-secrets.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
FAILED=0

echo "=================================================================="
echo " 1. Files under secrets/ must be SOPS-encrypted"
echo "=================================================================="

# Only tracked files: an unencrypted secret sitting untracked in a working copy
# is a local matter, not a disclosure.
mapfile -t SECRET_FILES < <(git ls-files -- '*/secrets/*.yaml' '*/secrets/*.yml' 2>/dev/null)

if [ "${#SECRET_FILES[@]}" -eq 0 ]; then
  echo "  no secret files tracked yet"
else
  for f in "${SECRET_FILES[@]}"; do
    # Only files that actually DECLARE a Secret need encrypting. A secrets/
    # directory also holds the machinery that decrypts them -- a kustomization
    # and a ksops generator -- which carry no sensitive data.
    #
    # Keying on location rather than content made this check fail on its own
    # plumbing, which is the false positive its own comments warn about: a check
    # people routinely override is not a check.
    if ! grep -qE '^kind:[[:space:]]*Secret[[:space:]]*$' "$f" 2>/dev/null; then
      printf '  %-56s %s
' "$f" "skipped (not a Secret)"
      continue
    fi

    printf '  %-56s ' "$f"
    if grep -q '^sops:' "$f" 2>/dev/null || grep -q '"sops"' "$f" 2>/dev/null; then
      # Encrypted, but confirm the payload really is ciphertext rather than a
      # file that merely carries a stale sops block.
      if grep -qE 'ENC\[AES256_GCM' "$f" 2>/dev/null; then
        echo "encrypted"
      else
        echo "HAS A SOPS BLOCK BUT NO CIPHERTEXT"
        FAILED=1
      fi
    else
      echo "PLAINTEXT — refusing"
      FAILED=1
    fi
  done
fi

echo
echo "=================================================================="
echo " 2. Credential shapes in tracked files"
echo "=================================================================="

# Deliberately specific. Each pattern is a credential format used by this
# project, so a hit is almost certainly real rather than a guess.
#
#   tskey-      Tailscale auth key (ADR-0006)
#   hcloud      Hetzner tokens are 64 hex chars, too generic to match alone, so
#               only the assignment form is flagged
#   AGE-SECRET-KEY  the bootstrap secret itself (ADR-0003)
#   PRIVATE KEY block  any SSH or TLS private key
PATTERNS=(
  'AGE-SECRET-KEY-1'
  'tskey-auth-[A-Za-z0-9]'
  'BEGIN [A-Z ]*PRIVATE KEY'
  'hcloud_token[[:space:]]*=[[:space:]]*"[A-Za-z0-9]{40,}"'
  'aws_secret_access_key[[:space:]]*=[[:space:]]*"[A-Za-z0-9/+]{30,}"'
)

for pat in "${PATTERNS[@]}"; do
  # Exclude this script, which necessarily contains the patterns it looks for.
  hits="$(git grep -nE "$pat" -- ':!infra/scripts/check-secrets.sh' 2>/dev/null | head -5)"
  printf '  %-46s ' "${pat:0:44}"
  if [ -n "$hits" ]; then
    echo "FOUND"
    echo "$hits" | sed 's/^/      /'
    FAILED=1
  else
    echo "clean"
  fi
done

echo
if [ "$FAILED" -ne 0 ]; then
  echo "SECRET CHECK FAILED."
  echo
  echo "If a real credential was committed, rewriting history is NOT sufficient:"
  echo "this repository is public, so treat it as disclosed and rotate it."
  echo
  echo "To encrypt a secrets file properly:"
  echo "  SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --encrypt --in-place <file>"
  exit 1
fi
echo "No unencrypted secrets found."
