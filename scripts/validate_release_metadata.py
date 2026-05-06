#!/usr/bin/env python3
"""Validate release automation metadata stays aligned with the app bundle."""

from __future__ import annotations

import json
import plistlib
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INFO_PLIST = ROOT / "support" / "Info.plist"
MANIFEST = ROOT / ".release-please-manifest.json"
CONFIG = ROOT / "release-please-config.json"
VERSION_FILE = ROOT / "version.txt"


def fail(message: str) -> None:
    raise SystemExit(message)


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"{path.relative_to(ROOT)} is missing")
    except json.JSONDecodeError as exc:
        fail(f"{path.relative_to(ROOT)} is not valid JSON: {exc}")


def main() -> int:
    with INFO_PLIST.open("rb") as fh:
        info = plistlib.load(fh)
    bundle_version = str(info.get("CFBundleVersion") or "")
    short_version = str(info.get("CFBundleShortVersionString") or "")
    if not bundle_version or not short_version:
        fail("support/Info.plist must contain both bundle version fields")
    if bundle_version != short_version:
        fail(
            "support/Info.plist version fields must match: "
            f"CFBundleVersion={bundle_version!r}, "
            f"CFBundleShortVersionString={short_version!r}"
        )

    manifest = load_json(MANIFEST)
    manifest_version = str(manifest.get(".") or "")
    if manifest_version != bundle_version:
        fail(
            ".release-please-manifest.json must match support/Info.plist: "
            f"{manifest_version!r} != {bundle_version!r}"
        )
    try:
        version_file = VERSION_FILE.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        fail("version.txt is missing")
    if version_file != bundle_version:
        fail(
            "version.txt must match support/Info.plist: "
            f"{version_file!r} != {bundle_version!r}"
        )

    config = load_json(CONFIG)
    package = (config.get("packages") or {}).get(".") or {}
    if package.get("release-type") != "simple":
        fail("release-please-config.json must use the simple release type")

    extra_files = package.get("extra-files") or []
    expected_xpaths = {
        "/plist/dict/key[text()='CFBundleVersion']/following-sibling::string[1]",
        "/plist/dict/key[text()='CFBundleShortVersionString']/following-sibling::string[1]",
    }
    actual_xpaths = {
        entry.get("xpath")
        for entry in extra_files
        if entry.get("type") == "xml" and entry.get("path") == "support/Info.plist"
    }
    missing = expected_xpaths - actual_xpaths
    if missing:
        fail(
            "release-please-config.json must update both Info.plist version "
            f"fields; missing {sorted(missing)}"
        )

    print(f"Release metadata is aligned at {bundle_version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
