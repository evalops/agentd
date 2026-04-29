// SPDX-License-Identifier: BUSL-1.1

import Foundation
import XCTest

@testable import agentd

final class ChronicleControlTests: XCTestCase {
  func testEndpointDerivesControlMethodsFromSubmitBatchURL() {
    let endpoint = URL(
      string: "https://chronicle.example.com/chronicle.v1.ChronicleService/SubmitBatch")!

    XCTAssertEqual(
      ChronicleEndpoint.methodURL(fromSubmitBatchEndpoint: endpoint, method: "Heartbeat")
        .absoluteString,
      "https://chronicle.example.com/chronicle.v1.ChronicleService/Heartbeat"
    )
  }

  func testHeartbeatEncodesProtoJSONInt64AsString() throws {
    let request = HeartbeatRequest(
      deviceId: "device_1",
      organizationId: "org_1",
      pendingFrameCount: 2,
      pendingBytes: 123_456
    )

    let data = try encodeChronicleControlRequest(request)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(root["deviceId"] as? String, "device_1")
    XCTAssertEqual(root["organizationId"] as? String, "org_1")
    XCTAssertEqual(root["pendingFrameCount"] as? Int, 2)
    XCTAssertEqual(root["pendingBytes"] as? String, "123456")
    XCTAssertEqual(root["paused"] as? Bool, false)
  }

  func testControlClientRegistersAndHeartbeatsWithBearerAuth() async throws {
    let recorder = ChronicleRequestRecorder()
    let client = StubHTTPClient { request in
      await recorder.record(request)
      let url = try XCTUnwrap(request.url)
      let body = try XCTUnwrap(request.httpBody)
      let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer chronicle-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")

      if url.path.hasSuffix("/RegisterDevice") {
        XCTAssertEqual(root["deviceId"] as? String, "device_1")
        XCTAssertEqual(root["organizationId"] as? String, "org_1")
        let metadata = try XCTUnwrap(root["metadata"] as? [String: String])
        XCTAssertEqual(metadata["capture_state"], "stopped")
        return (
          Data(
            #"{"device":{"deviceId":"device_1","organizationId":"org_1","paused":false},"policy":{"policyVersion":"p1","captureMode":"CAPTURE_MODE_HYBRID","allowedBundleIds":["com.test.App"],"maxFramesPerBatch":4}}"#
              .utf8),
          Self.response(for: url, statusCode: 200)
        )
      }

      XCTAssertTrue(url.path.hasSuffix("/Heartbeat"))
      XCTAssertEqual(root["pendingFrameCount"] as? Int, 3)
      XCTAssertEqual(root["pendingBytes"] as? String, "4096")
      XCTAssertEqual(root["paused"] as? Bool, true)
      XCTAssertEqual(root["pauseReason"] as? String, "scheduled:meeting")
      return (
        Data(
          #"{"device":{"deviceId":"device_1","organizationId":"org_1","paused":true,"pauseReason":"policy"},"policy":{"policyVersion":"p2","captureMode":"CAPTURE_MODE_PAUSED","scheduledPauseWindows":[{"id":"meeting_1","reason":"meeting","startsAt":"2026-04-28T16:00:00Z","endsAt":"2026-04-28T17:00:00Z"}]}}"#
            .utf8),
        Self.response(for: url, statusCode: 200)
      )
    }

    let control = try ChronicleControlClient(
      submitBatchEndpoint: URL(
        string: "https://chronicle.example.com/chronicle.v1.ChronicleService/SubmitBatch")!,
      authMode: .bearer(keychainService: "agentd", keychainAccount: "chronicle"),
      credentialProvider: StubCredentialProvider(tokens: ["agentd:chronicle": "chronicle-token"]),
      client: client
    )

    let register = try await control.register(
      RegisterDeviceRequest(
        deviceId: "device_1",
        organizationId: "org_1",
        workspaceId: nil,
        userId: nil,
        hostname: "host",
        appVersion: "1.0.0",
        metadata: ["capture_state": "stopped"]
      ))
    let heartbeat = try await control.heartbeat(
      HeartbeatRequest(
        deviceId: "device_1",
        organizationId: "org_1",
        pendingFrameCount: 3,
        pendingBytes: 4096,
        paused: true,
        pauseReason: "scheduled:meeting"
      ))

    XCTAssertEqual(register.policy?.policyVersion, "p1")
    XCTAssertEqual(register.policy?.maxFramesPerBatch, 4)
    XCTAssertEqual(heartbeat.device?.paused, true)
    XCTAssertEqual(heartbeat.policy?.captureMode, .paused)
    XCTAssertEqual(heartbeat.policy?.scheduledPauseWindows.first?.id, "meeting_1")
    let requestCount = await recorder.count()
    XCTAssertEqual(requestCount, 2)
  }

  func testCapturePolicyOverlayPreservesLocalHardDenies() {
    var cfg = PipelineTests.config(maxFramesPerBatch: 24)
    cfg.deniedBundleIds = ["com.local.Secret"]
    cfg.deniedPathPrefixes = [".ssh"]
    cfg.pauseWindowTitlePatterns = ["1Password"]
    cfg.batchIntervalSeconds = 30

    let policy = CapturePolicy(
      policyVersion: "policy_1",
      captureMode: .hybrid,
      allowedBundleIds: ["com.remote.Allowed"],
      deniedBundleIds: ["com.remote.Secret"],
      deniedPathPrefixes: [".aws"],
      pauseWindowTitlePatterns: ["Zoom Meeting"],
      minBatchIntervalSeconds: 60,
      maxFramesPerBatch: 8,
      sourcePolicyRef: "chronicle.default"
    )

    let next = cfg.applying(policy: policy)

    XCTAssertEqual(next.allowedBundleIds, ["com.remote.Allowed"])
    XCTAssertTrue(next.deniedBundleIds.contains("com.agilebits.onepassword7"))
    XCTAssertTrue(next.deniedBundleIds.contains("com.local.Secret"))
    XCTAssertTrue(next.deniedBundleIds.contains("com.remote.Secret"))
    XCTAssertTrue(next.deniedPathPrefixes.contains(".ssh"))
    XCTAssertTrue(next.deniedPathPrefixes.contains(".aws"))
    XCTAssertTrue(next.pauseWindowTitlePatterns.contains("1Password"))
    XCTAssertTrue(next.pauseWindowTitlePatterns.contains("Zoom Meeting"))
    XCTAssertEqual(next.batchIntervalSeconds, 60)
    XCTAssertEqual(next.maxFramesPerBatch, 8)
  }

  func testPolicyReapplyFromLocalBaselineAllowsServerPolicyToShrink() {
    var base = PipelineTests.config(maxFramesPerBatch: 24)
    base.deniedBundleIds = ["com.local.Secret"]
    base.batchIntervalSeconds = 30

    let first = base.applying(
      policy: CapturePolicy(
        policyVersion: "policy_1",
        deniedBundleIds: ["com.remote.Secret"],
        minBatchIntervalSeconds: 120
      ))
    let second = base.applying(
      policy: CapturePolicy(
        policyVersion: "policy_2",
        deniedBundleIds: ["com.remote.NewSecret"],
        minBatchIntervalSeconds: 45
      ))

    XCTAssertTrue(first.deniedBundleIds.contains("com.local.Secret"))
    XCTAssertTrue(first.deniedBundleIds.contains("com.remote.Secret"))
    XCTAssertEqual(first.batchIntervalSeconds, 120)

    XCTAssertTrue(second.deniedBundleIds.contains("com.local.Secret"))
    XCTAssertFalse(second.deniedBundleIds.contains("com.remote.Secret"))
    XCTAssertTrue(second.deniedBundleIds.contains("com.remote.NewSecret"))
    XCTAssertEqual(second.batchIntervalSeconds, 45)
  }

  func testCapturePolicyCanSelectDisplayScope() throws {
    let data = """
      {
        "policyVersion": "policy_display",
        "captureAllDisplays": true,
        "selectedDisplayIds": [123, 456]
      }
      """.data(using: .utf8)!

    let policy = try JSONDecoder().decode(CapturePolicy.self, from: data)
    var cfg = PipelineTests.config()
    cfg.captureAllDisplays = false
    cfg.selectedDisplayIds = []

    let next = cfg.applying(policy: policy)

    XCTAssertEqual(policy.selectedDisplayIds, [123, 456])
    XCTAssertEqual(next.captureAllDisplays, true)
    XCTAssertEqual(next.selectedDisplayIds, [123, 456])
  }

  func testControlStateReportsDevicePauseChangesWithoutPolicy() {
    var state = ChronicleControlState()

    XCTAssertTrue(
      state.apply(
        device: ChronicleDevice(
          deviceId: "device_1",
          organizationId: "org_1",
          paused: true,
          pauseReason: "policy"
        )))
    XCTAssertEqual(state.serverPaused, true)
    XCTAssertEqual(state.serverPauseReason, "policy")

    XCTAssertFalse(
      state.apply(
        device: ChronicleDevice(
          deviceId: "device_1",
          organizationId: "org_1",
          paused: true,
          pauseReason: "policy"
        )))

    XCTAssertTrue(
      state.apply(
        device: ChronicleDevice(
          deviceId: "device_1",
          organizationId: "org_1",
          paused: false,
          pauseReason: nil
        )))
    XCTAssertEqual(state.serverPaused, false)
    XCTAssertNil(state.serverPauseReason)
  }

  fileprivate static func response(for url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
  }
}

actor ChronicleRequestRecorder {
  private var requests: [URLRequest] = []

  func record(_ request: URLRequest) {
    requests.append(request)
  }

  func count() -> Int {
    requests.count
  }
}
