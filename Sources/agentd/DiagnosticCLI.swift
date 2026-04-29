// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit

enum DiagnosticCLI {
  static let handledCommands = [
    "list-displays", "capture-once", "selftest", "help", "--help", "-h",
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
        let payload = try await DisplayDiagnostics.snapshot()
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

struct DisplayDiagnosticsSnapshot: Codable {
  let generatedAt: Date
  let permissions: PermissionSnapshot
  let displays: [DisplayDiagnostic]
}

struct DisplayDiagnostic: Codable, Equatable {
  let displayId: UInt32
  let name: String
  let width: Int
  let height: Int
  let scale: Double?
  let isMain: Bool
  let bounds: DisplayBounds
}

struct DisplayBounds: Codable, Equatable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double
}

enum DisplayDiagnostics {
  @MainActor
  static func snapshot() async throws -> DisplayDiagnosticsSnapshot {
    let content = try await SCShareableContent.excludingDesktopWindows(
      true, onScreenWindowsOnly: true
    )
    let displays = content.displays.sorted { $0.displayID < $1.displayID }.map { display in
      DisplayDiagnostic(
        displayId: display.displayID,
        name: displayName(display.displayID),
        width: display.width,
        height: display.height,
        scale: displayScale(display.displayID),
        isMain: display.displayID == CGMainDisplayID(),
        bounds: DisplayBounds(
          x: display.frame.origin.x,
          y: display.frame.origin.y,
          width: display.frame.width,
          height: display.frame.height
        )
      )
    }
    return DisplayDiagnosticsSnapshot(
      generatedAt: Date(),
      permissions: PermissionSnapshot.current(promptForAccessibility: false),
      displays: displays
    )
  }

  static func availableDisplayIds() async throws -> Set<UInt32> {
    let content = try await SCShareableContent.excludingDesktopWindows(
      true, onScreenWindowsOnly: true
    )
    return Set(content.displays.map(\.displayID))
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

  static func displayScale(_ displayId: CGDirectDisplayID) -> Double? {
    let pixelWidth = CGDisplayPixelsWide(displayId)
    guard pixelWidth > 0 else { return nil }
    let boundsWidth = CGDisplayBounds(displayId).width
    guard boundsWidth > 0 else { return nil }
    return Double(pixelWidth) / Double(boundsWidth)
  }
}

struct CaptureOnceOutput: Codable {
  let generatedAt: Date
  let permissions: PermissionSnapshot
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
    let frame = try await captureOneFrame(
      displayId: options.displayId, timeoutSeconds: 6)
    await pipeline.consume(
      frame,
      context: try await MainActor.run {
        guard let context = WindowContextProbe.current() else {
          throw DiagnosticCLIError.noWindowContext
        }
        return context
      }
    )
    await pipeline.flush()
    let batches = await recorder.snapshot()
    guard let batch = batches.last else { throw DiagnosticCLIError.noBatchProduced }
    return CaptureOnceOutput(
      generatedAt: Date(),
      permissions: await MainActor.run {
        PermissionSnapshot.current(promptForAccessibility: false)
      },
      batch: batch
    )
  }

  private static func captureOneFrame(
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
  let permissions: PermissionSnapshot
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
  static func run() -> SelftestOutput {
    SelftestOutput(
      generatedAt: Date(),
      permissions: PermissionSnapshot.current(promptForAccessibility: false),
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
