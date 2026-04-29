// SPDX-License-Identifier: BUSL-1.1

import XCTest

@testable import agentd

final class EventCaptureSchedulerTests: XCTestCase {
  func testFocusedWindowTriggerWaitsForDebounce() {
    var scheduler = EventCaptureScheduler(config: Self.config())
    let start = Date(timeIntervalSince1970: 100)

    XCTAssertEqual(
      scheduler.observe(
        context: Self.context(windowTitle: "A"), clipboardChangeCount: 1, now: start),
      []
    )
    XCTAssertEqual(
      scheduler.observe(
        context: Self.context(windowTitle: "A"),
        clipboardChangeCount: 1,
        now: start.addingTimeInterval(0.1)
      ),
      []
    )
    XCTAssertEqual(
      scheduler.observe(
        context: Self.context(windowTitle: "A"),
        clipboardChangeCount: 1,
        now: start.addingTimeInterval(0.3)
      ),
      [.focusedWindow]
    )

    let stats = scheduler.stats()
    XCTAssertEqual(stats.triggerCounts[.focusedWindow], 1)
    XCTAssertEqual(stats.triggersDebounced, 2)
  }

  func testMinGapSuppressesRapidTriggers() {
    var scheduler = EventCaptureScheduler(config: Self.config())
    let start = Date(timeIntervalSince1970: 100)

    XCTAssertEqual(
      scheduler.observe(
        context: Self.context(windowTitle: "A"),
        clipboardChangeCount: 1,
        now: start.addingTimeInterval(0.3)
      ),
      []
    )
    XCTAssertEqual(
      scheduler.observe(
        context: Self.context(windowTitle: "A"),
        clipboardChangeCount: 1,
        now: start.addingTimeInterval(0.6)
      ),
      [.focusedWindow]
    )
    XCTAssertEqual(
      scheduler.observe(
        context: Self.context(windowTitle: "A"),
        clipboardChangeCount: 2,
        now: start.addingTimeInterval(0.7)
      ),
      []
    )

    XCTAssertEqual(scheduler.stats().triggersSuppressedByMinGap, 1)
  }

  func testIdleFallbackRunsAfterConfiguredGap() {
    var cfg = Self.config()
    cfg.eventCaptureIdleFallbackSeconds = 5
    cfg.eventCaptureMinGapSeconds = 0
    var scheduler = EventCaptureScheduler(config: cfg)
    let start = Date(timeIntervalSince1970: 100)

    XCTAssertEqual(
      scheduler.observe(context: nil, clipboardChangeCount: 1, now: start),
      [.idleFallback]
    )
    XCTAssertEqual(
      scheduler.observe(context: nil, clipboardChangeCount: 1, now: start.addingTimeInterval(4)),
      []
    )
    XCTAssertEqual(
      scheduler.observe(context: nil, clipboardChangeCount: 1, now: start.addingTimeInterval(5)),
      [.idleFallback]
    )
  }

  func testDisabledSchedulerIgnoresSignals() {
    var cfg = Self.config()
    cfg.eventCaptureEnabled = false
    var scheduler = EventCaptureScheduler(config: cfg)

    XCTAssertEqual(
      scheduler.observe(
        context: Self.context(windowTitle: "A"),
        clipboardChangeCount: 2,
        now: Date(timeIntervalSince1970: 1)
      ),
      []
    )
    XCTAssertFalse(scheduler.stats().enabled)
  }

  func testNativeEventRequestsUseMinGapAndCounters() {
    var scheduler = EventCaptureScheduler(config: Self.config())
    let start = Date(timeIntervalSince1970: 100)

    XCTAssertEqual(scheduler.request(.click, now: start), .click)
    XCTAssertNil(scheduler.request(.typingPause, now: start.addingTimeInterval(0.1)))
    XCTAssertEqual(scheduler.request(.scrollStop, now: start.addingTimeInterval(1.1)), .scrollStop)

    let stats = scheduler.stats()
    XCTAssertEqual(stats.triggerCounts[.click], 1)
    XCTAssertEqual(stats.triggerCounts[.scrollStop], 1)
    XCTAssertEqual(stats.triggersSuppressedByMinGap, 1)
  }

  private static func config() -> AgentConfig {
    AgentConfig(
      deviceId: "device_1",
      organizationId: "org_1",
      endpoint: URL(string: "http://127.0.0.1:8787/chronicle.v1.ChronicleService/SubmitBatch")!,
      allowedBundleIds: AgentConfig.defaultAllowedBundleIds,
      deniedBundleIds: AgentConfig.defaultDeniedBundleIds,
      deniedPathPrefixes: AgentConfig.defaultDeniedPathPrefixes,
      pauseWindowTitlePatterns: AgentConfig.defaultPauseWindowPatterns,
      captureFps: 1,
      idleFps: 0.2,
      batchIntervalSeconds: 30,
      maxFramesPerBatch: 24,
      eventCaptureEnabled: true,
      eventCaptureDebounceSeconds: 0.25,
      eventCaptureMinGapSeconds: 1,
      eventCaptureIdleFallbackSeconds: 0,
      localOnly: true
    )
  }

  private static func context(windowTitle: String) -> WindowContext {
    WindowContext(
      bundleId: "com.test.App",
      appName: "Test",
      windowTitle: windowTitle,
      documentPath: nil,
      pid: 123,
      timestamp: Date()
    )
  }
}
