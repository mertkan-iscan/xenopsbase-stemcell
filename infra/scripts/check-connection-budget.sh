#!/usr/bin/env bash
#
# The application tier must not be able to demand more database connections
# than Postgres will accept (T-2.18, #259).
#
# WHY THIS EXISTS
#
# Three numbers decide whether the database survives a scale-up, and they live
# in three different files with nothing connecting them:
#
#   HPA maxReplicas          platform/envs/dev/services/hpa.yaml
#   Hikari maximum-pool-size services/core/.../application-prod.yml
#   max_connections          platform/envs/dev/database/cluster.yaml
#
# plus Keycloak's own pool, which had no value at all and therefore ran the
# Quarkus default of 100 -- on its own equal to every connection the database
# has.
#
# Before this check the arithmetic was:
#
#   core     3 x 20 =  60
#   keycloak        = 100   (defaulted, unbounded in config)
#   system          =  11   (measured)
#                     ---
#                     171   against max_connections 100
#
# It never failed, because the HPA had never scaled and neither pool had ever
# filled. **The relationship held by luck and reported nothing while it held.**
# That is the shape this repository keeps finding: T-2.8 set an HPA target
# against a request that made the arithmetic meaningless, T-2.13 published an
# RPO resting on a default nobody had pinned.
#
# WHAT THIS DOES NOT DO
#
# It does not measure. It reads the declared ceilings and adds them up, because
# the failure being prevented is a scale-up event that has not happened yet.
# Live usage is the wrong signal: it is low precisely until the moment it is
# not.
#
# Usage:
#   ./check-connection-budget.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

ENVIRONMENT="${1:-dev}"

PY_BIN="$(python3 -c '' >/dev/null 2>&1 && echo python3 || echo python)"

"$PY_BIN" - "$ENVIRONMENT" <<'PY'
import re
import sys
import yaml

env = sys.argv[1]
FAIL = []


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def docs(path):
    return [d for d in yaml.safe_load_all(read(path)) if d]


# --- max_connections -------------------------------------------------------
cluster = docs("platform/envs/%s/database/cluster.yaml" % env)[0]
params = cluster["spec"]["postgresql"]["parameters"]
max_connections = int(params["max_connections"])

# Postgres keeps these for superusers; applications cannot have them. Read from
# the cluster if it is set, otherwise the Postgres default.
reserved = int(params.get("superuser_reserved_connections", 3))

# CNPG's instance manager, streaming replication, and the barman plugin.
# Measured on the running cluster: 11 connections that are neither core nor
# keycloak. Held as a constant rather than queried, because this check must run
# in CI where there is no cluster to ask.
SYSTEM = 11

# --- core ------------------------------------------------------------------
hpas = docs("platform/envs/%s/services/hpa.yaml" % env)
core_max_replicas = next(
    h["spec"]["maxReplicas"] for h in hpas
    if h.get("kind") == "HorizontalPodAutoscaler" and h["metadata"]["name"] == "core"
)

core_conf = read("services/core/src/main/resources/config/application-prod.yml")
m = re.search(r"^\s*maximum-pool-size:\s*(\d+)", core_conf, re.M)
if not m:
    FAIL.append("could not find maximum-pool-size in core's application-prod.yml")
    core_pool = 0
else:
    core_pool = int(m.group(1))

# --- keycloak --------------------------------------------------------------
kc = docs("platform/envs/%s/keycloak/keycloak.yaml" % env)[0]
kc_instances = int(kc["spec"].get("instances", 1))
opts = {o["name"]: o["value"] for o in (kc["spec"].get("additionalOptions") or [])}

if "db-pool-max-size" not in opts:
    # The important case. An absent value is not "small", it is the Quarkus
    # default of 100 -- and an unpinned pool cannot be budgeted for at all.
    FAIL.append(
        "keycloak sets no db-pool-max-size, so it defaults to 100 — on its own "
        "equal to max_connections. Pin it in additionalOptions."
    )
    kc_pool = 100
else:
    kc_pool = int(opts["db-pool-max-size"])

# --- the arithmetic --------------------------------------------------------
core_total = core_max_replicas * core_pool
kc_total = kc_instances * kc_pool
demand = core_total + kc_total + SYSTEM + reserved

# 20% headroom. Not superstition: a rolling deploy runs old and new pods at the
# same time, so the real peak briefly exceeds maxReplicas x pool.
LIMIT = int(max_connections * 0.8)

print("=" * 66)
print(" Connection budget — %s" % env)
print("=" * 66)
print("  core       %d replicas x %-3d = %3d" % (core_max_replicas, core_pool, core_total))
print("  keycloak   %d instance%s x %-3d = %3d" % (
    kc_instances, "" if kc_instances == 1 else "s", kc_pool, kc_total))
print("  system, replication, CNPG = %3d" % SYSTEM)
print("  superuser reserved        = %3d" % reserved)
print("  " + "-" * 40)
print("  demand at full scale      = %3d" % demand)
print("  max_connections           = %3d" % max_connections)
print("  budget (80%%, for rollovers) = %3d" % LIMIT)
print("")

if demand > max_connections:
    FAIL.append(
        "demand %d EXCEEDS max_connections %d — a scale-up event will be refused "
        "connections" % (demand, max_connections))
elif demand > LIMIT:
    FAIL.append(
        "demand %d is over the %d budget. It fits, but a rolling deploy runs old "
        "and new pods together and would not." % (demand, LIMIT))

if FAIL:
    print("FAILED")
    for f in FAIL:
        print("  - %s" % f)
    print("")
    print("  Levers, cheapest first: lower Hikari maximum-pool-size, lower the")
    print("  HPA ceiling, pin Keycloak smaller. Raising max_connections is the")
    print("  expensive one — every connection is a backend process against")
    print("  shared_buffers, so it trades a refused connection for a slower")
    print("  database. A pooler is the real answer and is part of #259.")
    sys.exit(1)

print("PASSED — %d of %d, %d spare." % (demand, max_connections, max_connections - demand))
PY
