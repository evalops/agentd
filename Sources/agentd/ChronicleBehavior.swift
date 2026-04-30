// SPDX-License-Identifier: BUSL-1.1

import Foundation

enum CaptureTier: String, Sendable, Codable, Equatable {
  case evidence
  case audit
  case deny
}

struct DomainTier: Sendable, Codable, Equatable {
  var pattern: String
  var tier: CaptureTier
}

struct BundleCaptureProfile: Sendable, Codable, Equatable {
  var bundleId: String
  var captureFps: Double?
  var idleFps: Double?
  var eventDrivenOnly: Bool?
}

struct BehavioralClassification: Sendable, Codable, Equatable {
  var workDomains: [String]
  var leisureDomains: [String]
  var workBundleIds: [String]
  var leisureBundleIds: [String]

  static let `default` = BehavioralClassification(
    workDomains: ["github.com", "localhost", "127.0.0.1"],
    leisureDomains: ["x.com", "twitter.com", "youtube.com", "reddit.com"],
    workBundleIds: [
      "com.apple.dt.Xcode",
      "com.microsoft.VSCode",
      "com.todesktop.230313mzl4w4u92",
      "com.googlecode.iterm2",
      "com.apple.Terminal",
      "dev.warp.Warp-Stable",
      "com.openai.codex",
    ],
    leisureBundleIds: []
  )
}

struct ContextExtractor: Sendable, Codable, Equatable {
  var name: String
  var documentPattern: String
  var captureKey: String
  var lastPathSegments: Int?
  var regex: String?
  var captureGroup: Int?

  static let defaults: [ContextExtractor] = [
    ContextExtractor(
      name: "github-issue",
      documentPattern: "github.com/*/issues/*",
      captureKey: "activeIssue",
      lastPathSegments: 4,
      regex: nil,
      captureGroup: nil
    ),
    ContextExtractor(
      name: "github-pr",
      documentPattern: "github.com/*/pull/*",
      captureKey: "activePullRequest",
      lastPathSegments: 4,
      regex: nil,
      captureGroup: nil
    ),
  ]
}

struct ThrashRule: Sendable, Codable, Equatable {
  var name: String
  var domainPattern: String
  var windowSeconds: Int
  var distinctThreshold: Int

  static let githubPR = ThrashRule(
    name: "github-pr",
    domainPattern: "github.com/*/pull/*",
    windowSeconds: 600,
    distinctThreshold: 5
  )
}

struct BoundaryHookConfig: Sendable, Codable, Equatable {
  var foregroundChurnWindowSeconds: Int
  var foregroundChurnThreshold: Int

  static let `default` = BoundaryHookConfig(
    foregroundChurnWindowSeconds: 60,
    foregroundChurnThreshold: 8
  )
}

struct EmittedCounts: Sendable, Codable, Equatable {
  let distinctBundles: Int
  let distinctDomains: Int
  let distinctDocumentPaths: Int
  let distinctGithubPrs: Int
  let foregroundChanges: Int
  let documentChanges: Int
  let workLeisureFlips: Int
  let longestUninterruptedSeconds: Int
  let thrashEventCount: Int

  static let empty = EmittedCounts(
    distinctBundles: 0,
    distinctDomains: 0,
    distinctDocumentPaths: 0,
    distinctGithubPrs: 0,
    foregroundChanges: 0,
    documentChanges: 0,
    workLeisureFlips: 0,
    longestUninterruptedSeconds: 0,
    thrashEventCount: 0
  )
}

enum ChronicleBehavior {
  static func captureTier(for documentPath: String?, domainTiers: [DomainTier]) -> CaptureTier {
    guard let documentPath, !documentPath.isEmpty else { return .evidence }
    let matches = domainTiers.filter { globMatches($0.pattern, documentPath) }
    return matches.max { specificity($0.pattern) < specificity($1.pattern) }?.tier ?? .evidence
  }

  static func auditDocumentPath(_ documentPath: String?) -> String? {
    guard let documentPath, !documentPath.isEmpty else { return nil }
    guard let components = URLComponents(string: documentPath), let host = components.host else {
      return nil
    }
    let scheme = components.scheme.map { "\($0)://" } ?? ""
    return "\(scheme)\(host)"
  }

  static func emittedCounts(
    for frames: [ProcessedFrame],
    classification: BehavioralClassification,
    thrashRules: [ThrashRule]
  ) -> EmittedCounts {
    guard !frames.isEmpty else { return .empty }
    let sorted = frames.sorted { $0.capturedAt < $1.capturedAt }
    let bundles = Set(sorted.map(\.bundleId).filter { !$0.isEmpty })
    let documentPaths = Set(sorted.compactMap(\.documentPath).filter { !$0.isEmpty })
    let domains = Set(documentPaths.compactMap(host))
    let prs = Set(documentPaths.compactMap(githubPullRequestArtifact))
    var foregroundChanges = 0
    var documentChanges = 0
    var workLeisureFlips = 0
    var longest = 0.0
    var uninterruptedStart = sorted[0].capturedAt
    var previousBundle = sorted[0].bundleId
    var previousDocument = sorted[0].documentPath ?? ""
    var previousClass = activityClass(for: sorted[0], classification: classification)

    for frame in sorted.dropFirst() {
      if frame.bundleId != previousBundle {
        foregroundChanges += 1
        longest = max(longest, frame.capturedAt.timeIntervalSince(uninterruptedStart))
        uninterruptedStart = frame.capturedAt
        previousBundle = frame.bundleId
      }
      let document = frame.documentPath ?? ""
      if document != previousDocument {
        documentChanges += 1
        previousDocument = document
      }
      let nextClass = activityClass(for: frame, classification: classification)
      if previousClass != .neutral && nextClass != .neutral && previousClass != nextClass {
        workLeisureFlips += 1
      }
      if nextClass != .neutral {
        previousClass = nextClass
      }
    }
    if let last = sorted.last {
      longest = max(longest, last.capturedAt.timeIntervalSince(uninterruptedStart))
    }

    return EmittedCounts(
      distinctBundles: bundles.count,
      distinctDomains: domains.count,
      distinctDocumentPaths: documentPaths.count,
      distinctGithubPrs: prs.count,
      foregroundChanges: foregroundChanges,
      documentChanges: documentChanges,
      workLeisureFlips: workLeisureFlips,
      longestUninterruptedSeconds: max(0, Int(longest.rounded())),
      thrashEventCount: thrashEvents(in: sorted, rules: thrashRules).count
    )
  }

  static func contextMetadata(
    for frames: [ProcessedFrame],
    extractors: [ContextExtractor]
  ) -> [String: String] {
    var metadata: [String: String] = [:]
    var firstSeen: [String: Date] = [:]
    var foregroundSeconds: [String: TimeInterval] = [:]
    let sorted = frames.sorted { $0.capturedAt < $1.capturedAt }
    for (index, frame) in sorted.enumerated() {
      guard frame.tier != .audit, let documentPath = frame.documentPath else { continue }
      for extractor in extractors where globMatches(extractor.documentPattern, documentPath) {
        guard let value = extractValue(from: documentPath, extractor: extractor) else { continue }
        let key = extractor.captureKey
        metadata[key] = value
        firstSeen[key] = firstSeen[key] ?? frame.capturedAt
        let nextAt = index + 1 < sorted.count ? sorted[index + 1].capturedAt : frame.capturedAt
        foregroundSeconds[key, default: 0] += max(0, nextAt.timeIntervalSince(frame.capturedAt))
      }
    }
    for (key, date) in firstSeen {
      metadata["\(key).firstSeenAt"] = ISO8601DateFormatter().string(from: date)
      metadata["\(key).foregroundSeconds"] = String(Int(foregroundSeconds[key, default: 0]))
    }
    return metadata
  }

  static func profile(
    for bundleId: String,
    profiles: [BundleCaptureProfile]
  ) -> BundleCaptureProfile? {
    profiles.first { globMatches($0.bundleId, bundleId) }
  }

  private enum ActivityClass {
    case work
    case leisure
    case neutral
  }

  private static func activityClass(
    for frame: ProcessedFrame,
    classification: BehavioralClassification
  ) -> ActivityClass {
    if classification.workBundleIds.contains(frame.bundleId) {
      return .work
    }
    if classification.leisureBundleIds.contains(frame.bundleId) {
      return .leisure
    }
    guard let domain = frame.documentPath.flatMap(host) else { return .neutral }
    if classification.workDomains.contains(where: { globMatches($0, domain) }) {
      return .work
    }
    if classification.leisureDomains.contains(where: { globMatches($0, domain) }) {
      return .leisure
    }
    return .neutral
  }

  private static func thrashEvents(in frames: [ProcessedFrame], rules: [ThrashRule]) -> [String] {
    var events: [String] = []
    for rule in rules where rule.distinctThreshold > 0 && rule.windowSeconds > 0 {
      for frame in frames {
        let windowEnd = frame.capturedAt.addingTimeInterval(TimeInterval(rule.windowSeconds))
        let distinct = Set(
          frames.compactMap { candidate -> String? in
            guard candidate.capturedAt >= frame.capturedAt, candidate.capturedAt <= windowEnd,
              let documentPath = candidate.documentPath,
              globMatches(rule.domainPattern, documentPath)
            else {
              return nil
            }
            return documentPath
          })
        if distinct.count >= rule.distinctThreshold {
          events.append(rule.name)
          break
        }
      }
    }
    return events
  }

  private static func extractValue(from documentPath: String, extractor: ContextExtractor)
    -> String?
  {
    if let regex = extractor.regex, !regex.isEmpty,
      let expression = try? NSRegularExpression(pattern: regex),
      let match = expression.firstMatch(
        in: documentPath,
        range: NSRange(documentPath.startIndex..., in: documentPath)
      )
    {
      let group = extractor.captureGroup ?? 1
      guard group < match.numberOfRanges,
        let range = Range(match.range(at: group), in: documentPath)
      else {
        return nil
      }
      return String(documentPath[range])
    }
    let segments = pathSegments(documentPath)
    let count = max(1, extractor.lastPathSegments ?? 1)
    guard segments.count >= count else { return nil }
    let selected = segments.suffix(count)
    if selected.count >= 5, selected.first == "github.com" {
      let values = Array(selected)
      return "\(values[1])/\(values[2])#\(values[4])"
    }
    if selected.count >= 4 {
      let values = Array(selected)
      if values[2] == "pull" || values[2] == "issues" {
        return "\(values[0])/\(values[1])#\(values[3])"
      }
    }
    return selected.joined(separator: "/")
  }

  private static func githubPullRequestArtifact(_ documentPath: String) -> String? {
    let segments = pathSegments(documentPath)
    guard let hostIndex = segments.firstIndex(of: "github.com"),
      hostIndex + 4 < segments.count,
      segments[hostIndex + 3] == "pull"
    else {
      return nil
    }
    return "\(segments[hostIndex + 1])/\(segments[hostIndex + 2])#\(segments[hostIndex + 4])"
  }

  private static func pathSegments(_ value: String) -> [String] {
    if let components = URLComponents(string: value), let host = components.host {
      return ([host] + components.path.split(separator: "/").map(String.init)).filter {
        !$0.isEmpty
      }
    }
    return value.split(separator: "/").map(String.init)
  }

  private static func host(_ value: String) -> String? {
    if let components = URLComponents(string: value), let host = components.host {
      return host.lowercased()
    }
    return nil
  }

  private static func globMatches(_ pattern: String, _ value: String) -> Bool {
    let pattern = pattern.lowercased()
    let candidates = matchCandidates(for: value)
    if !pattern.contains("*") {
      if pattern.contains("/") {
        return candidates.contains(pattern)
      }
      guard let hostCandidate = hostMatchCandidate(for: value) else { return false }
      return hostCandidate == pattern || hostCandidate.hasSuffix(".\(pattern)")
    }
    let escaped = NSRegularExpression.escapedPattern(for: pattern)
      .replacingOccurrences(of: "\\*", with: ".*")
    let expression = "^\(escaped)$"
    return candidates.contains { candidate in
      candidate.range(of: expression, options: .regularExpression) != nil
    }
  }

  private static func matchCandidates(for value: String) -> [String] {
    let value = value.lowercased()
    var candidates = [value]
    if let components = URLComponents(string: value), let host = components.host?.lowercased() {
      candidates.append(host)
      if !components.path.isEmpty {
        candidates.append("\(host)\(components.path)")
      }
    }
    return Array(Set(candidates))
  }

  private static func hostMatchCandidate(for value: String) -> String? {
    let value = value.lowercased()
    if let components = URLComponents(string: value), let host = components.host?.lowercased() {
      return host
    }
    let host = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
    return host.isEmpty ? nil : host
  }

  private static func specificity(_ pattern: String) -> Int {
    pattern.filter { $0 != "*" }.count
  }
}
