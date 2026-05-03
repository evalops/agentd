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
    XCTAssertTrue(DiagnosticCLI.shouldHandle(["agentd", "capture-worker-stream"]))
    XCTAssertTrue(DiagnosticCLI.shouldHandle(["agentd", "selftest"]))
    XCTAssertTrue(DiagnosticCLI.shouldHandle(["agentd", "activity"]))
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

  func testCaptureWorkerStreamParserRequiresDisplayAndAcceptsFps() throws {
    let command = try DiagnosticCommand.parse([
      "capture-worker-stream", "--display-id", "7", "--fps", "0.5",
    ])

    guard case .captureWorkerStream(let options) = command else {
      return XCTFail("expected capture-worker-stream")
    }
    XCTAssertEqual(options.displayId, 7)
    XCTAssertEqual(options.fps, 0.5)
  }

  func testCaptureWorkerStreamParserRequiresDisplayId() {
    XCTAssertThrowsError(try DiagnosticCommand.parse(["capture-worker-stream", "--fps", "1"])) {
      error in
      guard let cliError = error as? DiagnosticCLIError else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(cliError.localizedDescription.contains("requires --display-id"))
    }
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

  func testActivityParserAcceptsSinceAndBatchDir() throws {
    let command = try DiagnosticCommand.parse([
      "activity", "--since", "2.5", "--batch-dir", "/tmp/agentd-batches",
    ])

    guard case .activity(let options) = command else {
      return XCTFail("expected activity")
    }
    XCTAssertEqual(options.sinceHours, 2.5)
    XCTAssertEqual(options.batchDirectory.path, "/tmp/agentd-batches")
  }

  func testActivitySummaryAggregatesPersistedBatches() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 3_600)
    try writeBatch(
      ActivitySummaryTests.batch(
        id: "batch_1",
        startedAt: Date(timeIntervalSince1970: 3_000),
        endedAt: Date(timeIntervalSince1970: 3_030),
        frames: [
          ActivitySummaryTests.frame(
            appName: "Ghostty",
            bundleId: "com.mitchellh.ghostty",
            windowTitle: "Disable CodeQL across EvalOps",
            documentPath: "https://sdk.cloud.google.com/auth?code=secret&state=abc&safe=keep"
          ),
          ActivitySummaryTests.frame(
            appName: "Codex",
            bundleId: "com.openai.codex",
            windowTitle: "Codex"
          ),
        ],
        droppedCounts: DropCounts(secret: 0, duplicate: 3, deniedApp: 1, deniedPath: 0),
        droppedReasonCounts: ["duplicate.phash": 3, "privacy.allowlist_miss": 1]
      ),
      to: root.appendingPathComponent("batch_1.json")
    )
    try writeBatch(
      ActivitySummaryTests.batch(
        id: "old_batch",
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 1_030),
        frames: [
          ActivitySummaryTests.frame(
            appName: "Old", bundleId: "com.old.App", windowTitle: "Old work")
        ]
      ),
      to: root.appendingPathComponent("old_batch.json")
    )

    let summary = try await ActivitySummary.run(
      options: ActivityOptions(sinceHours: 0.5, batchDirectory: root),
      now: now
    )

    XCTAssertEqual(summary.batchCount, 1)
    XCTAssertEqual(summary.nonemptyBatchCount, 1)
    XCTAssertEqual(summary.frameCount, 2)
    XCTAssertEqual(summary.droppedCounts.duplicate, 3)
    XCTAssertEqual(summary.droppedCounts.deniedApp, 1)
    XCTAssertEqual(summary.droppedReasonCounts["duplicate.phash"], 3)
    XCTAssertEqual(summary.apps.map(\.appName), ["Codex", "Ghostty"])
    XCTAssertEqual(summary.windows.first?.windowTitle, "Codex")
    XCTAssertTrue(summary.windows.contains { $0.windowTitle == "Disable CodeQL across EvalOps" })
    let ghostty = try XCTUnwrap(
      summary.windows.first { $0.windowTitle == "Disable CodeQL across EvalOps" })
    XCTAssertEqual(
      ghostty.documentPath,
      "https://sdk.cloud.google.com/auth?code=REDACTED&state=REDACTED&safe=keep"
    )
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

  private func writeBatch(_ batch: Batch, to url: URL) throws {
    try encodeSubmitBatchRequest(batch, localOnly: true).write(to: url)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

enum ActivitySummaryTests {
  static func batch(
    id: String,
    startedAt: Date,
    endedAt: Date,
    frames: [ProcessedFrame],
    droppedCounts: DropCounts = DropCounts(secret: 0, duplicate: 0, deniedApp: 0, deniedPath: 0),
    droppedReasonCounts: [String: Int] = [:]
  ) -> Batch {
    Batch(
      batchId: id,
      deviceId: "device_1",
      organizationId: "org_1",
      workspaceId: nil,
      userId: nil,
      projectId: nil,
      repository: nil,
      startedAt: startedAt,
      endedAt: endedAt,
      frames: frames,
      droppedCounts: droppedCounts,
      droppedReasonCounts: droppedReasonCounts
    )
  }

  static func frame(
    appName: String,
    bundleId: String,
    windowTitle: String,
    documentPath: String? = nil
  ) -> ProcessedFrame {
    ProcessedFrame(
      frameHash: UUID().uuidString,
      perceptualHash: 1,
      capturedAt: Date(timeIntervalSince1970: 3_010),
      bundleId: bundleId,
      appName: appName,
      windowTitle: windowTitle,
      documentPath: documentPath,
      ocrText: "",
      ocrConfidence: 0,
      widthPx: 8,
      heightPx: 8,
      bytesPng: 8 * 8 * 4
    )
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
