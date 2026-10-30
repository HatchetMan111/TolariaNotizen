#!/usr/bin/env python3
"""Inject the Tolaria web runtime config loader into built HTML files.

The Tolaria web build reads ``window.TOLARIA_REMOTE_URL`` and
``window.TOLARIA_REMOTE_TOKEN`` at boot.  ``/tolaria-config.js`` is served by
nginx (behind Basic Auth) and must load before the application bundle.

Idempotent: running it twice never adds a second tag.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile
from pathlib import Path

TAG = '<script src="/tolaria-config.js"></script>'
TAG_RE = re.compile(r"""<script\b[^>]*\bsrc\s*=\s*["']/tolaria-config\.js["'][^>]*>\s*</script\s*>""", re.IGNORECASE)
HEAD_RE = re.compile(r"</head\s*>", re.IGNORECASE)
BODY_RE = re.compile(r"</body\s*>", re.IGNORECASE)


def html_files(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*.html") if p.is_file())


def inject(content: str) -> tuple[str, bool]:
    if TAG_RE.search(content):
        return content, False
    if HEAD_RE.search(content):
        return HEAD_RE.sub(lambda m: f"    {TAG}\n  {m.group(0)}", content, count=1), True
    if BODY_RE.search(content):
        return BODY_RE.sub(lambda m: f"    {TAG}\n  {m.group(0)}", content, count=1), True
    return content + f"\n{TAG}\n", True


def write_atomic(path: Path, content: str) -> None:
    mode = path.stat().st_mode
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dist", type=Path, help="web build directory (apps/web/dist)")
    parser.add_argument("--check", action="store_true", help="only verify, do not write")
    args = parser.parse_args()

    root = args.dist
    if not root.is_dir():
        print(f"inject-web-config: not a directory: {root}", file=sys.stderr)
        return 2

    files = html_files(root)
    if not files:
        print(f"inject-web-config: no HTML files under {root}", file=sys.stderr)
        return 2

    changed = 0
    missing = 0
    for path in files:
        content = path.read_text(encoding="utf-8")
        new_content, did_change = inject(content)
        if args.check:
            if TAG_RE.search(content):
                print(f"OK       {path}")
            else:
                print(f"MISSING  {path}")
                missing += 1
            continue
        if did_change:
            write_atomic(path, new_content)
            changed += 1
            print(f"INJECTED {path}")
        else:
            print(f"OK       {path}")

    if args.check:
        return 1 if missing else 0
    print(f"inject-web-config: {changed} file(s) changed, {len(files)} checked")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
