#!/usr/bin/env python3
"""Check that every relative Markdown link in the repo points at a file that
exists. External (http/https/mailto) links and pure #anchors are skipped. This
catches the usual rot when chapters get renamed or moved. Run via `make links`.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
SKIP = ("http://", "https://", "mailto:", "#", "tel:")


def main() -> int:
    broken = []
    checked = 0
    for md in sorted(ROOT.rglob("*.md")):
        if "/.git/" in str(md):
            continue
        for m in LINK.finditer(md.read_text(encoding="utf-8")):
            target = m.group(1).strip()
            if target.startswith(SKIP) or not target:
                continue
            path = target.split("#", 1)[0]
            if not path:
                continue
            # leading "/" is a docsify root-relative route; else relative to this file
            base = ROOT if path.startswith("/") else md.parent
            cand = base / path.lstrip("/")
            # docsify routes drop the .md extension; try both
            candidates = [cand]
            if cand.suffix == "":
                candidates.append(cand.with_name(cand.name + ".md"))
            checked += 1
            if not any(c.exists() for c in candidates):
                broken.append(f"{md.relative_to(ROOT)} -> {target}")
    if broken:
        print("broken links:")
        for b in broken:
            print("  FAIL", b)
    print(f"\n{checked} relative links checked, {len(broken)} broken")
    return 1 if broken else 0


if __name__ == "__main__":
    raise SystemExit(main())
