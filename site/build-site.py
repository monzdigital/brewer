#!/usr/bin/env python3
"""Builds docs/index.html (the GitHub Pages site) from site/index.template.html
by inlining the app screenshots as base64 data URIs. Usage:

    python3 site/build-site.py <shots-dir>
"""
import base64
import pathlib
import plistlib
import re
import sys

root = pathlib.Path(__file__).parent
template = (root / "index.template.html").read_text()
shots_dir = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / "shots"

# Keep the download link and labels in lockstep with the app version.
with open(root.parent / "packaging" / "Info.plist", "rb") as fh:
    version = plistlib.load(fh)["CFBundleShortVersionString"]
template = template.replace("{{VERSION}}", version)

used = set()

def inline(match: re.Match) -> str:
    name = match.group(1)
    used.add(name)
    path = shots_dir / f"{name}.png"
    data = base64.b64encode(path.read_bytes()).decode()
    return f"data:image/png;base64,{data}"

html = re.sub(r"\{\{SHOT:([a-z0-9-]+)\}\}", inline, template)
docs = root.parent / "docs"
docs.mkdir(exist_ok=True)
out = docs / "index.html"
out.write_text(html)
(docs / ".nojekyll").write_text("")
size_mb = out.stat().st_size / 1_000_000
print(f"docs/index.html written (v{version}) - {size_mb:.2f} MB, {len(used)} screenshots inlined: {sorted(used)}")
