# agentd

Desktop capture client for the EvalOps Chronicle pipeline. Status-bar-only macOS
app that turns recent screen activity into batched, scrubbed, deduped frame
events for `cmd/chronicle` in `evalops/platform`.

This is the desktop component of the work tracked in
[evalops/platform#1075](https://github.com/evalops/platform/issues/1075).

## How agentd compares to OpenAI Codex Chronicle

| Axis | OpenAI Codex Chronicle | agentd |
| --- | --- | --- |
| Subject of capture | Single user's work context, opt-in per device | Humans-and-agents-at-work evidence for the EvalOps Chronicle pipeline |
| Governance posture | Single-user app toggle and local pause controls | `RegisterDevice`, `Heartbeat`, server-pushed `CapturePolicy`, and local-hard-deny rails that win over server allow rules |
| Data plane | Screen frames and OCR are processed by OpenAI to generate local Codex memories | Self-hosted Connect/proto JSON `chronicle.v1.ChronicleService.SubmitBatch`, with optional ASB Secret Broker artifact wrapping |
| Evidence model | LLM-summarized markdown memories under `$CODEX_HOME/memories_extensions/chronicle/` plus temporary sparse frames | Frame batches with OCR, window/path metadata, pHash dedupe, drop counts, and optional sparse local frame artifacts |
| Privacy filter | Window-identity filters for browser private/incognito and meeting surfaces | Window identity, app/path policy, pause windows, and content scrub for AWS/GCP/SSH/JWT/GitHub/Anthropic/OpenAI/Slack/Stripe-style secrets |
| Encryption at rest | Temporary JPEG/OCR sidecars and plaintext markdown memories on local disk | `.agentdbatch` AES-GCM by default in remote or Secret Broker mode, Keychain-managed keys, and local-only opt-in encryption |
| Crash isolation | ScreenCaptureKit capture work runs through child-process paths with termination handling | Continuous and one-shot ScreenCaptureKit capture run through supervised same-binary worker subprocesses with TERM -> KILL shutdown |
| Prompt-injection exposure | Observed screen content is summarized by an LLM with prompt-level untrusted-input framing | Observed content is not fed to an on-device LLM by default; any future summarizer belongs in the controlled server pipeline |
| Distribution | Notarized `Codex.app` bundle | Notarized `EvalOps agentd.app` release workflow and permission-smoke evidence |

Things agentd deliberately does not copy:

- Shipping frames or OCR text to a third-party LLM provider for summarization.
- Window-identity-only privacy filtering without content-aware secret scrub.
- Plaintext screen memories as the default managed-mode storage format.

Source for the Codex column: the public
[Chronicle docs](https://developers.openai.com/codex/memories/chronicle) and a
local inspection of the shipped arm64 `codex_chronicle` helper bundled with
`Codex.app`.

## What it does

- Captures one display by default, or all/selected displays via
  `ScreenCaptureKit` when configured, at an adaptive 0.2–1 fps; input idle time
  drops cadence to `idleFps` and activity restores `captureFps`. Frames include
  display id, scale, and main-display metadata for multi-display diagnostics.
- Reads `(bundleId, windowTitle, documentPath)` per frame via the Accessibility
  API and `NSWorkspace`.
- Extracts focused-window Accessibility text first when available, then falls
  back to Apple Vision OCR on-device for image-heavy or AX-empty frames.
- Drops near-duplicate frames via a 64-bit pHash ring buffer (Hamming ≤ 5).
- Fail-closed `SecretScrubber` against AWS / GCP / SSH / JWT / GitHub classic
  and fine-grained tokens / Google API keys / npm / SendGrid / DigitalOcean /
  Azure storage keys / Mailgun / Twilio / Discord / Anthropic / OpenAI / Slack /
  Stripe markers — match → frame dropped, never partial-redacted.
- Per-app allow/deny list and per-path deny list.
- Window-title pause patterns (Zoom, FaceTime, 1Password…).
- Foreground privacy pause releases active ScreenCaptureKit streams when known
  protected streaming or remote-desktop content is focused, rather than merely
  dropping frames after capture.
- Scheduled pause windows from managed policy pause capture for meetings,
  interviews, private/focus blocks, or Platform-driven policy windows; manual
  pause always wins over automatic resume.
- Secret scanning covers OCR text, window titles, and document paths before a
  frame is batched.
- OCR text is scrubbed at full length, then capped to `maxOcrTextChars`
  (default 4096) with `ocrTextTruncated` set when the cap applies.
- A bounded OCR result cache reuses Vision output for unchanged window/content
  observations while still running SecretScrubber on every frame before
  persistence.
- Optional event-triggered capture mode arms one-shot captures on focused-window
  changes, clicks, typing pauses, scroll stops, clipboard updates, and idle
  fallback ticks behind `eventCaptureEnabled`, with debounce/min-gap counters in
  diagnostics.
- Continuous capture has a local health watchdog that restarts ScreenCaptureKit
  streams when active displays stop producing frames, with restart counts in
  diagnostics.
- Optional sparse-frame visual redaction masks OCR text boxes in local JPEG
  artifacts behind `sparseFrameVisualRedactionEnabled`; remote batch payloads are
  unchanged.
- Batches every 30s or 24 frames, whichever first.
- Local-only mode persists batches under `~/.evalops/agentd/batches/` as
  `0o600` JSON by default and sweeps old or over-budget batches; HTTP mode
  `POST`s a Connect/proto JSON `SubmitBatchRequest` to
  `chronicle.v1.ChronicleService.SubmitBatch` and falls back to local on
  failure. Remote HTTP is allowed only for loopback development; non-loopback
  remote endpoints must use HTTPS and configured client auth.
- Remote and Secret Broker modes encrypt local fallback batches at rest by
  default using a per-device Keychain-backed AES-GCM key. Local-only mode can
  opt in with `encryptLocalBatches: true`.
- Optional Secret Broker mode wraps the frame batch into a broker artifact
  (`chronicle_frame_batch_json`) first, then sends only the artifact/session
  reference to Chronicle so Platform can unwrap, meter, and revoke through ASB.
- Remote mode registers the device with Chronicle, sends periodic heartbeats
  with pending local queue pressure, and applies server-returned capture policy
  without requiring an app restart. Local hard-deny safety rails remain
  fail-closed even when a remote policy allows a bundle or path.
- The default local allowlist includes common developer surfaces, terminals,
  browsers, issue/chat tools, and LLM coding apps such as Codex, ChatGPT, and
  Claude Desktop.
- Browser capture has Chronicle-style metadata hardening: private/incognito and
  meeting browser windows are denied, and browser frames with missing focused
  window titles fail closed instead of being treated as normal allowed windows.
- Menu-bar UI: capture and permission status, a permission setup window with
  stable bundle identity, direct Screen Recording and Accessibility settings
  actions, permission refresh, relaunch, pause/resume (`⌃⌥⌘P`), flush now
  (`⌃⌥⌘F`), reveal batches dir, diagnostics report (`⌃⌥⌘D`), delete queued
  batches, launch-at-login, quit.

## Build

```
swift build
swift run agentd       # foreground; menu-bar item appears
swift run agentd -- list-displays
swift run agentd -- capture-once --no-ocr
swift test
python3 scripts/mock_chronicle.py --self-test Tests/Fixtures/chronicle
python3 scripts/chronicle_parity_audit.py # compare installed Codex Chronicle helper
scripts/multi_display_smoke.sh --phase before-attach # capture #34 display evidence
scripts/package_app.sh # release .app bundle with hardened runtime signing
scripts/permission_smoke.sh --no-launch # generate permission-smoke evidence template
./script/build_and_run.sh --verify # package, launch, and verify the menu app process
./script/build_and_run.sh --tcc-verify # relaunch the existing app without rebuilding
./script/build_and_run.sh --local-batch-verify # verify sanitized local batch output
```

The diagnostic subcommands emit bounded JSON for local support. `list-displays`
uses CoreGraphics/NSScreen display metadata instead of ScreenCaptureKit
discovery, and `list-displays` / `selftest` include structured probe status when
permission preflight or display discovery times out.

First run will trigger the system Screen Recording and Accessibility prompts the
first time the gated APIs are called. Grant both in System Settings → Privacy &
Security. If capture starts before the grants are complete, agentd retries
capture startup in the background; the menu also includes a permission setup
window, permission refresh, System Settings, and relaunch actions for TCC
recovery.
For ad-hoc local builds, approve the exact packaged app you are testing and use
`./script/build_and_run.sh --tcc-verify`; rebuilding changes the CDHash and can
make macOS treat it as a different TCC client.
For a downloaded/notarized workflow artifact, run
`AGENTD_APP_PATH="/path/to/EvalOps agentd.app" scripts/permission_smoke.sh`.
The smoke helper installs that artifact to `/Applications/EvalOps agentd.app`
before launch so the System Settings grant binds to a stable path/signature.
Then verify the same installed bundle with
`AGENTD_APP_PATH="/Applications/EvalOps agentd.app" ./script/build_and_run.sh --tcc-verify`.
`--local-batch-verify` also relaunches without rebuilding, activates Codex by
default, and prints only frame counts/metadata lengths so OCR text is not echoed
into the terminal. Set `AGENTD_SMOKE_FOREGROUND_APP=Terminal` or another
allowed app to probe a different foreground surface.

`scripts/package_app.sh` creates `dist/EvalOps agentd.app` and
`dist/agentd.zip`. By default CI uses ad-hoc signing with hardened runtime so
the bundle shape, embedded Sparkle framework, and entitlements are continuously
checked. Ad-hoc packages add `disable-library-validation` only for the local
signature so the embedded Sparkle framework can load; set
`AGENTD_ADHOC_DISABLE_LIBRARY_VALIDATION=0` to test without that local escape
hatch. Release builds inject `AGENTD_SPARKLE_FEED_URL` and
`AGENTD_SPARKLE_PUBLIC_ED_KEY` so the menu bar's "Check for Updates..." action
can use Sparkle. When `AGENTD_SPARKLE_DOWNLOAD_URL` is set, the package script
signs the final zip with Sparkle EdDSA, writes `dist/appcast.xml`, and verifies
that the appcast enclosure URL, signature, version, and archive length match the
packaged artifact. Release workflow builds also enable Sparkle signed-feed
validation so compromised update metadata cannot redirect users to a different
archive. To dry-run Sparkle's update discovery against a packaged bundle, use
`scripts/sparkle_update_probe.sh` with `AGENTD_SPARKLE_PROBE_FEED_URL` or a
local `dist/appcast.xml`.

For release signing, set `AGENTD_CODESIGN_IDENTITY` to a Developer ID
Application identity. To notarize and staple the bundle, either set
`AGENTD_NOTARY_PROFILE` for a notarytool keychain profile or set
`AGENTD_NOTARY_APPLE_ID`, `AGENTD_NOTARY_TEAM_ID`, and
`AGENTD_NOTARY_PASSWORD`.

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
- `AGENTD_SPARKLE_FEED_URL`
- `AGENTD_SPARKLE_PUBLIC_ED_KEY`
- `AGENTD_SPARKLE_PRIVATE_ED_KEY`: the private key text exported with Sparkle's
  `generate_keys -x`; store it as a secret and rotate it if exposed.

The workflow also requires a `sparkle_download_url` dispatch input. It must be
the final HTTPS URL where the uploaded `agentd.zip` will be served, because
Sparkle validates the appcast enclosure URL before downloading the update.

`scripts/permission_smoke.sh` packages the app when needed, installs the tested
bundle to `/Applications/EvalOps agentd.app` by default, records macOS
version/checksum/codesign evidence in `dist/permission-smoke-report.md`, and
opens the installed app unless `--no-launch` is supplied. Use it for the
hardware-backed Screen Recording and Accessibility permission smoke. Set
`AGENTD_APPLICATIONS_DIR` for tests or `AGENTD_INSTALL_APPLICATIONS=0` to skip
the install.
`scripts/multi_display_smoke.sh` records repeatable `list-displays` snapshots
for before-attach, after-attach, capture-all, and after-detach phases. It writes
bounded JSON and a Markdown report without screenshots or OCR text, and
`--require-multiple` fails when the attached-display phase still sees fewer
than two displays.

Launch-at-login uses native `SMAppService.mainApp` from the menu bar; agentd
does not install LaunchAgent plists.

## Configuration

agentd reads and writes `~/.evalops/agentd/config.json`. Important defaults:

- `localOnly: true`
- `captureFps: 1.0`
- `idleFps: 0.2`
- `idleThresholdSeconds: 60`
- `captureAllDisplays: false`
- `selectedDisplayIds: []`
- `adaptiveOcrMinChars: 1024`
- `adaptiveOcrBackpressureThreshold: 8`
- `adaptiveOcrBacklogBytes: 67108864`
- `ocrDiffSamplerEnabled: false`
- `ocrDiffSimilarityThreshold: 0.92`
- `eventCaptureEnabled: false`
- `eventCapturePollSeconds: 0.5`
- `eventCaptureDebounceSeconds: 0.25`
- `eventCaptureMinGapSeconds: 1`
- `eventCaptureIdleFallbackSeconds: 30`
- `eventCaptureTimeoutSeconds: 5`
- `sparseFrameStorageRoot: null`
- `sparseFrameRetentionHours: 6`
- `sparseFrameIncludeOcrText: false`
- `sparseFrameVisualRedactionEnabled: false`
- `batchIntervalSeconds: 30`
- `maxFramesPerBatch: 24`
- `maxOcrTextChars: 4096`
- `maxBatchAgeDays: 7`
- `maxBatchBytes: 536870912`
- `encryptLocalBatches: false` in local-only mode, `true` in remote or Secret
  Broker mode when omitted
- `auth: { "mode": "none" }`

Optional `metadata` entries are copied into every Chronicle `FrameBatch` and
Secret Broker wrap request. Use this for non-secret correlation IDs such as
`evalops_context_version`, `maestro_session_id`, `agent_run_id`,
`tool_execution_id`, `trace_id`, `traceparent`, `task_id`, and `source_issue`;
Platform preserves these as receipt evidence and Cerebro indexes them as
Chronicle graph labels. agentd centralizes the `evalops.context.v1` keys in
`EvalOpsContextMetadata`, preserving unknown keys while dropping malformed
canonical values such as invalid `traceparent` strings. This mirrors the
Platform envelope contract and Maestro emitter shape tracked in
evalops/platform#1201 and evalops/maestro-internal#1538.

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

When `localOnly` is `false`, agentd derives the other Chronicle control-plane
RPC URLs from `endpoint`. For example:

```json
{
  "endpoint": "https://chronicle.example.com/chronicle.v1.ChronicleService/SubmitBatch",
  "localOnly": false,
  "auth": {
    "mode": "bearer",
    "keychainService": "dev.evalops.agentd",
    "keychainAccount": "chronicle"
  }
}
```

On boot, agentd calls `RegisterDevice` with app version, hostname, capture mode,
Secret Broker mode, and local permission preflight metadata. Every 30 seconds it
calls `Heartbeat` with pending in-memory frames plus local fallback batch count
and bytes. `RegisterDevice` and `Heartbeat` responses may include a
`CapturePolicy`; agentd applies allowlist, denylist, path-deny, pause-window,
scheduled pause windows, selected-display scope, batch interval, and max-frame
settings at runtime.
Server `PAUSED` capture mode stops capture until a later policy resumes it.
Manual user pause wins over scheduled pause, scheduled pause wins over
foreground privacy pauses, and foreground privacy pauses win over server policy
pause for visible menu/diagnostic state.

Encrypted local batches use the `.agentdbatch` extension. The encryption key is
created or loaded from Keychain service `dev.evalops.agentd.local-batch-key`,
accounted by `deviceId`, and is never written to `config.json` or the batch
directory. Retention sweeps apply to both plaintext `.json` batches and
encrypted `.agentdbatch` batches.

Diagnostics reports are written under `~/.evalops/agentd/diagnostics/` with
`0o600` permissions. They summarize permissions, policy, queue pressure, local
batches, OCR cache hit-rate counters, AX-vs-OCR text-source counters,
event-capture trigger counters, sparse-frame visual-redaction state, active
display frame/drop counters, and last submit health without OCR text or raw
payloads. The same binary also supports `list-displays`, `capture-once`, and
`selftest` diagnostic subcommands; see `docs/diagnostics.md`.

For Chronicle-style local introspection, set `sparseFrameStorageRoot` to a
directory such as `~/.evalops/agentd/sparse-frames`. agentd then writes
per-display `*.capture` markers, `*.capture.json` segment metadata,
`*-latest.jpg` snapshots, sparse historical `frame-*.jpg` images, and OCR
change sidecars for frames that have already passed allow/deny policy,
deduplication, pause checks, and full-text secret scanning. OCR sidecars store
hashes and lengths by default; set `sparseFrameIncludeOcrText: true` only for
explicit local debugging where raw OCR persistence is acceptable.

`scripts/mock_chronicle.py` provides a strict local mock Chronicle and Secret
Broker harness. CI validates the golden fixtures in `Tests/Fixtures/chronicle`
so request-shape drift is explicit until generated `chronicle.v1` Swift types
are available.

## What's next

- Consume generated `chronicle.v1` Swift types when the platform SDK publishes
  them
  ([evalops/platform#1078](https://github.com/evalops/platform/issues/1078)).
- Hardware-backed permission-flow smoke test for Screen Recording and
  Accessibility prompts.
- macOS framework availability inventory: `docs/macos-availability.md`.

## Layout

```
Sources/agentd/
  main.swift              # NSApplication + AppController boot
  ChronicleControl.swift  # RegisterDevice/Heartbeat + policy response client
  Diagnostics.swift       # Redacted local report generation
  PauseState.swift        # Manual/scheduled/policy pause precedence
  LaunchAtLoginController.swift # Native SMAppService login item toggle
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
