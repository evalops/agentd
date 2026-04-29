#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
"""Audit local agentd parity against the installed Codex Chronicle binary.

The Codex app updates independently of agentd. This script mines stable strings
from the local `codex_chronicle` binary, then checks whether agentd still has
the corresponding implementation or documented stronger alternative.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


DEFAULT_BINARY = Path("/Applications/Codex.app/Contents/Resources/codex_chronicle")


@dataclass(frozen=True)
class Probe:
    path: str
    needles: tuple[str, ...]


@dataclass(frozen=True)
class Capability:
    name: str
    chronicle_needles: tuple[str, ...]
    agentd_probes: tuple[Probe, ...]
    note: str


CAPABILITIES: tuple[Capability, ...] = (
    Capability(
        name="single-instance runtime lock",
        chronicle_needles=("codex_chronicle.lock", "acquired single-instance lock"),
        agentd_probes=(Probe("Sources/agentd/AgentdRuntimeLock.swift", ("AgentdRuntimeLock",)),),
        note="Prevents competing capture processes from fighting ScreenCaptureKit.",
    ),
    Capability(
        name="out-of-process ScreenCaptureKit worker",
        chronicle_needles=(
            "capture-screenshot-child",
            "ScreenCaptureKit child",
            "child_termination_guard",
        ),
        agentd_probes=(
            Probe("Sources/agentd/CaptureWorkerSupervisor.swift", ("CaptureWorkerSupervisor",)),
            Probe("Sources/agentd/DiagnosticCLI.swift", ("capture-worker-stream",)),
            Probe("Sources/agentd/CaptureService.swift", ("CaptureWorkerStreamClient",)),
        ),
        note="Keeps ScreenCaptureKit crashes/leaks outside the menu-bar parent.",
    ),
    Capability(
        name="bounded child termination",
        chronicle_needles=("failed to terminate", "and killed process", "SIGTERM"),
        agentd_probes=(
            Probe("Sources/agentd/CaptureWorkerSupervisor.swift", ("SIGKILL", "terminate")),
            Probe("Tests/agentdTests/CaptureWorkerSupervisorTests.swift", ("testEscalatesToKill",)),
        ),
        note="TERM first, then force kill when a capture child ignores shutdown.",
    ),
    Capability(
        name="display-list diagnostic child",
        chronicle_needles=("list-displays-child", "display-list child"),
        agentd_probes=(
            Probe("Sources/agentd/DiagnosticCLI.swift", ("list-displays", "DisplayDiagnostics")),
            Probe("Tests/agentdTests/DiagnosticCLITests.swift", ("testListDisplays",)),
        ),
        note="Support path for display ids and permission/display probe state.",
    ),
    Capability(
        name="per-display sparse artifacts",
        chronicle_needles=(".capture.json", ".ocr.jsonl", "-display-"),
        agentd_probes=(
            Probe("Sources/agentd/SparseFrameStore.swift", ("SparseFrameStore", ".ocr.jsonl")),
            Probe("Tests/agentdTests/PipelineTests.swift", ("testSparseFrameStore",)),
        ),
        note="Local opt-in artifacts mirror Chronicle shape after agentd privacy gates pass.",
    ),
    Capability(
        name="material text change sampler",
        chronicle_needles=("one JSON object per material text change", ".ocr.jsonl"),
        agentd_probes=(
            Probe("Sources/agentd/Pipeline.swift", ("OcrDiffSampler",)),
            Probe("Tests/agentdTests/PipelineTests.swift", ("testOcrDiffSampler",)),
        ),
        note="Optional OCR-diff override catches material text changes after pHash dedupe.",
    ),
    Capability(
        name="browser private and missing-title handling",
        chronicle_needles=(
            "BrowserWindowObservation",
            "Private Browsing",
            "Incognito",
            "browser_observations",
        ),
        agentd_probes=(
            Probe("Sources/agentd/Pipeline.swift", ("BrowserPrivacyObservation",)),
            Probe("Tests/agentdTests/PipelineTests.swift", ("testBrowserPrivacyObservation",)),
        ),
        note="Agentd keeps content scrub and adds fail-closed browser metadata handling.",
    ),
    Capability(
        name="meeting surface exclusion",
        chronicle_needles=("meet.google.com", "Google Meet"),
        agentd_probes=(
            Probe("Sources/agentd/Config.swift", ("meet.google.com", "Google Meet")),
            Probe("Sources/agentd/Pipeline.swift", ("browser_meeting_window",)),
        ),
        note="Meeting windows are denied via pause patterns and browser observation.",
    ),
    Capability(
        name="safe-to-persist audit semantics",
        chronicle_needles=("safe_to_persist", "privacy_filter"),
        agentd_probes=(
            Probe("Sources/agentd/Pipeline.swift", ("DropCounts", "reasonCode")),
            Probe("docs/secret-scrub.md", ("fail-closed",)),
        ),
        note="Agentd exposes deny/drop counts locally; proto-level per-frame flags live server-side.",
    ),
    Capability(
        name="prompt-injection-aware summarizer posture",
        chronicle_needles=(
            "UNTRUSTED OBSERVED INPUT",
            "--ephemeral",
            "--sandbox",
            "read-only",
        ),
        agentd_probes=(
            Probe("README.md", ("Prompt-injection",)),
            Probe("docs/chronicle-comparison.md", ("Prompt-injection",)),
        ),
        note="Agentd does not run a local LLM summarizer; docs preserve the architectural boundary.",
    ),
    Capability(
        name="macOS ScreenCaptureKit availability guard",
        chronicle_needles=(
            "captureImageInRect requires macOS 15.2+",
            "captureScreenshot requires macOS 26.0+",
        ),
        agentd_probes=(
            Probe("scripts/macos_availability_audit.py", ("ScreenCaptureKit",)),
            Probe("docs/macos-availability.md", ("ScreenCaptureKit",)),
        ),
        note="Availability inventory keeps post-floor APIs out of agentd by default.",
    ),
    Capability(
        name="audio capture intentionally out of scope",
        chronicle_needles=("Failed to start audio capture", "Failed to start microphone capture"),
        agentd_probes=(
            Probe("docs/chronicle-comparison.md", ("audio capture", "should not copy")),
        ),
        note="Chronicle has audio strings; agentd intentionally remains screen-only.",
    ),
)


def run_strings(binary: Path) -> str:
    try:
        output = subprocess.check_output(["strings", "-a", str(binary)], text=True)
    except FileNotFoundError:
        raise SystemExit("strings(1) is required") from None
    except subprocess.CalledProcessError as exc:
        raise SystemExit(f"failed to read strings from {binary}: {exc}") from None
    return output


def read_repo_text(root: Path, probe: Probe) -> str:
    path = root / probe.path
    if not path.exists():
        return ""
    return path.read_text(errors="replace")


def all_present(haystack: str, needles: tuple[str, ...]) -> bool:
    return all(needle in haystack for needle in needles)


def evaluate(binary_strings: str, root: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for capability in CAPABILITIES:
        chronicle_present = all_present(binary_strings, capability.chronicle_needles)
        agentd_evidence = [
            probe.path
            for probe in capability.agentd_probes
            if all_present(read_repo_text(root, probe), probe.needles)
        ]
        if not chronicle_present:
            status = "not_observed"
        elif len(agentd_evidence) == len(capability.agentd_probes):
            status = "covered"
        elif agentd_evidence:
            status = "partial"
        else:
            status = "gap"
        rows.append(
            {
                "name": capability.name,
                "status": status,
                "chronicleEvidence": list(capability.chronicle_needles),
                "agentdEvidence": agentd_evidence,
                "note": capability.note,
            }
        )
    return rows


def print_markdown(rows: list[dict[str, object]]) -> None:
    print("| Capability | Status | Agentd evidence | Note |")
    print("| --- | --- | --- | --- |")
    for row in rows:
        evidence = ", ".join(row["agentdEvidence"]) if row["agentdEvidence"] else "none"
        print(f"| {row['name']} | {row['status']} | {evidence} | {row['note']} |")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--json", action="store_true", help="emit JSON instead of Markdown")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit non-zero when an observed Chronicle capability is not fully covered",
    )
    args = parser.parse_args(argv)

    if not args.binary.exists():
        raise SystemExit(f"Chronicle binary not found: {args.binary}")
    if not (args.repo_root / "Package.swift").exists():
        raise SystemExit(f"repo root does not look like agentd: {args.repo_root}")

    rows = evaluate(run_strings(args.binary), args.repo_root)
    if args.json:
        print(json.dumps(rows, indent=2, sort_keys=True))
    else:
        print_markdown(rows)
    if args.strict and any(row["status"] in {"gap", "partial"} for row in rows):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
