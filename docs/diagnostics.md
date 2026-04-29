# Local Diagnostics

agentd exposes a local diagnostics report from the menu bar. The report is a
redacted Markdown file under `~/.evalops/agentd/diagnostics/` and is intended
for dogfood, support, and hardware-smoke evidence without opening raw batch
JSON.

The report includes:

- capture state and pause reason;
- Screen Recording and Accessibility permission preflight;
- app version, local-only/managed mode, Secret Broker mode, policy version, and
  policy source;
- in-memory frame pressure and queued local batch count/bytes;
- OCR cache entry, hit-rate, miss, and eviction counters;
- text-source counts for focused-window Accessibility text, fresh Vision OCR,
  and cached OCR reuse;
- event-capture trigger counts, debounce/min-gap suppressions, and one-shot
  capture success/failure counts;
- capture health restart counts and the last stale-stream restart reason;
- sparse-frame visual-redaction enabled/disabled state;
- queued batch id, modification time, size, and encryption state.

The report omits OCR text and raw queued payloads. It strips endpoint query
strings, redacts secret-looking strings, and shortens home-directory paths.

The menu also includes `Delete Queued Batches`, which removes local plaintext
and encrypted fallback batches from the configured batch directory.

Foreground privacy pauses are visible as capture-state reasons. These pauses
release active ScreenCaptureKit streams while known protected streaming content,
remote-desktop content, or configured pause-window title patterns are focused,
so support reports can distinguish deliberate privacy release from capture
failure.

## One-shot CLI

The executable also has diagnostic subcommands that emit JSON without starting
the menu-bar app:

```sh
agentd list-displays
agentd capture-once --display-id 1 --out ~/.evalops/agentd/diagnostics/cli/capture.json
agentd capture-once --no-ocr
agentd selftest
```

`list-displays` reports display id, bounds, scale, main-display status, and the
current Accessibility/Screen Recording preflight state. Display discovery uses
CoreGraphics/NSScreen metadata instead of ScreenCaptureKit so developers can
inspect local display ids even when capture permission plumbing is unhealthy.
The JSON includes `displayProbe` and `screenCaptureProbe` status objects; if a
probe times out or degrades, the command exits with structured `timedOut` /
`unavailableReason` fields instead of hanging. `capture-once` captures a single
frame, runs the normal privacy filters, SecretScrubber, and OCR pipeline, then
writes a redacted batch JSON object to stdout or an `0o600` `--out` path. It
refuses to run while another agentd daemon or diagnostic capture holds the
runtime lock, which avoids ScreenCaptureKit contention during support sessions.

`capture-once` launches a same-binary `capture-worker-once` subprocess for the
ScreenCaptureKit one-shot and decodes the worker's frame payload in the parent
before policy, scrubber, OCR, and batch generation run. This exercises the
out-of-process capture boundary used by the larger worker-supervision roadmap
while keeping privacy decisions in the parent process. `--no-ocr` keeps the
capture and scrubber path intact but records an empty OCR result. `--no-scrub`
is recognized for operator muscle memory but deliberately refused; local
diagnostics should not bypass the scrubber.

Continuous menu-bar capture uses the same boundary: the parent starts one
same-binary `capture-worker-stream` subprocess per selected display, reads
newline-delimited frame payloads over stdout, and keeps policy, scrubber, OCR,
batching, health checks, and TERM -> KILL supervision in the parent process.
