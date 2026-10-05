#!/usr/bin/env bash
# Render the per-day activity ledger:  activity.sh [max-weeks]
#
# Reads the per-day blocks already sitting in weekly-report-<week>.md, so it
# calls no model and touches no network. Weeks drafted before those blocks
# existed are named in the output rather than passed over in silence.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

mkdir -p "$WORKLOG_DIR"
OUT="${WORKLOG_ACTIVITY_FILE:-$WORKLOG_DIR/activity.html}"

python3 "$DIR/../lib/activity.py" \
    "$WORKLOG_DIR" "$OUT" "$WORKLOG_JIRA_BASE" "$WORKLOG_PROJECT_LINKS_FILE" "${1:-}"
