#!/usr/bin/env bash
#
# Renders the realm Keycloak imports locally FROM THE FILE THE CLUSTER USES
# (T-4.1).
#
# WHY NOT JUST COMMIT A LOCAL REALM
#
# Because it would drift, and it would drift silently. Local login would keep
# working against a realm nobody deploys, and the first sign would be a change
# that works on a laptop and fails in dev -- which is the specific failure a
# local stack is supposed to remove, not introduce. T-4.2 makes the same
# argument for the Testcontainers harness, and this is the same file.
#
# The only substitution is ${GATEWAY_CLIENT_SECRET}: a SOPS placeholder in the
# committed realm, with no value outside the cluster. Locally it is a literal,
# and that is fine for the same reason the dev realm's passwords are published
# (#149) -- this listens on localhost and holds nothing.
#
# yq runs in a container rather than being required on the machine. The whole
# point of this card is "under five minutes from clone", and that budget does
# not survive "first install these four tools".
#
# Read-only with respect to the repository, apart from the generated file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/platform/envs/dev/keycloak/realm-import.yaml"
OUT_DIR="$ROOT/infra/dev/.generated"
OUT="$OUT_DIR/realm.json"

# Matches the value the local compose stack hands the gateway. It is not a
# secret and is not the deployed one.
LOCAL_CLIENT_SECRET="local-dev-gateway-secret"

command -v docker >/dev/null 2>&1 || {
  echo "error: docker is required (it is the only thing this stack needs)." >&2
  exit 1
}

[ -f "$SOURCE" ] || {
  echo "error: $SOURCE is missing." >&2
  exit 1
}

mkdir -p "$OUT_DIR"

# `.spec.realm` is the realm representation inside the KeycloakRealmImport CR.
# Keycloak's --import-realm wants that object alone, as JSON.
docker run --rm -i mikefarah/yq:4 -o=json '.spec.realm' < "$SOURCE" > "$OUT.tmp"

# Substituted here rather than by Keycloak. Its realm import does not expand
# shell-style placeholders, so leaving it would create a client whose secret is
# the literal string "${GATEWAY_CLIENT_SECRET}" -- which works right up until
# the gateway tries to authenticate and fails with something unrelated-looking.
sed "s|\${GATEWAY_CLIENT_SECRET}|$LOCAL_CLIENT_SECRET|g" "$OUT.tmp" > "$OUT.subst"
rm -f "$OUT.tmp"

# THE ONE PLACE LOCALHOST HAS TO BE ADDED, and it cannot be avoided.
#
# The committed realm trusts exactly one callback, deliberately and with a
# comment saying a wildcard redirect URI turns the authorization code flow into
# an open redirect:
#
#   redirectUris: [https://app-dev.xenopsoftware.com/login/oauth2/code/oidc]
#
# A gateway on localhost:8080 is not that, so Keycloak answers the local login
# with "Invalid parameter: redirect_uri" -- correctly. The URLs are APPENDED
# rather than replaced, so the deployed callback stays in the local realm too and
# this file cannot become a way to loosen the deployed one: it only ever adds to
# a copy that never leaves the machine.
docker run --rm -i mikefarah/yq:4 -o=json '
  (.clients[] | select(.clientId == "gateway") | .redirectUris) += ["http://localhost:8080/login/oauth2/code/oidc"] |
  (.clients[] | select(.clientId == "gateway") | .webOrigins) += ["http://localhost:8080"] |
  (.clients[] | select(.clientId == "gateway") | .attributes."post.logout.redirect.uris") += "##http://localhost:8080"
' < "$OUT.subst" > "$OUT"
rm -f "$OUT.subst"

REALM_NAME="$(docker run --rm -i mikefarah/yq:4 -o=json '.realm' < "$OUT" | tr -d '"')"
USERS="$(docker run --rm -i mikefarah/yq:4 '.users | length' < "$OUT")"

echo "wrote $OUT"
echo "  realm : $REALM_NAME"
echo "  users : $USERS (from the deployed realm, so local identity matches dev)"
