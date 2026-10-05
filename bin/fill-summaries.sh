#!/usr/bin/env bash
# Turn pending sidecars into row summaries.  fill-summaries.sh [week]
#
# Invoked by /timelog and by a detached Codex hook worker. With no argument it
# processes every sidecar; with an ISO week it processes only that week's rows.
#
# A sidecar holds the digest of one session, written at SessionEnd (or by the
# reaper). It exists precisely so a summary can still be generated after Claude
# Code prunes the transcript at ~30 days. It is deleted the moment its row is
# filled, so the directory is a work queue rather than an archive.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOG_LIB="$DIR/../lib"
. "$WORKLOG_LIB/common.sh"
. "$WORKLOG_LIB/model.sh"

WEEK_FILTER="${1:-}"

[ -d "$WORKLOG_PENDING_DIR" ] || { echo "nothing pending"; exit 0; }

# --- prune what can no longer be honoured -----------------------------------
# Reported rather than dropped in silence: an expired sidecar means a row that
# will read _(pending)_ forever.
EXPIRED=$(find "$WORKLOG_PENDING_DIR" -maxdepth 1 -name '*.txt' \
               -mtime +"$WORKLOG_SUMMARY_LOOKBACK_DAYS" 2>/dev/null)
if [ -n "$EXPIRED" ]; then
    N=$(printf '%s\n' "$EXPIRED" | grep -c .)
    printf 'pruning %s sidecar(s) older than %s days — those rows stay unsummarised\n' \
        "$N" "$WORKLOG_SUMMARY_LOOKBACK_DAYS"
    printf '%s\n' "$EXPIRED" | xargs -r rm -f
fi

FILLED=0; FAILED=0; SKIPPED=0

# A glob, not `while read`: `claude -p` drains stdin even when the prompt is an
# argument, so a stdin-fed loop would lose every item after the first.
shopt -s nullglob
for CARD in "$WORKLOG_PENDING_DIR"/*.txt; do
    SESSION_ID=$(basename "$CARD" .txt)

    # The row is the source of truth for which week this belongs to; the sidecar
    # is only the raw material.
    # /dev/null is load-bearing: nullglob is on, so with no worklog files the
    # glob vanishes and grep, left without file operands, reads stdin instead -
    # blocking for the life of whatever pipe the caller happened to hold open.
    ROW=$(grep -hF -- "<!--sid:$SESSION_ID" "$WORKLOG_DIR"/worklog-*.md /dev/null 2>/dev/null | head -1)
    if [ -z "$ROW" ]; then
        # No row: the week file was deleted, or the row was pruned by hand.
        rm -f "$CARD"
        continue
    fi
    case "$ROW" in
        *";s:1-->"*) rm -f "$CARD"; continue ;;   # already summarised elsewhere
    esac
    if [ -n "$WEEK_FILTER" ]; then
        ROW_WEEK=$(grep -lF -- "<!--sid:$SESSION_ID" "$WORKLOG_DIR"/worklog-*.md /dev/null 2>/dev/null | head -1)
        ROW_WEEK=$(basename "${ROW_WEEK:-}" .md); ROW_WEEK="${ROW_WEEK#worklog-}"
        if [ "$ROW_WEEK" != "$WEEK_FILTER" ]; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    fi

    WORKDIR=$(sed -n 's/^workdir: //p' "$CARD" | head -1)
    BRANCH=$(sed -n 's/^branch: //p' "$CARD" | head -1)
    COMMITS=$(sed -n 's/^commits: //p' "$CARD" | head -1)

    PROMPT="You keep a developer's work journal.

Below is an extract from a coding session (working directory: $WORKDIR, branch: $BRANCH).
Commits during the session: ${COMMITS:-none}

Write EXACTLY 2 short sentences on what was concretely done.

Rules:
- write in $WORKLOG_LANG, but keep technical terms in English
- be specific about what changed and where, not generic
- no preamble, no markdown, no lists — two sentences on one line

$(sed -n '/^---$/,$p' "$CARD" | tail -n +2)"

    # CLAUDE_WORKLOG_CHILD stops this child session from logging itself.
    RAW_SUMMARY=$(worklog_model "$WORKLOG_SUMMARY_MODEL" "$PROMPT" "$WORKLOG_SUMMARY_TIMEOUT")
    RC=$?
    SUMMARY=$(printf '%s' "$RAW_SUMMARY" | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')

    # `claude -p` prints its failures to stdout and exits non-zero — "Not logged
    # in", a usage limit, a network error. Without checking the status those land
    # in the table as though they were the summary. The sidecar is kept so the
    # row is retried next run rather than being stuck with the error text.
    if [ "$RC" -ne 0 ] || [ -z "$SUMMARY" ] || [ "$SUMMARY" = "Execution error" ]; then
        FAILED=$((FAILED + 1))
        continue
    fi

    if [ -n "$(python3 "$WORKLOG_LIB/fill_row.py" "$WORKLOG_DIR" "$SESSION_ID" "$SUMMARY")" ]; then
        rm -f "$CARD"
        FILLED=$((FILLED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
done
shopt -u nullglob

REMAINING=$(worklog_pending_count)
printf 'filled %s, failed %s, skipped %s, still pending %s\n' \
    "$FILLED" "$FAILED" "$SKIPPED" "${REMAINING:-0}"
exit 0
