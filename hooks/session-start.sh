#!/usr/bin/env bash
# SessionStart — record an open-session stub and schedule Codex summaries.
#
# The hook itself makes no model call. The old gate (a stamp, a lock, a
# detached weekly-report run and an injection of the result) is gone: reports
# are built on demand by /timelog, which also means any week can be built, not
# only the one that most recently finished.

set -uo pipefail

# Load-bearing: bin/fill-summaries.sh spawns `claude -p`, and that child session
# fires this hook too. Without the guard every summary call would write a fresh
# row and sidecar, which would then need summarising — a loop that feeds itself.
[ -n "${CLAUDE_WORKLOG_CHILD:-}" ] && exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOG_LIB="$DIR/../lib"
. "$WORKLOG_LIB/common.sh"

mkdir -p "$WORKLOG_STATE_DIR" "$WORKLOG_DIR"

# `cat` returns only at EOF, and a caller that holds stdin open without sending
# anything never produces one - the hook then blocks for the life of that pipe,
# taking the session with it. `read -d ''` still consumes the whole payload, but
# cannot outlive the timeout.
INPUT=""
IFS= read -r -d '' -t "$WORKLOG_STDIN_TIMEOUT" INPUT || true

field() {
    printf '%s' "$INPUT" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('$1','$2'))
except Exception: print('$2')" 2>/dev/null
}

SID=$(field session_id unknown)
CWD=$(field cwd "")
[ -z "$CWD" ] && CWD="$PWD"
BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")

# A resume reuses the session ID, and a session that died never had its stub
# removed, so this file only ever grew. Drop this session's earlier stub and age
# out anything past 48 h (worklog-reap.sh covers those from the transcripts).
# Rewriting after the read loop means a parse error leaves the file untouched
# rather than truncating it.
python3 - "$WORKLOG_STATE_DIR/open-sessions.tsv" "$SID" <<'PYEOF' 2>/dev/null
import datetime, os, sys
path, sid = sys.argv[1], sys.argv[2]
if os.path.exists(path):
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=48)
    keep = []
    for ln in open(path, errors="replace"):
        parts = ln.rstrip("\n").split("\t")
        if len(parts) < 4 or parts[0] == sid:
            continue
        try:
            ts = datetime.datetime.fromisoformat(parts[1])
        except ValueError:
            continue
        if ts.astimezone(datetime.timezone.utc) >= cutoff:
            keep.append(ln)
    with open(path, "w") as fh:
        fh.write("".join(keep))
PYEOF

printf '%s\t%s\t%s\t%s\n' "$SID" "$(date -Is)" "$CWD" "$BRANCH" >> "$WORKLOG_STATE_DIR/open-sessions.tsv"

if [ "${WORKLOG_AUTO_SUMMARISE:-}" = "codex" ]; then
    bash "$DIR/summary-start.sh" >/dev/null 2>&1
    exit 0
fi

# --- nudge ------------------------------------------------------------------
# Pure filesystem arithmetic: a row count, a file count, a directory listing.
# Silent unless there is something to act on, so it does not become wallpaper.
WORKLOG_DIR="$WORKLOG_DIR" WORKLOG_PENDING_DIR="$WORKLOG_PENDING_DIR" python3 <<'PYEOF' 2>/dev/null
import datetime, glob, json, os

wdir = os.environ["WORKLOG_DIR"]
pending_dir = os.environ["WORKLOG_PENDING_DIR"]
today = datetime.date.today()
this_week = today.strftime("%G-W%V")

pending = len(glob.glob(os.path.join(pending_dir, "*.txt")))

rows = 0
path = os.path.join(wdir, "worklog-%s.md" % this_week)
if os.path.exists(path):
    rows = sum(1 for ln in open(path, errors="replace") if "<!--sid:" in ln)

# Past weeks that have rows but were never reported. Unlike the old gate this
# is not limited to last week, so a week you were away from does not vanish.
unreported = []
for f in sorted(glob.glob(os.path.join(wdir, "worklog-*.md"))):
    wk = os.path.basename(f)[len("worklog-"):-len(".md")]
    if wk >= this_week or not wk[:4].isdigit():
        continue
    if not os.path.exists(os.path.join(wdir, "weekly-report-%s.md" % wk)):
        unreported.append(wk)

bits = []
if rows:
    bits.append("%s: %d row%s" % (this_week, rows, "" if rows == 1 else "s"))
if pending:
    bits.append("%d unsummarised" % pending)
if unreported:
    bits.append("no report for " + ", ".join(unreported[-3:]))

if pending or unreported:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "time-logger — " + "; ".join(bits) + ". Run /timelog to summarise and draft.",
        }
    }))
PYEOF

exit 0
