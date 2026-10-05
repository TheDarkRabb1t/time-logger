#!/usr/bin/env bash
# Sandbox tests for the hooks and bin/fill-summaries.sh. Builds a throwaway
# HOME, synthesises transcripts, stubs `claude`, and asserts on the rows, the
# sidecars and the report context. Never calls a real model; touches nothing
# outside $ROOT.
#
#   bash tests/simtest.sh

ROOT="${TMPDIR:-/tmp}/time-logger-simtest"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
REAP="$REPO/hooks/worklog-reap.sh"
LOG_HOOK="$REPO/hooks/session-log.sh"
START_HOOK="$REPO/hooks/session-start.sh"
FILL="$REPO/bin/fill-summaries.sh"
REPORT="$REPO/hooks/weekly-report.sh"
PASS=0; FAIL=0

# --- helpers ----------------------------------------------------------------

setup() {
    rm -rf "$ROOT"
    SIM="$ROOT/home"
    WL="$SIM/vault/My Notes"        # a space, as a vault path usually has
    PEND="$SIM/.claude/time-logger/pending"
    mkdir -p "$SIM/.claude/projects/proj" "$SIM/.claude/time-logger" "$WL" "$ROOT/bin"
    cat > "$SIM/.claude/time-logger/config.sh" <<EOF
WORKLOG_DIR="\$HOME/vault/My Notes"
WORKLOG_IDLE_GAP_MIN=30
EOF
    printf '[user]\n\temail = sim@example.com\n' > "$SIM/.gitconfig"
    stub_claude "Refactored the thing. Added tests."
}

stub_claude() {
    # Drains stdin first, as the real `claude -p` does even when the prompt is an
    # argument. Without this a caller looping on stdin looks fine here and eats
    # its own input in production.
    { printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1\n'
      printf 'printf %%s\\\\n %q\n' "$1"; } > "$ROOT/bin/claude"
    chmod +x "$ROOT/bin/claude"
}

stub_claude_failing() {
    printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1\necho "%s"\nexit 1\n' "$1" > "$ROOT/bin/claude"
    chmod +x "$ROOT/bin/claude"
}

# mktranscript <name> <age_hours> <spec...>
# "u:<iso>" real prompt, "a:<iso>" assistant, "t:<iso>" tool result (role user,
# no promptSource), "s:<iso>" sidechain, "x" malformed line
mktranscript() {
    local name="$1" age="$2"; shift 2
    local f="$SIM/.claude/projects/proj/$name.jsonl"
    : > "$f"
    for spec in "$@"; do
        local kind="${spec%%:*}" ts="${spec#*:}"
        case "$kind" in
        u) printf '{"type":"user","promptSource":"user","timestamp":"%s","cwd":"%s","gitBranch":"feat/x","message":{"content":"do the thing"}}\n' "$ts" "$SIM/repo" >> "$f" ;;
        a) printf '{"type":"assistant","timestamp":"%s","cwd":"%s","gitBranch":"feat/x","message":{"content":[{"type":"text","text":"did the thing"}]}}\n' "$ts" "$SIM/repo" >> "$f" ;;
        t) printf '{"type":"user","timestamp":"%s","cwd":"%s","message":{"content":[{"type":"tool_result","content":"out"}]}}\n' "$ts" "$SIM/repo" >> "$f" ;;
        s) printf '{"type":"user","promptSource":"user","isSidechain":true,"timestamp":"%s","cwd":"%s","message":{"content":"subagent"}}\n' "$ts" "$SIM/repo" >> "$f" ;;
        x) printf 'this is not json{{{\n' >> "$f" ;;
        esac
    done
    touch -d "$age hours ago" "$f"
}

run()          { HOME="$SIM" PATH="$ROOT/bin:$PATH" WORKLOG_REAP_INLINE=1 bash "$REAP"; }
run_detached() { HOME="$SIM" PATH="$ROOT/bin:$PATH" bash "$REAP"; }
fill()         { HOME="$SIM" PATH="$ROOT/bin:$PATH" bash "$FILL" "$@"; }
end_session()  {
    printf '{"transcript_path":"%s","session_id":"%s"}' \
        "$SIM/.claude/projects/proj/$1.jsonl" "$1" \
        | HOME="$SIM" PATH="$ROOT/bin:$PATH" bash "$LOG_HOOK"
}

rows()     { cat "$WL"/worklog-*.md 2>/dev/null | grep -c '<!--sid:' || true; }
pending()  { ls -1 "$PEND"/*.txt 2>/dev/null | grep -c . || true; }
logtext()  { cat "$WL"/worklog-*.md 2>/dev/null; }
cell()     { logtext | grep '<!--sid:' | awk -F'|' -v n="$1" '{gsub(/^ +| +$/,"",$n); print $n}'; }

ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
is()  { [ "$2" = "$3" ] && ok "$1" || no "$1" "expected [$3] got [$2]"; }
iso() { date -d "$1" -Iseconds; }

# ============================================================ reaper (no model)

echo "== 1. a stale session yields a pending row and a sidecar =="
setup
mktranscript dead-1 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +2 min')" "u:$(iso '25 hours ago +5 min')" "a:$(iso '25 hours ago +9 min')"
run
is "row written" "$(rows)" "1"
is "summary is pending" "$(cell 8)" "_(pending)_"
is "sidecar written" "$(pending)" "1"
is "active minutes" "$(cell 6)" "9"
logtext | grep -qE '<!--sid:dead-1;iv:[0-9]+-[0-9]+;s:0-->' && ok "marker carries intervals and s:0" || no "marker" "$(logtext|tail -1)"
grep -q '^workdir: ' "$PEND/dead-1.txt" && grep -q '^branch: feat/x' "$PEND/dead-1.txt" && ok "sidecar header" || no "sidecar header"

echo "== 2. the reaper needs no model at all =="
setup
mktranscript dead-2 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +4 min')"
HOME="$SIM" PATH="/usr/bin:/bin" WORKLOG_REAP_INLINE=1 bash "$REAP"    # no `claude` on PATH
is "row written without claude" "$(rows)" "1"
is "sidecar written without claude" "$(pending)" "1"

echo "== 3. several orphans in ONE pass =="
setup
for n in 1 2 3 4; do mktranscript "many-$n" 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +4 min')"; done
run
is "all four reaped" "$(rows)" "4"

echo "== 4. live session untouched; re-running does not duplicate =="
setup
mktranscript alive 2 "u:$(iso '2 hours ago')" "a:$(iso '2 hours ago +3 min')"
mktranscript dead-4 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +4 min')"
run; run; run
is "one row only" "$(rows)" "1"
is "one sidecar only" "$(pending)" "1"

echo "== 5. nothing to log: no prompt, sidechain, empty, truncated =="
setup
mktranscript toolonly 24 "t:$(iso '25 hours ago')" "a:$(iso '25 hours ago +2 min')"
mktranscript sidechain 24 "s:$(iso '25 hours ago')" "s:$(iso '25 hours ago +5 min')"
mktranscript empty 24
mktranscript trunc 24 "x"
run
is "no rows" "$(rows)" "0"
is "no sidecars" "$(pending)" "0"

echo "== 6. malformed lines do not abort the parse =="
setup
mktranscript dead-6 24 "u:$(iso '25 hours ago')" "x" "a:$(iso '25 hours ago +6 min')" "x"
run
is "row written despite garbage" "$(rows)" "1"

echo "== 7. an existing marker anywhere blocks a second row =="
setup
mktranscript dead-7 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +4 min')"
printf '| x | x | x | x | 1 | 1 | prior | - | - <!--sid:dead-7;iv:1-2;s:1--> |\n' > "$WL/worklog-1999-W01.md"
run
is "not re-logged" "$(rows)" "1"

echo "== 8. a week that already has a report is closed =="
setup
mktranscript dead-8 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +4 min')"
echo "report" > "$WL/weekly-report-$(date -d '25 hours ago' +%G-W%V).md"
run
is "reported week untouched" "$(rows)" "0"

echo "== 9. idle gaps over 30 min are excluded =="
setup
mktranscript gappy 24 "u:$(iso '30 hours ago')" "a:$(iso '30 hours ago +5 min')" "u:$(iso '26 hours ago')" "a:$(iso '26 hours ago +5 min')"
run
is "4 h gap dropped, 10 min kept" "$(cell 6)" "10"
is "two intervals recorded" "$(logtext | grep -o 'iv:[0-9,-]*' | tr ',' '\n' | grep -c '[0-9]-[0-9]')" "2"

echo "== 10. a session crossing midnight books both dates =="
setup
mktranscript midnight 24 "u:$(iso 'yesterday 23:40')" "a:$(iso 'yesterday 23:50')" "u:$(iso 'today 00:10')" "a:$(iso 'today 00:20')"
run
logtext | grep -qE '\| [0-9]{2}-[0-9]{2}->[0-9]{2}-[0-9]{2} \|' && ok "date rendered as range" || no "date range" "$(logtext|tail -1)"

echo "== 11. concurrency, stale lock, detach =="
setup
mktranscript dead-11 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +4 min')"
for i in 1 2 3 4 5; do run_detached & done; wait; sleep 3
is "lock held, one row" "$(rows)" "1"
setup
mktranscript dead-11b 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +4 min')"
mkdir -p "$SIM/.claude/time-logger/reap.lock"; touch -d "2 hours ago" "$SIM/.claude/time-logger/reap.lock"
run_detached; sleep 3
is "stale lock broken" "$(rows)" "1"
[ -d "$SIM/.claude/time-logger/reap.lock" ] && no "lock released" || ok "lock released"
setup
for n in 1 2 3 4 5 6; do mktranscript "d-$n" 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +4 min')"; done
T0=$(date +%s%N); run_detached; T1=$(date +%s%N); MS=$(( (T1-T0)/1000000 ))
[ "$MS" -lt 500 ] && ok "foreground returned in ${MS}ms" || no "foreground blocked ${MS}ms"
sleep 6
is "all six reaped in background" "$(rows)" "6"

echo "== 12. guards: child invocation, missing transcript dir, lookback =="
setup
mktranscript dead-12 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +4 min')"
HOME="$SIM" PATH="$ROOT/bin:$PATH" CLAUDE_WORKLOG_CHILD=1 WORKLOG_REAP_INLINE=1 bash "$REAP"
is "child invocation is a no-op" "$(rows)" "0"
setup; rm -rf "$SIM/.claude/projects"; run; is "missing dir: clean exit" "$?" "0"
setup; mktranscript ancient 2000 "u:$(iso '80 days ago')" "a:$(iso '80 days ago +4 min')"; run
is "80-day transcript ignored" "$(rows)" "0"

echo "== 13. floor, cap, trivial-session filter =="
setup
mktranscript trivial 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago')"
run; is "0-min 1-turn skipped" "$(rows)" "0"
WORKLOG_REAP_MIN_MINUTES=0 HOME="$SIM" PATH="$ROOT/bin:$PATH" WORKLOG_REAP_INLINE=1 bash "$REAP"
is "opt-in logs it" "$(rows)" "1"
setup; mktranscript f1 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +4 min')"
WORKLOG_REAP_NOT_BEFORE=2099-W01 HOME="$SIM" PATH="$ROOT/bin:$PATH" WORKLOG_REAP_INLINE=1 bash "$REAP"
is "below the floor, skipped" "$(rows)" "0"
setup; for n in 1 2 3 4 5; do mktranscript "c-$n" 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +4 min')"; done
WORKLOG_REAP_MAX_PER_RUN=2 HOME="$SIM" PATH="$ROOT/bin:$PATH" WORKLOG_REAP_INLINE=1 bash "$REAP"
is "cap honoured" "$(rows)" "2"

echo "== 14. open-sessions stub cleared, others kept =="
setup
mktranscript dead-14 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +4 min')"
printf 'dead-14\t%s\t%s\tfeat/x\nother\t%s\t%s\tmain\n' \
  "$(iso '25 hours ago')" "$SIM/repo" "$(iso '25 hours ago')" "$SIM/repo" \
  > "$SIM/.claude/time-logger/open-sessions.tsv"
run
is "own stub dropped" "$(grep -c '^dead-14' "$SIM/.claude/time-logger/open-sessions.tsv")" "0"
is "other stub kept" "$(grep -c '^other' "$SIM/.claude/time-logger/open-sessions.tsv")" "1"

# ============================================================ workdir labelling

echo "== 15. subdirectory sessions label repo/subpath =="
setup
mkdir -p "$SIM/repo/sub/deep"
git -C "$SIM/repo" init -q; git -C "$SIM/repo" config user.email sim@example.com
git -C "$SIM/repo" config user.name sim
echo hi > "$SIM/repo/f.txt"; git -C "$SIM/repo" add -A; git -C "$SIM/repo" commit -qm init
f="$SIM/.claude/projects/proj/sub.jsonl"
printf '{"type":"user","promptSource":"user","timestamp":"%s","cwd":"%s","gitBranch":"main","message":{"content":"go"}}\n' "$(iso '25 hours ago')" "$SIM/repo/sub/deep" > "$f"
printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"content":[{"type":"text","text":"ok"}]}}\n' "$(iso '25 hours ago +4 min')" "$SIM/repo/sub/deep" >> "$f"
touch -d "24 hours ago" "$f"
run
is "workdir is repo/subpath" "$(cell 4)" "repo/sub/deep"

echo "== 16. a non-repo directory is home-relative =="
setup
mkdir -p "$SIM/Downloads"
f="$SIM/.claude/projects/proj/dl.jsonl"
printf '{"type":"user","promptSource":"user","timestamp":"%s","cwd":"%s","message":{"content":"go"}}\n' "$(iso '25 hours ago')" "$SIM/Downloads" > "$f"
printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"content":[{"type":"text","text":"ok"}]}}\n' "$(iso '25 hours ago +4 min')" "$SIM/Downloads" >> "$f"
touch -d "24 hours ago" "$f"
run
is "workdir is ~-relative" "$(cell 4)" "~/Downloads"

# ============================================================ SessionEnd

echo "== 17. a clean exit writes a pending row plus sidecar =="
setup
mktranscript live-1 0 "u:$(iso '2 hours ago')" "a:$(iso '2 hours ago +3 min')" "u:$(iso '2 hours ago +6 min')" "a:$(iso '2 hours ago +11 min')"
end_session live-1
is "row written" "$(rows)" "1"
is "pending summary" "$(cell 8)" "_(pending)_"
is "sidecar written" "$(pending)" "1"
is "active minutes" "$(cell 6)" "11"

echo "== 18. SessionEnd never touches a model =="
setup
mktranscript live-2 0 "u:$(iso '2 hours ago')" "a:$(iso '2 hours ago +5 min')"
# a `claude` that would hang for a minute if anything called it
printf '#!/usr/bin/env bash\nsleep 60\n' > "$ROOT/bin/claude"; chmod +x "$ROOT/bin/claude"
T0=$(date +%s%N); end_session live-2; T1=$(date +%s%N); MS=$(( (T1-T0)/1000000 ))
[ "$MS" -lt 1000 ] && ok "returned in ${MS}ms" || no "blocked ${MS}ms — something called the model"
is "row still written" "$(rows)" "1"
setup
mktranscript live-2b 0 "u:$(iso '2 hours ago')" "a:$(iso '2 hours ago +5 min')"
printf '{"transcript_path":"%s","session_id":"live-2b"}' "$SIM/.claude/projects/proj/live-2b.jsonl" \
  | HOME="$SIM" PATH="/usr/bin:/bin" bash "$LOG_HOOK"
is "works with no claude on PATH" "$(rows)" "1"

echo "== 19. resume replaces its own row; clean exit supersedes the reaper's =="
setup
mktranscript live-3 0 "u:$(iso '3 hours ago')" "a:$(iso '3 hours ago +5 min')"
end_session live-3
mktranscript live-3 0 "u:$(iso '3 hours ago')" "a:$(iso '3 hours ago +5 min')" "u:$(iso '3 hours ago +10 min')" "a:$(iso '3 hours ago +20 min')"
end_session live-3
is "one row" "$(rows)" "1"
is "minutes updated" "$(cell 6)" "20"
is "one sidecar" "$(pending)" "1"
setup
mktranscript live-4 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +7 min')"
run; is "reaper wrote it" "$(rows)" "1"
end_session live-4
is "still one row" "$(rows)" "1"

echo "== 20. both writers emit the same row for the same transcript =="
setup
mktranscript live-5 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +8 min')" "u:$(iso '25 hours ago +12 min')" "a:$(iso '25 hours ago +15 min')"
run
REAPED=$(logtext | grep '<!--sid:live-5')
rm -f "$WL"/worklog-*.md "$PEND"/*.txt
end_session live-5
is "rows identical" "$(logtext | grep '<!--sid:live-5')" "$REAPED"

echo "== 21. zero-turn writes nothing but clears its stub =="
setup
mktranscript live-6 0 "t:$(iso '1 hour ago')" "a:$(iso '1 hour ago +2 min')"
printf 'live-6\t%s\t%s\tmain\n' "$(iso '1 hour ago')" "$SIM/repo" > "$SIM/.claude/time-logger/open-sessions.tsv"
end_session live-6
is "no row" "$(rows)" "0"
is "no sidecar" "$(pending)" "0"
is "stub cleared" "$(grep -c '^live-6' "$SIM/.claude/time-logger/open-sessions.tsv")" "0"

echo "== 22. Files column survives a commitless session (grep -c fix) =="
setup
mkdir -p "$SIM/repo3"; git -C "$SIM/repo3" init -q
git -C "$SIM/repo3" config user.email sim@example.com; git -C "$SIM/repo3" config user.name sim
echo a > "$SIM/repo3/tracked.txt"; git -C "$SIM/repo3" add -A; git -C "$SIM/repo3" commit -qm init
echo b >> "$SIM/repo3/tracked.txt"
f="$SIM/.claude/projects/proj/live-7.jsonl"
printf '{"type":"user","promptSource":"user","timestamp":"%s","cwd":"%s","message":{"content":"go"}}\n' "$(iso '2 hours ago')" "$SIM/repo3" > "$f"
printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"content":[{"type":"text","text":"ok"}]}}\n' "$(iso '2 hours ago +4 min')" "$SIM/repo3" >> "$f"
ERR=$(end_session live-7 2>&1 >/dev/null)
is "stderr clean" "$ERR" ""
is "uncommitted file listed" "$(cell 9)" "tracked.txt"

echo "== 23. the child guard stops SessionEnd logging the summariser =="
setup
mktranscript live-8 0 "u:$(iso '2 hours ago')" "a:$(iso '2 hours ago +4 min')"
printf '{"transcript_path":"%s","session_id":"live-8"}' "$SIM/.claude/projects/proj/live-8.jsonl" \
  | HOME="$SIM" PATH="$ROOT/bin:$PATH" CLAUDE_WORKLOG_CHILD=1 bash "$LOG_HOOK"
is "no row for a child session" "$(rows)" "0"

# ============================================================ fill-summaries

echo "== 24. fill writes the summary, flips s:1 and drops the sidecar =="
setup
mktranscript dead-24 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +6 min')"
run
fill >/dev/null
is "summary landed" "$(cell 8)" "Refactored the thing. Added tests."
logtext | grep -q ';s:1-->' && ok "marker flipped to s:1" || no "marker not flipped" "$(logtext|tail -1)"
is "sidecar consumed" "$(pending)" "0"
is "still one row" "$(rows)" "1"

echo "== 25. fill is idempotent and cheap once drained =="
setup
mktranscript dead-25 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +6 min')"
run; fill >/dev/null
BEFORE=$(logtext)
stub_claude "SHOULD NOT RUN."
fill >/dev/null
is "unchanged on a second pass" "$(logtext)" "$BEFORE"

echo "== 26. a summary still generates after the transcript is gone =="
setup
mktranscript dead-26 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +6 min')"
run
rm -f "$SIM/.claude/projects/proj/dead-26.jsonl"        # Claude Code pruned it
rm -rf "$SIM/.claude/projects"
fill >/dev/null
is "summary landed from the sidecar" "$(cell 8)" "Refactored the thing. Added tests."

echo "== 27. a failed summariser leaves the row retryable =="
setup
mktranscript dead-27 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +6 min')"
run
stub_claude_failing "Not logged in · Please run /login"
fill >/dev/null
logtext | grep -q 'Not logged in' && no "error text leaked into the row" "$(logtext|tail -1)" || ok "no error text in the row"
is "row still pending" "$(cell 8)" "_(pending)_"
logtext | grep -q ';s:0-->' && ok "still s:0" || no "flag wrongly flipped"
is "sidecar kept for retry" "$(pending)" "1"
stub_claude "Recovered on the retry."
fill >/dev/null
is "retry succeeds" "$(cell 8)" "Recovered on the retry."

echo "== 28. pipes and newlines in a summary cannot break the table =="
setup
mktranscript dead-28 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +6 min')"
run
printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1\nprintf "a | b\\nsecond line\\n"\n' > "$ROOT/bin/claude"
chmod +x "$ROOT/bin/claude"
fill >/dev/null
is "row still has 9 cells" "$(logtext | grep '<!--sid:' | awk -F'|' '{print NF-2}')" "9"
is "one row, not two" "$(rows)" "1"

echo "== 29. week filter, orphaned and expired sidecars =="
setup
mktranscript dead-29 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +6 min')"
run
fill 2099-W01 >/dev/null
is "other week skipped" "$(cell 8)" "_(pending)_"
fill "$(date -d '25 hours ago' +%G-W%V)" >/dev/null
is "matching week filled" "$(cell 8)" "Refactored the thing. Added tests."
setup
mkdir -p "$PEND"; printf 'workdir: x\nbranch: y\ncommits: none\n---\nbody\n' > "$PEND/ghost.txt"
fill >/dev/null
is "orphaned sidecar removed" "$(pending)" "0"
setup
mkdir -p "$PEND"; printf 'workdir: x\nbranch: y\ncommits: none\n---\nbody\n' > "$PEND/old.txt"
touch -d "90 days ago" "$PEND/old.txt"
OUT=$(fill)
printf '%s' "$OUT" | grep -q 'pruning 1 sidecar' && ok "expiry reported, not silent" || no "expiry silent" "$OUT"
is "expired sidecar pruned" "$(pending)" "0"

# ============================================================ SessionStart nudge

echo "== 30. the nudge is silent when there is nothing to do =="
setup
OUT=$(printf '{"session_id":"n1","cwd":"%s"}' "$SIM" | HOME="$SIM" PATH="/usr/bin:/bin" bash "$START_HOOK")
is "no output" "$OUT" ""

echo "== 31. the nudge reports pending work, with no model on PATH =="
setup
mktranscript dead-31 24 "u:$(iso '25 hours ago')" "a:$(iso '25 hours ago +6 min')"
run
OUT=$(printf '{"session_id":"n2","cwd":"%s"}' "$SIM" | HOME="$SIM" PATH="/usr/bin:/bin" bash "$START_HOOK")
printf '%s' "$OUT" | grep -q 'unsummarised' && ok "mentions unsummarised rows" || no "nudge text" "$OUT"
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["hookEventName"]=="SessionStart"' 2>/dev/null \
  && ok "valid SessionStart hook output" || no "invalid hook JSON" "$OUT"

echo "== 32. the nudge flags a past week with rows but no report =="
setup
printf '| 2020-01-01 | Wed | r | main | 5 | 1 | done | - | - <!--sid:z;iv:1-2;s:1--> |\n' > "$WL/worklog-2020-W01.md"
mkdir -p "$PEND"; printf 'workdir: x\nbranch: y\ncommits: none\n---\nb\n' > "$PEND/p.txt"
OUT=$(printf '{"session_id":"n3","cwd":"%s"}' "$SIM" | HOME="$SIM" PATH="/usr/bin:/bin" bash "$START_HOOK")
printf '%s' "$OUT" | grep -q '2020-W01' && ok "names the unreported week" || no "missing week" "$OUT"

echo "== 33. the stub is still recorded =="
setup
printf '{"session_id":"n4","cwd":"%s"}' "$SIM" | HOME="$SIM" PATH="/usr/bin:/bin" bash "$START_HOOK" >/dev/null
is "stub appended" "$(grep -c '^n4' "$SIM/.claude/time-logger/open-sessions.tsv")" "1"

# ============================================================ weekly report

report_ctx() {
    printf '#!/usr/bin/env bash\nexit 1\n' > "$ROOT/bin/claude"; chmod +x "$ROOT/bin/claude"
    HOME="$SIM" PATH="$ROOT/bin:$PATH" bash "$REPORT" "$1" 2>/dev/null
}

echo "== 34. overlapping sessions are counted once =="
setup
W=$(date -d '10 days ago' +%G-W%V); D=$(date -d '10 days ago' +%Y-%m-%d)
{ echo "| Date | Day | Workdir | Branch | Min | Turns | What | Files | Commits |"
  echo "|---|---|---|---|---|---|---|---|---|"
  printf '| %s | Mon | repo | main | 240 | 5 | long | - | - <!--sid:a;iv:%s-%s;s:1--> |\n' \
      "$D" "$(date -d "$D 11:00" +%s)" "$(date -d "$D 15:00" +%s)"
  printf '| %s | Mon | repo | main | 30 | 2 | nested | - | - <!--sid:b;iv:%s-%s;s:1--> |\n' \
      "$D" "$(date -d "$D 13:00" +%s)" "$(date -d "$D 13:30" +%s)"
} > "$WL/worklog-$W.md"
CTX=$(report_ctx "$W")
is "4 h, not 4.5" "$(printf '%s' "$CTX" | grep -oE ': [0-9.]+ h' | head -1)" ": 4.0 h"

echo "== 35. a session spanning midnight splits across both days =="
setup
W=$(date -d '10 days ago' +%G-W%V)
D=$(python3 -c "import datetime,sys; y,w=sys.argv[1].split('-W'); print(datetime.date.fromisocalendar(int(y),int(w),1))" "$W")
{ echo "| Date | Day | Workdir | Branch | Min | Turns | What | Files | Commits |"
  echo "|---|---|---|---|---|---|---|---|---|"
  printf '| %s | Mon | repo | main | 180 | 5 | overnight | - | - <!--sid:c;iv:%s-%s;s:1--> |\n' \
      "$D" "$(date -d "$D 23:00" +%s)" "$(date -d "$D 23:00 3 hours" +%s)"
} > "$WL/worklog-$W.md"
CTX=$(report_ctx "$W")
is "two days listed" "$(printf '%s' "$CTX" | grep -cE '^- [0-9-]+ [A-Za-z]+: ')" "2"

echo "== 36. legacy rows without intervals still report =="
setup
W=$(date -d '10 days ago' +%G-W%V)
{ echo "| Date | Day | Workdir | Branch | Min | Turns | What | Files | Commits |"
  echo "|---|---|---|---|---|---|---|---|---|"
  printf '| x | Mon | repo | main | 60 | 2 | legacy row | - | - <!--sid:d--> |\n'
} > "$WL/worklog-$W.md"
CTX=$(report_ctx "$W")
printf '%s' "$CTX" | grep -q 'legacy row' && ok "legacy row reported" || no "legacy row missing"
printf '%s' "$CTX" | grep -q 'Hours per day' && no "totals section unexpected" || ok "totals omitted"

echo "== 37. the current week is no longer refused =="
setup
printf '#!/usr/bin/env bash\nexit 1\n' > "$ROOT/bin/claude"; chmod +x "$ROOT/bin/claude"
HOME="$SIM" PATH="$ROOT/bin:$PATH" bash "$REPORT" "$(date +%G-W%V)" >/dev/null 2>&1
is "accepted" "$?" "0"

echo "== 38. hook registration =="
python3 - "$REPO/hooks/hooks.json" <<'PYEOF'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
starts = [c["command"] for g in h["SessionStart"] for c in g["hooks"]]
ends = [c["command"] for g in h["SessionEnd"] for c in g["hooks"]]
assert any("session-start.sh" in c for c in starts), "session-start.sh missing"
assert any("worklog-reap.sh" in c for c in starts), "worklog-reap.sh missing"
assert any("session-log.sh" in c for c in ends), "session-log.sh missing"
assert not any("fill-summaries" in c for c in starts + ends), "fill must not be a hook"
PYEOF
[ $? -eq 0 ] && ok "hooks registered, summariser is not a hook" || no "hook registration"

echo "== 39. calendar meetings are collected, filtered and netted off sessions =="
setup
W=$(date -d '10 days ago' +%G-W%V); D=$(date -d '10 days ago' +%Y-%m-%d)
{ echo "| Date | Day | Workdir | Branch | Min | Turns | What | Files | Commits |"
  echo "|---|---|---|---|---|---|---|---|---|"
  printf '| %s | Mon | repo | main | 120 | 5 | coding | - | - <!--sid:e;iv:%s-%s;s:1--> |\n' \
      "$D" "$(date -d "$D 09:00" +%s)" "$(date -d "$D 11:00" +%s)"
} > "$WL/worklog-$W.md"
cat > "$SIM/events.json" <<JSON
{"items": [
  {"summary": "Sprint Planning",
   "start": {"dateTime": "$(date -d "$D 10:00" --iso-8601=seconds)"},
   "end":   {"dateTime": "$(date -d "$D 11:30" --iso-8601=seconds)"},
   "attendees": [{"self": true, "responseStatus": "accepted"}]},
  {"summary": "Retro",
   "start": {"dateTime": "$(date -d "$D 14:00" --iso-8601=seconds)"},
   "end":   {"dateTime": "$(date -d "$D 15:00" --iso-8601=seconds)"}},
  {"summary": "Daily standup",
   "start": {"dateTime": "$(date -d "$D 09:30" --iso-8601=seconds)"},
   "end":   {"dateTime": "$(date -d "$D 09:45" --iso-8601=seconds)"}},
  {"summary": "Someone on leave",
   "start": {"date": "$D"}, "end": {"date": "$D"}},
  {"summary": "Workshop I declined",
   "start": {"dateTime": "$(date -d "$D 16:00" --iso-8601=seconds)"},
   "end":   {"dateTime": "$(date -d "$D 17:30" --iso-8601=seconds)"},
   "attendees": [{"self": true, "responseStatus": "declined"}]}
]}
JSON
: > "$SIM/.claude/time-logger/cal-auth"
printf '#!/usr/bin/env bash\nexit 1\n' > "$ROOT/bin/claude"; chmod +x "$ROOT/bin/claude"
CTX=$(HOME="$SIM" PATH="$ROOT/bin:$PATH" WORKLOG_CAL_FIXTURE="$SIM/events.json" \
      bash "$REPORT" "$W" 2>/dev/null)
printf '%s' "$CTX" | grep -q 'Sprint Planning' && ok "long meeting collected" || no "planning missing"
printf '%s' "$CTX" | grep -q 'Daily standup' && no "short meeting not filtered" || ok "standup filtered out"
printf '%s' "$CTX" | grep -q 'Someone on leave' && no "all-day event not filtered" || ok "all-day filtered out"
printf '%s' "$CTX" | grep -q 'Workshop I declined' && no "declined not filtered" || ok "declined filtered out"
is "meeting hours" "$(printf '%s' "$CTX" | grep -oE 'calendar \(2 meetings, [0-9.]+ h\)')" \
   "calendar (2 meetings, 2.5 h)"
# Planning overlaps the session 10:00-11:00, so only 1.5 of the 2.5 h are new.
printf '%s' "$CTX" | grep -q 'of which 1.5 h' && ok "overlap netted off" || no "overlap not netted off"

echo "== 40. no auth file, no calendar section =="
setup
W=$(date -d '10 days ago' +%G-W%V)
{ echo "| Date | Day | Workdir | Branch | Min | Turns | What | Files | Commits |"
  echo "|---|---|---|---|---|---|---|---|---|"
  printf '| x | Mon | repo | main | 60 | 2 | row | - | - <!--sid:f;s:1--> |\n'
} > "$WL/worklog-$W.md"
CTX=$(report_ctx "$W")
printf '%s' "$CTX" | grep -q 'Source 4' && no "calendar section unexpected" || ok "calendar skipped"

echo "== 41. an iCal feed: recurrence expanded, EXDATE dropped, override moved =="
setup
W=$(date -d '10 days ago' +%G-W%V)
MON=$(python3 -c "import datetime,sys; y,w=sys.argv[1].split('-W'); print(datetime.date.fromisocalendar(int(y),int(w),1))" "$W")
STAMP() { date -d "$1" +%Y%m%dT%H%M%S; }
cat > "$SIM/feed.ics" <<ICS
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:retro@t
DTSTART:$(STAMP "$MON -21 days 14:00")
DTEND:$(STAMP "$MON -21 days 15:00")
RRULE:FREQ=WEEKLY;COUNT=10
SUMMARY:Weekly Retro
END:VEVENT
BEGIN:VEVENT
UID:grooming@t
DTSTART:$(STAMP "$MON -21 days 11:00")
DTEND:$(STAMP "$MON -21 days 12:00")
RRULE:FREQ=WEEKLY;UNTIL=$(date -d "$MON 60 days" +%Y%m%dT%H%M%S)
EXDATE:$(STAMP "$MON 11:00")
SUMMARY:Backlog Grooming
END:VEVENT
BEGIN:VEVENT
UID:demo@t
DTSTART:$(STAMP "$MON -21 days 09:00")
DTEND:$(STAMP "$MON -21 days 10:30")
RRULE:FREQ=WEEKLY;COUNT=10
SUMMARY:Demo day
END:VEVENT
BEGIN:VEVENT
UID:demo@t
RECURRENCE-ID:$(STAMP "$MON 09:00")
DTSTART:$(STAMP "$MON 16:00")
DTEND:$(STAMP "$MON 17:30")
SUMMARY:Demo day
END:VEVENT
BEGIN:VEVENT
UID:standup@t
DTSTART:$(STAMP "$MON 09:30")
DTEND:$(STAMP "$MON 09:45")
SUMMARY:Daily standup
END:VEVENT
BEGIN:VEVENT
UID:leave@t
DTSTART;VALUE=DATE:$(date -d "$MON" +%Y%m%d)
DTEND;VALUE=DATE:$(date -d "$MON 1 day" +%Y%m%d)
SUMMARY:Someone on leave
END:VEVENT
END:VCALENDAR
ICS
echo "file://$SIM/feed.ics" > "$SIM/.claude/time-logger/cal-ics"
{ echo "| Date | Day | Workdir | Branch | Min | Turns | What | Files | Commits |"
  echo "|---|---|---|---|---|---|---|---|---|"
  printf '| x | Mon | repo | main | 60 | 2 | row | - | - <!--sid:g;s:1--> |\n'
} > "$WL/worklog-$W.md"
CTX=$(report_ctx "$W")
printf '%s' "$CTX" | grep -q 'Weekly Retro' && ok "recurrence expanded into the week" || no "retro missing"
printf '%s' "$CTX" | grep -q 'Backlog Grooming' && no "EXDATE occurrence not dropped" || ok "EXDATE occurrence dropped"
printf '%s' "$CTX" | grep -qE '16:00-17:30 \(1.5 h\) Demo day' && ok "override moved the occurrence" || no "override not applied"
printf '%s' "$CTX" | grep -q '09:00-10:30' && no "original occurrence still shown" || ok "original occurrence replaced"
printf '%s' "$CTX" | grep -q 'Daily standup' && no "short meeting not filtered" || ok "standup filtered out"
printf '%s' "$CTX" | grep -q 'Someone on leave' && no "all-day not filtered" || ok "all-day filtered out"
is "feed totals" "$(printf '%s' "$CTX" | grep -oE 'calendar \(2 meetings, [0-9.]+ h\)')" \
   "calendar (2 meetings, 2.5 h)"

echo "== 42. a week in progress stops at now, not on Sunday night =="
setup
W=$(date +%G-W%V)
{ echo "| Date | Day | Workdir | Branch | Min | Turns | What | Files | Commits |"
  echo "|---|---|---|---|---|---|---|---|---|"
  printf '| x | Mon | repo | main | 60 | 2 | row | - | - <!--sid:h;s:1--> |\n'
} > "$WL/worklog-$W.md"
# Only the future side is asserted here. Whether a past meeting survives is
# what tests 39 and 41 cover, on a finished week, where no clock can make them
# flaky - anchoring a "recent past" event to now would break when the suite
# runs just after midnight on a Monday.
cat > "$SIM/ahead.json" <<JSON
{"items": [
  {"summary": "Not sat through yet",
   "start": {"dateTime": "$(date -d '2 hours' --iso-8601=seconds)"},
   "end":   {"dateTime": "$(date -d '3 hours 30 minutes' --iso-8601=seconds)"}}
]}
JSON
: > "$SIM/.claude/time-logger/cal-auth"
printf '#!/usr/bin/env bash\nexit 1\n' > "$ROOT/bin/claude"; chmod +x "$ROOT/bin/claude"
CTX=$(HOME="$SIM" PATH="$ROOT/bin:$PATH" WORKLOG_CAL_FIXTURE="$SIM/ahead.json" \
      bash "$REPORT" "$W" 2>/dev/null)
printf '%s' "$CTX" | grep -q 'Not sat through yet' && no "future meeting counted" || ok "future meeting not counted"
is "no hours claimed" "$(printf '%s' "$CTX" | grep -oE 'calendar \(0 meetings, [0-9.]+ h\)')" \
   "calendar (0 meetings, 0.0 h)"

echo "== 43. a repo mapped to several projects keeps both =="
setup
W=$(date -d '10 days ago' +%G-W%V)
printf 'repo\tAAA,BBB\nsolo\tCCC\n' > "$SIM/.claude/time-logger/repo-project.map"
{ echo "| Date | Day | Workdir | Branch | Min | Turns | What | Files | Commits |"
  echo "|---|---|---|---|---|---|---|---|---|"
  printf '| x | Mon | repo | main | 60 | 2 | row | - | - <!--sid:i;s:1--> |\n'
} > "$WL/worklog-$W.md"
CTX=$(report_ctx "$W")
printf '%s' "$CTX" | grep -q 'repo -> AAA, BBB' && ok "both keys kept" || no "second key dropped"
printf '%s' "$CTX" | grep -q 'solo -> CCC' && ok "single key still works" || no "single key broken"

echo "== 44. the activity ledger renders newest week first =="
setup
mkdir -p "$WL"
cat > "$WL/weekly-report-2026-W20.md" <<'RPT'
<!--daily
2026-05-11	PROJ	PROJ-9	1.5	ok	Older week row	
-->
RPT
cat > "$WL/weekly-report-2026-W21.md" <<'RPT'
<!--daily
2026-05-18	PROJ	PROJ-7	2.5	ok	Newer week row	
2026-05-19	-	-	1.0	new	Untracked bit	Create a ticket for it
-->
RPT
cat > "$WL/weekly-report-2026-W19.md" <<'RPT'
no per-day block at all
RPT
# The sandbox config sets no Jira base, and without one an issue link cannot
# be built at all - which is the correct behaviour, so supply one here.
OUT=$(HOME="$SIM" WORKLOG_JIRA_BASE="https://example.atlassian.net" \
      bash "$REPO/bin/activity.sh" 2>&1)
H="$WL/activity.html"
printf '%s' "$OUT" | grep -q '2 week(s) rendered' && ok "two weeks rendered" || no "wrong week count"
printf '%s' "$OUT" | grep -q '2026-W19' && ok "block-less week named" || no "block-less week hidden"
python3 - "$H" <<'PY'
import sys
h = open(sys.argv[1]).read()
assert h.index("2026-W21") < h.index("2026-W20"), "weeks not newest first"
assert ">3.5<" in h, "week total wrong"
assert "/browse/PROJ-7" in h, "issue link missing"
assert "line-through" in h, "exclusion styling missing"
PY
[ $? -eq 0 ] && ok "order, totals, links, exclusion styling" || no "ledger content wrong"

echo "== 45. a ledger with nothing to show says so =="
setup
OUT=$(HOME="$SIM" bash "$REPO/bin/activity.sh" 2>&1)
printf '%s' "$OUT" | grep -q '0 week(s) rendered' && ok "empty run is not an error" || no "empty run misreported"
grep -q 'No week has per-day rows yet' "$WL/activity.html" && ok "page explains itself" || no "empty page silent"

# A caller can start a session holding stdin open and never send anything. The
# hooks used to slurp with `cat`, which returns only at EOF, so they blocked for
# the life of that pipe - this suite itself hung on it twice.
hold_open_stdin() {   # $1 = hook path; echoes "<exit-code> <elapsed-seconds>"
    local hook="$1" fifo="$SIM/hangfifo.$$" rc start end
    mkfifo "$fifo"
    sleep 10 > "$fifo" &
    local holder=$!
    start=$(date +%s)
    HOME="$SIM" PATH="/usr/bin:/bin" WORKLOG_STDIN_TIMEOUT=1 \
        timeout 8 bash "$hook" < "$fifo" >/dev/null 2>&1
    rc=$?
    end=$(date +%s)
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    rm -f "$fifo"
    echo "$rc $((end - start))"
}

echo "== 46. SessionStart does not hang on a stdin nobody closes =="
setup
read -r RC ELAPSED <<< "$(hold_open_stdin "$START_HOOK")"
is "did not time out" "$RC" "0"
[ "$ELAPSED" -le 5 ] && ok "returned in ${ELAPSED}s" || no "took ${ELAPSED}s"

echo "== 47. SessionEnd does not hang either, and logs nothing without a payload =="
setup
read -r RC ELAPSED <<< "$(hold_open_stdin "$LOG_HOOK")"
is "did not time out" "$RC" "0"
[ "$ELAPSED" -le 5 ] && ok "returned in ${ELAPSED}s" || no "took ${ELAPSED}s"
# No JSON means no transcript to read, so the correct outcome is no row at all -
# the hook already exits early on an empty payload.
[ -z "$(ls "$WL"/worklog-*.md 2>/dev/null)" ] && ok "no row written from an empty payload" \
    || no "wrote a row with nothing to log"

echo "== 48. a payload that does arrive is still read whole =="
setup
OUT=$(printf '{"session_id":"n48","cwd":"%s"}' "$SIM" | \
      HOME="$SIM" PATH="/usr/bin:/bin" bash "$START_HOOK")
grep -q "n48" "$SIM/.claude/time-logger/open-sessions.tsv" 2>/dev/null \
    && ok "stub recorded from piped json" || no "payload lost"

echo "== 49. a draining model call cannot block the report on stdin =="
setup
# The real `claude -p` reads stdin to EOF even though the prompt is an argument -
# fill-summaries.sh has said so in a comment since 0.2.0. The usual stub exits
# too fast to show it, so this one drains the way the real binary does.
printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1\nexit 1\n' > "$ROOT/bin/claude"
chmod +x "$ROOT/bin/claude"
W=$(date -d '10 days ago' +%G-W%V)
{ echo "| Date | Day | Workdir | Branch | Min | Turns | What | Files | Commits |"
  echo "|---|---|---|---|---|---|---|---|---|"
  printf '| x | Mon | repo | main | 60 | 2 | row | - | - <!--sid:j;s:1--> |\n'
} > "$WL/worklog-$W.md"
FIFO="$SIM/reportfifo"; mkfifo "$FIFO"
sleep 20 > "$FIFO" & HOLDER=$!
S=$(date +%s)
HOME="$SIM" PATH="$ROOT/bin:$PATH" timeout 12 bash "$REPORT" "$W" >/dev/null 2>&1
RC=$?; E=$(( $(date +%s) - S ))
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; rm -f "$FIFO"
is "report did not block on stdin" "$RC" "0"
[ "$E" -le 8 ] && ok "finished in ${E}s" || no "took ${E}s"

echo "== 50. any project's ticket may be proposed, and transitions are evidence =="
setup
W=$(date -d '10 days ago' +%G-W%V)
MON=$(python3 -c "import datetime,sys; y,w=sys.argv[1].split('-W'); print(datetime.date.fromisocalendar(int(y),int(w),1))" "$W")
# The repo maps to AAA only. A BBB ticket must still be proposable, because the
# hint is a tie-breaker now - filtering by it would hide other projects.
printf 'repo\tAAA\n' > "$SIM/.claude/time-logger/repo-project.map"
cat > "$SIM/jira.json" <<JSON
{"accountId": "me",
 "assigned": [
   {"key": "AAA-1", "fields": {"summary": "Mapped project work", "status": {"name": "To Do"}, "project": {"key": "AAA"}}},
   {"key": "BBB-9", "fields": {"summary": "Other project work", "status": {"name": "In Progress"}, "project": {"key": "BBB"}}}],
 "moved": [{"key": "BBB-9", "fields": {"summary": "Other project work"}}],
 "changelog": {"BBB-9": {"fields": {"summary": "Other project work"},
   "changelog": {"histories": [
     {"created": "${MON}T09:30:00.000+0000", "author": {"accountId": "me"},
      "items": [{"field": "status", "fromString": "To Do", "toString": "In Progress"}]},
     {"created": "${MON}T18:00:00.000+0000", "author": {"accountId": "someone-else"},
      "items": [{"field": "status", "fromString": "In Progress", "toString": "Done"}]}]}}}}
JSON
{ echo "| Date | Day | Workdir | Branch | Min | Turns | What | Files | Commits |"
  echo "|---|---|---|---|---|---|---|---|---|"
  printf '| x | Mon | repo | main | 60 | 2 | row | - | - <!--sid:k;s:1--> |\n'
} > "$WL/worklog-$W.md"
: > "$SIM/.claude/time-logger/jira-auth"
printf '#!/usr/bin/env bash\nexit 1\n' > "$ROOT/bin/claude"; chmod +x "$ROOT/bin/claude"
CTX=$(HOME="$SIM" PATH="$ROOT/bin:$PATH" WORKLOG_JIRA_BASE="https://example.atlassian.net" \
      WORKLOG_JIRA_FIXTURE="$SIM/jira.json" bash "$REPORT" "$W" 2>/dev/null)
printf '%s' "$CTX" | grep -q 'BBB-9' && ok "unmapped project still proposed" || no "BBB-9 filtered out"
printf '%s' "$CTX" | grep -q 'AAA-1' && ok "mapped project still listed" || no "AAA-1 missing"
printf '%s' "$CTX" | grep -q 'tie-breaker' && ok "map presented as a hint" || no "map still presented as a filter"
printf '%s' "$CTX" | grep -qE 'Source 5 - ticket activity \(1 status change' \
    && ok "only your own transition counted" || no "someone else's transition leaked in"
printf '%s' "$CTX" | grep -q 'To Do -> In Progress' && ok "transition rendered with its times" || no "transition missing"

echo "== 51. a sidecar with no worklog file does not read stdin =="
setup
# nullglob is on inside fill-summaries, so with no worklog-*.md the glob
# vanishes and grep - left with no file operands - reads stdin instead. This is
# what stalled this suite for a whole afternoon.
mkdir -p "$PEND"; printf 'workdir: x\nbranch: y\ncommits: none\n---\nbody\n' > "$PEND/ghost51.txt"
rm -f "$WL"/worklog-*.md
FIFO="$SIM/fillfifo"; mkfifo "$FIFO"
sleep 20 > "$FIFO" & HOLDER=$!
S=$(date +%s)
HOME="$SIM" PATH="$ROOT/bin:$PATH" timeout 10 bash "$FILL" < "$FIFO" >/dev/null 2>&1
RC=$?; E=$(( $(date +%s) - S ))
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; rm -f "$FIFO"
is "fill did not block on stdin" "$RC" "0"
[ "$E" -le 5 ] && ok "finished in ${E}s" || no "took ${E}s"
is "orphaned sidecar still removed" "$(pending)" "0"

echo "== 52. Codex session end records one shared worklog row =="
setup
CID=00000000-0000-0000-0000-000000000001
CF="$SIM/.codex/sessions/2020/01/01/rollout-2020-01-01T00-00-00-$CID.jsonl"
mkdir -p "$(dirname "$CF")"
T0=$(iso '10 minutes ago')
T1=$(iso '8 minutes ago')
printf '{"type":"session_meta","timestamp":"%s","payload":{"id":"%s","cwd":"%s/repo"}}\n' "$T0" "$CID" "$SIM" > "$CF"
printf '{"type":"response_item","timestamp":"%s","payload":{"type":"message","role":"user","internal_chat_message_metadata_passthrough":{"content_item_kinds":["environments.environment_context"]},"content":[{"type":"input_text","text":"environment setup"}]}}\n' "$T0" >> "$CF"
printf '{"type":"response_item","timestamp":"%s","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"internal"}]}}\n' "$T0" >> "$CF"
printf '{"type":"response_item","timestamp":"%s","payload":{"type":"message","role":"user","internal_chat_message_metadata_passthrough":{"content_item_kinds":["user.text"]},"content":[{"type":"input_text","text":"fix the bug"}]}}\n' "$T0" >> "$CF"
printf '{"type":"response_item","timestamp":"%s","payload":{"type":"message","role":"assistant","phase":"final","content":[{"type":"output_text","text":"fixed the bug"}]}}\n' "$T1" >> "$CF"
printf '{"session_id":"hook-codex-id","transcript_path":"%s"}' "$CF" \
    | HOME="$SIM" PATH="$ROOT/bin:$PATH" bash "$LOG_HOOK"
is "Codex row written" "$(rows)" "1"
is "Codex prompt counted once" "$(cell 7)" "1"
is "Codex active minutes" "$(cell 6)" "2"
grep -qF "<!--sid:$CID" "$WL"/worklog-*.md && ok "transcript id wins over hook id" || no "transcript id missing"
grep -q 'fix the bug' "$PEND/$CID.txt" && ok "Codex digest preserved" || no "Codex digest missing"

echo "== 53. stale Codex transcripts are reaped without duplicates =="
setup
mkdir -p "$(dirname "$CF")"
T0=$(iso '25 hours ago')
T1=$(iso '25 hours ago +4 min')
printf '{"type":"session_meta","timestamp":"%s","payload":{"id":"%s","cwd":"%s/repo"}}\n' "$T0" "$CID" "$SIM" > "$CF"
printf '{"type":"response_item","timestamp":"%s","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the bug"}]}}\n' "$T0" >> "$CF"
printf '{"type":"response_item","timestamp":"%s","payload":{"type":"message","role":"assistant","phase":"final","content":[{"type":"output_text","text":"fixed the bug"}]}}\n' "$T1" >> "$CF"
touch -d '24 hours ago' "$CF"
run; run
is "one Codex row after two reaps" "$(rows)" "1"
grep -qF "<!--sid:$CID" "$WL"/worklog-*.md && ok "Codex marker uses session id" || no "Codex marker missing"

echo "== 54. Codex backend fills a pending summary =="
printf '#!/usr/bin/env bash\nwhile [ "$#" -gt 0 ]; do\n  if [ "$1" = "-o" ]; then printf "Fixed the bug. Added coverage.\\n" > "$2"; exit 0; fi\n  shift\ndone\nexit 1\n' > "$ROOT/bin/codex"
chmod +x "$ROOT/bin/codex"
HOME="$SIM" PATH="$ROOT/bin:$PATH" WORKLOG_MODEL_BACKEND=codex bash "$FILL" >/dev/null
is "Codex model filled summary" "$(pending)" "0"
grep -q 'Fixed the bug. Added coverage.' "$WL"/worklog-*.md \
    && ok "Codex model text in worklog" || no "Codex summary missing"

# ============================================================ automatic Codex summaries

stub_codex_auto() {
    cat > "$ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/codex-calls"
printf '%s\n' "${CLAUDE_WORKLOG_CHILD:-}" >> "$HOME/child-guards"
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        printf 'Summarised in child. Kept main chat quiet.\n' > "$2"
        exit 0
    fi
    shift
done
exit 1
SH
    chmod +x "$ROOT/bin/codex"
}

wait_for_auto_summary() {
    local n
    for n in $(seq 1 50); do
        [ "$(pending)" = 0 ] && grep -q 'Summarised in child' "$WL"/worklog-*.md 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

echo "== 55. Codex SessionEnd launches a quiet child summary =="
setup
stub_codex_auto
CID=00000000-0000-0000-0000-000000000002
CF="$SIM/.codex/sessions/2020/01/01/rollout-2020-01-01T00-00-00-$CID.jsonl"
mkdir -p "$(dirname "$CF")"
T0=$(iso '10 minutes ago')
T1=$(iso '8 minutes ago')
printf '{"type":"session_meta","timestamp":"%s","payload":{"id":"%s","cwd":"%s/repo"}}\n' "$T0" "$CID" "$SIM" > "$CF"
printf '{"type":"response_item","timestamp":"%s","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the bug"}]}}\n' "$T0" >> "$CF"
printf '{"type":"response_item","timestamp":"%s","payload":{"type":"message","role":"assistant","phase":"final","content":[{"type":"output_text","text":"fixed the bug"}]}}\n' "$T1" >> "$CF"
S=$(date +%s)
OUT=$(printf '{"session_id":"hook-codex-id","transcript_path":"%s"}' "$CF" \
    | HOME="$SIM" PATH="$ROOT/bin:$PATH" PLUGIN_ROOT="$REPO" bash "$LOG_HOOK")
E=$(( $(date +%s) - S ))
is "SessionEnd has no conversation output" "$OUT" ""
[ "$E" -lt 3 ] && ok "SessionEnd returned before its budget" || no "SessionEnd took ${E}s"
wait_for_auto_summary && ok "detached Codex child filled the row" || no "automatic summary missing"
grep -q -- '--sandbox read-only -c approval_policy=never' "$SIM/codex-calls" \
    && ok "child has read-only sandbox and no approval prompts" || no "child flags missing"
is "child recursion guard set" "$(cat "$SIM/child-guards")" "1"

echo "== 56. Codex SessionStart retries silently =="
setup
stub_codex_auto
mkdir -p "$PEND"
printf '| Date | Day | Workdir | Branch | Min | Turns | What was done | Files | Commits |\n|---|---|---|---|---|---|---|---|---|\n| 2020-01-02 | Thu | repo | main | 2 | 1 | _(pending)_ | - | - <!--sid:retry-56;iv:1-2;s:0--> |\n' > "$WL/worklog-2020-W01.md"
printf 'workdir: repo\nbranch: main\ncommits: none\n---\nfixed the bug\n' > "$PEND/retry-56.txt"
OUT=$(printf '{"session_id":"start-56","cwd":"%s"}' "$SIM" \
    | HOME="$SIM" PATH="$ROOT/bin:$PATH" PLUGIN_ROOT="$REPO" bash "$START_HOOK")
is "SessionStart adds no conversation context" "$OUT" ""
wait_for_auto_summary && ok "pending row retried automatically" || no "pending row not retried"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
