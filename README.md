# claude-time-logger

Logs Claude Code and Codex sessions to a shared weekly worklog, then drafts a timesheet from
the sessions, your git history and, optionally, Jira and your calendar.

Built because on Monday nobody remembers what they did last week. The deliverable
is recall, not accurate hours.

## Install

```
/plugin marketplace add TheDarkRabb1t/time-logger
/plugin install time-logger@claude-time-logger
```

Then, optionally:

```
mkdir -p ~/.claude/time-logger
cp config.example.sh ~/.claude/time-logger/config.sh
```

It works with no config. Defaults write to `~/.claude/time-logger/worklogs`.

### Codex

Install this repository as a Codex plugin and trust its `SessionStart` and
`SessionEnd` hooks. It shares the same `~/.claude/time-logger/config.sh`, worklogs,
pending summaries, and reports. The Codex skill supports worklog, timelog, and
activity requests; summary and report requests select the Codex model backend.
Codex transcripts are read from `~/.codex/sessions` by default. Hook-generated
rows are summarised by a detached `codex exec` child with read-only sandbox and
no approval prompts. The hook returns immediately and writes no chat context.
`timelog` still drafts weekly reports when you request one.

## What it produces

`worklog-2026-W31.md` — one row per session:

| Date | Day | Workdir | Branch | Min | Turns | What was done | Files | Commits |
|---|---|---|---|---|---|---|---|---|
| 2026-08-04 | Tue | acme-api/cmd | fix/rate-limit | 87 | 11 | Added a sliding-window limiter behind a config switch. Reworked the retry path to honour Retry-After. | limiter.go retry.go | 03d2d21 rate limit |

`weekly-report-2026-W31.md` — a timesheet draft with hours per ticket, work that
has no ticket, and the gaps worth checking by hand. Built when you ask for it.

`/worklog` reads: the current week, or `/worklog 2026-W31`. It never generates.

`/timelog` generates: bare, it summarises every pending row; `/timelog 2026-W31`
reaps, summarises and drafts that week's timesheet; `/timelog status` lists what
is outstanding.

`/activity` renders `activity.html` — every week that has per-day rows, newest
first, one line per day per ticket with its hours and summary. Ticket colour is
green when a commit names it, amber when it needs your check, red when no ticket
covers the work; hovering explains the colour and, for amber and red, what to do
about it. Tickets link into Jira, rows with none link to their project's backlog,
and ⊘ drops a row from the week total. No model call — it lays out what the
weekly draft already decided.

## Config

All optional. See `config.example.sh`.

| Variable | Default |
|---|---|
| `WORKLOG_DIR` | `~/.claude/time-logger/worklogs` |
| `WORKLOG_PROJECT_DIRS` | `~/projects:~/src:~/code:~/dev:~/git` |
| `WORKLOG_LANG` | `English` |
| `WORKLOG_IDLE_GAP_MIN` | `30` |
| `WORKLOG_TARGET_HOURS` | `40` |
| `WORKLOG_SUMMARY_MODEL` | `claude-haiku-4-5` |
| `WORKLOG_REPORT_MODEL` | `claude-sonnet-5` |
| `WORKLOG_JIRA_BASE` | unset — Jira source skipped |
| `WORKLOG_CAL_AUTH_FILE` | `~/.claude/time-logger/cal-auth` — absent, calendar skipped |
| `WORKLOG_CAL_IDS` | `primary` (colon-separated) |
| `WORKLOG_CAL_MIN_MINUTES` | `45` |
| `WORKLOG_CAL_MAX_MINUTES` | `480` |
| `WORKLOG_CAL_SKIP_DECLINED` | `1` |
| `WORKLOG_CAL_ICS_FILE` | `~/.claude/time-logger/cal-ics` — feed URLs, wins over OAuth |
| `WORKLOG_PROJECT_LINKS_FILE` | `~/.claude/time-logger/project-links.map` — optional backlog URLs |
| `WORKLOG_REAP_LOOKBACK_DAYS` | `60` |
| `WORKLOG_REAP_STALE_HOURS` | `12` |
| `WORKLOG_REAP_NOT_BEFORE` | unset — no floor (e.g. `2026-W33`) |
| `WORKLOG_REAP_MAX_PER_RUN` | `200` |
| `WORKLOG_PENDING_DIR` | `~/.claude/time-logger/pending` |
| `WORKLOG_SUMMARY_LOOKBACK_DAYS` | `60` |
| `WORKLOG_REAP_MIN_MINUTES` | `1` |
| `WORKLOG_CODEX_TRANSCRIPT_DIR` | `~/.codex/sessions` |
| `WORKLOG_MODEL_BACKEND` | `claude` (Codex skill sets `codex` for generation) |
| `WORKLOG_CODEX_MODEL` | unset (Codex default model) |

Jira needs `~/.claude/time-logger/jira-auth` containing `email:api-token`, and a
`repo-project.map` next to it. Auth is Basic, not Bearer. A read-only scoped token
is enough, and is the point: the plugin cannot write worklogs back to Jira.

A repo may map to several projects — `example-repo⇥PROJ,OTHER` — because repos carry
work for more than one over time. Auth is checked against `/myself` before the
search runs: search answers an unauthenticated request with 200 and an empty
list, so without that probe an expired token reads as a week with no tickets.

### Calendar

Planning, retro and demo day are the hours no commit and no session records, so
without this the timesheet's meetings row is whatever it takes to reach the
target. With it, those hours come from what was actually in the calendar.

Two ways in. Both end up in the same place, and the feed wins if you set up both.

**A. iCal feed — no Cloud project, no admin.**

1. Google Calendar → hover the calendar → ⋮ → *Settings and sharing* →
   **Integrate calendar** → copy **Secret address in iCal format**.
2. `bin/cal-feed.py`, paste it at the prompt. It is not echoed, never appears
   on a command line, and is masked in the confirmation — that URL is a bearer
   credential and anyone holding it reads the whole calendar. The helper
   fetches once to prove the feed works and reports how many meetings this
   week clears the filters, then writes `~/.claude/time-logger/cal-ics` 0600.
   `--add` appends a second calendar; `--force` accepts a non-Google feed.

Needs `python3-dateutil`: a feed carries recurrence *rules*, so `RRULE` is
expanded locally, `EXDATE` occurrences dropped and `RECURRENCE-ID` overrides
applied. Google's export can lag edits by a few hours, which does not matter for
a week that is already over. Whether declined events can be filtered depends on
the feed carrying `ATTENDEE` lines matching your git `user.email`; when it does
not, that filter is a no-op.

**B. OAuth — needs a Google Cloud project you can create.**

1. Console: enable the Calendar API, then Credentials → Create credentials →
   OAuth client ID → **Desktop app**.
2. On the consent screen set the user type to **Internal** if the project is in
   your work Workspace. An External client left in *Testing* hands out refresh
   tokens that expire after seven days, and the calendar section would then go
   quiet every week.
3. `bin/cal-auth.py`, paste the client ID and secret, approve in the browser.
   It writes `~/.claude/time-logger/cal-auth` (chmod 600).

Recurrence is expanded by Google here, so nothing beyond the stdlib is needed.

The OAuth scope is `calendar.events.readonly`. Either way a weekly retro shows
up as this week's occurrence, a moved one at its new time and a cancelled one
not at all. Only meetings between `WORKLOG_CAL_MIN_MINUTES` and
`WORKLOG_CAL_MAX_MINUTES` are collected — long enough to be a ceremony, short
enough not to be an all-day OOO block — and the report notes which of those
hours overlapped a logged session, so nothing is counted twice.

## How it works

`SessionEnd` records the facts and drops a sidecar; `SessionStart` records a stub
and reaps sessions that never got a row. In Codex, the hooks also launch a
detached child to summarise pending rows. It writes to the worklog and has no
conversation output. Claude Code keeps the deferred `/timelog` workflow.
Timesheets are drafted by `/timelog` when you request one.

Six things are less obvious than they look:

- **Active time is not wall clock.** Terminals sit open for days on a resumed
  session. Minutes are the sum of inter-message gaps with anything over
  `WORKLOG_IDLE_GAP_MIN` discarded.
- **One row per session, not per SessionEnd.** A resumed session fires again with
  a cumulative minute count. Each row hides a session marker and the previous row
  is deleted before the new one is written, across all week files, since a resume
  can cross a week boundary.
- **Reports generate detached.** The summarising call runs for minutes, far past
  any hook budget. The stamp that closes the gate is written when the report
  reaches a session, not when it is generated, so a failed run just retries.
- **Summaries run outside the hook budget.** A summary call costs
  16-34 s, and `SessionEnd` blocks the session exiting for every second of it.
  So the hook writes the row with `_(pending)_` and a marker of `s:0`, plus a
  sidecar holding the digest. In Codex, a detached child turns these into prose
  and flips `s:1`; `/timelog` can retry any remaining sidecars.
  The facts are the perishable part — they only exist while the transcript does;
  the prose can be produced any time.
- **The sidecar outlives the transcript.** Claude Code prunes transcripts at
  about 30 days. Deferring summaries to a transcript-only design would mean a
  row left alone for a month is blank forever. The sidecar is the same digest
  the summariser would have used, kept until the row is filled and deleted the
  moment it is — a work queue, not an archive.
- **A failed summary is retried, not frozen.** `claude -p` prints "Not logged
  in", usage limits and network errors to *stdout* and exits non-zero, so the
  exit status decides. A failure leaves `s:0` and keeps the sidecar; the earlier
  design wrote a placeholder that nothing ever revisited.
- **A killed session still gets logged.** `SessionEnd` does not fire on a closed
  terminal, a SIGKILL or a reboot, and the open-session stub ages out after 48 h,
  so the work would vanish. `worklog-reap.sh` finds transcripts untouched for
  `WORKLOG_REAP_STALE_HOURS` with no row yet and writes them, detached and behind
  a lock. Every prompt appends to its transcript, so mtime is already the
  heartbeat — no per-prompt hook is needed. It refuses weeks that already have a
  report, since rewriting a timesheet you have read is worse than a missing row.
- **Hours come from intervals, not from the Min column.** Each row hides the
  active stretches it covers as epoch ranges. The report cuts them at midnight
  and unions them per day, so two terminals open on one repo count that hour once
  and a session spanning days lands on the days it actually spanned. Summing Min
  double-counts both.
- **The current week is never reported.** A mid-week report looks complete, and
  once injected it closes the gate for good. Pass `--force` if you want one
  anyway. A worklog newer than its report also forces a regenerate.

Two sources, deliberately redundant: session rows are rich but vanish when a
session is killed; `git log --author` is thin but survives everything.

## Requirements

`bash`, `python3`, `git`, and the `claude` CLI on `PATH`. Codex auto summaries
also need `codex` and `flock`; `setsid` is used when available. The iCal calendar
source additionally needs `python3-dateutil`; nothing else does.

## Known limits

In Codex, the "What was done" column reads `_(pending)_` until the detached
summary finishes. A failed summary remains pending for the next session start
or `/timelog`.

A session that wanders between directories is labelled by the one it ended in.

Commits are matched by your global `user.email`, so a repo-local override hides
them, and a commit made after the last message falls outside the window.

Calendar hours are what was scheduled, not what was attended: a meeting that
ended early still counts in full, and one you never marked as declined counts
even if you skipped it.

Ticket attribution is only as good as the weekly draft that produced it. The
activity ledger presents that judgement, it does not re-check it — amber exists
precisely because some rows are a guess.

## Tests

`bash tests/simtest.sh` — builds a throwaway `$HOME`, synthesises transcripts,
stubs `claude`, asserts on the rows and the report context. No model calls, and
nothing outside the sandbox is touched.

## License

MIT
