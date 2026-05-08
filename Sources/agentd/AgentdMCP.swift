// SPDX-License-Identifier: BUSL-1.1

import Foundation

struct AgentdMCPPermissionStatus: Codable, Equatable, Sendable {
  let accessibilityTrusted: Bool
  let screenCaptureTrusted: Bool
  let menuSummary: String
}

struct AgentdMCPPrivacyStatus: Codable, Equatable, Sendable {
  let allowedBundleCount: Int
  let deniedBundleCount: Int
  let deniedPathPrefixCount: Int
  let pauseTitlePatternCount: Int
  let captureAllDisplays: Bool
  let selectedDisplayIds: [UInt32]
}

struct AgentdMCPLocalBatchStats: Codable, Equatable, Sendable {
  let fileCount: Int
  let bytes: Int64

  init(fileCount: Int, bytes: Int64) {
    self.fileCount = fileCount
    self.bytes = bytes
  }

  init(_ stats: LocalBatchStats) {
    self.fileCount = stats.fileCount
    self.bytes = stats.bytes
  }
}

struct AgentdMCPDeviceSnapshot: Codable, Equatable, Sendable {
  let generatedAt: Date
  let appVersion: String
  let deviceId: String
  let organizationId: String
  let mode: String
  let endpoint: String
  let permissions: AgentdMCPPermissionStatus
  let localBatchStats: AgentdMCPLocalBatchStats
  let privacy: AgentdMCPPrivacyStatus
}

struct AgentdMCPDiagnosticsResult: Codable, Equatable, Sendable {
  let instructionsPath: String
  let resourcePaths: [String]
}

protocol AgentdMCPRuntime {
  func deviceSnapshot() async throws -> AgentdMCPDeviceSnapshot
  func activityRecent(options: ActivityOptions) async throws -> ActivitySummary
  func collectDiagnostics(options: ActivityOptions, outputDirectory: URL) async throws
    -> AgentdMCPDiagnosticsResult
}

struct SystemAgentdMCPRuntime: AgentdMCPRuntime {
  func deviceSnapshot() async throws -> AgentdMCPDeviceSnapshot {
    let config = ConfigStore.load()
    let permissions = await MainActor.run {
      PermissionSnapshot.current(promptForAccessibility: false)
    }
    let submitter = try Submitter(
      endpoint: config.endpoint,
      localOnly: true,
      authMode: .none,
      maxBatchBytes: config.maxBatchBytes,
      maxBatchAgeDays: config.maxBatchAgeDays,
      deviceId: config.deviceId,
      encryptLocalBatches: config.encryptLocalBatches
    )
    let batchStats = await submitter.localBatchStats()

    return AgentdMCPDeviceSnapshot(
      generatedAt: Date(),
      appVersion: Bundle.main.appVersion,
      deviceId: config.deviceId,
      organizationId: config.organizationId,
      mode: config.localOnly ? "local-only" : "managed",
      endpoint: EndpointRedaction.redact(config.endpoint),
      permissions: AgentdMCPPermissionStatus(
        accessibilityTrusted: permissions.accessibilityTrusted,
        screenCaptureTrusted: permissions.screenCaptureTrusted,
        menuSummary: permissions.menuSummary
      ),
      localBatchStats: AgentdMCPLocalBatchStats(batchStats),
      privacy: AgentdMCPPrivacyStatus(
        allowedBundleCount: config.allowedBundleIds.count,
        deniedBundleCount: config.deniedBundleIds.count,
        deniedPathPrefixCount: config.deniedPathPrefixes.count,
        pauseTitlePatternCount: config.pauseWindowTitlePatterns.count,
        captureAllDisplays: config.captureAllDisplays,
        selectedDisplayIds: config.selectedDisplayIds
      )
    )
  }

  func activityRecent(options: ActivityOptions) async throws -> ActivitySummary {
    try await ActivitySummary.run(options: options)
  }

  func collectDiagnostics(options: ActivityOptions, outputDirectory: URL) async throws
    -> AgentdMCPDiagnosticsResult
  {
    let summary = try await ActivitySummary.run(options: options)
    let resource = try ActivitySummaryArtifacts.write(summary, root: outputDirectory)
    return AgentdMCPDiagnosticsResult(
      instructionsPath: outputDirectory.appendingPathComponent("instructions.md").path,
      resourcePaths: [resource.path]
    )
  }

}

struct AgentdMCPServer {
  private let runtime: AgentdMCPRuntime

  init(runtime: AgentdMCPRuntime = SystemAgentdMCPRuntime()) {
    self.runtime = runtime
  }

  func handle(_ data: Data) async -> Data {
    do {
      let request = try AgentdMCPRequest(data: data)
      do {
        return try await handleRequest(request)
      } catch {
        let mcpError = Self.jsonRPCError(for: error)
        return safeErrorResponse(id: request.id, code: mcpError.code, message: mcpError.message)
      }
    } catch let error as AgentdMCPError {
      let mcpError = Self.jsonRPCError(for: error)
      return safeErrorResponse(id: nil, code: mcpError.code, message: mcpError.message)
    } catch {
      return safeErrorResponse(id: nil, code: -32700, message: "parse error")
    }
  }

  private func handleRequest(_ request: AgentdMCPRequest) async throws -> Data {
    switch request.method {
    case "initialize":
      return try response(
        id: request.id,
        result: [
          "protocolVersion": "2025-06-18",
          "capabilities": ["tools": ["listChanged": false]],
          "serverInfo": ["name": "agentd-local", "version": Bundle.main.appVersion],
        ])
    case "notifications/initialized":
      return Data()
    case "tools/list":
      return try response(id: request.id, result: ["tools": Self.toolCatalog()])
    case "tools/call":
      return try await callTool(request)
    default:
      return try errorResponse(id: request.id, code: -32601, message: "method not found")
    }
  }

  private func callTool(_ request: AgentdMCPRequest) async throws -> Data {
    guard let params = request.params,
      let name = params["name"] as? String
    else {
      return try errorResponse(id: request.id, code: -32602, message: "tools/call requires name")
    }
    let arguments = params["arguments"] as? [String: Any] ?? [:]

    switch name {
    case "agentd_device_snapshot":
      return try await toolResponse(id: request.id, value: runtime.deviceSnapshot())
    case "agentd_activity_recent":
      let options = try activityOptions(from: arguments)
      return try await toolResponse(id: request.id, value: runtime.activityRecent(options: options))
    case "agentd_collect_diagnostics":
      let options = try activityOptions(from: arguments)
      let outputDirectory = outputDirectory(from: arguments)
      return try await toolResponse(
        id: request.id,
        value: runtime.collectDiagnostics(options: options, outputDirectory: outputDirectory)
      )
    default:
      return try errorResponse(id: request.id, code: -32602, message: "unknown tool '\(name)'")
    }
  }

  private func toolResponse<T: Encodable>(id: Any?, value: T) async throws -> Data {
    let text = try Self.jsonString(value)
    return try response(
      id: id,
      result: [
        "content": [
          [
            "type": "text",
            "mimeType": "application/json",
            "text": text,
          ]
        ],
        "isError": false,
      ])
  }

  private func activityOptions(from arguments: [String: Any]) throws -> ActivityOptions {
    var raw: [String] = []
    if let window = arguments["window"] as? String {
      raw += ["--window", window]
    }
    if let since = arguments["since"] {
      raw += ["--since", String(describing: since)]
    }
    if let batchDirectory = arguments["batch_dir"] as? String {
      raw += ["--batch-dir", batchDirectory]
    }
    return try ActivityOptions.parse(raw)
  }

  private func outputDirectory(from arguments: [String: Any]) -> URL {
    if let path = arguments["out_dir"] as? String, !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".evalops/agentd/mcp-diagnostics", isDirectory: true)
  }

  private func response(id: Any?, result: [String: Any]) throws -> Data {
    try Self.jsonData([
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "result": result,
    ])
  }

  private func errorResponse(id: Any?, code: Int, message: String) throws -> Data {
    try Self.jsonData([
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "error": ["code": code, "message": message],
    ])
  }

  private func safeErrorResponse(id: Any?, code: Int, message: String) -> Data {
    (try? errorResponse(id: id, code: code, message: message))
      ?? (Data(#"{"error":{"code":-32603,"message":"internal error"},"id":null,"jsonrpc":"2.0"}"#.utf8)
        + Data([0x0A]))
  }

  private static func toolCatalog() -> [[String: Any]] {
    [
      [
        "name": "agentd_device_snapshot",
        "description":
          "Return a redacted local device snapshot including agentd mode, permissions, privacy policy counts, and queued local batch stats.",
        "inputSchema": ["type": "object", "additionalProperties": false, "properties": [:]],
        "annotations": ["title": "Device Snapshot", "readOnlyHint": true],
      ],
      [
        "name": "agentd_activity_recent",
        "description":
          "Summarize recent local agentd activity from persisted redacted batch JSON without returning raw frames.",
        "inputSchema": [
          "type": "object",
          "additionalProperties": false,
          "properties": [
            "window": ["type": "string", "enum": ["10m", "6h", "24h"]],
            "since": ["type": "number"],
            "batch_dir": ["type": "string"],
          ],
        ],
        "annotations": ["title": "Recent Activity", "readOnlyHint": true],
      ],
      [
        "name": "agentd_collect_diagnostics",
        "description":
          "Write Chronicle-style local activity summary artifacts for support/debugging and return their paths.",
        "inputSchema": [
          "type": "object",
          "required": ["out_dir"],
          "additionalProperties": false,
          "properties": [
            "window": ["type": "string", "enum": ["10m", "6h", "24h"]],
            "since": ["type": "number"],
            "batch_dir": ["type": "string"],
            "out_dir": ["type": "string"],
          ],
        ],
        "annotations": ["title": "Collect Diagnostics", "readOnlyHint": false],
      ],
    ]
  }

  private static func jsonString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  private static func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
      + Data([0x0A])
  }

  private static func jsonRPCError(for error: Error) -> (code: Int, message: String) {
    switch error {
    case let error as AgentdMCPError:
      return (error.code, error.localizedDescription)
    case let error as DiagnosticCLIError:
      return (-32602, error.localizedDescription)
    default:
      return (-32603, error.localizedDescription)
    }
  }
}

struct AgentdMCPRequest {
  let id: Any?
  let method: String
  let params: [String: Any]?

  init(data: Data) throws {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let root = object as? [String: Any],
      let method = root["method"] as? String
    else {
      throw AgentdMCPError.invalidRequest
    }
    self.id = root["id"]
    self.method = method
    self.params = root["params"] as? [String: Any]
  }
}

enum AgentdMCPError: Error, LocalizedError {
  case invalidRequest

  var code: Int {
    switch self {
    case .invalidRequest:
      return -32600
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidRequest:
      return "invalid MCP JSON-RPC request"
    }
  }
}

enum AgentdMCPStdio {
  static func run(server: AgentdMCPServer = AgentdMCPServer()) async -> Int32 {
    while let line = readLine(strippingNewline: true) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let response = await server.handle(Data(trimmed.utf8))
      if !response.isEmpty {
        FileHandle.standardOutput.write(response)
      }
    }
    return 0
  }
}
