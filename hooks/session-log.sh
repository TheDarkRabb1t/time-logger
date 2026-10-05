#!/usr/bin/env bash
# SessionEnd — append one row for the finished session to worklog-<ISO-week>.md.
#
# No model call in the hook: this blocks the session exiting, and a summary
# costs 16-34 s. The row carries the facts and a sidecar carries the digest;
# Codex starts a detached child to fill the summary.
#
# Only ever runs on a clean exit. A closed terminal, a SIGKILL or a reboot never
# fires SessionEnd, so worklog-reap.sh covers those from the transcripts.

set -uo pipefail

# Load-bearing: bin/fill-summaries.sh spawns `claude -p`, and that child session
# fires this hook too. Without the guard every summary call would write a fresh
# row and sidecar, which would then need summarising — a loop that feeds itself.
[ -n "${CLAUDE_WORKLOG_CHILD:-}" ] && exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOG_LIB="$DIR/../lib"
. "$WORKLOG_LIB/common.sh"
. "$WORKLOG_LIB/row.sh"

mkdir -p "$WORKLOG_DIR" "$WORKLOG_STATE_DIR"

# `cat` returns only at EOF, and a caller that holds stdin open without sending
# anything never produces one - the hook then blocks for the life of that pipe,
# taking the session with it. `read -d ''` still consumes the whole payload, but
# cannot outlive the timeout.
INPUT=""
IFS= read -r -d '' -t "$WORKLOG_STDIN_TIMEOUT" INPUT || true
[ -z "$INPUT" ] && exit 0

TRANSCRIPT=$(printf '%s' "$INPUT" | python3 -c "import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get('transcript_path',''))
    print(d.get('session_id',''))
except Exception:
    print(''); print('')" 2>/dev/null)
SESSION_ID=$(printf '%s\n' "$TRANSCRIPT" | sed -n 2p)
TRANSCRIPT=$(printf '%s\n' "$TRANSCRIPT" | sed -n 1p)
HOOK_SESSION_ID="$SESSION_ID"

[ -f "$TRANSCRIPT" ] || exit 0
[ -n "$SESSION_ID" ] || exit 0

CONVO=$(mktemp) || exit 0
trap 'rm -f "$CONVO"' EXIT

worklog_parse "$TRANSCRIPT" "$CONVO" || exit 0
SESSION_ID="${WL_SESSION_ID:-$HOOK_SESSION_ID}"

# A session with no real prompt is not work.
if [ "${WL_TURNS:-0}" -lt 1 ]; then
    sed -i "/^$HOOK_SESSION_ID\t/d" "$WORKLOG_STATE_DIR/open-sessions.tsv" 2>/dev/null
    exit 0
fi

# 1 = an uncommitted working tree may stand in for commits; at SessionEnd it is
# still this session's work.
worklog_emit "$SESSION_ID" "$CONVO" 1

if [ "${WORKLOG_AUTO_SUMMARISE:-}" = "codex" ]; then
    bash "$DIR/summary-start.sh" >/dev/null 2>&1
fi

sed -i "/^$HOOK_SESSION_ID\t/d" "$WORKLOG_STATE_DIR/open-sessions.tsv" 2>/dev/null

exit 0
