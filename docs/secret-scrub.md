# Secret Scrub

agentd treats secret detection as a fail-closed capture rail. A match drops the
frame before persistence or submission; it does not redact and ship a partial
frame.

The scrubber runs against:

- OCR text before `maxOcrTextChars` truncation;
- active window title;
- focused document path.

The pattern families include AWS keys, GCP service-account material, SSH keys,
JWTs, GitHub classic and fine-grained tokens, Google API keys, npm, SendGrid,
DigitalOcean, Azure storage keys, Mailgun, Twilio, Discord, Slack, Anthropic,
OpenAI, Stripe live keys, certificate requests, and generic password/API-key
fields.

Local hard-deny rails still win over remote policy. Fleet `CapturePolicy` may
add allowlists or denylists, but the built-in password managers, keychain paths,
private/incognito/meeting title pauses, denied paths, and content-aware secret
scrub remain local fail-closed controls.

Browser windows get an additional Chronicle-parity privacy check before OCR or
content scrub. Supported browser bundle IDs fail closed when Accessibility
cannot provide a focused-window title, and private/incognito or meeting browser
windows are denied by browser-window observation even if the bundle is otherwise
allowed. This keeps degraded browser metadata from becoming an accidental allow.
