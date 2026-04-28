// SPDX-License-Identifier: BUSL-1.1

import Foundation

enum AuthMode: Sendable, Codable, Equatable {
  case none
  case bearer(keychainService: String, keychainAccount: String)
  case mtls(identityLabel: String)

  enum CodingKeys: String, CodingKey {
    case mode
    case keychainService
    case keychainAccount
    case identityLabel
  }

  enum Mode: String, Codable {
    case none
    case bearer
    case mtls
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .none
    switch mode {
    case .none:
      self = .none
    case .bearer:
      self = .bearer(
        keychainService: try container.decode(String.self, forKey: .keychainService),
        keychainAccount: try container.decode(String.self, forKey: .keychainAccount)
      )
    case .mtls:
      self = .mtls(identityLabel: try container.decode(String.self, forKey: .identityLabel))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .none:
      try container.encode(Mode.none, forKey: .mode)
    case .bearer(let service, let account):
      try container.encode(Mode.bearer, forKey: .mode)
      try container.encode(service, forKey: .keychainService)
      try container.encode(account, forKey: .keychainAccount)
    case .mtls(let identityLabel):
      try container.encode(Mode.mtls, forKey: .mode)
      try container.encode(identityLabel, forKey: .identityLabel)
    }
  }
}

struct AgentConfig: Codable, Sendable {
  var deviceId: String
  var organizationId: String
  var workspaceId: String?
  var userId: String?
  var projectId: String?
  var repository: String?
  var metadata: [String: String]
  var endpoint: URL
  var allowedBundleIds: [String]
  var deniedBundleIds: [String]
  var deniedPathPrefixes: [String]
  var pauseWindowTitlePatterns: [String]
  var captureFps: Double
  var idleFps: Double
  var batchIntervalSeconds: Double
  var maxFramesPerBatch: Int
  var maxOcrTextChars: Int
  var maxBatchBytes: Int64
  var maxBatchAgeDays: Double
  var idleThresholdSeconds: Double
  var idlePollSeconds: Double
  var adaptiveOcrMinChars: Int
  var adaptiveOcrBackpressureThreshold: Int
  var adaptiveOcrBacklogBytes: Int64
  var localOnly: Bool
  var encryptLocalBatches: Bool
  var auth: AuthMode
  var secretBroker: SecretBrokerConfig?

  enum CodingKeys: String, CodingKey {
    case deviceId
    case organizationId
    case orgId
    case workspaceId
    case userId
    case projectId
    case repository
    case metadata
    case endpoint
    case allowedBundleIds
    case deniedBundleIds
    case deniedPathPrefixes
    case pauseWindowTitlePatterns
    case captureFps
    case idleFps
    case batchIntervalSeconds
    case maxFramesPerBatch
    case maxOcrTextChars
    case maxBatchBytes
    case maxBatchAgeDays
    case idleThresholdSeconds
    case idlePollSeconds
    case adaptiveOcrMinChars
    case adaptiveOcrBackpressureThreshold
    case adaptiveOcrBacklogBytes
    case localOnly
    case encryptLocalBatches
    case auth
    case secretBroker
  }

  init(
    deviceId: String,
    organizationId: String,
    workspaceId: String? = nil,
    userId: String? = nil,
    projectId: String? = nil,
    repository: String? = nil,
    metadata: [String: String] = [:],
    endpoint: URL,
    allowedBundleIds: [String],
    deniedBundleIds: [String],
    deniedPathPrefixes: [String],
    pauseWindowTitlePatterns: [String],
    captureFps: Double,
    idleFps: Double,
    batchIntervalSeconds: Double,
    maxFramesPerBatch: Int,
    maxOcrTextChars: Int = 4096,
    maxBatchBytes: Int64 = 512 * 1024 * 1024,
    maxBatchAgeDays: Double = 7,
    idleThresholdSeconds: Double = 60,
    idlePollSeconds: Double = 5,
    adaptiveOcrMinChars: Int = 1024,
    adaptiveOcrBackpressureThreshold: Int = 8,
    adaptiveOcrBacklogBytes: Int64 = 64 * 1024 * 1024,
    localOnly: Bool,
    encryptLocalBatches: Bool? = nil,
    auth: AuthMode = .none,
    secretBroker: SecretBrokerConfig? = nil
  ) {
    self.deviceId = deviceId
    self.organizationId = organizationId
    self.workspaceId = workspaceId
    self.userId = userId
    self.projectId = projectId
    self.repository = repository
    self.metadata = Self.cleanMetadata(metadata)
    self.endpoint = endpoint
    self.allowedBundleIds = allowedBundleIds
    self.deniedBundleIds = deniedBundleIds
    self.deniedPathPrefixes = deniedPathPrefixes
    self.pauseWindowTitlePatterns = pauseWindowTitlePatterns
    self.captureFps = captureFps
    self.idleFps = idleFps
    self.batchIntervalSeconds = batchIntervalSeconds
    self.maxFramesPerBatch = maxFramesPerBatch
    self.maxOcrTextChars = maxOcrTextChars
    self.maxBatchBytes = maxBatchBytes
    self.maxBatchAgeDays = maxBatchAgeDays
    self.idleThresholdSeconds = idleThresholdSeconds
    self.idlePollSeconds = idlePollSeconds
    self.adaptiveOcrMinChars = adaptiveOcrMinChars
    self.adaptiveOcrBackpressureThreshold = adaptiveOcrBackpressureThreshold
    self.adaptiveOcrBacklogBytes = adaptiveOcrBacklogBytes
    self.localOnly = localOnly
    self.encryptLocalBatches = encryptLocalBatches ?? (!localOnly || secretBroker != nil)
    self.auth = auth
    self.secretBroker = secretBroker
  }

  func applying(policy: CapturePolicy) -> AgentConfig {
    var next = self

    if !policy.allowedBundleIds.isEmpty {
      next.allowedBundleIds = policy.allowedBundleIds
    }

    next.deniedBundleIds = Self.mergePolicyList(
      defaultValues: Self.defaultDeniedBundleIds,
      currentValues: deniedBundleIds,
      policyValues: policy.deniedBundleIds
    )
    next.deniedPathPrefixes = Self.mergePolicyList(
      defaultValues: Self.defaultDeniedPathPrefixes,
      currentValues: deniedPathPrefixes,
      policyValues: policy.deniedPathPrefixes
    )
    next.pauseWindowTitlePatterns = Self.mergePolicyList(
      defaultValues: Self.defaultPauseWindowPatterns,
      currentValues: pauseWindowTitlePatterns,
      policyValues: policy.pauseWindowTitlePatterns
    )

    if policy.minBatchIntervalSeconds > 0 {
      next.batchIntervalSeconds = max(batchIntervalSeconds, Double(policy.minBatchIntervalSeconds))
    }
    if policy.maxFramesPerBatch > 0 {
      next.maxFramesPerBatch = policy.maxFramesPerBatch
    }

    return next
  }

  private static func mergePolicyList(
    defaultValues: [String],
    currentValues: [String],
    policyValues: [String]
  ) -> [String] {
    var seen = Set<String>()
    var merged: [String] = []
    for value in defaultValues + currentValues + policyValues where !value.isEmpty {
      if seen.insert(value).inserted {
        merged.append(value)
      }
    }
    return merged
  }

  private static func cleanMetadata(_ metadata: [String: String]) -> [String: String] {
    var cleaned: [String: String] = [:]
    for (rawKey, rawValue) in metadata {
      let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
      let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if key.isEmpty || value.isEmpty {
        continue
      }
      cleaned[key] = value
    }
    return cleaned
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceId = try container.decode(String.self, forKey: .deviceId)
    organizationId =
      try container.decodeIfPresent(String.self, forKey: .organizationId)
      ?? container.decodeIfPresent(String.self, forKey: .orgId)
      ?? "local"
    workspaceId = try container.decodeIfPresent(String.self, forKey: .workspaceId)
    userId = try container.decodeIfPresent(String.self, forKey: .userId)
    projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
    repository = try container.decodeIfPresent(String.self, forKey: .repository)
    metadata = Self.cleanMetadata(
      try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    )
    endpoint = try container.decode(URL.self, forKey: .endpoint)
    allowedBundleIds =
      try container.decodeIfPresent([String].self, forKey: .allowedBundleIds)
      ?? Self.defaultAllowedBundleIds
    deniedBundleIds =
      try container.decodeIfPresent([String].self, forKey: .deniedBundleIds)
      ?? Self.defaultDeniedBundleIds
    deniedPathPrefixes =
      try container.decodeIfPresent([String].self, forKey: .deniedPathPrefixes)
      ?? Self.defaultDeniedPathPrefixes
    pauseWindowTitlePatterns =
      try container.decodeIfPresent([String].self, forKey: .pauseWindowTitlePatterns)
      ?? Self.defaultPauseWindowPatterns
    captureFps = try container.decodeIfPresent(Double.self, forKey: .captureFps) ?? 1.0
    idleFps = try container.decodeIfPresent(Double.self, forKey: .idleFps) ?? 0.2
    batchIntervalSeconds =
      try container.decodeIfPresent(Double.self, forKey: .batchIntervalSeconds) ?? 30
    maxFramesPerBatch = try container.decodeIfPresent(Int.self, forKey: .maxFramesPerBatch) ?? 24
    maxOcrTextChars = try container.decodeIfPresent(Int.self, forKey: .maxOcrTextChars) ?? 4096
    maxBatchBytes =
      try container.decodeIfPresent(Int64.self, forKey: .maxBatchBytes) ?? 512 * 1024 * 1024
    maxBatchAgeDays = try container.decodeIfPresent(Double.self, forKey: .maxBatchAgeDays) ?? 7
    idleThresholdSeconds =
      try container.decodeIfPresent(Double.self, forKey: .idleThresholdSeconds) ?? 60
    idlePollSeconds = try container.decodeIfPresent(Double.self, forKey: .idlePollSeconds) ?? 5
    adaptiveOcrMinChars =
      try container.decodeIfPresent(Int.self, forKey: .adaptiveOcrMinChars) ?? 1024
    adaptiveOcrBackpressureThreshold =
      try container.decodeIfPresent(Int.self, forKey: .adaptiveOcrBackpressureThreshold) ?? 8
    adaptiveOcrBacklogBytes =
      try container.decodeIfPresent(Int64.self, forKey: .adaptiveOcrBacklogBytes)
      ?? 64 * 1024 * 1024
    localOnly = try container.decodeIfPresent(Bool.self, forKey: .localOnly) ?? true
    auth = try container.decodeIfPresent(AuthMode.self, forKey: .auth) ?? .none
    secretBroker = try container.decodeIfPresent(SecretBrokerConfig.self, forKey: .secretBroker)
    encryptLocalBatches =
      try container.decodeIfPresent(Bool.self, forKey: .encryptLocalBatches)
      ?? (!localOnly || secretBroker != nil)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(deviceId, forKey: .deviceId)
    try container.encode(organizationId, forKey: .organizationId)
    try container.encodeIfPresent(workspaceId, forKey: .workspaceId)
    try container.encodeIfPresent(userId, forKey: .userId)
    try container.encodeIfPresent(projectId, forKey: .projectId)
    try container.encodeIfPresent(repository, forKey: .repository)
    if !metadata.isEmpty {
      try container.encode(metadata, forKey: .metadata)
    }
    try container.encode(endpoint, forKey: .endpoint)
    try container.encode(allowedBundleIds, forKey: .allowedBundleIds)
    try container.encode(deniedBundleIds, forKey: .deniedBundleIds)
    try container.encode(deniedPathPrefixes, forKey: .deniedPathPrefixes)
    try container.encode(pauseWindowTitlePatterns, forKey: .pauseWindowTitlePatterns)
    try container.encode(captureFps, forKey: .captureFps)
    try container.encode(idleFps, forKey: .idleFps)
    try container.encode(batchIntervalSeconds, forKey: .batchIntervalSeconds)
    try container.encode(maxFramesPerBatch, forKey: .maxFramesPerBatch)
    try container.encode(maxOcrTextChars, forKey: .maxOcrTextChars)
    try container.encode(maxBatchBytes, forKey: .maxBatchBytes)
    try container.encode(maxBatchAgeDays, forKey: .maxBatchAgeDays)
    try container.encode(idleThresholdSeconds, forKey: .idleThresholdSeconds)
    try container.encode(idlePollSeconds, forKey: .idlePollSeconds)
    try container.encode(adaptiveOcrMinChars, forKey: .adaptiveOcrMinChars)
    try container.encode(
      adaptiveOcrBackpressureThreshold, forKey: .adaptiveOcrBackpressureThreshold)
    try container.encode(adaptiveOcrBacklogBytes, forKey: .adaptiveOcrBacklogBytes)
    try container.encode(localOnly, forKey: .localOnly)
    try container.encode(encryptLocalBatches, forKey: .encryptLocalBatches)
    try container.encode(auth, forKey: .auth)
    try container.encodeIfPresent(secretBroker, forKey: .secretBroker)
  }

  static let defaultAllowedBundleIds: [String] = [
    "com.apple.dt.Xcode",
    "com.microsoft.VSCode",
    "com.todesktop.230313mzl4w4u92",  // Cursor
    "com.googlecode.iterm2",
    "com.apple.Terminal",
    "dev.warp.Warp-Stable",
    "company.thebrowser.Browser",  // Arc
    "com.google.Chrome",
    "com.apple.Safari",
    "org.mozilla.firefox",
    "com.linear.LinearDesktop",
    "com.tinyspeck.slackmacgap",
  ]

  static let defaultDeniedBundleIds: [String] = [
    "com.agilebits.onepassword7",
    "com.agilebits.onepassword-osx",
    "com.bitwarden.desktop",
    "com.lastpass.LastPass",
    "com.dashlane.dashlanephonefinal",
    "com.apple.keychainaccess",
  ]

  static let defaultDeniedPathPrefixes: [String] = [
    ".ssh", ".aws", ".config/gcloud", ".gnupg",
    ".kube", ".docker/config.json",
    "Library/Keychains",
  ]

  static let defaultPauseWindowPatterns: [String] = [
    "Zoom Meeting", "Meet - ", "meet.google.com", "FaceTime", "Google Meet",
    "1Password", "Bitwarden", "Keychain Access",
    "Private Browsing", "Private", "Incognito",
  ]

  static func fallback() -> AgentConfig {
    AgentConfig(
      deviceId: ProcessInfo.processInfo.globallyUniqueString,
      organizationId: "local",
      endpoint: URL(string: "http://127.0.0.1:8787/chronicle.v1.ChronicleService/SubmitBatch")!,
      allowedBundleIds: defaultAllowedBundleIds,
      deniedBundleIds: defaultDeniedBundleIds,
      deniedPathPrefixes: defaultDeniedPathPrefixes,
      pauseWindowTitlePatterns: defaultPauseWindowPatterns,
      captureFps: 1.0,
      idleFps: 0.2,
      batchIntervalSeconds: 30,
      maxFramesPerBatch: 24,
      maxOcrTextChars: 4096,
      maxBatchBytes: 512 * 1024 * 1024,
      maxBatchAgeDays: 7,
      idleThresholdSeconds: 60,
      idlePollSeconds: 5,
      adaptiveOcrMinChars: 1024,
      adaptiveOcrBackpressureThreshold: 8,
      adaptiveOcrBacklogBytes: 64 * 1024 * 1024,
      localOnly: true,
      encryptLocalBatches: false,
      auth: .none,
      secretBroker: nil
    )
  }
}

struct SecretBrokerConfig: Codable, Sendable, Equatable {
  var endpoint: URL
  var sessionTokenKeychainService: String
  var sessionTokenKeychainAccount: String
  var ttlSeconds: Int
  var tool: String
  var capability: String
  var reason: String

  enum CodingKeys: String, CodingKey {
    case endpoint
    case sessionTokenKeychainService
    case sessionTokenKeychainAccount
    case ttlSeconds
    case tool
    case capability
    case reason
  }

  init(
    endpoint: URL,
    sessionTokenKeychainService: String,
    sessionTokenKeychainAccount: String,
    ttlSeconds: Int = 300,
    tool: String = "chronicle.agentd",
    capability: String = "chronicle.frame_batch",
    reason: String = "agentd Chronicle frame batch"
  ) {
    self.endpoint = endpoint
    self.sessionTokenKeychainService = sessionTokenKeychainService
    self.sessionTokenKeychainAccount = sessionTokenKeychainAccount
    self.ttlSeconds = ttlSeconds
    self.tool = tool
    self.capability = capability
    self.reason = reason
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      endpoint: try container.decode(URL.self, forKey: .endpoint),
      sessionTokenKeychainService: try container.decode(
        String.self,
        forKey: .sessionTokenKeychainService
      ),
      sessionTokenKeychainAccount: try container.decode(
        String.self,
        forKey: .sessionTokenKeychainAccount
      ),
      ttlSeconds: try container.decodeIfPresent(Int.self, forKey: .ttlSeconds) ?? 300,
      tool: try container.decodeIfPresent(String.self, forKey: .tool) ?? "chronicle.agentd",
      capability: try container.decodeIfPresent(String.self, forKey: .capability)
        ?? "chronicle.frame_batch",
      reason: try container.decodeIfPresent(String.self, forKey: .reason)
        ?? "agentd Chronicle frame batch"
    )
  }
}

enum ConfigStore {
  static var path: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".evalops/agentd/config.json")
  }

  static func load() -> AgentConfig {
    guard let data = try? Data(contentsOf: path),
      let cfg = try? JSONDecoder().decode(AgentConfig.self, from: data)
    else {
      let fallback = AgentConfig.fallback()
      try? save(fallback)
      return fallback
    }
    return cfg
  }

  static func save(_ cfg: AgentConfig) throws {
    let dir = path.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(cfg).write(to: path, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
  }
}
