#!/usr/bin/env python3
"""Write a generated summary into its row.

    fill_row.py <worklog_dir> <session_id> <summary>

Finds the row carrying <!--sid:<session_id> in any week file, replaces the
"What was done" cell and flips the marker's s:0 to s:1. Prints the week it
landed in, or nothing when no such row exists.

Done here rather than in sed because the summary is arbitrary text — it can
hold slashes, ampersands and newlines, all of which a sed replacement would
either mangle or execute.
"""

import glob
import os
import sys

SUMMARY_CELL = 7          # | date | day | workdir | branch | min | turns | HERE | files | commits |


def main():
    worklog_dir, sid, summary = sys.argv[1], sys.argv[2], sys.argv[3]

    # A pipe would add a column; a newline would split the row in two.
    summary = summary.replace("|", ";").replace("\n", " ").strip()
    if not summary:
        return

    marker = "<!--sid:" + sid
    for path in sorted(glob.glob(os.path.join(worklog_dir, "worklog-*.md"))):
        lines = open(path, errors="replace").read().splitlines()
        hit = False
        for i, line in enumerate(lines):
            if marker not in line:
                continue
            cells = line.split("|")
            if len(cells) <= SUMMARY_CELL:
                continue
            cells[SUMMARY_CELL] = " %s " % summary
            lines[i] = "|".join(cells).replace(";s:0-->", ";s:1-->")
            hit = True
        if hit:
            with open(path, "w") as fh:
                fh.write("\n".join(lines) + "\n")
            print(os.path.basename(path)[len("worklog-"):-len(".md")])
            return


if __name__ == "__main__":
    main()
