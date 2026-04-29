// SPDX-License-Identifier: BUSL-1.1

import XCTest

@testable import agentd

final class MenuBarControllerTests: XCTestCase {
  func testMenuPresentationShowsPermissionAttention() {
    let presentation = MenuStatusPresentation(
      paused: false,
      detail: "capturing",
      permissions: PermissionSnapshot(accessibilityTrusted: true, screenCaptureTrusted: false),
      localOnly: true,
      policyVersion: nil,
      appVersion: "1.2.3"
    )

    XCTAssertEqual(presentation.title, "EvalOps agentd needs permissions")
    XCTAssertEqual(presentation.statusLine, "Status: capturing")
    XCTAssertEqual(presentation.aboutLine, "agentd 1.2.3 — local-only")
    XCTAssertEqual(presentation.badgeText, "Setup")
    XCTAssertEqual(presentation.symbolName, "exclamationmark.triangle.fill")
  }

  func testMenuPresentationShowsManagedPolicyState() {
    let presentation = MenuStatusPresentation(
      paused: true,
      detail: "scheduled pause",
      permissions: PermissionSnapshot(accessibilityTrusted: true, screenCaptureTrusted: true),
      localOnly: false,
      policyVersion: "42",
      appVersion: "1.2.3"
    )

    XCTAssertEqual(presentation.title, "EvalOps agentd")
    XCTAssertEqual(presentation.subtitle, "managed policy 42")
    XCTAssertEqual(presentation.statusLine, "Status: scheduled pause")
    XCTAssertEqual(presentation.permissionsLine, "Permissions: Ready")
    XCTAssertEqual(presentation.aboutLine, "agentd 1.2.3 — managed policy 42")
    XCTAssertEqual(presentation.badgeText, "Paused")
    XCTAssertEqual(presentation.symbolName, "pause.circle")
  }

  func testMenuPresentationShowsCapturingBadge() {
    let presentation = MenuStatusPresentation(
      paused: false,
      detail: "capturing, registered",
      permissions: PermissionSnapshot(accessibilityTrusted: true, screenCaptureTrusted: true),
      localOnly: false,
      policyVersion: nil,
      appVersion: "1.2.3"
    )

    XCTAssertEqual(presentation.badgeText, "Capturing")
    XCTAssertEqual(presentation.symbolName, "circle.fill")
  }
}
