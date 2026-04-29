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
  }

  func testDisabledWithoutFeedOrPublicKey() {
    let cfg = SparkleUpdaterConfiguration.read(from: [:])

    XCTAssertFalse(cfg.isConfigured)
    XCTAssertEqual(
      cfg.disabledReason,
      "Sparkle update feed and public key are not configured for this build."
    )
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
