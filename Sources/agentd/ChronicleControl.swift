// SPDX-License-Identifier: BUSL-1.1

import Foundation

enum CaptureMode: String, Sendable, Codable, Equatable {
  case unspecified = "CAPTURE_MODE_UNSPECIFIED"
  case localOnly = "CAPTURE_MODE_LOCAL_ONLY"
  case hybrid = "CAPTURE_MODE_HYBRID"
  case cloud = "CAPTURE_MODE_CLOUD"
  case paused = "CAPTURE_MODE_PAUSED"

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let raw = try? container.decode(String.self),
      let value = CaptureMode(rawValue: raw)
    {
      self = value
    } else {
      self = .unspecified
    }
  }
}

struct CapturePolicy: Sendable, Codable, Equatable {
  var policyVersion: String
  var captureMode: CaptureMode
  var allowedBundleIds: [String]
  var deniedBundleIds: [String]
  var deniedPathPrefixes: [String]
  var pauseWindowTitlePatterns: [String]
  var secretPatterns: [String]
  var cloudConsolidationTier: String
  var minBatchIntervalSeconds: Int
  var maxFramesPerBatch: Int
  var scheduledPauseWindows: [ScheduledPauseWindow]
  var sourcePolicyRef: String

  init(
    policyVersion: String = "",
    captureMode: CaptureMode = .unspecified,
    allowedBundleIds: [String] = [],
    deniedBundleIds: [String] = [],
    deniedPathPrefixes: [String] = [],
    pauseWindowTitlePatterns: [String] = [],
    secretPatterns: [String] = [],
    cloudConsolidationTier: String = "",
    minBatchIntervalSeconds: Int = 0,
    maxFramesPerBatch: Int = 0,
    scheduledPauseWindows: [ScheduledPauseWindow] = [],
    sourcePolicyRef: String = ""
  ) {
    self.policyVersion = policyVersion
    self.captureMode = captureMode
    self.allowedBundleIds = allowedBundleIds
    self.deniedBundleIds = deniedBundleIds
    self.deniedPathPrefixes = deniedPathPrefixes
    self.pauseWindowTitlePatterns = pauseWindowTitlePatterns
    self.secretPatterns = secretPatterns
    self.cloudConsolidationTier = cloudConsolidationTier
    self.minBatchIntervalSeconds = minBatchIntervalSeconds
    self.maxFramesPerBatch = maxFramesPerBatch
    self.scheduledPauseWindows = scheduledPauseWindows
    self.sourcePolicyRef = sourcePolicyRef
  }

  enum CodingKeys: String, CodingKey {
    case policyVersion
    case captureMode
    case allowedBundleIds
    case deniedBundleIds
    case deniedPathPrefixes
    case pauseWindowTitlePatterns
    case secretPatterns
    case cloudConsolidationTier
    case minBatchIntervalSeconds
    case maxFramesPerBatch
    case scheduledPauseWindows
    case sourcePolicyRef
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      policyVersion: try container.decodeIfPresent(String.self, forKey: .policyVersion) ?? "",
      captureMode: try container.decodeIfPresent(CaptureMode.self, forKey: .captureMode)
        ?? .unspecified,
      allowedBundleIds: try container.decodeIfPresent([String].self, forKey: .allowedBundleIds)
        ?? [],
      deniedBundleIds: try container.decodeIfPresent([String].self, forKey: .deniedBundleIds)
        ?? [],
      deniedPathPrefixes: try container.decodeIfPresent([String].self, forKey: .deniedPathPrefixes)
        ?? [],
      pauseWindowTitlePatterns: try container.decodeIfPresent(
        [String].self,
        forKey: .pauseWindowTitlePatterns
      ) ?? [],
      secretPatterns: try container.decodeIfPresent([String].self, forKey: .secretPatterns) ?? [],
      cloudConsolidationTier: try container.decodeIfPresent(
        String.self,
        forKey: .cloudConsolidationTier
      ) ?? "",
      minBatchIntervalSeconds: try container.decodeIfPresent(
        Int.self,
        forKey: .minBatchIntervalSeconds
      ) ?? 0,
      maxFramesPerBatch: try container.decodeIfPresent(Int.self, forKey: .maxFramesPerBatch) ?? 0,
      scheduledPauseWindows: try container.decodeIfPresent(
        [ScheduledPauseWindow].self,
        forKey: .scheduledPauseWindows
      ) ?? [],
      sourcePolicyRef: try container.decodeIfPresent(String.self, forKey: .sourcePolicyRef) ?? ""
    )
  }
}

struct ScheduledPauseWindow: Sendable, Codable, Equatable {
  var id: String
  var reason: String
  var startsAt: Date
  var endsAt: Date
}

struct ChronicleDevice: Sendable, Codable, Equatable {
  var deviceId: String
  var organizationId: String
  var workspaceId: String?
  var userId: String?
  var hostname: String?
  var appVersion: String?
  var captureMode: CaptureMode?
  var paused: Bool?
  var pauseReason: String?
  var metadata: [String: String]?

  init(
    deviceId: String,
    organizationId: String,
    workspaceId: String? = nil,
    userId: String? = nil,
    hostname: String? = nil,
    appVersion: String? = nil,
    captureMode: CaptureMode? = nil,
    paused: Bool? = nil,
    pauseReason: String? = nil,
    metadata: [String: String]? = nil
  ) {
    self.deviceId = deviceId
    self.organizationId = organizationId
    self.workspaceId = workspaceId
    self.userId = userId
    self.hostname = hostname
    self.appVersion = appVersion
    self.captureMode = captureMode
    self.paused = paused
    self.pauseReason = pauseReason
    self.metadata = metadata
  }
}

struct RegisterDeviceRequest: Sendable, Codable, Equatable {
  var deviceId: String
  var organizationId: String
  var workspaceId: String?
  var userId: String?
  var hostname: String
  var appVersion: String
  var metadata: [String: String]
}

struct RegisterDeviceResponse: Sendable, Codable, Equatable {
  var device: ChronicleDevice?
  var policy: CapturePolicy?
}

struct HeartbeatRequest: Sendable, Codable, Equatable {
  var deviceId: String
  var organizationId: String
  var pendingFrameCount: Int
  var pendingBytes: Int64
  var paused: Bool
  var pauseReason: String?

  enum CodingKeys: String, CodingKey {
    case deviceId
    case organizationId
    case pendingFrameCount
    case pendingBytes
    case paused
    case pauseReason
  }

  init(
    deviceId: String,
    organizationId: String,
    pendingFrameCount: Int,
    pendingBytes: Int64,
    paused: Bool = false,
    pauseReason: String? = nil
  ) {
    self.deviceId = deviceId
    self.organizationId = organizationId
    self.pendingFrameCount = pendingFrameCount
    self.pendingBytes = pendingBytes
    self.paused = paused
    self.pauseReason = pauseReason
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(deviceId, forKey: .deviceId)
    try container.encode(organizationId, forKey: .organizationId)
    try container.encode(pendingFrameCount, forKey: .pendingFrameCount)
    try container.encode(String(pendingBytes), forKey: .pendingBytes)
    try container.encode(paused, forKey: .paused)
    try container.encodeIfPresent(pauseReason, forKey: .pauseReason)
  }
}

struct HeartbeatResponse: Sendable, Codable, Equatable {
  var device: ChronicleDevice?
  var policy: CapturePolicy?
}

struct ChronicleControlState: Sendable, Equatable {
  var registered: Bool = false
  var lastPolicyVersion: String?
  var serverPaused: Bool = false
  var serverPauseReason: String?
  var lastError: String?

  mutating func apply(device: ChronicleDevice) -> Bool {
    let previousPaused = serverPaused
    let previousReason = serverPauseReason
    serverPaused = device.paused ?? false
    serverPauseReason = device.pauseReason
    return previousPaused != serverPaused || previousReason != serverPauseReason
  }
}

actor ChronicleControlClient {
  private let submitBatchEndpoint: URL
  private let client: any HTTPClient
  private let auth: ResolvedSubmitterAuth

  init(
    submitBatchEndpoint: URL,
    authMode: AuthMode,
    credentialProvider: any SubmitterCredentialProviding = KeychainCredentialProvider(),
    session: URLSession? = nil,
    client: (any HTTPClient)? = nil
  ) throws {
    guard EndpointPolicy.isAllowed(endpoint: submitBatchEndpoint, localOnly: false) else {
      throw SubmitterInitError.insecureRemoteEndpoint(submitBatchEndpoint.absoluteString)
    }
    guard authMode != .none else {
      throw SubmitterInitError.missingRemoteAuth
    }
    self.submitBatchEndpoint = submitBatchEndpoint
    self.auth = try ResolvedSubmitterAuth(mode: authMode, credentialProvider: credentialProvider)

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
      self.client = URLSessionHTTPClient(
        session: URLSession(
          configuration: cfg,
          delegate: MTLSURLSessionDelegate(identity: identity.secIdentity),
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

  func register(_ request: RegisterDeviceRequest) async throws -> RegisterDeviceResponse {
    try await send(request, method: "RegisterDevice", responseType: RegisterDeviceResponse.self)
  }

  func heartbeat(_ request: HeartbeatRequest) async throws -> HeartbeatResponse {
    try await send(request, method: "Heartbeat", responseType: HeartbeatResponse.self)
  }

  func endpoint(for method: String) -> URL {
    ChronicleEndpoint.methodURL(fromSubmitBatchEndpoint: submitBatchEndpoint, method: method)
  }

  private func send<Request: Encodable & Sendable, Response: Decodable & Sendable>(
    _ body: Request,
    method: String,
    responseType: Response.Type
  ) async throws -> Response {
    let data = try encodeChronicleControlRequest(body)
    var req = URLRequest(url: endpoint(for: method))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    if case .bearer(let token) = auth {
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    req.httpBody = data

    let (responseBody, resp) = try await client.data(for: req)
    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw ChronicleControlError.status(method: method, statusCode: http.statusCode)
    }
    if responseBody.isEmpty {
      return try JSONDecoder().decode(responseType, from: Data("{}".utf8))
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(responseType, from: responseBody)
  }
}

enum ChronicleEndpoint {
  static func methodURL(fromSubmitBatchEndpoint endpoint: URL, method: String) -> URL {
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    let marker = "/chronicle.v1.ChronicleService/"
    if let path = components?.path, let range = path.range(of: marker) {
      components?.path = String(path[..<range.upperBound]) + method
      return components?.url ?? endpoint
    }
    components?.path = endpoint.deletingLastPathComponent().appendingPathComponent(method).path
    return components?.url ?? endpoint
  }
}

enum ChronicleControlError: Error, LocalizedError, Equatable {
  case status(method: String, statusCode: Int)

  var errorDescription: String? {
    switch self {
    case .status(let method, let statusCode):
      return "Chronicle \(method) returned HTTP \(statusCode)"
    }
  }
}

func encodeChronicleControlRequest<T: Encodable>(_ request: T) throws -> Data {
  let enc = JSONEncoder()
  enc.dateEncodingStrategy = .iso8601
  enc.outputFormatting = [.sortedKeys]
  return try enc.encode(request)
}
