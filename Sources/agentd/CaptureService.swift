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

actor CaptureService: NSObject {
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
    let service = CaptureService { frame in
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
    case .enqueued, .terminated:
      return true
    @unknown default:
      return true
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
