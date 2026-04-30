# Chronicle Parity Audit

`scripts/chronicle_parity_audit.py` compares the installed Codex Chronicle
helper against this repo. It is intentionally local because Codex.app can update
outside agentd release cadence.

Run it after Codex.app updates or before a Chronicle-parity planning pass:

```sh
python3 scripts/chronicle_parity_audit.py
python3 scripts/chronicle_parity_audit.py --json
python3 scripts/chronicle_parity_audit.py --strict
```

By default it reads
`/Applications/Codex.app/Contents/Resources/codex_chronicle`, mines stable
binary strings, and maps observed Chronicle capabilities to agentd source,
tests, or docs evidence. `--strict` exits non-zero when an observed Chronicle
capability is only partial or missing locally.

The audit is not a substitute for source review. It is a drift tripwire for the
specific Chronicle traits we care about: worker isolation, termination behavior,
display diagnostics, sparse local artifacts, material-text-change sampling,
browser-window privacy handling, meeting exclusion, safe-to-persist semantics,
summarizer prompt-injection posture, macOS API availability, and the deliberate
choice to keep audio capture out of scope.

## Flagship Product Loop Signals

Agentd now emits the source-side structure that lets Platform answer "what was
I doing, what changed, and what should an agent know about it?" without
re-parsing raw OCR:

- `domainTiers` grades matching domains as `evidence`, `audit`, or `deny`.
  Audit-tier frames preserve host-level evidence, set `tier=audit`, blank OCR,
  truncate `documentPath` to scheme plus host, and skip sparse-frame artifacts.
- `emittedCounts` is attached to every batch with deterministic counters for
  distinct bundles/domains/document paths, GitHub PRs, foreground/document
  changes, work-leisure flips, longest uninterrupted seconds, and thrash events.
- `contextExtractors` add dynamic batch metadata such as `activeIssue` and
  `activePullRequest`, including first-seen timestamps and foreground seconds.
- `perBundleProfiles` and `urlChangeIdleThresholdSeconds` let managed policy
  reduce noisy polling for browser/feed surfaces while keeping IDE and terminal
  work at higher fidelity.

These fields are additive on the wire. Older Platform versions ignore them;
newer Platform Chronicle policy can send them back through `CapturePolicy`.
