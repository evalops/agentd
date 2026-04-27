import Foundation

struct AgentConfig: Codable, Sendable {
    var deviceId: String
    var orgId: String
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
            orgId: "local",
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
