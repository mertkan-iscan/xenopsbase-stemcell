#!/usr/bin/env python3
"""Render a scalability run as a self-contained HTML report with charts (T-5.10).

WHY CHARTS AND NOT JUST THE TEXT REPORT

scalability-report.py prints a table, and a table is the right artifact for a
gate. It is the wrong artifact for the two questions this test actually asks,
because both are about SHAPE:

  - "where is the knee" is the point a curve stops being straight, and a reader
    comparing six numbers in a column finds it slowly and sometimes not at all
  - "did the HPA react in time" is the relationship between two timelines, and
    no table puts a replica count next to the latency it was supposed to protect

Every colour here is from the validated categorical palette and every chart is
inline SVG with no external requests, so the page renders under a strict CSP and
survives being emailed to somebody as a single file.

Usage:
  scalability-charts.py <k6.log> <timeline.tsv> <out.html> [events.txt]
"""
import html
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load_reporter():
    """Reuse the text reporter's parsers rather than re-implementing them.

    Two parsers for one log format is two things to keep in step, and the one
    that drifts is always the one without a gate on it.
    """
    path = os.path.join(HERE, "scalability-report.py")
    spec = importlib.util.spec_from_file_location("scalability_report", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


R = load_reporter()

# The validated categorical palette, slots 1-3, light and dark. Validated with
# scripts/validate_palette.js --pairs all in both modes: worst CVD dE 9.2 light /
# 9.4 dark, worst normal-vision dE 24.0 light / 20.9 dark.
#
# Light-mode aqua sits at 2.74:1 against the surface, below the 3:1 line, so the
# relief rule applies: every series carries a direct end label AND the full data
# table is on the page. Identity is never colour alone here.
SERIES = [
    ("s1", "#2a78d6", "#3987e5"),
    ("s2", "#eb6834", "#d95926"),
    ("s3", "#1baf7a", "#199e70"),
]

PAD_L, PAD_R, PAD_T, PAD_B = 62, 46, 26, 46
W, H = 660, 300


def slot_cls(slot):
    """-1 is the reference role: neutral ink, never a categorical hue."""
    return "ref" if slot < 0 else SERIES[slot][0]


def esc(s):
    return html.escape(str(s), quote=True)


def nice_ticks(lo, hi, count=5):
    """Round tick values that a person would have chosen."""
    if hi <= lo:
        hi = lo + 1
    span = hi - lo
    raw = span / max(count - 1, 1)
    mag = 10 ** int(_floor_log10(raw))
    for mult in (1, 2, 2.5, 5, 10):
        step = mag * mult
        if step >= raw:
            break
    start = step * int(lo / step)
    ticks = []
    v = start
    while v <= hi + step * 0.5:
        if v >= lo - 1e-9:
            ticks.append(v)
        v += step
    return ticks, (ticks[-1] if ticks else hi)


def _floor_log10(x):
    import math

    return math.floor(math.log10(x)) if x > 0 else 0


def fmt_num(v):
    if v >= 1000:
        return "{:,.0f}".format(v)
    if v >= 10:
        return "{:.0f}".format(v)
    if v >= 1:
        return "{:.1f}".format(v)
    return "{:.2f}".format(v)


def axes(y_ticks, y_max, x_labels, x_pos, y_label, x_label):
    """Recessive grid and axis furniture, drawn before any data mark."""
    out = []
    plot_h = H - PAD_T - PAD_B
    for t in y_ticks:
        y = PAD_T + plot_h - (t / y_max * plot_h if y_max else 0)
        out.append(
            '<line class="grid" x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" />' % (PAD_L, y, W - PAD_R, y)
        )
        out.append(
            '<text class="tick" x="%.1f" y="%.1f" text-anchor="end" dominant-baseline="middle">%s</text>'
            % (PAD_L - 8, y, esc(fmt_num(t)))
        )
    for lbl, x in zip(x_labels, x_pos):
        out.append(
            '<text class="tick" x="%.1f" y="%.1f" text-anchor="middle">%s</text>'
            % (x, H - PAD_B + 18, esc(lbl))
        )
    out.append(
        '<text class="axis-label" x="%.1f" y="%.1f" text-anchor="middle">%s</text>'
        % ((PAD_L + W - PAD_R) / 2, H - 6, esc(x_label))
    )
    out.append(
        '<text class="axis-label" transform="translate(14,%.1f) rotate(-90)" text-anchor="middle">%s</text>'
        % (PAD_T + plot_h / 2, esc(y_label))
    )
    return "".join(out)


def line_chart(title, subtitle, x_labels, series, y_label, x_label, dashed_first=False):
    """Line chart. `series` is [(name, [values], slot_index)] — values align to x_labels."""
    n = len(x_labels)
    if n == 0:
        return ""
    plot_w = W - PAD_L - PAD_R
    plot_h = H - PAD_T - PAD_B
    x_pos = [PAD_L + (plot_w * (i / (n - 1)) if n > 1 else plot_w / 2) for i in range(n)]

    all_vals = [v for _, vals, _ in series for v in vals if v is not None]
    y_ticks, y_max = nice_ticks(0, max(all_vals) if all_vals else 1)

    body = [axes(y_ticks, y_max, x_labels, x_pos, y_label, x_label)]

    for si, (name, vals, slot) in enumerate(series):
        cls = slot_cls(slot)
        pts = [
            (x_pos[i], PAD_T + plot_h - (v / y_max * plot_h if y_max else 0))
            for i, v in enumerate(vals)
            if v is not None
        ]
        if not pts:
            continue
        d = " ".join(
            ("M" if i == 0 else "L") + "%.1f %.1f" % p for i, p in enumerate(pts)
        )
        dash = ' stroke-dasharray="6 5"' if (dashed_first and si == 0) else ""
        body.append('<path class="ln %s" d="%s"%s />' % (cls, d, dash))
        for i, p in enumerate(pts):
            val = [v for v in vals if v is not None][i]
            # A 2px surface ring so overlapping markers stay countable.
            body.append(
                '<circle class="mk %s" cx="%.1f" cy="%.1f" r="4.5"><title>%s — %s: %s</title></circle>'
                % (cls, p[0], p[1], esc(x_labels[i]), esc(name), esc(fmt_num(val)))
            )
        # Direct label at the series end. This is the relief the palette
        # validator requires for the light-mode aqua slot, and it is also just
        # better than making the reader trace a colour back to a legend box.
        lx, ly = pts[-1]
        body.append(
            '<text class="endlab %s" x="%.1f" y="%.1f" text-anchor="end">%s</text>'
            % (cls, min(lx, W - PAD_R), ly - 11, esc(name))
        )

    legend = "".join(
        '<span class="lg"><i class="sw %s"></i>%s</span>' % (slot_cls(slot), esc(name))
        for name, _, slot in series
    )
    return (
        '<figure class="chart">'
        '<figcaption><h3>%s</h3><p>%s</p></figcaption>'
        '<div class="legend">%s</div>'
        '<div class="svgwrap"><svg viewBox="0 0 %d %d" role="img" aria-label="%s">%s</svg></div>'
        "</figure>"
        % (esc(title), esc(subtitle), legend, W, H, esc(title), "".join(body))
    )


def time_chart(title, subtitle, rows, cols, y_label, step_marks=None, integer_y=False):
    """Time series over elapsed seconds. `cols` is [(name, tsv_key, slot)]."""
    pts_by_series = []
    for name, key, slot in cols:
        pts = []
        for r in rows:
            v = R.num(r, key)
            if v is not None:
                pts.append((r["elapsed_s"], v))
        pts_by_series.append((name, pts, slot))

    all_x = [x for _, pts, _ in pts_by_series for x, _ in pts]
    all_y = [y for _, pts, _ in pts_by_series for _, y in pts]
    if not all_x:
        return ""
    x_max = max(all_x) or 1
    y_ticks, y_max = nice_ticks(0, max(all_y) if all_y else 1, 5)
    if integer_y:
        top = int(max(all_y)) + 1
        y_ticks = list(range(0, top + 1))
        y_max = top

    plot_w = W - PAD_L - PAD_R
    plot_h = H - PAD_T - PAD_B

    def sx(x):
        return PAD_L + plot_w * (x / x_max)

    def sy(y):
        return PAD_T + plot_h - (y / y_max * plot_h if y_max else 0)

    x_ticks, _ = nice_ticks(0, x_max, 6)
    body = []
    for t in y_ticks:
        body.append(
            '<line class="grid" x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" />'
            % (PAD_L, sy(t), W - PAD_R, sy(t))
        )
        body.append(
            '<text class="tick" x="%.1f" y="%.1f" text-anchor="end" dominant-baseline="middle">%s</text>'
            % (PAD_L - 8, sy(t), esc(fmt_num(t)))
        )
    for t in x_ticks:
        if t > x_max:
            continue
        body.append(
            '<text class="tick" x="%.1f" y="%.1f" text-anchor="middle">%d</text>'
            % (sx(t), H - PAD_B + 18, int(t))
        )

    # Step boundaries: the whole point of putting these two timelines together
    # is being able to see which offered rate a replica change belongs to.
    #
    # The rule always draws, but LABELS are thinned. Steps late in a run sit
    # close together in time, and overlapping labels are worse than absent ones
    # -- an unreadable smear implies the data is crowded when it is the
    # annotation that is.
    last_label_x = -1e9
    for boundary, label in (step_marks or []):
        if boundary > x_max:
            continue
        bx = sx(boundary)
        body.append(
            '<line class="stepline" x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" />'
            % (bx, PAD_T, bx, PAD_T + plot_h)
        )
        if bx - last_label_x >= 40:
            body.append(
                '<text class="steplab" x="%.1f" y="%.1f" text-anchor="middle">%s</text>'
                % (bx, PAD_T - 6, esc(label))
            )
            last_label_x = bx

    for name, pts, slot in pts_by_series:
        if not pts:
            continue
        cls = slot_cls(slot)
        if integer_y:
            # Replica counts are a step function. Drawing them as a smooth line
            # implies fractional replicas, which do not exist.
            d = "M%.1f %.1f" % (sx(pts[0][0]), sy(pts[0][1]))
            for i in range(1, len(pts)):
                d += " L%.1f %.1f L%.1f %.1f" % (
                    sx(pts[i][0]), sy(pts[i - 1][1]), sx(pts[i][0]), sy(pts[i][1]),
                )
        else:
            d = " ".join(
                ("M" if i == 0 else "L") + "%.1f %.1f" % (sx(x), sy(y))
                for i, (x, y) in enumerate(pts)
            )
        body.append('<path class="ln %s" d="%s" />' % (cls, d))
        lx, ly = sx(pts[-1][0]), sy(pts[-1][1])
        body.append(
            '<text class="endlab %s" x="%.1f" y="%.1f" text-anchor="end">%s</text>'
            % (cls, lx, ly - 11, esc(name))
        )

    body.append(
        '<text class="axis-label" x="%.1f" y="%.1f" text-anchor="middle">elapsed seconds</text>'
        % ((PAD_L + W - PAD_R) / 2, H - 6)
    )
    body.append(
        '<text class="axis-label" transform="translate(14,%.1f) rotate(-90)" text-anchor="middle">%s</text>'
        % (PAD_T + plot_h / 2, esc(y_label))
    )

    legend = "".join(
        '<span class="lg"><i class="sw %s"></i>%s</span>' % (slot_cls(slot), esc(name))
        for name, _, slot in cols
    )
    return (
        '<figure class="chart">'
        '<figcaption><h3>%s</h3><p>%s</p></figcaption>'
        '<div class="legend">%s</div>'
        '<div class="svgwrap"><svg viewBox="0 0 %d %d" role="img" aria-label="%s">%s</svg></div>'
        "</figure>"
        % (esc(title), esc(subtitle), legend, W, H, esc(title), "".join(body))
    )


def collect_steps(schedule, counters, trends, prefix):
    out = []
    for w in schedule["windows"]:
        if not w["label"].startswith(prefix + "_"):
            continue
        label = w["label"]
        hold = w["to"] - w["from"]
        sent = counters.get("req_" + label, 0)
        fails = counters.get("fail_" + label, 0)
        auth = counters.get("auth_" + label, 0)
        svr = counters.get("svr_" + label, 0)
        t = trends.get("lat_" + label, {})
        out.append(
            {
                "offered": w["rate"],
                "served": max(sent - fails, 0) / hold if hold else 0.0,
                "sent": sent,
                "auth": auth,
                "svr": svr,
                "auth_pct": (auth / sent * 100.0) if sent else 0.0,
                "svr_pct": (svr / sent * 100.0) if sent else 0.0,
                "p50": t.get("med"),
                "p95": t.get("p(95)"),
                "p99": t.get("p(99)"),
                "from": w["from"],
                "to": w["to"],
            }
        )
    return out


def steps_table(steps, caption):
    if not steps:
        return ""
    head = (
        "<tr><th>Offered req/s</th><th>Served req/s</th><th>Served %</th>"
        "<th>p50 ms</th><th>p95 ms</th><th>p99 ms</th><th>5xx %</th><th>auth %</th></tr>"
    )
    body = []
    for s in steps:
        invalid = s["auth_pct"] > 5.0
        body.append(
            "<tr%s><td>%d</td><td>%s</td><td>%.1f</td><td>%s</td><td>%s</td><td>%s</td>"
            "<td>%.1f</td><td>%.1f</td></tr>"
            % (
                ' class="invalid"' if invalid else "",
                s["offered"],
                fmt_num(s["served"]),
                (s["served"] / s["offered"] * 100.0) if s["offered"] else 0.0,
                R.fmt_ms(s["p50"]),
                R.fmt_ms(s["p95"]),
                R.fmt_ms(s["p99"]),
                s["svr_pct"],
                s["auth_pct"],
            )
        )
    return (
        '<div class="tablewrap"><table><caption>%s</caption><thead>%s</thead><tbody>%s</tbody></table></div>'
        % (esc(caption), head, "".join(body))
    )


CSS = """
:root{
  color-scheme: light;
  --ground:#f7f8fa; --surface:#ffffff; --surface-2:#eef1f5;
  --ink:#10131a; --ink-2:#565f70; --ink-3:#8b94a5;
  --rule:#dfe4ea; --grid:#e7ebf0;
  --alert:#b3261e; --alert-bg:#fdf0ef; --alert-rule:#e8b4b0;
  --ok:#1a7f4f;
  --s1:#2a78d6; --s2:#eb6834; --s3:#1baf7a;
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    color-scheme: dark;
    --ground:#14161a; --surface:#1c1f24; --surface-2:#23272e;
    --ink:#eef1f6; --ink-2:#9aa4b5; --ink-3:#6d7789;
    --rule:#2c313a; --grid:#282d35;
    --alert:#e66767; --alert-bg:#2a1d1d; --alert-rule:#5c3130;
    --ok:#4cae7d;
    --s1:#3987e5; --s2:#d95926; --s3:#199e70;
  }
}
:root[data-theme="dark"]{
  color-scheme: dark;
  --ground:#14161a; --surface:#1c1f24; --surface-2:#23272e;
  --ink:#eef1f6; --ink-2:#9aa4b5; --ink-3:#6d7789;
  --rule:#2c313a; --grid:#282d35;
  --alert:#e66767; --alert-bg:#2a1d1d; --alert-rule:#5c3130;
  --ok:#4cae7d;
  --s1:#3987e5; --s2:#d95926; --s3:#199e70;
}

*{box-sizing:border-box}
body{
  margin:0; background:var(--ground); color:var(--ink);
  font-family:"Source Sans 3","Segoe UI",system-ui,sans-serif;
  font-size:16px; line-height:1.6;
}
.wrap{max-width:1120px; margin:0 auto; padding:40px 24px 72px; display:flex; flex-direction:column; gap:34px}
h1,h2,h3{font-family:Archivo,"Segoe UI",system-ui,sans-serif; margin:0; text-wrap:balance; letter-spacing:-0.015em}
h1{font-size:2.1rem; font-weight:700; line-height:1.15}
h2{font-size:1.28rem; font-weight:650}
h3{font-size:1rem; font-weight:650}
p{margin:0}
.eyebrow{
  font-family:Archivo,system-ui,sans-serif; font-size:.72rem; font-weight:600;
  letter-spacing:.13em; text-transform:uppercase; color:var(--ink-3);
}
.sub{color:var(--ink-2); max-width:68ch}
header .meta{
  font-family:"JetBrains Mono",ui-monospace,monospace; font-size:.78rem;
  color:var(--ink-3); display:flex; flex-wrap:wrap; gap:6px 18px;
}
section{display:flex; flex-direction:column; gap:18px}
.sechead{display:flex; flex-direction:column; gap:5px; border-top:1px solid var(--rule); padding-top:16px}

.tiles{display:grid; grid-template-columns:repeat(auto-fit,minmax(190px,1fr)); gap:14px}
.tile{background:var(--surface); border:1px solid var(--rule); border-radius:10px; padding:16px 18px; display:flex; flex-direction:column; gap:4px}
.tile .k{font-size:.74rem; letter-spacing:.08em; text-transform:uppercase; color:var(--ink-3); font-weight:600}
.tile .v{font-family:"JetBrains Mono",ui-monospace,monospace; font-size:1.62rem; font-weight:600; font-variant-numeric:tabular-nums; letter-spacing:-.02em}
.tile .n{font-size:.83rem; color:var(--ink-2); line-height:1.4}

.alert{background:var(--alert-bg); border:1px solid var(--alert-rule); border-left:4px solid var(--alert); border-radius:8px; padding:18px 20px; display:flex; flex-direction:column; gap:10px}
.alert h2{color:var(--alert); font-size:1.05rem}
.alert p{font-size:.93rem; color:var(--ink)}
.alert code{background:var(--surface); padding:1px 5px; border-radius:4px}

.grid2{display:grid; grid-template-columns:repeat(auto-fit,minmax(420px,1fr)); gap:18px}
.chart{margin:0; background:var(--surface); border:1px solid var(--rule); border-radius:10px; padding:18px 18px 10px; display:flex; flex-direction:column; gap:10px}
.chart figcaption{display:flex; flex-direction:column; gap:3px}
.chart figcaption p{font-size:.84rem; color:var(--ink-2)}
.svgwrap{overflow-x:auto}
svg{width:100%; height:auto; display:block}
.legend{display:flex; flex-wrap:wrap; gap:6px 16px}
.lg{display:inline-flex; align-items:center; gap:6px; font-size:.79rem; color:var(--ink-2); font-weight:500}
.sw{width:11px; height:11px; border-radius:3px; display:inline-block}
.sw.s1{background:var(--s1)} .sw.s2{background:var(--s2)} .sw.s3{background:var(--s3)}

.grid{stroke:var(--grid); stroke-width:1}
.tick{fill:var(--ink-3); font-size:11px; font-family:"JetBrains Mono",monospace}
.axis-label{fill:var(--ink-2); font-size:11.5px; font-family:"Source Sans 3",sans-serif; letter-spacing:.04em}
.ln{fill:none; stroke-width:2; stroke-linejoin:round; stroke-linecap:round}
.mk{stroke:var(--surface); stroke-width:2}
.endlab{font-size:11.5px; font-weight:600; font-family:Archivo,sans-serif}
.ln.ref{stroke:var(--ink-3)} .mk.ref{fill:var(--ink-3)} .endlab.ref{fill:var(--ink-3)}
.sw.ref{background:var(--ink-3)}
.ln.s1{stroke:var(--s1)} .mk.s1{fill:var(--s1)} .endlab.s1{fill:var(--s1)}
.ln.s2{stroke:var(--s2)} .mk.s2{fill:var(--s2)} .endlab.s2{fill:var(--s2)}
.ln.s3{stroke:var(--s3)} .mk.s3{fill:var(--s3)} .endlab.s3{fill:var(--s3)}
.stepline{stroke:var(--rule); stroke-width:1; stroke-dasharray:3 4}
.steplab{fill:var(--ink-3); font-size:9.5px; font-family:"JetBrains Mono",monospace}

.tablewrap{overflow-x:auto; background:var(--surface); border:1px solid var(--rule); border-radius:10px}
table{border-collapse:collapse; width:100%; font-size:.87rem}
caption{text-align:left; padding:14px 16px 8px; font-weight:600; font-family:Archivo,sans-serif; color:var(--ink)}
th,td{padding:8px 14px; text-align:right; border-top:1px solid var(--rule); font-variant-numeric:tabular-nums; font-family:"JetBrains Mono",monospace}
th{font-size:.72rem; letter-spacing:.05em; text-transform:uppercase; color:var(--ink-3); font-weight:600; font-family:Archivo,sans-serif; text-align:right}
th:first-child,td:first-child{text-align:left}
tbody tr:hover{background:var(--surface-2)}
tr.invalid td{color:var(--alert)}

.findings{display:flex; flex-direction:column; gap:12px}
.finding{background:var(--surface); border:1px solid var(--rule); border-radius:10px; padding:16px 18px; display:flex; flex-direction:column; gap:6px}
.finding .t{font-family:Archivo,sans-serif; font-weight:650; font-size:.98rem}
.finding p{font-size:.9rem; color:var(--ink-2)}
.finding .tag{align-self:flex-start; font-size:.68rem; letter-spacing:.09em; text-transform:uppercase; font-weight:700; padding:2px 8px; border-radius:20px; background:var(--surface-2); color:var(--ink-2)}
.finding .tag.bad{background:var(--alert-bg); color:var(--alert)}
.finding .tag.good{color:var(--ok)}
footer{color:var(--ink-3); font-size:.82rem; border-top:1px solid var(--rule); padding-top:16px}
@media (max-width:560px){ h1{font-size:1.6rem} .wrap{padding:26px 16px 48px} }

/* PRINT / PDF.
   The screen page is theme-aware; a PDF is not. It is printed once and read
   anywhere, so it commits to the light token set regardless of what theme the
   renderer happened to be in -- a dark PDF is unreadable on paper and wrong in
   every document viewer that composites it on white.
   print-color-adjust: exact keeps the series colours, without which every line
   in every chart prints as the same grey and the charts stop meaning anything. */
@page{ size:A4 portrait; margin:13mm; }
@media print{
  :root, :root[data-theme="dark"], :root:not([data-theme="light"]){
    color-scheme: light;
    --ground:#ffffff; --surface:#ffffff; --surface-2:#f3f5f8;
    --ink:#0b0d12; --ink-2:#3d4551; --ink-3:#5c6472;
    --rule:#c9cfd8; --grid:#e2e6ec;
    --alert:#9c2019; --alert-bg:#fbf1f0; --alert-rule:#e0b3af;
    --ok:#14663f;
    --s1:#2a78d6; --s2:#eb6834; --s3:#1baf7a;
  }
  *{ -webkit-print-color-adjust:exact; print-color-adjust:exact; }
  body{ background:#fff; font-size:10.5pt; }
  .wrap{ max-width:none; padding:0; gap:20px; }
  h1{ font-size:20pt; }
  h2{ font-size:12.5pt; }
  /* Nothing that is read as one unit may be split across a page boundary. */
  .chart, .tablewrap, .tile, .alert, .finding, figure, table{ break-inside:avoid; page-break-inside:avoid; }
  .grid2{ grid-template-columns:1fr 1fr; gap:10px; }
  .tiles{ grid-template-columns:repeat(4,1fr); gap:8px; }
  .tile .v{ font-size:1.2rem; }
  section{ break-before:auto; }
  .sechead{ break-after:avoid; page-break-after:avoid; }
  tbody tr:hover{ background:none; }
  footer{ font-size:8.5pt; }
}
"""


def build(k6log, timeline, out_path, events=None):
    schedule, trends, counters, totals = R.parse_k6(k6log)
    rows = R.parse_timeline(timeline)
    if not schedule:
        raise SystemExit("no SCHEDULE_JSON in %s — cannot attribute steps" % k6log)

    core = collect_steps(schedule, counters, trends, "core")
    gw = collect_steps(schedule, counters, trends, "gw")

    valid_core = [s for s in core if s["auth_pct"] <= 5.0]
    clean = [s for s in valid_core if s["svr_pct"] < 1.0 and s["served"] >= s["offered"] * 0.99]
    capacity = max((s["offered"] for s in clean), default=None)
    knee = next((s["offered"] for s in valid_core if s["served"] < s["offered"] * 0.95), None)

    _, gw_rep_hi = R.span(rows, "gw_cur")
    _, core_rep_hi = R.span(rows, "core_cur")
    _, k6_cpu_hi = R.span(rows, "k6_cpu_m")
    _, pending_hi = R.span(rows, "pending")

    step_marks = [(s["from"], "%d/s" % s["offered"]) for s in core + gw]

    tiles = [
        ("Clean read capacity", "%s req/s" % (fmt_num(capacity) if capacity else "—"),
         "Highest step serving the full offered rate with no 5xx."),
        ("Knee", "%s req/s" % (fmt_num(knee) if knee else "not reached"),
         "First step that could not serve 95% of what it was offered."),
        ("Gateway alone", "%s req/s" % (fmt_num(max((s["offered"] for s in gw), default=0)) or "—"),
         "Unauthenticated path, no downstream call."),
        ("Peak replicas", "%s gw / %s core" % (gw_rep_hi, core_rep_hi),
         "Ceilings are 4 and 3. Pending pods peaked at %s." % pending_hi),
    ]
    tiles_html = "".join(
        '<div class="tile"><span class="k">%s</span><span class="v">%s</span><span class="n">%s</span></div>'
        % (esc(k), esc(v), esc(n))
        for k, v, n in tiles
    )

    charts = []
    if core:
        charts.append(
            line_chart(
                "Throughput: served against offered",
                "The dashed line is the offered rate. Where the solid line leaves it, the system stopped keeping up.",
                ["%d" % s["offered"] for s in core],
                [
                    ("offered", [float(s["offered"]) for s in core], -1),
                    ("served", [s["served"] for s in core], 0),
                ],
                "req/s", "offered req/s", dashed_first=True,
            )
        )
        charts.append(
            line_chart(
                "Latency by percentile",
                "Read this against the error columns: rejections are fast, so a failing step can show an improving p95.",
                ["%d" % s["offered"] for s in core],
                [
                    ("p50", [s["p50"] for s in core], 0),
                    ("p95", [s["p95"] for s in core], 1),
                    ("p99", [s["p99"] for s in core], 2),
                ],
                "milliseconds", "offered req/s",
            )
        )
    charts.append(
        time_chart(
            "CPU through the run",
            "Application CPU against the load generator's own. A generator taking a large share of a worker is competing with what it measures.",
            rows,
            [("gateway", "gw_cpu_m", 0), ("core", "core_cpu_m", 1), ("k6", "k6_cpu_m", 2)],
            "millicores", step_marks,
        )
    )
    charts.append(
        time_chart(
            "Replicas through the run",
            "Drawn as steps, because fractional replicas do not exist. Compare the timing against the CPU chart above.",
            rows,
            [("gateway", "gw_cur", 0), ("core", "core_cur", 1)],
            "replicas", step_marks, integer_y=True,
        )
    )

    doc = """<title>Stemcell Capacity Curve</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@500;600;700&family=Source+Sans+3:wght@400;500;600&family=JetBrains+Mono:wght@400;500;600&display=swap">
<style>%s</style>
<div class="wrap">
<header>
  <span class="eyebrow">T-5.10 &middot; scalability</span>
  <h1>Where the stack stops scaling</h1>
  <p class="sub">An open-model step ramp against the dev cluster, with replica counts and CPU sampled from outside while it ran. %s</p>
  <div class="meta"><span>%s</span><span>k6 ramping-arrival-rate</span><span>in-cluster</span></div>
</header>

<section>
  <div class="tiles">%s</div>
</section>

<section>
  <div class="sechead"><span class="eyebrow">Question one &middot; where is the knee</span><h2>The capacity curve</h2>
  <p class="sub">Throughput rises with offered load until it does not. The step before it departs is the honest number.</p></div>
  <div class="grid2">%s</div>
  %s
</section>

<section>
  <div class="sechead"><span class="eyebrow">Question two &middot; does the autoscaler govern it</span><h2>What the cluster did</h2>
  <p class="sub">The HPA targets were derived arithmetically and rehearsed on a local k3s. These are the timelines of them acting on the real cluster.</p></div>
  <div class="grid2">%s</div>
  %s
</section>

<footer>Generated by <code>infra/scripts/scalability-charts.py</code> from the run's k6 log and cluster timeline. Every figure on this page was measured; nothing is projected.</footer>
</div>
""" % (
        CSS,
        esc(
            "Load generator peaked at %sm CPU on a worker under test." % k6_cpu_hi
            if k6_cpu_hi is not None
            else ""
        ),
        esc(os.path.basename(os.path.dirname(os.path.abspath(k6log)))),
        tiles_html,
        "".join(charts[:2]),
        steps_table(core, "Through core — gateway to core to Postgres"),
        "".join(charts[2:]),
        steps_table(gw, "Gateway only — permitAll, no downstream call") if gw else "",
    )

    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(doc)
    return out_path


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    out = build(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
    print("wrote %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
