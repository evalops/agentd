// SPDX-License-Identifier: BUSL-1.1

import CoreGraphics
import CryptoKit
import Foundation

protocol OCRRecognizing: Sendable {
  func recognize(cgImage: CGImage) async throws -> OCRResult
}

struct ProcessedFrame: Sendable, Codable {
  let frameHash: String
  let perceptualHash: UInt64
  let capturedAt: Date
  let bundleId: String
  let appName: String
  let windowTitle: String
  let documentPath: String?
  let ocrText: String
  let ocrTextTruncated: Bool
  let ocrConfidence: Float
  let widthPx: Int
  let heightPx: Int
  let bytesPng: Int
  let displayId: UInt32
  let displayScale: Double?
  let mainDisplay: Bool

  enum CodingKeys: String, CodingKey {
    case frameHash
    case perceptualHash
    case capturedAt
    case bundleId
    case appName
    case windowTitle
    case documentPath
    case ocrText
    case ocrTextTruncated
    case ocrConfidence
    case widthPx
    case heightPx
    case bytesPng
    case displayId
    case displayScale
    case mainDisplay
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
    ocrTextTruncated: Bool = false,
    ocrConfidence: Float,
    widthPx: Int,
    heightPx: Int,
    bytesPng: Int,
    displayId: UInt32 = 0,
    displayScale: Double? = nil,
    mainDisplay: Bool = false
  ) {
    self.frameHash = frameHash
    self.perceptualHash = perceptualHash
    self.capturedAt = capturedAt
    self.bundleId = bundleId
    self.appName = appName
    self.windowTitle = windowTitle
    self.documentPath = documentPath
    self.ocrText = ocrText
    self.ocrTextTruncated = ocrTextTruncated
    self.ocrConfidence = ocrConfidence
    self.widthPx = widthPx
    self.heightPx = heightPx
    self.bytesPng = bytesPng
    self.displayId = displayId
    self.displayScale = displayScale
    self.mainDisplay = mainDisplay
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
    ocrTextTruncated = try container.decodeIfPresent(Bool.self, forKey: .ocrTextTruncated) ?? false
    ocrConfidence = try container.decode(Float.self, forKey: .ocrConfidence)
    widthPx = try container.decode(Int.self, forKey: .widthPx)
    heightPx = try container.decode(Int.self, forKey: .heightPx)
    if let value = try? container.decode(Int.self, forKey: .bytesPng) {
      bytesPng = value
    } else {
      let raw = try container.decode(String.self, forKey: .bytesPng)
      bytesPng = Int(raw) ?? 0
    }
    if let value = try? container.decode(UInt32.self, forKey: .displayId) {
      displayId = value
    } else if let raw = try? container.decode(String.self, forKey: .displayId) {
      displayId = UInt32(raw) ?? 0
    } else {
      displayId = 0
    }
    displayScale = try container.decodeIfPresent(Double.self, forKey: .displayScale)
    mainDisplay = try container.decodeIfPresent(Bool.self, forKey: .mainDisplay) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(frameHash, forKey: .frameHash)
    // Connect-protocol JSON serializes int64/uint64 as strings; keep this wire contract aligned with cmd/chronicle.
    try container.encode(String(perceptualHash), forKey: .perceptualHash)
    try container.encode(capturedAt, forKey: .capturedAt)
    try container.encode(bundleId, forKey: .bundleId)
    try container.encode(appName, forKey: .appName)
    try container.encode(windowTitle, forKey: .windowTitle)
    try container.encodeIfPresent(documentPath, forKey: .documentPath)
    try container.encode(ocrText, forKey: .ocrText)
    try container.encode(ocrTextTruncated, forKey: .ocrTextTruncated)
    try container.encode(ocrConfidence, forKey: .ocrConfidence)
    try container.encode(widthPx, forKey: .widthPx)
    try container.encode(heightPx, forKey: .heightPx)
    // Connect-protocol JSON serializes int64/uint64 as strings; keep this wire contract aligned with cmd/chronicle.
    try container.encode(String(bytesPng), forKey: .bytesPng)
    try container.encode(displayId, forKey: .displayId)
    try container.encodeIfPresent(displayScale, forKey: .displayScale)
    try container.encode(mainDisplay, forKey: .mainDisplay)
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
  let metadata: [String: String]
  let startedAt: Date
  let endedAt: Date
  let captureWindow: CaptureWindow
  let frames: [ProcessedFrame]
  let droppedCounts: DropCounts

  init(
    batchId: String,
    deviceId: String,
    organizationId: String,
    workspaceId: String?,
    userId: String?,
    projectId: String?,
    repository: String?,
    metadata: [String: String] = [:],
    startedAt: Date,
    endedAt: Date,
    captureWindow: CaptureWindow? = nil,
    frames: [ProcessedFrame],
    droppedCounts: DropCounts
  ) {
    self.batchId = batchId
    self.deviceId = deviceId
    self.organizationId = organizationId
    self.workspaceId = workspaceId
    self.userId = userId
    self.projectId = projectId
    self.repository = repository
    self.metadata = metadata
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.captureWindow = captureWindow ?? CaptureWindow(startedAt: startedAt, endedAt: endedAt)
    self.frames = frames
    self.droppedCounts = droppedCounts
  }

  enum CodingKeys: String, CodingKey {
    case batchId
    case deviceId
    case organizationId
    case workspaceId
    case userId
    case projectId
    case repository
    case metadata
    case startedAt
    case endedAt
    case captureWindow
    case frames
    case droppedCounts
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let startedAt = try container.decode(Date.self, forKey: .startedAt)
    let endedAt = try container.decode(Date.self, forKey: .endedAt)
    self.init(
      batchId: try container.decode(String.self, forKey: .batchId),
      deviceId: try container.decode(String.self, forKey: .deviceId),
      organizationId: try container.decode(String.self, forKey: .organizationId),
      workspaceId: try container.decodeIfPresent(String.self, forKey: .workspaceId),
      userId: try container.decodeIfPresent(String.self, forKey: .userId),
      projectId: try container.decodeIfPresent(String.self, forKey: .projectId),
      repository: try container.decodeIfPresent(String.self, forKey: .repository),
      metadata: try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:],
      startedAt: startedAt,
      endedAt: endedAt,
      captureWindow: try container.decodeIfPresent(CaptureWindow.self, forKey: .captureWindow),
      frames: try container.decode([ProcessedFrame].self, forKey: .frames),
      droppedCounts: try container.decode(DropCounts.self, forKey: .droppedCounts)
    )
  }
}

struct CaptureWindow: Sendable, Codable, Equatable {
  let startedAt: Date
  let endedAt: Date
}

struct DropCounts: Sendable, Codable {
  let secret: Int
  let duplicate: Int
  let deniedApp: Int
  let deniedPath: Int
  let droppedBackpressure: Int

  enum CodingKeys: String, CodingKey {
    case secret
    case duplicate
    case deniedApp
    case deniedPath
    case droppedBackpressure
  }

  init(secret: Int, duplicate: Int, deniedApp: Int, deniedPath: Int, droppedBackpressure: Int = 0) {
    self.secret = secret
    self.duplicate = duplicate
    self.deniedApp = deniedApp
    self.deniedPath = deniedPath
    self.droppedBackpressure = droppedBackpressure
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    secret = try container.decode(Int.self, forKey: .secret)
    duplicate = try container.decode(Int.self, forKey: .duplicate)
    deniedApp = try container.decode(Int.self, forKey: .deniedApp)
    deniedPath = try container.decode(Int.self, forKey: .deniedPath)
    droppedBackpressure = try container.decodeIfPresent(Int.self, forKey: .droppedBackpressure) ?? 0
  }
}

struct OcrBudgetController: Sendable, Equatable {
  static func maxPersistedCharacters(
    config: AgentConfig,
    pendingBytes: Int64,
    droppedBackpressure: Int
  ) -> Int {
    guard config.maxOcrTextChars > 0 else { return 0 }
    let minChars = max(0, min(config.adaptiveOcrMinChars, config.maxOcrTextChars))
    let underBackpressure =
      config.adaptiveOcrBackpressureThreshold > 0
      && droppedBackpressure >= config.adaptiveOcrBackpressureThreshold
    let overBacklog =
      config.adaptiveOcrBacklogBytes > 0 && pendingBytes >= config.adaptiveOcrBacklogBytes
    guard underBackpressure || overBacklog else {
      return config.maxOcrTextChars
    }
    return minChars
  }
}

struct DedupWindow: Sendable {
  private var hashes: [PerceptualHash] = []
  let capacity: Int
  let threshold: Int

  init(capacity: Int = 16, threshold: Int = 5) {
    self.capacity = capacity
    self.threshold = threshold
  }

  func containsDuplicate(of hash: PerceptualHash) -> Bool {
    hashes.contains { PerceptualHash.distance($0, hash) <= threshold }
  }

  mutating func remember(_ hash: PerceptualHash) {
    hashes.append(hash)
    if hashes.count > capacity {
      hashes.removeFirst(hashes.count - capacity)
    }
  }
}

struct OcrDiffSampler: Sendable {
  static func normalizedText(_ text: String) -> String {
    text
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  static func shouldOverrideDuplicate(
    previousText: String?,
    candidateText: String,
    threshold: Double
  ) -> Bool {
    let candidate = normalizedText(candidateText)
    guard !candidate.isEmpty else { return false }
    guard let previousText else { return true }
    let previous = normalizedText(previousText)
    guard !previous.isEmpty else { return true }
    return shingledSimilarity(previous, candidate) < threshold
  }

  static func shingledSimilarity(_ lhs: String, _ rhs: String) -> Double {
    let lhsShingles = shingles(lhs)
    let rhsShingles = shingles(rhs)
    guard !lhsShingles.isEmpty || !rhsShingles.isEmpty else { return 1 }
    guard !lhsShingles.isEmpty, !rhsShingles.isEmpty else { return 0 }
    let intersection = lhsShingles.intersection(rhsShingles).count
    let union = lhsShingles.union(rhsShingles).count
    guard union > 0 else { return 1 }
    return Double(intersection) / Double(union)
  }

  private static func shingles(_ text: String) -> Set<String> {
    let tokens = text.split(separator: " ").map(String.init)
    guard tokens.count > 1 else { return Set(tokens) }
    var values = Set<String>()
    for index in 0..<(tokens.count - 1) {
      values.insert("\(tokens[index]) \(tokens[index + 1])")
    }
    return values
  }
}

actor FramePipeline {
  private var config: AgentConfig
  private let ocr: any OCRRecognizing
  private var dedupWindow = DedupWindow(capacity: 16, threshold: 5)
  private var lastEmittedOcrText: String?
  private var sparseFrameStore: SparseFrameStore?
  private var sparseFrameStoreOptions: SparseFrameStoreOptions?

  private var pending: [ProcessedFrame] = []
  private var startedAt = Date()
  private var droppedSecret = 0
  private var droppedDup = 0
  private var droppedDeniedApp = 0
  private var droppedDeniedPath = 0
  private var droppedBackpressure = 0

  private let onBatch: @Sendable (Batch) async -> SubmitResult

  init(
    config: AgentConfig,
    ocr: any OCRRecognizing = VisionOCR(),
    onBatch: @escaping @Sendable (Batch) async -> SubmitResult
  ) {
    self.config = config
    self.ocr = ocr
    self.onBatch = onBatch
    let options = Self.sparseFrameStoreOptions(config)
    self.sparseFrameStoreOptions = options
    self.sparseFrameStore = options.map(Self.makeSparseFrameStore)
  }

  func updateConfig(_ cfg: AgentConfig) {
    self.config = cfg
    let options = Self.sparseFrameStoreOptions(cfg)
    guard options != sparseFrameStoreOptions else { return }
    sparseFrameStoreOptions = options
    sparseFrameStore = options.map(Self.makeSparseFrameStore)
  }

  func recordBackpressureDrop() {
    droppedBackpressure += 1
  }

  func pendingStats() -> PendingFrameStats {
    let pendingBytes = pending.reduce(Int64(0)) { $0 + Int64($1.bytesPng) }
    return PendingFrameStats(frameCount: pending.count, estimatedBytes: pendingBytes)
  }

  func consume(_ frame: CapturedFrame, context: WindowContext?) async {
    guard let ctx = context else { return }

    if config.deniedBundleIds.contains(ctx.bundleId) {
      droppedDeniedApp += 1
      Log.scrub.debug("denied bundle \(ctx.bundleId, privacy: .public)")
      return
    }
    if !config.allowedBundleIds.isEmpty,
      !config.allowedBundleIds.contains(ctx.bundleId)
    {
      droppedDeniedApp += 1
      Log.scrub.info("allowlist miss bundle=\(ctx.bundleId, privacy: .public)")
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
    let duplicateByHash = dedupWindow.containsDuplicate(of: phash)
    if duplicateByHash, !config.ocrDiffSamplerEnabled {
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

    switch evaluateSecretSurfaces(context: ctx, ocrText: ocrResult.text) {
    case .dropped(let reason):
      droppedSecret += 1
      Log.scrub.warning("frame dropped secret=\(reason, privacy: .public)")
      return
    case .clean:
      break
    }

    if duplicateByHash {
      if config.ocrDiffSamplerEnabled,
        OcrDiffSampler.shouldOverrideDuplicate(
          previousText: lastEmittedOcrText,
          candidateText: ocrResult.text,
          threshold: config.ocrDiffSimilarityThreshold
        )
      {
        Log.capture.info("ocr diff sampler emitted pHash duplicate frame")
      } else {
        droppedDup += 1
        return
      }
    }

    let pendingBytes = pending.reduce(Int64(0)) { $0 + Int64($1.bytesPng) }
    let maxOcrChars = OcrBudgetController.maxPersistedCharacters(
      config: config,
      pendingBytes: pendingBytes,
      droppedBackpressure: droppedBackpressure
    )
    let ocrText = truncated(ocrResult.text, maxChars: maxOcrChars)
    // `bytesPng` is a cheap raw-BGRA size estimate; raw pixels stay on device and are not PNG-encoded.
    let estimatedBytes = frame.cgImage.width * frame.cgImage.height * 4
    let frameHash = sha256Hex(
      "\(phash.value)|\(frame.timestamp.timeIntervalSince1970)|\(ctx.bundleId)|\(ctx.windowTitle)|\(ocrResult.text)"
    )

    let processed = ProcessedFrame(
      frameHash: frameHash,
      perceptualHash: phash.value,
      capturedAt: frame.timestamp,
      bundleId: ctx.bundleId,
      appName: ctx.appName,
      windowTitle: ctx.windowTitle,
      documentPath: ctx.documentPath,
      ocrText: ocrText.value,
      ocrTextTruncated: ocrText.truncated,
      ocrConfidence: ocrResult.confidence,
      widthPx: frame.cgImage.width,
      heightPx: frame.cgImage.height,
      bytesPng: estimatedBytes,
      displayId: frame.displayId,
      displayScale: frame.displayScale,
      mainDisplay: frame.mainDisplay
    )

    pending.append(processed)
    dedupWindow.remember(phash)
    lastEmittedOcrText = ocrResult.text
    if let sparseFrameStore {
      do {
        try await sparseFrameStore.record(image: frame.cgImage, processed: processed)
      } catch {
        Log.capture.error(
          "sparse frame store write failed display=\(frame.displayId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
      }
    }

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
      metadata: config.metadata,
      startedAt: startedAt,
      endedAt: Date(),
      frames: pending,
      droppedCounts: DropCounts(
        secret: droppedSecret,
        duplicate: droppedDup,
        deniedApp: droppedDeniedApp,
        deniedPath: droppedDeniedPath,
        droppedBackpressure: droppedBackpressure
      )
    )
    pending.removeAll(keepingCapacity: true)
    droppedSecret = 0
    droppedDup = 0
    droppedDeniedApp = 0
    droppedDeniedPath = 0
    droppedBackpressure = 0
    startedAt = Date()
    let result = await onBatch(batch)
    guard case .failed = result else { return }
    pending = batch.frames + pending
    droppedSecret += batch.droppedCounts.secret
    droppedDup += batch.droppedCounts.duplicate
    droppedDeniedApp += batch.droppedCounts.deniedApp
    droppedDeniedPath += batch.droppedCounts.deniedPath
    droppedBackpressure += batch.droppedCounts.droppedBackpressure
    startedAt = min(startedAt, batch.startedAt)
  }

  private func hasDrops() -> Bool {
    droppedSecret + droppedDup + droppedDeniedApp + droppedDeniedPath + droppedBackpressure > 0
  }

  private func evaluateSecretSurfaces(context: WindowContext, ocrText: String)
    -> SecretScrubber.Decision
  {
    let surfaces = [
      ("windowTitle", context.windowTitle),
      ("documentPath", context.documentPath ?? ""),
      ("ocrText", ocrText),
    ]
    for (name, text) in surfaces {
      switch SecretScrubber.evaluate(text) {
      case .clean:
        continue
      case .dropped(let reason):
        return .dropped(reason: "\(name):\(reason)")
      }
    }
    return .clean
  }

  private func truncated(_ text: String, maxChars: Int) -> (value: String, truncated: Bool) {
    guard maxChars >= 0, text.count > maxChars else {
      return (text, false)
    }
    return (String(text.prefix(maxChars)), true)
  }

  private func sha256Hex(_ s: String) -> String {
    let digest = SHA256.hash(data: Data(s.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func sparseFrameStoreOptions(_ config: AgentConfig) -> SparseFrameStoreOptions? {
    guard let root = config.sparseFrameStoreRootURL else { return nil }
    return SparseFrameStoreOptions(
      root: root,
      retentionHours: config.sparseFrameRetentionHours,
      includeOcrText: config.sparseFrameIncludeOcrText
    )
  }

  private static func makeSparseFrameStore(_ options: SparseFrameStoreOptions) -> SparseFrameStore {
    return SparseFrameStore(
      root: options.root,
      retentionHours: options.retentionHours,
      includeOcrText: options.includeOcrText
    )
  }
}

struct PendingFrameStats: Sendable, Equatable {
  let frameCount: Int
  let estimatedBytes: Int64
}
