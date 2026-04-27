# Privacy

agentd is a macOS menu-bar client that captures screen activity, performs OCR
locally, and submits scrubbed frame metadata to the EvalOps Chronicle pipeline.
This document describes the behavior in this repository as implemented today.

## What agentd Captures

For accepted frames, agentd may collect:

- active display dimensions
- capture timestamp
- app bundle ID and app name
- focused window title
- focused document path or document URL when macOS Accessibility exposes it
- OCR text recognized by Apple Vision
- OCR confidence
- a 64-bit perceptual hash used for deduplication
- a raw-BGRA byte estimate for the frame size

Raw screen pixels are used in memory for OCR, hashing, and filtering. Raw pixels
are not written to batch JSON and are not PNG-encoded for metadata.

## What Stays On Device

agentd performs these steps locally:

- ScreenCaptureKit capture
- Vision OCR
- perceptual hashing and deduplication
- allowlist, denylist, pause-window, path, and secret checks
- local fallback persistence

Local fallback batches are stored as `0o600` JSON files under:

```text
~/.evalops/agentd/batches
```

The batch directory is swept on local persistence and after successful remote
submissions. Defaults are:

- maximum local batch age: 7 days
- maximum local batch size budget: 512 MiB

Oldest files are removed first when the byte budget is exceeded.

## What Crosses The Wire

When `localOnly` is `false`, agentd sends a Connect/proto JSON
`SubmitBatchRequest` to the configured Chronicle endpoint. Remote submission is
refused unless:

- the endpoint is HTTPS, or
- the endpoint is loopback HTTP such as `localhost`, `127.x.x.x`, or `::1`, or
- the endpoint uses a supported local socket scheme

Remote submission also requires configured client authentication. Bearer tokens
are resolved from Keychain. They are not stored in `config.json`. mTLS identities
are resolved from Keychain by label and attached through URLSession client
certificate authentication.

## Drop And Scrub Behavior

agentd drops a frame before batching when:

- the active app bundle is denied
- an allowlist is present and the active app is not in it
- the document path matches a denied path prefix
- the window title matches a pause pattern
- the window title, document path, or full OCR text matches a secret pattern
- the perceptual hash is near a recent accepted frame

Secret matches are fail-closed: agentd drops the whole frame rather than
redacting and shipping partial content. Secret scanning runs against the full OCR
text before any configured OCR text truncation.

## Inspecting Or Wiping State

Configuration:

```text
~/.evalops/agentd/config.json
```

Local batches:

```text
~/.evalops/agentd/batches
```

To wipe local batches:

```sh
rm -f ~/.evalops/agentd/batches/*.json
```

To force local-only behavior, set `localOnly` to `true` in `config.json`.

## Residual Risks

OCR can miss secrets inside images, screenshots, unusual fonts, or partially
visible text. Window titles and document paths can still contain sensitive
metadata even when OCR is clean, which is why those fields are also checked by
the secret scrubber before batching. Local JSON batches contain OCR-derived
content and should be treated as sensitive until encrypted-at-rest support is
added.
