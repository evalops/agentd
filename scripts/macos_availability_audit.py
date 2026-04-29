#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1

"""Static guardrail for agentd's macOS framework availability floor."""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Package.swift"
INFO_PLIST = ROOT / "support" / "Info.plist"
SOURCE_ROOTS = [ROOT / "Sources", ROOT / "Tests"]

EXPECTED_PACKAGE_FLOOR = ".macOS(.v14)"
EXPECTED_INFO_FLOOR = "14.0"

POST_FLOOR_PATTERNS = {
    # macOS 26.0 ScreenCaptureKit screenshot output APIs.
    "captureScreenshot": "macOS 26.0 ScreenCaptureKit screenshot API",
    "SCScreenshotConfiguration": "macOS 26.0 ScreenCaptureKit screenshot API",
    "SCScreenshotOutput": "macOS 26.0 ScreenCaptureKit screenshot API",
    # macOS 15.2 ScreenCaptureKit stream/filter convenience APIs.
    "streamDidBecomeActive": "macOS 15.2 SCStreamDelegate callback",
    "streamDidBecomeInactive": "macOS 15.2 SCStreamDelegate callback",
    "includedDisplays": "macOS 15.2 SCContentFilter metadata",
    "includedApplications": "macOS 15.2 SCContentFilter metadata",
    "includedWindows": "macOS 15.2 SCContentFilter metadata",
    # macOS 15.0 ScreenCaptureKit optional capture features.
    "captureMicrophone": "macOS 15.0 microphone capture",
    "microphoneCaptureDeviceID": "macOS 15.0 microphone capture",
    "showMouseClicks": "macOS 15.0 mouse-click rendering",
    "captureDynamicRange": "macOS 15.0 HDR capture",
    "streamConfigurationWithPreset": "macOS 15.0 stream presets",
    # macOS 14.2+ APIs above the declared 14.0 floor.
    "includeMenuBar": "macOS 14.2 SCContentFilter property",
    "SCStreamFrameInfoPresenterOverlayContentRect": "macOS 14.2 frame info key",
    "currentProcess()": "macOS 14.4 SCShareableContent current-process enumeration",
}


def fail(message: str) -> None:
    print(f"macos availability audit failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def source_files() -> list[Path]:
    files: list[Path] = []
    for root in SOURCE_ROOTS:
        files.extend(path for path in root.rglob("*.swift") if path.is_file())
    return files


def assert_minimums() -> None:
    package_text = PACKAGE.read_text(encoding="utf-8")
    if EXPECTED_PACKAGE_FLOOR not in package_text:
        fail(f"Package.swift must keep platforms: [{EXPECTED_PACKAGE_FLOOR}]")

    with INFO_PLIST.open("rb") as handle:
        info = plistlib.load(handle)
    actual = info.get("LSMinimumSystemVersion")
    if actual != EXPECTED_INFO_FLOOR:
        fail(
            f"support/Info.plist LSMinimumSystemVersion must be {EXPECTED_INFO_FLOOR}, got {actual!r}"
        )


def assert_no_post_floor_apis() -> None:
    violations: list[str] = []
    for path in source_files():
        text = path.read_text(encoding="utf-8")
        for pattern, reason in POST_FLOOR_PATTERNS.items():
            if re.search(rf"(?<![A-Za-z0-9_]){re.escape(pattern)}(?![A-Za-z0-9_])", text):
                rel = path.relative_to(ROOT)
                violations.append(f"{rel}: uses {pattern} ({reason})")
    if violations:
        fail(
            "post-macOS-14 API usage requires an explicit availability-gated PR:\n"
            + "\n".join(f"- {violation}" for violation in violations)
        )


def main() -> int:
    assert_minimums()
    assert_no_post_floor_apis()
    print("macos availability audit passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
