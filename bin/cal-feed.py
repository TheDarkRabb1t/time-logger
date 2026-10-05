#!/usr/bin/env python3
"""Store a Google Calendar secret iCal address, without it being seen.

That URL is a bearer credential: whoever holds it reads the whole calendar, and
there is no password on it. So it is never typed on a command line, where it
would land in shell history and in `ps`, and never echoed - getpass keeps it out
of the terminal scrollback too. It is fetched once to prove it works, written
0600, and reported back masked.

    bin/cal-feed.py [--add] [--force]

    --add     keep the feeds already stored and append this one
    --force   accept a URL that is not a Google secret address (a file:// path,
              or another provider's feed)

Get the URL from Calendar -> Settings and sharing -> Integrate calendar ->
"Secret address in iCal format".
"""
import datetime
import getpass
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import ics  # noqa: E402

PREFIX = "https://calendar.google.com/calendar/ical/"
dest = os.environ.get("WORKLOG_CAL_ICS_FILE") or os.path.expanduser(
    "~/.claude/time-logger/cal-ics")
add = "--add" in sys.argv
force = "--force" in sys.argv


def mask(url):
    """Keep the shape, lose the secret: .../ical/<who>/private-****/basic.ics"""
    parts = url.split("/")
    return "/".join("private-****" if p.startswith("private-") else p for p in parts)


url = getpass.getpass("Secret iCal URL (not echoed): ").strip()
if not url:
    sys.exit("Nothing entered.")

if not force:
    if not url.startswith(PREFIX):
        sys.exit(f"That does not start with {PREFIX}\n"
                 "It should come from Integrate calendar -> Secret address in iCal "
                 "format. Use --force to store it anyway.")
    if not url.endswith(".ics"):
        sys.exit("That does not end in .ics - looks like the wrong field. "
                 "Use --force to store it anyway.")
    if "private-" not in url:
        print("Warning: no `private-` segment - this may be the PUBLIC address, "
              "which only works if the calendar is public.", file=sys.stderr)

# Proving it works now beats a silent empty section in next week's report.
email = subprocess.run(["git", "config", "--global", "user.email"],
                       capture_output=True, text=True).stdout.strip()
today = datetime.date.today()
monday = today - datetime.timedelta(days=today.weekday())
lo = datetime.datetime.combine(monday, datetime.time.min).astimezone()
hi = lo + datetime.timedelta(days=7)

print("Fetching...")
try:
    events = ics.fetch([url], lo, hi, email)
except Exception as exc:
    sys.exit(f"Could not read that feed: {exc}\nNothing was written.")

low = float(os.environ.get("WORKLOG_CAL_MIN_MINUTES", 45))
high = float(os.environ.get("WORKLOG_CAL_MAX_MINUTES", 480))
timed = [e for e in events if "dateTime" in e["start"]]
kept = [e for e in timed
        if low <= (datetime.datetime.fromisoformat(e["end"]["dateTime"])
                   - datetime.datetime.fromisoformat(e["start"]["dateTime"])
                   ).total_seconds() / 60 <= high]

print(f"This week: {len(events)} events, {len(kept)} counted as "
      f"{'a meeting' if len(kept) == 1 else 'meetings'} ({low:.0f}-{high:.0f} min).")
if timed and not kept:
    print("None of them clear the duration filter - lower "
          "WORKLOG_CAL_MIN_MINUTES if that looks wrong.", file=sys.stderr)
if not any("attendees" in e for e in events):
    print("No attendee status in this feed, so declined meetings cannot be "
          "filtered out - they will be counted.", file=sys.stderr)

feeds = []
if add and os.path.exists(dest):
    feeds = [ln.strip() for ln in open(dest, errors="replace")
             if ln.strip() and not ln.startswith("#")]
    if url in feeds:
        sys.exit("That feed is already stored.")
feeds.append(url)

os.makedirs(os.path.dirname(dest), exist_ok=True)
fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    fh.write("\n".join(feeds) + "\n")
os.chmod(dest, 0o600)   # an existing file keeps its old mode through O_CREAT

print(f"\nStored {mask(url)}")
print(f"in {dest} (chmod 600){', ' + str(len(feeds)) + ' feeds total' if len(feeds) > 1 else ''}.")
