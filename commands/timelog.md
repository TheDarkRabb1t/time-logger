---
description: Fill pending summaries, and draft a timesheet with Jira correspondence
---

Config lives in `~/.claude/time-logger/config.sh`; defaults are in `lib/common.sh`.

This is the only command that generates anything. Hooks never call a model —
they record facts at session end and leave a sidecar; everything below turns
those into prose and into a timesheet.

Argument: `$ARGUMENTS`

## empty — catch up

Run `${CLAUDE_PLUGIN_ROOT}/bin/fill-summaries.sh` and show its result.

It summarises **every** pending row, in any week, up to right now. Each row takes
a model call of roughly 15-35 s, so tell the user the count first if there are
more than about ten pending — `ls ~/.claude/time-logger/pending/*.txt | wc -l`.

## an ISO week such as `2026-W33` — draft the timesheet

In this order:

1. `${CLAUDE_PLUGIN_ROOT}/hooks/worklog-reap.sh` with `WORKLOG_REAP_INLINE=1`,
   so sessions that died get rows before anything is drafted. No model calls,
   takes a few seconds.
2. `${CLAUDE_PLUGIN_ROOT}/bin/fill-summaries.sh <week>` — summaries for that
   week only.
3. `${CLAUDE_PLUGIN_ROOT}/hooks/weekly-report.sh <week>` — merges rows, unioned
   per-day hours, git log and Jira into a draft. Several minutes. It writes
   `weekly-report-<week>.md` and prints it; on failure it prints the collected
   context and writes nothing.

Show the result. The current week is allowed — it is simply partial, and nothing
is gated on it any more.

## `status` — what needs doing

Report, without generating anything:

- pending sidecars: `ls ~/.claude/time-logger/pending/*.txt | wc -l`
- per week, from `worklog-*.md`: row count, how many are `_(pending)_`, and
  whether `weekly-report-<week>.md` exists
- weeks with rows but no report, oldest first — these are the ones at risk
- any sidecar older than `WORKLOG_SUMMARY_LOOKBACK_DAYS` (default 60), which
  will be pruned unsummarised on the next fill

## Notes

A row's hidden marker carries `s:0` until it is summarised, then `s:1`. A failed
summary leaves `s:0` and keeps the sidecar, so it is simply retried next run —
never silently stuck with an error string in the table.

Sidecars are what make this safe to defer: Claude Code prunes transcripts at
about 30 days, but the sidecar holds the digest, so a row stays summarisable
long after its transcript is gone.
