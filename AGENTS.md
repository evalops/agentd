# Repository Instructions

## Scope

agentd is the macOS desktop capture client for the EvalOps Chronicle pipeline. Treat privacy, local data handling, permissions, and Platform contract drift as first-class product behavior.

## Codex App Operating Rails

- Prefer Codex App Worktree mode for changes in this repository so packaging, permission-smoke, and Chronicle contract experiments stay isolated.
- Before changing Chronicle request shape, policy handling, or Secret Broker behavior, check related live issues/PRs in `evalops/agentd` and `evalops/platform` with `gh`.
- Keep local-only behavior safe by default. Do not weaken fail-closed secret scanning, pause precedence, local file permissions, HTTPS/client-auth requirements, or encrypted fallback behavior without an explicit issue.
- Do not commit local batch data, diagnostics output, packaged apps, archives, signing identities, notarization credentials, or Keychain-derived material.

## Verification Defaults

- Run `swift test` for code changes.
- Run `python3 scripts/mock_chronicle.py --self-test Tests/Fixtures/chronicle` for Chronicle contract or fixture changes.
- Run `scripts/package_app.sh` when changing packaging, entitlements, launch-at-login, or notarization paths.
- Run `scripts/permission_smoke.sh --no-launch` when changing Screen Recording or Accessibility permission flows and note that hardware-backed prompts still need manual verification.

## PR Expectations

- Include privacy/security impact in the PR body for capture, storage, policy, or transport changes.
- Include the exact Platform contract, issue, or fixture touched when request/response shapes change.
- Keep app behavior, fixtures, and README updates together when a user-visible safety property changes.
