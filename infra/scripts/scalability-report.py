#!/usr/bin/env python3
"""Join the k6 curve with the cluster timeline into one report (T-5.10).

WHY THIS IS A SEPARATE FILE

k6 answers "what did the client see" and the sampler answers "what did the
cluster do". Read apart, each one supports the wrong conclusion:

  latency flat at 1600 req/s        looks like headroom -- until you see the
                                    HPA went to maxReplicas at 800 to hold it
  latency climbing at 1200 req/s    looks like the ceiling -- until you see the
                                    replica the HPA asked for was Pending the
                                    whole time, so the ceiling measured was the
                                    node's, not the application's

So the join is the deliverable, not a convenience. Everything below is parsing
in service of putting those two columns next to each other.

Usage:
  scalability-report.py <k6.log> <timeline.tsv> [events.txt]
"""
import json
import re
import sys

# k6 prints durations with a unit and, for sub-millisecond values, a Greek mu
# that is not the micro sign. Both code points appear in the wild depending on
# the terminal, so accept either rather than dropping the sample.
DUR = re.compile(r"([0-9.]+)\s*(ms|s|µs|μs|us|ns|m)\b")


def to_ms(text):
    """A k6 duration such as '3.63ms', '1.23s' or '454.81µs' in milliseconds."""
    m = DUR.match(text.strip())
    if not m:
        return None
    value, unit = float(m.group(1)), m.group(2)
    factor = {
        "ns": 1e-6,
        "us": 1e-3,
        "µs": 1e-3,
        "μs": 1e-3,
        "ms": 1.0,
        "s": 1000.0,
        "m": 60000.0,
    }[unit]
    return value * factor


def parse_k6(path):
    """Pull the schedule, the per-step metrics and the run totals out of the log."""
    schedule, trends, counters, totals = None, {}, {}, {}

    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if "SCHEDULE_JSON" in line and schedule is None:
                # k6 does not print console output raw. It wraps it in its own
                # logfmt record and escapes the quotes inside:
                #
                #   time="..." level=info msg="SCHEDULE_JSON {\\"gap\\":420,...}" source=console
                #
                # So take everything between the marker and the closing quote
                # that precedes ` source=`, then unescape. The non-greedy match
                # is safe: the escaped quotes inside the payload are never
                # followed by ` source=`.
                m = re.search(r'SCHEDULE_JSON\s+(.*?)"\s+source=', line)
                payload = m.group(1).replace('\\"', '"') if m else line.split("SCHEDULE_JSON", 1)[1].strip()
                try:
                    schedule = json.loads(payload)
                except ValueError:
                    pass
                continue

            # Summary rows look like:  name.......: k=v k=v ...   or   name...: 123  4.5/s
            m = re.match(r"\s*[✓✗x]?\s*([a-zA-Z0-9_()]+)\.{2,}:\s*(.+?)\s*$", line)
            if not m:
                continue
            name, rest = m.group(1), m.group(2)

            stats = dict(re.findall(r"(avg|min|med|max|p\(90\)|p\(95\)|p\(99\))=(\S+)", rest))
            if stats:
                trends[name] = {k: to_ms(v) for k, v in stats.items()}
                continue

            first = rest.split()[0] if rest.split() else ""
            if re.fullmatch(r"[0-9]+", first):
                counters[name] = int(first)
            totals[name] = rest

    return schedule, trends, counters, totals


def parse_timeline(path):
    rows = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        header = fh.readline().rstrip("\n").split("\t")
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != len(header):
                continue
            row = dict(zip(header, parts))
            try:
                row["elapsed_s"] = int(row["elapsed_s"])
            except ValueError:
                continue
            rows.append(row)
    return rows


def num(row, key):
    try:
        return int(row.get(key, "-"))
    except (TypeError, ValueError):
        return None


def window_rows(rows, start, end):
    return [r for r in rows if start <= r["elapsed_s"] < end]


def span(rows, key):
    """(min, max) of an integer column over these rows, or (None, None)."""
    vals = [num(r, key) for r in rows]
    vals = [v for v in vals if v is not None]
    return (min(vals), max(vals)) if vals else (None, None)


def fmt_ms(v):
    return "-" if v is None else ("%.1f" % v)


def fmt_range(lo, hi):
    if lo is None:
        return "-"
    return str(lo) if lo == hi else "%d-%d" % (lo, hi)


def step_table(title, prefix, schedule, trends, counters, rows, out):
    windows = [w for w in schedule["windows"] if w["label"].startswith(prefix + "_")]
    if not windows:
        return

    out.append("")
    out.append(title)
    out.append("-" * len(title))
    out.append("")
    # SERVED, not DELIVERED. An earlier version of this table divided every
    # request k6 sent by the rate it was asked to send, and reported 100% for
    # steps where every single response was an error -- the generator had indeed
    # delivered them, and the column said so, which made a total outage look like
    # perfect throughput. A request that returns an error is offered load, not
    # served load, and the two must never share a column.
    #
    # The 5xx and auth columns are separate for a harder-won reason. See the
    # header of scalability.js: a step failing on 401 is a broken HARNESS and a
    # step failing on 503 is a strained SYSTEM, they look identical in every
    # aggregate metric, and collapsing them cost a full working session.
    out.append("  offered    served   served     p50      p95      p99     5xx    auth   replicas   peak cpu")
    out.append("   req/s      req/s      %        ms       ms       ms      %       %    (gw/core)   gw / core")
    out.append("  " + "-" * 100)

    prev_p95 = None
    knee = None
    degraded = []
    invalid = []
    for w in windows:
        label = w["label"]
        hold = w["to"] - w["from"]
        offered = w["rate"]
        sent = counters.get("req_" + label, 0)
        fails = counters.get("fail_" + label, 0)
        auth = counters.get("auth_" + label, 0)
        svr = counters.get("svr_" + label, 0)
        served = max(sent - fails, 0) / hold if hold else 0.0
        served_pct = (served / offered * 100.0) if offered else 0.0
        auth_pct = (auth / sent * 100.0) if sent else 0.0
        svr_pct = (svr / sent * 100.0) if sent else 0.0
        t = trends.get("lat_" + label, {})

        wr = window_rows(rows, w["from"], w["to"])
        gw_lo, gw_hi = span(wr, "gw_cur")
        c_lo, c_hi = span(wr, "core_cur")
        _, gw_cpu = span(wr, "gw_cpu_m")
        _, core_cpu = span(wr, "core_cpu_m")

        flag = "  <-- NOT A CAPACITY RESULT" if auth_pct > 5.0 else ""
        out.append(
            "  %6d  %8.0f  %7.1f  %7s  %7s  %7s  %6.1f  %6.1f   %4s/%-4s  %6s/%-6s%s"
            % (
                offered, served, served_pct,
                fmt_ms(t.get("med")), fmt_ms(t.get("p(95)")), fmt_ms(t.get("p(99)")),
                svr_pct, auth_pct,
                fmt_range(gw_lo, gw_hi), fmt_range(c_lo, c_hi),
                "-" if gw_cpu is None else "%dm" % gw_cpu,
                "-" if core_cpu is None else "%dm" % core_cpu,
                flag,
            )
        )

        # An auth-failed step measures nothing about capacity. It must not set
        # the knee, and it must not be carried forward as a latency baseline --
        # its p95 is the cost of being rejected, which is near zero.
        if auth_pct > 5.0:
            invalid.append((offered, auth_pct))
            continue

        if svr_pct > 5.0:
            degraded.append((offered, svr_pct))

        p95 = t.get("p(95)")
        if knee is None:
            if served_pct < 95.0:
                knee = (offered, "only %.0f%% of the offered rate was served successfully" % served_pct)
            elif prev_p95 and p95 and p95 > 2 * prev_p95:
                knee = (offered, "p95 more than doubled against the previous step")
        if p95 and svr_pct <= 5.0:
            prev_p95 = p95

    out.append("")
    if invalid:
        out.append("  !! THESE STEPS ARE INVALID, NOT SATURATED: %s."
                   % ", ".join("%d req/s (%.0f%% auth errors)" % d for d in invalid))
        out.append("  The requests were REJECTED, not served slowly. The gateway never forwarded")
        out.append("  them, so downstream CPU falls to idle and latency falls to nothing -- which")
        out.append("  reads as a capacity cliff in every aggregate metric and is not one.")
        out.append("  Usual cause: the run outlived its access token (accessTokenLifespan is 300s).")
        out.append("  Fix the harness and re-run; do not quote these rows.")
        out.append("")
    if degraded:
        out.append("  LATENCY IS NOT SERVICE TIME at %s."
                   % ", ".join("%d req/s (%.0f%% 5xx)" % d for d in degraded))
        out.append("  A rejection is faster than an answer, so p95 improves as the system fails.")
        out.append("  Read the error columns first; the milliseconds mean nothing without them.")
        out.append("")
    if knee:
        out.append("  KNEE at %d req/s: %s" % knee)
        out.append("  Honest capacity is the step BELOW this one.")
    elif invalid:
        out.append("  NO KNEE ESTABLISHED. Every step above the valid ones failed on auth, so the")
        out.append("  ceiling was never measured. This run does not have a capacity answer in it.")
    else:
        out.append("  NO KNEE REACHED. Every step served the offered rate with flat latency,")
        out.append("  so this run found a floor on capacity, not the ceiling. Raise the steps.")


def scaling_section(rows, events_path, out):
    out.append("")
    out.append("Scaling behaviour")
    out.append("-----------------")
    out.append("")

    changes = []
    for key, who in (("gw_cur", "gateway"), ("core_cur", "core")):
        last = None
        for r in rows:
            v = num(r, key)
            if v is None:
                continue
            if last is not None and v != last:
                changes.append((r["elapsed_s"], who, last, v))
            last = v

    if changes:
        for t, who, a, b in changes:
            arrow = "scaled UP" if b > a else "scaled DOWN"
            out.append("  t+%-5ds  %-8s %s  %d -> %d" % (t, who, arrow, a, b))
    else:
        out.append("  NO REPLICA CHANGE for the whole run.")
        out.append("  Either the load never reached the HPA target, or the HPA is not governing.")
        out.append("  The utilisation column below says which.")

    gw_pct = [num(r, "gw_pct") for r in rows]
    gw_pct = [v for v in gw_pct if v is not None]
    core_pct = [num(r, "core_pct") for r in rows]
    core_pct = [v for v in core_pct if v is not None]
    out.append("")
    if gw_pct:
        out.append("  gateway HPA utilisation  peak %d%%  (target 200%%)" % max(gw_pct))
    if core_pct:
        out.append("  core    HPA utilisation  peak %d%%  (target 200%%)" % max(core_pct))

    _, nodes_hi = span(rows, "nodes")
    nodes_lo, _ = span(rows, "nodes")
    _, pending_hi = span(rows, "pending")
    out.append("  nodes %s   peak Pending app pods %s" % (fmt_range(nodes_lo, nodes_hi), pending_hi))
    if pending_hi:
        out.append("  A Pending pod means the HPA's decision was not schedulable. The ceiling")
        out.append("  measured past that point is the node's, not the application's.")

    _, k6_hi = span(rows, "k6_cpu_m")
    if k6_hi is not None:
        out.append("")
        out.append("  LOAD GENERATOR: k6 peaked at %dm CPU on a worker under test." % k6_hi)
        if k6_hi >= 1800:
            out.append("  That is a large share of one 3700m worker. Treat the top steps as a")
            out.append("  lower bound: some of what was measured is contention with k6 itself.")

    if events_path:
        try:
            with open(events_path, "r", encoding="utf-8", errors="replace") as fh:
                lines = [l.rstrip() for l in fh if "Scaled" in l or "FailedScheduling" in l or "TriggeredScaleUp" in l]
        except OSError:
            lines = []
        if lines:
            out.append("")
            out.append("  What the cluster said, in its own words:")
            for l in lines[-12:]:
                out.append("    " + l.strip()[:110])


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2

    k6log, timeline = sys.argv[1], sys.argv[2]
    events = sys.argv[3] if len(sys.argv) > 3 else None

    schedule, trends, counters, totals = parse_k6(k6log)
    rows = parse_timeline(timeline)

    out = []
    out.append("=" * 90)
    out.append(" SCALABILITY REPORT")
    out.append("=" * 90)

    if not schedule:
        out.append("")
        out.append(" No SCHEDULE_JSON in the k6 log, so the steps cannot be attributed.")
        out.append(" The run may still have produced a usable raw log; the per-step join is lost.")
        print("\n".join(out))
        return 1

    step_table("Through core  (gateway -> core -> Postgres)", "core", schedule, trends, counters, rows, out)
    step_table("Gateway only  (permitAll, no downstream call)", "gw", schedule, trends, counters, rows, out)
    scaling_section(rows, events, out)

    dropped = counters.get("dropped_iterations")
    out.append("")
    out.append("Run totals")
    out.append("----------")
    out.append("")
    for k in ("http_reqs", "http_req_failed", "dropped_iterations", "iterations", "vus_max"):
        if k in totals:
            out.append("  %-22s %s" % (k, totals[k]))
    if dropped:
        out.append("")
        out.append("  dropped_iterations is non-zero: k6 could not START %d requests on" % dropped)
        out.append("  schedule. That is the open model reporting real overload -- unless k6")
        out.append("  itself ran out of VUs, which the k6 log names explicitly.")

    out.append("")
    out.append("=" * 90)
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
