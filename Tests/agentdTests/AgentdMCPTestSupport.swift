// SPDX-License-Identifier: BUSL-1.1

import Foundation
import XCTest

@testable import agentd

final class AgentdMCPRuntimeStub: AgentdMCPRuntime {
  var deviceSnapshot = AgentdMCPDeviceSnapshot(
    generatedAt: Date(timeIntervalSince1970: 0),
    appVersion: "test",
    deviceId: "device_test",
    organizationId: "org_test",
    mode: "local-only",
    endpoint: "http://127.0.0.1:8787/chronicle.v1.ChronicleService/SubmitBatch",
    permissions: AgentdMCPPermissionStatus(
      accessibilityTrusted: true,
      screenCaptureTrusted: true,
      menuSummary: "Ready"
    ),
    localBatchStats: AgentdMCPLocalBatchStats(fileCount: 0, bytes: 0),
    privacy: AgentdMCPPrivacyStatus(
      allowedBundleCount: 0,
      deniedBundleCount: 0,
      deniedPathPrefixCount: 0,
      pauseTitlePatternCount: 0,
      captureAllDisplays: true,
      selectedDisplayIds: []
    )
  )
  var activitySummary = ActivitySummaryTests.summary(batchDirectory: URL(fileURLWithPath: "/tmp"))
  var diagnosticsResult = AgentdMCPDiagnosticsResult(
    instructionsPath: "/tmp/instructions.md",
    resourcePaths: ["/tmp/resources/activity.md"]
  )
  private(set) var requestedActivity: ActivityOptions?
  private(set) var requestedWorkContext: ActivityOptions?
  private(set) var requestedDiagnostics: ActivityOptions?
  private(set) var requestedDiagnosticsOutDir: URL?

  func deviceSnapshot() async throws -> AgentdMCPDeviceSnapshot {
    deviceSnapshot
  }

  func activityRecent(options: ActivityOptions) async throws -> ActivitySummary {
    requestedActivity = options
    return activitySummary.replacing(
      batchDirectory: options.batchDirectory.path,
      windowLabel: options.windowLabel
    )
  }

  func workContext(options: ActivityOptions) async throws -> AgentdMCPWorkContext {
    requestedWorkContext = options
    return AgentdMCPWorkContext.make(
      device: deviceSnapshot,
      activity: activitySummary.replacing(
        batchDirectory: options.batchDirectory.path,
        windowLabel: options.windowLabel
      ),
      now: Date(timeIntervalSince1970: 1_200)
    )
  }

  func collectDiagnostics(options: ActivityOptions, outputDirectory: URL) async throws
    -> AgentdMCPDiagnosticsResult
  {
    requestedDiagnostics = options
    requestedDiagnosticsOutDir = outputDirectory
    return diagnosticsResult
  }
}

func jsonData(_ object: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

func jsonObject(_ data: Data) throws -> [String: Any] {
  let decoded = try JSONSerialization.jsonObject(with: data)
  return try XCTUnwrap(decoded as? [String: Any])
}

func mcpText(_ data: Data) throws -> String {
  let root = try jsonObject(data)
  let result = try XCTUnwrap(root["result"] as? [String: Any])
  let content = try XCTUnwrap(result["content"] as? [[String: Any]])
  return try XCTUnwrap(content.first?["text"] as? String)
}

extension ActivitySummaryTests {
  static func summary(
    batchDirectory: URL,
    windowLabel: String = "24h",
    windows: [ActivityWindowSummary] = []
  ) -> ActivitySummary {
    ActivitySummary(
      generatedAt: Date(timeIntervalSince1970: 1_000),
      since: Date(timeIntervalSince1970: 0),
      until: Date(timeIntervalSince1970: 1_000),
      staleAfter: Date(timeIntervalSince1970: 1_600),
      windowLabel: windowLabel,
      batchDirectory: batchDirectory.path,
      batchCount: 0,
      nonemptyBatchCount: 0,
      frameCount: 0,
      sourceBatchIds: [],
      displayIds: [],
      droppedCounts: DropCounts(secret: 0, duplicate: 0, deniedApp: 0, deniedPath: 0),
      droppedReasonCounts: [:],
      apps: [],
      windows: windows,
      artifacts: []
    )
  }
}

extension ActivitySummary {
  func replacing(batchDirectory: String, windowLabel: String) -> ActivitySummary {
    ActivitySummary(
      generatedAt: generatedAt,
      since: since,
      until: until,
      staleAfter: staleAfter,
      windowLabel: windowLabel,
      batchDirectory: batchDirectory,
      batchCount: batchCount,
      nonemptyBatchCount: nonemptyBatchCount,
      frameCount: frameCount,
      sourceBatchIds: sourceBatchIds,
      displayIds: displayIds,
      droppedCounts: droppedCounts,
      droppedReasonCounts: droppedReasonCounts,
      apps: apps,
      windows: windows,
      artifacts: artifacts
    )
  }
}
