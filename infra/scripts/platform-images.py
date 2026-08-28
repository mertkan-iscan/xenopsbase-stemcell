#!/usr/bin/env python3
"""Every off-the-shelf container image the platform manifests declare (T-6.8, #329).

WHY THIS IS DERIVED RATHER THAN LISTED

security.yml scanned two images, named in the workflow:

    matrix:
      service: [core, gateway]

That is the right check for what this repository BUILDS. It said nothing about
what this repository RUNS. T-3.24 added curlimages/curl as an initContainer in
every application pod, and nothing scanned it -- so the image with the widest
pod count in the cluster was the one image nobody looked at.

Extending that list by hand would have restated the same weakness: add a third
image in a year and the matrix still passes, having scanned what it was told
about rather than what is deployed. A list nobody is forced to update is a list
that goes stale silently, which is the shape of failure this repository keeps
finding.

So the list comes from the manifests. An image the cluster runs cannot fall out
of the scan without someone deleting it from the tree.

WHAT IS IN SCOPE

Container images written into platform/ manifests, EXCLUDING this project's own
images. Those are resolved by name from the `images:` block in the services
kustomization, they gate a release, and security.yml already scans them -- see
its `image` job.

WHAT IS NOT, AND WHY IT CANNOT BE

Images pulled by the Helm-sourced Applications -- cert-manager, ingress-nginx,
kube-prometheus-stack, loki, tempo, alloy, cloudnative-pg -- are not referenced
anywhere in this repository. The chart decides them at render time. Nothing that
reads this tree can enumerate them, and a scan that quietly covered a smaller
set than its name suggests is worse than one that states its boundary. Covering
those means asking the CLUSTER what it is running rather than asking the repo
what it declares, which is T-6.2.

AN IMAGE WITHOUT A DIGEST IS SCANNED ANYWAY, AND SAID OUT LOUD

A tag moves. Scanning `keycloak:26.7.1` describes whatever that tag meant at scan
time, which is not necessarily what the kubelet pulled. That is weaker than a
digest and it is not nothing, so such images are scanned and flagged rather than
skipped or treated as an error.

Not an error, deliberately. Four of the six images here are tag-pinned today:
cloudflared, cloudnative-pg's postgresql, keycloak and tempo. Failing on them
would make this job red from its first run for reasons predating it, and
security.yml says at the top why that is self-defeating -- "a check that always
fails is one people learn to skip", which this repository has now met three
times. Pinning them is real work with an upgrade story attached -- each needs a rule
for when its digest moves -- so it is T-6.9 (#330) rather than something
smuggled into the change that noticed it.

Skipping them was the other option and is worse: an image would leave the scan
silently, which is the failure this whole script exists to prevent.

Usage:
    ./platform-images.py            # JSON array, one object per image
    ./platform-images.py --matrix   # {"include": [...]}, for a GitHub Actions matrix
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLATFORM = ROOT / "platform"

# This project's own images, scanned by security.yml's `image` job.
OWN_REGISTRY_PREFIX = "ghcr.io/mertkan-iscan/xenopsbase-stemcell/"

# `image:` as a YAML key, not the word appearing in prose. Anchored to the key
# so a comment mentioning an image does not become a scan target.
#
# The reference stops at whitespace or `#`, NOT at end of line. Anchoring to the
# line end was the first version and it silently missed both digest-pinned
# images -- the only two this card was raised about -- because each carries a
# trailing version comment:
#
#   image: valkey/valkey@sha256:e706d121…  # 8.1.4-alpine
#
# It reported four images, all tag-pinned, and looked entirely plausible.
IMAGE_KEY = re.compile(r"^\s*(?:-\s+)?image:\s*(?P<ref>[^\s#]+)", re.MULTILINE)

DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")


def discover():
    found = {}

    for path in sorted(PLATFORM.rglob("*.yaml")) + sorted(PLATFORM.rglob("*.yml")):
        text = path.read_text(encoding="utf-8")
        for match in IMAGE_KEY.finditer(text):
            ref = match.group("ref").strip("\"'")

            if ref.startswith(OWN_REGISTRY_PREFIX):
                continue

            pinned = bool(DIGEST.search(ref))

            # The last path segment, which is what a human calls it: curl,
            # valkey, keycloak. Used for the SARIF category and the artefact
            # name, so it has to be stable and filesystem-safe.
            repo = ref.split("@", 1)[0]
            last = repo.rsplit("/", 1)[-1]
            name = last.split(":", 1)[0]

            entry = found.setdefault(
                ref, {"name": name, "ref": ref, "pinned": pinned, "declared_in": []}
            )
            where = path.relative_to(ROOT).as_posix()
            if where not in entry["declared_in"]:
                entry["declared_in"].append(where)

    if not found:
        # Never pass by finding nothing. If the manifests stop declaring any
        # off-the-shelf image, that is a change worth failing on rather than a
        # green tick over an empty set.
        print(
            "error: no off-the-shelf image found under platform/ - the pattern "
            "that finds them has probably stopped matching.",
            file=sys.stderr,
        )
        sys.exit(1)

    images = sorted(found.values(), key=lambda i: i["ref"])

    # Two images could share a last path segment and then collide as a SARIF
    # category, which silently overwrites one set of findings with another.
    # Cheap to make impossible rather than to remember.
    seen = {}
    for image in images:
        base = image["name"]
        seen[base] = seen.get(base, 0) + 1
        if seen[base] > 1:
            image["name"] = "%s-%d" % (base, seen[base])

    return images


def main():
    images = discover()
    if "--matrix" in sys.argv[1:]:
        # declared_in flattened to a string: a matrix include carrying a list
        # is awkward to reference from a workflow expression, and this value is
        # only ever printed.
        entries = [dict(i, declared_in=", ".join(i["declared_in"])) for i in images]
        print(json.dumps({"include": entries}))
    else:
        print(json.dumps(images, indent=2))


if __name__ == "__main__":
    main()
