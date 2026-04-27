// SPDX-License-Identifier: BUSL-1.1

import CoreGraphics
import XCTest

@testable import agentd

final class PipelineTests: XCTestCase {
  func testWindowTitleSecretDropsFrame() async throws {
    let recorder = BatchRecorder()
    let pipeline = FramePipeline(config: Self.config(), ocr: StubOCR(text: "clean")) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(
      Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA),
      context: Self.context(windowTitle: "prod \("AKIA" + String(repeating: "A", count: 16))")
    )
    await pipeline.flush()

    let batches = await recorder.snapshot()
    let batch = try XCTUnwrap(batches.first)
    XCTAssertEqual(batch.frames.count, 0)
    XCTAssertEqual(batch.droppedCounts.secret, 1)
  }

  func testDocumentPathSecretDropsFrame() async throws {
    let recorder = BatchRecorder()
    let pipeline = FramePipeline(config: Self.config(), ocr: StubOCR(text: "clean")) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(
      Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA),
      context: Self.context(documentPath: "/tmp/report?\(SecretScrubberTests.jwtFixture())")
    )
    await pipeline.flush()

    let batches = await recorder.snapshot()
    let batch = try XCTUnwrap(batches.first)
    XCTAssertEqual(batch.frames.count, 0)
    XCTAssertEqual(batch.droppedCounts.secret, 1)
  }

  func testDeniedPathPrecedenceStillUsesPathPolicy() async throws {
    let recorder = BatchRecorder()
    let pipeline = FramePipeline(config: Self.config(), ocr: StubOCR(text: "clean")) { batch in
      await recorder.append(batch)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    await pipeline.consume(
      Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA),
      context: Self.context(documentPath: "\(home)/.ssh/id_ed25519")
    )
    await pipeline.flush()

    let batches = await recorder.snapshot()
    let batch = try XCTUnwrap(batches.first)
    XCTAssertEqual(batch.frames.count, 0)
    XCTAssertEqual(batch.droppedCounts.deniedPath, 1)
    XCTAssertEqual(batch.droppedCounts.secret, 0)
  }

  func testOcrTextIsCappedAfterFullTextSecretScan() async throws {
    let cleanRecorder = BatchRecorder()
    let cleanPipeline = FramePipeline(
      config: Self.config(maxOcrTextChars: 64),
      ocr: StubOCR(text: String(repeating: "a", count: 128))
    ) { batch in
      await cleanRecorder.append(batch)
    }

    await cleanPipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await cleanPipeline.flush()

    let cleanBatches = await cleanRecorder.snapshot()
    let cleanBatch = try XCTUnwrap(cleanBatches.first)
    let frame = try XCTUnwrap(cleanBatch.frames.first)
    XCTAssertEqual(frame.ocrText.count, 64)
    XCTAssertTrue(frame.ocrTextTruncated)

    let secretRecorder = BatchRecorder()
    let secretText =
      String(repeating: "a", count: 128) + " " + ("AKIA" + String(repeating: "B", count: 16))
    let secretPipeline = FramePipeline(
      config: Self.config(maxOcrTextChars: 64),
      ocr: StubOCR(text: secretText)
    ) { batch in
      await secretRecorder.append(batch)
    }

    await secretPipeline.consume(Self.frame(bits: 0x5555_5555_5555_5555), context: Self.context())
    await secretPipeline.flush()

    let secretBatches = await secretRecorder.snapshot()
    let secretBatch = try XCTUnwrap(secretBatches.first)
    XCTAssertEqual(secretBatch.frames.count, 0)
    XCTAssertEqual(secretBatch.droppedCounts.secret, 1)
  }

  func testMaxFramesPerBatchFlushesAutomatically() async throws {
    let recorder = BatchRecorder()
    let pipeline = FramePipeline(
      config: Self.config(maxFramesPerBatch: 2), ocr: StubOCR(text: "clean")
    ) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await pipeline.consume(Self.frame(bits: 0x5555_5555_5555_5555), context: Self.context())

    let batches = await recorder.snapshot()
    let batch = try XCTUnwrap(batches.first)
    XCTAssertEqual(batch.frames.count, 2)
    XCTAssertEqual(batch.frames.first?.bytesPng, 8 * 8 * 4)
  }

  func testManualFlushEmitsPendingFrame() async throws {
    let recorder = BatchRecorder()
    let pipeline = FramePipeline(config: Self.config(), ocr: StubOCR(text: "clean")) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await pipeline.flush()

    let batches = await recorder.snapshot()
    let batch = try XCTUnwrap(batches.first)
    XCTAssertEqual(batch.frames.count, 1)
  }

  func testFlushEmitsDropOnlyBatch() async throws {
    let recorder = BatchRecorder()
    let pipeline = FramePipeline(config: Self.config(), ocr: StubOCR(text: "clean")) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(
      Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA),
      context: Self.context(bundleId: "com.agilebits.onepassword7")
    )
    await pipeline.flush()

    let batches = await recorder.snapshot()
    let batch = try XCTUnwrap(batches.first)
    XCTAssertEqual(batch.frames.count, 0)
    XCTAssertEqual(batch.droppedCounts.deniedApp, 1)
  }

  func testPauseWindowTitleBeatsAllowedBundle() async throws {
    let recorder = BatchRecorder()
    let pipeline = FramePipeline(config: Self.config(), ocr: StubOCR(text: "clean")) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(
      Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA),
      context: Self.context(windowTitle: "Zoom Meeting")
    )
    await pipeline.flush()

    let batches = await recorder.snapshot()
    let batch = try XCTUnwrap(batches.first)
    XCTAssertEqual(batch.frames.count, 0)
    XCTAssertEqual(batch.droppedCounts.deniedApp, 1)
  }

  func testDeniedBundleBeatsAllowlist() async throws {
    var cfg = Self.config()
    cfg.allowedBundleIds = ["com.agilebits.onepassword7"]
    let recorder = BatchRecorder()
    let pipeline = FramePipeline(config: cfg, ocr: StubOCR(text: "clean")) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(
      Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA),
      context: Self.context(bundleId: "com.agilebits.onepassword7")
    )
    await pipeline.flush()

    let batches = await recorder.snapshot()
    let batch = try XCTUnwrap(batches.first)
    XCTAssertEqual(batch.frames.count, 0)
    XCTAssertEqual(batch.droppedCounts.deniedApp, 1)
  }

  func testPerceptualHashDistanceForIdenticalSmallNoiseAndUnrelatedImages() throws {
    let base = try XCTUnwrap(PerceptualHash(cgImage: Self.image(bits: 0xAAAA_AAAA_AAAA_AAAA)))
    let identical = try XCTUnwrap(PerceptualHash(cgImage: Self.image(bits: 0xAAAA_AAAA_AAAA_AAAA)))
    let smallNoise = try XCTUnwrap(PerceptualHash(cgImage: Self.image(bits: 0xAAAA_AAAA_AAAA_AAAB)))
    let unrelated = try XCTUnwrap(PerceptualHash(cgImage: Self.image(bits: 0x5555_5555_5555_5555)))

    XCTAssertEqual(PerceptualHash.distance(base, identical), 0)
    XCTAssertLessThanOrEqual(PerceptualHash.distance(base, smallNoise), 5)
    XCTAssertGreaterThan(PerceptualHash.distance(base, unrelated), 5)
  }

  func testDedupWindowDropsABAInsideWindowAndEvictsOldest() {
    var window = DedupWindow(capacity: 16, threshold: 0)
    let a = PerceptualHash(value: 0x1)
    let b = PerceptualHash(value: 0x2)

    XCTAssertFalse(window.containsDuplicate(of: a))
    window.remember(a)
    XCTAssertFalse(window.containsDuplicate(of: b))
    window.remember(b)
    XCTAssertTrue(window.containsDuplicate(of: a))

    for value in UInt64(3)...UInt64(17) {
      window.remember(PerceptualHash(value: value))
    }
    XCTAssertFalse(window.containsDuplicate(of: a))
    XCTAssertTrue(window.containsDuplicate(of: b))
  }

  func testBufferedFrameDispatcherBoundsBackpressure() async throws {
    let counts = DispatchCounts()
    let dispatcher = BufferedFrameDispatcher(bufferingNewest: 2) { _ in
      try? await Task.sleep(nanoseconds: 50_000_000)
      await counts.recordProcessed()
    } onDropped: {
      await counts.recordDropped()
    }

    for value in 0..<100 {
      dispatcher.yield(Self.frame(bits: UInt64(value + 1)))
    }

    try await Task.sleep(nanoseconds: 300_000_000)
    dispatcher.finish()
    let processed = await counts.processed
    let dropped = await counts.dropped
    XCTAssertLessThan(processed, 100)
    XCTAssertGreaterThan(dropped, 0)
  }

  static func config(maxFramesPerBatch: Int = 24, maxOcrTextChars: Int = 4096) -> AgentConfig {
    AgentConfig(
      deviceId: "device_1",
      organizationId: "org_1",
      endpoint: URL(string: "http://127.0.0.1:8787/submit")!,
      allowedBundleIds: ["com.test.App"],
      deniedBundleIds: AgentConfig.defaultDeniedBundleIds,
      deniedPathPrefixes: AgentConfig.defaultDeniedPathPrefixes,
      pauseWindowTitlePatterns: AgentConfig.defaultPauseWindowPatterns,
      captureFps: 1,
      idleFps: 0.2,
      batchIntervalSeconds: 30,
      maxFramesPerBatch: maxFramesPerBatch,
      maxOcrTextChars: maxOcrTextChars,
      localOnly: true
    )
  }

  static func context(
    bundleId: String = "com.test.App",
    windowTitle: String = "clean",
    documentPath: String? = nil
  ) -> WindowContext {
    WindowContext(
      bundleId: bundleId,
      appName: "TestApp",
      windowTitle: windowTitle,
      documentPath: documentPath,
      pid: 123,
      timestamp: Date()
    )
  }

  static func frame(bits: UInt64) -> CapturedFrame {
    CapturedFrame(timestamp: Date(), cgImage: image(bits: bits), displayId: 1)
  }

  static func image(bits: UInt64) -> CGImage {
    let size = 8
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil,
      width: size,
      height: size,
      bitsPerComponent: 8,
      bytesPerRow: size * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for y in 0..<size {
      for x in 0..<size {
        let index = UInt64(y * size + x)
        let white = ((bits >> index) & 1) == 1
        context.setFillColor(white ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: x, y: y, width: 1, height: 1))
      }
    }
    return context.makeImage()!
  }
}

actor BatchRecorder {
  private(set) var batches: [Batch] = []

  func append(_ batch: Batch) {
    batches.append(batch)
  }

  func snapshot() -> [Batch] {
    batches
  }
}

struct StubOCR: OCRRecognizing {
  let text: String
  let confidence: Float

  init(text: String, confidence: Float = 0.9) {
    self.text = text
    self.confidence = confidence
  }

  func recognize(cgImage: CGImage) async throws -> OCRResult {
    OCRResult(text: text, confidence: confidence, language: "en")
  }
}

actor DispatchCounts {
  private(set) var processed = 0
  private(set) var dropped = 0

  func recordProcessed() {
    processed += 1
  }

  func recordDropped() {
    dropped += 1
  }
}
