// SPDX-License-Identifier: BUSL-1.1

import Foundation

struct EvalOpsContextMetadata: Sendable, Equatable {
  static let contextVersionKey = "evalops_context_version"
  static let expectedContextVersion = "evalops.context.v1"
  static let traceparentKey = "traceparent"

  private static let traceparentRegex =
    try! NSRegularExpression(
      pattern: #"^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$"#,
      options: []
    )

  static func clean(_ metadata: [String: String]) -> [String: String] {
    var cleaned: [String: String] = [:]
    for (rawKey, rawValue) in metadata {
      let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
      let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty, !value.isEmpty else { continue }
      guard acceptsCanonicalValue(key: key, value: value) else { continue }
      cleaned[key] = value
    }
    return cleaned
  }

  static func frameBatchMetadata(
    base metadata: [String: String],
    batch: Batch,
    source: String = "agentd"
  ) -> [String: String] {
    var values = clean(metadata)
    for reservedKey in [
      "batch_id",
      "device_id",
      "organization_id",
      "workspace_id",
      "user_id",
      "project_id",
      "repository",
      "source",
    ] {
      values.removeValue(forKey: reservedKey)
    }
    values["batch_id"] = batch.batchId
    values["device_id"] = batch.deviceId
    values["organization_id"] = batch.organizationId
    if let workspaceId = batch.workspaceId {
      values["workspace_id"] = workspaceId
    }
    if let userId = batch.userId {
      values["user_id"] = userId
    }
    if let projectId = batch.projectId {
      values["project_id"] = projectId
    }
    if let repository = batch.repository {
      values["repository"] = repository
    }
    values["source"] = source
    return values
  }

  private static func acceptsCanonicalValue(key: String, value: String) -> Bool {
    switch key {
    case contextVersionKey:
      return value == expectedContextVersion
    case traceparentKey:
      let range = NSRange(value.startIndex..<value.endIndex, in: value)
      return traceparentRegex.firstMatch(in: value, options: [], range: range) != nil
    default:
      return true
    }
  }
}
