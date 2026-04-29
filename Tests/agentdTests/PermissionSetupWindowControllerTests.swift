// SPDX-License-Identifier: BUSL-1.1

import AppKit
import XCTest

@testable import agentd

@MainActor
final class PermissionSetupWindowControllerTests: XCTestCase {
  func testBuildsPermissionSetupWindowWithoutTriggeringActions() throws {
    var actionsOpened = 0
    let controller = PermissionSetupWindowController(
      currentPermissions: {
        PermissionSnapshot(accessibilityTrusted: true, screenCaptureTrusted: false)
      },
      onOpenScreenRecordingSettings: {
        actionsOpened += 1
      },
      onOpenAccessibilitySettings: {
        actionsOpened += 1
      },
      onRelaunch: {
        actionsOpened += 1
      }
    )

    let window = try XCTUnwrap(controller.window)
    XCTAssertEqual(window.title, "agentd Permissions")
    XCTAssertNotNil(window.contentView)
    XCTAssertEqual(actionsOpened, 0)
    controller.close()
  }
}
