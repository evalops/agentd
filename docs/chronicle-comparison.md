# Chronicle Comparison

This page captures the practical delta between agentd and OpenAI Codex
Chronicle-style local capture.

| Axis | agentd | Codex Chronicle-style capture |
| --- | --- | --- |
| Primary use | Enterprise/work audit trail for humans and agents | Personal memory for Codex |
| Capture governance | Fleet `CapturePolicy` plus local hard-deny rails | Single-user app policy |
| Secret handling | Content-aware fail-closed scrub before persistence | Window/app identity filter |
| Storage fallback | Encrypted `.agentdbatch` by default in managed modes | Plain sidecars and summaries |
| Broker mode | Optional ASB Secret Broker artifact wrapping | No broker artifact path |
| Summarization | Local sanitized activity summaries plus server/control-plane enrichment; no raw-screen LLM path by default | LLM summarizer loop |
| Prompt-injection posture | Observed content is not fed to an on-device agent by default | Prompt framing around observed content |
| Local sparse artifacts | Opt-in sparse-frame store after policy and secret scrub | Default local temp frame/OCR sidecars |
| Release evidence | Developer ID/notarization workflow plus hardware-smoke helper | Signed/notarized app bundle |

Borrowed ideas worth keeping:

- material-text-change OCR diffs as a secondary sampler;
- sessionized per-display latest-frame and sparse historical frame artifacts;
- multi-display observability;
- downstream heartbeat-recency checks;
- explicit prompt-injection taxonomies for any future summarizer consumer;
- local `instructions.md` and `resources/*.md` summaries that teach agents to
  check freshness, use summaries as navigation aids, and upgrade to
  source-of-truth connectors before acting.

Things agentd should not copy:

- shipping frames or OCR text to a third-party LLM provider for summarization;
- window-identity-only privacy controls without content scrub;
- plaintext local memories as the default managed-mode storage;
- audio capture without a stated audit reason;
- update metadata that can advance without the signing/notarization evidence
  chain.
