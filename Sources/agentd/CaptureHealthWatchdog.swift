// SPDX-License-Identifier: BUSL-1.1

import Foundation

struct CaptureHealthDecision: Sendable, Equatable {
  let displayId: UInt32?
  let reason: String
}

struct CaptureHealthStats: Sendable, Equatable {
  let restartCount: Int
  let lastRestartAt: Date?
  let lastRestartDisplayId: UInt32?
  let lastRestartReason: String?
}

struct CaptureHealthWatchdog: Sendable {
  private var runningSince: Date?
  private var restartCount = 0
  private var lastRestartAt: Date?
  private var lastRestartDisplayId: UInt32?
  private var lastRestartReason: String?

  mutating func observeCaptureStarted(now: Date = Date()) {
    runningSince = now
  }

  mutating func observeCaptureStopped() {
    runningSince = nil
  }

  mutating func recordRestart(_ decision: CaptureHealthDecision, now: Date = Date()) {
    restartCount += 1
    lastRestartAt = now
    lastRestartDisplayId = decision.displayId
    lastRestartReason = decision.reason
    runningSince = nil
  }

  func stats() -> CaptureHealthStats {
    CaptureHealthStats(
      restartCount: restartCount,
      lastRestartAt: lastRestartAt,
      lastRestartDisplayId: lastRestartDisplayId,
      lastRestartReason: lastRestartReason
    )
  }

  func evaluate(
    now: Date = Date(),
    captureRunning: Bool,
    eventCaptureEnabled: Bool,
    displayStats: [CaptureDisplayStats],
    staleAfterSeconds: TimeInterval
  ) -> CaptureHealthDecision? {
    guard captureRunning, !eventCaptureEnabled else { return nil }
    guard let runningSince else { return nil }
    let staleAfterSeconds = max(1, staleAfterSeconds)
    guard now.timeIntervalSince(runningSince) >= staleAfterSeconds else { return nil }
    guard !displayStats.isEmpty else {
      return CaptureHealthDecision(displayId: nil, reason: "no active display stats")
    }

    for display in displayStats.sorted(by: { $0.displayId < $1.displayId }) {
      guard let lastFrameAt = display.lastFrameAt else {
        return CaptureHealthDecision(displayId: display.displayId, reason: "no frames observed")
      }
      if now.timeIntervalSince(lastFrameAt) >= staleAfterSeconds {
        return CaptureHealthDecision(displayId: display.displayId, reason: "stale frame stream")
      }
    }
    return nil
  }
}
