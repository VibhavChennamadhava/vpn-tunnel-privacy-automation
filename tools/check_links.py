#!/usr/bin/env python3
"""Check that relative links and images in markdown files point at real files."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINK = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
bad = 0
for md in sorted(ROOT.rglob("*.md")):
    if ".git" in md.parts:
        continue
    text = md.read_text(encoding="utf-8")
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    for target in LINK.findall(text):
        if re.match(r"^(https?:|mailto:|#)", target):
            continue
        path = (md.parent / target.split("#")[0]).resolve()
        if not path.exists():
            print(f"{md.relative_to(ROOT)}: broken link {target}")
            bad += 1
print("links ok" if not bad else f"{bad} broken link(s)")
sys.exit(1 if bad else 0)
