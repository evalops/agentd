// SPDX-License-Identifier: BUSL-1.1

import Foundation
import XCTest

@testable import agentd

final class CaptureHealthWatchdogTests: XCTestCase {
  func testIgnoresEventCaptureMode() {
    var watchdog = CaptureHealthWatchdog()
    let started = Date(timeIntervalSince1970: 100)
    watchdog.observeCaptureStarted(now: started)

    let decision = watchdog.evaluate(
      now: started.addingTimeInterval(120),
      captureRunning: true,
      eventCaptureEnabled: true,
      displayStats: [Self.display(lastFrameAt: nil)],
      staleAfterSeconds: 30
    )

    XCTAssertNil(decision)
  }

  func testRestartsWhenRunningStreamHasNoFrames() {
    var watchdog = CaptureHealthWatchdog()
    let started = Date(timeIntervalSince1970: 100)
    watchdog.observeCaptureStarted(now: started)

    let decision = watchdog.evaluate(
      now: started.addingTimeInterval(31),
      captureRunning: true,
      eventCaptureEnabled: false,
      displayStats: [Self.display(lastFrameAt: nil)],
      staleAfterSeconds: 30
    )

    XCTAssertEqual(decision?.displayId, 42)
    XCTAssertEqual(decision?.reason, "no frames observed")
  }

  func testRestartsWhenLastFrameIsStaleAndRecordsStats() {
    var watchdog = CaptureHealthWatchdog()
    let started = Date(timeIntervalSince1970: 100)
    let now = started.addingTimeInterval(90)
    watchdog.observeCaptureStarted(now: started)

    let decision = watchdog.evaluate(
      now: now,
      captureRunning: true,
      eventCaptureEnabled: false,
      displayStats: [Self.display(lastFrameAt: started.addingTimeInterval(10))],
      staleAfterSeconds: 30
    )

    let unwrapped = try! XCTUnwrap(decision)
    watchdog.recordRestart(unwrapped, now: now)

    XCTAssertEqual(unwrapped.reason, "stale frame stream")
    XCTAssertEqual(watchdog.stats().restartCount, 1)
    XCTAssertEqual(watchdog.stats().lastRestartDisplayId, 42)
  }

  private static func display(lastFrameAt: Date?) -> CaptureDisplayStats {
    CaptureDisplayStats(
      displayId: 42,
      widthPx: 1800,
      heightPx: 1169,
      displayScale: 1,
      mainDisplay: true,
      framesEnqueued: lastFrameAt == nil ? 0 : 3,
      framesDropped: 0,
      lastFrameAt: lastFrameAt
    )
  }
}
