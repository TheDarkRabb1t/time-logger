#!/usr/bin/env python3
"""Google Calendar's secret iCal feed, as a source of meetings.

The OAuth path asks Google for occurrences and gets them already expanded. A
feed carries the *rules* instead, so everything events.list would have done
server-side has to happen here: expand RRULE across the week, drop the
occurrences named in EXDATE, and apply RECURRENCE-ID overrides so a retro that
was moved shows at its new time and a cancelled one does not show at all.

Events come back shaped exactly like calendar.events.list items, so
weekly-report.sh filters, clips and nets them off sessions without caring which
source produced them.

RDATE is not handled - Google writes ceremonies as RRULE, and a bare RDATE
addition would simply be missed rather than misreported.
"""
import datetime
import urllib.request

try:
    from zoneinfo import ZoneInfo
except ImportError:                                     # pragma: no cover
    ZoneInfo = None

PARTSTAT = {"ACCEPTED": "accepted", "DECLINED": "declined",
            "TENTATIVE": "tentative", "NEEDS-ACTION": "needsAction"}


def _unfold(text):
    """RFC 5545 folds long lines by starting the continuation with a space."""
    lines = []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if line[:1] in (" ", "\t") and lines:
            lines[-1] += line[1:]
        else:
            lines.append(line)
    return lines


def _split(line):
    """NAME;PARAM=v;PARAM="a:b":VALUE -> (name, params, value).

    The scan tracks quotes because a quoted parameter may contain the colon
    that would otherwise look like the start of the value.
    """
    quoted, cut = False, len(line)
    for i, ch in enumerate(line):
        if ch == '"':
            quoted = not quoted
        elif ch == ":" and not quoted:
            cut = i
            break
    head, value = line[:cut], line[cut + 1:]
    bits = head.split(";")
    params = {}
    for bit in bits[1:]:
        key, _, val = bit.partition("=")
        params[key.upper()] = val.strip('"')
    return bits[0].upper(), params, value


def _text(value):
    return (value.replace("\\n", " ").replace("\\N", " ")
                 .replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\"))


def _dt(value, params, local):
    """An iCal date or date-time. Returns a date for all-day, else aware."""
    value = value.strip()
    if params.get("VALUE") == "DATE" or (len(value) == 8 and value.isdigit()):
        return datetime.date(int(value[:4]), int(value[4:6]), int(value[6:8]))
    naive = datetime.datetime.strptime(value.rstrip("Z"), "%Y%m%dT%H%M%S")
    if value.endswith("Z"):
        return naive.replace(tzinfo=datetime.timezone.utc)
    tzid = params.get("TZID")
    if tzid and ZoneInfo:
        try:
            return naive.replace(tzinfo=ZoneInfo(tzid))
        except Exception:
            pass
    # A floating time means "whatever local is", which is what a calendar
    # exported for one person is in practice.
    return naive.replace(tzinfo=local)


def _duration(value):
    """PT1H30M / P1DT2H -> timedelta. Weeks and days included, months are not
    expressible in a DURATION so nothing is lost."""
    value = value.strip().lstrip("+")
    sign = -1 if value.startswith("-") else 1
    value = value.lstrip("-")
    if not value.startswith("P"):
        return datetime.timedelta(0)
    days = seconds = 0
    num, in_time = "", False
    for ch in value[1:]:
        if ch == "T":
            in_time = True
        elif ch.isdigit():
            num += ch
        else:
            n = int(num or 0)
            num = ""
            if ch == "W":
                days += n * 7
            elif ch == "D":
                days += n
            elif ch == "H":
                seconds += n * 3600
            elif ch == "M":
                seconds += n * 60 if in_time else 0
            elif ch == "S":
                seconds += n
    return sign * datetime.timedelta(days=days, seconds=seconds)


def _blocks(text):
    """Every VEVENT as {NAME: [(params, value), ...]}."""
    events, current = [], None
    for line in _unfold(text):
        if line == "BEGIN:VEVENT":
            current = {}
        elif line == "END:VEVENT":
            if current is not None:
                events.append(current)
            current = None
        elif current is not None and ":" in line:
            name, params, value = _split(line)
            current.setdefault(name, []).append((params, value))
    return events


def _first(props, name):
    got = props.get(name)
    return got[0][1] if got else None


def _instant(when, local):
    """A comparable key for one occurrence, immune to how it was written."""
    if isinstance(when, datetime.datetime):
        return round(when.timestamp())
    return round(datetime.datetime.combine(
        when, datetime.time.min, tzinfo=local).timestamp())


def _reply(props, email):
    """Your PARTSTAT, when the feed carries one.

    A feed with no ATTENDEE lines - or one whose addresses never match - leaves
    this empty, and the declined filter downstream simply never fires. That is
    a quiet no-op by design: guessing which attendee is you would be worse.
    """
    if not email:
        return ""
    for params, value in props.get("ATTENDEE", []):
        who = value.split(":")[-1].strip().lower()
        if who == email.lower():
            return PARTSTAT.get(params.get("PARTSTAT", "").upper(), "")
    return ""


def _item(start, end, props, email, all_day):
    key = "date" if all_day else "dateTime"
    item = {"summary": _text(_first(props, "SUMMARY") or "(no title)"),
            "start": {key: start.isoformat()}, "end": {key: end.isoformat()}}
    status = (_first(props, "STATUS") or "").upper()
    if status == "CANCELLED":
        item["status"] = "cancelled"
    reply = _reply(props, email)
    if reply:
        item["attendees"] = [{"self": True, "responseStatus": reply}]
    return item


def _normalise_until(rule, dtstart):
    """dateutil refuses a naive UNTIL against an aware DTSTART, and some feeds
    write one. RFC 5545 says UNTIL is UTC in that case, so say so explicitly."""
    if dtstart.tzinfo is None or "UNTIL=" not in rule.upper():
        return rule
    out = []
    for part in rule.split(";"):
        key, _, val = part.partition("=")
        if key.upper() == "UNTIL" and not val.endswith("Z"):
            val = (val + "T235959Z") if len(val) == 8 else (val + "Z")
            part = f"{key}={val}"
        out.append(part)
    return ";".join(out)


def fetch(urls, win_lo, win_hi, email=""):
    """events.list-shaped dicts for everything overlapping [win_lo, win_hi)."""
    try:
        from dateutil.rrule import rrulestr
    except ImportError:
        raise RuntimeError(
            "the iCal calendar source needs python3-dateutil (apt install python3-dateutil)")

    local = datetime.datetime.now().astimezone().tzinfo
    raw = []
    for url in urls:
        with urllib.request.urlopen(url, timeout=30) as response:
            raw.extend(_blocks(response.read().decode("utf-8", "replace")))

    masters, overrides = [], {}
    for props in raw:
        uid = _first(props, "UID") or ""
        rid = props.get("RECURRENCE-ID")
        if rid:
            params, value = rid[0]
            overrides[(uid, _instant(_dt(value, params, local), local))] = props
        else:
            masters.append((uid, props))

    out = []
    for uid, props in masters:
        dtstart_raw = props.get("DTSTART")
        if not dtstart_raw:
            continue
        start = _dt(dtstart_raw[0][1], dtstart_raw[0][0], local)
        all_day = not isinstance(start, datetime.datetime)

        if props.get("DTEND"):
            end = _dt(props["DTEND"][0][1], props["DTEND"][0][0], local)
            length = ((datetime.datetime.combine(end, datetime.time.min, tzinfo=local)
                       if all_day else end)
                      - (datetime.datetime.combine(start, datetime.time.min, tzinfo=local)
                         if all_day else start))
        elif props.get("DURATION"):
            length = _duration(props["DURATION"][0][1])
        else:
            length = datetime.timedelta(days=1) if all_day else datetime.timedelta(0)

        anchor = (datetime.datetime.combine(start, datetime.time.min, tzinfo=local)
                  if all_day else start)

        rule = _first(props, "RRULE")
        if rule:
            # A day of slack at the low end catches a meeting that began before
            # Monday and runs into it; the caller clips to the real window.
            try:
                starts = rrulestr(_normalise_until(rule, anchor), dtstart=anchor).between(
                    win_lo - datetime.timedelta(days=1), win_hi, inc=True)
            except Exception:
                starts = []
        else:
            starts = [anchor]

        excluded = set()
        for params, value in props.get("EXDATE", []):
            for one in value.split(","):
                if one.strip():
                    excluded.add(_instant(_dt(one, params, local), local))

        for occurrence in starts:
            key = _instant(occurrence, local)
            if key in excluded or (uid, key) in overrides:
                continue
            finish = occurrence + length
            if finish <= win_lo or occurrence >= win_hi:
                continue
            if all_day:
                out.append(_item(occurrence.date(), finish.date(), props, email, True))
            else:
                out.append(_item(occurrence, finish, props, email, False))

    # A moved occurrence is its own VEVENT, and it may have been moved into the
    # week from outside it, so these are considered on their own terms.
    for (uid, _key), props in overrides.items():
        dtstart_raw = props.get("DTSTART")
        if not dtstart_raw:
            continue
        start = _dt(dtstart_raw[0][1], dtstart_raw[0][0], local)
        all_day = not isinstance(start, datetime.datetime)
        if props.get("DTEND"):
            end = _dt(props["DTEND"][0][1], props["DTEND"][0][0], local)
        elif props.get("DURATION"):
            end = start + _duration(props["DURATION"][0][1])
        else:
            end = start
        lo = start if isinstance(start, datetime.datetime) else datetime.datetime.combine(
            start, datetime.time.min, tzinfo=local)
        hi = end if isinstance(end, datetime.datetime) else datetime.datetime.combine(
            end, datetime.time.min, tzinfo=local)
        if hi <= win_lo or lo >= win_hi:
            continue
        out.append(_item(start, end, props, email, all_day))

    return out
