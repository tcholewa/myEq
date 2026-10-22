#!/usr/bin/env python3
"""Check source/config syntax and local documentation links without building audio code."""
import ast
import plistlib
import re
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlsplit
from xml.etree import ElementTree


repo = Path(__file__).resolve().parent.parent
paths = subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=repo,
).decode().split("\0")
files = sorted({repo / path for path in paths if path and (repo / path).is_file()})
links = 0
for path in files:
    suffix = path.suffix.lower()
    if suffix == ".py":
        ast.parse(path.read_text(), filename=str(path.relative_to(repo)))
    elif suffix == ".sh" or path.parent == repo / "Installer/scripts":
        subprocess.run(["bash", "-n", str(path)], check=True)
    elif suffix == ".plist":
        plistlib.loads(path.read_bytes())
    elif suffix in {".xml", ".xcscheme"}:
        ElementTree.parse(path)
    elif suffix == ".md":
        text = path.read_text()
        # Ignore fenced examples; validate inline Markdown and HTML image links.
        text = re.sub(r"```.*?```", "", text, flags=re.S)
        targets = re.findall(r"!?\[[^\]\n]*\]\(([^\s)]+)\)", text)
        targets += re.findall(r'<img\b[^>]*\bsrc="([^"]+)"', text)
        for target in targets:
            url = urlsplit(target)
            if url.scheme or url.netloc or not url.path:
                continue
            local = (path.parent / unquote(url.path)).resolve()
            if not (local == repo or repo in local.parents) or not local.exists():
                raise SystemExit(f"Broken local link in {path.relative_to(repo)}: {target}")
            links += 1

for name in ["LICENSE", "THIRD_PARTY_NOTICES.md"]:
    if not (repo / name).is_file():
        raise SystemExit(f"Missing distribution notice: {name}")

print(f"PASS: checked {len(files)} repository files and {links} local documentation links.")
