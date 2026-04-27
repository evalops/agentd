# Security Policy

## Reporting

Please report suspected vulnerabilities through GitHub private vulnerability
reporting for this repository, or email security@evalops.dev with the subject
`agentd security report`.

Include:

- affected version or commit
- macOS version and hardware class, if relevant
- reproduction steps
- expected and observed behavior
- whether screen content, OCR text, local batches, credentials, or transport
  authentication are involved

Do not post exploitable details in public GitHub issues before EvalOps has had
a chance to triage and coordinate a fix.

## Scope

In scope:

- screen capture, OCR, and window-context handling
- local batch persistence under `~/.evalops/agentd/batches`
- secret detection and fail-closed drop behavior
- endpoint transport security and client authentication
- macOS permissions and Keychain integration used by agentd

Out of scope:

- social engineering
- denial-of-service reports without a concrete security impact
- vulnerabilities in macOS, ScreenCaptureKit, Vision, or GitHub Actions unless
  agentd uses them in a way that creates additional exposure

## Severity Expectations

EvalOps treats these as high severity by default:

- screen pixels, OCR text, window titles, or document paths sent to an
  unintended remote endpoint
- plaintext remote transport outside loopback development
- missing or bypassed client authentication for remote submission
- secret-bearing OCR text or window metadata shipped instead of dropped
- unbounded local retention of OCR-derived batch data

Lower-severity issues include missing hardening, incomplete docs, or telemetry
gaps that do not expose captured content or credentials directly.

## Handling

EvalOps will acknowledge credible reports as quickly as possible, triage impact,
and coordinate fixes through private advisories when warranted. Public issues
may be opened after a fix is available or when the report is not security
sensitive.
