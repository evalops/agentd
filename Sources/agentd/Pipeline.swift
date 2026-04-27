import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ProcessedFrame: Sendable, Codable {
    let frameHash: String
    let phash: UInt64
    let capturedAt: Date
    let bundleId: String
    let appName: String
    let windowTitle: String
    let documentPath: String?
    let ocrText: String
    let ocrConfidence: Float
    let widthPx: Int
    let heightPx: Int
    let bytesPng: Int
}

struct Batch: Sendable, Codable {
    let id: String
    let deviceId: String
    let orgId: String
    let startedAt: Date
    let endedAt: Date
    let frames: [ProcessedFrame]
    let droppedSecretCount: Int
    let droppedDuplicateCount: Int
    let droppedDeniedAppCount: Int
    let droppedDeniedPathCount: Int
}

actor FramePipeline {
    private var config: AgentConfig
    private let ocr = VisionOCR()
    private var lastHash: PerceptualHash?
    private let phashThreshold = 5

    private var pending: [ProcessedFrame] = []
    private var startedAt = Date()
    private var droppedSecret = 0
    private var droppedDup = 0
    private var droppedDeniedApp = 0
    private var droppedDeniedPath = 0

    private let onBatch: @Sendable (Batch) async -> Void

    init(config: AgentConfig, onBatch: @escaping @Sendable (Batch) async -> Void) {
        self.config = config
        self.onBatch = onBatch
    }

    func updateConfig(_ cfg: AgentConfig) {
        self.config = cfg
    }

    func consume(_ frame: CapturedFrame, context: WindowContext?) async {
        guard let ctx = context else { return }

        if config.deniedBundleIds.contains(ctx.bundleId) {
            droppedDeniedApp += 1
            Log.scrub.debug("denied bundle \(ctx.bundleId, privacy: .public)")
            return
        }
        if !config.allowedBundleIds.isEmpty,
           !config.allowedBundleIds.contains(ctx.bundleId) {
            droppedDeniedApp += 1
            return
        }

        let pathPolicy = PathPolicy(deniedPrefixes: config.deniedPathPrefixes)
        if let p = ctx.documentPath, pathPolicy.deny(p) {
            droppedDeniedPath += 1
            Log.scrub.info("denied path bundle=\(ctx.bundleId, privacy: .public)")
            return
        }
        if config.pauseWindowTitlePatterns.contains(where: { ctx.windowTitle.contains($0) }) {
            droppedDeniedApp += 1
            return
        }

        guard let phash = PerceptualHash(cgImage: frame.cgImage) else { return }
        if let last = lastHash, PerceptualHash.distance(last, phash) <= phashThreshold {
            droppedDup += 1
            return
        }

        let ocrResult: OCRResult
        do {
            ocrResult = try await ocr.recognize(cgImage: frame.cgImage)
        } catch {
            Log.ocr.error("ocr failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        switch SecretScrubber.evaluate(ocrResult.text) {
        case .dropped(let reason):
            droppedSecret += 1
            Log.scrub.warning("frame dropped secret=\(reason, privacy: .public)")
            return
        case .clean:
            break
        }

        let pngBytes = encodePng(frame.cgImage) ?? 0
        let frameHash = sha256Hex("\(phash.value)|\(frame.timestamp.timeIntervalSince1970)|\(ctx.bundleId)|\(ctx.windowTitle)|\(ocrResult.text)")

        let processed = ProcessedFrame(
            frameHash: frameHash,
            phash: phash.value,
            capturedAt: frame.timestamp,
            bundleId: ctx.bundleId,
            appName: ctx.appName,
            windowTitle: ctx.windowTitle,
            documentPath: ctx.documentPath,
            ocrText: ocrResult.text,
            ocrConfidence: ocrResult.confidence,
            widthPx: frame.cgImage.width,
            heightPx: frame.cgImage.height,
            bytesPng: pngBytes
        )

        pending.append(processed)
        lastHash = phash

        if pending.count >= config.maxFramesPerBatch {
            await flush()
        }
    }

    func flush() async {
        guard !pending.isEmpty || hasDrops() else { return }
        let batch = Batch(
            id: UUID().uuidString,
            deviceId: config.deviceId,
            orgId: config.orgId,
            startedAt: startedAt,
            endedAt: Date(),
            frames: pending,
            droppedSecretCount: droppedSecret,
            droppedDuplicateCount: droppedDup,
            droppedDeniedAppCount: droppedDeniedApp,
            droppedDeniedPathCount: droppedDeniedPath
        )
        pending.removeAll(keepingCapacity: true)
        droppedSecret = 0; droppedDup = 0; droppedDeniedApp = 0; droppedDeniedPath = 0
        startedAt = Date()
        await onBatch(batch)
    }

    private func hasDrops() -> Bool {
        droppedSecret + droppedDup + droppedDeniedApp + droppedDeniedPath > 0
    }

    private func encodePng(_ image: CGImage) -> Int? {
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, nil)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return data.length
    }

    private func sha256Hex(_ s: String) -> String {
        let bytes = Array(s.utf8)
        // Use CommonCrypto via bridging-header would be ideal; v0 falls back to a simple FNV-1a 64
        // hex'd to 64 chars so the field shape matches the future SHA-256 swap-out.
        var h: UInt64 = 0xcbf29ce484222325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        let hex64 = String(h, radix: 16)
        let pad = String(repeating: "0", count: max(0, 16 - hex64.count))
        let core = pad + hex64
        // pad out to 64 hex chars to match sha256 width — trivial v0 stand-in
        return String(repeating: core, count: 4).prefix(64).description
    }
}
