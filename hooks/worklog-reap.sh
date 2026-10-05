#!/usr/bin/env bash
# SessionStart — write rows for sessions that died without firing SessionEnd.
#
# session-log.sh only runs on a clean exit, so a closed terminal, a SIGKILL or a
# reboot loses the session outright; session-start.sh then ages the stub out of
# open-sessions.tsv after 48 h and the work is unrecoverable by hand. This reads
# the transcripts directly, so it does not depend on the stub having survived.
#
# No model call in the reaper — it writes rows and sidecars exactly as
# session-log.sh does; Codex starts a detached summary child. Reaping stays
# detached because parsing a few hundred transcripts can take seconds.
#
# A separate hook rather than an addition to session-start.sh: hooks on the same
# event run in parallel, so anything here would race that 48 h prune.

set -uo pipefail

# Load-bearing: bin/fill-summaries.sh spawns `claude -p`, and that child session
# fires this hook too. Without the guard every summary call would write a fresh
# row and sidecar, which would then need summarising — a loop that feeds itself.
[ -n "${CLAUDE_WORKLOG_CHILD:-}" ] && exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOG_LIB="$DIR/../lib"
. "$WORKLOG_LIB/common.sh"
. "$WORKLOG_LIB/row.sh"

LOCK="${WORKLOG_REAP_LOCK:-$WORKLOG_STATE_DIR/reap.lock}"
CONVO=""

mkdir -p "$WORKLOG_DIR" "$WORKLOG_STATE_DIR" 2>/dev/null

# --- detach -----------------------------------------------------------------
if [ "${WORKLOG_REAP_INLINE:-0}" != "1" ]; then
    # A lock left by a run that was killed would otherwise block reaping forever.
    if [ -d "$LOCK" ] && [ -z "$(find "$LOCK" -maxdepth 0 -mmin -30 2>/dev/null)" ]; then
        rmdir "$LOCK" 2>/dev/null || true
    fi
    # mkdir is the atomic test-and-set: two concurrent session starts cannot
    # both reap, which would append the same row twice.
    mkdir "$LOCK" 2>/dev/null || exit 0

    SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
    RUNNER=(bash "$SELF")
    command -v setsid >/dev/null 2>&1 && RUNNER=(setsid bash "$SELF")
    nohup env WORKLOG_REAP_INLINE=1 WORKLOG_REAP_LOCK="$LOCK" \
        "${RUNNER[@]}" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    exit 0
fi

trap 'rmdir "$LOCK" 2>/dev/null || true; rm -f "$CONVO"' EXIT

TRANSCRIPT_DIRS=()
[ -d "$WORKLOG_TRANSCRIPT_DIR" ] && TRANSCRIPT_DIRS+=("$WORKLOG_TRANSCRIPT_DIR")
[ -d "$WORKLOG_CODEX_TRANSCRIPT_DIR" ] && TRANSCRIPT_DIRS+=("$WORKLOG_CODEX_TRANSCRIPT_DIR")
[ "${#TRANSCRIPT_DIRS[@]}" -gt 0 ] || exit 0

# --- candidates -------------------------------------------------------------
# Touched within the lookback window but not in the last STALE_HOURS. Every
# prompt appends to its transcript, so mtime is already a per-prompt heartbeat —
# no extra hook is needed to know when a session went quiet.
CANDIDATES=$(find "${TRANSCRIPT_DIRS[@]}" -type f -name '*.jsonl' \
                  -mtime -"$WORKLOG_REAP_LOOKBACK_DAYS" \
                  ! -newermt "-$WORKLOG_REAP_STALE_HOURS hours" 2>/dev/null)
[ -z "$CANDIDATES" ] && exit 0

CONVO=$(mktemp) || exit 0
WRITTEN=0

# fd 3, not stdin. Nothing in this loop reads stdin today, but the summariser
# that used to live here did, and it silently ate the whole backlog after the
# first row.
while IFS= read -r TRANSCRIPT <&3; do
    [ -f "$TRANSCRIPT" ] || continue
    [ "$WRITTEN" -ge "$WORKLOG_REAP_MAX_PER_RUN" ] && break

    SESSION_ID=$(basename "$TRANSCRIPT" .jsonl)
    if [[ "$SESSION_ID" =~ ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$ ]]; then
        SESSION_ID="${BASH_REMATCH[1]}"
    fi

    # Already logged — by a clean SessionEnd or an earlier reap. Swept across
    # every week file because a resumed session's row can sit in another week.
    # Checked before parsing, so repeat passes over a drained backlog stay cheap.
    # /dev/null keeps a file operand even when the glob matches nothing: without
    # one, grep would read stdin. Safe today only because nullglob is not set
    # here, which is too fragile a thing to depend on in a SessionStart hook.
    if grep -qF -- "<!--sid:$SESSION_ID" "$WORKLOG_DIR"/worklog-*.md /dev/null 2>/dev/null; then
        continue
    fi

    worklog_parse "$TRANSCRIPT" "$CONVO" || continue

    # A session with no real prompt is not work.
    [ "${WL_TURNS:-0}" -lt 1 ] && continue
    [ -n "${WL_WEEK:-}" ] || continue

    # Stricter than session-log.sh, deliberately. A reap pass writes many rows at
    # once, and a terminal opened and closed on one prompt registers zero active
    # minutes — noise as a backfill. Kept when there is either measurable time or
    # a real exchange.
    if [ "${WL_SPAN:-0}" -lt "$WORKLOG_REAP_MIN_MINUTES" ] && [ "${WL_TURNS:-0}" -lt 2 ]; then
        continue
    fi

    # Floor. ISO week strings compare correctly as plain strings.
    if [ -n "$WORKLOG_REAP_NOT_BEFORE" ] && [[ "$WL_WEEK" < "$WORKLOG_REAP_NOT_BEFORE" ]]; then
        continue
    fi

    # A week whose report already exists is closed; appending now would quietly
    # invalidate a timesheet you have already read.
    [ -f "$WORKLOG_DIR/weekly-report-$WL_WEEK.md" ] && continue

    # 0 = no dirty-tree fallback: this session died some time ago and the working
    # tree has moved on, so uncommitted files would describe other work.
    worklog_emit "$SESSION_ID" "$CONVO" 0
    WRITTEN=$((WRITTEN + 1))

    # Best effort: session-start.sh rewrites this file wholesale, so a concurrent
    # start can drop the edit. Harmless — the 48 h prune clears it regardless.
    sed -i "/^$SESSION_ID\t/d" "$WORKLOG_STATE_DIR/open-sessions.tsv" 2>/dev/null
done 3<<< "$CANDIDATES"

if [ "$WRITTEN" -gt 0 ] && [ "${WORKLOG_AUTO_SUMMARISE:-}" = "codex" ]; then
    bash "$DIR/summary-start.sh" >/dev/null 2>&1
fi

exit 0
