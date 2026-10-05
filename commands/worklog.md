---
description: Show logged sessions for a week (read-only)
---

Config lives in `~/.claude/time-logger/config.sh`; when a value is unset use the
default from `lib/common.sh` (worklogs default to `~/.claude/time-logger/worklogs`).

This command only reads. It never summarises, reaps or drafts — `/timelog` does
all of that.

Argument: `$ARGUMENTS`

- empty — read `worklog-<current ISO week>.md` and list the rows grouped by day,
  with minutes and commits.
- an ISO week such as `2026-W31` — the same for that week.

Strip the `<!--sid:...-->` markers from what you show.

Rows whose "What was done" reads `_(pending)_` have no summary yet. Count them
and end with a line saying how many, and that `/timelog` will fill them.

Do not sum the Min column into a day or week total: concurrent sessions overlap,
and a session spanning midnight books its minutes to the day it ended on. Say
"per-session minutes" if you show them, and point at `/timelog <week>` for real
hours, which come from unioned intervals.

If the file does not exist, say so and mention that rows appear when a session
ends, or when `/timelog` reaps sessions that died.
