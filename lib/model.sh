#!/usr/bin/env bash

worklog_model() {
    local model="$1" prompt="$2" timeout_sec="$3" output rc
    if [ "$WORKLOG_MODEL_BACKEND" = "codex" ]; then
        output=$(mktemp) || return 1
        local args=(exec --ephemeral --sandbox read-only -c approval_policy=never --skip-git-repo-check
                    -C "$WORKLOG_HOME" -o "$output")
        [ -n "$WORKLOG_CODEX_MODEL" ] && args+=(-m "$WORKLOG_CODEX_MODEL")
        CLAUDE_WORKLOG_CHILD=1 timeout "$timeout_sec" \
            codex "${args[@]}" "$prompt" </dev/null >/dev/null 2>&1
        rc=$?
        [ "$rc" -eq 0 ] && cat "$output"
        rm -f "$output"
        return "$rc"
    fi
    CLAUDE_WORKLOG_CHILD=1 timeout "$timeout_sec" \
        claude -p --model "$model" "$prompt" </dev/null 2>/dev/null
}
