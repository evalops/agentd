// SPDX-License-Identifier: BUSL-1.1

import Foundation
import XCTest

@testable import agentd

final class PauseStateTests: XCTestCase {
  func testManualPauseWinsOverScheduledAndPolicyPause() {
    let now = Date(timeIntervalSince1970: 100)
    let window = ScheduledPauseWindow(
      id: "meeting_1",
      reason: "customer meeting",
      startsAt: now.addingTimeInterval(-10),
      endsAt: now.addingTimeInterval(10)
    )

    let state = PauseStateResolver.resolve(
      userPaused: true,
      scheduledWindows: [window],
      foregroundPrivacyReason: "protected_content_url",
      policyPaused: true,
      policyReason: "fleet",
      now: now
    )

    XCTAssertEqual(state, .manual)
    XCTAssertEqual(state.reason, "manual")
  }

  func testScheduledPauseWinsOverPolicyAndExpires() {
    let now = Date(timeIntervalSince1970: 100)
    let window = ScheduledPauseWindow(
      id: "meeting_1",
      reason: "interview",
      startsAt: now.addingTimeInterval(-10),
      endsAt: now.addingTimeInterval(10)
    )

    XCTAssertEqual(
      PauseStateResolver.resolve(
        userPaused: false,
        scheduledWindows: [window],
        foregroundPrivacyReason: "protected_content_url",
        policyPaused: true,
        policyReason: "fleet",
        now: now
      ),
      .scheduled(id: "meeting_1", reason: "interview", endsAt: now.addingTimeInterval(10))
    )
    XCTAssertEqual(
      PauseStateResolver.resolve(
        userPaused: false,
        scheduledWindows: [window],
        foregroundPrivacyReason: nil,
        policyPaused: false,
        policyReason: nil,
        now: now.addingTimeInterval(11)
      ),
      .active
    )
  }

  func testNextScheduledPauseTransitionUsesStartOrEnd() {
    let now = Date(timeIntervalSince1970: 100)
    let window = ScheduledPauseWindow(
      id: "meeting_1",
      reason: "meeting",
      startsAt: now.addingTimeInterval(30),
      endsAt: now.addingTimeInterval(90)
    )

    XCTAssertEqual(
      PauseStateResolver.nextTransition(after: now, scheduledWindows: [window]),
      now.addingTimeInterval(30)
    )
    XCTAssertEqual(
      PauseStateResolver.nextTransition(
        after: now.addingTimeInterval(40), scheduledWindows: [window]),
      now.addingTimeInterval(90)
    )
  }

  func testForegroundPrivacyWinsOverPolicy() {
    let now = Date(timeIntervalSince1970: 100)

    let state = PauseStateResolver.resolve(
      userPaused: false,
      scheduledWindows: [],
      foregroundPrivacyReason: "protected_content_url",
      policyPaused: true,
      policyReason: "fleet",
      now: now
    )

    XCTAssertEqual(state, .foregroundPrivacy(reason: "protected_content_url"))
    XCTAssertEqual(state.reason, "foreground_privacy:protected_content_url")
  }
}
