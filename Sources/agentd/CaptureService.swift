import Foundation
import ScreenCaptureKit
import CoreVideo
import CoreImage
import CoreGraphics
import AppKit

struct CapturedFrame: Sendable {
    let timestamp: Date
    let cgImage: CGImage
    let displayId: CGDirectDisplayID
}

actor CaptureService: NSObject {
    private var stream: SCStream?
    private var output: FrameOutput?
    private let onFrame: @Sendable (CapturedFrame) async -> Void
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(onFrame: @escaping @Sendable (CapturedFrame) async -> Void) {
        self.onFrame = onFrame
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
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.width = Int(display.width)
        cfg.height = Int(display.height)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(targetFps))))
        cfg.queueDepth = 5
        cfg.showsCursor = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        let output = FrameOutput(ciContext: ciContext, displayId: display.displayID, onFrame: onFrame)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()

        self.stream = stream
        self.output = output
        Log.capture.info("capture started fps=\(targetFps, privacy: .public) display=\(display.displayID, privacy: .public)")
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        output = nil
        Log.capture.info("capture stopped")
    }

    func updateFps(_ fps: Double) async {
        guard let stream else { return }
        let cfg = SCStreamConfiguration()
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(fps))))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        try? await stream.updateConfiguration(cfg)
    }
}

private final class FrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let ciContext: CIContext
    let displayId: CGDirectDisplayID
    let onFrame: @Sendable (CapturedFrame) async -> Void

    init(ciContext: CIContext, displayId: CGDirectDisplayID,
         onFrame: @escaping @Sendable (CapturedFrame) async -> Void) {
        self.ciContext = ciContext
        self.displayId = displayId
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let frame = CapturedFrame(timestamp: Date(), cgImage: cg, displayId: displayId)
        Task { await onFrame(frame) }
    }
}
