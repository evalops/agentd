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
    XCTAssertTrue(DiagnosticCLI.shouldHandle(["agentd", "mcp"]))
    XCTAssertFalse(DiagnosticCLI.shouldHandle(["agentd", "--local-only"]))
  }

  func testMcpInitializeAndToolsListExposeLocalContextTools() async throws {
    let runtime = AgentdMCPRuntimeStub()
    let server = AgentdMCPServer(runtime: runtime)

    let initialize = try await server.handle(
      jsonData(
        [
          "jsonrpc": "2.0",
          "id": 1,
          "method": "initialize",
          "params": [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "codex-test", "version": "dev"],
          ],
        ]))
    let initializeRoot = try jsonObject(initialize)

    XCTAssertEqual(initializeRoot["jsonrpc"] as? String, "2.0")
    XCTAssertEqual(initializeRoot["id"] as? Int, 1)
    let initializeResult = try XCTUnwrap(initializeRoot["result"] as? [String: Any])
    XCTAssertEqual(initializeResult["protocolVersion"] as? String, "2025-06-18")

    let tools = try await server.handle(
      jsonData(["jsonrpc": "2.0", "id": "tools", "method": "tools/list"]))
    let toolsRoot = try jsonObject(tools)
    let toolsResult = try XCTUnwrap(toolsRoot["result"] as? [String: Any])
    let toolList = try XCTUnwrap(toolsResult["tools"] as? [[String: Any]])
    let names = Set(toolList.compactMap { $0["name"] as? String })

    XCTAssertEqual(
      names,
      [
        "agentd_device_snapshot", "agentd_work_context", "agentd_activity_recent",
        "agentd_collect_diagnostics",
      ]
    )
    let annotationsByName = Dictionary(
      uniqueKeysWithValues: try toolList.map { tool in
        (
          try XCTUnwrap(tool["name"] as? String),
          try XCTUnwrap(tool["annotations"] as? [String: Any])
        )
      }
    )
    XCTAssertEqual(annotationsByName["agentd_device_snapshot"]?["readOnlyHint"] as? Bool, true)
    XCTAssertEqual(annotationsByName["agentd_work_context"]?["readOnlyHint"] as? Bool, true)
    XCTAssertEqual(annotationsByName["agentd_activity_recent"]?["readOnlyHint"] as? Bool, true)
    XCTAssertEqual(annotationsByName["agentd_collect_diagnostics"]?["readOnlyHint"] as? Bool, false)
  }

  func testMcpConfigParserAcceptsCommandAndServerName() throws {
    let command = try DiagnosticCommand.parse([
      "mcp", "config", "--command", "/Applications/EvalOps agentd.app/Contents/MacOS/agentd",
      "--server-name", "evalops-agentd",
    ])

    XCTAssertEqual(
      command,
      .mcpConfig(
        AgentdMCPConfigOptions(
          command: "/Applications/EvalOps agentd.app/Contents/MacOS/agentd",
          serverName: "evalops-agentd"
        ))
    )
  }

  func testMcpClientConfigEncodesClaudeStyleServerConfig() throws {
    let payload = AgentdMCPClientConfig(command: "/usr/local/bin/agentd", serverName: "agentd")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try jsonObject(encoder.encode(payload))
    let servers = try XCTUnwrap(encoded["mcpServers"] as? [String: Any])
    let agentd = try XCTUnwrap(servers["agentd"] as? [String: Any])

    XCTAssertEqual(agentd["command"] as? String, "/usr/local/bin/agentd")
    XCTAssertEqual(agentd["args"] as? [String], ["mcp"])
  }

  func testMcpResponsesAreSingleLineJSONRPCMessages() async throws {
    let server = AgentdMCPServer(runtime: AgentdMCPRuntimeStub())

    let response = try await server.handle(
      jsonData(["jsonrpc": "2.0", "id": "tools", "method": "tools/list"]))

    XCTAssertEqual(response.filter { $0 == 0x0A }.count, 1)
    XCTAssertEqual(response.last, 0x0A)
  }

  func testMcpErrorsReturnJSONRPCResponses() async throws {
    let server = AgentdMCPServer(runtime: AgentdMCPRuntimeStub())

    let invalidParams = try await server.handle(
      jsonData([
        "jsonrpc": "2.0",
        "id": "bad-window",
        "method": "tools/call",
        "params": [
          "name": "agentd_activity_recent",
          "arguments": ["window": "bad"],
        ],
      ]))
    let invalidParamsRoot = try jsonObject(invalidParams)
    let invalidParamsError = try XCTUnwrap(invalidParamsRoot["error"] as? [String: Any])
    XCTAssertEqual(invalidParamsRoot["id"] as? String, "bad-window")
    XCTAssertEqual(invalidParamsError["code"] as? Int, -32602)

    let parseError = try await server.handle(Data("{".utf8))
    let parseErrorRoot = try jsonObject(parseError)
    let parseErrorBody = try XCTUnwrap(parseErrorRoot["error"] as? [String: Any])
    XCTAssertTrue(parseErrorRoot["id"] is NSNull)
    XCTAssertEqual(parseErrorBody["code"] as? Int, -32700)
  }

  func testMcpActivityRecentReturnsRedactedActivitySummary() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = AgentdMCPRuntimeStub()
    runtime.activitySummary = ActivitySummaryTests.summary(
      batchDirectory: root,
      windows: [
        ActivityWindowSummary(
          appName: "Google Chrome",
          bundleId: "com.google.Chrome",
          windowTitle: "Review EvalOps",
          documentPath: "https://github.com/evalops/platform/pull/123?code=REDACTED&safe=1",
          frameCount: 3,
          firstSeenAt: Date(timeIntervalSince1970: 100),
          lastSeenAt: Date(timeIntervalSince1970: 120)
        )
      ]
    )
    let server = AgentdMCPServer(runtime: runtime)

    let response = try await server.handle(
      jsonData([
        "jsonrpc": "2.0",
        "id": "activity",
        "method": "tools/call",
        "params": [
          "name": "agentd_activity_recent",
          "arguments": ["window": "6h", "batch_dir": root.path],
        ],
      ]))
    let text = try mcpText(response)
    let decoded = try jsonObject(Data(text.utf8))

    XCTAssertEqual(decoded["windowLabel"] as? String, "6h")
    XCTAssertEqual(decoded["batchDirectory"] as? String, root.path)
    let windows = try XCTUnwrap(decoded["windows"] as? [[String: Any]])
    XCTAssertEqual(
      windows.first?["documentPath"] as? String,
      "https://github.com/evalops/platform/pull/123?code=REDACTED&safe=1"
    )
    XCTAssertEqual(runtime.requestedActivity?.windowLabel, "6h")
    XCTAssertEqual(runtime.requestedActivity?.batchDirectory.path, root.path)
  }

  func testMcpWorkContextReturnsBoundedFreshStatusForAgents() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = AgentdMCPRuntimeStub()
    runtime.deviceSnapshot = AgentdMCPDeviceSnapshot(
      generatedAt: Date(timeIntervalSince1970: 1_000),
      appVersion: "0.3.0",
      deviceId: "device_1",
      organizationId: "evalops",
      mode: "managed",
      endpoint: "https://chronicle.evalops.dev/chronicle.v1.ChronicleService/SubmitBatch",
      permissions: AgentdMCPPermissionStatus(
        accessibilityTrusted: true,
        screenCaptureTrusted: false,
        menuSummary: "Needs Screen Recording"
      ),
      localBatchStats: AgentdMCPLocalBatchStats(fileCount: 1, bytes: 64),
      privacy: AgentdMCPPrivacyStatus(
        allowedBundleCount: 3,
        deniedBundleCount: 1,
        deniedPathPrefixCount: 2,
        pauseTitlePatternCount: 4,
        captureAllDisplays: true,
        selectedDisplayIds: []
      )
    )
    runtime.activitySummary = ActivitySummary(
      generatedAt: Date(timeIntervalSince1970: 1_000),
      since: Date(timeIntervalSince1970: 800),
      until: Date(timeIntervalSince1970: 1_000),
      staleAfter: Date(timeIntervalSince1970: 1_600),
      windowLabel: "24h",
      batchDirectory: root.path,
      batchCount: 2,
      nonemptyBatchCount: 1,
      frameCount: 3,
      sourceBatchIds: ["batch_1"],
      displayIds: [1, 2],
      droppedCounts: DropCounts(secret: 1, duplicate: 2, deniedApp: 0, deniedPath: 0),
      droppedReasonCounts: ["secret.ocrText:openai": 1],
      apps: [
        ActivityAppSummary(appName: "Codex", bundleId: "com.openai.codex", frameCount: 1),
        ActivityAppSummary(appName: "Ghostty", bundleId: "com.mitchellh.ghostty", frameCount: 2),
      ],
      windows: [
        ActivityWindowSummary(
          appName: "Google Chrome",
          bundleId: "com.google.Chrome",
          windowTitle: "evalops/agentd#123",
          documentPath: "https://github.com/evalops/agentd/pull/123?token=REDACTED",
          frameCount: 3,
          firstSeenAt: Date(timeIntervalSince1970: 900),
          lastSeenAt: Date(timeIntervalSince1970: 1_000)
        )
      ],
      artifacts: [
        ActivityArtifactSummary(
          label: "evalops/agentd#123",
          url: "https://github.com/evalops/agentd/pull/123",
          batchCount: 1,
          firstSeenAt: Date(timeIntervalSince1970: 900),
          lastSeenAt: Date(timeIntervalSince1970: 1_000),
          foregroundSeconds: 60
        )
      ]
    )
    let server = AgentdMCPServer(runtime: runtime)

    let response = try await server.handle(
      jsonData([
        "jsonrpc": "2.0",
        "id": "work",
        "method": "tools/call",
        "params": [
          "name": "agentd_work_context",
          "arguments": ["window": "6h", "batch_dir": root.path],
        ],
      ]))
    let decoded = try jsonObject(Data(try mcpText(response).utf8))

    XCTAssertEqual(decoded["generatedAt"] as? String, "1970-01-01T00:20:00Z")
    XCTAssertEqual(
      decoded["warnings"] as? [String],
      [
        "screen recording permission is not trusted",
        "queued local batches are waiting to submit",
      ])
    let activity = try XCTUnwrap(decoded["activity"] as? [String: Any])
    XCTAssertEqual(activity["windowLabel"] as? String, "6h")
    XCTAssertEqual(activity["frameCount"] as? Int, 3)
    let topApps = try XCTUnwrap(activity["topApps"] as? [[String: Any]])
    XCTAssertEqual(topApps.first?["appName"] as? String, "Ghostty")
    let activeArtifacts = try XCTUnwrap(activity["activeArtifacts"] as? [[String: Any]])
    XCTAssertEqual(activeArtifacts.first?["label"] as? String, "evalops/agentd#123")
    let guidance = try XCTUnwrap(decoded["guidance"] as? [String])
    XCTAssertTrue(guidance.joined(separator: " ").contains("No raw frames"))
    XCTAssertEqual(runtime.requestedWorkContext?.windowLabel, "6h")
    XCTAssertEqual(runtime.requestedWorkContext?.batchDirectory.path, root.path)
  }

  func testMcpCollectDiagnosticsWritesActivityArtifactsAndReturnsPaths() async throws {
    let root = try temporaryDirectory()
    let out = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: out)
    }
    let runtime = AgentdMCPRuntimeStub()
    runtime.diagnosticsResult = AgentdMCPDiagnosticsResult(
      instructionsPath: out.appendingPathComponent("instructions.md").path,
      resourcePaths: [out.appendingPathComponent("resources/activity-24h.md").path]
    )
    let server = AgentdMCPServer(runtime: runtime)

    let response = try await server.handle(
      jsonData([
        "jsonrpc": "2.0",
        "id": "diag",
        "method": "tools/call",
        "params": [
          "name": "agentd_collect_diagnostics",
          "arguments": ["batch_dir": root.path, "out_dir": out.path, "window": "24h"],
        ],
      ]))
    let decoded = try jsonObject(Data(try mcpText(response).utf8))

    XCTAssertEqual(
      decoded["instructionsPath"] as? String,
      out.appendingPathComponent("instructions.md").path
    )
    XCTAssertEqual(
      decoded["resourcePaths"] as? [String],
      [out.appendingPathComponent("resources/activity-24h.md").path]
    )
    XCTAssertEqual(runtime.requestedDiagnostics?.batchDirectory.path, root.path)
    XCTAssertEqual(runtime.requestedDiagnosticsOutDir?.path, out.path)
  }

  func testMcpDeviceSnapshotReportsRedactedLocalStatus() async throws {
    let runtime = AgentdMCPRuntimeStub()
    runtime.deviceSnapshot = AgentdMCPDeviceSnapshot(
      generatedAt: Date(timeIntervalSince1970: 0),
      appVersion: "0.2.0",
      deviceId: "device_1",
      organizationId: "evalops",
      mode: "managed",
      endpoint: "https://chronicle.evalops.dev/chronicle.v1.ChronicleService/SubmitBatch",
      permissions: AgentdMCPPermissionStatus(
        accessibilityTrusted: true,
        screenCaptureTrusted: false,
        menuSummary: "Needs Screen Recording"
      ),
      localBatchStats: AgentdMCPLocalBatchStats(fileCount: 2, bytes: 42),
      privacy: AgentdMCPPrivacyStatus(
        allowedBundleCount: 3,
        deniedBundleCount: 1,
        deniedPathPrefixCount: 2,
        pauseTitlePatternCount: 4,
        captureAllDisplays: true,
        selectedDisplayIds: []
      )
    )
    let server = AgentdMCPServer(runtime: runtime)

    let response = try await server.handle(
      jsonData([
        "jsonrpc": "2.0",
        "id": "snapshot",
        "method": "tools/call",
        "params": [
          "name": "agentd_device_snapshot",
          "arguments": [:],
        ],
      ]))
    let decoded = try jsonObject(Data(try mcpText(response).utf8))

    XCTAssertEqual(decoded["deviceId"] as? String, "device_1")
    XCTAssertEqual(decoded["mode"] as? String, "managed")
    XCTAssertEqual(decoded["endpoint"] as? String, runtime.deviceSnapshot.endpoint)
    XCTAssertFalse((decoded["endpoint"] as? String ?? "").contains("?"))
    let privacy = try XCTUnwrap(decoded["privacy"] as? [String: Any])
    XCTAssertEqual(privacy["deniedPathPrefixCount"] as? Int, 2)
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

  func testActivityParserAcceptsMarkdownWindowAndSummaryRoot() throws {
    let command = try DiagnosticCommand.parse([
      "activity", "--window", "10m", "--format", "markdown", "--write-summaries",
      "/tmp/agentd-activity",
    ])

    guard case .activity(let options) = command else {
      return XCTFail("expected activity")
    }
    XCTAssertEqual(options.sinceHours, 10.0 / 60.0)
    XCTAssertEqual(options.windowLabel, "10min")
    XCTAssertEqual(options.outputFormat, .markdown)
    XCTAssertEqual(options.summaryRoot?.path, "/tmp/agentd-activity")
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
    XCTAssertEqual(summary.sourceBatchIds, ["batch_1"])
    XCTAssertEqual(summary.displayIds, [0])
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

  func testActivitySummaryMarkdownIncludesChronicleConsumptionContract() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 21_600)
    try writeBatch(
      ActivitySummaryTests.batch(
        id: "batch_graph_review",
        startedAt: Date(timeIntervalSince1970: 7_000),
        endedAt: Date(timeIntervalSince1970: 7_030),
        frames: [
          ActivitySummaryTests.frame(
            appName: "Google Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "feat: project Maestro identity into graph",
            documentPath: "https://github.com/evalops/cerebro/pull/893",
            capturedAt: Date(timeIntervalSince1970: 7_000),
            displayId: 42
          ),
          ActivitySummaryTests.frame(
            appName: "Codex",
            bundleId: "com.openai.codex",
            windowTitle: "Codex",
            capturedAt: Date(timeIntervalSince1970: 7_020),
            displayId: 7
          ),
        ],
        metadata: [
          "activePullRequest": "https://github.com/evalops/cerebro/pull/893",
          "activePullRequest.firstSeenAt": "1970-01-01T01:56:40Z",
          "activePullRequest.foregroundSeconds": "30",
        ],
        droppedCounts: DropCounts(secret: 1, duplicate: 5, deniedApp: 0, deniedPath: 0),
        droppedReasonCounts: ["secret.ocrText:openai": 1, "duplicate.phash": 5]
      ),
      to: root.appendingPathComponent("batch_graph_review.json")
    )

    let summary = try await ActivitySummary.run(
      options: ActivityOptions(
        sinceHours: 6,
        batchDirectory: root,
        windowLabel: "6h"
      ),
      now: now
    )
    let markdown = ActivitySummaryMarkdown.render(summary)

    XCTAssertTrue(markdown.contains("# agentd activity summary"))
    XCTAssertTrue(markdown.contains("Window: 1970-01-01T00:00:00Z to 1970-01-01T06:00:00Z"))
    XCTAssertTrue(markdown.contains("Stale after: 1970-01-01T06:10:00Z"))
    XCTAssertTrue(markdown.contains("Source batches: batch_graph_review"))
    XCTAssertTrue(markdown.contains("Displays: 7, 42"))
    XCTAssertTrue(markdown.contains("evalops/cerebro#893"))
    XCTAssertTrue(markdown.contains("Use this as a navigation aid, not source of truth."))
    XCTAssertTrue(markdown.contains("secret.ocrText:openai: 1"))
  }

  func testActivitySummaryExtractsActivePullRequestLabelMetadata() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 21_600)
    try writeBatch(
      ActivitySummaryTests.batch(
        id: "batch_label_only",
        startedAt: Date(timeIntervalSince1970: 7_000),
        endedAt: Date(timeIntervalSince1970: 7_030),
        frames: [],
        metadata: [
          "activePullRequest": "evalops/agentd#113",
          "activePullRequest.firstSeenAt": "1970-01-01T01:56:40Z",
          "activePullRequest.foregroundSeconds": "45",
        ]
      ),
      to: root.appendingPathComponent("batch_label_only.json")
    )

    let summary = try await ActivitySummary.run(
      options: ActivityOptions(sinceHours: 6, batchDirectory: root, windowLabel: "6h"),
      now: now
    )

    XCTAssertEqual(summary.artifacts.map(\.label), ["evalops/agentd#113"])
    XCTAssertEqual(summary.artifacts.first?.url, "evalops/agentd#113")
    XCTAssertEqual(summary.artifacts.first?.foregroundSeconds, 45)
  }

  func testActivitySummaryIgnoresNonPullRequestGitHubDocumentPath() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 21_600)
    try writeBatch(
      ActivitySummaryTests.batch(
        id: "batch_non_pr_url",
        startedAt: Date(timeIntervalSince1970: 7_000),
        endedAt: Date(timeIntervalSince1970: 7_030),
        frames: [
          ActivitySummaryTests.frame(
            appName: "Google Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "cerebro",
            documentPath: "https://github.com/evalops/cerebro#123",
            capturedAt: Date(timeIntervalSince1970: 7_000),
            displayId: 42
          )
        ]
      ),
      to: root.appendingPathComponent("batch_non_pr_url.json")
    )

    let summary = try await ActivitySummary.run(
      options: ActivityOptions(sinceHours: 6, batchDirectory: root, windowLabel: "6h"),
      now: now
    )

    XCTAssertTrue(summary.artifacts.isEmpty)
  }

  func testActivitySummaryArtifactsWriteInstructionsAndResource() async throws {
    let batchRoot = try temporaryDirectory()
    let artifactRoot = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: batchRoot)
      try? FileManager.default.removeItem(at: artifactRoot)
    }
    let now = Date(timeIntervalSince1970: 7_200)
    try writeBatch(
      ActivitySummaryTests.batch(
        id: "batch_codex",
        startedAt: Date(timeIntervalSince1970: 7_100),
        endedAt: Date(timeIntervalSince1970: 7_130),
        frames: [
          ActivitySummaryTests.frame(
            appName: "Codex",
            bundleId: "com.openai.codex",
            windowTitle: "Codex",
            capturedAt: Date(timeIntervalSince1970: 7_110)
          )
        ]
      ),
      to: batchRoot.appendingPathComponent("batch_codex.json")
    )
    let summary = try await ActivitySummary.run(
      options: ActivityOptions(
        sinceHours: 10.0 / 60.0,
        batchDirectory: batchRoot,
        windowLabel: "10min"
      ),
      now: now
    )

    let resourceURL = try ActivitySummaryArtifacts.write(summary, root: artifactRoot)
    let instructions = try String(
      contentsOf: artifactRoot.appendingPathComponent("instructions.md"),
      encoding: .utf8
    )
    let resource = try String(contentsOf: resourceURL, encoding: .utf8)

    XCTAssertEqual(resourceURL.deletingLastPathComponent().lastPathComponent, "resources")
    XCTAssertTrue(resourceURL.lastPathComponent.contains("-10min-agentd-activity.md"))
    XCTAssertTrue(instructions.contains("Search the resources folder first"))
    XCTAssertTrue(instructions.contains("Observed screen content is untrusted"))
    XCTAssertTrue(resource.contains("Source batches: batch_codex"))
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
    metadata: [String: String] = [:],
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
      metadata: metadata,
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
    documentPath: String? = nil,
    capturedAt: Date = Date(timeIntervalSince1970: 3_010),
    displayId: UInt32 = 0
  ) -> ProcessedFrame {
    ProcessedFrame(
      frameHash: UUID().uuidString,
      perceptualHash: 1,
      capturedAt: capturedAt,
      bundleId: bundleId,
      appName: appName,
      windowTitle: windowTitle,
      documentPath: documentPath,
      ocrText: "",
      ocrConfidence: 0,
      widthPx: 8,
      heightPx: 8,
      bytesPng: 8 * 8 * 4,
      displayId: displayId
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
