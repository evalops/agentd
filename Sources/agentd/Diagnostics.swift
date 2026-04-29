// SPDX-License-Identifier: BUSL-1.1

import Foundation

struct DiagnosticsSnapshot: Sendable {
  let generatedAt: Date
  let appVersion: String
  let captureState: String
  let permissions: PermissionSnapshot
  let config: AgentConfig
  let policyVersion: String?
  let policySource: String?
  let controlError: String?
  let pendingStats: PendingFrameStats
  let ocrCacheStats: OCRCacheStats
  let eventCaptureStats: EventCaptureStats
  let localBatchStats: LocalBatchStats
  let localBatches: [LocalBatchSummary]
  let captureDisplayStats: [CaptureDisplayStats]
  let lastSubmitResult: String?
}

enum DiagnosticsReport {
  static func markdown(_ snapshot: DiagnosticsSnapshot) -> String {
    var lines: [String] = []
    lines.append("# agentd diagnostics")
    lines.append("")
    lines.append("- Generated: \(iso(snapshot.generatedAt))")
    lines.append("- App version: \(snapshot.appVersion)")
    lines.append("- Capture state: \(snapshot.captureState)")
    lines.append("- Accessibility trusted: \(snapshot.permissions.accessibilityTrusted)")
    lines.append("- Screen capture preflight: \(snapshot.permissions.screenCaptureTrusted)")
    lines.append("- Mode: \(snapshot.config.localOnly ? "local-only" : "managed")")
    lines.append("- Secret Broker: \(snapshot.config.secretBroker == nil ? "disabled" : "enabled")")
    lines.append("- Endpoint: \(redactEndpoint(snapshot.config.endpoint))")
    lines.append("- Policy version: \(snapshot.policyVersion ?? "none")")
    lines.append("- Policy source: \(redact(snapshot.policySource ?? "none"))")
    lines.append("- Last control error: \(redact(snapshot.controlError ?? "none"))")
    lines.append("- Pending in-memory frames: \(snapshot.pendingStats.frameCount)")
    lines.append("- Pending in-memory bytes: \(snapshot.pendingStats.estimatedBytes)")
    lines.append("- OCR cache entries: \(snapshot.ocrCacheStats.entries)")
    lines.append(
      "- OCR cache hit rate: \(String(format: "%.2f", snapshot.ocrCacheStats.hitRate))"
    )
    lines.append("- OCR cache misses: \(snapshot.ocrCacheStats.misses)")
    lines.append("- OCR cache evictions: \(snapshot.ocrCacheStats.evictions)")
    lines.append("- Event capture enabled: \(snapshot.eventCaptureStats.enabled)")
    lines.append("- Event capture starts: \(snapshot.eventCaptureStats.capturesStarted)")
    lines.append("- Event capture successes: \(snapshot.eventCaptureStats.capturesSucceeded)")
    lines.append("- Event capture failures: \(snapshot.eventCaptureStats.capturesFailed)")
    lines.append(
      "- Event capture debounced triggers: \(snapshot.eventCaptureStats.triggersDebounced)")
    lines.append(
      "- Event capture min-gap suppressions: \(snapshot.eventCaptureStats.triggersSuppressedByMinGap)"
    )
    lines.append("- Queued local batches: \(snapshot.localBatchStats.fileCount)")
    lines.append("- Queued local bytes: \(snapshot.localBatchStats.bytes)")
    lines.append("- Last submit result: \(snapshot.lastSubmitResult ?? "unknown")")
    lines.append("")
    lines.append("## Capture Policy")
    lines.append("")
    lines.append("- Allowed bundles: \(snapshot.config.allowedBundleIds.count)")
    lines.append("- Denied bundles: \(snapshot.config.deniedBundleIds.count)")
    lines.append("- Capture all displays: \(snapshot.config.captureAllDisplays)")
    lines.append(
      "- Selected display ids: \(snapshot.config.selectedDisplayIds.map(String.init).joined(separator: ", ").nilIfEmpty ?? "none")"
    )
    lines.append(
      "- Denied path prefixes: \(snapshot.config.deniedPathPrefixes.map(redactPath).joined(separator: ", "))"
    )
    lines.append(
      "- Pause title patterns: \(snapshot.config.pauseWindowTitlePatterns.map(redact).joined(separator: ", "))"
    )
    lines.append("- Batch interval seconds: \(snapshot.config.batchIntervalSeconds)")
    lines.append("- Max frames per batch: \(snapshot.config.maxFramesPerBatch)")
    lines.append("- Max OCR text chars: \(snapshot.config.maxOcrTextChars)")
    lines.append("- Adaptive OCR min chars: \(snapshot.config.adaptiveOcrMinChars)")
    lines.append("- Event capture poll seconds: \(snapshot.config.eventCapturePollSeconds)")
    lines.append(
      "- Event capture idle fallback seconds: \(snapshot.config.eventCaptureIdleFallbackSeconds)"
    )
    lines.append("")
    lines.append("## Event Capture")
    lines.append("")
    lines.append("| Trigger | Count |")
    lines.append("| --- | ---: |")
    for trigger in EventCaptureTrigger.allCases {
      lines.append(
        "| \(trigger.rawValue) | \(snapshot.eventCaptureStats.triggerCounts[trigger] ?? 0) |"
      )
    }
    lines.append("")
    lines.append("## Capture Displays")
    lines.append("")
    if snapshot.captureDisplayStats.isEmpty {
      lines.append("No active capture displays.")
    } else {
      lines.append("| Display | Size | Scale | Main | Frames | Drops | Last frame |")
      lines.append("| ---: | --- | ---: | --- | ---: | ---: | --- |")
      for display in snapshot.captureDisplayStats {
        let size = "\(display.widthPx)x\(display.heightPx)"
        let scale = display.displayScale.map { String(format: "%.2f", $0) } ?? "unknown"
        let lastFrame = display.lastFrameAt.map(iso) ?? "none"
        lines.append(
          "| \(display.displayId) | \(size) | \(scale) | \(display.mainDisplay) | \(display.framesEnqueued) | \(display.framesDropped) | \(lastFrame) |"
        )
      }
    }
    lines.append("")
    lines.append("## Queued Batches")
    lines.append("")
    if snapshot.localBatches.isEmpty {
      lines.append("No queued local batches.")
    } else {
      lines.append("| Batch | Modified | Bytes | Encrypted |")
      lines.append("| --- | --- | ---: | --- |")
      for batch in snapshot.localBatches {
        lines.append(
          "| \(redact(batch.batchId)) | \(iso(batch.modified)) | \(batch.bytes) | \(batch.encrypted) |"
        )
      }
    }
    lines.append("")
    lines.append(
      "OCR text, secrets, document paths, bearer tokens, and full endpoint query strings are omitted."
    )
    lines.append("")
    return lines.joined(separator: "\n")
  }

  static func write(_ snapshot: DiagnosticsSnapshot, directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(
      "diagnostics-\(fileTimestamp(snapshot.generatedAt)).md")
    try markdown(snapshot).write(to: url, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }

  static func redact(_ value: String) -> String {
    guard !value.isEmpty else { return value }
    if SecretScrubber.evaluate(value) != .clean {
      return "[redacted]"
    }
    return value.replacingOccurrences(of: NSHomeDirectory(), with: "~")
  }

  static func redactPath(_ value: String) -> String {
    if value.contains("/") || value.hasPrefix(".") {
      return value.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
    return redact(value)
  }

  private static func redactEndpoint(_ endpoint: URL) -> String {
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    components?.query = nil
    components?.user = nil
    components?.password = nil
    return components?.url?.absoluteString ?? "[redacted]"
  }

  private static func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func fileTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
