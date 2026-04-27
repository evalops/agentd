# agentd

Desktop capture client for the EvalOps Chronicle pipeline. Status-bar-only macOS
app that turns recent screen activity into batched, scrubbed, deduped frame
events for `cmd/chronicle` in `evalops/platform`.

This is the desktop component of the work tracked in
[evalops/platform#1075](https://github.com/evalops/platform/issues/1075).

## What it does (v0)

- Captures the active display via `ScreenCaptureKit` at an adaptive 0.2–1 fps.
- Reads `(bundleId, windowTitle, documentPath)` per frame via the Accessibility
  API and `NSWorkspace`.
- Runs Apple Vision OCR on-device.
- Drops near-duplicate frames via 64-bit pHash (Hamming ≤ 5).
- Fail-closed `SecretScrubber` against AWS / GCP / SSH / JWT / GitHub /
  Anthropic / OpenAI / Slack / Stripe markers — match → frame dropped, never
  partial-redacted.
- Per-app allow/deny list and per-path deny list.
- Window-title pause patterns (Zoom, FaceTime, 1Password…).
- Batches every 30s or 24 frames, whichever first.
- Local-only mode persists batches under `~/.evalops/agentd/batches/` as
  `0o600` JSON; HTTP mode `POST`s to
  `chronicle.v1.ChronicleService.SubmitBatch` and falls back to local on
  failure.
- Menu-bar UI: pause/resume (`⌃⌥⌘P`), flush now (`⌃⌥⌘F`), reveal batches dir,
  quit.

## Build

```
swift build
swift run agentd       # foreground; menu-bar item appears
swift test
```

First run will trigger the system Screen Recording and Accessibility prompts the
first time the gated APIs are called. Grant both in System Settings → Privacy &
Security and relaunch.

## What's next

- Replace local FNV-1a-based `frameHash` with real SHA-256 via CryptoKit.
- Wire to `chronicle.v1` when proto/codegen lands
  ([evalops/platform#1076](https://github.com/evalops/platform/issues/1076)).
- ASB artifact upload path
  ([evalops/platform#1082](https://github.com/evalops/platform/issues/1082)).
- Calendar / Zoom auto-pause via NATS subject
  `chronicle.policy.pause` (siphon-fed).
- Encryption-at-rest option for local batches.
- Notarized + hardened-runtime signed `.app` bundle.

## Layout

```
Sources/agentd/
  main.swift              # NSApplication + AppController boot
  Config.swift            # ~/.evalops/agentd/config.json
  CaptureService.swift    # SCStream pipeline
  WindowContext.swift     # AX + NSWorkspace probe
  VisionOCR.swift         # VNRecognizeTextRequest actor
  PerceptualHash.swift    # 8x8 mean-luma pHash
  SecretScrubber.swift    # NSRegularExpression fail-closed scrubber
  Pipeline.swift          # frame → processed-frame → batch
  Submitter.swift         # HTTP/JSON SubmitBatch with local fallback
  MenuBarController.swift # NSStatusItem UI
  Logging.swift           # OSLog categories
support/Info.plist        # injected via -sectcreate __TEXT __info_plist
Tests/agentdTests/        # SecretScrubber + path policy
```
