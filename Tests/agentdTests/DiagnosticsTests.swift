// SPDX-License-Identifier: BUSL-1.1

import Foundation
import XCTest

@testable import agentd

final class DiagnosticsTests: XCTestCase {
  func testDiagnosticsReportRedactsSecretsAndPathsButKeepsQueueSummary() {
    let cfg = AgentConfig(
      deviceId: "device_1",
      organizationId: "org_1",
      endpoint: URL(
        string:
          "https://chronicle.example.com/chronicle.v1.ChronicleService/SubmitBatch?token=secret"
      )!,
      allowedBundleIds: ["com.test.App"],
      deniedBundleIds: AgentConfig.defaultDeniedBundleIds,
      deniedPathPrefixes: ["\(NSHomeDirectory())/.ssh", ".aws"],
      pauseWindowTitlePatterns: ["prod \(SecretScrubberTests.jwtFixture())"],
      captureFps: 1,
      idleFps: 0.2,
      batchIntervalSeconds: 30,
      maxFramesPerBatch: 24,
      localOnly: false,
      encryptLocalBatches: true,
      auth: .bearer(keychainService: "svc", keychainAccount: "acct")
    )
    let snapshot = DiagnosticsSnapshot(
      generatedAt: Date(timeIntervalSince1970: 1),
      appVersion: "1.0.0",
      captureState: "paused by schedule: interview",
      permissions: PermissionSnapshot(accessibilityTrusted: true, screenCaptureTrusted: false),
      config: cfg,
      policyVersion: "policy_1",
      policySource: "chronicle://policy/\(SecretScrubberTests.jwtFixture())",
      controlError: "none",
      pendingStats: PendingFrameStats(frameCount: 2, estimatedBytes: 4096),
      localBatchStats: LocalBatchStats(fileCount: 1, bytes: 1234),
      localBatches: [
        LocalBatchSummary(
          batchId: "batch_1",
          fileName: "batch_1.agentdbatch",
          modified: Date(timeIntervalSince1970: 2),
          bytes: 1234,
          encrypted: true
        )
      ],
      lastSubmitResult: "persisted local fallback batch batch_1"
    )

    let report = DiagnosticsReport.markdown(snapshot)

    XCTAssertTrue(report.contains("Queued local batches: 1"))
    XCTAssertTrue(report.contains("| batch_1 |"))
    XCTAssertTrue(
      report.contains("https://chronicle.example.com/chronicle.v1.ChronicleService/SubmitBatch"))
    XCTAssertFalse(report.contains("token=secret"))
    XCTAssertFalse(report.contains(SecretScrubberTests.jwtFixture()))
    XCTAssertTrue(report.contains("[redacted]"))
    XCTAssertTrue(report.contains("~/.ssh"))
  }
}
