// SPDX-License-Identifier: BUSL-1.1

import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

struct CapturedFrame: Sendable {
  let timestamp: Date
  let cgImage: CGImage
  let displayId: CGDirectDisplayID
  let displayScale: Double?
  let mainDisplay: Bool
}

struct CaptureDisplayStats: Sendable, Equatable {
  let displayId: UInt32
  let widthPx: Int
  let heightPx: Int
  let displayScale: Double?
  let mainDisplay: Bool
  let framesEnqueued: Int
  let framesDropped: Int
  let lastFrameAt: Date?
}

enum DisplaySelection {
  static func selectedDisplayIds(
    available: [UInt32],
    captureAllDisplays: Bool,
    selectedDisplayIds: [UInt32]
  ) -> [UInt32] {
    guard !available.isEmpty else { return [] }
    let allowed = Set(available)
    let explicit = selectedDisplayIds.filter { allowed.contains($0) }
    if !explicit.isEmpty {
      return Array(dictOrdered: explicit)
    }
    if captureAllDisplays {
      return available
    }
    return [available[0]]
  }
}

enum CaptureOneShotError: LocalizedError {
  case timedOut

  var errorDescription: String? {
    switch self {
    case .timedOut:
      return "timed out waiting for a captured frame"
    }
  }
}

actor CaptureService {
  private let workerClient: CaptureWorkerStreamClient
  private var runningScope: RunningCaptureScope?

  init(
    onFrame: @escaping @Sendable (CapturedFrame) async -> Void,
    onFrameDropped: @escaping @Sendable (CGDirectDisplayID) async -> Void = { _ in }
  ) {
    self.workerClient = CaptureWorkerStreamClient(
      onFrame: onFrame,
      onFrameDropped: onFrameDropped
    )
  }

  func start(
    targetFps: Double,
    captureAllDisplays: Bool = false,
    selectedDisplayIds: [UInt32] = []
  ) async throws {
    await stop()
    let scope = RunningCaptureScope(
      targetFps: targetFps,
      captureAllDisplays: captureAllDisplays,
      selectedDisplayIds: selectedDisplayIds
    )
    try await workerClient.start(scope: scope)
    runningScope = scope
  }

  func stop() async {
    await workerClient.stop()
    runningScope = nil
  }

  func updateFps(_ fps: Double) async {
    guard let current = runningScope else { return }
    let next = RunningCaptureScope(
      targetFps: fps,
      captureAllDisplays: current.captureAllDisplays,
      selectedDisplayIds: current.selectedDisplayIds
    )
    runningScope = nil
    do {
      try await workerClient.start(scope: next)
      runningScope = next
    } catch {
      runningScope = current
      Log.capture.error(
        "capture worker fps update failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  func displayStats() async -> [CaptureDisplayStats] {
    await workerClient.displayStats()
  }

  static func captureOneFrame(
    targetFps: Double,
    captureAllDisplays: Bool,
    selectedDisplayIds: [UInt32],
    timeoutSeconds: Double,
    onFrameDropped: @escaping @Sendable (CGDirectDisplayID) async -> Void = { _ in }
  ) async throws -> CapturedFrame {
    do {
      return try await CaptureWorkerClient.captureOneFrame(
        displayId: selectedDisplayIds.first,
        timeoutSeconds: timeoutSeconds
      )
    } catch {
      await onFrameDropped(selectedDisplayIds.first ?? CGMainDisplayID())
      throw error
    }
  }
}

struct RunningCaptureScope: Sendable, Equatable {
  let targetFps: Double
  let captureAllDisplays: Bool
  let selectedDisplayIds: [UInt32]
}

actor ScreenCaptureService: NSObject {
  private var captures: [CGDirectDisplayID: DisplayCapture] = [:]
  private let onFrame: @Sendable (CapturedFrame) async -> Void
  private let onFrameDropped: @Sendable (CGDirectDisplayID) async -> Void
  private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  init(
    onFrame: @escaping @Sendable (CapturedFrame) async -> Void,
    onFrameDropped: @escaping @Sendable (CGDirectDisplayID) async -> Void = { _ in }
  ) {
    self.onFrame = onFrame
    self.onFrameDropped = onFrameDropped
  }

  func start(
    targetFps: Double,
    captureAllDisplays: Bool = false,
    selectedDisplayIds: [UInt32] = []
  ) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      true, onScreenWindowsOnly: true
    )
    guard !content.displays.isEmpty else {
      throw NSError(domain: "agentd", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"])
    }
    let availableIds = content.displays.map(\.displayID)
    let targetIds = Set(
      DisplaySelection.selectedDisplayIds(
        available: availableIds,
        captureAllDisplays: captureAllDisplays,
        selectedDisplayIds: selectedDisplayIds
      ))
    let displays = content.displays.filter { targetIds.contains($0.displayID) }

    // Filter excludes our own menu-bar app from its own captures.
    let myPID = ProcessInfo.processInfo.processIdentifier
    let excluded = content.applications.filter { $0.processID == myPID }

    var nextCaptures: [CGDirectDisplayID: DisplayCapture] = [:]
    do {
      for display in displays {
        let filter = SCContentFilter(
          display: display, excludingApplications: excluded, exceptingWindows: [])
        let cfg = Self.streamConfiguration(display: display, targetFps: targetFps)
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        let output = FrameOutput(
          ciContext: ciContext,
          displayId: display.displayID,
          widthPx: Int(display.width),
          heightPx: Int(display.height),
          displayScale: Self.displayScale(display.displayID),
          mainDisplay: display.displayID == CGMainDisplayID(),
          onFrame: onFrame,
          onFrameDropped: onFrameDropped
        )
        try stream.addStreamOutput(
          output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        nextCaptures[display.displayID] = DisplayCapture(
          stream: stream,
          output: output,
          configuration: cfg
        )
      }
    } catch {
      for capture in nextCaptures.values {
        try? await capture.stream.stopCapture()
      }
      throw error
    }

    captures = nextCaptures
    Log.capture.info(
      "capture started fps=\(targetFps, privacy: .public) displays=\(nextCaptures.keys.map(String.init).joined(separator: ","), privacy: .public)"
    )
  }

  func stop() async {
    for capture in captures.values {
      try? await capture.stream.stopCapture()
    }
    captures.removeAll()
    Log.capture.info("capture stopped")
  }

  func updateFps(_ fps: Double) async {
    guard !captures.isEmpty else { return }
    for (displayId, capture) in captures {
      capture.configuration.minimumFrameInterval = Self.frameInterval(fps)
      do {
        try await capture.stream.updateConfiguration(capture.configuration)
      } catch {
        Log.capture.error(
          "capture fps update failed display=\(displayId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
      }
    }
    Log.capture.info("capture fps updated=\(fps, privacy: .public)")
  }

  func displayStats() -> [CaptureDisplayStats] {
    captures.values.map { $0.output.stats() }.sorted { $0.displayId < $1.displayId }
  }

  static func captureOneFrame(
    targetFps: Double,
    captureAllDisplays: Bool,
    selectedDisplayIds: [UInt32],
    timeoutSeconds: Double,
    onFrameDropped: @escaping @Sendable (CGDirectDisplayID) async -> Void = { _ in }
  ) async throws -> CapturedFrame {
    let receiver = OneShotFrameReceiver()
    let service = ScreenCaptureService { frame in
      await receiver.record(frame)
    } onFrameDropped: { displayId in
      await onFrameDropped(displayId)
    }

    try await service.start(
      targetFps: targetFps,
      captureAllDisplays: captureAllDisplays,
      selectedDisplayIds: selectedDisplayIds
    )

    let waitTask = Task {
      try await receiver.wait()
    }
    let timeoutTask = Task {
      do {
        try await Task.sleep(nanoseconds: UInt64(max(0.5, timeoutSeconds) * 1_000_000_000))
        await receiver.fail(CaptureOneShotError.timedOut)
      } catch {
        await receiver.fail(error)
      }
    }

    do {
      let frame = try await waitTask.value
      timeoutTask.cancel()
      await service.stop()
      return frame
    } catch {
      timeoutTask.cancel()
      await service.stop()
      throw error
    }
  }

  private static func streamConfiguration(
    display: SCDisplay,
    targetFps: Double
  ) -> SCStreamConfiguration {
    let cfg = SCStreamConfiguration()
    cfg.width = Int(display.width)
    cfg.height = Int(display.height)
    cfg.minimumFrameInterval = frameInterval(targetFps)
    cfg.queueDepth = 5
    cfg.showsCursor = true
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    return cfg
  }

  private static func frameInterval(_ fps: Double) -> CMTime {
    CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(fps))))
  }

  private static func displayScale(_ displayId: CGDirectDisplayID) -> Double? {
    let pixelWidth = CGDisplayPixelsWide(displayId)
    guard pixelWidth > 0 else { return nil }
    let boundsWidth = CGDisplayBounds(displayId).width
    guard boundsWidth > 0 else { return nil }
    return Double(pixelWidth) / Double(boundsWidth)
  }
}

actor CaptureWorkerStreamClient {
  private let executable: URL
  private let onFrame: @Sendable (CapturedFrame) async -> Void
  private let onFrameDropped: @Sendable (CGDirectDisplayID) async -> Void
  private var streams: [CGDirectDisplayID: CaptureWorkerStream] = [:]

  init(
    executable: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
    onFrame: @escaping @Sendable (CapturedFrame) async -> Void,
    onFrameDropped: @escaping @Sendable (CGDirectDisplayID) async -> Void
  ) {
    self.executable = executable
    self.onFrame = onFrame
    self.onFrameDropped = onFrameDropped
  }

  func start(scope: RunningCaptureScope) async throws {
    stop()
    let displays = try await MainActor.run { try SystemDisplayDiagnosticsProbe.systemDisplays() }
    let selectedIds = DisplaySelection.selectedDisplayIds(
      available: displays.map(\.displayId),
      captureAllDisplays: scope.captureAllDisplays,
      selectedDisplayIds: scope.selectedDisplayIds
    )
    guard !selectedIds.isEmpty else {
      throw NSError(domain: "agentd", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"])
    }
    let byId = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayId, $0) })
    var started: [CGDirectDisplayID: CaptureWorkerStream] = [:]
    do {
      for displayId in selectedIds {
        guard let display = byId[displayId] else { continue }
        let stream = CaptureWorkerStream(
          display: display,
          onFrame: onFrame,
          onFrameDropped: onFrameDropped
        )
        try stream.start(executable: executable, fps: scope.targetFps)
        started[displayId] = stream
      }
    } catch {
      for stream in started.values {
        stream.stop()
      }
      throw error
    }
    streams = started
    Log.capture.info(
      "capture worker stream started fps=\(scope.targetFps, privacy: .public) displays=\(selectedIds.map(String.init).joined(separator: ","), privacy: .public)"
    )
  }

  func stop() {
    for stream in streams.values {
      stream.stop()
    }
    streams.removeAll()
    Log.capture.info("capture worker stream stopped")
  }

  func displayStats() -> [CaptureDisplayStats] {
    streams.values.map { $0.stats() }.sorted { $0.displayId < $1.displayId }
  }
}

final class CaptureWorkerStream: @unchecked Sendable {
  private let display: DisplayDiagnostic
  private let supervisor = CaptureWorkerSupervisor()
  private let stdout = Pipe()
  private let stderr = Pipe()
  private let reader: CaptureWorkerStreamLineReader
  private let statsRecorder: CaptureWorkerStreamStatsRecorder
  private let dispatcher: BufferedFrameDispatcher

  init(
    display: DisplayDiagnostic,
    onFrame: @escaping @Sendable (CapturedFrame) async -> Void,
    onFrameDropped: @escaping @Sendable (CGDirectDisplayID) async -> Void
  ) {
    self.display = display
    self.statsRecorder = CaptureWorkerStreamStatsRecorder(display: display)
    self.dispatcher = BufferedFrameDispatcher(
      onFrame: onFrame,
      onDropped: { await onFrameDropped(display.displayId) }
    )
    self.reader = CaptureWorkerStreamLineReader { [statsRecorder, dispatcher] payload in
      do {
        let frame = try CaptureWorkerFrameCodec.frame(from: payload)
        if dispatcher.yield(frame) {
          statsRecorder.recordEnqueued(frame)
        } else {
          statsRecorder.recordDropped()
        }
      } catch {
        statsRecorder.recordDropped()
        Log.capture.error(
          "capture worker frame decode failed display=\(payload.displayId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
      }
    } onDecodeError: { [statsRecorder, display] message in
      statsRecorder.recordDropped()
      Log.capture.error(
        "capture worker stream decode failed display=\(display.displayId, privacy: .public) error=\(message, privacy: .public)"
      )
    }
  }

  func start(executable: URL, fps: Double) throws {
    stdout.fileHandleForReading.readabilityHandler = { @Sendable [reader] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      reader.append(data)
    }
    stderr.fileHandleForReading.readabilityHandler = { @Sendable [display] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      guard let message = String(data: data, encoding: .utf8) else { return }
      Log.capture.warning(
        "capture worker stderr display=\(display.displayId, privacy: .public) \(message, privacy: .public)"
      )
    }
    _ = try supervisor.start(
      CaptureWorkerProcessSpec(
        executableURL: executable,
        arguments: [
          "capture-worker-stream",
          "--display-id", String(display.displayId),
          "--fps", String(max(0.2, fps)),
        ],
        standardOutput: stdout,
        standardError: stderr
      )
    )
  }

  func stop() {
    stdout.fileHandleForReading.readabilityHandler = nil
    stderr.fileHandleForReading.readabilityHandler = nil
    _ = supervisor.terminate(graceSeconds: 2)
    dispatcher.finish()
  }

  func stats() -> CaptureDisplayStats {
    statsRecorder.snapshot()
  }
}

final class CaptureWorkerStreamLineReader: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private let onPayload: @Sendable (CaptureWorkerFramePayload) -> Void
  private let onDecodeError: @Sendable (String) -> Void

  init(
    onPayload: @escaping @Sendable (CaptureWorkerFramePayload) -> Void,
    onDecodeError: @escaping @Sendable (String) -> Void
  ) {
    self.onPayload = onPayload
    self.onDecodeError = onDecodeError
  }

  func append(_ data: Data) {
    let lines = lock.withLock { () -> [Data] in
      buffer.append(data)
      var lines: [Data] = []
      while let newline = buffer.firstIndex(of: 0x0A) {
        lines.append(buffer[..<newline])
        buffer.removeSubrange(...newline)
      }
      return lines
    }
    for line in lines where !line.isEmpty {
      do {
        onPayload(try CaptureWorkerFrameCodec.decodePayload(line))
      } catch {
        onDecodeError(error.localizedDescription)
      }
    }
  }
}

final class CaptureWorkerStreamStatsRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private let display: DisplayDiagnostic
  private var widthPx: Int
  private var heightPx: Int
  private var framesEnqueued = 0
  private var framesDropped = 0
  private var lastFrameAt: Date?

  init(display: DisplayDiagnostic) {
    self.display = display
    self.widthPx = display.width
    self.heightPx = display.height
  }

  func recordEnqueued(_ frame: CapturedFrame) {
    lock.lock()
    framesEnqueued += 1
    widthPx = frame.cgImage.width
    heightPx = frame.cgImage.height
    lastFrameAt = frame.timestamp
    lock.unlock()
  }

  func recordDropped() {
    lock.lock()
    framesDropped += 1
    lock.unlock()
  }

  func snapshot() -> CaptureDisplayStats {
    lock.lock()
    defer { lock.unlock() }
    return CaptureDisplayStats(
      displayId: display.displayId,
      widthPx: widthPx,
      heightPx: heightPx,
      displayScale: display.scale,
      mainDisplay: display.isMain,
      framesEnqueued: framesEnqueued,
      framesDropped: framesDropped,
      lastFrameAt: lastFrameAt
    )
  }
}

actor OneShotFrameReceiver {
  private var frame: CapturedFrame?
  private var continuation: CheckedContinuation<CapturedFrame, any Error>?

  func record(_ frame: CapturedFrame) {
    guard self.frame == nil else { return }
    self.frame = frame
    continuation?.resume(returning: frame)
    continuation = nil
  }

  func wait() async throws -> CapturedFrame {
    if let frame { return frame }
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
    }
  }

  func fail(_ error: any Error) {
    guard frame == nil else { return }
    continuation?.resume(throwing: error)
    continuation = nil
  }
}

private struct DisplayCapture {
  let stream: SCStream
  let output: FrameOutput
  let configuration: SCStreamConfiguration
}

private final class FrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
  let ciContext: CIContext
  let displayId: CGDirectDisplayID
  let widthPx: Int
  let heightPx: Int
  let displayScale: Double?
  let mainDisplay: Bool
  let dispatcher: BufferedFrameDispatcher
  private let statsLock = NSLock()
  private var framesEnqueued = 0
  private var framesDropped = 0
  private var lastFrameAt: Date?

  init(
    ciContext: CIContext,
    displayId: CGDirectDisplayID,
    widthPx: Int,
    heightPx: Int,
    displayScale: Double?,
    mainDisplay: Bool,
    onFrame: @escaping @Sendable (CapturedFrame) async -> Void,
    onFrameDropped: @escaping @Sendable (CGDirectDisplayID) async -> Void
  ) {
    self.ciContext = ciContext
    self.displayId = displayId
    self.widthPx = widthPx
    self.heightPx = heightPx
    self.displayScale = displayScale
    self.mainDisplay = mainDisplay
    self.dispatcher = BufferedFrameDispatcher(
      onFrame: onFrame,
      onDropped: { await onFrameDropped(displayId) }
    )
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, sampleBuffer.isValid,
      let pixelBuffer = sampleBuffer.imageBuffer
    else { return }
    let ci = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
    let frame = CapturedFrame(
      timestamp: Date(),
      cgImage: cg,
      displayId: displayId,
      displayScale: displayScale,
      mainDisplay: mainDisplay
    )
    if dispatcher.yield(frame) {
      recordEnqueued(at: frame.timestamp)
    } else {
      recordDropped()
    }
  }

  func stats() -> CaptureDisplayStats {
    statsLock.lock()
    defer { statsLock.unlock() }
    return CaptureDisplayStats(
      displayId: displayId,
      widthPx: widthPx,
      heightPx: heightPx,
      displayScale: displayScale,
      mainDisplay: mainDisplay,
      framesEnqueued: framesEnqueued,
      framesDropped: framesDropped,
      lastFrameAt: lastFrameAt
    )
  }

  private func recordEnqueued(at date: Date) {
    statsLock.lock()
    framesEnqueued += 1
    lastFrameAt = date
    statsLock.unlock()
  }

  private func recordDropped() {
    statsLock.lock()
    framesDropped += 1
    statsLock.unlock()
  }
}

final class BufferedFrameDispatcher: @unchecked Sendable {
  private let continuation: AsyncStream<CapturedFrame>.Continuation
  private let task: Task<Void, Never>
  private let onDropped: @Sendable () async -> Void

  init(
    bufferingNewest: Int = 2,
    onFrame: @escaping @Sendable (CapturedFrame) async -> Void,
    onDropped: @escaping @Sendable () async -> Void
  ) {
    var continuation: AsyncStream<CapturedFrame>.Continuation!
    let stream = AsyncStream<CapturedFrame>(bufferingPolicy: .bufferingNewest(bufferingNewest)) {
      cont in
      continuation = cont
    }
    self.continuation = continuation
    self.onDropped = onDropped
    self.task = Task {
      for await frame in stream {
        await onFrame(frame)
      }
    }
  }

  @discardableResult
  func yield(_ frame: CapturedFrame) -> Bool {
    switch continuation.yield(frame) {
    case .dropped:
      Task { await onDropped() }
      return false
    case .enqueued:
      return true
    case .terminated:
      Task { await onDropped() }
      return false
    @unknown default:
      Task { await onDropped() }
      return false
    }
  }

  func finish() {
    continuation.finish()
    task.cancel()
  }

  deinit {
    finish()
  }
}

extension Array where Element: Hashable {
  init(dictOrdered values: [Element]) {
    var seen = Set<Element>()
    self = values.filter { seen.insert($0).inserted }
  }
}
