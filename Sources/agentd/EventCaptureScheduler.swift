// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation

enum EventCaptureTrigger: String, Codable, CaseIterable, Sendable, Hashable {
  case focusedWindow
  case clipboard
  case idleFallback
  case click
  case typingPause
  case scrollStop
  case manual
}

struct EventCaptureStats: Sendable, Equatable {
  let enabled: Bool
  let triggerCounts: [EventCaptureTrigger: Int]
  let capturesStarted: Int
  let capturesSucceeded: Int
  let capturesFailed: Int
  let triggersDebounced: Int
  let triggersSuppressedByMinGap: Int

  static let disabled = EventCaptureStats(
    enabled: false,
    triggerCounts: [:],
    capturesStarted: 0,
    capturesSucceeded: 0,
    capturesFailed: 0,
    triggersDebounced: 0,
    triggersSuppressedByMinGap: 0
  )
}

struct EventCaptureScheduler: Sendable {
  private var config: AgentConfig
  private var lastAcceptedAt: Date?
  private var lastIdleFallbackAt: Date?
  private var lastFocusedWindow: FocusedWindowSignature?
  private var pendingFocusedWindow: PendingFocusedWindow?
  private var lastClipboardChangeCount: Int?
  private var triggerCounts: [EventCaptureTrigger: Int] = [:]
  private var capturesStarted = 0
  private var capturesSucceeded = 0
  private var capturesFailed = 0
  private var triggersDebounced = 0
  private var triggersSuppressedByMinGap = 0

  init(config: AgentConfig) {
    self.config = config
  }

  mutating func updateConfig(_ next: AgentConfig) {
    config = next
    if !next.eventCaptureEnabled {
      pendingFocusedWindow = nil
    }
  }

  mutating func observe(
    context: WindowContext?,
    clipboardChangeCount: Int?,
    now: Date
  ) -> [EventCaptureTrigger] {
    guard config.eventCaptureEnabled else { return [] }

    var triggers: [EventCaptureTrigger] = []
    if observeFocusedWindow(context: context, now: now) {
      triggers.append(.focusedWindow)
    }
    if observeClipboard(changeCount: clipboardChangeCount) {
      triggers.append(.clipboard)
    }
    if shouldRunIdleFallback(now: now) {
      triggers.append(.idleFallback)
    }
    return triggers.compactMap { accept($0, now: now) }
  }

  mutating func request(_ trigger: EventCaptureTrigger, now: Date) -> EventCaptureTrigger? {
    guard config.eventCaptureEnabled else { return nil }
    return accept(trigger, now: now)
  }

  mutating func recordCaptureStarted() {
    capturesStarted += 1
  }

  mutating func recordCaptureSucceeded() {
    capturesSucceeded += 1
  }

  mutating func recordCaptureFailed() {
    capturesFailed += 1
  }

  func stats() -> EventCaptureStats {
    EventCaptureStats(
      enabled: config.eventCaptureEnabled,
      triggerCounts: triggerCounts,
      capturesStarted: capturesStarted,
      capturesSucceeded: capturesSucceeded,
      capturesFailed: capturesFailed,
      triggersDebounced: triggersDebounced,
      triggersSuppressedByMinGap: triggersSuppressedByMinGap
    )
  }

  private mutating func observeFocusedWindow(context: WindowContext?, now: Date) -> Bool {
    guard let signature = context.map(FocusedWindowSignature.init) else { return false }
    guard signature != lastFocusedWindow else {
      pendingFocusedWindow = nil
      return false
    }

    if pendingFocusedWindow?.signature != signature {
      pendingFocusedWindow = PendingFocusedWindow(signature: signature, firstSeenAt: now)
      triggersDebounced += 1
      return false
    }

    guard let pendingFocusedWindow,
      now.timeIntervalSince(pendingFocusedWindow.firstSeenAt) >= config.eventCaptureDebounceSeconds
    else {
      triggersDebounced += 1
      return false
    }

    lastFocusedWindow = signature
    self.pendingFocusedWindow = nil
    return true
  }

  private mutating func observeClipboard(changeCount: Int?) -> Bool {
    guard let changeCount else { return false }
    defer { lastClipboardChangeCount = changeCount }
    guard let lastClipboardChangeCount else { return false }
    return changeCount != lastClipboardChangeCount
  }

  private mutating func shouldRunIdleFallback(now: Date) -> Bool {
    guard config.eventCaptureIdleFallbackSeconds > 0 else { return false }
    let reference = lastAcceptedAt ?? lastIdleFallbackAt
    guard let reference else { return true }
    return now.timeIntervalSince(reference) >= config.eventCaptureIdleFallbackSeconds
  }

  private mutating func accept(
    _ trigger: EventCaptureTrigger,
    now: Date
  ) -> EventCaptureTrigger? {
    if let lastAcceptedAt,
      now.timeIntervalSince(lastAcceptedAt) < config.eventCaptureMinGapSeconds
    {
      triggersSuppressedByMinGap += 1
      return nil
    }
    lastAcceptedAt = now
    if trigger == .idleFallback {
      lastIdleFallbackAt = now
    }
    triggerCounts[trigger, default: 0] += 1
    return trigger
  }
}

private struct PendingFocusedWindow: Sendable, Equatable {
  let signature: FocusedWindowSignature
  let firstSeenAt: Date
}

private struct FocusedWindowSignature: Sendable, Equatable {
  let bundleId: String
  let pid: pid_t
  let titleHash: String
  let documentHash: String

  init(context: WindowContext) {
    bundleId = context.bundleId
    pid = context.pid
    titleHash = Self.hash(context.windowTitle)
    documentHash = Self.hash(context.documentPath ?? "")
  }

  private static func hash(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }
}
