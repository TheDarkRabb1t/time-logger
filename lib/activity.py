#!/usr/bin/env python3
"""Render the per-day activity ledger as one self-contained HTML page.

Reads the <!--daily ...--> blocks that weekly-report.sh writes into each
weekly-report-<week>.md and lays them out newest week first. Nothing here calls
a model or a network: the attribution was decided when the report was drafted,
and this only presents it.

    activity.py <worklog_dir> <out_path> <jira_base> <links_file> [max_weeks]

A week whose report predates the block is listed as needing a redraft rather
than quietly omitted - a missing week must never look like an empty one.
"""
import glob
import hashlib
import html
import os
import re
import sys

TICKET = re.compile(r"^[A-Z][A-Z0-9]*-[0-9]+$")   # PROJ-123: the key has digits
GLYPH = {"ok": "✓", "verify": "?", "new": "+"}
WORD = {"ok": "Matched", "verify": "Verify", "new": "New"}


def parse_block(text):
    """The rows inside <!--daily ... -->, tolerant about the separator."""
    m = re.search(r"<!--\s*daily\s*(.*?)-->", text, re.S)
    if not m:
        return None
    rows = []
    for line in m.group(1).splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 6:
            # A model asked for tabs sometimes emits aligned spaces instead.
            parts = re.split(r"\s{2,}", line.strip())
        if len(parts) < 6:
            continue
        parts = [p.strip() for p in parts] + [""] * (7 - len(parts))
        date, project, ticket, hours, status, summary, suggestion = parts[:7]
        try:
            hrs = float(hours.replace(",", "."))
        except ValueError:
            continue
        if status not in GLYPH:
            status = "verify"
        rows.append({"date": date, "project": project, "ticket": ticket,
                     "hours": hrs, "status": status, "summary": summary,
                     "suggestion": suggestion})
    return rows


def week_sessions(worklog_dir, week):
    path = os.path.join(worklog_dir, f"worklog-{week}.md")
    if not os.path.exists(path):
        return 0
    return open(path, errors="replace").read().count("<!--sid:")


def read_links(path):
    links = {}
    if path and os.path.exists(path):
        for line in open(path, errors="replace"):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t") if "\t" in line else line.split(None, 1)
            if len(parts) >= 2:
                links[parts[0].strip()] = parts[1].strip()
    return links


def href(row, jira_base, links):
    """An issue links to itself; work with no ticket links to its backlog.

    A project with no configured backlog gets no link at all - a guessed Jira
    URL that 404s is worse than plain text.
    """
    if TICKET.match(row["ticket"]) and jira_base:
        return f"{jira_base.rstrip('/')}/browse/{row['ticket']}"
    return links.get(row["project"], "")


def day_name(iso):
    try:
        import datetime
        d = datetime.date.fromisoformat(iso)
        return d.strftime("%a"), str(d.day), d.strftime("%b")
    except Exception:
        return "", iso, ""


def render(worklog_dir, out_path, jira_base, links_file, max_weeks=0):
    links = read_links(links_file)
    weeks, stale = [], []
    for path in sorted(glob.glob(os.path.join(worklog_dir, "weekly-report-*.md")), reverse=True):
        week = os.path.basename(path)[len("weekly-report-"):-len(".md")]
        rows = parse_block(open(path, errors="replace").read())
        if rows is None:
            stale.append(week)
            continue
        if not rows:
            continue
        days = {}
        for r in rows:
            days.setdefault(r["date"], []).append(r)
        weeks.append({"week": week, "days": sorted(days.items(), reverse=True),
                      "sessions": week_sessions(worklog_dir, week),
                      "hours": sum(r["hours"] for r in rows)})
    if max_weeks:
        weeks = weeks[:max_weeks]

    body = []
    for w in weeks:
        first, last = w["days"][-1][0], w["days"][0][0]
        _, d1, m1 = day_name(first)
        _, d2, m2 = day_name(last)
        span = f"{d1} {m1} – {d2} {m2}" if m1 else ""
        day_html = []
        for date, rows in w["days"]:
            dow, num, mon = day_name(date)
            tasks = []
            for r in rows:
                rid = hashlib.sha1(
                    f"{w['week']}|{r['date']}|{r['ticket']}|{r['summary']}".encode()
                ).hexdigest()[:12]
                tip = WORD[r["status"]]
                if r["suggestion"] and r["status"] != "ok":
                    tip += "\n" + r["suggestion"]
                label = r["ticket"] if r["ticket"] and r["ticket"] != "-" else "no ticket"
                url = href(r, jira_base, links)
                chip = (f'<a class="chip {r["status"]}" href="{html.escape(url)}" '
                        f'target="_blank" rel="noreferrer" data-tip="{html.escape(tip)}">'
                        if url else
                        f'<span class="chip {r["status"]}" tabindex="0" '
                        f'data-tip="{html.escape(tip)}">')
                close = "</a>" if url else "</span>"
                tasks.append(
                    f'<li class="task" data-id="{rid}" data-hrs="{r["hours"]:.1f}">'
                    f'<button class="drop" type="button" title="Do not count this row"'
                    f' aria-label="Do not count this row">⊘</button>'
                    f'{chip}<span class="glyph">{GLYPH[r["status"]]}</span>'
                    f'{html.escape(label)}{close}'
                    f'<span class="hrs">{r["hours"]:.1f}</span>'
                    f'<span class="sum">{html.escape(r["summary"])}</span></li>')
            day_html.append(
                f'<li class="day"><div class="day-date"><span class="dow">{dow}</span>'
                f'<span class="dnum">{num}</span><span class="dmon">{mon}</span></div>'
                f'<ul class="tasks">{"".join(tasks)}</ul></li>')
        body.append(
            f'<section class="wk" data-week="{w["week"]}">'
            f'<header class="wk-head"><span class="wk-id">{w["week"]}</span>'
            f'<span class="wk-range">{span}</span>'
            f'<span class="wk-tot"><b data-total>{w["hours"]:.1f}</b> h</span>'
            f'<span class="wk-sess">{w["sessions"]} sessions</span></header>'
            f'<ol class="days">{"".join(day_html)}</ol></section>')

    note = ""
    if stale:
        note = ('<p class="stale">No per-day rows in: ' + ", ".join(sorted(stale, reverse=True))
                + '. Redraft those weeks to include them.</p>')
    if not weeks:
        body.append('<p class="stale">No week has per-day rows yet. '
                    'Draft a week with /timelog and run this again.</p>')

    page = TEMPLATE.replace("{{BODY}}", "".join(body)).replace("{{NOTE}}", note)
    with open(out_path, "w") as fh:
        fh.write(page)
    return len(weeks), stale


TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Activity ledger</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;450;600&display=swap">
<style>
:root{
  --ground:#f4f6f8;--surface:#fff;--sunken:#eef1f5;
  --ink:#1b1f26;--ink-2:#4a5563;--muted:#6b7683;
  --rule:#dfe4ea;--accent:#0f7d8c;
  --ok:#2f8f4e;--ok-bg:#e8f5ec;--warn:#a86f00;--warn-bg:#fdf3de;
  --new:#c0392f;--new-bg:#fdecea;--tip-bg:#1b1f26;--tip-ink:#f2f4f7;
}
@media (prefers-color-scheme:dark){:root{
  --ground:#0f1216;--surface:#161a20;--sunken:#1c222a;
  --ink:#e7ebf0;--ink-2:#b3bcc8;--muted:#87919e;
  --rule:#262d36;--accent:#45b3c2;
  --ok:#54c07a;--ok-bg:#16301f;--warn:#e0a83a;--warn-bg:#332711;
  --new:#f0776a;--new-bg:#361a19;--tip-bg:#e7ebf0;--tip-ink:#12161b;
}}
*{box-sizing:border-box}
body{margin:0;background:var(--ground);color:var(--ink);
  font-family:"IBM Plex Sans",ui-sans-serif,system-ui,sans-serif;font-size:15px;line-height:1.55}
.wrap{max-width:960px;margin:0 auto;padding:44px 24px 80px;display:flex;flex-direction:column;gap:22px}
h1{margin:0;font-size:27px;font-weight:600;letter-spacing:-.02em}
.eyebrow{font-family:"IBM Plex Mono",monospace;font-size:11px;letter-spacing:.14em;
  text-transform:uppercase;color:var(--accent)}
.hint,.stale{margin:0;color:var(--muted);font-size:13px;max-width:70ch}
.wk{background:var(--surface);border:1px solid var(--rule);border-radius:5px;overflow:hidden}
.wk-head{display:grid;grid-template-columns:auto 1fr auto auto;gap:14px;align-items:baseline;
  background:var(--sunken);padding:13px 20px;border-bottom:1px solid var(--rule)}
.wk-id{font-family:"IBM Plex Mono",monospace;font-weight:600;font-size:15px}
.wk-range,.wk-sess{color:var(--muted);font-size:13px}
.wk-tot{font-family:"IBM Plex Mono",monospace;font-variant-numeric:tabular-nums}
.days,.tasks{list-style:none;margin:0;padding:0}
.days{padding:6px 20px 14px}
.day{display:grid;grid-template-columns:74px 1fr;gap:0 16px;padding:12px 0;align-items:start}
.day+.day{border-top:1px solid var(--rule)}
.day-date{font-family:"IBM Plex Mono",monospace;font-size:12px;color:var(--muted);
  display:flex;flex-direction:column;line-height:1.25;padding-top:6px}
.day-date .dnum{font-size:17px;color:var(--ink);font-weight:500}
.task{display:grid;grid-template-columns:20px minmax(120px,auto) 46px 1fr;gap:10px;
  align-items:baseline;padding:5px 0}
.drop{background:none;border:0;color:var(--muted);opacity:.35;cursor:pointer;
  font-size:14px;padding:0;line-height:1}
.drop:hover,.drop:focus-visible{opacity:1;color:var(--new)}
.chip{font-family:"IBM Plex Mono",monospace;font-size:12.5px;font-weight:500;
  display:inline-flex;align-items:center;gap:6px;position:relative;white-space:nowrap;
  background:var(--sunken);border:1px solid var(--rule);border-radius:99px;padding:2px 10px;
  text-decoration:none}
a.chip:hover{text-decoration:underline}
.chip .glyph{font-size:11px;opacity:.9}
.chip.ok{color:var(--ok);background:var(--ok-bg);border-color:transparent}
.chip.verify{color:var(--warn);background:var(--warn-bg);border-color:transparent}
.chip.new{color:var(--new);background:var(--new-bg);border-color:transparent}
.chip::after{content:attr(data-tip);position:absolute;bottom:calc(100% + 8px);left:0;z-index:9;
  min-width:200px;max-width:330px;background:var(--tip-bg);color:var(--tip-ink);
  font-family:"IBM Plex Sans",sans-serif;font-size:12.5px;font-weight:400;line-height:1.45;
  white-space:pre-line;padding:9px 11px;border-radius:4px;box-shadow:0 6px 20px rgb(0 0 0/.22);
  opacity:0;visibility:hidden;transform:translateY(3px);
  transition:opacity .12s ease,transform .12s ease,visibility .12s}
.chip:hover::after,.chip:focus-visible::after{opacity:1;visibility:visible;transform:translateY(0)}
.chip:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.hrs{font-family:"IBM Plex Mono",monospace;font-variant-numeric:tabular-nums;
  text-align:right;color:var(--ink-2)}
.sum{color:var(--ink-2);font-size:14.5px;min-width:0}
.task.out .chip,.task.out .hrs,.task.out .sum{text-decoration:line-through;opacity:.42}
.task.out .drop{opacity:1;color:var(--accent)}
@media (prefers-reduced-motion:reduce){.chip::after{transition:none}}
</style></head><body>
<div class="wrap">
  <span class="eyebrow">time-logger</span>
  <h1>Activity ledger</h1>
  <p class="hint">Hover a ticket for why it is coloured. Use the ⊘ to drop a row from the
  week total — the choice is remembered in this browser only.</p>
  {{NOTE}}
  {{BODY}}
</div>
<script>
var KEY = "time-logger:excluded";
function load(){ try { return JSON.parse(localStorage.getItem(KEY) || "{}"); } catch (e) { return {}; } }
function save(state){ try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) {} }
var state = load();

function retotal(wk){
  var sum = 0;
  wk.querySelectorAll(".task").forEach(function(t){
    if (!t.classList.contains("out")) sum += parseFloat(t.dataset.hrs || 0);
  });
  wk.querySelector("[data-total]").textContent = sum.toFixed(1);
}
document.querySelectorAll(".task").forEach(function(task){
  if (state[task.dataset.id]) task.classList.add("out");
  task.querySelector(".drop").addEventListener("click", function(){
    var off = task.classList.toggle("out");
    if (off) { state[task.dataset.id] = 1; } else { delete state[task.dataset.id]; }
    save(state);
    retotal(task.closest(".wk"));
  });
});
document.querySelectorAll(".wk").forEach(retotal);
</script></body></html>
"""

if __name__ == "__main__":
    worklog_dir, out_path, jira_base, links_file = sys.argv[1:5]
    limit = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] else 0
    n, stale = render(worklog_dir, out_path, jira_base, links_file, limit)
    print(f"{n} week(s) rendered -> {out_path}")
    if stale:
        print("no per-day rows (redraft to include): " + ", ".join(sorted(stale, reverse=True)))
