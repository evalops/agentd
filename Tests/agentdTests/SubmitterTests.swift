// SPDX-License-Identifier: BUSL-1.1

import Foundation
import XCTest

@testable import agentd

final class SubmitterTests: XCTestCase {
  func testSubmitBatchEncodingMatchesChronicleProtoJSONShape() throws {
    let batch = Batch(
      batchId: "batch_fixture",
      deviceId: "device_1",
      organizationId: "org_1",
      workspaceId: "workspace_1",
      userId: "user_1",
      projectId: "project_1",
      repository: "evalops/platform",
      startedAt: Date(timeIntervalSince1970: 1),
      endedAt: Date(timeIntervalSince1970: 2),
      frames: [
        ProcessedFrame(
          frameHash: String(repeating: "a", count: 64),
          perceptualHash: 42,
          capturedAt: Date(timeIntervalSince1970: 1),
          bundleId: "com.microsoft.VSCode",
          appName: "Code",
          windowTitle: "chronicle.proto",
          documentPath: "/Users/alice/src/platform/proto/chronicle/v1/chronicle.proto",
          ocrText: "ChronicleService SubmitBatch",
          ocrConfidence: 0.93,
          widthPx: 1512,
          heightPx: 982,
          bytesPng: 120_000
        )
      ],
      droppedCounts: DropCounts(secret: 0, duplicate: 1, deniedApp: 0, deniedPath: 0)
    )

    let data = try encodeSubmitBatchRequest(batch, localOnly: true)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(root["localOnly"] as? Bool, true)
    let encodedBatch = try XCTUnwrap(root["batch"] as? [String: Any])
    XCTAssertEqual(encodedBatch["batchId"] as? String, "batch_fixture")
    XCTAssertEqual(encodedBatch["organizationId"] as? String, "org_1")
    XCTAssertEqual(encodedBatch["projectId"] as? String, "project_1")
    XCTAssertNil(encodedBatch["orgId"])

    let frames = try XCTUnwrap(encodedBatch["frames"] as? [[String: Any]])
    XCTAssertEqual(frames.first?["perceptualHash"] as? String, "42")
    XCTAssertEqual(frames.first?["bytesPng"] as? String, "120000")
    XCTAssertEqual(frames.first?["ocrTextTruncated"] as? Bool, false)
    XCTAssertEqual(frames.first?["bundleId"] as? String, "com.microsoft.VSCode")
    XCTAssertEqual(frames.first?["frameHash"] as? String, String(repeating: "a", count: 64))

    let droppedCounts = try XCTUnwrap(encodedBatch["droppedCounts"] as? [String: Any])
    XCTAssertEqual(droppedCounts["duplicate"] as? Int, 1)
  }

  func testAgentConfigDecodesLegacyOrgIdAndEncodesOrganizationId() throws {
    let legacy = """
      {
        "deviceId": "device_1",
        "orgId": "org_legacy",
        "endpoint": "http://127.0.0.1:8787/chronicle.v1.ChronicleService/SubmitBatch",
        "localOnly": true
      }
      """.data(using: .utf8)!

    let cfg = try JSONDecoder().decode(AgentConfig.self, from: legacy)
    XCTAssertEqual(cfg.organizationId, "org_legacy")
    XCTAssertEqual(cfg.allowedBundleIds, AgentConfig.defaultAllowedBundleIds)
    XCTAssertEqual(cfg.maxOcrTextChars, 4096)
    XCTAssertEqual(cfg.maxBatchBytes, 512 * 1024 * 1024)

    let encoded = try JSONEncoder().encode(cfg)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(root["organizationId"] as? String, "org_legacy")
    XCTAssertNil(root["orgId"])
  }

  func testAgentConfigPrefersOrganizationIdOverLegacyOrgId() throws {
    let data = """
      {
        "deviceId": "device_1",
        "organizationId": "org_new",
        "orgId": "org_legacy",
        "endpoint": "http://127.0.0.1:8787/chronicle.v1.ChronicleService/SubmitBatch",
        "localOnly": true
      }
      """.data(using: .utf8)!

    let cfg = try JSONDecoder().decode(AgentConfig.self, from: data)
    XCTAssertEqual(cfg.organizationId, "org_new")
  }

  func testEndpointPolicyRejectsPlainHttpRemoteAndAllowsHttpsAndLoopback() throws {
    let provider = StubCredentialProvider(token: "token")
    XCTAssertNoThrow(
      try Submitter(
        endpoint: URL(string: "https://chronicle.example.com/submit")!,
        localOnly: false,
        authMode: .bearer(keychainService: "svc", keychainAccount: "acct"),
        credentialProvider: provider,
        client: StubHTTPClient.success()
      ))
    XCTAssertNoThrow(
      try Submitter(
        endpoint: URL(string: "http://127.0.0.1:8787/submit")!,
        localOnly: false,
        authMode: .bearer(keychainService: "svc", keychainAccount: "acct"),
        credentialProvider: provider,
        client: StubHTTPClient.success()
      ))
    XCTAssertThrowsError(
      try Submitter(
        endpoint: URL(string: "http://chronicle.example.com/submit")!,
        localOnly: false,
        authMode: .bearer(keychainService: "svc", keychainAccount: "acct"),
        credentialProvider: provider,
        client: StubHTTPClient.success()
      )
    ) { error in
      XCTAssertEqual(
        error as? SubmitterInitError, .insecureRemoteEndpoint("http://chronicle.example.com/submit")
      )
    }
  }

  func testRemoteSubmitterRequiresAuth() {
    XCTAssertThrowsError(
      try Submitter(
        endpoint: URL(string: "https://chronicle.example.com/submit")!,
        localOnly: false,
        authMode: .none,
        credentialProvider: StubCredentialProvider(token: ""),
        client: StubHTTPClient.success()
      )
    ) { error in
      XCTAssertEqual(error as? SubmitterInitError, .missingRemoteAuth)
    }
  }

  func testBearerModeAddsAuthorizationHeader() async throws {
    let submitter = try Submitter(
      endpoint: URL(string: "https://chronicle.example.com/submit")!,
      localOnly: false,
      authMode: .bearer(keychainService: "svc", keychainAccount: "acct"),
      credentialProvider: StubCredentialProvider(token: "secret-token"),
      client: StubHTTPClient.success()
    )

    let request = await submitter.makeRequest(body: Data("{}".utf8))
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
  }

  func testSubmitterPersistsLocalOnServerAndTransportFailures() async throws {
    let cases: [(String, StubHTTPClient)] = [
      ("client_error", .status(400, body: #"{"batchId":"nope"}"#)),
      ("server_error", .status(500, body: #"{"batchId":"nope"}"#)),
      ("malformed_body", .status(200, body: #"{"#)),
      ("timeout", .failure(URLError(.timedOut))),
    ]

    for (id, client) in cases {
      let dir = try makeTemporaryDirectory()
      let submitter = try Submitter(
        endpoint: URL(string: "https://chronicle.example.com/submit")!,
        localOnly: false,
        authMode: .bearer(keychainService: "svc", keychainAccount: "acct"),
        credentialProvider: StubCredentialProvider(token: "token"),
        client: client,
        batchDirectory: dir
      )

      let result = await submitter.submit(Self.batch(id: id))
      XCTAssertEqual(result, .persistedLocal, id)
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).json").path), id)
    }
  }

  func testLocalBatchSweepRemovesOldFiles() async throws {
    let dir = try makeTemporaryDirectory()
    try writeBatchFile(
      dir.appendingPathComponent("old.json"), bytes: 10,
      modified: Date(timeIntervalSinceNow: -8 * 24 * 60 * 60))
    try writeBatchFile(dir.appendingPathComponent("new.json"), bytes: 10, modified: Date())
    let submitter = try Submitter(
      endpoint: URL(string: "http://127.0.0.1:8787/submit")!,
      localOnly: true,
      batchDirectory: dir,
      maxBatchAgeDays: 7
    )

    await submitter.sweepLocalBatches()
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: dir.appendingPathComponent("old.json").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.json").path))
  }

  func testLocalBatchSweepRemovesOldestFilesOverByteBudget() async throws {
    let dir = try makeTemporaryDirectory()
    try writeBatchFile(
      dir.appendingPathComponent("oldest.json"), bytes: 80, modified: Date(timeIntervalSince1970: 1)
    )
    try writeBatchFile(
      dir.appendingPathComponent("middle.json"), bytes: 80, modified: Date(timeIntervalSince1970: 2)
    )
    try writeBatchFile(
      dir.appendingPathComponent("newest.json"), bytes: 80, modified: Date(timeIntervalSince1970: 3)
    )
    let submitter = try Submitter(
      endpoint: URL(string: "http://127.0.0.1:8787/submit")!,
      localOnly: true,
      batchDirectory: dir,
      maxBatchBytes: 120,
      maxBatchAgeDays: 365 * 100
    )

    await submitter.sweepLocalBatches()
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: dir.appendingPathComponent("oldest.json").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: dir.appendingPathComponent("middle.json").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: dir.appendingPathComponent("newest.json").path))
  }

  static func batch(id: String = "batch_fixture") -> Batch {
    Batch(
      batchId: id,
      deviceId: "device_1",
      organizationId: "org_1",
      workspaceId: nil,
      userId: nil,
      projectId: nil,
      repository: nil,
      startedAt: Date(timeIntervalSince1970: 1),
      endedAt: Date(timeIntervalSince1970: 2),
      frames: [
        ProcessedFrame(
          frameHash: String(repeating: "a", count: 64),
          perceptualHash: 42,
          capturedAt: Date(timeIntervalSince1970: 1),
          bundleId: "com.microsoft.VSCode",
          appName: "Code",
          windowTitle: "chronicle.proto",
          documentPath: nil,
          ocrText: "ChronicleService SubmitBatch",
          ocrConfidence: 0.93,
          widthPx: 10,
          heightPx: 10,
          bytesPng: 400
        )
      ],
      droppedCounts: DropCounts(secret: 0, duplicate: 0, deniedApp: 0, deniedPath: 0)
    )
  }

  private func makeTemporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("agentd-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func writeBatchFile(_ url: URL, bytes: Int, modified: Date) throws {
    try Data(repeating: 0x41, count: bytes).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
  }
}

struct StubCredentialProvider: SubmitterCredentialProviding {
  let token: String

  func bearerToken(service: String, account: String) throws -> String {
    token
  }

  func clientIdentity(label: String) throws -> ClientIdentity {
    throw SubmitterInitError.missingClientIdentity(label: label)
  }
}

struct StubHTTPClient: HTTPClient {
  let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await handler(request)
  }

  static func success() -> StubHTTPClient {
    status(200, body: #"{"batchId":"ok"}"#)
  }

  static func status(_ statusCode: Int, body: String) -> StubHTTPClient {
    StubHTTPClient { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: nil
      )!
      return (Data(body.utf8), response)
    }
  }

  static func failure(_ error: Error) -> StubHTTPClient {
    StubHTTPClient { _ in throw error }
  }
}
