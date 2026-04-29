// SPDX-License-Identifier: BUSL-1.1

import Foundation
import XCTest

@testable import agentd

final class ForegroundPrivacyPauseTests: XCTestCase {
  func testPauseWindowTitlePatternTriggersForegroundPause() {
    let reason = ForegroundPrivacyPauseDetector.reason(
      context: Self.context(title: "1Password - Production Vault"),
      config: Self.config()
    )

    XCTAssertEqual(reason, "window_title_pattern")
  }

  func testProtectedStreamingDomainTriggersForegroundPause() {
    let reason = ForegroundPrivacyPauseDetector.reason(
      context: Self.context(title: "Safari", documentPath: "https://www.netflix.com/watch/123"),
      config: Self.config()
    )

    XCTAssertEqual(reason, "protected_content_url")
  }

  func testProtectedRemoteDesktopApplicationTriggersForegroundPause() {
    let reason = ForegroundPrivacyPauseDetector.reason(
      context: Self.context(appName: "Omnissa Horizon Client"),
      config: Self.config()
    )

    XCTAssertEqual(reason, "protected_application")
  }

  func testUnrelatedWindowDoesNotPause() {
    XCTAssertNil(
      ForegroundPrivacyPauseDetector.reason(
        context: Self.context(title: "main.swift - agentd"),
        config: Self.config()
      ))
  }

  private static func config() -> AgentConfig {
    AgentConfig(
      deviceId: "device_1",
      organizationId: "org_1",
      endpoint: URL(string: "http://127.0.0.1:8787/submit")!,
      allowedBundleIds: AgentConfig.defaultAllowedBundleIds,
      deniedBundleIds: AgentConfig.defaultDeniedBundleIds,
      deniedPathPrefixes: AgentConfig.defaultDeniedPathPrefixes,
      pauseWindowTitlePatterns: AgentConfig.defaultPauseWindowPatterns,
      captureFps: 1,
      idleFps: 0.2,
      batchIntervalSeconds: 30,
      maxFramesPerBatch: 24,
      localOnly: true
    )
  }

  private static func context(
    appName: String = "Safari",
    title: String = "normal",
    documentPath: String? = nil
  ) -> WindowContext {
    WindowContext(
      bundleId: "com.apple.Safari",
      appName: appName,
      windowTitle: title,
      documentPath: documentPath,
      pid: 123,
      timestamp: Date()
    )
  }
}
