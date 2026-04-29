// SPDX-License-Identifier: BUSL-1.1

import XCTest

@testable import agentd

final class SparkleUpdaterConfigurationTests: XCTestCase {
  func testConfiguredWhenFeedAndPublicKeyArePresent() {
    let cfg = SparkleUpdaterConfiguration.read(from: [
      "SUFeedURL": "https://updates.example.invalid/agentd/appcast.xml",
      "SUPublicEDKey": "public-key",
    ])

    XCTAssertTrue(cfg.isConfigured)
    XCTAssertEqual(
      cfg.feedURL?.absoluteString,
      "https://updates.example.invalid/agentd/appcast.xml"
    )
    XCTAssertEqual(cfg.publicEDKey, "public-key")

    let presentation = SparkleUpdateMenuPresentation(configuration: cfg)
    XCTAssertEqual(presentation.title, "Check for Updates…")
    XCTAssertEqual(presentation.statusLine, "Updates: Enabled")
    XCTAssertEqual(presentation.symbolName, "arrow.down.circle")
    XCTAssertTrue(presentation.isConfigured)
  }

  func testDisabledWithoutFeedOrPublicKey() {
    let cfg = SparkleUpdaterConfiguration.read(from: [:])

    XCTAssertFalse(cfg.isConfigured)
    XCTAssertEqual(
      cfg.disabledReason,
      "Sparkle update feed and public key are not configured for this build."
    )

    let presentation = SparkleUpdateMenuPresentation(configuration: cfg)
    XCTAssertEqual(presentation.title, "Updates Not Configured")
    XCTAssertEqual(presentation.statusLine, "Updates: Local build")
    XCTAssertEqual(presentation.symbolName, "arrow.down.circle.dotted")
    XCTAssertFalse(presentation.isConfigured)
  }

  func testDisabledWhenPublicKeyIsBlank() {
    let cfg = SparkleUpdaterConfiguration.read(from: [
      "SUFeedURL": "https://updates.example.invalid/agentd/appcast.xml",
      "SUPublicEDKey": "   ",
    ])

    XCTAssertFalse(cfg.isConfigured)
    XCTAssertEqual(cfg.disabledReason, "Sparkle public key is not configured for this build.")
  }
}
