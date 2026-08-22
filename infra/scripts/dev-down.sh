#!/usr/bin/env bash
#
# Stops what dev-up.sh started (T-4.1).
#
# Removes volumes as well as containers. The local stack is disposable by
# design -- the realm is regenerated from the deployed file on every `dev-up`
# and the database holds nothing anyone should mind losing -- and a stack that
# accumulates state between runs stops being a clean starting point, which is
# the thing this card is actually buying.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV="$ROOT/infra/dev"
LOGS="$DEV/.logs"

for name in gateway core; do
  PIDFILE="$LOGS/$name.pid"
  [ -f "$PIDFILE" ] || continue
  PID="$(cat "$PIDFILE")"
  if kill -0 "$PID" 2>/dev/null; then
    # The Maven wrapper forks the application, so killing the recorded pid alone
    # can leave the JVM holding the port -- which then reads as "already
    # running" on the next dev-up. Take the process group where the shell
    # supports it, and fall back to the pid.
    kill -- "-$PID" 2>/dev/null || kill "$PID" 2>/dev/null
    echo "stopped $name (pid $PID)"
  fi
  rm -f "$PIDFILE"
done

# Anything still holding the service ports, whichever way it was started.
#
# THIS NEEDS THREE IMPLEMENTATIONS, and the first version had one. `lsof` does
# not exist on Windows, so on the machine this was written on the whole block
# was a silent no-op: the previous stack kept running, `dev-up` saw a healthy
# port and skipped starting a new process, and the "restarted" services were
# still the old ones with the old environment. That cost an hour of chasing a
# config change that had been applied to a process nobody had restarted.
#
# A cleanup step that cannot fail is a cleanup step that cannot be trusted, so
# this reports what it could not release rather than exiting quietly.
release_port() {
  local port="$1" released=0
  if command -v lsof >/dev/null 2>&1; then
    for p in $(lsof -ti ":$port" 2>/dev/null); do
      kill "$p" 2>/dev/null && { echo "released port $port (pid $p)"; released=1; }
    done
  elif command -v powershell.exe >/dev/null 2>&1; then
    # Windows. netstat's output format shifts between locales; Get-NetTCPConnection
    # returns the owning pid as data rather than as text to be parsed.
    local out
    out="$(powershell.exe -NoProfile -Command "
      Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
      ForEach-Object { \$_.OwningProcess } | Sort-Object -Unique" 2>/dev/null | tr -d '\r')"
    for p in $out; do
      powershell.exe -NoProfile -Command "Stop-Process -Id $p -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 \
        && { echo "released port $port (pid $p)"; released=1; }
    done
  elif command -v ss >/dev/null 2>&1; then
    for p in $(ss -lptn "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
      kill "$p" 2>/dev/null && { echo "released port $port (pid $p)"; released=1; }
    done
  else
    echo "warning: no lsof, powershell or ss - cannot check port $port"
    return 0
  fi
  return 0
}

for port in 8080 8081; do release_port "$port"; done

# Verified, not assumed. If something still holds a port, the next dev-up will
# quietly reuse it and every change made since will appear not to have applied.
sleep 1
for port in 8080 8081; do
  if curl -sf -o /dev/null --max-time 2 "http://localhost:$port/management/health" 2>/dev/null; then
    echo "WARNING: something is still serving on $port. `make dev-up` will reuse it"
    echo "         rather than starting a fresh process, and config changes will"
    echo "         look like they did nothing. Stop it before continuing."
  fi
done

docker compose -f "$DEV/compose.yml" down -v 2>&1 | sed 's/^/  /'

echo "local stack down."
