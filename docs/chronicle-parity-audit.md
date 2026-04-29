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
