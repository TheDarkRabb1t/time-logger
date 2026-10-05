#!/usr/bin/env bash
# Row writing, shared by session-log.sh (clean exit) and worklog-reap.sh (the
# session died). Both must produce identical rows for the same transcript, since
# either may be the one that gets there first.
#
# Neither calls a model. The row carries the facts, which are only recoverable
# while the transcript exists; the prose is deferred to `/timelog`, which reads
# the sidecar this writes. That is what keeps SessionEnd at milliseconds instead
# of the 16-34 s a summary call costs.

# worklog_parse <transcript> <convo_out_file>
# Fills WL_CWD, WL_BRANCH, WL_SPAN, WL_TURNS, WL_DATE, WL_DAY, WL_WEEK,
# WL_FIRST_TS, WL_LAST_TS, WL_INTERVALS and writes the digest to <convo_out>.
# Returns 1 when the transcript yields nothing usable.
worklog_parse() {
    local transcript="$1" convo_out="$2" shellvars
    shellvars=$(python3 "$WORKLOG_LIB/extract.py" "$transcript" \
                    "$WORKLOG_IDLE_GAP_MIN" --shell --convo-out "$convo_out" 2>/dev/null)
    [ -z "$shellvars" ] && return 1
    eval "$shellvars"
    return 0
}

# worklog_emit <session_id> <convo_file> <allow_dirty_diff>
# Writes the pending sidecar and appends the row. allow_dirty_diff=1 lets an
# uncommitted working tree stand in for commits — right at SessionEnd, wrong for
# a reaped session whose tree has since moved on to other work.
worklog_emit() {
    local sid="$1" convo="$2" allow_dirty="${3:-0}"
    local workdir commits="" files="" all_files nfiles email log

    workdir=$(worklog_workdir "$WL_CWD")
    email=$(git config --global user.email 2>/dev/null || echo "")

    if [ -n "$WL_CWD" ] && git -C "$WL_CWD" rev-parse --git-dir >/dev/null 2>&1; then
        commits=$(git -C "$WL_CWD" log --author="$email" \
                    --since="$WL_FIRST_TS" --until="$WL_LAST_TS" \
                    --format='%h %s' 2>/dev/null | cut -c1-62 | head -6 | tr '\n' ';' | sed 's/;$//')

        # Basenames only — full paths make the table unreadable and the commit
        # subjects already carry the "where".
        all_files=$(git -C "$WL_CWD" log --author="$email" \
                      --since="$WL_FIRST_TS" --until="$WL_LAST_TS" \
                      --name-only --format='' 2>/dev/null | grep -v '^$' | sort -u)
        [ -z "$all_files" ] && [ "$allow_dirty" = "1" ] && \
            all_files=$(git -C "$WL_CWD" diff --name-only HEAD 2>/dev/null)
        # No `|| echo 0`: grep -c already prints 0, and its non-zero exit would
        # append a second line, leaving the test below to bail with "integer
        # expression expected" and silently blank the Files column.
        nfiles=$(printf '%s\n' "$all_files" | grep -c . 2>/dev/null)
        if [ "${nfiles:-0}" -gt 0 ]; then
            files=$(printf '%s\n' "$all_files" | xargs -r -n1 basename 2>/dev/null \
                    | sort -u | head -6 | tr '\n' ' ')
            [ "$nfiles" -gt 6 ] && files="$files(+$((nfiles - 6)) more)"
        fi
    fi

    # The sidecar is the work queue for /timelog. It holds everything the
    # summariser needs, so a row stays summarisable after Claude Code prunes the
    # transcript at ~30 days. Deleted the moment the summary lands.
    mkdir -p "$WORKLOG_PENDING_DIR" 2>/dev/null
    {
        printf 'workdir: %s\n' "$workdir"
        printf 'branch: %s\n' "$WL_BRANCH"
        printf 'commits: %s\n' "${commits:-none}"
        printf -- '---\n'
        cat "$convo" 2>/dev/null
    } > "$WORKLOG_PENDING_DIR/$sid.txt"

    log="$WORKLOG_DIR/worklog-$WL_WEEK.md"
    if [ ! -f "$log" ]; then
        { echo "# Worklog — $WL_WEEK"; echo; echo "$WORKLOG_TABLE_HEADER"; echo "$WORKLOG_TABLE_RULE"; } > "$log"
    fi

    # A resumed session fires SessionEnd again with a cumulative minute count, so
    # appending would book the same work twice. Drop this session's previous row
    # first — including one the reaper wrote. Matching the id prefix rather than
    # the whole marker keeps this working whatever trails it; a session id is
    # unique enough that nothing else can collide.
    sed -i "/<!--sid:$sid/d" "$WORKLOG_DIR"/worklog-*.md 2>/dev/null

    # s:0 means "no summary yet". A row that fails to summarise stays s:0 and is
    # retried; the old design wrote a placeholder with a plain marker, which the
    # reaper then skipped forever.
    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s <!--sid:%s;iv:%s;s:0--> |\n' \
        "$WL_DATE" "$WL_DAY" "${workdir//|/;}" "${WL_BRANCH//|/;}" "$WL_SPAN" "$WL_TURNS" \
        "_(pending)_" "${files:--}" "${commits:--}" "$sid" "$WL_INTERVALS" >> "$log"
}
