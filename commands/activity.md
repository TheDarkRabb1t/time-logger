---
description: Render the per-day activity ledger as HTML
---

Argument: `$ARGUMENTS`

Run `${CLAUDE_PLUGIN_ROOT}/bin/activity.sh $ARGUMENTS` and report the path it
prints, plus any weeks it names as having no per-day rows.

A bare argument limits how many weeks are rendered, newest first: `/activity 4`.

No model is called and nothing is fetched — the attribution was decided when
each week was drafted, and this only lays it out. A week drafted before the
per-day block existed is listed as needing a redraft rather than omitted; run
`/timelog <week>` again to fill it in.
