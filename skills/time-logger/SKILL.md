---
name: time-logger
description: Review coding session worklogs, summarise pending sessions, draft a weekly timesheet, or render the activity ledger. Use when the user asks for timelog, worklog, timesheet, or activity from this plugin.
---

# Time Logger

Find the plugin root two directories above this `SKILL.md`. The state and optional config live in `~/.claude/time-logger/` for both Claude Code and Codex. Source `lib/common.sh` to resolve custom paths. Never print auth files or calendar feed URLs.

- **Worklog [ISO week]:** Read `worklog-<week>.md` in `WORKLOG_DIR` (current ISO week by default). Show rows grouped by day, stripping `<!--sid:...-->` markers. Count pending summaries. Minutes are per session; overlapping sessions must not be summed.
- **Timelog status:** Count pending sidecars in `WORKLOG_PENDING_DIR`, list weeks with worklog rows but no report, and report expired sidecars. This is read-only.
- **Timelog [ISO week]:** Run `hooks/worklog-reap.sh` with `WORKLOG_REAP_INLINE=1`, then `bin/fill-summaries.sh <week>`, then `hooks/weekly-report.sh <week>`. Set `WORKLOG_MODEL_BACKEND=codex` for the latter two. With no week, run only `bin/fill-summaries.sh` to fill all pending summaries. Tell the user before a batch with more than ten pending sidecars, since each calls a model.
- **Activity [N]:** Run `bin/activity.sh [N]` and report the generated HTML path and any weeks it says need a new report. This does not call a model.

Use the plugin's scripts directly. Do not recreate their row, report, or calendar logic in the conversation.
