import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct ProcessedFrame: Sendable, Codable {
    let frameHash: String
    let perceptualHash: UInt64
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

    enum CodingKeys: String, CodingKey {
        case frameHash
        case perceptualHash
        case capturedAt
        case bundleId
        case appName
        case windowTitle
        case documentPath
        case ocrText
        case ocrConfidence
        case widthPx
        case heightPx
        case bytesPng
    }

    init(
        frameHash: String,
        perceptualHash: UInt64,
        capturedAt: Date,
        bundleId: String,
        appName: String,
        windowTitle: String,
        documentPath: String?,
        ocrText: String,
        ocrConfidence: Float,
        widthPx: Int,
        heightPx: Int,
        bytesPng: Int
    ) {
        self.frameHash = frameHash
        self.perceptualHash = perceptualHash
        self.capturedAt = capturedAt
        self.bundleId = bundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.documentPath = documentPath
        self.ocrText = ocrText
        self.ocrConfidence = ocrConfidence
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.bytesPng = bytesPng
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frameHash = try container.decode(String.self, forKey: .frameHash)
        if let value = try? container.decode(UInt64.self, forKey: .perceptualHash) {
            perceptualHash = value
        } else {
            let raw = try container.decode(String.self, forKey: .perceptualHash)
            perceptualHash = UInt64(raw) ?? 0
        }
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        bundleId = try container.decode(String.self, forKey: .bundleId)
        appName = try container.decode(String.self, forKey: .appName)
        windowTitle = try container.decode(String.self, forKey: .windowTitle)
        documentPath = try container.decodeIfPresent(String.self, forKey: .documentPath)
        ocrText = try container.decode(String.self, forKey: .ocrText)
        ocrConfidence = try container.decode(Float.self, forKey: .ocrConfidence)
        widthPx = try container.decode(Int.self, forKey: .widthPx)
        heightPx = try container.decode(Int.self, forKey: .heightPx)
        if let value = try? container.decode(Int.self, forKey: .bytesPng) {
            bytesPng = value
        } else {
            let raw = try container.decode(String.self, forKey: .bytesPng)
            bytesPng = Int(raw) ?? 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frameHash, forKey: .frameHash)
        try container.encode(String(perceptualHash), forKey: .perceptualHash)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(bundleId, forKey: .bundleId)
        try container.encode(appName, forKey: .appName)
        try container.encode(windowTitle, forKey: .windowTitle)
        try container.encodeIfPresent(documentPath, forKey: .documentPath)
        try container.encode(ocrText, forKey: .ocrText)
        try container.encode(ocrConfidence, forKey: .ocrConfidence)
        try container.encode(widthPx, forKey: .widthPx)
        try container.encode(heightPx, forKey: .heightPx)
        try container.encode(String(bytesPng), forKey: .bytesPng)
    }
}

struct Batch: Sendable, Codable {
    let batchId: String
    let deviceId: String
    let organizationId: String
    let workspaceId: String?
    let userId: String?
    let projectId: String?
    let repository: String?
    let startedAt: Date
    let endedAt: Date
    let frames: [ProcessedFrame]
    let droppedCounts: DropCounts
}

struct DropCounts: Sendable, Codable {
    let secret: Int
    let duplicate: Int
    let deniedApp: Int
    let deniedPath: Int
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
            perceptualHash: phash.value,
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
            batchId: UUID().uuidString,
            deviceId: config.deviceId,
            organizationId: config.organizationId,
            workspaceId: config.workspaceId,
            userId: config.userId,
            projectId: config.projectId,
            repository: config.repository,
            startedAt: startedAt,
            endedAt: Date(),
            frames: pending,
            droppedCounts: DropCounts(
                secret: droppedSecret,
                duplicate: droppedDup,
                deniedApp: droppedDeniedApp,
                deniedPath: droppedDeniedPath
            )
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
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
