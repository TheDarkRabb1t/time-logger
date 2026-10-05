# Copy to ~/.claude/time-logger/config.sh. Values here win over the environment.

# Where worklog-<week>.md and weekly-report-<week>.md are written.
# Point this at a notes vault if you keep one.
WORKLOG_DIR="$HOME/.claude/time-logger/worklogs"

# Colon-separated roots scanned one level deep for git repos.
WORKLOG_PROJECT_DIRS="$HOME/projects:$HOME/src"

# Language for summaries and descriptions. Table headers stay English.
WORKLOG_LANG="English"

# Gaps longer than this many minutes are not counted as working time.
WORKLOG_IDLE_GAP_MIN=30

# Hours the drafted timesheet should add up to.
WORKLOG_TARGET_HOURS=40

WORKLOG_SUMMARY_MODEL="claude-haiku-4-5"
WORKLOG_REPORT_MODEL="claude-sonnet-5"

# Codex sessions are scanned in addition to Claude sessions. Codex's skill
# selects its own model backend when generating summaries and reports.
# WORKLOG_CODEX_TRANSCRIPT_DIR="$HOME/.codex/sessions"
# WORKLOG_MODEL_BACKEND="codex"
# WORKLOG_CODEX_MODEL="gpt-6-sol"  # unset to use your Codex default

# Jira is optional and skipped entirely when WORKLOG_JIRA_BASE is empty.
# Auth file holds one line, "email:api-token", chmod 600.
# A scoped read-only token is enough: read:jql:jira, read:issue:jira,
# read:issue-details:jira, read:project:jira, read:user:jira.
# WORKLOG_JIRA_BASE="https://your-org.atlassian.net"
# WORKLOG_JIRA_AUTH_FILE="$HOME/.claude/time-logger/jira-auth"

# Calendar is optional and skipped entirely when the auth file is missing.
# Run bin/cal-auth.py once to create it (Desktop-app OAuth client, Calendar API
# enabled, scope calendar.events.readonly). See the README.
# WORKLOG_CAL_AUTH_FILE="$HOME/.claude/time-logger/cal-auth"
# Colon-separated calendar ids; `primary` is the one behind your own address.
# WORKLOG_CAL_IDS="primary"
# Only meetings this long or longer - planning, retro and demo clear 45 min,
# a daily standup does not.
# WORKLOG_CAL_MIN_MINUTES=45
# And no longer than this, so all-day markers and OOO blocks stay out.
# WORKLOG_CAL_MAX_MINUTES=480
# WORKLOG_CAL_SKIP_DECLINED=1

# Or skip Google Cloud entirely: a file of iCal feed URLs, one per line, from
# Calendar -> Settings and sharing -> Integrate calendar -> "Secret address in
# iCal format". Wins over the OAuth file when both exist. Needs python3-dateutil.
# WORKLOG_CAL_ICS_FILE="$HOME/.claude/time-logger/cal-ics"
