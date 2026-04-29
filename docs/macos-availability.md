# macOS Availability Audit

agentd's supported deployment floor is macOS 14.0. The Swift package declares
`.macOS(.v14)` in `Package.swift`, and the packaged app declares
`LSMinimumSystemVersion` as `14.0` in `support/Info.plist`.

This audit covers the macOS framework APIs that gate capture, OCR, permissions,
window context, and launch-at-login.

| API | Call site | SDK availability | agentd posture |
| --- | --- | --- | --- |
| `SCShareableContent.excludingDesktopWindows(_:onScreenWindowsOnly:)` | `Sources/agentd/CaptureService.swift` | `SCShareableContent` is available since macOS 12.3. The current-process-only variant is macOS 14.4 and is not used. | Safe at the macOS 14.0 floor. |
| `SCContentFilter(display:excludingApplications:exceptingWindows:)` | `Sources/agentd/CaptureService.swift` | `SCContentFilter` is available since macOS 12.3. The metadata properties `style`, `pointPixelScale`, and `contentRect` are macOS 14.0 and are not used. | Safe at the macOS 14.0 floor. |
| `SCStream`, `addStreamOutput`, `startCapture`, `stopCapture`, `updateConfiguration` | `Sources/agentd/CaptureService.swift` | `SCStream` is available since macOS 12.3. | Safe at the macOS 14.0 floor. |
| `SCStreamConfiguration.width`, `height`, `minimumFrameInterval`, `queueDepth`, `showsCursor`, `pixelFormat` | `Sources/agentd/CaptureService.swift` | The base configuration object and these properties predate macOS 14.0. Properties such as `captureMicrophone`, `showMouseClicks`, `captureDynamicRange`, and `streamConfigurationWithPreset` are macOS 15.0+ and are not used. | Safe at the macOS 14.0 floor. |
| `SCStreamOutput.stream(_:didOutputSampleBuffer:of:)` | `Sources/agentd/CaptureService.swift` | `SCStreamOutput` is available since macOS 12.3. | Safe at the macOS 14.0 floor. |
| `VNRecognizeTextRequest` with `VNRecognizeTextRequestRevision3` | `Sources/agentd/VisionOCR.swift` | Revision 3 is available before macOS 14.0 and replaces deprecated revisions 1 and 2. | Safe at the macOS 14.0 floor. |
| `CGPreflightScreenCaptureAccess` | `Sources/agentd/main.swift` | Available since macOS 10.15. | Safe at the macOS 14.0 floor. |
| `AXIsProcessTrusted`, `AXIsProcessTrustedWithOptions`, `AXUIElementCopyAttributeValue` | `Sources/agentd/main.swift`, `Sources/agentd/WindowContext.swift` | `AXIsProcessTrustedWithOptions` is available since macOS 10.9; `AXIsProcessTrusted` and the AX element calls predate the floor. | Safe at the macOS 14.0 floor. |
| `SMAppService.mainApp`, `register`, `unregister`, `status` | `Sources/agentd/LaunchAtLoginController.swift` | Available since macOS 13.0. | Safe at the macOS 14.0 floor. |
| `NSWorkspace.frontmostApplication`, `activateFileViewerSelecting` | `Sources/agentd/WindowContext.swift`, `Sources/agentd/main.swift` | Available before macOS 14.0. | Safe at the macOS 14.0 floor. |

## Guardrail

`scripts/macos_availability_audit.py` is the CI tripwire for this inventory. It
checks that `Package.swift` and `support/Info.plist` agree on macOS 14.0, and it
fails if the source tree starts using known post-floor capture APIs without an
explicit availability review.

The blocked API list intentionally includes the Codex Chronicle-style future
paths from the local binary archaeology pass:

- `captureScreenshot` / `SCScreenshotConfiguration` / `SCScreenshotOutput`
  (macOS 26.0);
- `streamDidBecomeActive` / `streamDidBecomeInactive` and
  `includedDisplays` / `includedApplications` / `includedWindows`
  (macOS 15.2);
- `captureMicrophone`, `microphoneCaptureDeviceID`, `showMouseClicks`,
  `captureDynamicRange`, and `streamConfigurationWithPreset` (macOS 15.0);
- `includeMenuBar` and `SCStreamFrameInfoPresenterOverlayContentRect`
  (macOS 14.2);
- `SCShareableContent.currentProcess()` (macOS 14.4).

If agentd needs one of those APIs, add a focused code path with
`if #available(...)` / `@available(...)`, update this table, and adjust the
audit script in the same PR.
