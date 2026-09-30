#!/usr/bin/env python3
"""Style check for docs and code: no em dashes, no en dashes, no trailing spaces.

Usage: check_style.py [PATH...]   (default: the whole repo)
Exit code 1 if anything is found.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEXT_SUFFIXES = {".md", ".sh", ".py", ".tf", ".tftpl", ".tfvars", ".example", ".yml", ".yaml",
                 ".json", ".txt", ".service", ".js", ".toml", ""}
BAD = {"—": "em dash", "–": "en dash"}


def tracked_files() -> list[Path]:
    try:
        out = subprocess.run(["git", "ls-files", "-co", "--exclude-standard"], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout.split("\n")
        return [ROOT / p for p in out if p]
    except (subprocess.CalledProcessError, FileNotFoundError):
        return [p for p in ROOT.rglob("*") if p.is_file() and ".git" not in p.parts]


def main(argv: list[str]) -> int:
    files = [Path(a).resolve() for a in argv] if argv else tracked_files()
    problems = 0
    for f in files:
        if f.suffix.lower() not in TEXT_SUFFIXES or f == Path(__file__).resolve():
            continue
        try:
            lines = f.read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        for n, line in enumerate(lines, 1):
            for ch, name in BAD.items():
                if ch in line:
                    print(f"{f.relative_to(ROOT)}:{n}: {name}")
                    problems += 1
            if line != line.rstrip() and f.suffix != ".md":
                print(f"{f.relative_to(ROOT)}:{n}: trailing whitespace")
                problems += 1
    if problems:
        print(f"{problems} style problem(s)")
        return 1
    print("style ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
