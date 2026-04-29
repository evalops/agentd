// SPDX-License-Identifier: BUSL-1.1

import Foundation
import XCTest

@testable import agentd

final class DiagnosticCLITests: XCTestCase {
  func testShouldHandleOnlyDiagnosticCommands() {
    XCTAssertFalse(DiagnosticCLI.shouldHandle(["agentd"]))
    XCTAssertTrue(DiagnosticCLI.shouldHandle(["agentd", "list-displays"]))
    XCTAssertTrue(DiagnosticCLI.shouldHandle(["agentd", "capture-once"]))
    XCTAssertTrue(DiagnosticCLI.shouldHandle(["agentd", "capture-worker-once"]))
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

  func testCaptureWorkerOnceParserReusesCaptureOnceSafeFlags() throws {
    let command = try DiagnosticCommand.parse([
      "capture-worker-once", "--display-id", "7", "--no-ocr",
    ])

    guard case .captureWorkerOnce(let options) = command else {
      return XCTFail("expected capture-worker-once")
    }
    XCTAssertEqual(options.displayId, 7)
    XCTAssertTrue(options.noOCR)
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

  func testDisplayDiagnosticsReturnsStructuredTimeout() async {
    let snapshot = await DisplayDiagnostics.snapshot(
      probe: SlowDisplayProbe(),
      timeoutNanoseconds: 5_000_000
    )

    XCTAssertTrue(snapshot.displayProbe.timedOut)
    XCTAssertEqual(snapshot.displayProbe.unavailableReason, "display discovery timed out")
    XCTAssertEqual(snapshot.displays, [])
  }

  func testDisplayDiagnosticsReturnsStructuredProbeError() async {
    let snapshot = await DisplayDiagnostics.snapshot(
      probe: ThrowingDisplayProbe(),
      timeoutNanoseconds: 1_000_000_000
    )

    XCTAssertFalse(snapshot.displayProbe.timedOut)
    XCTAssertEqual(snapshot.displayProbe.unavailableReason, "synthetic display failure")
    XCTAssertEqual(snapshot.displays, [])
  }

  @MainActor
  func testDiagnosticPermissionsReturnStructuredTimeout() {
    let permissions = DiagnosticPermissionSnapshot.current(
      promptForAccessibility: false,
      screenCaptureTimeoutSeconds: 0.005
    ) {
      Thread.sleep(forTimeInterval: 0.1)
      return true
    }

    XCTAssertNil(permissions.screenCaptureTrusted)
    XCTAssertTrue(permissions.screenCaptureProbe.timedOut)
    XCTAssertEqual(
      permissions.screenCaptureProbe.unavailableReason,
      "screen capture permission preflight timed out"
    )
  }

  func testSelftestIncludesDegradedDisplayProbe() async {
    let output = await SelftestDiagnostics.run(
      displayProbe: SlowDisplayProbe(),
      displayTimeoutNanoseconds: 5_000_000
    )

    XCTAssertTrue(output.displayProbe.timedOut)
    XCTAssertEqual(output.displayCount, 0)
  }
}

private struct SlowDisplayProbe: DisplayDiagnosticsProbing {
  func displays() async throws -> [DisplayDiagnostic] {
    try await Task.sleep(nanoseconds: 1_000_000_000)
    return [
      DisplayDiagnostic(
        displayId: 1,
        name: "Slow",
        width: 1,
        height: 1,
        scale: 1,
        isMain: true,
        bounds: DisplayBounds(x: 0, y: 0, width: 1, height: 1)
      )
    ]
  }
}

private struct ThrowingDisplayProbe: DisplayDiagnosticsProbing {
  func displays() async throws -> [DisplayDiagnostic] {
    throw DiagnosticCLIError.displayProbeFailed("synthetic display failure")
  }
}
