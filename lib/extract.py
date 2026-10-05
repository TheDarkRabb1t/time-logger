#!/usr/bin/env python3
"""Reduce a session transcript to the facts a worklog row needs.

    extract.py <transcript.jsonl> <idle_gap_minutes> [--shell] [--convo-out FILE]

Prints one JSON object, or nothing when the transcript holds no usable
timestamps. Shared by session-log.sh (clean exit) and worklog-reap.sh (session
died) so the two cannot drift apart — they must produce identical rows for the
same transcript, since either may be the one that writes it.

--shell prints `WL_<KEY>=<shell-quoted>` instead, so a hook can `eval` the lot
in one python start rather than one per field; --convo-out drops the digest in
a file, keeping a 12 KB blob out of the shell entirely. Together they are what
lets SessionEnd finish in milliseconds.
"""

import datetime
import json
import shlex
import subprocess
import sys


def parse(t):
    try:
        return datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))
    except Exception:
        return None


def main():
    path, idle_gap = sys.argv[1], int(sys.argv[2]) * 60
    as_shell = "--shell" in sys.argv
    convo_out = ""
    if "--convo-out" in sys.argv:
        convo_out = sys.argv[sys.argv.index("--convo-out") + 1]

    first_ts = last_ts = None
    cwd = branch = ""
    session_id = ""
    turns = 0
    users, assists, stamps = [], [], []

    for ln in open(path, errors="replace"):
        try:
            d = json.loads(ln)
        except Exception:
            continue
        if d.get("type") == "session_meta":
            meta = d.get("payload") or {}
            cwd = meta.get("cwd") or cwd
            session_id = meta.get("id") or meta.get("session_id") or session_id
            continue
        if d.get("type") == "turn_context":
            cwd = (d.get("payload") or {}).get("cwd") or cwd
            continue
        if d.get("type") == "response_item":
            item = d.get("payload") or {}
            if item.get("type") != "message" or item.get("role") not in ("user", "assistant"):
                continue
            if item["role"] == "user":
                kinds = (item.get("internal_chat_message_metadata_passthrough") or {}).get("content_item_kinds")
                if kinds and not any(kind.startswith("user.") for kind in kinds):
                    continue
            parts = [b.get("text", "") for b in item.get("content") or []
                     if isinstance(b, dict) and b.get("type") in ("input_text", "output_text")]
            body = "\n".join(p for p in parts if p).strip()
            if not body:
                continue
            ts = d.get("timestamp")
            if ts:
                first_ts = first_ts or ts
                last_ts = ts
                stamps.append(ts)
            if item["role"] == "user":
                turns += 1
                users.append(body[:1500])
            elif item.get("phase") in ("final", "commentary", None):
                assists.append(body[:1200])
            continue
        if d.get("type") not in ("user", "assistant") or d.get("isSidechain"):
            continue

        ts = d.get("timestamp")
        if ts:
            first_ts = first_ts or ts
            last_ts = ts
            stamps.append(ts)
        cwd = d.get("cwd") or cwd
        branch = d.get("gitBranch") or branch

        content = (d.get("message") or {}).get("content")
        parts = []
        if isinstance(content, str):
            parts.append(content)
        elif isinstance(content, list):
            for b in content:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text":
                    parts.append(b.get("text", ""))
                elif b.get("type") == "tool_use":
                    parts.append("[tool:%s]" % b.get("name"))
        body = "\n".join(p for p in parts if p).strip()
        if not body:
            continue

        if d.get("type") == "user":
            # Tool results also arrive as role=user; real prompts carry
            # promptSource or a bare string content.
            if d.get("promptSource") or isinstance(content, str):
                turns += 1
                users.append(body[:1500])
        else:
            assists.append(body[:1200])

    marks = sorted(p for p in (parse(t) for t in stamps) if p)
    if not marks:
        return

    if session_id and cwd:
        try:
            branch = subprocess.run(
                ["git", "-C", cwd, "branch", "--show-current"],
                capture_output=True, text=True, timeout=2,
            ).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            pass

    # Wall clock is useless — terminals sit open for days on a resumed session.
    # Split the timeline wherever the gap exceeds idle_gap; what remains are the
    # stretches actually worked. Their total is the session's minutes, and the
    # stretches themselves are what lets the weekly report union overlapping
    # sessions instead of summing them (two terminals open on one repo used to
    # book the same hour twice) and split a session across the days it spans.
    intervals = []
    run_start = prev = marks[0]
    for cur in marks[1:]:
        if (cur - prev).total_seconds() > idle_gap:
            if prev > run_start:
                intervals.append((run_start, prev))
            run_start = cur
        prev = cur
    if prev > run_start:
        intervals.append((run_start, prev))

    active = sum((b - a).total_seconds() for a, b in intervals)
    span = int(active // 60)

    local = marks[-1].astimezone()
    start_local = marks[0].astimezone()

    # A session spanning several days shouldn't book all its time to the last.
    date_str = local.strftime("%Y-%m-%d")
    if start_local.date() != local.date():
        date_str = "%s->%s" % (start_local.strftime("%m-%d"), local.strftime("%m-%d"))

    convo = "\n\n".join(
        ["## What the user asked for"] + users[-12:] +
        ["## What the assistant did"] + assists[-12:]
    )[:12000]

    fields = {
        "cwd": cwd,
        "session_id": session_id,
        "repo": cwd.rstrip("/").split("/")[-1] if cwd else "-",
        "branch": branch or "-",
        "span": span,
        "turns": turns,
        "date": date_str,
        "day": local.strftime("%a"),
        "week": local.strftime("%G-W%V"),
        "first_ts": first_ts or "",
        "last_ts": last_ts or "",
        # Epoch seconds, so the report can union them without reparsing dates.
        "intervals": ",".join("%d-%d" % (a.timestamp(), b.timestamp())
                              for a, b in intervals),
    }

    if convo_out:
        with open(convo_out, "w") as fh:
            fh.write(convo)

    if as_shell:
        for k, v in fields.items():
            print("WL_%s=%s" % (k.upper(), shlex.quote(str(v))))
    else:
        fields["convo"] = convo
        print(json.dumps(fields))


if __name__ == "__main__":
    main()
