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
   release evidence and GitHub release assets.
8. Publish update metadata only after the archive checksum, Sparkle signature,
   signing identity, notarization request id, and Gatekeeper output are recorded.

Sparkle is now the release update framework. Local and ad-hoc packages keep the
menu item disabled unless the package step injects both `SUFeedURL` and
`SUPublicEDKey`; this prevents a developer build from pointing at production
updates by accident. Ad-hoc packages also add `disable-library-validation` to
the local app signature so macOS can load the embedded Sparkle framework without
a Developer ID team identifier. Developer ID release packages use the normal
app entitlements and keep library validation enabled. A release package that
sets `AGENTD_SPARKLE_DOWNLOAD_URL` must also be notarized and must produce a
signed appcast.

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

## Automated Releases

`release-please` runs on every push to `main`. It reads Conventional Commit PR
titles, opens a release PR that updates `CHANGELOG.md`,
`.release-please-manifest.json`, `version.txt`, `support/Info.plist`
`CFBundleVersion`, and `support/Info.plist` `CFBundleShortVersionString`, then
creates the GitHub release when that PR merges. The same workflow calls
`package-release` with the new tag so the notarized app, signed Sparkle archive,
appcast, checksums, codesign evidence, Gatekeeper assessment, and
`update-channel.json` are attached to that release automatically.

The CI workflow validates PR titles with `scripts/validate_pr_title.py` because
non-Conventional titles are invisible to Release Please. Use titles such as
`feat: add activity summaries`, `fix: recover capture startup`, or
`chore: update signing evidence`.

For bot-created release PR branches to trigger normal PR checks, configure the
optional `AGENTD_RELEASE_TOKEN` secret with a fine-grained token that can push
branches and open pull requests in this repository. Without it, Release Please
falls back to `GITHUB_TOKEN`; that can still update GitHub state, but events
created by `GITHUB_TOKEN` may not start follow-on workflows.

For local appcast fixture testing without notarization, set
`AGENTD_SPARKLE_ALLOW_UNNOTARIZED=1`; do not use that override in release
automation.

To probe an already packaged app without installing an update, run
`scripts/sparkle_update_probe.sh`. It uses Sparkle's optional `sparkle` CLI
from `AGENTD_SPARKLE_BIN_DIR` or any local artifact path where the CLI is
present, uses `AGENTD_SPARKLE_PROBE_FEED_URL` when set, and falls back to
`dist/appcast.xml` as a local file URL. A zero exit means Sparkle found an
available update; non-zero exits preserve Sparkle's CLI result for debugging.
