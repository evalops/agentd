import Foundation

struct AgentConfig: Codable, Sendable {
    var deviceId: String
    var organizationId: String
    var workspaceId: String?
    var userId: String?
    var projectId: String?
    var repository: String?
    var endpoint: URL
    var allowedBundleIds: [String]
    var deniedBundleIds: [String]
    var deniedPathPrefixes: [String]
    var pauseWindowTitlePatterns: [String]
    var captureFps: Double
    var idleFps: Double
    var batchIntervalSeconds: Double
    var maxFramesPerBatch: Int
    var localOnly: Bool

    enum CodingKeys: String, CodingKey {
        case deviceId
        case organizationId
        case orgId
        case workspaceId
        case userId
        case projectId
        case repository
        case endpoint
        case allowedBundleIds
        case deniedBundleIds
        case deniedPathPrefixes
        case pauseWindowTitlePatterns
        case captureFps
        case idleFps
        case batchIntervalSeconds
        case maxFramesPerBatch
        case localOnly
    }

    init(
        deviceId: String,
        organizationId: String,
        workspaceId: String? = nil,
        userId: String? = nil,
        projectId: String? = nil,
        repository: String? = nil,
        endpoint: URL,
        allowedBundleIds: [String],
        deniedBundleIds: [String],
        deniedPathPrefixes: [String],
        pauseWindowTitlePatterns: [String],
        captureFps: Double,
        idleFps: Double,
        batchIntervalSeconds: Double,
        maxFramesPerBatch: Int,
        localOnly: Bool
    ) {
        self.deviceId = deviceId
        self.organizationId = organizationId
        self.workspaceId = workspaceId
        self.userId = userId
        self.projectId = projectId
        self.repository = repository
        self.endpoint = endpoint
        self.allowedBundleIds = allowedBundleIds
        self.deniedBundleIds = deniedBundleIds
        self.deniedPathPrefixes = deniedPathPrefixes
        self.pauseWindowTitlePatterns = pauseWindowTitlePatterns
        self.captureFps = captureFps
        self.idleFps = idleFps
        self.batchIntervalSeconds = batchIntervalSeconds
        self.maxFramesPerBatch = maxFramesPerBatch
        self.localOnly = localOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        organizationId = try container.decodeIfPresent(String.self, forKey: .organizationId)
            ?? container.decodeIfPresent(String.self, forKey: .orgId)
            ?? "local"
        workspaceId = try container.decodeIfPresent(String.self, forKey: .workspaceId)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
        repository = try container.decodeIfPresent(String.self, forKey: .repository)
        endpoint = try container.decode(URL.self, forKey: .endpoint)
        allowedBundleIds = try container.decodeIfPresent([String].self, forKey: .allowedBundleIds) ?? Self.defaultAllowedBundleIds
        deniedBundleIds = try container.decodeIfPresent([String].self, forKey: .deniedBundleIds) ?? Self.defaultDeniedBundleIds
        deniedPathPrefixes = try container.decodeIfPresent([String].self, forKey: .deniedPathPrefixes) ?? Self.defaultDeniedPathPrefixes
        pauseWindowTitlePatterns = try container.decodeIfPresent([String].self, forKey: .pauseWindowTitlePatterns) ?? Self.defaultPauseWindowPatterns
        captureFps = try container.decodeIfPresent(Double.self, forKey: .captureFps) ?? 1.0
        idleFps = try container.decodeIfPresent(Double.self, forKey: .idleFps) ?? 0.2
        batchIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .batchIntervalSeconds) ?? 30
        maxFramesPerBatch = try container.decodeIfPresent(Int.self, forKey: .maxFramesPerBatch) ?? 24
        localOnly = try container.decodeIfPresent(Bool.self, forKey: .localOnly) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(organizationId, forKey: .organizationId)
        try container.encodeIfPresent(workspaceId, forKey: .workspaceId)
        try container.encodeIfPresent(userId, forKey: .userId)
        try container.encodeIfPresent(projectId, forKey: .projectId)
        try container.encodeIfPresent(repository, forKey: .repository)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(allowedBundleIds, forKey: .allowedBundleIds)
        try container.encode(deniedBundleIds, forKey: .deniedBundleIds)
        try container.encode(deniedPathPrefixes, forKey: .deniedPathPrefixes)
        try container.encode(pauseWindowTitlePatterns, forKey: .pauseWindowTitlePatterns)
        try container.encode(captureFps, forKey: .captureFps)
        try container.encode(idleFps, forKey: .idleFps)
        try container.encode(batchIntervalSeconds, forKey: .batchIntervalSeconds)
        try container.encode(maxFramesPerBatch, forKey: .maxFramesPerBatch)
        try container.encode(localOnly, forKey: .localOnly)
    }

    static let defaultAllowedBundleIds: [String] = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "dev.warp.Warp-Stable",
        "company.thebrowser.Browser",       // Arc
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.linear.LinearDesktop",
        "com.tinyspeck.slackmacgap"
    ]

    static let defaultDeniedBundleIds: [String] = [
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "com.apple.keychainaccess"
    ]

    static let defaultDeniedPathPrefixes: [String] = [
        ".ssh", ".aws", ".config/gcloud", ".gnupg",
        ".kube", ".docker/config.json",
        "Library/Keychains"
    ]

    static let defaultPauseWindowPatterns: [String] = [
        "Zoom Meeting", "FaceTime", "Google Meet",
        "1Password", "Bitwarden", "Keychain Access",
        "Private", "Incognito"
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
            localOnly: true
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
