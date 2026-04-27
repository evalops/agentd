// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Security

/// HTTP/JSON poster against `chronicle.v1.ChronicleService.SubmitBatch`.
/// Local-only mode writes batches to `~/.evalops/agentd/batches/` instead of POSTing.
actor Submitter {
  private let endpoint: URL
  private let localOnly: Bool
  private let client: any HTTPClient
  private let auth: ResolvedSubmitterAuth
  private let secretBroker: ResolvedSecretBrokerConfig?
  private let batchDirectory: URL
  private let maxBatchBytes: Int64
  private let maxBatchAgeDays: Double

  init(
    endpoint: URL,
    localOnly: Bool,
    authMode: AuthMode = .none,
    secretBroker: SecretBrokerConfig? = nil,
    credentialProvider: any SubmitterCredentialProviding = KeychainCredentialProvider(),
    session: URLSession? = nil,
    client: (any HTTPClient)? = nil,
    batchDirectory: URL? = nil,
    maxBatchBytes: Int64 = 512 * 1024 * 1024,
    maxBatchAgeDays: Double = 7
  ) throws {
    guard EndpointPolicy.isAllowed(endpoint: endpoint, localOnly: localOnly) else {
      throw SubmitterInitError.insecureRemoteEndpoint(endpoint.absoluteString)
    }
    guard localOnly || authMode != .none else {
      throw SubmitterInitError.missingRemoteAuth
    }
    if let secretBroker, !localOnly {
      guard EndpointPolicy.isAllowed(endpoint: secretBroker.endpoint, localOnly: false) else {
        throw SubmitterInitError.insecureRemoteEndpoint(secretBroker.endpoint.absoluteString)
      }
    }

    self.endpoint = endpoint
    self.localOnly = localOnly
    self.auth = try ResolvedSubmitterAuth(mode: authMode, credentialProvider: credentialProvider)
    if let secretBroker, !localOnly {
      self.secretBroker = try ResolvedSecretBrokerConfig(
        config: secretBroker,
        credentialProvider: credentialProvider
      )
    } else {
      self.secretBroker = nil
    }
    self.batchDirectory =
      batchDirectory
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".evalops/agentd/batches")
    self.maxBatchBytes = maxBatchBytes
    self.maxBatchAgeDays = maxBatchAgeDays

    if let client {
      self.client = client
    } else if let session {
      self.client = URLSessionHTTPClient(session: session)
    } else if case .mtls(let identity) = auth {
      let cfg = URLSessionConfiguration.ephemeral
      cfg.httpAdditionalHeaders = [
        "Content-Type": "application/json",
        "Connect-Protocol-Version": "1",
      ]
      cfg.timeoutIntervalForRequest = 30
      let delegate = MTLSURLSessionDelegate(identity: identity.secIdentity)
      self.client = URLSessionHTTPClient(
        session: URLSession(
          configuration: cfg,
          delegate: delegate,
          delegateQueue: nil
        ))
    } else {
      let cfg = URLSessionConfiguration.ephemeral
      cfg.httpAdditionalHeaders = [
        "Content-Type": "application/json",
        "Connect-Protocol-Version": "1",
      ]
      cfg.timeoutIntervalForRequest = 30
      self.client = URLSessionHTTPClient(session: URLSession(configuration: cfg))
    }
  }

  @discardableResult
  func submit(_ batch: Batch) async -> SubmitResult {
    let fallbackData: Data
    do {
      fallbackData = try encodeSubmitBatchRequest(batch, localOnly: localOnly)
    } catch {
      Log.submit.error("batch encode failed id=\(batch.batchId, privacy: .public)")
      return .failed
    }

    if localOnly {
      await persistLocal(batch.batchId, data: fallbackData)
      return .persistedLocal
    }

    let submitData: Data
    if let secretBroker {
      do {
        let wrapped = try await wrapFrameBatch(batch, using: secretBroker)
        submitData = try encodeBrokerSubmitBatchRequest(
          sessionToken: secretBroker.sessionToken,
          artifactId: wrapped.artifactId,
          grantId: wrapped.grantId,
          localOnly: localOnly
        )
      } catch {
        Log.submit.warning(
          "secret broker wrap failed batch=\(batch.batchId, privacy: .public) error=\(error.localizedDescription, privacy: .public) — falling back to local"
        )
        await persistLocal(batch.batchId, data: fallbackData)
        return .persistedLocal
      }
    } else {
      submitData = fallbackData
    }

    let req = makeRequest(body: submitData)
    do {
      let (body, resp) = try await client.data(for: req)
      if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        Log.submit.warning(
          "submit status=\(http.statusCode, privacy: .public) batch=\(batch.batchId, privacy: .public) — falling back to local"
        )
        await persistLocal(batch.batchId, data: fallbackData)
        return .persistedLocal
      } else {
        let response: SubmitBatchResponse?
        if body.isEmpty {
          response = nil
        } else {
          do {
            response = try JSONDecoder().decode(SubmitBatchResponse.self, from: body)
          } catch {
            Log.submit.warning(
              "submit malformed response batch=\(batch.batchId, privacy: .public) — falling back to local"
            )
            await persistLocal(batch.batchId, data: fallbackData)
            return .persistedLocal
          }
        }
        Log.submit.info(
          "submit ok batch=\(batch.batchId, privacy: .public) frames=\(batch.frames.count, privacy: .public)"
        )
        await sweepLocalBatches()
        return .submitted(response)
      }
    } catch {
      Log.submit.warning(
        "submit error \(error.localizedDescription, privacy: .public) — falling back to local")
      await persistLocal(batch.batchId, data: fallbackData)
      return .persistedLocal
    }
  }

  func makeRequest(body: Data) -> URLRequest {
    var req = URLRequest(url: endpoint)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    if case .bearer(let token) = auth {
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    req.httpBody = body
    return req
  }

  private func makeSecretBrokerRequest(endpoint: URL, body: Data) -> URLRequest {
    var req = URLRequest(url: endpoint)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    return req
  }

  private func wrapFrameBatch(
    _ batch: Batch,
    using secretBroker: ResolvedSecretBrokerConfig
  ) async throws -> WrappedArtifact {
    let payload = try encodeFrameBatch(batch)
    guard let payloadJSON = String(data: payload, encoding: .utf8) else {
      throw SubmitterError.invalidBatchPayload
    }
    let request = WrapArtifactRequest(
      sessionToken: secretBroker.sessionToken,
      tool: secretBroker.tool,
      capability: secretBroker.capability,
      resourceRef: "chronicle://\(batch.organizationId)/\(batch.deviceId)/\(batch.batchId)",
      ttlSeconds: secretBroker.ttlSeconds,
      reason: secretBroker.reason,
      secretData: ["chronicle_frame_batch_json": payloadJSON],
      metadata: [
        "batch_id": batch.batchId,
        "device_id": batch.deviceId,
        "organization_id": batch.organizationId,
        "source": "agentd",
      ]
    )
    let data = try encodeWrapArtifactRequest(request)
    let (body, resp) = try await client.data(
      for: makeSecretBrokerRequest(endpoint: secretBroker.endpoint, body: data)
    )
    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw SubmitterError.secretBrokerStatus(http.statusCode)
    }
    let wrapped = try JSONDecoder().decode(WrapArtifactResponse.self, from: body)
    guard !wrapped.artifactId.isEmpty, !wrapped.grantId.isEmpty else {
      throw SubmitterError.malformedSecretBrokerResponse
    }
    return WrappedArtifact(artifactId: wrapped.artifactId, grantId: wrapped.grantId)
  }

  private func persistLocal(_ id: String, data: Data) async {
    try? FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: true)
    let url = batchDirectory.appendingPathComponent("\(id).json")
    try? data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    Log.submit.info("local persist \(url.path, privacy: .public)")
    await sweepLocalBatches()
  }

  func sweepLocalBatches() async {
    let fm = FileManager.default
    guard
      let urls = try? fm.contentsOfDirectory(
        at: batchDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return }

    var files: [LocalBatchFile] = []
    let now = Date()
    let cutoff = now.addingTimeInterval(-maxBatchAgeDays * 24 * 60 * 60)
    var removedCount = 0
    var removedBytes: Int64 = 0

    for url in urls where url.pathExtension == "json" {
      guard
        let values = try? url.resourceValues(forKeys: [
          .contentModificationDateKey,
          .fileSizeKey,
          .isRegularFileKey,
        ]),
        values.isRegularFile == true
      else { continue }

      let modified = values.contentModificationDate ?? .distantPast
      let size = Int64(values.fileSize ?? 0)
      if modified < cutoff {
        if (try? fm.removeItem(at: url)) != nil {
          removedCount += 1
          removedBytes += size
        }
        continue
      }
      files.append(LocalBatchFile(url: url, modified: modified, size: size))
    }

    var totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
    for file in files.sorted(by: { $0.modified < $1.modified }) where totalBytes > maxBatchBytes {
      if (try? fm.removeItem(at: file.url)) != nil {
        totalBytes -= file.size
        removedCount += 1
        removedBytes += file.size
      }
    }

    if removedCount > 0 {
      Log.submit.notice(
        "local batch sweep removed=\(removedCount, privacy: .public) bytes=\(removedBytes, privacy: .public)"
      )
    }
  }
}

private struct LocalBatchFile {
  let url: URL
  let modified: Date
  let size: Int64
}

protocol HTTPClient: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionHTTPClient: HTTPClient {
  let session: URLSession

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }
}

enum SubmitterInitError: Error, Equatable, LocalizedError {
  case insecureRemoteEndpoint(String)
  case missingRemoteAuth
  case missingBearerToken(service: String, account: String)
  case missingClientIdentity(label: String)

  var errorDescription: String? {
    switch self {
    case .insecureRemoteEndpoint(let endpoint):
      return "remote agentd endpoint must use HTTPS or loopback HTTP: \(endpoint)"
    case .missingRemoteAuth:
      return "remote agentd endpoint requires bearer or mTLS auth"
    case .missingBearerToken(let service, let account):
      return "bearer token not found in Keychain service=\(service) account=\(account)"
    case .missingClientIdentity(let label):
      return "mTLS identity not found in Keychain label=\(label)"
    }
  }
}

enum EndpointPolicy {
  static func isAllowed(endpoint: URL, localOnly: Bool) -> Bool {
    guard !localOnly else { return true }
    guard let scheme = endpoint.scheme?.lowercased() else { return false }
    if scheme == "https" || scheme == "unix" {
      return true
    }
    guard scheme == "http", let host = endpoint.host?.lowercased() else {
      return false
    }
    return host == "localhost" || host == "::1" || host.hasPrefix("127.")
  }
}

protocol SubmitterCredentialProviding: Sendable {
  func bearerToken(service: String, account: String) throws -> String
  func clientIdentity(label: String) throws -> ClientIdentity
}

struct ClientIdentity: @unchecked Sendable {
  let secIdentity: SecIdentity
}

enum ResolvedSubmitterAuth: @unchecked Sendable, Equatable {
  case none
  case bearer(String)
  case mtls(ClientIdentity)

  init(mode: AuthMode, credentialProvider: any SubmitterCredentialProviding) throws {
    switch mode {
    case .none:
      self = .none
    case .bearer(let service, let account):
      let token = try credentialProvider.bearerToken(service: service, account: account)
      guard !token.isEmpty else {
        throw SubmitterInitError.missingBearerToken(service: service, account: account)
      }
      self = .bearer(token)
    case .mtls(let label):
      self = .mtls(try credentialProvider.clientIdentity(label: label))
    }
  }

  static func == (lhs: ResolvedSubmitterAuth, rhs: ResolvedSubmitterAuth) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
      return true
    case (.bearer(let left), .bearer(let right)):
      return left == right
    case (.mtls, .mtls):
      return true
    default:
      return false
    }
  }
}

struct KeychainCredentialProvider: SubmitterCredentialProviding {
  func bearerToken(service: String, account: String) throws -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess,
      let data = item as? Data,
      let token = String(data: data, encoding: .utf8)
    else {
      throw SubmitterInitError.missingBearerToken(service: service, account: account)
    }
    return token.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func clientIdentity(label: String) throws -> ClientIdentity {
    let query: [String: Any] = [
      kSecClass as String: kSecClassIdentity,
      kSecAttrLabel as String: label,
      kSecReturnRef as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let identity = item else {
      throw SubmitterInitError.missingClientIdentity(label: label)
    }
    return ClientIdentity(secIdentity: identity as! SecIdentity)
  }
}

private final class MTLSURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
  private let identity: SecIdentity

  init(identity: SecIdentity) {
    self.identity = identity
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    guard
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate
    else {
      return (.performDefaultHandling, nil)
    }
    return (
      .useCredential,
      URLCredential(
        identity: identity,
        certificates: nil,
        persistence: .forSession
      )
    )
  }
}

struct SubmitBatchRequest: Sendable, Codable {
  let batch: Batch?
  let localOnly: Bool
  let secretBrokerSessionToken: String?
  let secretBrokerArtifactId: String?
  let secretBrokerGrantId: String?

  init(
    batch: Batch? = nil,
    localOnly: Bool,
    secretBrokerSessionToken: String? = nil,
    secretBrokerArtifactId: String? = nil,
    secretBrokerGrantId: String? = nil
  ) {
    self.batch = batch
    self.localOnly = localOnly
    self.secretBrokerSessionToken = secretBrokerSessionToken
    self.secretBrokerArtifactId = secretBrokerArtifactId
    self.secretBrokerGrantId = secretBrokerGrantId
  }
}

struct SubmitBatchResponse: Sendable, Codable, Equatable {
  let batchId: String?
  let artifactId: String?
  let acceptedFrameCount: Int?
  let droppedFrameCount: Int?
  let memoryIds: [String]?
}

enum SubmitResult: Sendable, Equatable {
  case submitted(SubmitBatchResponse?)
  case persistedLocal
  case failed
}

enum SubmitterError: Error, LocalizedError {
  case invalidBatchPayload
  case secretBrokerStatus(Int)
  case malformedSecretBrokerResponse

  var errorDescription: String? {
    switch self {
    case .invalidBatchPayload:
      return "frame batch could not be encoded as UTF-8 JSON"
    case .secretBrokerStatus(let status):
      return "secret broker wrap returned HTTP \(status)"
    case .malformedSecretBrokerResponse:
      return "secret broker wrap response did not include artifact and grant ids"
    }
  }
}

struct ResolvedSecretBrokerConfig: Sendable, Equatable {
  let endpoint: URL
  let sessionToken: String
  let ttlSeconds: Int
  let tool: String
  let capability: String
  let reason: String

  init(
    config: SecretBrokerConfig,
    credentialProvider: any SubmitterCredentialProviding
  ) throws {
    let sessionToken = try credentialProvider.bearerToken(
      service: config.sessionTokenKeychainService,
      account: config.sessionTokenKeychainAccount
    )
    guard !sessionToken.isEmpty else {
      throw SubmitterInitError.missingBearerToken(
        service: config.sessionTokenKeychainService,
        account: config.sessionTokenKeychainAccount
      )
    }
    self.endpoint = config.endpoint
    self.sessionToken = sessionToken
    self.ttlSeconds = config.ttlSeconds
    self.tool = config.tool
    self.capability = config.capability
    self.reason = config.reason
  }
}

struct WrappedArtifact: Sendable, Equatable {
  let artifactId: String
  let grantId: String
}

struct WrapArtifactRequest: Sendable, Codable {
  let sessionToken: String
  let tool: String
  let capability: String
  let resourceRef: String
  let ttlSeconds: Int
  let reason: String
  let secretData: [String: String]
  let metadata: [String: String]

  enum CodingKeys: String, CodingKey {
    case sessionToken = "session_token"
    case tool
    case capability
    case resourceRef = "resource_ref"
    case ttlSeconds = "ttl_seconds"
    case reason
    case secretData = "secret_data"
    case metadata
  }
}

struct WrapArtifactResponse: Sendable, Codable, Equatable {
  let grantId: String
  let artifactId: String

  enum CodingKeys: String, CodingKey {
    case grantId = "grant_id"
    case artifactId = "artifact_id"
  }
}

func encodeSubmitBatchRequest(_ batch: Batch, localOnly: Bool) throws -> Data {
  try encodeSubmitBatchRequest(SubmitBatchRequest(batch: batch, localOnly: localOnly))
}

func encodeBrokerSubmitBatchRequest(
  sessionToken: String,
  artifactId: String,
  grantId: String,
  localOnly: Bool
) throws -> Data {
  try encodeSubmitBatchRequest(
    SubmitBatchRequest(
      localOnly: localOnly,
      secretBrokerSessionToken: sessionToken,
      secretBrokerArtifactId: artifactId,
      secretBrokerGrantId: grantId
    ))
}

private func encodeSubmitBatchRequest(_ request: SubmitBatchRequest) throws -> Data {
  let enc = JSONEncoder()
  enc.dateEncodingStrategy = .iso8601
  enc.outputFormatting = [.sortedKeys]
  return try enc.encode(request)
}

func encodeFrameBatch(_ batch: Batch) throws -> Data {
  let enc = JSONEncoder()
  enc.dateEncodingStrategy = .iso8601
  enc.outputFormatting = [.sortedKeys]
  return try enc.encode(batch)
}

func encodeWrapArtifactRequest(_ request: WrapArtifactRequest) throws -> Data {
  let enc = JSONEncoder()
  enc.dateEncodingStrategy = .iso8601
  enc.outputFormatting = [.sortedKeys]
  return try enc.encode(request)
}
