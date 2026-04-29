// SPDX-License-Identifier: BUSL-1.1

import Foundation

enum ForegroundPrivacyPauseDetector {
  static func reason(context: WindowContext?, config: AgentConfig) -> String? {
    guard let context else { return nil }

    if config.pauseWindowTitlePatterns.contains(where: { pattern in
      !pattern.isEmpty && context.windowTitle.localizedCaseInsensitiveContains(pattern)
    }) {
      return "window_title_pattern"
    }
    if isProtectedApplication(context.appName) {
      return "protected_application"
    }
    if isProtectedURL(context.documentPath) || isProtectedURL(context.windowTitle) {
      return "protected_content_url"
    }
    if isProtectedTitle(context.windowTitle) {
      return "protected_content_title"
    }
    return nil
  }

  static func isProtectedApplication(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return false }
    if normalized == "max" {
      return true
    }
    return protectedApplicationFragments.contains { normalized.contains($0) }
  }

  static func isProtectedTitle(_ value: String) -> Bool {
    let normalized = value.lowercased()
    guard !normalized.isEmpty else { return false }
    return protectedTitleFragments.contains { normalized.contains($0) }
  }

  static func isProtectedURL(_ value: String?) -> Bool {
    guard let value, !value.isEmpty else { return false }
    let lower = value.lowercased()
    guard lower.contains("://") || protectedDomains.contains(where: { lower.contains($0) })
    else {
      return false
    }
    guard let components = URLComponents(string: lower),
      let rawHost = components.host
    else {
      return protectedDomains.contains { lower.contains($0) }
    }
    let host = rawHost.replacingOccurrences(of: "www.", with: "")
    return protectedDomains.contains { domain in
      host == domain || host.hasSuffix(".\(domain)")
    } || (host == "amazon.com" && components.path.hasPrefix("/gp/video/"))
  }

  private static let protectedApplicationFragments: [String] = [
    "netflix",
    "disney+",
    "hulu",
    "prime video",
    "apple tv",
    "peacock",
    "paramount+",
    "hbo max",
    "crunchyroll",
    "dazn",
    "horizon client",
    "vmware horizon",
    "omnissa horizon",
  ]

  private static let protectedTitleFragments: [String] = [
    "netflix",
    "disney+",
    "hulu",
    "prime video",
    "apple tv",
    "peacock",
    "paramount+",
    "hbo max",
    "crunchyroll",
    "dazn",
  ]

  private static let protectedDomains: [String] = [
    "netflix.com",
    "disneyplus.com",
    "hulu.com",
    "primevideo.com",
    "tv.apple.com",
    "peacocktv.com",
    "paramountplus.com",
    "play.max.com",
    "crunchyroll.com",
    "dazn.com",
  ]
}
