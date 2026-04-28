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
- queued batch id, modification time, size, and encryption state.

The report omits OCR text and raw queued payloads. It strips endpoint query
strings, redacts secret-looking strings, and shortens home-directory paths.

The menu also includes `Delete Queued Batches`, which removes local plaintext
and encrypted fallback batches from the configured batch directory.

