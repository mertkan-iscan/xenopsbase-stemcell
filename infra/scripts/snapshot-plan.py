#!/usr/bin/env python3
"""Decide which snapshots may be deleted (T-1.21, #253).

Separated from prune-snapshots.sh so the decision can be tested without an
account, without a network, and without the possibility of deleting anything.

A retention policy whose delete path has never run is one you find out about
when it removes the wrong image -- on a cold rebuild, which is precisely when
nobody wants to discover it. `--self-test` runs the cases below.

WHAT IS NEVER A CANDIDATE, AND WHY EACH IS CHECKED RATHER THAN ASSUMED

  in use      a running server booted from it. Read from the servers, not from
              terraform config: config says what should be true, the server
              says what is, and on a cold rebuild they differ for minutes.
  newest      there must always be something to boot, whatever an age rule says.
  base        golden images are built ON TOP of the base snapshot. Deleting one
              breaks `make golden-image` rather than `make up` -- a slower and
              more confusing failure.
  unlabelled  not created by this project. A retention policy that reaches
              outside what it made is one that eventually deletes something it
              should never have seen.

Usage:
  snapshot-plan.py            reads IMAGES and SERVERS from the environment
  snapshot-plan.py --self-test
"""

import json
import os
import sys


def plan(images, servers, keep):
    """Returns (decisions, delete_ids). A decision is (action, image, reason)."""
    in_use = set()
    for s in servers:
        image = s.get("image") or {}
        if image.get("id"):
            in_use.add(image["id"])

    def labels(i):
        return i.get("labels") or {}

    golden = [i for i in images if labels(i).get("xenopsbase-golden") == "yes"]
    base = [i for i in images if labels(i).get("leapmicro-snapshot") == "yes"]
    known = {i["id"] for i in golden} | {i["id"] for i in base}
    other = [i for i in images if i["id"] not in known]

    golden.sort(key=lambda i: i["created"], reverse=True)

    decisions = []
    for i in base:
        decisions.append(("KEEP", i, "base image — golden images are built from it"))
    for i in other:
        decisions.append(("SKIP", i, "not labelled by this project — not ours to delete"))

    for rank, i in enumerate(golden):
        if i["id"] in in_use:
            decisions.append(("KEEP", i, "a running server is booted from it"))
        elif rank == 0:
            decisions.append(("KEEP", i, "newest golden — there must always be one to boot"))
        elif rank < keep:
            decisions.append(("KEEP", i, "within the newest %d" % keep))
        else:
            decisions.append(("DELETE", i, "older than the newest %d, nothing boots from it" % keep))

    # Belt and braces. If the labelling scheme ever changes, an image a server
    # is actually running must still not be deleted merely because this script
    # stopped recognising it.
    for i in images:
        if i["id"] in in_use and not any(d[1]["id"] == i["id"] for d in decisions):
            decisions.append(("KEEP", i, "a running server is booted from it"))

    return decisions, [i["id"] for a, i, _ in decisions if a == "DELETE"]


def _self_test():
    def img(i, created, **labels):
        return {"id": i, "created": created, "description": "img-%d" % i,
                "image_size": 1.5, "labels": labels}

    def golden(i, created):
        return img(i, created, **{"xenopsbase-golden": "yes"})

    cases = []

    # Growth beyond the keep count is the whole point.
    cases.append((
        "old goldens are deleted", [4],
        [golden(1, "2026-08-01"), golden(2, "2026-08-02"),
         golden(3, "2026-08-03"), golden(4, "2026-07-01")], [], 3))

    # Every one of these has a specific way of going wrong.
    cases.append((
        "the newest is never deleted", [],
        [golden(1, "2026-08-01")], [], 0))
    cases.append((
        "an in-use golden is never deleted, however old", [],
        [golden(1, "2026-08-05"), golden(2, "2020-01-01")],
        [{"image": {"id": 2}}], 1))
    cases.append((
        "the base image is never deleted", [],
        [img(9, "2020-01-01", **{"leapmicro-snapshot": "yes"})], [], 0))
    cases.append((
        "unlabelled snapshots are never touched", [],
        [img(7, "2019-01-01")], [], 0))

    # An image a server runs but this script no longer recognises. If the
    # labels are ever renamed, the policy must fail safe.
    cases.append((
        "an unrecognised but running image is kept", [],
        [img(5, "2019-01-01", some_other_scheme="yes")],
        [{"image": {"id": 5}}], 0))

    # Mixed: base + running golden + spares + a stranger.
    cases.append((
        "a realistic account", [11],
        [img(99, "2026-01-01", **{"leapmicro-snapshot": "yes"}),
         golden(13, "2026-08-13"), golden(12, "2026-08-12"),
         golden(11, "2026-08-11"), golden(10, "2026-08-10"),
         img(50, "2026-02-02")],
        [{"image": {"id": 10}}], 2))

    failures = 0
    for name, expected, images, servers, keep in cases:
        _, got = plan(images, servers, keep)
        ok = sorted(got) == sorted(expected)
        print("  %s %-46s delete=%s expected=%s"
              % ("ok  " if ok else "FAIL", name, sorted(got), sorted(expected)))
        if not ok:
            failures += 1

    print("")
    if failures:
        print("%d of %d self-tests FAILED" % (failures, len(cases)))
        return 1
    print("all %d self-tests passed" % len(cases))
    return 0


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        return _self_test()

    images = json.loads(os.environ["IMAGES"])["images"]
    servers = json.loads(os.environ["SERVERS"])["servers"]
    keep = int(os.environ.get("KEEP", "3"))

    decisions, to_delete = plan(images, servers, keep)
    in_use = sorted({(s.get("image") or {}).get("id") for s in servers
                     if (s.get("image") or {}).get("id")})

    print(json.dumps({
        "delete": to_delete,
        "in_use": in_use,
        "total_gb": round(sum(i.get("image_size") or 0.0 for i in images), 2),
        "lines": [
            "%-7s %-11s %-34s %5.1fGB  %s" % (
                a, i["id"], (i.get("description") or "")[:34],
                i.get("image_size") or 0.0, r)
            for a, i, r in sorted(decisions, key=lambda d: (d[0], d[1]["created"]))
        ],
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
