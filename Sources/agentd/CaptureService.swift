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

actor CaptureService: NSObject {
  private var stream: SCStream?
  private var output: FrameOutput?
  private var streamConfiguration: SCStreamConfiguration?
  private let onFrame: @Sendable (CapturedFrame) async -> Void
  private let onFrameDropped: @Sendable () async -> Void
  private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  init(
    onFrame: @escaping @Sendable (CapturedFrame) async -> Void,
    onFrameDropped: @escaping @Sendable () async -> Void = {}
  ) {
    self.onFrame = onFrame
    self.onFrameDropped = onFrameDropped
  }

  func start(targetFps: Double) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      true, onScreenWindowsOnly: true
    )
    guard let display = content.displays.first else {
      throw NSError(domain: "agentd", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"])
    }

    // Filter excludes our own menu-bar app from its own captures.
    let myPID = ProcessInfo.processInfo.processIdentifier
    let excluded = content.applications.filter { $0.processID == myPID }
    let filter = SCContentFilter(
      display: display, excludingApplications: excluded, exceptingWindows: [])

    let cfg = SCStreamConfiguration()
    cfg.width = Int(display.width)
    cfg.height = Int(display.height)
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(targetFps))))
    cfg.queueDepth = 5
    cfg.showsCursor = true
    cfg.pixelFormat = kCVPixelFormatType_32BGRA

    let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
    let output = FrameOutput(
      ciContext: ciContext,
      displayId: display.displayID,
      displayScale: Self.displayScale(display.displayID),
      mainDisplay: display.displayID == CGMainDisplayID(),
      onFrame: onFrame,
      onFrameDropped: onFrameDropped
    )
    try stream.addStreamOutput(
      output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
    try await stream.startCapture()

    self.stream = stream
    self.output = output
    self.streamConfiguration = cfg
    Log.capture.info(
      "capture started fps=\(targetFps, privacy: .public) display=\(display.displayID, privacy: .public)"
    )
  }

  func stop() async {
    if let stream {
      try? await stream.stopCapture()
    }
    stream = nil
    output = nil
    streamConfiguration = nil
    Log.capture.info("capture stopped")
  }

  func updateFps(_ fps: Double) async {
    guard let stream, let cfg = streamConfiguration else { return }
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(fps))))
    do {
      try await stream.updateConfiguration(cfg)
      Log.capture.info("capture fps updated=\(fps, privacy: .public)")
    } catch {
      Log.capture.error(
        "capture fps update failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private static func displayScale(_ displayId: CGDirectDisplayID) -> Double? {
    let pixelWidth = CGDisplayPixelsWide(displayId)
    guard pixelWidth > 0 else { return nil }
    let boundsWidth = CGDisplayBounds(displayId).width
    guard boundsWidth > 0 else { return nil }
    return Double(pixelWidth) / Double(boundsWidth)
  }
}

private final class FrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
  let ciContext: CIContext
  let displayId: CGDirectDisplayID
  let displayScale: Double?
  let mainDisplay: Bool
  let dispatcher: BufferedFrameDispatcher

  init(
    ciContext: CIContext,
    displayId: CGDirectDisplayID,
    displayScale: Double?,
    mainDisplay: Bool,
    onFrame: @escaping @Sendable (CapturedFrame) async -> Void,
    onFrameDropped: @escaping @Sendable () async -> Void
  ) {
    self.ciContext = ciContext
    self.displayId = displayId
    self.displayScale = displayScale
    self.mainDisplay = mainDisplay
    self.dispatcher = BufferedFrameDispatcher(onFrame: onFrame, onDropped: onFrameDropped)
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
    dispatcher.yield(frame)
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

  func yield(_ frame: CapturedFrame) {
    switch continuation.yield(frame) {
    case .dropped:
      Task { await onDropped() }
    case .enqueued, .terminated:
      break
    @unknown default:
      break
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
