#!/usr/bin/env python3
"""Check that every relative link in the Markdown, and every docs/ path
mentioned in the code, points at a file that exists.

Documentation that confidently links to a page nobody wrote is worse than
documentation that says nothing: the reader goes looking, finds a 404, and
stops trusting the rest of it.

Only relative links are checked. External URLs are not fetched, because a check
that fails when a third party's website is down is a check people learn to
ignore.
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent

MD_LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
# docs/<something>.md mentioned inside code comments and scripts.
DOC_REF_RE = re.compile(r"\bdocs/[0-9A-Za-z._-]+\.md\b")

CODE_SUFFIXES = {".tf", ".yaml", ".yml", ".sh", ".py", ".tftpl"}

errors: list[str] = []
links_checked = 0
refs_checked = 0


def check_markdown(path: pathlib.Path) -> None:
    global links_checked
    rel = path.relative_to(REPO_ROOT)

    for target in MD_LINK_RE.findall(path.read_text()):
        if target.startswith(("http://", "https://", "mailto:", "#")):
            continue

        # Strip any anchor; the file is what matters here.
        file_part = target.split("#", 1)[0]
        if not file_part:
            continue

        links_checked += 1
        resolved = (path.parent / file_part).resolve()

        if not resolved.exists():
            errors.append(f"{rel}: link to {target!r} does not exist")
        elif REPO_ROOT not in resolved.parents and resolved != REPO_ROOT:
            errors.append(f"{rel}: link to {target!r} escapes the repository")


def check_code_reference(path: pathlib.Path) -> None:
    global refs_checked
    rel = path.relative_to(REPO_ROOT)

    try:
        text = path.read_text()
    except (UnicodeDecodeError, OSError):
        return

    for ref in set(DOC_REF_RE.findall(text)):
        refs_checked += 1
        if not (REPO_ROOT / ref).exists():
            errors.append(
                f"{rel}: mentions {ref}, which does not exist. A comment that "
                f"sends a reader to a missing document is a dead end."
            )


def main() -> int:
    markdown = [
        p for p in REPO_ROOT.rglob("*.md")
        if not any(part in {".tools", ".helm", ".terraform", ".git"} for part in p.parts)
    ]
    if not markdown:
        print("No Markdown found, which is a failure.", file=sys.stderr)
        return 1

    for path in markdown:
        check_markdown(path)

    for path in REPO_ROOT.rglob("*"):
        if path.is_file() and path.suffix in CODE_SUFFIXES:
            if any(part in {".tools", ".helm", ".terraform", ".git"} for part in path.parts):
                continue
            check_code_reference(path)

    if errors:
        print("Broken references:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print(f"  {links_checked} relative link(s) and {refs_checked} docs reference(s) resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
