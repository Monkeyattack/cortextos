#!/usr/bin/env python3
"""Fail-closed date/weekday-pair validator for pack docs.

Built 2026-08-13 after the SECOND day-of-week error in
h137-bilateral-breakout.md (guardrail rule: two violations -> script check).

Scans markdown for date-with-weekday claims and validates the weekday against
the calendar. Exits 1 on any mismatch or on any parse ambiguity it cannot
resolve (fail-closed), 0 only when every detected pair checks out.

Usage: date-weekday-check.py [--year 2026] file.md [file2.md ...]
"""
import argparse
import datetime
import re
import sys

MONTHS = {m.lower()[:3]: i + 1 for i, m in enumerate(
    ["January", "February", "March", "April", "May", "June", "July",
     "August", "September", "October", "November", "December"])}
DAYS = {d.lower()[:3]: i for i, d in enumerate(
    ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"])}
DAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

MONTH_RE = r"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*"
DAY_RE = r"(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*"

# Forms: "Aug 7=Fri", "Aug-7 = Friday", "Tue Aug 11", "Friday, Aug 7", "Aug 7 (Fri)"
PATTERNS = [
    re.compile(rf"{MONTH_RE}[ -](\d{{1,2}})\s*=\s*{DAY_RE}"),
    # (?<![=\w]) stops cross-pair bleed: in "Aug 8=Sat, Aug 9" the "Sat" is
    # bound to Aug 8 by '=', so it must not pair with the following "Aug 9".
    re.compile(rf"(?<![=\w]){DAY_RE},?\s+{MONTH_RE}[ -](\d{{1,2}})"),
    re.compile(rf"{MONTH_RE}[ -](\d{{1,2}})\s*\(\s*{DAY_RE}\s*\)"),
]
# Pattern index -> (month_group, dom_group, day_group)
GROUP_ORDER = {0: (1, 2, 3), 1: (2, 3, 1), 2: (1, 2, 3)}


def check_file(path: str, year: int) -> int:
    failures = 0
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError as e:
        print(f"FAIL-CLOSED {path}: unreadable ({e})")
        return 1
    for lineno, line in enumerate(lines, 1):
        # Explicit per-line suppression for QUOTED MENTIONS of past errors
        # (e.g. a correction note citing the wrong string it replaced).
        # Invisible in rendered markdown: <!-- dw-skip: reason -->
        if "dw-skip" in line:
            continue
        for pi, pat in enumerate(PATTERNS):
            for m in pat.finditer(line):
                mg, dg, wg = GROUP_ORDER[pi]
                month = MONTHS[m.group(mg).lower()[:3]]
                dom = int(m.group(dg))
                claimed = DAYS[m.group(wg).lower()[:3]]
                try:
                    actual = datetime.date(year, month, dom).weekday()
                except ValueError:
                    print(f"MISMATCH {path}:{lineno}: '{m.group(0)}' — invalid date for {year}")
                    failures += 1
                    continue
                if actual != claimed:
                    print(f"MISMATCH {path}:{lineno}: '{m.group(0)}' — "
                          f"{year}-{month:02d}-{dom:02d} is {DAY_NAMES[actual]}, "
                          f"text claims {DAY_NAMES[claimed]}")
                    failures += 1
    return failures


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--year", type=int, default=datetime.date.today().year,
                    help="year to resolve month/day dates against (default: current)")
    ap.add_argument("files", nargs="+")
    args = ap.parse_args()
    total = sum(check_file(f, args.year) for f in args.files)
    if total:
        print(f"FAIL: {total} date/weekday mismatch(es)")
        sys.exit(1)
    print("PASS: all date/weekday pairs consistent")


if __name__ == "__main__":
    main()
