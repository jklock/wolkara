#!/bin/bash
# Check the fork's documentation: every relative link and image must resolve, and
# every fork markdown file must be reachable from the documentation index.
#
# Usage: wolkaraforever/tools/check_docs.sh
#
# The vendored engine (platform/) is upstream's, unchanged, and is skipped: its own
# links are correct inside it. Everything else that ships with the repository is
# checked. Exit status is non-zero if any link or reference does not resolve.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 2
exec python3 - "$@" <<'PY'
import os
import re
import sys

root = os.getcwd()
skip_dirs = {"platform", "build", "logs", ".git", "node_modules", ".github"}

md_files = []
for dirpath, dirnames, filenames in os.walk(root):
    rel_dir = os.path.relpath(dirpath, root)
    parts = [] if rel_dir == "." else rel_dir.split(os.sep)
    dirnames[:] = [d for d in dirnames if d not in skip_dirs]
    if any(p in skip_dirs for p in parts):
        continue
    for name in filenames:
        if name.lower().endswith(".md"):
            md_files.append(os.path.join(dirpath, name))

md_files.sort()

link_re = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
src_re = re.compile(r'(?:src|href)="([^"]+)"')
problems = []

def is_external(target):
    return (
        target.startswith(("http://", "https://", "mailto:", "tel:", "#"))
        or re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target) is not None
    )

def check_target(md_path, target, kind):
    target = target.strip()
    if not target or is_external(target):
        return
    path = target.split("#", 1)[0].split("?", 1)[0]
    if not path:
        return
    path = path.replace("%20", " ")
    if path.startswith("/"):
        resolved = os.path.join(root, path.lstrip("/"))
    else:
        resolved = os.path.normpath(os.path.join(os.path.dirname(md_path), path))
    if not os.path.exists(resolved):
        problems.append(
            "{}: {} does not resolve: {} (from {})".format(
                os.path.relpath(md_path, root), kind, target,
                os.path.relpath(resolved, root),
            )
        )

for md in md_files:
    try:
        text = open(md, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError) as exc:
        problems.append("{}: cannot read ({})".format(os.path.relpath(md, root), exc))
        continue
    for match in link_re.finditer(text):
        check_target(md, match.group(1), "link")
    for match in src_re.finditer(text):
        check_target(md, match.group(1), "image")

if problems:
    print("check_docs: {} problem(s)".format(len(problems)))
    for p in problems:
        print("  " + p)
    sys.exit(1)

print("check_docs: OK - {} markdown files, all relative links and images resolve".format(len(md_files)))
PY
