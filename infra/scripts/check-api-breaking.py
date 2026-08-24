#!/usr/bin/env python3
"""Classify OpenAPI changes as breaking or not (T-5.4, #43).

WHY NOT AN OFF-THE-SHELF DIFF TOOL

openapi-diff exists and is good. It is also another toolchain to install and
pin, and it answers a more general question than this repository asks. What is
needed here is narrow and stable: does this change break the consumers this
project actually has -- clients/java, generated from the committed spec, and a
browser front end going through the gateway?

The rules below are therefore deliberately short and deliberately conservative.
A rule that fires on something harmless teaches people to bypass the gate, and
a gate people bypass is worse than no gate -- which this repository has now met
several times.

WHAT COUNTS AS BREAKING, AND WHY EACH ONE

  removed path / operation    a call a consumer makes stops existing
  removed response code       a branch a consumer handles stops being reachable
                              -- and the client is generated with a typed
                              method per declared response
  new required request field  every existing caller is now sending an invalid
                              request, without changing anything
  removed response property   a field a consumer reads disappears
  narrowed type               a value a consumer parses no longer fits

WHAT IS EXPLICITLY NOT BREAKING

  new path / operation        nothing existing calls it
  new optional request field  existing callers keep working
  new response property       a consumer that ignores it is unaffected; every
                              generated client here tolerates unknown fields
  description / summary text  documentation, not contract

Usage:
  check-api-breaking.py <old-spec.json> <new-spec.json>
  check-api-breaking.py --self-test

Exit 0 if compatible, 1 if breaking.
"""

import json
import sys


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def operations(spec):
    """(path, method) -> operation, for real HTTP methods only."""
    verbs = {"get", "put", "post", "delete", "patch", "head", "options", "trace"}
    found = {}
    for path, item in (spec.get("paths") or {}).items():
        for method, operation in (item or {}).items():
            if method.lower() in verbs:
                found[(path, method.lower())] = operation or {}
    return found


def resolve(spec, node, seen=None):
    """Follow a local $ref. Returns the node itself if it is not a ref.

    Bounded by `seen` because a self-referential schema is legal in OpenAPI and
    would otherwise recurse forever -- a hang in CI is indistinguishable from a
    broken runner, so it is worth the four lines to make it impossible.
    """
    seen = seen or set()
    while isinstance(node, dict) and "$ref" in node:
        ref = node["$ref"]
        if ref in seen or not ref.startswith("#/"):
            return {}
        seen.add(ref)
        target = spec
        for part in ref[2:].split("/"):
            if not isinstance(target, dict) or part not in target:
                return {}
            target = target[part]
        node = target
    return node if isinstance(node, dict) else {}


def schema_properties(spec, schema):
    """Property name -> type, flattened one level. Good enough for the checks
    below and honest about being shallow: a nested field is compared by its
    parent's presence, not field by field."""
    schema = resolve(spec, schema)
    props = {}
    for name, prop in (schema.get("properties") or {}).items():
        resolved = resolve(spec, prop)
        props[name] = resolved.get("type")
    return props


def body_schema(spec, operation):
    content = resolve(spec, operation.get("requestBody") or {}).get("content") or {}
    for media in ("application/json", "*/*"):
        if media in content:
            return content[media].get("schema") or {}
    return {}


def response_schema(spec, operation, code):
    response = resolve(spec, (operation.get("responses") or {}).get(code) or {})
    content = response.get("content") or {}
    for media in ("application/json", "application/problem+json", "*/*"):
        if media in content:
            return content[media].get("schema") or {}
    return {}


def required_of(spec, schema):
    return set(resolve(spec, schema).get("required") or [])


def compare(old, new):
    breaking = []
    compatible = []

    old_ops = operations(old)
    new_ops = operations(new)

    for key in sorted(old_ops.keys() - new_ops.keys()):
        breaking.append("removed operation: %s %s" % (key[1].upper(), key[0]))

    for key in sorted(new_ops.keys() - old_ops.keys()):
        compatible.append("new operation: %s %s" % (key[1].upper(), key[0]))

    for key in sorted(old_ops.keys() & new_ops.keys()):
        path, method = key
        where = "%s %s" % (method.upper(), path)
        old_op, new_op = old_ops[key], new_ops[key]

        old_codes = set((old_op.get("responses") or {}).keys())
        new_codes = set((new_op.get("responses") or {}).keys())
        for code in sorted(old_codes - new_codes):
            breaking.append("%s: removed response %s" % (where, code))
        for code in sorted(new_codes - old_codes):
            compatible.append("%s: new response %s" % (where, code))

        old_required = required_of(old, body_schema(old, old_op))
        new_required = required_of(new, body_schema(new, new_op))
        for field in sorted(new_required - old_required):
            breaking.append("%s: request field '%s' is now required" % (where, field))

        for code in sorted(old_codes & new_codes):
            old_props = schema_properties(old, response_schema(old, old_op, code))
            new_props = schema_properties(new, response_schema(new, new_op, code))
            for field in sorted(set(old_props) - set(new_props)):
                breaking.append("%s %s: response field '%s' removed" % (where, code, field))
            for field in sorted(set(old_props) & set(new_props)):
                if old_props[field] != new_props[field] and old_props[field] and new_props[field]:
                    breaking.append(
                        "%s %s: response field '%s' changed type %s -> %s"
                        % (where, code, field, old_props[field], new_props[field])
                    )

    return breaking, compatible



def _self_test():
    """Synthetic cases proving each rule, run by --self-test in CI.

    A gate with no tests of its own is the thing this repository keeps finding:
    a check that reports success because it never fires. These cases are
    synthetic rather than taken from docs/api/core.json on purpose -- the real
    spec does not currently exercise every rule (no operation declares more
    than one response code), so relying on it would leave rules unproven.
    """
    def spec(paths, schemas=None):
        return {"paths": paths, "components": {"schemas": schemas or {}}}

    def op(responses=None, required=None):
        o = {"responses": responses or {"200": {"description": "ok"}}}
        if required is not None:
            o["requestBody"] = {
                "content": {"application/json": {"schema": {"type": "object", "required": required}}}
            }
        return o

    cases = []

    # breaking: an operation disappears
    cases.append(("removed operation", True,
        spec({"/a": {"get": op()}, "/b": {"get": op()}}),
        spec({"/a": {"get": op()}})))

    # breaking: a response branch a consumer handles disappears
    cases.append(("removed response code", True,
        spec({"/a": {"get": op({"200": {"description": "ok"}, "404": {"description": "gone"}})}}),
        spec({"/a": {"get": op({"200": {"description": "ok"}})}})))

    # breaking: every existing caller is now sending an invalid request
    cases.append(("new required request field", True,
        spec({"/a": {"post": op(required=["x"])}}),
        spec({"/a": {"post": op(required=["x", "y"])}})))

    # breaking: a field consumers read is gone
    body = lambda props: {"responses": {"200": {"content": {"application/json": {"schema": {
        "type": "object", "properties": props}}}}}}
    cases.append(("removed response property", True,
        spec({"/a": {"get": body({"id": {"type": "string"}, "name": {"type": "string"}})}}),
        spec({"/a": {"get": body({"id": {"type": "string"}})}})))

    # breaking: a value consumers parse no longer fits
    cases.append(("narrowed response type", True,
        spec({"/a": {"get": body({"id": {"type": "string"}})}}),
        spec({"/a": {"get": body({"id": {"type": "integer"}})}})))

    # NOT breaking: growth
    cases.append(("new operation", False,
        spec({"/a": {"get": op()}}),
        spec({"/a": {"get": op()}, "/b": {"get": op()}})))
    cases.append(("new response code", False,
        spec({"/a": {"get": op({"200": {"description": "ok"}})}}),
        spec({"/a": {"get": op({"200": {"description": "ok"}, "404": {"description": "gone"}})}})))
    cases.append(("new optional request field", False,
        spec({"/a": {"post": op(required=["x"])}}),
        spec({"/a": {"post": op(required=["x"])}})))
    cases.append(("new response property", False,
        spec({"/a": {"get": body({"id": {"type": "string"}})}}),
        spec({"/a": {"get": body({"id": {"type": "string"}, "extra": {"type": "string"}})}})))

    # a self-referential schema must terminate rather than hang CI
    recursive = {"Node": {"type": "object", "properties": {"child": {"$ref": "#/components/schemas/Node"}}}}
    ref_body = {"responses": {"200": {"content": {"application/json": {
        "schema": {"$ref": "#/components/schemas/Node"}}}}}}
    cases.append(("self-referential schema terminates", False,
        spec({"/a": {"get": ref_body}}, recursive),
        spec({"/a": {"get": ref_body}}, recursive)))

    failures = 0
    for name, should_break, old, new in cases:
        breaking, _ = compare(old, new)
        actual = bool(breaking)
        status = "ok  " if actual == should_break else "FAIL"
        if actual != should_break:
            failures += 1
        print("  %s %-38s expected breaking=%s got=%s %s"
              % (status, name, should_break, actual, breaking if actual != should_break else ""))

    print("")
    if failures:
        print("%d of %d self-tests FAILED" % (failures, len(cases)))
        return 1
    print("all %d self-tests passed" % len(cases))
    return 0


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        return _self_test()

    if len(sys.argv) != 3:
        print(__doc__)
        return 2

    breaking, compatible = compare(load(sys.argv[1]), load(sys.argv[2]))

    if compatible:
        print("Compatible changes (%d):" % len(compatible))
        for line in compatible:
            print("  + %s" % line)
        print("")

    if not breaking:
        print("No breaking changes. %s -> %s" % (sys.argv[1], sys.argv[2]))
        return 0

    print("=" * 66)
    print(" BREAKING API CHANGES (%d)" % len(breaking))
    print("=" * 66)
    for line in breaking:
        print("  ! %s" % line)
    print("")
    print("Every one of these breaks a consumer that is working today.")
    print("clients/java is generated from this spec, so it breaks at compile;")
    print("anything calling the API over HTTP breaks at runtime, which is worse.")
    print("")
    print("If the break is intended, say so in the pull request body and")
    print("version the API rather than editing this gate.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
