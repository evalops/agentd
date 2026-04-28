# Release And Update Channel

agentd now uses native `SMAppService.mainApp` for launch-at-login. Users can
toggle it from the menu bar; the app does not install ad hoc LaunchAgent plists.

The signed update-channel path is intentionally evidence-first:

1. Package `dist/EvalOps agentd.app`.
2. Sign with Developer ID Application and hardened runtime.
3. Notarize with `notarytool`.
4. Staple with `xcrun stapler`.
5. Validate with `spctl -a -t exec -vv`.
6. Publish `dist/agentd.zip`, `dist/SHA256SUMS`, `dist/codesign.txt`, and
   `dist/spctl.txt` as release evidence.
7. Publish update metadata only after the artifact checksum, signing identity,
   notarization request id, and Gatekeeper output are recorded.

Sparkle remains the preferred full auto-update framework once product policy
allows automatic delivery. Until then, the update channel is a signed manual
feed: publish checksummed artifacts and metadata from the notarized workflow,
and never advance update metadata for an artifact that has not passed the same
sign, notarize, staple, and Gatekeeper checks.

