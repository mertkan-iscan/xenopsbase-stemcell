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
kube-prometheus-stack, loki, alloy, cloudnative-pg -- are not referenced
anywhere in this repository. The chart decides them at render time. Nothing that
reads this tree can enumerate them, and a scan that quietly covered a smaller
set than its name suggests is worse than one that states its boundary. Covering
those means asking the CLUSTER what it is running rather than asking the repo
what it declares, which is T-6.2.

(Tempo is NOT in that list, though a reader would expect it to be: Grafana's
Tempo charts are deprecated, so platform/envs/dev/observability/tempo.yaml is
written out here and its image is therefore in scope. Its header says why.)

A REMOTE KUSTOMIZE BASE IS THE SAME BOUNDARY, less obviously (T-6.9, #330).
platform/components/keycloak-operator/kustomization.yaml pulls the operator's own
release kustomization by ref, and that manifest -- not this tree -- names
quay.io/keycloak/keycloak-operator. The cluster runs it; nothing here reads it.
It is out of scope for the same reason a chart is, and is worth naming because
the keycloak IMAGE is in the list directly above it, which makes it easy to read
the operator as covered too.

AN IMAGE WITHOUT A DIGEST IS NOW AN ERROR (T-6.9, #330)

A tag moves. Scanning `keycloak:26.7.1` describes whatever that tag meant at scan
time, which is not necessarily what the kubelet pulled -- and with
`imagePullPolicy: IfNotPresent`, two nodes can hold two different builds of one
tag with nothing reporting the difference.

The first version of this script scanned such images and flagged them rather than
failing, because four of the six were tag-pinned on the day it was written:
cloudflared, cloudnative-pg's postgresql, keycloak and tempo. Failing then would
have made the job red from its first run for reasons predating it, and
security.yml says at the top why that is self-defeating -- "a check that always
fails is one people learn to skip", which this repository had already met three
times.

T-6.9 pinned those four, each with the rule for when its digest moves written at
the pin. So the condition that made a warning the honest answer is gone, and a
warning is now the weaker choice: every image here is pinned, and the way that
stops being true is somebody adding a fifth manifest without one. That is exactly
the case a warning would let through. It fails instead.

Failing HERE rather than in the scan job is deliberate. The scan gates on findings
against a digest, one image at a time; this gates on the SHAPE of the list, before
any of it is scanned, so an unpinned image never becomes a matrix entry that looks
scanned. The remedy is in the error message, because a gate whose fix has to be
inferred is one that gets bypassed.

Skipping unpinned images was the other option and remains the worst: an image
would leave the scan silently, which is the failure this whole script exists to
prevent.

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

    # Every image the platform declares must name one artefact. See the module
    # docstring for why this became an error once T-6.9 had pinned the four that
    # were not. The message carries the remedy: the reader is somebody who just
    # added a manifest, not somebody who knows this file.
    unpinned = [i for i in images if not i["pinned"]]
    if unpinned:
        print(
            "error: %d image(s) declared under platform/ without a digest. A tag "
            "does not name one artefact, so it cannot be scanned as what the "
            "kubelet actually pulled:" % len(unpinned),
            file=sys.stderr,
        )
        for image in unpinned:
            print(
                "  %s\n      declared in: %s"
                % (image["ref"], ", ".join(image["declared_in"])),
                file=sys.stderr,
            )
        print(
            "\nResolve each with:\n"
            "  docker buildx imagetools inspect <ref>\n"
            "and pin the INDEX digest, keeping the tag in a trailing comment, as\n"
            "platform/envs/dev/cache/valkey.yaml does. Write down at the pin when\n"
            "that digest is allowed to move -- T-6.9 (#330) did this for the four\n"
            "images that were tag-pinned, and each rule is at its own pin.",
            file=sys.stderr,
        )
        sys.exit(1)

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
