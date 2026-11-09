#!/usr/bin/env bash

# worklog_model <summary|report> <prompt> <timeout_sec>
# Prints the model's answer; the exit status is the backend's. Each backend
# picks its own model for the purpose, since model ids do not carry across.
worklog_model() {
    local purpose="$1" prompt="$2" timeout_sec="$3" output rc model
    case "$WORKLOG_MODEL_BACKEND" in
    codex)
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
        ;;
    omp)
        model="$WORKLOG_OMP_SUMMARY_MODEL"
        [ "$purpose" = "report" ] && model="$WORKLOG_OMP_REPORT_MODEL"
        # A bare completion: no session file for the reaper to find, no tools,
        # and none of the extensions, skills, rules or context files that would
        # load this plugin again or pad the prompt. Run from the state dir so a
        # project's .omp config cannot leak in.
        ( cd "$WORKLOG_HOME" 2>/dev/null || cd /
          CLAUDE_WORKLOG_CHILD=1 timeout "$timeout_sec" \
              omp -p --no-session --no-title --no-tools --no-extensions --no-skills \
                  --no-rules --no-context-files --model "$model" "$prompt" </dev/null 2>/dev/null )
        ;;
    *)
        model="$WORKLOG_SUMMARY_MODEL"
        [ "$purpose" = "report" ] && model="$WORKLOG_REPORT_MODEL"
        CLAUDE_WORKLOG_CHILD=1 timeout "$timeout_sec" \
            claude -p --model "$model" "$prompt" </dev/null 2>/dev/null
        ;;
    esac
}
