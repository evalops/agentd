---
name: agentd-chronicle-privacy-pr
description: Use when changing agentd Chronicle capture, privacy, local storage, permissions, policy sync, Secret Broker, or Platform contract behavior.
---

# agentd Chronicle Privacy PR

Use this workflow for agentd changes that touch capture, privacy, storage, transport, policy, or Chronicle contracts.

## Start

1. Check live state:
   - `gh issue list --repo evalops/agentd --limit 20`
   - `gh pr list --repo evalops/agentd --limit 20`
   - `gh issue list --repo evalops/platform --search Chronicle --limit 20`
2. Identify whether the change affects:
   - Screen Recording or Accessibility permissions
   - OCR, pHash, secret scanning, or frame dropping
   - local fallback batches or encryption
   - Chronicle RegisterDevice, Heartbeat, or SubmitBatch shape
   - Secret Broker artifact wrapping
   - policy pause precedence

## Implementation Rules

- Preserve fail-closed secret scanning and pause precedence unless the issue explicitly asks for a behavior change.
- Do not log OCR text, raw frame payloads, secrets, Keychain values, or unredacted document paths.
- Keep request fixtures and the strict mock Chronicle harness aligned with any request-shape change.
- If generated Swift Chronicle types become available, prefer them over handwritten request structs and add an explicit drift gate.

## Verification

Run the narrow checks that match the touched surface:

```bash
swift test
python3 scripts/mock_chronicle.py --self-test Tests/Fixtures/chronicle
```

For packaging or permission work:

```bash
scripts/package_app.sh
scripts/permission_smoke.sh --no-launch
```

If hardware-backed macOS permission prompts cannot be verified in the current environment, say that clearly.

## PR Body Checklist

- Privacy/security impact.
- Chronicle or Platform contract impact.
- Commands run and result.
- Any manual hardware, signing, notarization, or Platform follow-up.
