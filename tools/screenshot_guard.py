#!/usr/bin/env python3
"""screenshot_guard: find and black out sensitive text in screenshots before publishing.

Commands
  scan   PATH...   report findings, exit 1 if there are any (use in CI and pre-commit)
  redact PATH...   black out findings in place, then re-run scan to confirm

What it looks for (all found with OCR, so always look at the result yourself)
  * public IPv4 and IPv6 addresses (private, loopback and well known public DNS are allowed)
  * malformed four-part numbers that look like an IP the OCR misread
  * Oracle Cloud OCIDs, SSH and PEM key material, long base64-like blobs
  * a value that follows the words password, secret, token or passphrase
  * anything in your private literals file (fuzzy matched, tolerant of OCR mistakes)
  * anything covered by a manual box file (for text OCR cannot read)

The literals file lists strings you know are sensitive, one per line, for example
your real IPs or account name. It must NEVER be committed, keep it outside the repo
or use tools/redaction.local.txt, which is git-ignored.

Manual boxes are fractions of the image size:
  {"part2/06-instance-running.png": [[0.30, 0.63, 0.56, 0.66, "ocid"]]}

Output never prints the sensitive text itself, only its first characters and length,
so CI logs of a public repository do not leak it.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import sys
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path

try:
    import pytesseract
    from PIL import Image, ImageDraw, ImageOps, ImageStat
except ImportError as exc:  # pragma: no cover
    sys.exit(f"missing dependency: {exc}. Install with: pip install pillow pytesseract (and the tesseract binary)")

IMAGE_EXTS = {".png", ".jpg", ".jpeg"}

# Public resolvers that appear in VPN documentation and are not sensitive.
DEFAULT_ALLOW = {
    "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112",
    "208.67.222.222", "208.67.220.220",
}

IPV4_RE = re.compile(r"(?<![\d.])(?:\d{1,3}[.,]){3}\d{1,3}(?![\d])")
IPV6_RE = re.compile(r"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{0,4}")
# OCR often reads the digit 1 as l or i, so accept those in the OCID prefix.
OCID_RE = re.compile(r"oc[il1]d[il1]\.|\.oc[il1]\.(?:phx|iad|ams|fra|lhr|[a-z]{3})", re.IGNORECASE)
KEYWORD_RE = re.compile(r"ssh-(?:rsa|ed25519)|ecdsa-sha2-\S+|AAAAB3Nza|AAAAC3Nza|-----BEGIN [A-Z ]+-----")
BLOB_RE = re.compile(r"[A-Za-z0-9+/=_-]{40,}")
CRED_RE = re.compile(
    r"(?i)\b(?:password|passwd|secret|token|passphrase)\b[^A-Za-z0-9]{0,6}(?:is\s+)?[\"']?([A-Za-z0-9!@#$%^&*_+=-]{8,})"
)

CONFUSABLE = str.maketrans({"o": "0", "l": "1", "i": "1", "s": "5", "b": "8", "z": "2", "g": "9", "q": "9"})


@dataclass
class Finding:
    kind: str
    text: str
    box: tuple  # x, y, w, h in the original image

    def masked(self) -> str:
        return f"{self.text[:3]}*** ({len(self.text)} chars)"


def norm(value: str, numeric: bool) -> str:
    out = re.sub(r"[^0-9a-z]", "", value.lower())
    return out.translate(CONFUSABLE) if numeric else out


def is_numericish(value: str) -> bool:
    chars = [c for c in value if c.isalnum()]
    return bool(chars) and sum(c.isdigit() for c in chars) / len(chars) >= 0.5


def longest_common(a: str, b: str) -> int:
    if not a or not b:
        return 0
    return SequenceMatcher(None, a, b, autojunk=False).find_longest_match(0, len(a), 0, len(b)).size


def load_literals(path: str | None) -> list[str]:
    if not path:
        return []
    lines = Path(path).read_text().splitlines()
    return [ln.strip() for ln in lines if ln.strip() and not ln.lstrip().startswith("#")]


# --------------------------------------------------------------------------- OCR

def ocr_passes(img: Image.Image, fast: bool):
    """Yield (crop_origin, scale, image) tuples to run OCR on."""
    w, h = img.size
    gray = img.convert("L")
    dark = ImageStat.Stat(gray).mean[0] < 110
    scales = (2,) if fast else (2, 3)
    for s in scales:
        yield (0, 0), s, gray.resize((w * s, h * s), Image.LANCZOS)
        if dark:
            yield (0, 0), s, ImageOps.invert(gray).resize((w * s, h * s), Image.LANCZOS)
    # Browser URL bars and clipped bottom rows hold tiny text, so give them their own pass.
    top = gray.crop((0, 0, w, max(int(h * 0.09), 24)))
    yield (0, 0), 4, top.resize((top.width * 4, top.height * 4), Image.LANCZOS)
    bh = max(int(h * 0.14), 40)
    bottom = gray.crop((0, h - bh, w, h))
    yield (0, h - bh), 4, bottom.resize((bottom.width * 4, bottom.height * 4), Image.LANCZOS)


def read_lines(img: Image.Image, fast: bool):
    """Return OCR lines as a list of words: each word is (text, (x, y, w, h)) in original pixels."""
    lines = []
    for (ox, oy), scale, pic in ocr_passes(img, fast):
        data = pytesseract.image_to_data(pic, output_type=pytesseract.Output.DICT, config="--psm 11")
        groups: dict = {}
        for i, text in enumerate(data["text"]):
            if not text.strip():
                continue
            key = (data["block_num"][i], data["par_num"][i], data["line_num"][i])
            box = (ox + data["left"][i] / scale, oy + data["top"][i] / scale,
                   data["width"][i] / scale, data["height"][i] / scale)
            groups.setdefault(key, []).append((text, box))
        lines.extend(groups.values())
    return lines


def union(boxes) -> tuple:
    x0 = min(b[0] for b in boxes)
    y0 = min(b[1] for b in boxes)
    x1 = max(b[0] + b[2] for b in boxes)
    y1 = max(b[1] + b[3] for b in boxes)
    return (x0, y0, x1 - x0, y1 - y0)


def words_for_span(words, starts, span):
    """Boxes of the words overlapping the character span in the joined line text."""
    return [words[i][1] for i, (s, e) in enumerate(starts) if s < span[1] and e > span[0]]


# --------------------------------------------------------------------------- detection

def detect_line(words, literals, allow) -> list[Finding]:
    text, starts, pos = "", [], 0
    for w, _ in words:
        starts.append((pos, pos + len(w)))
        text += w + " "
        pos += len(w) + 1
    found: list[Finding] = []

    def add(kind, span):
        boxes = words_for_span(words, starts, span)
        if boxes:
            found.append(Finding(kind, text[span[0]:span[1]], union(boxes)))

    for m in IPV4_RE.finditer(text):
        raw = m.group(0).replace(",", ".")
        parts = raw.split(".")
        try:
            ip = ipaddress.IPv4Address(raw)
            if ip.is_global and raw not in allow:
                add("public-ip", m.span())
        except ValueError:
            if all(p.isdigit() for p in parts):
                add("malformed-ip", m.span())

    for m in IPV6_RE.finditer(text):
        ip = parse_ipv6(m.group(0))
        if ip is not None and ip.is_global:
            add("public-ipv6", m.span())

    for m in OCID_RE.finditer(text):
        end = text.find(" ", m.start())
        add("ocid", (m.start(), end if end != -1 else len(text)))

    for m in KEYWORD_RE.finditer(text):
        add("key-material", (m.start(), len(text)))

    for m in BLOB_RE.finditer(text):
        token = m.group(0)
        if token.startswith("/") or "://" in text[max(0, m.start() - 8):m.start() + 3]:
            continue
        if any(seg in token for seg in (".com", ".net", ".org", "/usr", "/etc", "/lib", "/var")):
            continue
        add("key-material", m.span())

    for m in CRED_RE.finditer(text):
        token = m.group(1)
        if any(c.isdigit() for c in token) and any(c.isalpha() for c in token):
            add("credential", m.span(1))

    for lit in literals:
        numeric = is_numericish(lit)
        target = norm(lit, numeric)
        need = max(6, int(len(target) * 0.8))
        for n in (1, 2, 3):
            for i in range(0, len(words) - n + 1):
                cand = "".join(w for w, _ in words[i:i + n])
                nc = norm(cand, numeric)
                if len(nc) >= 5 and longest_common(nc, target) >= need:
                    found.append(Finding("literal", cand, union([b for _, b in words[i:i + n]])))
    return found


def parse_ipv6(value: str):
    for candidate in (value, value.rstrip(":")):
        try:
            return ipaddress.IPv6Address(candidate)
        except ValueError:
            continue
    return None


def dedupe(findings: list[Finding]) -> list[Finding]:
    out: list[Finding] = []
    for f in sorted(findings, key=lambda f: (f.box[1], f.box[0])):
        x, y, w, h = f.box
        dup = False
        for o in out:
            ox, oy, ow, oh = o.box
            ix = max(0, min(x + w, ox + ow) - max(x, ox))
            iy = max(0, min(y + h, oy + oh) - max(y, oy))
            if ix * iy > 0.5 * min(w * h, ow * oh):
                dup = True
                break
        if not dup:
            out.append(f)
    return out


def scan_image(path: str, literals: list[str], allow: set, fast: bool) -> list[Finding]:
    with Image.open(path) as im:
        img = im.convert("RGB")
    found = []
    for words in read_lines(img, fast):
        found.extend(detect_line(words, literals, allow))
    return dedupe(found)


def manual_findings(path: Path, root: Path, boxes: dict, size) -> list[Finding]:
    try:
        rel = path.resolve().relative_to(root).as_posix()
    except ValueError:
        rel = path.name
    out = []
    for x0, y0, x1, y1, label in boxes.get(rel, []):
        w, h = size
        out.append(Finding(f"manual:{label}", "<manual box>", (x0 * w, y0 * h, (x1 - x0) * w, (y1 - y0) * h)))
    return out


def apply_boxes(path: Path, findings: list[Finding]) -> None:
    with Image.open(path) as im:
        img = im.convert("RGB")
    draw = ImageDraw.Draw(img)
    for f in findings:
        x, y, w, h = f.box
        rect = [x - 3, y - 3, x + w + 3, y + h + 3]
        draw.rectangle(rect, fill=(15, 15, 18))
        draw.rectangle(rect, outline=(200, 40, 40), width=1)
    img.save(path)


# --------------------------------------------------------------------------- CLI

def collect(paths: list[str]) -> list[Path]:
    files: list[Path] = []
    for p in map(Path, paths):
        if p.is_dir():
            files.extend(sorted(f for f in p.rglob("*") if f.suffix.lower() in IMAGE_EXTS))
        elif p.suffix.lower() in IMAGE_EXTS:
            files.append(p)
    return files


def _scan_job(args):
    return args[0], scan_image(*args)


def run_scan(files, literals, allow, fast, jobs):
    results = {}
    work = [(str(f), literals, allow, fast) for f in files]
    if jobs > 1 and len(work) > 1:
        with ProcessPoolExecutor(max_workers=jobs) as pool:
            for path, found in pool.map(_scan_job, work):
                results[path] = found
    else:
        for w in work:
            results[w[0]] = scan_image(*w)
    return results


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["scan", "redact"])
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--literals", help="file of sensitive strings, one per line (never commit it)")
    ap.add_argument("--boxes", help="JSON file of manual redaction boxes (fractions), used by redact")
    ap.add_argument("--root", default=".", help="directory the keys in the boxes file are relative to")
    ap.add_argument("--allow", action="append", default=[], help="extra public IP to allow (repeatable)")
    ap.add_argument("--fast", action="store_true", help="single OCR scale, quicker but may miss tiny text")
    ap.add_argument("--jobs", type=int, default=min(4, os.cpu_count() or 1))
    args = ap.parse_args(argv)

    files = collect(args.paths)
    if not files:
        print("no images found")
        return 0
    literals = load_literals(args.literals)
    allow = DEFAULT_ALLOW | set(args.allow)
    boxes = json.loads(Path(args.boxes).read_text()) if args.boxes else {}
    root = Path(args.root).resolve()

    results = run_scan(files, literals, allow, args.fast, args.jobs)

    total = 0
    for f in files:
        found = results[str(f)]
        if args.command == "redact" and boxes:
            with Image.open(f) as im:
                found = found + manual_findings(f, root, boxes, im.size)
        if not found:
            continue
        total += len(found)
        print(f"{f}")
        for item in found:
            print(f"   {item.kind:<14} {item.masked()}")
        if args.command == "redact":
            apply_boxes(f, found)

    if args.command == "redact":
        print(f"\nredacted {total} region(s) in place. Now look at every image yourself, OCR can miss text.")
        return 0
    if total:
        print(f"\n{total} possible sensitive item(s) found")
        return 1
    print(f"scanned {len(files)} image(s): nothing found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
