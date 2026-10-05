#!/usr/bin/env bash
# Codex hook helper: start the model worker without holding up the main thread.
set -uo pipefail

[ -n "${CLAUDE_WORKLOG_CHILD:-}" ] && exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOG_LIB="$DIR/../lib"
. "$WORKLOG_LIB/common.sh"

mkdir -p "$WORKLOG_STATE_DIR" 2>/dev/null || exit 0
RUNNER=(bash "$DIR/summary-worker.sh")
command -v setsid >/dev/null 2>&1 && RUNNER=(setsid "${RUNNER[@]}")
nohup env CLAUDE_WORKLOG_CHILD=1 WORKLOG_MODEL_BACKEND=codex \
    "${RUNNER[@]}" </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
