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
  var domainTiers: [DomainTier]
  var perBundleProfiles: [BundleCaptureProfile]
  var behavioralClassification: BehavioralClassification
  var contextExtractors: [ContextExtractor]
  var thrashAlerts: [ThrashRule]
  var sessionBoundaryHooks: BoundaryHookConfig
  var captureAllDisplays: Bool
  var selectedDisplayIds: [UInt32]
  var captureFps: Double
  var idleFps: Double
  var batchIntervalSeconds: Double
  var maxFramesPerBatch: Int
  var maxOcrTextChars: Int
  var maxBatchBytes: Int64
  var maxBatchAgeDays: Double
  var idleThresholdSeconds: Double
  var urlChangeIdleThresholdSeconds: Double
  var idlePollSeconds: Double
  var adaptiveOcrMinChars: Int
  var adaptiveOcrBackpressureThreshold: Int
  var adaptiveOcrBacklogBytes: Int64
  var ocrDiffSamplerEnabled: Bool
  var ocrDiffSimilarityThreshold: Double
  var eventCaptureEnabled: Bool
  var eventCapturePollSeconds: Double
  var eventCaptureDebounceSeconds: Double
  var eventCaptureMinGapSeconds: Double
  var eventCaptureIdleFallbackSeconds: Double
  var eventCaptureTimeoutSeconds: Double
  var sparseFrameStorageRoot: String?
  var sparseFrameRetentionHours: Double
  var sparseFrameIncludeOcrText: Bool
  var sparseFrameVisualRedactionEnabled: Bool
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
    case domainTiers
    case perBundleProfiles
    case behavioralClassification
    case contextExtractors
    case thrashAlerts
    case sessionBoundaryHooks
    case captureAllDisplays
    case selectedDisplayIds
    case captureFps
    case idleFps
    case batchIntervalSeconds
    case maxFramesPerBatch
    case maxOcrTextChars
    case maxBatchBytes
    case maxBatchAgeDays
    case idleThresholdSeconds
    case urlChangeIdleThresholdSeconds
    case idlePollSeconds
    case adaptiveOcrMinChars
    case adaptiveOcrBackpressureThreshold
    case adaptiveOcrBacklogBytes
    case ocrDiffSamplerEnabled
    case ocrDiffSimilarityThreshold
    case eventCaptureEnabled
    case eventCapturePollSeconds
    case eventCaptureDebounceSeconds
    case eventCaptureMinGapSeconds
    case eventCaptureIdleFallbackSeconds
    case eventCaptureTimeoutSeconds
    case sparseFrameStorageRoot
    case sparseFrameRetentionHours
    case sparseFrameIncludeOcrText
    case sparseFrameVisualRedactionEnabled
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
    domainTiers: [DomainTier] = Self.defaultDomainTiers,
    perBundleProfiles: [BundleCaptureProfile] = [],
    behavioralClassification: BehavioralClassification = .default,
    contextExtractors: [ContextExtractor] = ContextExtractor.defaults,
    thrashAlerts: [ThrashRule] = [.githubPR],
    sessionBoundaryHooks: BoundaryHookConfig = .default,
    captureAllDisplays: Bool = false,
    selectedDisplayIds: [UInt32] = [],
    captureFps: Double,
    idleFps: Double,
    batchIntervalSeconds: Double,
    maxFramesPerBatch: Int,
    maxOcrTextChars: Int = 4096,
    maxBatchBytes: Int64 = 512 * 1024 * 1024,
    maxBatchAgeDays: Double = 7,
    idleThresholdSeconds: Double = 60,
    urlChangeIdleThresholdSeconds: Double = 30,
    idlePollSeconds: Double = 5,
    adaptiveOcrMinChars: Int = 1024,
    adaptiveOcrBackpressureThreshold: Int = 8,
    adaptiveOcrBacklogBytes: Int64 = 64 * 1024 * 1024,
    ocrDiffSamplerEnabled: Bool = false,
    ocrDiffSimilarityThreshold: Double = 0.92,
    eventCaptureEnabled: Bool = false,
    eventCapturePollSeconds: Double = 0.5,
    eventCaptureDebounceSeconds: Double = 0.25,
    eventCaptureMinGapSeconds: Double = 1,
    eventCaptureIdleFallbackSeconds: Double = 30,
    eventCaptureTimeoutSeconds: Double = 5,
    sparseFrameStorageRoot: String? = nil,
    sparseFrameRetentionHours: Double = 6,
    sparseFrameIncludeOcrText: Bool = false,
    sparseFrameVisualRedactionEnabled: Bool = false,
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
    self.metadata = EvalOpsContextMetadata.clean(metadata)
    self.endpoint = endpoint
    self.allowedBundleIds = allowedBundleIds
    self.deniedBundleIds = deniedBundleIds
    self.deniedPathPrefixes = deniedPathPrefixes
    self.pauseWindowTitlePatterns = pauseWindowTitlePatterns
    self.domainTiers = domainTiers
    self.perBundleProfiles = perBundleProfiles
    self.behavioralClassification = behavioralClassification
    self.contextExtractors = contextExtractors
    self.thrashAlerts = thrashAlerts
    self.sessionBoundaryHooks = sessionBoundaryHooks
    self.captureAllDisplays = captureAllDisplays
    self.selectedDisplayIds = selectedDisplayIds
    self.captureFps = captureFps
    self.idleFps = idleFps
    self.batchIntervalSeconds = batchIntervalSeconds
    self.maxFramesPerBatch = maxFramesPerBatch
    self.maxOcrTextChars = maxOcrTextChars
    self.maxBatchBytes = maxBatchBytes
    self.maxBatchAgeDays = maxBatchAgeDays
    self.idleThresholdSeconds = idleThresholdSeconds
    self.urlChangeIdleThresholdSeconds = urlChangeIdleThresholdSeconds
    self.idlePollSeconds = idlePollSeconds
    self.adaptiveOcrMinChars = adaptiveOcrMinChars
    self.adaptiveOcrBackpressureThreshold = adaptiveOcrBackpressureThreshold
    self.adaptiveOcrBacklogBytes = adaptiveOcrBacklogBytes
    self.ocrDiffSamplerEnabled = ocrDiffSamplerEnabled
    self.ocrDiffSimilarityThreshold = ocrDiffSimilarityThreshold
    self.eventCaptureEnabled = eventCaptureEnabled
    self.eventCapturePollSeconds = eventCapturePollSeconds
    self.eventCaptureDebounceSeconds = eventCaptureDebounceSeconds
    self.eventCaptureMinGapSeconds = eventCaptureMinGapSeconds
    self.eventCaptureIdleFallbackSeconds = eventCaptureIdleFallbackSeconds
    self.eventCaptureTimeoutSeconds = eventCaptureTimeoutSeconds
    self.sparseFrameStorageRoot = sparseFrameStorageRoot
    self.sparseFrameRetentionHours = sparseFrameRetentionHours
    self.sparseFrameIncludeOcrText = sparseFrameIncludeOcrText
    self.sparseFrameVisualRedactionEnabled = sparseFrameVisualRedactionEnabled
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
    if !policy.domainTiers.isEmpty {
      next.domainTiers = policy.domainTiers
    }
    if !policy.perBundleProfiles.isEmpty {
      next.perBundleProfiles = policy.perBundleProfiles
    }
    if let behavioralClassification = policy.behavioralClassification {
      next.behavioralClassification = behavioralClassification
    }
    if !policy.contextExtractors.isEmpty {
      next.contextExtractors = policy.contextExtractors
    }
    if !policy.thrashAlerts.isEmpty {
      next.thrashAlerts = policy.thrashAlerts
    }
    if let hooks = policy.sessionBoundaryHooks {
      next.sessionBoundaryHooks = hooks
    }

    if policy.captureAllDisplays != nil {
      next.captureAllDisplays = policy.captureAllDisplays == true
    }
    if let selectedDisplayIds = policy.selectedDisplayIds {
      next.selectedDisplayIds = selectedDisplayIds
    }

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
    metadata = EvalOpsContextMetadata.clean(
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
    domainTiers =
      try container.decodeIfPresent([DomainTier].self, forKey: .domainTiers)
      ?? Self.defaultDomainTiers
    perBundleProfiles =
      try container.decodeIfPresent([BundleCaptureProfile].self, forKey: .perBundleProfiles) ?? []
    behavioralClassification =
      try container.decodeIfPresent(
        BehavioralClassification.self,
        forKey: .behavioralClassification
      ) ?? .default
    contextExtractors =
      try container.decodeIfPresent([ContextExtractor].self, forKey: .contextExtractors)
      ?? ContextExtractor.defaults
    thrashAlerts =
      try container.decodeIfPresent([ThrashRule].self, forKey: .thrashAlerts) ?? [.githubPR]
    sessionBoundaryHooks =
      try container.decodeIfPresent(BoundaryHookConfig.self, forKey: .sessionBoundaryHooks)
      ?? .default
    captureAllDisplays =
      try container.decodeIfPresent(Bool.self, forKey: .captureAllDisplays) ?? false
    selectedDisplayIds =
      try container.decodeIfPresent([UInt32].self, forKey: .selectedDisplayIds) ?? []
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
    urlChangeIdleThresholdSeconds =
      try container.decodeIfPresent(Double.self, forKey: .urlChangeIdleThresholdSeconds) ?? 30
    idlePollSeconds = try container.decodeIfPresent(Double.self, forKey: .idlePollSeconds) ?? 5
    adaptiveOcrMinChars =
      try container.decodeIfPresent(Int.self, forKey: .adaptiveOcrMinChars) ?? 1024
    adaptiveOcrBackpressureThreshold =
      try container.decodeIfPresent(Int.self, forKey: .adaptiveOcrBackpressureThreshold) ?? 8
    adaptiveOcrBacklogBytes =
      try container.decodeIfPresent(Int64.self, forKey: .adaptiveOcrBacklogBytes)
      ?? 64 * 1024 * 1024
    ocrDiffSamplerEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .ocrDiffSamplerEnabled) ?? false
    ocrDiffSimilarityThreshold =
      try container.decodeIfPresent(Double.self, forKey: .ocrDiffSimilarityThreshold) ?? 0.92
    eventCaptureEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .eventCaptureEnabled) ?? false
    eventCapturePollSeconds =
      try container.decodeIfPresent(Double.self, forKey: .eventCapturePollSeconds) ?? 0.5
    eventCaptureDebounceSeconds =
      try container.decodeIfPresent(Double.self, forKey: .eventCaptureDebounceSeconds) ?? 0.25
    eventCaptureMinGapSeconds =
      try container.decodeIfPresent(Double.self, forKey: .eventCaptureMinGapSeconds) ?? 1
    eventCaptureIdleFallbackSeconds =
      try container.decodeIfPresent(Double.self, forKey: .eventCaptureIdleFallbackSeconds) ?? 30
    eventCaptureTimeoutSeconds =
      try container.decodeIfPresent(Double.self, forKey: .eventCaptureTimeoutSeconds) ?? 5
    sparseFrameStorageRoot = try container.decodeIfPresent(
      String.self, forKey: .sparseFrameStorageRoot)
    sparseFrameRetentionHours =
      try container.decodeIfPresent(Double.self, forKey: .sparseFrameRetentionHours) ?? 6
    sparseFrameIncludeOcrText =
      try container.decodeIfPresent(Bool.self, forKey: .sparseFrameIncludeOcrText) ?? false
    sparseFrameVisualRedactionEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .sparseFrameVisualRedactionEnabled) ?? false
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
    try container.encode(domainTiers, forKey: .domainTiers)
    if !perBundleProfiles.isEmpty {
      try container.encode(perBundleProfiles, forKey: .perBundleProfiles)
    }
    try container.encode(behavioralClassification, forKey: .behavioralClassification)
    try container.encode(contextExtractors, forKey: .contextExtractors)
    try container.encode(thrashAlerts, forKey: .thrashAlerts)
    try container.encode(sessionBoundaryHooks, forKey: .sessionBoundaryHooks)
    try container.encode(captureAllDisplays, forKey: .captureAllDisplays)
    if !selectedDisplayIds.isEmpty {
      try container.encode(selectedDisplayIds, forKey: .selectedDisplayIds)
    }
    try container.encode(captureFps, forKey: .captureFps)
    try container.encode(idleFps, forKey: .idleFps)
    try container.encode(batchIntervalSeconds, forKey: .batchIntervalSeconds)
    try container.encode(maxFramesPerBatch, forKey: .maxFramesPerBatch)
    try container.encode(maxOcrTextChars, forKey: .maxOcrTextChars)
    try container.encode(maxBatchBytes, forKey: .maxBatchBytes)
    try container.encode(maxBatchAgeDays, forKey: .maxBatchAgeDays)
    try container.encode(idleThresholdSeconds, forKey: .idleThresholdSeconds)
    try container.encode(urlChangeIdleThresholdSeconds, forKey: .urlChangeIdleThresholdSeconds)
    try container.encode(idlePollSeconds, forKey: .idlePollSeconds)
    try container.encode(adaptiveOcrMinChars, forKey: .adaptiveOcrMinChars)
    try container.encode(
      adaptiveOcrBackpressureThreshold, forKey: .adaptiveOcrBackpressureThreshold)
    try container.encode(adaptiveOcrBacklogBytes, forKey: .adaptiveOcrBacklogBytes)
    try container.encode(ocrDiffSamplerEnabled, forKey: .ocrDiffSamplerEnabled)
    try container.encode(ocrDiffSimilarityThreshold, forKey: .ocrDiffSimilarityThreshold)
    try container.encode(eventCaptureEnabled, forKey: .eventCaptureEnabled)
    try container.encode(eventCapturePollSeconds, forKey: .eventCapturePollSeconds)
    try container.encode(eventCaptureDebounceSeconds, forKey: .eventCaptureDebounceSeconds)
    try container.encode(eventCaptureMinGapSeconds, forKey: .eventCaptureMinGapSeconds)
    try container.encode(eventCaptureIdleFallbackSeconds, forKey: .eventCaptureIdleFallbackSeconds)
    try container.encode(eventCaptureTimeoutSeconds, forKey: .eventCaptureTimeoutSeconds)
    try container.encodeIfPresent(sparseFrameStorageRoot, forKey: .sparseFrameStorageRoot)
    try container.encode(sparseFrameRetentionHours, forKey: .sparseFrameRetentionHours)
    try container.encode(sparseFrameIncludeOcrText, forKey: .sparseFrameIncludeOcrText)
    try container.encode(
      sparseFrameVisualRedactionEnabled, forKey: .sparseFrameVisualRedactionEnabled)
    try container.encode(localOnly, forKey: .localOnly)
    try container.encode(encryptLocalBatches, forKey: .encryptLocalBatches)
    try container.encode(auth, forKey: .auth)
    try container.encodeIfPresent(secretBroker, forKey: .secretBroker)
  }

  static let defaultAllowedBundleIds: [String] = [
    "com.apple.dt.Xcode",
    "com.microsoft.VSCode",
    "com.todesktop.230313mzl4w4u92",  // Cursor
    "com.todesktop.230313mzl4w4u92.helper",  // Cursor helpers can be foreground in terminals
    "com.googlecode.iterm2",
    "com.apple.Terminal",
    "com.mitchellh.ghostty",
    "dev.warp.Warp-Stable",
    "com.openai.codex",
    "com.openai.chat",
    "com.anthropic.claudefordesktop",
    "company.thebrowser.Browser",  // Arc
    "com.google.Chrome",
    "com.google.Chrome.beta",
    "com.google.Chrome.canary",
    "com.google.Chrome.dev",
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
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

  static let defaultDomainTiers: [DomainTier] = [
    DomainTier(pattern: "github.com/*/pull/*", tier: .evidence),
    DomainTier(pattern: "github.com/*/issues/*", tier: .evidence),
    DomainTier(pattern: "x.com", tier: .audit),
    DomainTier(pattern: "twitter.com", tier: .audit),
    DomainTier(pattern: "youtube.com", tier: .audit),
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
      domainTiers: defaultDomainTiers,
      perBundleProfiles: [],
      behavioralClassification: .default,
      contextExtractors: ContextExtractor.defaults,
      thrashAlerts: [.githubPR],
      sessionBoundaryHooks: .default,
      captureAllDisplays: false,
      selectedDisplayIds: [],
      captureFps: 1.0,
      idleFps: 0.2,
      batchIntervalSeconds: 30,
      maxFramesPerBatch: 24,
      maxOcrTextChars: 4096,
      maxBatchBytes: 512 * 1024 * 1024,
      maxBatchAgeDays: 7,
      idleThresholdSeconds: 60,
      urlChangeIdleThresholdSeconds: 30,
      idlePollSeconds: 5,
      adaptiveOcrMinChars: 1024,
      adaptiveOcrBackpressureThreshold: 8,
      adaptiveOcrBacklogBytes: 64 * 1024 * 1024,
      ocrDiffSamplerEnabled: false,
      ocrDiffSimilarityThreshold: 0.92,
      eventCaptureEnabled: false,
      eventCapturePollSeconds: 0.5,
      eventCaptureDebounceSeconds: 0.25,
      eventCaptureMinGapSeconds: 1,
      eventCaptureIdleFallbackSeconds: 30,
      eventCaptureTimeoutSeconds: 5,
      sparseFrameStorageRoot: nil,
      sparseFrameRetentionHours: 6,
      sparseFrameIncludeOcrText: false,
      sparseFrameVisualRedactionEnabled: false,
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
