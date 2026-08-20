#!/usr/bin/env python3
"""Pre-publish humanization gate.

Fail-closed check that every article, script, or post clears before it reaches
WordPress (or any other publish surface). Replaces the old manual
em-dash/contraction read-through with the `untell` detector ensemble, and keeps
the two mechanical rules the ensemble does NOT enforce on its own:

  1. Zero em-dashes and en-dashes. untell's ai-tells catalog calls the em-dash
     the #1 AI tell but explicitly allows keeping one that was already in the
     source ("If the original had one, you may keep it"). The fleet rule is
     zero, non-overridable, headers included. So the gate asserts it directly.
  2. Zero hidden characters (zero-width, bidi, tag). untell scrubs these during
     a rewrite; the gate refuses to pass text that still carries them.

Then it scores the text with untell, section by section, and refuses to issue a
PASS on weak evidence: if the detector ensemble degrades to the `lite` tier, the
result is DEGRADED, not PASS. A gate that cannot measure does not clear.

Usage:
    prepublish-humanize-gate.py <file> [--threshold 0.30] [--tier full]
    prepublish-humanize-gate.py <file> --json

Exit codes:
    0  PASS      — no dashes, no hidden chars, every chunk under threshold
    1  FAIL      — a mechanical rule broke, or a chunk scored at/over threshold
    2  DEGRADED  — detectors unavailable/lite; no verdict can be issued
    3  ERROR     — bad input, skill not installed
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

SKILL_DIR = Path(
    os.environ.get("UNTELL_SKILL_DIR", Path.home() / ".claude" / "skills" / "untell")
)

# U+2014 em dash, U+2013 en dash. Also catch the horizontal bar (U+2015) and the
# two-/three-em variants, which paste in from the same sources.
DASHES = {
    "—": "em dash",
    "–": "en dash",
    "―": "horizontal bar",
    "⸺": "two-em dash",
    "⸻": "three-em dash",
}

# Zero-width, bidi controls, tag characters, BOM.
HIDDEN = re.compile(
    "[​-‏‪-‮⁠-⁤⁪-⁯﻿\U000e0000-\U000e007f]"
)

MAX_CHUNK_CHARS = 2000


def reexec_under_untell_python() -> None:
    """Re-run this script under the interpreter that actually has the detector stack.

    The gate imports untell in-process, so whichever interpreter launched us decides
    which detector tier is reachable. The system python3 here has a scikit-learn built
    against numpy 1.x, which raises a numpy ABI error and drops the ensemble to the weak
    lite tier. That would surface as DEGRADED on every run, so point ourselves at the
    untell venv instead and let the documented command stay a plain `python3 ...`.
    """
    if os.environ.get("_UNTELL_GATE_REEXEC"):
        return  # already re-executed once; never loop
    candidate = os.environ.get("UNTELL_PYTHON") or str(SKILL_DIR / ".venv" / "bin" / "python")
    if not os.path.isfile(candidate):
        return
    # Compare PREFIXES, not realpaths. A venv's bin/python is a symlink to the system
    # interpreter, so realpath(venv/bin/python) == realpath(/usr/bin/python3) and a
    # realpath comparison concludes we are already there while sys.path still points at
    # the system site-packages. The prefix is what actually differs.
    candidate_prefix = os.path.dirname(os.path.dirname(os.path.abspath(candidate)))
    if os.path.abspath(sys.prefix) == candidate_prefix:
        return
    env = dict(os.environ, _UNTELL_GATE_REEXEC="1")
    os.execve(candidate, [candidate, os.path.abspath(__file__), *sys.argv[1:]], env)


def load_untell():
    """Import untell's scorer. Prefer the installed package, fall back to the skill dir."""
    try:
        from untell.scripts.score import score_text  # type: ignore

        return score_text
    except Exception:
        pass
    if not (SKILL_DIR / "scripts" / "score.py").exists():
        sys.stderr.write(
            f"ERROR: untell skill not found at {SKILL_DIR}.\n"
            "Install it: curl -fsSL "
            "https://raw.githubusercontent.com/ssamba1/untell/main/install.sh | sh\n"
        )
        raise SystemExit(3)
    sys.path.insert(0, str(SKILL_DIR.parent))
    try:
        from untell.scripts.score import score_text  # type: ignore

        return score_text
    except Exception as exc:  # pragma: no cover - environment dependent
        sys.stderr.write(f"ERROR: could not import untell scorer: {exc}\n")
        raise SystemExit(3)


def find_dashes(text: str) -> list[dict]:
    """Every banned dash, with the line number and the line it sits on."""
    hits = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        for ch, name in DASHES.items():
            if ch in line:
                hits.append({"line": lineno, "char": name, "text": line.strip()[:160]})
    return hits


def find_hidden(text: str) -> list[dict]:
    hits = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        for m in HIDDEN.finditer(line):
            hits.append(
                {"line": lineno, "codepoint": f"U+{ord(m.group()):04X}", "col": m.start() + 1}
            )
    return hits


def chunk(text: str, limit: int = MAX_CHUNK_CHARS) -> list[tuple[str, str]]:
    """Split into (label, body). untell has no native chunking, so: split on `##`
    headers first, then break any oversized section on paragraph boundaries."""
    sections: list[tuple[str, str]] = []
    current_label = "intro"
    buf: list[str] = []
    for line in text.splitlines():
        if re.match(r"^#{2,6}\s+", line):
            if "".join(buf).strip():
                sections.append((current_label, "\n".join(buf)))
            current_label = line.lstrip("#").strip()[:60] or "section"
            buf = []
        else:
            buf.append(line)
    if "".join(buf).strip():
        sections.append((current_label, "\n".join(buf)))
    if not sections:
        sections = [("document", text)]

    out: list[tuple[str, str]] = []
    for label, body in sections:
        if len(body) <= limit:
            out.append((label, body))
            continue
        part, para_buf = 1, []
        size = 0
        # A paragraph can itself exceed the limit, so break those on sentence
        # boundaries first. Without this the grouping loop below emits the
        # oversized paragraph whole and the cap silently does nothing.
        units: list[str] = []
        for para in body.split("\n\n"):
            if len(para) <= limit:
                units.append(para)
                continue
            sent_buf, sent_size = [], 0
            for sent in re.split(r"(?<=[.!?])\s+", para):
                # A "sentence" with no terminal punctuation anywhere can still
                # blow the cap, so fall back to words for that last mile.
                pieces = [sent]
                if len(sent) > limit:
                    pieces, word_buf, word_size = [], [], 0
                    for word in sent.split():
                        if word_size + len(word) > limit and word_buf:
                            pieces.append(" ".join(word_buf))
                            word_buf, word_size = [], 0
                        word_buf.append(word)
                        word_size += len(word) + 1
                    if word_buf:
                        pieces.append(" ".join(word_buf))
                for piece in pieces:
                    if sent_size + len(piece) > limit and sent_buf:
                        units.append(" ".join(sent_buf))
                        sent_buf, sent_size = [], 0
                    sent_buf.append(piece)
                    sent_size += len(piece) + 1
            if sent_buf:
                units.append(" ".join(sent_buf))
        # Last resort for a single unbroken token longer than the cap (a base64
        # blob, a giant URL). Not prose, but the cap has to hold regardless.
        units = [
            u[i : i + limit] if len(u) > limit else u
            for u in units
            for i in range(0, max(len(u), 1), limit)
        ]
        for para in units:
            if size + len(para) > limit and para_buf:
                out.append((f"{label} (part {part})", "\n\n".join(para_buf)))
                part += 1
                para_buf, size = [], 0
            para_buf.append(para)
            size += len(para) + 2
        if para_buf:
            out.append((f"{label} (part {part})", "\n\n".join(para_buf)))
    return [(lbl, b) for lbl, b in out if b.strip()]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("file", help="Article / script / post to gate.")
    ap.add_argument("--threshold", type=float, default=0.30)
    ap.add_argument("--tier", default="full", choices=["lite", "full", "heavy", "commercial"])
    ap.add_argument(
        "--allow-lite",
        action="store_true",
        help="Accept a lite-tier score as a verdict. Off by default: lite is documented "
        "weak evidence in both directions, so it cannot clear a publish gate.",
    )
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    if args.tier != "lite":
        reexec_under_untell_python()

    path = Path(args.file)
    if not path.is_file():
        sys.stderr.write(f"ERROR: no such file: {path}\n")
        return 3
    text = path.read_text(encoding="utf-8")

    report: dict = {"file": str(path), "threshold": args.threshold}

    dashes = find_dashes(text)
    hidden = find_hidden(text)
    report["dashes"] = dashes
    report["hidden_chars"] = hidden

    # Mechanical rules first — they are cheap, and they are non-overridable.
    if dashes or hidden:
        report["verdict"] = "FAIL"
        report["reason"] = "mechanical rule violated before scoring"
        emit(report, args.json)
        return 1

    score_text = load_untell()
    chunks = chunk(text)
    results = []
    worst = 0.0
    tiers = set()
    for label, body in chunks:
        res = score_text(body, tier=args.tier, threshold=args.threshold)
        tiers.add(res.get("tier"))
        worst = max(worst, float(res.get("max") or 0.0))
        results.append(
            {
                "section": label,
                "chars": len(body),
                "max": res.get("max"),
                "flagged": float(res.get("max") or 0.0) >= args.threshold,
                "tier": res.get("tier"),
                "detectors": res.get("detectors"),
                "warning": res.get("warning"),
            }
        )
    report["sections"] = results
    report["max"] = round(worst, 4)
    report["tier_ran"] = sorted(t for t in tiers if t)

    if "lite" in tiers and not args.allow_lite:
        report["verdict"] = "DEGRADED"
        report["reason"] = (
            "detector ensemble fell back to the lite tier, which is documented weak "
            "evidence in both directions. Fix the interpreter (UNTELL_PYTHON) or pass "
            "--allow-lite to accept it explicitly. No PASS is issued on this evidence."
        )
        emit(report, args.json)
        return 2

    over = [r for r in results if (r["max"] or 0) >= args.threshold]
    if over:
        report["verdict"] = "FAIL"
        report["reason"] = f"{len(over)} section(s) at or over P(AI) {args.threshold}"
        emit(report, args.json)
        return 1

    report["verdict"] = "PASS"
    emit(report, args.json)
    return 0


def emit(report: dict, as_json: bool) -> None:
    if as_json:
        print(json.dumps(report, indent=2))
        return
    v = report["verdict"]
    print(f"{v}: {report['file']}")
    if report.get("reason"):
        print(f"  {report['reason']}")
    for d in report.get("dashes", []):
        print(f"  line {d['line']}: {d['char']}: {d['text']}")
    for h in report.get("hidden_chars", []):
        print(f"  line {h['line']} col {h['col']}: hidden {h['codepoint']}")
    for s in report.get("sections", []):
        mark = "!!" if s["flagged"] else "ok"
        print(f"  [{mark}] {s['max']:.3f}  {s['section']} ({s['chars']} chars, {s['tier']})")
    if "max" in report:
        print(f"  worst P(AI) = {report['max']} (threshold {report['threshold']})")


if __name__ == "__main__":
    raise SystemExit(main())
