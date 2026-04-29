// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit

struct DiagnosticProbeStatus: Codable, Equatable, Sendable {
  let timedOut: Bool
  let unavailableReason: String?

  static let available = DiagnosticProbeStatus(timedOut: false, unavailableReason: nil)

  static func timedOut(_ reason: String) -> DiagnosticProbeStatus {
    DiagnosticProbeStatus(timedOut: true, unavailableReason: reason)
  }

  static func unavailable(_ reason: String) -> DiagnosticProbeStatus {
    DiagnosticProbeStatus(timedOut: false, unavailableReason: reason)
  }
}

struct DiagnosticPermissionSnapshot: Codable, Equatable, Sendable {
  let accessibilityTrusted: Bool
  let screenCaptureTrusted: Bool?
  let screenCaptureProbe: DiagnosticProbeStatus

  @MainActor
  static func current(
    promptForAccessibility: Bool,
    screenCaptureTimeoutSeconds: TimeInterval = 1.5,
    screenCapturePreflight: @escaping @Sendable () throws -> Bool = {
      CGPreflightScreenCaptureAccess()
    }
  ) -> DiagnosticPermissionSnapshot {
    let accessibilityTrusted =
      promptForAccessibility
      ? WindowContextProbe.axTrustedPrompt()
      : AXIsProcessTrusted()
    switch DiagnosticProbeRunner.runBlocking(
      timeoutSeconds: screenCaptureTimeoutSeconds,
      operation: screenCapturePreflight
    ) {
    case .success(let trusted):
      return DiagnosticPermissionSnapshot(
        accessibilityTrusted: accessibilityTrusted,
        screenCaptureTrusted: trusted,
        screenCaptureProbe: .available
      )
    case .failure(let error):
      return DiagnosticPermissionSnapshot(
        accessibilityTrusted: accessibilityTrusted,
        screenCaptureTrusted: nil,
        screenCaptureProbe: .unavailable(error)
      )
    case .timedOut:
      return DiagnosticPermissionSnapshot(
        accessibilityTrusted: accessibilityTrusted,
        screenCaptureTrusted: nil,
        screenCaptureProbe: .timedOut("screen capture permission preflight timed out")
      )
    }
  }
}

enum TimedDiagnosticResult<T: Sendable>: Sendable {
  case success(T)
  case failure(String)
  case timedOut
}

private final class DiagnosticResultBox<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: TimedDiagnosticResult<T>?

  func store(_ next: TimedDiagnosticResult<T>) {
    lock.withLock {
      guard result == nil else { return }
      result = next
    }
  }

  func snapshot() -> TimedDiagnosticResult<T>? {
    lock.withLock { result }
  }
}

enum DiagnosticProbeRunner {
  static func runBlocking<T: Sendable>(
    timeoutSeconds: TimeInterval,
    operation: @escaping @Sendable () throws -> T
  ) -> TimedDiagnosticResult<T> {
    let box = DiagnosticResultBox<T>()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      defer { group.leave() }
      do {
        box.store(.success(try operation()))
      } catch {
        box.store(.failure(error.localizedDescription))
      }
    }
    let deadline = DispatchTime.now() + max(0, timeoutSeconds)
    guard group.wait(timeout: deadline) == .success else { return .timedOut }
    return box.snapshot() ?? .timedOut
  }
}

enum DiagnosticCLI {
  static let handledCommands = [
    "list-displays", "capture-once", "capture-worker-once", "selftest", "help", "--help", "-h",
  ]

  static func shouldHandle(_ arguments: [String]) -> Bool {
    guard let command = arguments.dropFirst().first else { return false }
    return handledCommands.contains(command)
  }

  static func run(arguments: [String]) async -> Int32 {
    do {
      let command = try DiagnosticCommand.parse(Array(arguments.dropFirst()))
      switch command {
      case .help:
        FileHandle.standardOutput.writeString(help)
      case .listDisplays:
        let payload = await DisplayDiagnostics.snapshot()
        try writeJSON(payload, to: nil)
      case .captureOnce(let options):
        if options.noScrub {
          throw DiagnosticCLIError.unscrubbedCaptureUnavailable
        }
        let lock = try AgentdRuntimeLock.acquire(purpose: "diagnostic-capture-once")
        _ = lock
        let payload = try await CaptureOnceDiagnostics.run(options: options)
        try writeJSON(payload, to: options.out)
      case .selftest:
        let payload = await SelftestDiagnostics.run()
        try writeJSON(payload, to: nil)
      case .captureWorkerOnce(let options):
        let payload = try await CaptureWorkerDiagnostics.run(options: options)
        try writeJSON(payload, to: options.out)
      }
      return 0
    } catch let error as DiagnosticCLIError {
      FileHandle.standardError.writeString("agentd: \(error.localizedDescription)\n")
      if error.showsUsage {
        FileHandle.standardError.writeString(help)
      }
      return 2
    } catch {
      FileHandle.standardError.writeString("agentd: \(error.localizedDescription)\n")
      return 1
    }
  }

  private static func writeJSON<T: Encodable>(_ value: T, to url: URL?) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value) + Data([0x0A])
    if let url {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } else {
      FileHandle.standardOutput.write(data)
    }
  }

  static let help = """
    Usage:
      agentd list-displays
      agentd capture-once [--display-id ID] [--no-ocr] [--out PATH]
      agentd selftest

    Diagnostic commands emit redacted JSON and never start the menu-bar app.
    capture-once uses the normal privacy filters, SecretScrubber, and OCR pipeline.

    """
}

enum DiagnosticCommand: Equatable {
  case help
  case listDisplays
  case captureOnce(CaptureOnceOptions)
  case captureWorkerOnce(CaptureOnceOptions)
  case selftest

  static func parse(_ arguments: [String]) throws -> DiagnosticCommand {
    guard let command = arguments.first else { return .help }
    let tail = Array(arguments.dropFirst())
    switch command {
    case "help", "--help", "-h":
      return .help
    case "list-displays":
      guard tail.isEmpty else { throw DiagnosticCLIError.usage("list-displays takes no flags") }
      return .listDisplays
    case "capture-once":
      return .captureOnce(try CaptureOnceOptions.parse(tail))
    case "capture-worker-once":
      return .captureWorkerOnce(try CaptureOnceOptions.parse(tail))
    case "selftest":
      guard tail.isEmpty else { throw DiagnosticCLIError.usage("selftest takes no flags") }
      return .selftest
    default:
      throw DiagnosticCLIError.usage("unknown diagnostic command '\(command)'")
    }
  }
}

struct CaptureOnceOptions: Equatable {
  var displayId: UInt32?
  var noOCR = false
  var noScrub = false
  var out: URL?

  static func parse(_ arguments: [String]) throws -> CaptureOnceOptions {
    var options = CaptureOnceOptions()
    var index = 0
    while index < arguments.count {
      let flag = arguments[index]
      switch flag {
      case "--display-id":
        index += 1
        guard index < arguments.count, let value = UInt32(arguments[index]) else {
          throw DiagnosticCLIError.usage("--display-id requires a UInt32 display id")
        }
        options.displayId = value
      case "--no-ocr":
        options.noOCR = true
      case "--no-scrub":
        options.noScrub = true
      case "--out":
        index += 1
        guard index < arguments.count else {
          throw DiagnosticCLIError.usage("--out requires a path")
        }
        options.out = URL(fileURLWithPath: arguments[index])
      case "--help", "-h":
        throw DiagnosticCLIError.usage("")
      default:
        throw DiagnosticCLIError.usage("unknown capture-once flag '\(flag)'")
      }
      index += 1
    }
    return options
  }
}

enum DiagnosticCLIError: Error, LocalizedError {
  case usage(String)
  case timeout
  case noWindowContext
  case noBatchProduced
  case displayProbeFailed(String)
  case captureWorkerFailed(String)
  case unscrubbedCaptureUnavailable

  var errorDescription: String? {
    switch self {
    case .usage(let message):
      return message.isEmpty ? "usage requested" : message
    case .timeout:
      return "timed out waiting for a captured frame"
    case .noWindowContext:
      return "could not read frontmost window context; grant Accessibility permission and retry"
    case .noBatchProduced:
      return "capture produced no batch; privacy filters may have dropped the frame"
    case .displayProbeFailed(let message):
      return message
    case .captureWorkerFailed(let message):
      return message
    case .unscrubbedCaptureUnavailable:
      return
        "--no-scrub is recognized but intentionally unavailable; diagnostic captures stay scrubbed"
    }
  }

  var showsUsage: Bool {
    if case .usage = self { return true }
    return false
  }
}

struct DisplayDiagnosticsSnapshot: Codable, Sendable {
  let generatedAt: Date
  let permissions: DiagnosticPermissionSnapshot
  let displayProbe: DiagnosticProbeStatus
  let displays: [DisplayDiagnostic]
}

struct DisplayDiagnostic: Codable, Equatable, Sendable {
  let displayId: UInt32
  let name: String
  let width: Int
  let height: Int
  let scale: Double?
  let isMain: Bool
  let bounds: DisplayBounds
}

struct DisplayBounds: Codable, Equatable, Sendable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double
}

enum DisplayDiagnostics {
  @MainActor
  static func snapshot(
    probe: any DisplayDiagnosticsProbing = SystemDisplayDiagnosticsProbe(),
    timeoutNanoseconds: UInt64 = 2_000_000_000
  ) async -> DisplayDiagnosticsSnapshot {
    let probeResult = await runProbe(probe, timeoutNanoseconds: timeoutNanoseconds)
    let displays: [DisplayDiagnostic]
    let displayProbe: DiagnosticProbeStatus
    switch probeResult {
    case .success(let value):
      displays = value
      displayProbe = .available
    case .failure(let error):
      displays = []
      displayProbe = .unavailable(error)
    case .timedOut:
      displays = []
      displayProbe = .timedOut("display discovery timed out")
    }
    return DisplayDiagnosticsSnapshot(
      generatedAt: Date(),
      permissions: DiagnosticPermissionSnapshot.current(promptForAccessibility: false),
      displayProbe: displayProbe,
      displays: displays
    )
  }

  static func availableDisplayIds() async throws -> Set<UInt32> {
    try await MainActor.run {
      Set(try SystemDisplayDiagnosticsProbe.systemDisplays().map(\.displayId))
    }
  }

  private static func runProbe(
    _ probe: any DisplayDiagnosticsProbing,
    timeoutNanoseconds: UInt64
  ) async -> TimedDiagnosticResult<[DisplayDiagnostic]> {
    await withTaskGroup(of: TimedDiagnosticResult<[DisplayDiagnostic]>.self) { group in
      group.addTask {
        do {
          return .success(try await probe.displays())
        } catch {
          return .failure(error.localizedDescription)
        }
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        return .timedOut
      }
      let result = await group.next() ?? .timedOut
      group.cancelAll()
      return result
    }
  }
}

protocol DisplayDiagnosticsProbing: Sendable {
  func displays() async throws -> [DisplayDiagnostic]
}

struct SystemDisplayDiagnosticsProbe: DisplayDiagnosticsProbing {
  func displays() async throws -> [DisplayDiagnostic] {
    try await MainActor.run {
      try Self.systemDisplays()
    }
  }

  @MainActor
  static func systemDisplays() throws -> [DisplayDiagnostic] {
    var count: UInt32 = 0
    let countError = CGGetActiveDisplayList(0, nil, &count)
    guard countError == .success else {
      throw DiagnosticCLIError.displayProbeFailed("CGGetActiveDisplayList count failed")
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    let listError = CGGetActiveDisplayList(count, &ids, &count)
    guard listError == .success else {
      throw DiagnosticCLIError.displayProbeFailed("CGGetActiveDisplayList display list failed")
    }
    return ids.prefix(Int(count)).sorted().map { displayId in
      DisplayDiagnostic(
        displayId: displayId,
        name: Self.displayName(displayId),
        width: CGDisplayPixelsWide(displayId),
        height: CGDisplayPixelsHigh(displayId),
        scale: Self.displayScale(displayId),
        isMain: displayId == CGMainDisplayID(),
        bounds: {
          let bounds = CGDisplayBounds(displayId)
          return DisplayBounds(
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: bounds.width,
            height: bounds.height
          )
        }()
      )
    }
  }

  private static func displayName(_ displayId: CGDirectDisplayID) -> String {
    let numberKey = NSDeviceDescriptionKey("NSScreenNumber")
    if let screen = NSScreen.screens.first(where: {
      ($0.deviceDescription[numberKey] as? NSNumber)?.uint32Value == displayId
    }) {
      return screen.localizedName
    }
    return "Display \(displayId)"
  }

  private static func displayScale(_ displayId: CGDirectDisplayID) -> Double? {
    let pixelWidth = CGDisplayPixelsWide(displayId)
    guard pixelWidth > 0 else { return nil }
    let boundsWidth = CGDisplayBounds(displayId).width
    guard boundsWidth > 0 else { return nil }
    return Double(pixelWidth) / Double(boundsWidth)
  }
}

struct CaptureOnceOutput: Codable {
  let generatedAt: Date
  let permissions: DiagnosticPermissionSnapshot
  let batch: Batch
}

enum CaptureOnceDiagnostics {
  static func run(options: CaptureOnceOptions) async throws -> CaptureOnceOutput {
    let cfg = ConfigStore.load()
    let recorder = DiagnosticBatchRecorder()
    let ocr: any OCRRecognizing = options.noOCR ? EmptyOCR() : VisionOCR()
    let pipeline = FramePipeline(config: cfg, ocr: ocr) { batch in
      await recorder.append(batch)
      return .submitted(nil)
    }
    let frame = try await CaptureWorkerClient.captureOneFrame(
      displayId: options.displayId,
      timeoutSeconds: 6
    )
    let context = try await MainActor.run {
      guard let context = WindowContextProbe.current() else {
        throw DiagnosticCLIError.noWindowContext
      }
      return context
    }
    let axText = await MainActor.run { AccessibilityTextExtractor.current(context: context) }
    await pipeline.consume(
      frame,
      context: context,
      accessibilityText: axText
    )
    await pipeline.flush()
    let batches = await recorder.snapshot()
    guard let batch = batches.last else { throw DiagnosticCLIError.noBatchProduced }
    return CaptureOnceOutput(
      generatedAt: Date(),
      permissions: await MainActor.run {
        DiagnosticPermissionSnapshot.current(promptForAccessibility: false)
      },
      batch: batch
    )
  }

  static func captureOneFrame(
    displayId: UInt32?,
    timeoutSeconds: UInt64
  ) async throws -> CapturedFrame {
    if let displayId {
      let available = try await DisplayDiagnostics.availableDisplayIds()
      guard available.contains(displayId) else {
        throw DiagnosticCLIError.usage(
          "display id \(displayId) is not available; run agentd list-displays")
      }
    }
    do {
      return try await CaptureService.captureOneFrame(
        targetFps: 2,
        captureAllDisplays: false,
        selectedDisplayIds: displayId.map { [$0] } ?? [],
        timeoutSeconds: Double(timeoutSeconds)
      )
    } catch CaptureOneShotError.timedOut {
      throw DiagnosticCLIError.timeout
    } catch {
      throw error
    }
  }
}

enum CaptureWorkerDiagnostics {
  static func run(options: CaptureOnceOptions) async throws -> CaptureWorkerFramePayload {
    if options.noScrub {
      throw DiagnosticCLIError.unscrubbedCaptureUnavailable
    }
    let frame = try await CaptureOnceDiagnostics.captureOneFrame(
      displayId: options.displayId,
      timeoutSeconds: 6
    )
    return try CaptureWorkerFrameCodec.payload(for: frame)
  }
}

enum CaptureWorkerClient {
  static func captureOneFrame(displayId: UInt32?, timeoutSeconds: TimeInterval) async throws
    -> CapturedFrame
  {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    return try await captureOneFrame(
      executable: executable,
      displayId: displayId,
      timeoutSeconds: timeoutSeconds
    )
  }

  static func captureOneFrame(
    executable: URL,
    displayId: UInt32?,
    timeoutSeconds: TimeInterval
  ) async throws -> CapturedFrame {
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("agentd-capture-worker-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    var arguments = ["capture-worker-once", "--no-ocr", "--out", outputURL.path]
    if let displayId {
      arguments += ["--display-id", String(displayId)]
    }
    let stderr = Pipe()
    let supervisor = CaptureWorkerSupervisor()
    _ = try supervisor.start(
      CaptureWorkerProcessSpec(
        executableURL: executable,
        arguments: arguments,
        standardError: stderr
      )
    )
    guard
      let result = supervisor.waitForExit(timeoutSeconds: timeoutSeconds + 2),
      result.exited
    else {
      let termination = supervisor.terminate(graceSeconds: 1)
      throw DiagnosticCLIError.captureWorkerFailed(
        "capture worker timed out killSent=\(termination.killSent)")
    }

    let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
    guard result.terminationStatus == 0 else {
      let message = String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      throw DiagnosticCLIError.captureWorkerFailed(
        message?.isEmpty == false
          ? message!
          : "capture worker exited with status \(result.terminationStatus ?? -1)"
      )
    }
    let output = try Data(contentsOf: outputURL)
    let payload = try CaptureWorkerFrameCodec.decodePayload(output)
    return try CaptureWorkerFrameCodec.frame(from: payload)
  }
}

actor DiagnosticBatchRecorder {
  private var batches: [Batch] = []

  func append(_ batch: Batch) {
    batches.append(batch)
  }

  func snapshot() -> [Batch] {
    batches
  }
}

struct EmptyOCR: OCRRecognizing {
  func recognize(cgImage: CGImage) async throws -> OCRResult {
    OCRResult(text: "", confidence: 0, language: "und")
  }
}

struct SelftestOutput: Codable {
  let generatedAt: Date
  let permissions: DiagnosticPermissionSnapshot
  let displayProbe: DiagnosticProbeStatus
  let displayCount: Int
  let configPath: String
  let runtimeLockPath: String
  let mockChronicle: SelftestCommandResult?
}

struct SelftestCommandResult: Codable {
  let command: [String]
  let exitCode: Int32
}

enum SelftestDiagnostics {
  @MainActor
  static func run(
    displayProbe: any DisplayDiagnosticsProbing = SystemDisplayDiagnosticsProbe(),
    displayTimeoutNanoseconds: UInt64 = 2_000_000_000
  ) async -> SelftestOutput {
    let displaySnapshot = await DisplayDiagnostics.snapshot(
      probe: displayProbe,
      timeoutNanoseconds: displayTimeoutNanoseconds
    )
    return SelftestOutput(
      generatedAt: Date(),
      permissions: DiagnosticPermissionSnapshot.current(promptForAccessibility: false),
      displayProbe: displaySnapshot.displayProbe,
      displayCount: displaySnapshot.displays.count,
      configPath: ConfigStore.path.path,
      runtimeLockPath: AgentdRuntimeLock.lockURL.path,
      mockChronicle: runMockChronicleIfAvailable()
    )
  }

  private static func runMockChronicleIfAvailable() -> SelftestCommandResult? {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let script = cwd.appendingPathComponent("scripts/mock_chronicle.py")
    let fixtures = cwd.appendingPathComponent("Tests/Fixtures/chronicle")
    guard FileManager.default.fileExists(atPath: script.path),
      FileManager.default.fileExists(atPath: fixtures.path)
    else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [script.path, "--self-test", fixtures.path]
    process.standardOutput = FileHandle.standardError
    process.standardError = FileHandle.standardError
    do {
      try process.run()
      process.waitUntilExit()
      return SelftestCommandResult(
        command: ["/usr/bin/python3", script.path, "--self-test", fixtures.path],
        exitCode: process.terminationStatus
      )
    } catch {
      return SelftestCommandResult(
        command: ["/usr/bin/python3", script.path, "--self-test", fixtures.path],
        exitCode: 127
      )
    }
  }
}

extension FileHandle {
  fileprivate func writeString(_ value: String) {
    write(Data(value.utf8))
  }
}
