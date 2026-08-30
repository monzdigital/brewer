#!/usr/bin/env python3
"""Builds site/index.html from index.template.html by inlining the app
screenshots as base64 data URIs. Usage:

    python3 site/build-site.py <shots-dir>
"""
import base64
import pathlib
import re
import sys

root = pathlib.Path(__file__).parent
template = (root / "index.template.html").read_text()
shots_dir = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / "shots"

used = set()

def inline(match: re.Match) -> str:
    name = match.group(1)
    used.add(name)
    path = shots_dir / f"{name}.png"
    data = base64.b64encode(path.read_bytes()).decode()
    return f"data:image/png;base64,{data}"

html = re.sub(r"\{\{SHOT:([a-z0-9-]+)\}\}", inline, template)
out = root / "index.html"
out.write_text(html)
size_mb = out.stat().st_size / 1_000_000
print(f"index.html written — {size_mb:.2f} MB, {len(used)} screenshots inlined: {sorted(used)}")
