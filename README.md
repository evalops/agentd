# agentd

Desktop capture client for the EvalOps Chronicle pipeline. Status-bar-only macOS
app that turns recent screen activity into batched, scrubbed, deduped frame
events for `cmd/chronicle` in `evalops/platform`.

This is the desktop component of the work tracked in
[evalops/platform#1075](https://github.com/evalops/platform/issues/1075).

## What it does

- Captures the active display via `ScreenCaptureKit` at an adaptive 0.2–1 fps;
  input idle time drops cadence to `idleFps` and activity restores
  `captureFps`.
- Reads `(bundleId, windowTitle, documentPath)` per frame via the Accessibility
  API and `NSWorkspace`.
- Runs Apple Vision OCR on-device.
- Drops near-duplicate frames via a 64-bit pHash ring buffer (Hamming ≤ 5).
- Fail-closed `SecretScrubber` against AWS / GCP / SSH / JWT / GitHub classic
  and fine-grained tokens / Google API keys / npm / SendGrid / DigitalOcean /
  Azure storage keys / Mailgun / Twilio / Discord / Anthropic / OpenAI / Slack /
  Stripe markers — match → frame dropped, never partial-redacted.
- Per-app allow/deny list and per-path deny list.
- Window-title pause patterns (Zoom, FaceTime, 1Password…).
- Secret scanning covers OCR text, window titles, and document paths before a
  frame is batched.
- OCR text is scrubbed at full length, then capped to `maxOcrTextChars`
  (default 4096) with `ocrTextTruncated` set when the cap applies.
- Batches every 30s or 24 frames, whichever first.
- Local-only mode persists batches under `~/.evalops/agentd/batches/` as
  `0o600` JSON and sweeps old or over-budget batches; HTTP mode `POST`s a
  Connect/proto JSON `SubmitBatchRequest` to
  `chronicle.v1.ChronicleService.SubmitBatch` and falls back to local on
  failure. Remote HTTP is allowed only for loopback development; non-loopback
  remote endpoints must use HTTPS and configured client auth.
- Optional Secret Broker mode wraps the frame batch into a broker artifact
  (`chronicle_frame_batch_json`) first, then sends only the artifact/session
  reference to Chronicle so Platform can unwrap, meter, and revoke through ASB.
- Menu-bar UI: pause/resume (`⌃⌥⌘P`), flush now (`⌃⌥⌘F`), reveal batches dir,
  quit.

## Build

```
swift build
swift run agentd       # foreground; menu-bar item appears
swift test
scripts/package_app.sh # release .app bundle with hardened runtime signing
scripts/permission_smoke.sh --no-launch # generate permission-smoke evidence template
```

First run will trigger the system Screen Recording and Accessibility prompts the
first time the gated APIs are called. Grant both in System Settings → Privacy &
Security and relaunch.

`scripts/package_app.sh` creates `dist/EvalOps agentd.app` and
`dist/agentd.zip`. By default CI uses ad-hoc signing with hardened runtime so
the bundle shape and entitlements are continuously checked. For release signing,
set `AGENTD_CODESIGN_IDENTITY` to a Developer ID Application identity. To
notarize and staple the bundle, either set `AGENTD_NOTARY_PROFILE` for a
notarytool keychain profile or set `AGENTD_NOTARY_APPLE_ID`,
`AGENTD_NOTARY_TEAM_ID`, and `AGENTD_NOTARY_PASSWORD`.

The `package-release` GitHub Actions workflow performs the credential-backed
release path and uploads the stapled app, archive, checksums, codesign details,
and Gatekeeper assessment. Configure these repository secrets before dispatching
it:

- `AGENTD_CODESIGN_CERTIFICATE_P12`: base64-encoded Developer ID Application
  `.p12`.
- `AGENTD_CODESIGN_CERTIFICATE_PASSWORD`: password for that `.p12`.
- `AGENTD_CODESIGN_IDENTITY`: codesign identity name, for example
  `Developer ID Application: Example, Inc. (TEAMID)`.
- `AGENTD_NOTARY_APPLE_ID`
- `AGENTD_NOTARY_TEAM_ID`
- `AGENTD_NOTARY_PASSWORD`: app-specific password for notarization.

`scripts/permission_smoke.sh` packages the app when needed, records macOS
version/checksum/codesign evidence in `dist/permission-smoke-report.md`, and
opens the app unless `--no-launch` is supplied. Use it for the hardware-backed
Screen Recording and Accessibility permission smoke.

## Configuration

agentd reads and writes `~/.evalops/agentd/config.json`. Important defaults:

- `localOnly: true`
- `captureFps: 1.0`
- `idleFps: 0.2`
- `idleThresholdSeconds: 60`
- `batchIntervalSeconds: 30`
- `maxFramesPerBatch: 24`
- `maxOcrTextChars: 4096`
- `maxBatchAgeDays: 7`
- `maxBatchBytes: 536870912`
- `auth: { "mode": "none" }`

Remote mode requires `localOnly: false`, an HTTPS or loopback endpoint, and an
auth mode. Bearer auth references a Keychain item:

```json
{
  "auth": {
    "mode": "bearer",
    "keychainService": "dev.evalops.agentd",
    "keychainAccount": "chronicle"
  }
}
```

mTLS auth references a Keychain identity label:

```json
{
  "auth": {
    "mode": "mtls",
    "identityLabel": "agentd Chronicle client"
  }
}
```

Secret Broker artifact mode adds a second endpoint plus a Keychain-backed
session token reference. The endpoint is the Secret Broker HTTP
`/v1/artifacts:wrap` route:

```json
{
  "secretBroker": {
    "endpoint": "https://secret-broker.example.com/v1/artifacts:wrap",
    "sessionTokenKeychainService": "dev.evalops.agentd",
    "sessionTokenKeychainAccount": "secret-broker",
    "ttlSeconds": 300
  }
}
```

If wrapping fails, agentd persists the original inline `SubmitBatchRequest`
locally and does not write the broker session token to disk.

## What's next

- Consume generated `chronicle.v1` Swift types when the platform SDK publishes
  them
  ([evalops/platform#1078](https://github.com/evalops/platform/issues/1078)).
- Calendar / Zoom auto-pause via NATS subject
  `chronicle.policy.pause` (siphon-fed).
- Encryption-at-rest option for local batches.
- Hardware-backed permission-flow smoke test for Screen Recording and
  Accessibility prompts.

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

## License

Business Source License 1.1. See `LICENSE` and `LICENSING.md` for the current
terms.
