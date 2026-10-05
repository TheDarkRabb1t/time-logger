#!/usr/bin/env bash
# Runs outside the hook budget; fill-summaries owns the sidecar and row logic.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOG_LIB="$DIR/../lib"
. "$WORKLOG_LIB/common.sh"

exec 9>"$WORKLOG_STATE_DIR/codex-summary.lock" || exit 0
flock -n 9 || exit 0

[ -d "$WORKLOG_PENDING_DIR" ] || exit 0
bash "$DIR/../bin/fill-summaries.sh" >/dev/null 2>&1
