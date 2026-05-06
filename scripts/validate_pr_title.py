#!/usr/bin/env python3
"""Validate PR titles are usable by release automation."""

from __future__ import annotations

import re
import sys


ALLOWED_TYPES = (
    "feat",
    "fix",
    "chore",
    "docs",
    "test",
    "refactor",
    "perf",
    "build",
    "ci",
    "revert",
    "release",
)

PATTERN = re.compile(
    rf"^({'|'.join(ALLOWED_TYPES)})(\([A-Za-z0-9._/-]+\))?!?: .+"
)


def main() -> int:
    title = " ".join(sys.argv[1:]).strip()
    if not title:
        raise SystemExit("PR title is empty")
    if PATTERN.match(title):
        print(f"Release-ready PR title: {title}")
        return 0
    allowed = ", ".join(ALLOWED_TYPES)
    raise SystemExit(
        "PR title must use Conventional Commits so release-please can "
        f"version agentd automatically. Use one of: {allowed}. "
        "Example: feat: add activity summaries"
    )


if __name__ == "__main__":
    sys.exit(main())
