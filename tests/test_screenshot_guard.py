#!/usr/bin/env python3
"""Tests for tools/screenshot_guard.py using a synthetic screenshot.

A real-looking public address is used on purpose: documentation ranges such as
203.0.113.0/24 are treated as non-public and would correctly be ignored.
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUARD = ROOT / "tools" / "screenshot_guard.py"

if shutil.which("tesseract") is None:
    print("SKIP: tesseract is not installed")
    sys.exit(0)

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("SKIP: Pillow is not installed")
    sys.exit(0)

FONT = next((p for p in (
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
) if Path(p).exists()), None)
if FONT is None:
    print("SKIP: no TrueType font available")
    sys.exit(0)

passed = failed = 0


def check(desc: str, cond: bool, detail: str = "") -> None:
    global passed, failed
    if cond:
        print(f"ok   - {desc}")
        passed += 1
    else:
        print(f"FAIL - {desc}")
        if detail:
            print(detail)
        failed += 1


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(GUARD), *args], capture_output=True, text=True)


def make_image(path: Path, lines: list[str]) -> None:
    font = ImageFont.truetype(FONT, 26)
    img = Image.new("RGB", (1300, 70 * len(lines) + 40), "white")
    draw = ImageDraw.Draw(img)
    for i, line in enumerate(lines):
        draw.text((30, 30 + 70 * i), line, fill="black", font=font)
    img.save(path)


with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)

    # 1. A clean image passes.
    clean = tmp / "clean.png"
    make_image(clean, [
        "DNS servers 1.1.1.1 and 1.0.0.1",
        "Tunnel network 10.66.66.0/24 gateway 10.66.66.1",
        "Listening on 127.0.0.1 port 1080",
    ])
    r = run("scan", str(clean), "--jobs", "1")
    check("clean image has no findings", r.returncode == 0, r.stdout + r.stderr)

    # 2. A leaky image is flagged, and the output does not echo the secrets.
    leaky = tmp / "leaky.png"
    make_image(leaky, [
        "Server public IP 93.184.216.34",
        "Resource ocid1.instance.oc1.phx.anyhqljrexampleexampleexample",
        "Please remember this password Zx9Kq2Lm7Pw4",
        "Account name acme-tenancy-42",
    ])
    lit = tmp / "literals.txt"
    lit.write_text("# sensitive strings\nacme-tenancy-42\n")
    r = run("scan", str(leaky), "--literals", str(lit), "--jobs", "1")
    check("leaky image exits 1", r.returncode == 1, r.stdout + r.stderr)
    for kind in ("public-ip", "ocid", "credential", "literal"):
        check(f"detects {kind}", kind in r.stdout, r.stdout)
    check("output never prints the full address", "93.184.216.34" not in r.stdout)
    check("output never prints the password", "Zx9Kq2Lm7Pw4" not in r.stdout)

    # 3. Redaction covers the findings, then a fresh scan is clean.
    r = run("redact", str(leaky), "--literals", str(lit), "--jobs", "1")
    check("redact succeeds", r.returncode == 0, r.stdout + r.stderr)
    r = run("scan", str(leaky), "--literals", str(lit), "--jobs", "1")
    check("image is clean after redaction", r.returncode == 0, r.stdout + r.stderr)

    # 4. Manual boxes are applied even when OCR sees nothing.
    blank = tmp / "sub" / "blank.png"
    blank.parent.mkdir()
    Image.new("RGB", (400, 200), "white").save(blank)
    boxes = tmp / "boxes.json"
    boxes.write_text('{"sub/blank.png": [[0.25, 0.25, 0.75, 0.75, "test"]]}')
    r = run("redact", str(blank), "--boxes", str(boxes), "--root", str(tmp), "--jobs", "1")
    with Image.open(blank) as im:
        centre = im.convert("RGB").getpixel((200, 100))
    check("manual box blacks out the region", centre[0] < 40 and centre[1] < 40, r.stdout + r.stderr)

print(f"\npassed: {passed}  failed: {failed}")
sys.exit(1 if failed else 0)
