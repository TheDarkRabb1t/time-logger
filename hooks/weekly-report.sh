#!/usr/bin/env bash
# Weekly aggregator:  weekly-report.sh [--force] [2026-W31]
#
# Merges four sources for one ISO week and asks a model to draft a timesheet:
#   1. worklog-<week>.md      rich, but only covers sessions that exited cleanly
#   2. git log --author=<you> sparse, but survives crashes
#   3. Jira (optional)        candidate tickets, filtered by the repo->project map
#   4. Calendar (optional)    long meetings, the hours no other source records
#
# Writes the result to $WORKLOG_DIR and prints it. On failure it prints the
# collected context instead and writes nothing.

set -uo pipefail

[ -n "${CLAUDE_WORKLOG_CHILD:-}" ] && exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"
. "$DIR/../lib/model.sh"

FORCE=0
[ "${1:-}" = "--force" ] && { FORCE=1; shift; }

WEEK="${1:-$(date -d '7 days ago' +%G-W%V)}"

# The current week used to be refused: a mid-week report looked complete, and
# once a session start injected it the gate closed for good. Reports are built on
# demand now, nothing is stamped and nothing is injected, so an in-progress week
# is just a partial answer you asked for. --force is still accepted so existing
# callers do not break.
if [ "$FORCE" -eq 1 ]; then :; fi

mkdir -p "$WORKLOG_DIR"

CONTEXT=$(python3 - "$WEEK" "$WORKLOG_DIR" "$WORKLOG_STATE_DIR" "$WORKLOG_PROJECT_DIRS" \
                   "$WORKLOG_JIRA_AUTH_FILE" "$WORKLOG_MAP_FILE" "$WORKLOG_JIRA_BASE" \
                   "$WORKLOG_CAL_AUTH_FILE" "$WORKLOG_CAL_IDS" "$WORKLOG_CAL_MIN_MINUTES" \
                   "$WORKLOG_CAL_MAX_MINUTES" "$WORKLOG_CAL_SKIP_DECLINED" \
                   "$WORKLOG_CAL_ICS_FILE" "$DIR/../lib" <<'PYEOF'
import base64, datetime, json, os, re, subprocess, sys, urllib.error, urllib.parse, urllib.request

week, worklog_dir, state, project_dirs, auth_file, map_file, jira_base = sys.argv[1:8]
cal_auth_file, cal_ids, cal_min, cal_max, cal_skip_declined = sys.argv[8:13]
cal_ics_file, lib_dir = sys.argv[13:15]

year, wk = week.split("-W")
monday = datetime.date.fromisocalendar(int(year), int(wk), 1)
sunday = monday + datetime.timedelta(days=6)
out = [f"# Week {week}: {monday} - {sunday}\n"]

# --- 1. worklog rows
rows = []
intervals = []          # active stretches carried in the hidden row markers
log_path = os.path.join(worklog_dir, f"worklog-{week}.md")
if os.path.exists(log_path):
    seen_rule = False
    for line in open(log_path, errors="replace"):
        line = line.strip()
        if not line.startswith("|"):
            continue
        if set(line) <= set("|- "):
            seen_rule = True
            continue
        if not seen_rule:      # header row, whatever language it is in
            continue
        if "<!--sid:" in line:
            head, _, tail = line.partition("<!--sid:")
            marker, _, rest = tail.partition("-->")
            line = head + rest
            # Stop at the next field: the marker is sid;iv:<ranges>;s:<0|1>, so
            # reading to the end would leave "456;s:1" as an end timestamp and
            # silently drop every interval.
            ivs = marker.partition(";iv:")[2].partition(";")[0]
            for part in ivs.split(","):
                a, _, b = part.partition("-")
                if a.isdigit() and b.isdigit():
                    intervals.append((int(a), int(b)))
        rows.append(line)
out.append(f"## Source 1 - coding sessions ({len(rows)} rows)\n")
out.append("\n".join(rows) if rows else "_(no rows - rely on git)_")

# --- 1b. real hours per day
# The Min column cannot be summed. Two terminals open on one repo each counted
# the same hour, and a session spanning days booked all of its minutes to the
# day it happened to end on. Cutting the active stretches at local midnight and
# unioning them per day counts each wall-clock minute exactly once.
def day_hours(ivs):
    per_day = {}
    for a, b in ivs:
        while a < b:
            start = datetime.datetime.fromtimestamp(a)
            midnight = datetime.datetime.combine(
                start.date() + datetime.timedelta(days=1), datetime.time.min).timestamp()
            end = min(b, midnight)
            per_day.setdefault(start.date(), []).append((a, end))
            a = end

    hours = {}
    for day, segs in per_day.items():
        total = cur_a = cur_b = 0
        for s, e in sorted(segs):
            if not cur_b or s > cur_b:          # disjoint: bank the last run
                total += cur_b - cur_a
                cur_a, cur_b = s, e
            else:                               # overlapping: extend it
                cur_b = max(cur_b, e)
        total += cur_b - cur_a
        hours[day] = total / 3600.0
    return hours

in_week = {d: h for d, h in day_hours(intervals).items() if monday <= d <= sunday}
if in_week:
    out.append("\n## Hours per day (authoritative - overlaps counted once)\n")
    out.append("\n".join(f"- {d} {d.strftime('%a')}: {h:.1f} h"
                         for d, h in sorted(in_week.items())))
    out.append(f"\n_Week total: {sum(in_week.values()):.1f} h_")

# --- 2. sessions with no row yet
orphans = []
open_file = os.path.join(state, "open-sessions.tsv")
if os.path.exists(open_file):
    for line in open(open_file, errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 4:
            continue
        try:
            d = datetime.datetime.fromisoformat(parts[1]).date()
        except Exception:
            continue
        if monday <= d <= sunday:
            orphans.append(f"- {parts[1][:16]}  {os.path.basename(parts[2])}  ({parts[3]})")
if orphans:
    out.append("\n## Sessions with no summary (crashed / never closed)\n")
    out.append("\n".join(orphans))

# --- 3. git log
email = subprocess.run(["git", "config", "--global", "user.email"],
                       capture_output=True, text=True).stdout.strip()
since, until = str(monday), str(sunday + datetime.timedelta(days=1))
git_blocks, repos_touched = [], set()

for base in project_dirs.split(":"):
    if not base or not os.path.isdir(base):
        continue
    for repo in sorted(os.listdir(base)):
        path = os.path.join(base, repo)
        if not os.path.isdir(os.path.join(path, ".git")):
            continue
        try:
            log = subprocess.run(
                ["git", "-C", path, "log", f"--author={email}",
                 f"--since={since}", f"--until={until}",
                 "--format=%ad %h %s", "--date=short"],
                capture_output=True, text=True, timeout=15).stdout.strip()
        except Exception:
            continue
        if log:
            repos_touched.add(repo)
            git_blocks.append(f"### {repo}\n{log}")

out.append(f"\n## Source 2 - commits ({len(repos_touched)} repos)\n")
out.append("\n\n".join(git_blocks) if git_blocks else "_(no commits)_")

# --- 4. Jira, only when configured
mapping = {}
if os.path.exists(map_file):
    for line in open(map_file, errors="replace"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t") if "\t" in line else line.split(None, 1)
        if len(parts) >= 2:
            # A repo can belong to more than one project over time. One key per
            # repo would make that unrepresentable, so the second key could never
            # be proposed however plainly the work belonged to it.
            projects = [k for k in re.split(r"[,\s]+", parts[1].strip()) if k]
            if projects:
                mapping[parts[0]] = projects

if mapping:
    out.append("\n## Repo -> project hint (tie-breaker only)\n")
    out.append("\n".join(f"- {k} -> {', '.join(v)}" for k, v in mapping.items()))
    out.append("\n_A hint, not a filter. One repo can carry work for several "
               "projects over time._")

if jira_base and os.path.exists(auth_file):
    tickets = []
    auth = open(auth_file).read().strip()
    basic = {"Accept": "application/json",
             "Authorization": "Basic " + base64.b64encode(auth.encode()).decode()}

    # Search answers an unauthenticated request with 200 and an empty list, so a
    # dead token is indistinguishable from a quiet week and would read as "no
    # tickets". /myself does return 401, so ask it first.
    auth_ok, me_id = True, ""
    # tests/simtest.sh points this at a canned payload so the Jira paths can be
    # exercised without a network or a token; nothing else sets it.
    fixture = {}
    if os.environ.get("WORKLOG_JIRA_FIXTURE"):
        fixture = json.load(open(os.environ["WORKLOG_JIRA_FIXTURE"]))
        me_id = fixture.get("accountId", "me")
    try:
        if fixture:
            raise StopIteration
        with urllib.request.urlopen(
                urllib.request.Request(f"{jira_base}/rest/api/3/myself", headers=basic),
                timeout=15) as r:
            # Needed below: a changelog entry names its author by accountId, and
            # only your own transitions are evidence about your week.
            me_id = json.load(r).get("accountId", "")
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            auth_ok = False
            tickets.append(f"_(Jira auth rejected - HTTP {e.code}. The token in "
                           f"{os.path.basename(auth_file)} is invalid or expired, so no "
                           f"ticket can be proposed. Search would report this as an empty "
                           f"week rather than an error.)_")
    except StopIteration:
        pass
    except Exception as e:
        auth_ok = False
        tickets.append(f"_(Jira unreachable: {e})_")

    # No project filter. Filtering by a repo->project map would hide tickets
    # from other projects worked on in the same repo. What you moved that week
    # is the better filter.
    def jira_search(jql, fields="key,summary,status,updated,project"):
        if fixture:
            return fixture.get("moved" if "CHANGED BY" in jql else "assigned", [])
        qs = urllib.parse.urlencode({"jql": jql, "fields": fields, "maxResults": "60"})
        req = urllib.request.Request(f"{jira_base}/rest/api/3/search/jql?{qs}", headers=basic)
        with urllib.request.urlopen(req, timeout=25) as r:
            return json.load(r).get("issues", [])

    moved = []
    if auth_ok:
        try:
            moved = jira_search(f'status CHANGED BY currentUser() '
                                f'DURING ("{since}","{until}") ORDER BY updated DESC')
        except Exception as e:
            tickets.append(f"_(ticket activity unavailable: {e})_")
        try:
            for i in jira_search('assignee = currentUser() '
                                 f'AND (updated >= "{since}" OR statusCategory != Done) '
                                 'ORDER BY updated DESC'):
                f = i["fields"]
                tickets.append(f"- {i['key']} [{f['project']['key']}] "
                               f"({f['status']['name']}) {f['summary']}")
        except Exception as e:
            tickets.append(f"_(Jira unreachable: {e})_")
    out.append(f"\n## Source 3 - Jira tickets ({len(tickets)})\n")
    out.append("\n".join(tickets) if tickets else "_(none)_")

    # The strongest signal there is: a ticket you moved to In Progress on the
    # Wednesday, and to Done on the Thursday, tells you what the Wednesday and
    # Thursday sessions were - which no commit message here ever says.
    lines = []
    for issue in moved[:25]:
        try:
            if fixture:
                detail = fixture.get("changelog", {}).get(issue["key"])
                if not detail:
                    continue
            else:
                req = urllib.request.Request(
                    f"{jira_base}/rest/api/3/issue/{issue['key']}"
                    f"?expand=changelog&fields=summary", headers=basic)
                with urllib.request.urlopen(req, timeout=20) as r:
                    detail = json.load(r)
        except Exception:
            continue
        for h in detail.get("changelog", {}).get("histories", []):
            if h.get("author", {}).get("accountId") != me_id:
                continue
            when = h.get("created", "")[:16].replace("T", " ")
            if not (since <= when[:10] < until):
                continue
            for item in h.get("items", []):
                if item.get("field") == "status":
                    lines.append(f"- {when}  {issue['key']}  "
                                 f"{item.get('fromString')} -> {item.get('toString')}"
                                 f"  ({detail['fields']['summary'][:60]})")
    lines.sort()
    out.append(f"\n## Source 5 - ticket activity ({len(lines)} status changes you made)\n")
    out.append("\n".join(lines) if lines else
               "_(no status changes this week - fall back to commits and topic)_")

# --- 5. calendar, only when bin/cal-auth.py has been run
# Meetings leave no commit and no session row, so before this the timesheet's
# meetings line was pure arithmetic: whatever it took to reach the target. The
# refresh token is traded for an access token on every run - access tokens last
# an hour, which is no use to a weekly job. singleEvents=true makes Google
# expand recurrences server-side, so a weekly retro arrives as this week's
# occurrence, a moved one at its real time and a cancelled one not at all.
week_lo = datetime.datetime.combine(monday, datetime.time.min).astimezone()
week_hi = datetime.datetime.combine(
    sunday + datetime.timedelta(days=1), datetime.time.min).astimezone()

# A week still in progress ends at now, not on Sunday night. Sessions and
# commits cannot report work that has not happened, but a calendar can and
# would: drafting Wednesday would otherwise book Thursday's and Friday's
# meetings as already sat through. Past weeks are unaffected, and a week
# entirely in the future keeps its full window - nothing there is a claim
# about hours worked yet.
_now = datetime.datetime.now().astimezone()
if week_lo <= _now < week_hi:
    week_hi = _now


def cal_fetch():
    # tests/simtest.sh points this at a canned events.list payload; nothing
    # else sets it, and the fetch below is what runs for real.
    fixture = os.environ.get("WORKLOG_CAL_FIXTURE")
    if fixture:
        return json.load(open(fixture)).get("items", [])

    # A feed needs no Google Cloud project, so it wins when both are set up:
    # whoever wrote the ics file did so after meeting the OAuth path's demands.
    if os.path.exists(cal_ics_file):
        sys.path.insert(0, lib_dir)
        import ics
        feeds = [ln.strip() for ln in open(cal_ics_file, errors="replace")
                 if ln.strip() and not ln.startswith("#")]
        return ics.fetch(feeds, week_lo, week_hi, email)

    with open(cal_auth_file) as fh:
        cred = json.load(fh)
    body = urllib.parse.urlencode({
        "client_id": cred["client_id"],
        "client_secret": cred["client_secret"],
        "refresh_token": cred["refresh_token"],
        "grant_type": "refresh_token"}).encode()
    with urllib.request.urlopen(
            urllib.request.Request("https://oauth2.googleapis.com/token", data=body),
            timeout=25) as r:
        token = json.load(r)["access_token"]

    qs = urllib.parse.urlencode({
        "timeMin": week_lo.isoformat(),
        "timeMax": week_hi.isoformat(),
        "singleEvents": "true", "orderBy": "startTime", "maxResults": "250"})
    items = []
    for cal in cal_ids.split(":"):
        if not cal:
            continue
        req = urllib.request.Request(
            f"https://www.googleapis.com/calendar/v3/calendars/"
            f"{urllib.parse.quote(cal, safe='')}/events?{qs}",
            headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(req, timeout=25) as r:
            items.extend(json.load(r).get("items", []))
    return items

if os.path.exists(cal_auth_file) or os.path.exists(cal_ics_file):
    cal_err, raw = None, []
    try:
        raw = cal_fetch()
    except Exception as e:
        cal_err = e

    meetings = []
    for ev in raw:
        start, end = ev.get("start", {}), ev.get("end", {})
        # An all-day entry carries `date` instead of `dateTime`. Those are
        # markers - holidays, leave, OOO - and their 24 h would dwarf the week.
        if "dateTime" not in start or "dateTime" not in end:
            continue
        if ev.get("status") == "cancelled":
            continue
        a = datetime.datetime.fromisoformat(start["dateTime"]).astimezone()
        b = datetime.datetime.fromisoformat(end["dateTime"]).astimezone()
        mins = (b - a).total_seconds() / 60.0
        if mins < float(cal_min) or mins > float(cal_max):
            continue
        me = next((at for at in ev.get("attendees", []) if at.get("self")), {})
        reply = me.get("responseStatus", "")
        if cal_skip_declined == "1" and reply == "declined":
            continue
        # events.list returns anything overlapping the window, not only what
        # sits inside it, so a Monday breakfast meeting that started late on the
        # previous Sunday arrives whole. Its full length decides whether it is a
        # ceremony; only the part inside this week is counted as hours.
        a, b = max(a, week_lo), min(b, week_hi)
        if b <= a:
            continue
        meetings.append((a, b, ev.get("summary", "(no title)"), reply))

    # Hours per day above counts session stretches only. A meeting that ran
    # while a session sat open is already inside that figure; one that did not
    # is hours the week is otherwise missing. Reporting both keeps the model
    # from either double-counting or dropping the difference.
    merged = []
    for lo, hi in sorted(intervals):
        if merged and lo <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], hi)
        else:
            merged.append([lo, hi])

    lines, total, solo = [], 0.0, 0.0
    for a, b, title, reply in sorted(meetings):
        hrs = (b - a).total_seconds() / 3600.0
        ov = sum(max(0, min(b.timestamp(), hi) - max(a.timestamp(), lo))
                 for lo, hi in merged) / 3600.0
        total += hrs
        solo += hrs - ov
        lines.append(f"- {a.date()} {a.strftime('%a')} {a:%H:%M}-{b:%H:%M} "
                     f"({hrs:.1f} h) {title}"
                     + (f" [{reply}]" if reply else "")
                     + (f" - {ov:.1f} h overlaps a logged session" if ov > 0.05 else ""))

    out.append(f"\n## Source 4 - calendar ({len(lines)} meetings, {total:.1f} h)\n")
    if cal_err:
        out.append(f"_(calendar unreachable: {cal_err})_")
    elif lines:
        out.append("\n".join(lines))
        out.append(f"\n_Meeting hours: {total:.1f} h in total, of which {solo:.1f} h "
                   f"fall outside any logged session and are therefore missing "
                   f"from Hours per day._")
    else:
        out.append(f"_(no meetings between {cal_min} and {cal_max} minutes)_")

print("\n".join(out))
PYEOF
)

[ -z "$CONTEXT" ] && exit 0

PROMPT="Draft a weekly timesheet for a developer. They fill in the tracker by hand;
your job is to remind them what they did and propose options.

They do not remember last week. Show the EVIDENCE first (commits, files, session
summaries), and only then your guess at a ticket.

Rules:
1. Rank the evidence in this order, and say which one you used:
   a. Source 5. A ticket you moved that day is the strongest evidence there is -
      In Progress on the Wednesday and Done on the Thursday means the Wednesday
      and Thursday work was that ticket. Only this earns 'ok'.
   b. A commit or branch naming the ticket key. Also earns 'ok'.
   c. Topic. The work plainly matches the ticket's summary. This is 'verify'.
   d. The repo hint, ONLY to break a tie between two tickets that fit equally
      well on the evidence above. It is a hint, never a filter: any project's
      ticket may be proposed for any repo, because one repo carries work for
      several projects. A repo missing from the hint list changes nothing.
2. Never invent a ticket key. Work no ticket covers is 'new', and you say what
   ticket should be created. A Workdir starting with ~ is not a repo.
3. Use \"Hours per day\" for the totals when it is present - it already counts
   overlapping and multi-day sessions once each. Never add up the Min column,
   which double-counts both. Ticket hours plus a \"meetings/other\" row should
   come to about $WORKLOG_TARGET_HOURS.
   Write the per-day rows FIRST, then build the table above by adding up those
   rows per ticket. The two must agree exactly: the table is a summary of the
   per-day rows, not a second estimate of the same week. A reader comparing them
   and finding different totals will trust neither.
   The two must hold the SAME hours, in both directions. Every per-day row
   appears in the table, ticketless ones included - give those a row labelled
   \"(no ticket)\", one per project where that helps. And every table row is
   backed by per-day rows, meetings included: a meeting has a date, so it gets a
   per-day row like anything else. The \"Work with no ticket\" section names the
   tickets to create; it does NOT excuse those hours from either place. Add the
   two totals up before you answer - if they differ, you have dropped something
   from one side.
4. When a \"Source 4 - calendar\" block is present the meetings row comes from
   it, not from arithmetic: take the hours listed there and name the ceremonies
   in the description. Only the hours it reports as falling outside a logged
   session are added on top of \"Hours per day\" - the rest are already counted.
   A meeting that clearly belongs to one ticket may be booked against it
   instead. Without that block, the meetings row stays your estimate.
5. Write descriptions in $WORKLOG_LANG, keeping technical terms in English.
   Eight words maximum.
6. Confidence: 'high' when commits match the ticket directly, 'medium' when they
   match by topic, 'low' when it is a guess.

Output exactly this shape:

## Timesheet draft <week>

| Ticket | Hrs | Description | Confidence | Based on |
|---|---|---|---|---|
...

## Work with no ticket
(names for new tickets, and why)

## Gaps
(days with no activity, sessions with no summary - what to check by hand)

## Per-day rows

Then exactly this block, which is read by a tool and not by a person. One line
per day per ticket, tab-separated, seven fields, no header, no blank lines:

date, project, ticket, hours, status, summary, suggestion

- date is YYYY-MM-DD. Only days inside this week.
- project is the Jira project key the work belongs to, or a single - when none.
- ticket is the issue key, or a single - when there is none.
- hours is one decimal. The hours for a day must add up to that day's figure in
  Hours per day, and every ticket total must agree with the table above.
- status is exactly one of: ok, verify, new.
  ok     - a commit or session names this ticket directly.
  verify - matched by topic, or the hours were inferred, so a person must check.
  new    - no ticket covers this work and one should be created.
- summary is at most eight words, in $WORKLOG_LANG.
- suggestion is empty for ok. For verify say in one sentence what to check. For
  new say in one sentence what ticket to create. Never leave it empty for
  verify or new.

<!--daily
2026-08-21	PROJ	PROJ-123	1.2	ok	Fix retry on timeout	
2026-08-19	PROJ	-	5.0	verify	Design review	Hours come from a session spanning 19-20; confirm the split
2026-08-17	-	-	5.9	new	Split service into two packages	Create a ticket for splitting the service into core and plugin packages
-->

Data:

$CONTEXT"

REPORT=$(worklog_model "$WORKLOG_REPORT_MODEL" "$PROMPT" "$WORKLOG_REPORT_TIMEOUT")
RC=$?

# A killed `claude -p` still writes to stdout — a SIGTERM'd run prints
# "Execution error". Checking for empty output alone let that reach the report.
if [ "$RC" -ne 0 ] || [ -z "$REPORT" ] || [ "$REPORT" = "Execution error" ]; then
    echo "$CONTEXT"
    exit 0
fi

printf '%s\n' "$REPORT" > "$WORKLOG_DIR/weekly-report-$WEEK.md"
printf '%s\n' "$REPORT"
exit 0
