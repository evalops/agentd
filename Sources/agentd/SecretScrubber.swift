// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// Fail-closed scrubber. We never partial-redact and ship — a hit means the
/// frame is dropped and an audit event is emitted at the call site.
///
/// Uses NSRegularExpression because (a) it's documented thread-safe for matching
/// and (b) it bridges trivially to Sendable, unlike the new typed Regex which is
/// not Sendable in Swift 6.
struct SecretScrubber: Sendable {
  struct Pattern: @unchecked Sendable {
    let name: String
    let regex: NSRegularExpression
  }

  static let patterns: [Pattern] = {
    let raw: [(String, String)] = [
      ("aws_access_key", #"\bAKIA[0-9A-Z]{16}\b"#),
      ("aws_secret", #"(?i)aws(.{0,20})?(secret|access).{0,20}?["']?[A-Za-z0-9/+=]{40}["']?"#),
      ("gcp_sa_key", #"-----BEGIN\s+PRIVATE\s+KEY-----"#),
      ("ssh_private", #"-----BEGIN\s+(?:RSA|OPENSSH|EC|DSA)\s+PRIVATE\s+KEY-----"#),
      ("jwt", #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#),
      ("github_token", #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#),
      ("github_fine_grained_token", #"\bgithub_pat_[A-Za-z0-9_]{82}\b"#),
      ("google_api_key", #"\bAIza[0-9A-Za-z\-_]{35}\b"#),
      ("npm_token", #"\bnpm_[A-Za-z0-9]{36}\b"#),
      ("sendgrid_key", #"\bSG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}\b"#),
      ("digitalocean_pat", #"\bdop_v1_[a-f0-9]{64}\b"#),
      ("azure_storage_key", #"AccountKey=[A-Za-z0-9+/=]{86,90}"#),
      ("mailgun_key", #"\bkey-[0-9a-f]{32}\b"#),
      ("twilio_api_key", #"\bSK[a-f0-9]{32}\b"#),
      ("discord_bot_token", #"\b[A-Za-z0-9_-]{24}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}\b"#),
      ("slack_bot", #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#),
      ("anthropic_key", #"\bsk-ant-[A-Za-z0-9-_]{20,}\b"#),
      ("openai_key", #"\bsk-(?:proj-|svcacct-|admin-|None-)?[A-Za-z0-9]{32,}\b"#),
      ("stripe_live", #"\b(?:rk|sk)_live_[A-Za-z0-9]{20,}\b"#),
      ("pem_certreq", #"-----BEGIN\s+CERTIFICATE\s+REQUEST-----"#),
      ("password_field", #"(?i)\b(password|passwd|secret|api[_-]?key)\b\s*[:=]\s*\S{4,}"#),
    ]
    return raw.compactMap { (name, p) in
      (try? NSRegularExpression(pattern: p)).map { Pattern(name: name, regex: $0) }
    }
  }()

  enum Decision: Sendable, Equatable {
    case clean
    case dropped(reason: String)
  }

  /// O(n * patterns); short-circuits on first hit.
  static func evaluate(_ text: String) -> Decision {
    guard !text.isEmpty else { return .clean }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    for p in patterns {
      if p.regex.firstMatch(in: text, options: [], range: range) != nil {
        return .dropped(reason: p.name)
      }
    }
    return .clean
  }
}

struct PathPolicy: Sendable {
  let deniedPrefixes: [String]

  func deny(_ path: String) -> Bool {
    let normalized = path.hasPrefix("/") ? path : path
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return deniedPrefixes.contains { prefix in
      normalized.hasPrefix(home + "/" + prefix) || normalized.hasPrefix("~/" + prefix)
        || normalized.contains("/" + prefix + "/")
    }
  }
}
