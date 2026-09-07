"""Assert every realm-import manifest fits the columns Keycloak stores it in.

Driven by verify-realm-limits.sh, which carries the reasoning. The limits below
are Keycloak's own schema, not a house style: exceeding one crashes the import
job rather than truncating, and a crashed import cannot recreate a realm that was
deleted in order to apply the change.
"""

import glob
import sys

import yaml

# column -> (path description, maximum). Only the ones this repository actually
# writes; add a row when a manifest starts using a new field, rather than
# guessing at Keycloak's whole schema.
LIMITS = {
    "realm role description": 255,
    "client role description": 255,
    "client description": 255,
    "client name": 255,
    "username": 255,
    "group name": 255,
}


def check(path):
    problems = []
    with open(path, encoding="utf-8") as handle:
        document = yaml.safe_load(handle)

    realm = (document or {}).get("spec", {}).get("realm")
    if not realm:
        return problems, 0

    checked = 0

    def measure(kind, label, value):
        nonlocal checked
        if not isinstance(value, str):
            return
        checked += 1
        limit = LIMITS[kind]
        if len(value) > limit:
            problems.append(
                f"{path}: {kind} for {label!r} is {len(value)} characters, limit {limit}"
            )

    for role in realm.get("roles", {}).get("realm", []) or []:
        measure("realm role description", role.get("name"), role.get("description"))

    for client_id, roles in (realm.get("roles", {}).get("client", {}) or {}).items():
        for role in roles or []:
            measure("client role description", f"{client_id}:{role.get('name')}", role.get("description"))

    for client in realm.get("clients", []) or []:
        measure("client description", client.get("clientId"), client.get("description"))
        measure("client name", client.get("clientId"), client.get("name"))

    for user in realm.get("users", []) or []:
        measure("username", user.get("username"), user.get("username"))

    for group in realm.get("groups", []) or []:
        measure("group name", group.get("name"), group.get("name"))

    return problems, checked


def main():
    paths = sorted(glob.glob("platform/envs/*/keycloak/*realm-import*.yaml"))
    if not paths:
        # Never pass by finding nothing to check.
        print("  no realm-import manifests found — this check has stopped checking anything")
        return 1

    all_problems = []
    for path in paths:
        problems, checked = check(path)
        status = "FAIL" if problems else "ok"
        print(f"  {status:4}  {path}  ({checked} field(s))")
        all_problems.extend(problems)

    for problem in all_problems:
        print(f"    {problem}")
    return 1 if all_problems else 0


if __name__ == "__main__":
    sys.exit(main())
