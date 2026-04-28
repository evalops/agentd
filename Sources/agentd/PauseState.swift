// SPDX-License-Identifier: BUSL-1.1

import Foundation

enum EffectivePauseState: Sendable, Equatable {
  case active
  case manual
  case scheduled(id: String, reason: String, endsAt: Date)
  case policy(reason: String?)

  var paused: Bool {
    switch self {
    case .active:
      return false
    case .manual, .scheduled, .policy:
      return true
    }
  }

  var reason: String? {
    switch self {
    case .active:
      return nil
    case .manual:
      return "manual"
    case .scheduled(_, let reason, _):
      return "scheduled:\(reason)"
    case .policy(let reason):
      return reason.map { "policy:\($0)" } ?? "policy"
    }
  }

  var detail: String {
    switch self {
    case .active:
      return "capturing"
    case .manual:
      return "paused by user"
    case .scheduled(_, let reason, _):
      return "paused by schedule: \(reason)"
    case .policy(let reason):
      return "paused by policy\(reason.map { ": \($0)" } ?? "")"
    }
  }
}

struct PauseStateResolver: Sendable {
  static func resolve(
    userPaused: Bool,
    scheduledWindows: [ScheduledPauseWindow],
    policyPaused: Bool,
    policyReason: String?,
    now: Date
  ) -> EffectivePauseState {
    if userPaused {
      return .manual
    }
    if let window = scheduledWindows.first(where: { $0.startsAt <= now && now < $0.endsAt }) {
      return .scheduled(id: window.id, reason: window.reason, endsAt: window.endsAt)
    }
    if policyPaused {
      return .policy(reason: policyReason)
    }
    return .active
  }

  static func nextTransition(after now: Date, scheduledWindows: [ScheduledPauseWindow]) -> Date? {
    scheduledWindows
      .flatMap { [$0.startsAt, $0.endsAt] }
      .filter { $0 > now }
      .sorted()
      .first
  }
}
