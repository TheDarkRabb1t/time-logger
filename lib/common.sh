#!/usr/bin/env bash
# Config and defaults, sourced by the hooks and by bin/fill-summaries.sh.
# A value set in config.sh wins over the environment.

WORKLOG_HOME="${WORKLOG_HOME:-$HOME/.claude/time-logger}"
[ -f "$WORKLOG_HOME/config.sh" ] && . "$WORKLOG_HOME/config.sh"

: "${WORKLOG_STATE_DIR:=$WORKLOG_HOME}"
: "${WORKLOG_DIR:=$WORKLOG_HOME/worklogs}"
: "${WORKLOG_PROJECT_DIRS:=$HOME/projects:$HOME/src:$HOME/code:$HOME/dev:$HOME/git}"
: "${WORKLOG_LANG:=English}"
: "${WORKLOG_IDLE_GAP_MIN:=30}"
: "${WORKLOG_TARGET_HOURS:=40}"
: "${WORKLOG_SUMMARY_MODEL:=claude-haiku-4-5}"
: "${WORKLOG_REPORT_MODEL:=claude-sonnet-5}"
: "${WORKLOG_SUMMARY_TIMEOUT:=55}"
: "${WORKLOG_REPORT_TIMEOUT:=600}"
: "${WORKLOG_JIRA_BASE:=}"
: "${WORKLOG_JIRA_AUTH_FILE:=$WORKLOG_STATE_DIR/jira-auth}"
: "${WORKLOG_MAP_FILE:=$WORKLOG_STATE_DIR/repo-project.map}"
# Optional: <PROJECT-KEY><TAB><backlog URL>, one per line. Rows with no ticket
# link to their project's backlog; a project absent here gets no link at all,
# since a guessed Jira URL that 404s is worse than plain text.
: "${WORKLOG_PROJECT_LINKS_FILE:=$WORKLOG_STATE_DIR/project-links.map}"
# Where /activity writes its page. Kept separate from WORKLOG_DIR because the
# worklogs belong in a notes vault and a rendered HTML file usually does not.
: "${WORKLOG_ACTIVITY_FILE:=$WORKLOG_DIR/activity.html}"

# --- calendar (optional) ---
# Meetings are the one part of the week that leaves no trace in git and no
# session row. Skipped entirely when the auth file is missing, the same way
# Jira is skipped without WORKLOG_JIRA_BASE. bin/cal-auth.py writes the file;
# it holds a client id, a secret and a refresh token, so it stays chmod 600.
: "${WORKLOG_CAL_AUTH_FILE:=$WORKLOG_STATE_DIR/cal-auth}"
# Colon-separated calendar ids. `primary` is the one behind your own address.
: "${WORKLOG_CAL_IDS:=primary}"
# Only meetings at least this long. Planning, retro and demo clear it; a daily
# standup does not, and neither does a five-minute reminder.
: "${WORKLOG_CAL_MIN_MINUTES:=45}"
# Upper bound drops all-day markers, holidays and OOO blocks, which would
# otherwise swamp the week with hours nobody spent in a meeting.
: "${WORKLOG_CAL_MAX_MINUTES:=480}"
# Skip events you answered `no` to. Set to 0 to count them anyway.
: "${WORKLOG_CAL_SKIP_DECLINED:=1}"
# The other way in: a file of Google Calendar "secret address in iCal format"
# URLs, one per line. Needs no Cloud project, no OAuth client and no admin, so
# it is the way through when the console is closed to you. Takes precedence
# over the auth file when both exist. Needs python3-dateutil.
: "${WORKLOG_CAL_ICS_FILE:=$WORKLOG_STATE_DIR/cal-ics}"

: "${WORKLOG_TRANSCRIPT_DIR:=$HOME/.claude/projects}"
: "${WORKLOG_CODEX_TRANSCRIPT_DIR:=$HOME/.codex/sessions}"
: "${WORKLOG_MODEL_BACKEND:=claude}"
: "${WORKLOG_CODEX_MODEL:=}"
# Codex sets PLUGIN_ROOT as well as CLAUDE_PLUGIN_ROOT. Claude Code only sets
# the latter, so its deferred-summary workflow stays unchanged.
: "${WORKLOG_AUTO_SUMMARISE:=${PLUGIN_ROOT:+codex}}"
# How long a hook waits for its JSON payload on stdin before giving up. The
# harness closes stdin, so the normal path returns at EOF without ever waiting;
# this only bounds a caller that holds the pipe open and sends nothing.
: "${WORKLOG_STDIN_TIMEOUT:=2}"

# --- deferred summaries ---
# Rows are written with s:0 and a sidecar holding the digest. A detached Codex
# hook worker or `/timelog` turns those into prose.
: "${WORKLOG_PENDING_DIR:=$WORKLOG_STATE_DIR/pending}"
# How far back /timelog will still summarise a sidecar. Beyond this it is pruned
# unprocessed — /timelog status reports the count rather than dropping it quietly.
: "${WORKLOG_SUMMARY_LOOKBACK_DAYS:=60}"

# --- reaper (worklog-reap.sh) ---
# How far back to consider transcripts at all. Claude Code prunes its own
# transcripts around 30 days, so anything past that is a ceiling, not a floor —
# the sidecar is what makes summaries outlive it.
: "${WORKLOG_REAP_LOOKBACK_DAYS:=60}"
# Quiet for this long and the session is treated as dead. Long enough that a
# session idle overnight is not reaped out from under you.
: "${WORKLOG_REAP_STALE_HOURS:=12}"
# Never reap a week earlier than this, whatever the lookback allows. Stops a
# first run from retroactively inventing worklogs for months you never tracked.
: "${WORKLOG_REAP_NOT_BEFORE:=}"
# Rows per pass, a runaway backstop rather than a pacing knob now that reaping
# costs no model calls.
: "${WORKLOG_REAP_MAX_PER_RUN:=200}"
# A terminal opened and closed on a single prompt registers zero minutes. As a
# backfill that is noise. Set to 0 to log it anyway.
: "${WORKLOG_REAP_MIN_MINUTES:=1}"

WORKLOG_TABLE_HEADER="| Date | Day | Workdir | Branch | Min | Turns | What was done | Files | Commits |"
WORKLOG_TABLE_RULE="|---|---|---|---|---|---|---|---|---|"

# Label for the Workdir column: the repository root, plus the path below it when
# the session was started in a subdirectory. basename(cwd) alone is wrong there —
# org/example-repo would label itself
# `example-repo`, miss the repo->project map and fall into
# the untracked bucket. The map matches on the first segment.
worklog_workdir() {
    local cwd="$1" top rel
    [ -n "$cwd" ] || { printf '%s' "-"; return; }

    top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$top" ]; then
        rel="${cwd#"$top"}"; rel="${rel#/}"
        printf '%s' "$(basename "$top")${rel:+/$rel}"
        return
    fi

    # Not a repository: a home-relative path still says something useful,
    # where a bare basename like `user` or `Downloads` does not.
    case "$cwd" in
        "$HOME") printf '%s' "~" ;;
        "$HOME"/*) printf '~/%s' "${cwd#"$HOME"/}" ;;
        *) printf '%s' "$cwd" ;;
    esac
}

# How many rows in a week file still need a summary.
worklog_pending_count() {
    ls -1 "$WORKLOG_PENDING_DIR"/*.txt 2>/dev/null | grep -c . 2>/dev/null
}
