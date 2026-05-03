// SPDX-License-Identifier: BUSL-1.1

import Foundation

enum URLPrivacyRedactor {
  static func redactDocumentPath(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return value }
    guard value.contains("://"), var components = URLComponents(string: value) else {
      return value
    }

    var redacted = false
    if let queryItems = components.queryItems, !queryItems.isEmpty {
      components.queryItems = queryItems.map { item in
        guard isSensitiveQueryName(item.name) else { return item }
        redacted = true
        return URLQueryItem(name: item.name, value: "REDACTED")
      }
    }
    if components.fragment != nil {
      components.fragment = "REDACTED"
      redacted = true
    }

    return redacted ? components.string ?? value : value
  }

  private static func isSensitiveQueryName(_ name: String) -> Bool {
    let normalized = name.lowercased()
    if exactSensitiveQueryNames.contains(normalized) {
      return true
    }
    return normalized.hasSuffix("_token")
      || normalized.hasSuffix("-token")
      || normalized.contains("secret")
      || normalized.contains("credential")
  }

  private static let exactSensitiveQueryNames: Set<String> = [
    "access_token",
    "assertion",
    "authuser",
    "client_secret",
    "code",
    "credential",
    "id_token",
    "oauth_token",
    "oauth_verifier",
    "prompt",
    "refresh_token",
    "scope",
    "session",
    "session_state",
    "state",
    "token",
  ]
}
