// SPDX-License-Identifier: BUSL-1.1

import Foundation
import XCTest

@testable import agentd

final class DiagnosticCLITests: XCTestCase {
  func testShouldHandleOnlyDiagnosticCommands() {
    XCTAssertFalse(DiagnosticCLI.shouldHandle(["agentd"]))
    XCTAssertTrue(DiagnosticCLI.shouldHandle(["agentd", "list-displays"]))
    XCTAssertTrue(DiagnosticCLI.shouldHandle(["agentd", "capture-once"]))
    XCTAssertTrue(DiagnosticCLI.shouldHandle(["agentd", "selftest"]))
    XCTAssertFalse(DiagnosticCLI.shouldHandle(["agentd", "--local-only"]))
  }

  func testCaptureOnceParserAcceptsSafeFlags() throws {
    let command = try DiagnosticCommand.parse([
      "capture-once", "--display-id", "42", "--no-ocr", "--out", "/tmp/agentd.json",
    ])

    guard case .captureOnce(let options) = command else {
      return XCTFail("expected capture-once")
    }
    XCTAssertEqual(options.displayId, 42)
    XCTAssertTrue(options.noOCR)
    XCTAssertEqual(options.out?.path, "/tmp/agentd.json")
  }

  func testCaptureOnceParserRecognizesUnsafeScrubBypassForRuntimeRefusal() throws {
    let command = try DiagnosticCommand.parse(["capture-once", "--no-scrub"])

    guard case .captureOnce(let options) = command else {
      return XCTFail("expected capture-once")
    }
    XCTAssertTrue(options.noScrub)
  }

  func testCaptureOnceParserRejectsUnknownFlags() {
    XCTAssertThrowsError(try DiagnosticCommand.parse(["capture-once", "--stream"])) { error in
      guard let cliError = error as? DiagnosticCLIError else {
        return XCTFail("expected DiagnosticCLIError")
      }
      XCTAssertTrue(cliError.showsUsage)
      XCTAssertTrue(cliError.localizedDescription.contains("unknown capture-once flag"))
    }
  }

  func testListDisplaysRejectsFlags() {
    XCTAssertThrowsError(try DiagnosticCommand.parse(["list-displays", "--json"])) { error in
      guard let cliError = error as? DiagnosticCLIError else {
        return XCTFail("expected DiagnosticCLIError")
      }
      XCTAssertTrue(cliError.showsUsage)
      XCTAssertTrue(cliError.localizedDescription.contains("takes no flags"))
    }
  }
}
