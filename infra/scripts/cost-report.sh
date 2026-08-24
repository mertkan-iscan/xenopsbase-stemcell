#!/usr/bin/env bash
#
# What the Hetzner project is costing right now, priced from the API (T-8.4, #22... #62).
#
# WHY THIS READS THE ACCOUNT RATHER THAN QUOTING A FIGURE
#
# ADR-0002's whole argument is "near zero when idle". That is a claim about a
# bill, and until now nothing in this repository could check it. A number
# written into the README instead would be right on the day it was written and
# silently wrong afterwards -- server types change price, the sizing changes,
# and a volume that outlives its cluster does not announce itself.
#
# So this prices what actually exists, using Hetzner's own pricing endpoint
# rather than constants. If Hetzner changes a price, this changes with it.
#
# WHAT IT IS FOR
#
#   - the running cost of a cluster somebody left up
#   - the IDLE cost, which should be almost nothing and is the number that
#     proves or disproves the architecture
#   - orphans: volumes, load balancers and IPs with no server, which are what
#     a failed teardown leaves behind and what nobody notices for a month
#
# Usage:
#   source ~/.xenopsbase.env && ./cost-report.sh
#   ./cost-report.sh --json      machine-readable, for the scheduled check
#
set -uo pipefail

: "${HCLOUD_TOKEN:?HCLOUD_TOKEN is not set — run: source ~/.xenopsbase.env}"

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

api() {
  curl -sS -H "Authorization: Bearer ${HCLOUD_TOKEN}" "https://api.hetzner.cloud/v1/$1"
}

PRICING="$(api pricing)"
SERVERS="$(api 'servers?per_page=100')"
VOLUMES="$(api 'volumes?per_page=100')"
LBS="$(api 'load_balancers?per_page=100')"
IMAGES="$(api 'images?type=snapshot&per_page=100')"
IPS="$(api 'primary_ips?per_page=100')"

export PRICING SERVERS VOLUMES LBS IMAGES IPS JSON

# python3 on Linux, python on Windows -- resolved by RUNNING each candidate,
# because Windows ships a `python3` App Execution Alias that exists on PATH and
# then exits 49 printing an advert for the Microsoft Store.
PY_BIN="$(python3 -c '' >/dev/null 2>&1 && echo python3 || echo python)"

"$PY_BIN" - <<'PY'
import json, os, sys

def load(name):
    raw = os.environ[name]
    try:
        return json.loads(raw)
    except Exception:
        sys.exit("could not parse the %s response — is HCLOUD_TOKEN valid?" % name)

import datetime

pricing = load("PRICING")["pricing"]
servers = load("SERVERS")["servers"]
volumes = load("VOLUMES")["volumes"]
lbs     = load("LBS")["load_balancers"]
images  = load("IMAGES")["images"]
ips     = load("IPS").get("primary_ips", [])

def gross(node):
    # The API returns {"net": ..., "gross": ...}. Gross is what is actually
    # charged, and quoting net would understate the bill by the VAT rate --
    # which is exactly the kind of quietly-wrong number this script exists to
    # replace.
    return float(node["gross"]) if isinstance(node, dict) else float(node)

def server_hourly(server_type_name, location):
    for st in pricing.get("server_types", []):
        if st["name"] == server_type_name:
            for pr in st["prices"]:
                if pr["location"] == location:
                    return gross(pr["price_hourly"])
    return 0.0

def lb_hourly(lb_type_name, location):
    for lt in pricing.get("load_balancer_types", []):
        if lt["name"] == lb_type_name:
            for pr in lt["prices"]:
                if pr["location"] == location:
                    return gross(pr["price_monthly"]) / 730.0
    return 0.0

def ip_hourly(location):
    for ip in pricing.get("primary_ips", []):
        if ip["type"] == "ipv4":
            for pr in ip["prices"]:
                if pr["location"] == location:
                    return gross(pr["price_hourly"])
    return 0.0

volume_gb_month = gross(pricing["volume"]["price_per_gb_month"])
image_gb_month  = gross(pricing["image"]["price_per_gb_month"])

lines = []
running = 0.0   # goes away on `make down`
idle    = 0.0   # survives it, by design (ADR-0008)

def location_of(obj, default="fsn1"):
    """Hetzner returns `location` directly on some resources and nested under
    `datacenter` on others, and which one has changed between API revisions.
    Guessing wrong prices the resource at 0 and understates the bill silently,
    so both shapes are handled rather than one being assumed."""
    loc = obj.get("location")
    if isinstance(loc, dict) and loc.get("name"):
        return loc["name"]
    dc = obj.get("datacenter") or {}
    loc = dc.get("location") or {}
    return loc.get("name") or default


# How long the oldest server has existed. This is what turns a cost report
# into a guardrail: a cluster that is up during a working session is expected,
# and one that has been up for eighteen hours was forgotten. Without an age the
# only available alert is "a cluster exists", which is true most working days
# and is therefore ignored within a week.
now = datetime.datetime.now(datetime.timezone.utc)
oldest_hours = 0.0
for s in servers:
    created = datetime.datetime.fromisoformat(s["created"])
    oldest_hours = max(oldest_hours, (now - created).total_seconds() / 3600.0)

for s in servers:
    loc = location_of(s)
    h = server_hourly(s["server_type"]["name"], loc)
    running += h
    lines.append(("server", s["name"], "%s @ %s" % (s["server_type"]["name"], loc), h))

for lb in lbs:
    loc = location_of(lb)
    h = lb_hourly(lb["load_balancer_type"]["name"], loc)
    running += h
    lines.append(("load balancer", lb["name"], lb["load_balancer_type"]["name"], h))

for ip in ips:
    if ip.get("type") != "ipv4":
        continue
    loc = location_of(ip)
    h = ip_hourly(loc)
    attached = ip.get("assignee_id") is not None
    running += h
    lines.append(("primary ip", ip["name"], "attached" if attached else "UNATTACHED", h))

for v in volumes:
    h = (v["size"] * volume_gb_month) / 730.0
    attached = v.get("server") is not None
    running += h
    lines.append(("volume", v["name"], "%dGB %s" % (v["size"], "attached" if attached else "UNATTACHED"), h))

for im in images:
    size = im.get("image_size") or im.get("disk_size") or 0
    h = (float(size) * image_gb_month) / 730.0
    idle += h
    lines.append(("snapshot", im.get("description") or str(im["id"]), "%.1fGB" % float(size), h))

total = running + idle

# Orphans: the failure mode of a teardown that half-worked. verify-teardown.sh
# checks these immediately after `make down`; this catches the ones that appear
# later, or that a teardown nobody ran never checked at all.
orphans = [l for l in lines if "UNATTACHED" in l[2]]

if os.environ.get("JSON") == "1":
    print(json.dumps({
        "hourly_total": round(total, 5),
        "hourly_running": round(running, 5),
        "hourly_idle": round(idle, 5),
        "daily_total": round(total * 24, 4),
        "monthly_if_left_up": round(total * 730, 2),
        "servers": len(servers),
        "oldest_server_hours": round(oldest_hours, 2),
        "spent_so_far": round(running * oldest_hours, 2),
        "orphans": [{"kind": k, "name": n, "detail": d} for k, n, d, _ in orphans],
    }, indent=2))
    sys.exit(0)

unpriced = [l for l in lines if l[3] == 0.0 and l[0] != "snapshot"]

print("=" * 66)
print(" Hetzner project — what it costs right now")
print("=" * 66)
if not lines:
    print("  nothing billable exists.")
for kind, name, detail, h in sorted(lines, key=lambda x: -x[3]):
    print("  %-14s %-28s %-22s € %.5f/h" % (kind, name[:28], detail, h))
print("")
print("  %-46s € %.4f/h" % ("running (goes away on `make down`)", running))
print("  %-46s € %.4f/h" % ("idle (survives it, by design — ADR-0008)", idle))
print("  " + "-" * 62)
print("  %-46s € %.4f/h" % ("total", total))
print("  %-46s € %.2f" % ("per day, if left up", total * 24))
print("  %-46s € %.2f" % ("per 30 days, if left up", total * 24 * 30))
if servers:
    print("")
    print("  %-46s %.1f h" % ("oldest server has been up for", oldest_hours))
    print("  %-46s € %.2f" % ("spent on the running half so far", running * oldest_hours))
print("")
if unpriced:
    # A price of zero is almost never true and is what a changed API shape looks
    # like. Reporting a total that quietly omits a server is worse than failing.
    print("  WARNING — priced at zero, which usually means a lookup failed:")
    for kind, name, detail, _ in unpriced:
        print("    %s %s (%s)" % (kind, name, detail))
    print("")

if orphans:
    print("  ORPHANS — billable and attached to nothing:")
    for kind, name, detail, h in orphans:
        print("    %s %s (%s) € %.5f/h" % (kind, name, detail, h))
    print("")
    print("  These are what a failed teardown leaves behind. `make down` runs")
    print("  verify-teardown.sh, which would have caught them at the time.")
    sys.exit(1)
PY
