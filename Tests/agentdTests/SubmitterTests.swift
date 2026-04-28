// SPDX-License-Identifier: BUSL-1.1

@preconcurrency import CryptoKit
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
      metadata: [
        "evalops_context_version": "evalops.context.v1",
        "maestro_session_id": "session_1",
        "agent_run_id": "run_1",
        "traceparent": "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01",
      ],
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
    XCTAssertNotNil(encodedBatch["captureWindow"])
    let metadata = try XCTUnwrap(encodedBatch["metadata"] as? [String: String])
    XCTAssertEqual(metadata["evalops_context_version"], "evalops.context.v1")
    XCTAssertEqual(metadata["maestro_session_id"], "session_1")
    XCTAssertEqual(metadata["agent_run_id"], "run_1")
    XCTAssertEqual(
      metadata["traceparent"], "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01")

    let frames = try XCTUnwrap(encodedBatch["frames"] as? [[String: Any]])
    XCTAssertEqual(frames.first?["perceptualHash"] as? String, "42")
    XCTAssertEqual(frames.first?["bytesPng"] as? String, "120000")
    XCTAssertEqual(frames.first?["displayId"] as? Int, 0)
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

  func testAgentConfigDecodesAndCleansMetadata() throws {
    let data = """
      {
        "deviceId": "device_1",
        "organizationId": "org_1",
        "endpoint": "http://127.0.0.1:8787/chronicle.v1.ChronicleService/SubmitBatch",
        "localOnly": true,
        "metadata": {
          " evalops_context_version ": " evalops.context.v1 ",
          " maestro_session_id ": " session_1 ",
          "traceparent": "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01",
          "empty_value": " ",
          "agent_run_id": "run_1"
        }
      }
      """.data(using: .utf8)!

    let cfg = try JSONDecoder().decode(AgentConfig.self, from: data)
    XCTAssertEqual(cfg.metadata["evalops_context_version"], "evalops.context.v1")
    XCTAssertEqual(cfg.metadata["maestro_session_id"], "session_1")
    XCTAssertEqual(cfg.metadata["agent_run_id"], "run_1")
    XCTAssertEqual(
      cfg.metadata["traceparent"], "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01")
    XCTAssertNil(cfg.metadata["empty_value"])

    let encoded = try JSONEncoder().encode(cfg)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let metadata = try XCTUnwrap(root["metadata"] as? [String: String])
    XCTAssertEqual(metadata["evalops_context_version"], "evalops.context.v1")
    XCTAssertEqual(metadata["maestro_session_id"], "session_1")
    XCTAssertEqual(
      metadata["traceparent"], "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01")
  }

  func testAgentConfigDecodesSecretBroker() throws {
    let data = """
      {
        "deviceId": "device_1",
        "organizationId": "org_1",
        "endpoint": "https://chronicle.example.com/chronicle.v1.ChronicleService/SubmitBatch",
        "localOnly": false,
        "auth": {
          "mode": "bearer",
          "keychainService": "agentd",
          "keychainAccount": "chronicle"
        },
        "secretBroker": {
          "endpoint": "https://secret-broker.example.com/v1/artifacts:wrap",
          "sessionTokenKeychainService": "agentd",
          "sessionTokenKeychainAccount": "secret-broker",
          "ttlSeconds": 120
        }
      }
      """.data(using: .utf8)!

    let cfg = try JSONDecoder().decode(AgentConfig.self, from: data)

    XCTAssertEqual(
      cfg.secretBroker?.endpoint,
      URL(string: "https://secret-broker.example.com/v1/artifacts:wrap")!)
    XCTAssertEqual(cfg.secretBroker?.sessionTokenKeychainService, "agentd")
    XCTAssertEqual(cfg.secretBroker?.sessionTokenKeychainAccount, "secret-broker")
    XCTAssertEqual(cfg.secretBroker?.ttlSeconds, 120)
    XCTAssertEqual(cfg.secretBroker?.tool, "chronicle.agentd")
    XCTAssertEqual(cfg.secretBroker?.capability, "chronicle.frame_batch")

    let encoded = try JSONEncoder().encode(cfg)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertNotNil(root["secretBroker"])
  }

  func testAgentConfigDefaultsEncryptedBatchesForRemoteMode() throws {
    let remote = """
      {
        "deviceId": "device_1",
        "organizationId": "org_1",
        "endpoint": "https://chronicle.example.com/chronicle.v1.ChronicleService/SubmitBatch",
        "localOnly": false,
        "auth": {
          "mode": "bearer",
          "keychainService": "agentd",
          "keychainAccount": "chronicle"
        }
      }
      """.data(using: .utf8)!
    let local = """
      {
        "deviceId": "device_1",
        "organizationId": "org_1",
        "endpoint": "http://127.0.0.1:8787/chronicle.v1.ChronicleService/SubmitBatch",
        "localOnly": true
      }
      """.data(using: .utf8)!

    XCTAssertTrue(try JSONDecoder().decode(AgentConfig.self, from: remote).encryptLocalBatches)
    XCTAssertFalse(try JSONDecoder().decode(AgentConfig.self, from: local).encryptLocalBatches)
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

  func testSecretBrokerWrapSubmitsArtifactReferenceToChronicle() async throws {
    let recorder = RequestRecorder()
    let client = StubHTTPClient { request in
      await recorder.record(request)
      let url = try XCTUnwrap(request.url)
      let body = try XCTUnwrap(request.httpBody)
      let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

      if url.host == "secret-broker.example.com" {
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(root["session_token"] as? String, "broker-session")
        XCTAssertEqual(root["tool"] as? String, "chronicle.agentd")
        XCTAssertEqual(root["capability"] as? String, "chronicle.frame_batch")
        XCTAssertEqual(root["ttl_seconds"] as? Int, 300)

        let secretData = try XCTUnwrap(root["secret_data"] as? [String: String])
        let batchJSON = try XCTUnwrap(secretData["chronicle_frame_batch_json"])
        let batchData = Data(batchJSON.utf8)
        let batchRoot = try XCTUnwrap(
          JSONSerialization.jsonObject(with: batchData) as? [String: Any])
        XCTAssertEqual(batchRoot["batchId"] as? String, "batch_fixture")
        XCTAssertEqual(batchRoot["organizationId"] as? String, "org_1")

        let metadata = try XCTUnwrap(root["metadata"] as? [String: String])
        XCTAssertEqual(metadata["source"], "agentd")
        XCTAssertEqual(metadata["batch_id"], "batch_fixture")

        let response = """
          {
            "grant_id": "grant_1",
            "state": "issued",
            "delivery": {"artifact_id": "art_1"},
            "expires_at": "2026-04-27T00:00:00Z",
            "artifact_id": "art_1"
          }
          """
        return (Data(response.utf8), Self.response(for: url, statusCode: 200))
      }

      XCTAssertEqual(url.host, "chronicle.example.com")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer chronicle-token")
      XCTAssertEqual(root["secretBrokerSessionToken"] as? String, "broker-session")
      XCTAssertEqual(root["secretBrokerArtifactId"] as? String, "art_1")
      XCTAssertEqual(root["secretBrokerGrantId"] as? String, "grant_1")
      XCTAssertNil(root["batch"])

      return (
        Data(
          #"{"batchId":"batch_fixture","artifactId":"art_1","acceptedFrameCount":1,"droppedFrameCount":0,"memoryIds":["mem_1"]}"#
            .utf8),
        Self.response(for: url, statusCode: 200)
      )
    }
    let submitter = try Submitter(
      endpoint: URL(
        string: "https://chronicle.example.com/chronicle.v1.ChronicleService/SubmitBatch")!,
      localOnly: false,
      authMode: .bearer(keychainService: "agentd", keychainAccount: "chronicle"),
      secretBroker: SecretBrokerConfig(
        endpoint: URL(string: "https://secret-broker.example.com/v1/artifacts:wrap")!,
        sessionTokenKeychainService: "agentd",
        sessionTokenKeychainAccount: "secret-broker"
      ),
      credentialProvider: StubCredentialProvider(tokens: [
        "agentd:chronicle": "chronicle-token",
        "agentd:secret-broker": "broker-session",
      ]),
      client: client
    )

    let result = await submitter.submit(Self.batch())

    XCTAssertEqual(
      result,
      .submitted(
        SubmitBatchResponse(
          batchId: "batch_fixture",
          artifactId: "art_1",
          acceptedFrameCount: 1,
          droppedFrameCount: 0,
          memoryIds: ["mem_1"]
        )))
    let requestCount = await recorder.count()
    XCTAssertEqual(requestCount, 2)
  }

  func testSecretBrokerWrapRemovesSpoofedReservedMetadataWhenBatchFieldMissing() async throws {
    let client = StubHTTPClient { request in
      let url = try XCTUnwrap(request.url)
      let body = try XCTUnwrap(request.httpBody)
      let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

      if url.host == "secret-broker.example.com" {
        let metadata = try XCTUnwrap(root["metadata"] as? [String: String])
        XCTAssertEqual(metadata["batch_id"], "batch_fixture")
        XCTAssertEqual(metadata["device_id"], "device_1")
        XCTAssertEqual(metadata["organization_id"], "org_1")
        XCTAssertEqual(metadata["source"], "agentd")
        XCTAssertEqual(metadata["custom"], "kept")
        XCTAssertNil(metadata["workspace_id"])
        XCTAssertNil(metadata["user_id"])
        XCTAssertNil(metadata["project_id"])
        XCTAssertNil(metadata["repository"])

        let response = """
          {
            "grant_id": "grant_1",
            "artifact_id": "art_1"
          }
          """
        return (Data(response.utf8), Self.response(for: url, statusCode: 200))
      }

      return (Data(), Self.response(for: url, statusCode: 200))
    }

    let batch = Batch(
      batchId: "batch_fixture",
      deviceId: "device_1",
      organizationId: "org_1",
      workspaceId: nil,
      userId: nil,
      projectId: nil,
      repository: nil,
      metadata: [
        "batch_id": "spoofed-batch",
        "device_id": "spoofed-device",
        "organization_id": "spoofed-org",
        "workspace_id": "spoofed-workspace",
        "user_id": "spoofed-user",
        "project_id": "spoofed-project",
        "repository": "spoofed/repo",
        "source": "spoofed-source",
        "custom": "kept",
      ],
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

    let submitter = try Submitter(
      endpoint: URL(
        string: "https://chronicle.example.com/chronicle.v1.ChronicleService/SubmitBatch")!,
      localOnly: false,
      authMode: .bearer(keychainService: "agentd", keychainAccount: "chronicle"),
      secretBroker: SecretBrokerConfig(
        endpoint: URL(string: "https://secret-broker.example.com/v1/artifacts:wrap")!,
        sessionTokenKeychainService: "agentd",
        sessionTokenKeychainAccount: "secret-broker"
      ),
      credentialProvider: StubCredentialProvider(tokens: [
        "agentd:chronicle": "chronicle-token",
        "agentd:secret-broker": "broker-session",
      ]),
      client: client
    )

    let result = await submitter.submit(batch)
    XCTAssertEqual(result, .submitted(nil))
  }

  func testSecretBrokerWrapFailurePersistsInlineBatchWithoutSessionToken() async throws {
    let recorder = RequestRecorder()
    let dir = try makeTemporaryDirectory()
    let submitter = try Submitter(
      endpoint: URL(
        string: "https://chronicle.example.com/chronicle.v1.ChronicleService/SubmitBatch")!,
      localOnly: false,
      authMode: .bearer(keychainService: "agentd", keychainAccount: "chronicle"),
      secretBroker: SecretBrokerConfig(
        endpoint: URL(string: "https://secret-broker.example.com/v1/artifacts:wrap")!,
        sessionTokenKeychainService: "agentd",
        sessionTokenKeychainAccount: "secret-broker"
      ),
      credentialProvider: StubCredentialProvider(tokens: [
        "agentd:chronicle": "chronicle-token",
        "agentd:secret-broker": "broker-session",
      ]),
      client: StubHTTPClient { request in
        await recorder.record(request)
        return (Data(#"{"error":"nope"}"#.utf8), Self.response(for: request.url!, statusCode: 500))
      },
      batchDirectory: dir
    )

    let result = await submitter.submit(Self.batch())

    XCTAssertEqual(result, .persistedLocal)
    let requestCount = await recorder.count()
    XCTAssertEqual(requestCount, 1)
    let persisted = try Data(contentsOf: dir.appendingPathComponent("batch_fixture.json"))
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
    XCTAssertNotNil(root["batch"])
    XCTAssertNil(root["secretBrokerSessionToken"])
    XCTAssertNil(root["secretBrokerArtifactId"])
    XCTAssertNil(root["secretBrokerGrantId"])
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

  func testEncryptedLocalBatchPersistenceDoesNotWritePlaintext() async throws {
    let dir = try makeTemporaryDirectory()
    let submitter = try Submitter(
      endpoint: URL(string: "http://127.0.0.1:8787/submit")!,
      localOnly: true,
      batchDirectory: dir,
      deviceId: "device_1",
      encryptLocalBatches: true,
      localBatchKeyProvider: StaticLocalBatchKeyProvider.one
    )

    let result = await submitter.submit(Self.batch())

    XCTAssertEqual(result, .persistedLocal)
    let files = try FileManager.default.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: nil
    )
    let file = try XCTUnwrap(files.first)
    XCTAssertEqual(file.pathExtension, LocalBatchCryptor.encryptedExtension)
    let stored = try Data(contentsOf: file)
    XCTAssertFalse(String(data: stored, encoding: .utf8)?.contains("ChronicleService") ?? false)
    let plaintext = try LocalBatchCryptor(key: StaticLocalBatchKeyProvider.one.key).decrypt(stored)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
    XCTAssertNotNil(root["batch"])
  }

  func testEncryptedLocalBatchFailsClosedWithWrongKey() async throws {
    let dir = try makeTemporaryDirectory()
    let submitter = try Submitter(
      endpoint: URL(string: "http://127.0.0.1:8787/submit")!,
      localOnly: true,
      batchDirectory: dir,
      deviceId: "device_1",
      encryptLocalBatches: true,
      localBatchKeyProvider: StaticLocalBatchKeyProvider.one
    )
    _ = await submitter.submit(Self.batch())

    let file = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
    let stored = try Data(contentsOf: file)
    XCTAssertThrowsError(
      try LocalBatchCryptor(key: StaticLocalBatchKeyProvider.two.key).decrypt(stored)
    )
  }

  func testEncryptedLocalBatchReplaySubmitsAndRemovesQueuedFile() async throws {
    let dir = try makeTemporaryDirectory()
    let failing = try Submitter(
      endpoint: URL(string: "https://chronicle.example.com/submit")!,
      localOnly: false,
      authMode: .bearer(keychainService: "svc", keychainAccount: "acct"),
      credentialProvider: StubCredentialProvider(token: "token"),
      client: StubHTTPClient.status(503, body: #"{"error":"down"}"#),
      batchDirectory: dir,
      deviceId: "device_1",
      encryptLocalBatches: true,
      localBatchKeyProvider: StaticLocalBatchKeyProvider.one
    )

    let persistedResult = await failing.submit(Self.batch())
    XCTAssertEqual(persistedResult, .persistedLocal)
    let encrypted = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
    XCTAssertEqual(encrypted.pathExtension, LocalBatchCryptor.encryptedExtension)

    let recorder = RequestRecorder()
    let replaying = try Submitter(
      endpoint: URL(string: "https://chronicle.example.com/submit")!,
      localOnly: false,
      authMode: .bearer(keychainService: "svc", keychainAccount: "acct"),
      credentialProvider: StubCredentialProvider(token: "token"),
      client: StubHTTPClient { request in
        await recorder.record(request)
        let body = try XCTUnwrap(request.httpBody)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(root["batch"])
        return (
          Data(#"{"batchId":"batch_fixture"}"#.utf8),
          Self.response(for: request.url!, statusCode: 200)
        )
      },
      batchDirectory: dir,
      deviceId: "device_1",
      encryptLocalBatches: true,
      localBatchKeyProvider: StaticLocalBatchKeyProvider.one
    )

    let replay = await replaying.retryLocalBatches()

    XCTAssertEqual(replay, LocalBatchReplayResult(submitted: 1, failed: 0))
    let requestCount = await recorder.count()
    XCTAssertEqual(requestCount, 1)
    let remaining = try FileManager.default.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: nil
    )
    XCTAssertTrue(remaining.isEmpty)
  }

  func testConcurrentReplayRequestsDoNotResubmitQueuedBatch() async throws {
    let dir = try makeTemporaryDirectory()
    let failing = try Submitter(
      endpoint: URL(string: "https://chronicle.example.com/submit")!,
      localOnly: false,
      authMode: .bearer(keychainService: "svc", keychainAccount: "acct"),
      credentialProvider: StubCredentialProvider(token: "token"),
      client: StubHTTPClient.status(503, body: #"{"error":"down"}"#),
      batchDirectory: dir
    )

    let persistedResult = await failing.submit(Self.batch(id: "queued_batch"))
    XCTAssertEqual(persistedResult, .persistedLocal)

    let replayStarted = AsyncSignal()
    let releaseReplay = AsyncGate()
    let recorder = StringRecorder()
    let replaying = try Submitter(
      endpoint: URL(string: "https://chronicle.example.com/submit")!,
      localOnly: false,
      authMode: .bearer(keychainService: "svc", keychainAccount: "acct"),
      credentialProvider: StubCredentialProvider(token: "token"),
      client: StubHTTPClient { request in
        let body = try XCTUnwrap(request.httpBody)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let batch = try XCTUnwrap(root["batch"] as? [String: Any])
        let batchId = try XCTUnwrap(batch["batchId"] as? String)
        await recorder.record(batchId)
        await replayStarted.signal()
        await releaseReplay.wait()
        return (Data(), Self.response(for: request.url!, statusCode: 200))
      },
      batchDirectory: dir
    )

    let firstReplay = Task { await replaying.retryLocalBatches() }
    await replayStarted.wait()
    let secondReplay = Task { await replaying.retryLocalBatches() }
    await Task.yield()
    await releaseReplay.open()

    let firstResult = await firstReplay.value
    let secondResult = await secondReplay.value
    let results = [firstResult, secondResult]
    XCTAssertEqual(secondResult, LocalBatchReplayResult(submitted: 0, failed: 0))
    XCTAssertEqual(results.reduce(0) { $0 + $1.submitted }, 1)
    XCTAssertEqual(results.reduce(0) { $0 + $1.failed }, 0)
    let recordedBatchIds = await recorder.values()
    XCTAssertEqual(recordedBatchIds, ["queued_batch"])
    let remaining = try FileManager.default.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: nil
    )
    XCTAssertTrue(remaining.isEmpty)
  }

  func testSuccessfulSubmitRetriesQueuedLocalBatches() async throws {
    let dir = try makeTemporaryDirectory()
    let failing = try Submitter(
      endpoint: URL(string: "https://chronicle.example.com/submit")!,
      localOnly: false,
      authMode: .bearer(keychainService: "svc", keychainAccount: "acct"),
      credentialProvider: StubCredentialProvider(token: "token"),
      client: StubHTTPClient.status(503, body: #"{"error":"down"}"#),
      batchDirectory: dir
    )

    let persistedResult = await failing.submit(Self.batch(id: "queued_batch"))
    XCTAssertEqual(persistedResult, .persistedLocal)

    let recorder = StringRecorder()
    let replaying = try Submitter(
      endpoint: URL(string: "https://chronicle.example.com/submit")!,
      localOnly: false,
      authMode: .bearer(keychainService: "svc", keychainAccount: "acct"),
      credentialProvider: StubCredentialProvider(token: "token"),
      client: StubHTTPClient { request in
        let body = try XCTUnwrap(request.httpBody)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let batch = try XCTUnwrap(root["batch"] as? [String: Any])
        let batchId = try XCTUnwrap(batch["batchId"] as? String)
        await recorder.record(batchId)
        return (Data(), Self.response(for: request.url!, statusCode: 200))
      },
      batchDirectory: dir
    )

    let result = await replaying.submit(Self.batch(id: "live_batch"))

    XCTAssertEqual(result, .submitted(nil))
    let submittedBatchIds = await recorder.values()
    XCTAssertEqual(submittedBatchIds, ["live_batch", "queued_batch"])
    let remaining = try FileManager.default.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: nil
    )
    XCTAssertTrue(remaining.isEmpty)
  }

  func testEncryptedReplayUsesSecretBrokerWrapping() async throws {
    let dir = try makeTemporaryDirectory()
    let failing = try Submitter(
      endpoint: URL(
        string: "https://chronicle.example.com/chronicle.v1.ChronicleService/SubmitBatch")!,
      localOnly: false,
      authMode: .bearer(keychainService: "agentd", keychainAccount: "chronicle"),
      secretBroker: SecretBrokerConfig(
        endpoint: URL(string: "https://secret-broker.example.com/v1/artifacts:wrap")!,
        sessionTokenKeychainService: "agentd",
        sessionTokenKeychainAccount: "secret-broker"
      ),
      credentialProvider: StubCredentialProvider(tokens: [
        "agentd:chronicle": "chronicle-token",
        "agentd:secret-broker": "broker-session",
      ]),
      client: StubHTTPClient.status(503, body: #"{"error":"down"}"#),
      batchDirectory: dir,
      deviceId: "device_1",
      encryptLocalBatches: true,
      localBatchKeyProvider: StaticLocalBatchKeyProvider.one
    )

    let persistedResult = await failing.submit(Self.batch())
    XCTAssertEqual(persistedResult, .persistedLocal)

    let recorder = RequestRecorder()
    let replaying = try Submitter(
      endpoint: URL(
        string: "https://chronicle.example.com/chronicle.v1.ChronicleService/SubmitBatch")!,
      localOnly: false,
      authMode: .bearer(keychainService: "agentd", keychainAccount: "chronicle"),
      secretBroker: SecretBrokerConfig(
        endpoint: URL(string: "https://secret-broker.example.com/v1/artifacts:wrap")!,
        sessionTokenKeychainService: "agentd",
        sessionTokenKeychainAccount: "secret-broker"
      ),
      credentialProvider: StubCredentialProvider(tokens: [
        "agentd:chronicle": "chronicle-token",
        "agentd:secret-broker": "broker-session",
      ]),
      client: StubHTTPClient { request in
        await recorder.record(request)
        let url = try XCTUnwrap(request.url)
        let body = try XCTUnwrap(request.httpBody)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        if url.host == "secret-broker.example.com" {
          let secretData = try XCTUnwrap(root["secret_data"] as? [String: String])
          XCTAssertNotNil(secretData["chronicle_frame_batch_json"])
          return (
            Data(#"{"grant_id":"grant_1","artifact_id":"art_1"}"#.utf8),
            Self.response(for: url, statusCode: 200)
          )
        }

        XCTAssertEqual(url.host, "chronicle.example.com")
        XCTAssertNil(root["batch"])
        XCTAssertEqual(root["secretBrokerSessionToken"] as? String, "broker-session")
        XCTAssertEqual(root["secretBrokerArtifactId"] as? String, "art_1")
        XCTAssertEqual(root["secretBrokerGrantId"] as? String, "grant_1")
        return (
          Data(#"{"batchId":"batch_fixture","artifactId":"art_1"}"#.utf8),
          Self.response(for: url, statusCode: 200)
        )
      },
      batchDirectory: dir,
      deviceId: "device_1",
      encryptLocalBatches: true,
      localBatchKeyProvider: StaticLocalBatchKeyProvider.one
    )

    let replay = await replaying.retryLocalBatches()

    XCTAssertEqual(replay, LocalBatchReplayResult(submitted: 1, failed: 0))
    let requestCount = await recorder.count()
    XCTAssertEqual(requestCount, 2)
    let remaining = try FileManager.default.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: nil
    )
    XCTAssertTrue(remaining.isEmpty)
  }

  func testLocalBatchSweepRemovesOldFiles() async throws {
    let dir = try makeTemporaryDirectory()
    try writeBatchFile(
      dir.appendingPathComponent("old.json"), bytes: 10,
      modified: Date(timeIntervalSinceNow: -8 * 24 * 60 * 60))
    try writeBatchFile(
      dir.appendingPathComponent("old.\(LocalBatchCryptor.encryptedExtension)"), bytes: 10,
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
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("old.\(LocalBatchCryptor.encryptedExtension)").path))
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

  func testLocalBatchKeyProviderReadsExistingKeyAfterDuplicateStore() throws {
    final class DuplicateKeychain: @unchecked Sendable {
      let persisted = Data(repeating: 0xAA, count: 32)
      private(set) var readCount = 0

      func read() -> Data? {
        defer { readCount += 1 }
        return readCount == 0 ? nil : persisted
      }

      func store(_ key: Data) -> Bool {
        XCTAssertEqual(key.count, 32)
        return false
      }
    }

    let keychain = DuplicateKeychain()
    let provider = KeychainLocalBatchKeyProvider(
      service: "test.local-batch-key",
      readKeyData: { _, _ in keychain.read() },
      storeKeyData: { _, _, key in keychain.store(key) },
      generateRandomKeyData: { Data(repeating: 0xBB, count: 32) }
    )

    let key = try provider.localBatchKey(deviceId: "device_1")
    let keyData = key.withUnsafeBytes { Data($0) }

    XCTAssertEqual(keyData, keychain.persisted)
    XCTAssertEqual(keychain.readCount, 2)
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

  fileprivate static func response(for url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
  }
}

actor RequestRecorder {
  private var requests: [URLRequest] = []

  func record(_ request: URLRequest) {
    requests.append(request)
  }

  func count() -> Int {
    requests.count
  }
}

actor StringRecorder {
  private var recordedValues: [String] = []

  func record(_ value: String) {
    recordedValues.append(value)
  }

  func values() -> [String] {
    recordedValues
  }
}

actor AsyncSignal {
  private var isSignaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isSignaled else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func signal() {
    guard !isSignaled else { return }
    isSignaled = true
    let currentWaiters = waiters
    waiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume()
    }
  }
}

actor AsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let currentWaiters = waiters
    waiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume()
    }
  }
}

struct StubCredentialProvider: SubmitterCredentialProviding {
  let tokens: [String: String]

  init(token: String) {
    self.tokens = ["svc:acct": token]
  }

  init(tokens: [String: String]) {
    self.tokens = tokens
  }

  func bearerToken(service: String, account: String) throws -> String {
    tokens["\(service):\(account)"] ?? ""
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
      (Data(body.utf8), SubmitterTests.response(for: request.url!, statusCode: statusCode))
    }
  }

  static func failure(_ error: Error) -> StubHTTPClient {
    StubHTTPClient { _ in throw error }
  }
}

struct StaticLocalBatchKeyProvider: @unchecked Sendable, LocalBatchKeyProviding {
  static let one = StaticLocalBatchKeyProvider(seed: 0x11)
  static let two = StaticLocalBatchKeyProvider(seed: 0x22)

  let key: SymmetricKey

  init(seed: UInt8) {
    key = SymmetricKey(data: Data(repeating: seed, count: 32))
  }

  func localBatchKey(deviceId: String) throws -> SymmetricKey {
    key
  }
}
