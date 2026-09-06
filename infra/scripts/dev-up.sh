#!/usr/bin/env bash
#
# One command from clone to a working stack (T-4.1).
#
# Dependencies in containers, services from Maven. The split matters: a code
# change has to be running in seconds, and spring-boot-devtools restarts a
# changed class in about one. Putting the services in the compose file would
# make every edit a container rebuild and quietly cost the card its second
# acceptance criterion.
#
# Only Docker and a JDK are required, and the JDK is located by java-home.sh
# rather than assumed. No Hetzner resources, no cluster, no credentials.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV="$ROOT/infra/dev"
LOGS="$DEV/.logs"
COMPOSE=(docker compose -f "$DEV/compose.yml")

START="$(date +%s)"

command -v docker >/dev/null 2>&1 || { echo "error: docker is required." >&2; exit 1; }
docker info >/dev/null 2>&1 || {
  echo "error: the Docker daemon is not running." >&2
  echo "       start Docker Desktop, or the engine on Linux, then re-run." >&2
  exit 1
}

JH="$(bash "$ROOT/infra/scripts/java-home.sh")" || {
  echo "error: no usable JDK. See the output above." >&2
  exit 1
}

mkdir -p "$LOGS"

echo "=================================================================="
echo " Local stack"
echo "=================================================================="
echo

echo "1/5  realm"
bash "$ROOT/infra/scripts/dev-realm.sh" | sed 's/^/     /'

echo
echo "2/5  dependencies"
# --wait blocks on the healthchecks in compose.yml rather than on the container
# merely existing. Keycloak in particular accepts connections long before the
# realm import finishes, and starting the services against a half-imported realm
# fails as an issuer error that names nothing useful.
# Two calls. `--wait` counts the one-shot bucket creator's clean exit(0) as a
# failed service, so the wait lists only the four long-running dependencies.
"${COMPOSE[@]}" up -d 2>&1 | sed 's/^/     /'
"${COMPOSE[@]}" up -d --wait postgres keycloak minio valkey 2>&1 | sed 's/^/     /'
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  echo "     dependencies did not become healthy. Logs:"
  "${COMPOSE[@]}" ps | sed 's/^/       /'
  exit 1
fi

start_service() {
  local name="$1" dir="$2" port="$3"
  if curl -sf -o /dev/null "http://localhost:$port/management/health" 2>/dev/null; then
    echo "     $name already running on $port"
    return 0
  fi
  # shellcheck disable=SC2086
  ( cd "$ROOT/services" && \
    OIDC_ISSUER_URI=http://localhost:9080/realms/xenopsbase \
    OIDC_CLIENT_SECRET=local-dev-gateway-secret \
    CORE_URI=http://localhost:8081 \
    VALKEY_HOST=localhost \
    VALKEY_PASSWORD=localdev \
    DOCUMENTS_ENDPOINT=http://localhost:9000 \
    DOCUMENTS_BUCKET=xenopsbase-dev-documents \
    AWS_ACCESS_KEY_ID=localdevkey \
    AWS_SECRET_ACCESS_KEY=localdevsecret \
    AWS_REGION=us-east-1 \
    JAVA_HOME="$JH" \
    nohup ./mvnw -o -pl "$dir" spring-boot:run -Dspring-boot.run.profiles=dev > "$LOGS/$name.log" 2>&1 & \
    echo $! > "$LOGS/$name.pid" )
  echo "     $name starting (pid $(cat "$LOGS/$name.pid"), log $LOGS/$name.log)"
}

# The shared libraries first, ONCE, and installed rather than built in place
# (ADR-0017). The two services start in parallel, so `-am` on each would have
# two reactors writing platform-common/target at the same time -- which fails
# intermittently and looks like a flaky service rather than a build race.
echo
echo "3/5  shared modules"
if ! ( cd "$ROOT/services" && JAVA_HOME="$JH" ./mvnw -q -o --batch-mode -DskipTests        install -pl platform-common,platform-common-web ); then
  echo "     FAILED to build the shared modules. The services cannot resolve them."
  echo "     Try: cd services && ./mvnw install -pl platform-common,platform-common-web"
  exit 1
fi
echo "     platform-common, platform-common-web installed"

echo
echo "4/5  services"
start_service core core 8081
start_service gateway gateway 8080

wait_for() {
  local name="$1" port="$2" deadline=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -sf -o /dev/null "http://localhost:$port/management/health" 2>/dev/null; then
      echo "     $name is up on $port"
      return 0
    fi
    # A service that has exited will never come up, and waiting the full three
    # minutes to say so wastes the time this card exists to save.
    if [ -f "$LOGS/$name.pid" ] && ! kill -0 "$(cat "$LOGS/$name.pid")" 2>/dev/null; then
      echo "     $name exited. Last lines of $LOGS/$name.log:"
      tail -15 "$LOGS/$name.log" | sed 's/^/       /'
      return 1
    fi
    sleep 3
  done
  echo "     $name did not answer within 180s. See $LOGS/$name.log"
  return 1
}

echo
echo "5/5  waiting"
FAIL=0
wait_for core 8081 || FAIL=1
wait_for gateway 8080 || FAIL=1

echo
if [ "$FAIL" -ne 0 ]; then
  echo "STACK INCOMPLETE after $(( $(date +%s) - START ))s. See the logs above."
  exit 1
fi

cat <<EOF
STACK UP in $(( $(date +%s) - START ))s

  application     http://localhost:8080
  core (direct)   http://localhost:8081
  keycloak        http://localhost:9080   admin / admin
  minio console   http://localhost:9001   localdevkey / localdevsecret

  sign in as      smoke / smoke-dev-only        (app-user)
                  smoke-admin / smoke-dev-only  (app-user, app-admin)

  logs            make dev-logs
  stop            make dev-down

Edit a class and save: devtools restarts the affected service in about a second.
EOF
