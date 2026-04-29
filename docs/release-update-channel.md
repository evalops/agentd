# Release And Update Channel

agentd now uses native `SMAppService.mainApp` for launch-at-login. Users can
toggle it from the menu bar; the app does not install ad hoc LaunchAgent plists.

The signed update-channel path is intentionally evidence-first:

1. Package `dist/EvalOps agentd.app`.
2. Sign with Developer ID Application and hardened runtime.
3. Notarize with `notarytool`.
4. Staple with `xcrun stapler`.
5. Validate with `spctl -a -t exec -vv`.
6. Sign the final `dist/agentd.zip` with Sparkle EdDSA and generate
   `dist/appcast.xml`.
7. Publish `dist/agentd.zip`, `dist/appcast.xml`, `dist/SHA256SUMS`,
   `dist/update-channel.json`, `dist/codesign.txt`, and `dist/spctl.txt` as
   release evidence.
8. Publish update metadata only after the archive checksum, Sparkle signature,
   signing identity, notarization request id, and Gatekeeper output are recorded.

Sparkle is now the release update framework. Local and ad-hoc packages keep the
menu item disabled unless the package step injects both `SUFeedURL` and
`SUPublicEDKey`; this prevents a developer build from pointing at production
updates by accident. A release package that sets `AGENTD_SPARKLE_DOWNLOAD_URL`
must also be notarized and must produce a signed appcast.

Sparkle release configuration is injected at package time:

- `AGENTD_SPARKLE_FEED_URL`: hosted appcast URL embedded as `SUFeedURL`.
- `AGENTD_SPARKLE_PUBLIC_ED_KEY`: base64 public EdDSA key embedded as
  `SUPublicEDKey`.
- `AGENTD_SPARKLE_DOWNLOAD_URL`: hosted HTTPS URL for the final `agentd.zip`;
  when set, `scripts/package_app.sh` writes and verifies `dist/appcast.xml`.
- `AGENTD_SPARKLE_ED_KEY_FILE`: path to an exported Sparkle private EdDSA key
  for `sign_update --ed-key-file`. Local fixture testing may set
  `AGENTD_SPARKLE_ED_SIGNATURE` instead, but releases should sign the final
  zip after notarization/stapling.
- `AGENTD_SPARKLE_REQUIRE_SIGNED_FEED=1`: signs `dist/appcast.xml` with
  Sparkle and embeds `SURequireSignedFeed`. The release workflow enables this
  by default.
- `AGENTD_SPARKLE_RELEASE_NOTES_URL`: optional hosted release notes URL.
- `AGENTD_SPARKLE_CHANNEL`: optional Sparkle channel, for example `beta`.
- `AGENTD_SPARKLE_PHASED_ROLLOUT_INTERVAL`: optional rollout interval in
  seconds. Sparkle rolls phased releases across seven groups.
- `AGENTD_SPARKLE_MINIMUM_AUTOUPDATE_VERSION`: optional lower bound for silent
  automatic installation of major upgrades.
- `AGENTD_SPARKLE_CRITICAL_UPDATE=1`: marks the release as critical.

For local appcast fixture testing without notarization, set
`AGENTD_SPARKLE_ALLOW_UNNOTARIZED=1`; do not use that override in release
automation.

To probe an already packaged app without installing an update, run
`scripts/sparkle_update_probe.sh`. It uses Sparkle's optional `sparkle` CLI
from `AGENTD_SPARKLE_BIN_DIR` or any local artifact path where the CLI is
present, uses `AGENTD_SPARKLE_PROBE_FEED_URL` when set, and falls back to
`dist/appcast.xml` as a local file URL. A zero exit means Sparkle found an
available update; non-zero exits preserve Sparkle's CLI result for debugging.
