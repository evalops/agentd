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
    XCTAssertEqual(batch.frames.first?.displayId, 1)
    XCTAssertEqual(batch.frames.first?.displayScale, 2.0)
    XCTAssertTrue(batch.frames.first?.mainDisplay == true)
  }

  func testAdaptiveOcrBudgetCapsPersistedTextWhenBackpressureIsHigh() async throws {
    let recorder = BatchRecorder()
    var cfg = Self.config(maxOcrTextChars: 128)
    cfg.adaptiveOcrMinChars = 16
    cfg.adaptiveOcrBackpressureThreshold = 1
    let pipeline = FramePipeline(
      config: cfg,
      ocr: StubOCR(text: String(repeating: "a", count: 128))
    ) { batch in
      await recorder.append(batch)
    }

    await pipeline.recordBackpressureDrop()
    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await pipeline.flush()

    let batches = await recorder.snapshot()
    let frame = try XCTUnwrap(batches.first?.frames.first)
    XCTAssertEqual(frame.ocrText.count, 16)
    XCTAssertTrue(frame.ocrTextTruncated)
    XCTAssertEqual(batches.first?.droppedCounts.droppedBackpressure, 1)
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

  func testFailedSubmitKeepsBatchPendingForRetry() async throws {
    let recorder = BatchRecorder(result: .failed)
    let pipeline = FramePipeline(config: Self.config(), ocr: StubOCR(text: "clean")) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await pipeline.flush()
    let failedStats = await pipeline.pendingStats()
    XCTAssertEqual(failedStats.frameCount, 1)

    await recorder.setResult(.submitted(nil))
    await pipeline.flush()

    let batches = await recorder.snapshot()
    XCTAssertEqual(batches.count, 2)
    XCTAssertEqual(batches.last?.frames.count, 1)
    let succeededStats = await pipeline.pendingStats()
    XCTAssertEqual(succeededStats.frameCount, 0)
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

  func testOcrDiffSamplerOverridesPHashDuplicateWhenTextMateriallyChanges() async throws {
    let recorder = BatchRecorder()
    var cfg = Self.config()
    cfg.ocrDiffSamplerEnabled = true
    let pipeline = FramePipeline(
      config: cfg,
      ocr: SequenceOCR([
        "build succeeded target alpha",
        "deployment blocked target beta",
      ])
    ) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAB), context: Self.context())
    await pipeline.flush()

    let batches = await recorder.snapshot()
    let batch = try XCTUnwrap(batches.first)
    XCTAssertEqual(batch.frames.count, 2)
    XCTAssertEqual(batch.droppedCounts.duplicate, 0)
  }

  func testOcrDiffSamplerKeepsPHashDuplicateDroppedWhenTextIsSimilar() async throws {
    let recorder = BatchRecorder()
    var cfg = Self.config()
    cfg.ocrDiffSamplerEnabled = true
    let pipeline = FramePipeline(
      config: cfg,
      ocr: SequenceOCR([
        "build succeeded target alpha",
        "build succeeded target alpha",
      ])
    ) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await pipeline.flush()

    let batches = await recorder.snapshot()
    let batch = try XCTUnwrap(batches.first)
    XCTAssertEqual(batch.frames.count, 1)
    XCTAssertEqual(batch.droppedCounts.duplicate, 1)
  }

  func testOcrDiffSamplerStaysDisabledByDefault() async throws {
    let recorder = BatchRecorder()
    let pipeline = FramePipeline(
      config: Self.config(),
      ocr: SequenceOCR([
        "build succeeded target alpha",
        "deployment blocked target beta",
      ])
    ) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await pipeline.flush()

    let batches = await recorder.snapshot()
    let batch = try XCTUnwrap(batches.first)
    XCTAssertEqual(batch.frames.count, 1)
    XCTAssertEqual(batch.droppedCounts.duplicate, 1)
  }

  func testOcrDiffSamplerSimilarityUsesTokenShingles() {
    XCTAssertEqual(OcrDiffSampler.shingledSimilarity("alpha beta gamma", "alpha beta gamma"), 1)
    XCTAssertLessThan(
      OcrDiffSampler.shingledSimilarity("alpha beta gamma", "deploy failed prod"), 0.92)
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

  func testSparseFrameStoreWritesChronicleStyleArtifactsAfterScrub() async throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var cfg = Self.config()
    cfg.sparseFrameStorageRoot = root.path

    let recorder = BatchRecorder()
    let pipeline = FramePipeline(config: cfg, ocr: StubOCR(text: "visible work context")) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await pipeline.flush()

    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertTrue(files.contains { $0.hasSuffix("-display-1-latest.jpg") })
    XCTAssertTrue(files.contains { $0.hasSuffix("-display-1.capture") })
    XCTAssertTrue(files.contains { $0.hasSuffix("-display-1.capture.json") })
    let ocrSidecar = try XCTUnwrap(files.first(where: { $0.hasSuffix("-display-1.ocr.jsonl") }))
    let ocrText = try String(contentsOf: root.appendingPathComponent(ocrSidecar), encoding: .utf8)
    XCTAssertTrue(ocrText.contains("\"ocrTextHash\""))
    XCTAssertFalse(ocrText.contains("visible work context"))

    let segmentDirectory = try XCTUnwrap(
      files.first(where: { $0.contains("-display-1") && !$0.contains(".") }))
    let sparseFrames = try FileManager.default.contentsOfDirectory(
      atPath: root.appendingPathComponent(segmentDirectory).path)
    XCTAssertTrue(sparseFrames.contains { $0.hasPrefix("frame-0-") && $0.hasSuffix("Z.jpg") })
  }

  func testSparseFrameStoreCanOptIntoRawOcrSidecarForLocalDebugging() async throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var cfg = Self.config()
    cfg.sparseFrameStorageRoot = root.path
    cfg.sparseFrameIncludeOcrText = true

    let recorder = BatchRecorder()
    let pipeline = FramePipeline(config: cfg, ocr: StubOCR(text: "debuggable text")) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())

    let sidecar = try XCTUnwrap(
      try FileManager.default.contentsOfDirectory(atPath: root.path).first {
        $0.hasSuffix(".ocr.jsonl")
      })
    let ocrText = try String(contentsOf: root.appendingPathComponent(sidecar), encoding: .utf8)
    XCTAssertTrue(ocrText.contains("debuggable text"))
  }

  func testSparseFrameVisualRedactorMasksNormalizedVisionBox() {
    let image = Self.image(bits: UInt64.max)
    let redacted = SparseFrameVisualRedactor.mask(
      image: image,
      regions: [
        OCRTextRegion(normalizedBoundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
      ],
      paddingPixels: 0
    )

    let center = Self.pixel(redacted, x: 4, y: 4)
    XCTAssertLessThan(center.red, 10)
    XCTAssertLessThan(center.green, 10)
    XCTAssertLessThan(center.blue, 10)

    let corner = Self.pixel(redacted, x: 0, y: 0)
    XCTAssertGreaterThan(corner.red, 240)
    XCTAssertGreaterThan(corner.green, 240)
    XCTAssertGreaterThan(corner.blue, 240)
  }

  func testSparseFrameStoreCanOptIntoVisualRedactionMetadata() async throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var cfg = Self.config()
    cfg.sparseFrameStorageRoot = root.path
    cfg.sparseFrameVisualRedactionEnabled = true

    let recorder = BatchRecorder()
    let pipeline = FramePipeline(
      config: cfg,
      ocr: StubOCR(
        text: "visible work context",
        regions: [
          OCRTextRegion(
            normalizedBoundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        ]
      )
    ) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(Self.frame(bits: UInt64.max), context: Self.context())

    let metadataFile = try XCTUnwrap(
      try FileManager.default.contentsOfDirectory(atPath: root.path).first {
        $0.hasSuffix(".capture.json")
      })
    let metadata = try String(
      contentsOf: root.appendingPathComponent(metadataFile),
      encoding: .utf8
    )
    XCTAssertTrue(metadata.contains(#""visualRedactionEnabled":true"#))
  }

  func testSparseFrameStoreKeepsSessionAcrossUnchangedConfigRefresh() async throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var cfg = Self.config()
    cfg.sparseFrameStorageRoot = root.path

    let recorder = BatchRecorder()
    let pipeline = FramePipeline(config: cfg, ocr: StubOCR(text: "same session")) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await pipeline.updateConfig(cfg)
    await pipeline.consume(Self.frame(bits: 0x5555_5555_5555_5555), context: Self.context())

    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertEqual(files.filter { $0.contains("-display-1") && !$0.contains(".") }.count, 1)
  }

  func testDisplaySelectionPrefersExplicitIdsThenAllThenPrimary() {
    XCTAssertEqual(
      DisplaySelection.selectedDisplayIds(
        available: [10, 20, 30],
        captureAllDisplays: true,
        selectedDisplayIds: [20, 99, 20]
      ),
      [20]
    )
    XCTAssertEqual(
      DisplaySelection.selectedDisplayIds(
        available: [10, 20, 30],
        captureAllDisplays: true,
        selectedDisplayIds: []
      ),
      [10, 20, 30]
    )
    XCTAssertEqual(
      DisplaySelection.selectedDisplayIds(
        available: [10, 20, 30],
        captureAllDisplays: false,
        selectedDisplayIds: []
      ),
      [10]
    )
  }

  func testPrivacyDecisionCacheReusesStableNormalWindowClass() {
    var cache = PrivacyDecisionCache()
    let cfg = Self.config()

    let first = cache.decision(
      for: Self.context(windowTitle: "Editor - file one", documentPath: "/tmp/a.swift"),
      config: cfg,
      now: Date(timeIntervalSince1970: 1)
    )
    let second = cache.decision(
      for: Self.context(windowTitle: "Editor - file two", documentPath: "/tmp/b.swift"),
      config: cfg,
      now: Date(timeIntervalSince1970: 2)
    )

    XCTAssertTrue(first.allowed)
    XCTAssertFalse(first.cached)
    XCTAssertTrue(second.allowed)
    XCTAssertTrue(second.cached)
    XCTAssertEqual(first.observationId, second.observationId)
  }

  func testPrivacyDecisionCacheInvalidatesWhenTitleClassChanges() {
    var cache = PrivacyDecisionCache()
    let cfg = Self.config()

    let normal = cache.decision(for: Self.context(windowTitle: "Editor"), config: cfg)
    let privateWindow = cache.decision(
      for: Self.context(windowTitle: "Private Browsing - Example"), config: cfg)

    XCTAssertTrue(normal.allowed)
    XCTAssertFalse(privateWindow.allowed)
    XCTAssertFalse(privateWindow.cached)
    XCTAssertEqual(privateWindow.reasonCode, "pause_title_pattern")
    XCTAssertEqual(privateWindow.dropKind, .deniedApp)
    XCTAssertNotEqual(normal.observationId, privateWindow.observationId)
  }

  func testPrivacyDecisionCacheTreatsPauseTitlePatternsCaseInsensitively() {
    var cache = PrivacyDecisionCache()
    let cfg = Self.config()

    let decision = cache.decision(
      for: Self.context(windowTitle: "chrome - INCOGNITO"),
      config: cfg
    )

    XCTAssertFalse(decision.allowed)
    XCTAssertEqual(decision.reasonCode, "pause_title_pattern")
    XCTAssertEqual(decision.dropKind, .deniedApp)
  }

  func testBrowserPrivacyObservationFailsClosedOnMissingTitle() {
    var cache = PrivacyDecisionCache()
    var cfg = Self.config()
    cfg.allowedBundleIds += ["com.google.Chrome"]

    let decision = cache.decision(
      for: Self.context(bundleId: "com.google.Chrome", windowTitle: ""),
      config: cfg
    )

    XCTAssertFalse(decision.allowed)
    XCTAssertEqual(decision.reasonCode, "browser_window_missing_title")
    XCTAssertEqual(decision.dropKind, .deniedApp)
  }

  func testBrowserPrivacyObservationDeniesPrivateAndMeetWindows() {
    var cache = PrivacyDecisionCache()
    var cfg = Self.config()
    cfg.allowedBundleIds += ["com.apple.SafariTechnologyPreview", "com.google.Chrome.canary"]

    let privateDecision = cache.decision(
      for: Self.context(
        bundleId: "com.apple.SafariTechnologyPreview",
        windowTitle: "Private Browsing - Docs"
      ),
      config: cfg
    )
    let meetDecision = cache.decision(
      for: Self.context(
        bundleId: "com.google.Chrome.canary",
        windowTitle: "Sprint Review",
        documentPath: "https://meet.google.com/abc-defg-hij"
      ),
      config: cfg
    )

    XCTAssertFalse(privateDecision.allowed)
    XCTAssertEqual(privateDecision.reasonCode, "browser_private_window")
    XCTAssertFalse(meetDecision.allowed)
    XCTAssertEqual(meetDecision.reasonCode, "browser_meeting_window")
  }

  func testPrivacyDecisionCacheSeparatesBrowserMeetingURLs() {
    var cache = PrivacyDecisionCache()
    var cfg = Self.config()
    cfg.allowedBundleIds += ["com.google.Chrome"]

    let normalDecision = cache.decision(
      for: Self.context(
        bundleId: "com.google.Chrome",
        windowTitle: "Docs",
        documentPath: "https://docs.google.com/document/d/abc"
      ),
      config: cfg
    )
    let meetDecision = cache.decision(
      for: Self.context(
        bundleId: "com.google.Chrome",
        windowTitle: "Sprint Review",
        documentPath: "https://meet.google.com/abc-defg-hij"
      ),
      config: cfg
    )

    XCTAssertTrue(normalDecision.allowed)
    XCTAssertFalse(meetDecision.allowed)
    XCTAssertFalse(meetDecision.cached)
    XCTAssertEqual(meetDecision.reasonCode, "browser_meeting_window")
    XCTAssertNotEqual(normalDecision.observationId, meetDecision.observationId)
  }

  func testPrivacyDecisionCachePolicyInvalidationChangesObservationId() {
    var cache = PrivacyDecisionCache()
    let cfg = Self.config()

    let before = cache.decision(for: Self.context(), config: cfg)
    cache.invalidateForPolicyUpdate()
    let after = cache.decision(for: Self.context(), config: cfg)

    XCTAssertFalse(before.cached)
    XCTAssertFalse(after.cached)
    XCTAssertNotEqual(before.observationId, after.observationId)
  }

  func testPrivacyDecisionCacheDeniedPathStaysPathDrop() {
    var cache = PrivacyDecisionCache()
    let cfg = Self.config()
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    let decision = cache.decision(
      for: Self.context(documentPath: "\(home)/.ssh/id_ed25519"), config: cfg)

    XCTAssertFalse(decision.allowed)
    XCTAssertEqual(decision.reasonCode, "denied_path")
    XCTAssertEqual(decision.dropKind, .deniedPath)
  }

  func testOcrCacheAvoidsRecognizingSameDuplicateWhenSamplerEnabled() async throws {
    var cfg = Self.config()
    cfg.ocrDiffSamplerEnabled = true
    let recorder = BatchRecorder()
    let ocr = CountingOCR(text: "same visible text")
    let pipeline = FramePipeline(config: cfg, ocr: ocr) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await pipeline.flush()

    let callCount = await ocr.callCount()
    XCTAssertEqual(callCount, 1)
    let stats = await pipeline.ocrCacheStats()
    XCTAssertEqual(stats.entries, 1)
    XCTAssertEqual(stats.hits, 1)
    XCTAssertEqual(stats.misses, 1)
    let batches = await recorder.snapshot()
    let batch = try XCTUnwrap(batches.first)
    XCTAssertEqual(batch.frames.count, 1)
    XCTAssertEqual(batch.droppedCounts.duplicate, 1)
  }

  func testAccessibilityTextBypassesVisionOcr() async throws {
    let recorder = BatchRecorder()
    let ocr = CountingOCR(text: "vision text")
    let pipeline = FramePipeline(config: Self.config(), ocr: ocr) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(
      Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA),
      context: Self.context(),
      accessibilityText: AccessibilityTextResult(
        text: "  accessibility\nvisible\ttext  ",
        nodesVisited: 3,
        truncated: false
      )
    )
    await pipeline.flush()

    let callCount = await ocr.callCount()
    XCTAssertEqual(callCount, 0)
    let stats = await pipeline.textSourceStats()
    XCTAssertEqual(stats.counts[.accessibility], 1)
    let batches = await recorder.snapshot()
    let batch = try XCTUnwrap(batches.first)
    XCTAssertEqual(batch.frames.first?.ocrText, "accessibility visible text")
  }

  func testEmptyAccessibilityTextFallsBackToVisionOcr() async throws {
    let recorder = BatchRecorder()
    let ocr = CountingOCR(text: "vision fallback")
    let pipeline = FramePipeline(config: Self.config(), ocr: ocr) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(
      Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA),
      context: Self.context(),
      accessibilityText: AccessibilityTextResult(text: "   ", nodesVisited: 1, truncated: false)
    )
    await pipeline.flush()

    let callCount = await ocr.callCount()
    XCTAssertEqual(callCount, 1)
    let stats = await pipeline.textSourceStats()
    XCTAssertEqual(stats.counts[.visionOCR], 1)
    let batches = await recorder.snapshot()
    let batch = try XCTUnwrap(batches.first)
    XCTAssertEqual(batch.frames.first?.ocrText, "vision fallback")
  }

  func testOcrCacheMissesWhenImageContentChanges() async throws {
    let recorder = BatchRecorder()
    let ocr = CountingOCR(text: "visible text")
    let pipeline = FramePipeline(config: Self.config(), ocr: ocr) { batch in
      await recorder.append(batch)
    }

    await pipeline.consume(Self.frame(bits: 0xAAAA_AAAA_AAAA_AAAA), context: Self.context())
    await pipeline.consume(Self.frame(bits: 0x5555_5555_5555_5555), context: Self.context())

    let callCount = await ocr.callCount()
    XCTAssertEqual(callCount, 2)
    let stats = await pipeline.ocrCacheStats()
    XCTAssertEqual(stats.hits, 0)
    XCTAssertEqual(stats.misses, 2)
    XCTAssertEqual(stats.entries, 2)
  }

  func testOcrCacheEvictsOldestEntry() {
    var cache = OCRResultCache(maxEntries: 1)
    let first = OCRCacheKey(context: Self.context(windowTitle: "first"), imageHash: 1)
    let second = OCRCacheKey(context: Self.context(windowTitle: "second"), imageHash: 2)

    cache.insert(OCRResult(text: "first", confidence: 1, language: "en"), for: first)
    cache.insert(OCRResult(text: "second", confidence: 1, language: "en"), for: second)

    XCTAssertNil(cache.result(for: first))
    XCTAssertEqual(cache.result(for: second)?.text, "second")
    let stats = cache.stats()
    XCTAssertEqual(stats.entries, 1)
    XCTAssertEqual(stats.evictions, 1)
    XCTAssertEqual(stats.hits, 1)
    XCTAssertEqual(stats.misses, 1)
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
    CapturedFrame(
      timestamp: Date(),
      cgImage: image(bits: bits),
      displayId: 1,
      displayScale: 2.0,
      mainDisplay: true
    )
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

  static func pixel(_ image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
      data: &pixel,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.translateBy(x: -CGFloat(x), y: -CGFloat(y))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (pixel[0], pixel[1], pixel[2])
  }

  static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

actor BatchRecorder {
  private(set) var batches: [Batch] = []
  private var result: SubmitResult

  init(result: SubmitResult = .submitted(nil)) {
    self.result = result
  }

  @discardableResult
  func append(_ batch: Batch) -> SubmitResult {
    batches.append(batch)
    return result
  }

  func setResult(_ result: SubmitResult) {
    self.result = result
  }

  func snapshot() -> [Batch] {
    batches
  }
}

struct StubOCR: OCRRecognizing {
  let text: String
  let confidence: Float
  let regions: [OCRTextRegion]

  init(text: String, confidence: Float = 0.9, regions: [OCRTextRegion] = []) {
    self.text = text
    self.confidence = confidence
    self.regions = regions
  }

  func recognize(cgImage: CGImage) async throws -> OCRResult {
    OCRResult(text: text, confidence: confidence, language: "en", regions: regions)
  }
}

actor SequenceOCR: OCRRecognizing {
  private var texts: [String]
  private let confidence: Float

  init(_ texts: [String], confidence: Float = 0.9) {
    self.texts = texts
    self.confidence = confidence
  }

  func recognize(cgImage: CGImage) async throws -> OCRResult {
    let text = texts.isEmpty ? "" : texts.removeFirst()
    return OCRResult(text: text, confidence: confidence, language: "en")
  }
}

actor CountingOCR: OCRRecognizing {
  private let text: String
  private var calls = 0

  init(text: String) {
    self.text = text
  }

  func recognize(cgImage: CGImage) async throws -> OCRResult {
    calls += 1
    return OCRResult(text: text, confidence: 0.9, language: "en")
  }

  func callCount() -> Int {
    calls
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
