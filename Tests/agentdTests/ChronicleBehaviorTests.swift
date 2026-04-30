// SPDX-License-Identifier: BUSL-1.1

import XCTest

@testable import agentd

final class ChronicleBehaviorTests: XCTestCase {
  func testPlainDomainTierDoesNotMatchDomainSubstring() {
    let tiers = [DomainTier(pattern: "x.com", tier: .audit)]

    XCTAssertEqual(
      ChronicleBehavior.captureTier(for: "https://dropbox.com/files", domainTiers: tiers),
      .evidence
    )
    XCTAssertEqual(
      ChronicleBehavior.captureTier(for: "https://box.com/files", domainTiers: tiers),
      .evidence
    )
    XCTAssertEqual(
      ChronicleBehavior.captureTier(for: "https://x.com/home", domainTiers: tiers),
      .audit
    )
    XCTAssertEqual(
      ChronicleBehavior.captureTier(for: "https://mobile.x.com/home", domainTiers: tiers),
      .audit
    )
    XCTAssertEqual(
      ChronicleBehavior.captureTier(for: "https://evil.com/config.x.com", domainTiers: tiers),
      .evidence
    )
  }

  func testUrlGlobMatchesHostPathWithoutSubstringFallback() {
    let tiers = [
      DomainTier(pattern: "github.com/*/pull/*", tier: .audit)
    ]

    XCTAssertEqual(
      ChronicleBehavior.captureTier(
        for: "https://github.com/evalops/agentd/pull/102",
        domainTiers: tiers
      ),
      .audit
    )
    XCTAssertEqual(
      ChronicleBehavior.captureTier(
        for: "https://notgithub.com/evalops/agentd/pull/102",
        domainTiers: tiers
      ),
      .evidence
    )
  }
}
