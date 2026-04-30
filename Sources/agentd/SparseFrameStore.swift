// SPDX-License-Identifier: BUSL-1.1

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor SparseFrameStore {
  private let root: URL
  private let retentionHours: Double
  private let includeOcrText: Bool
  private let visualRedactionEnabled: Bool
  private var sessions: [UInt32: SparseFrameSession] = [:]
  private let jsonEncoder: JSONEncoder

  init(
    root: URL,
    retentionHours: Double = 6,
    includeOcrText: Bool = false,
    visualRedactionEnabled: Bool = false
  ) {
    self.root = root
    self.retentionHours = max(0, retentionHours)
    self.includeOcrText = includeOcrText
    self.visualRedactionEnabled = visualRedactionEnabled
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    self.jsonEncoder = encoder
  }

  func record(image: CGImage, processed: ProcessedFrame) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var session = try sessions[processed.displayId] ?? createSession(for: processed)
    let storageImage =
      visualRedactionEnabled
      ? SparseFrameVisualRedactor.mask(image: image, regions: processed.ocrTextRegions)
      : image

    let latestURL = session.latestURL
    try writeJPEG(storageImage, to: latestURL)

    let normalizedText = normalize(processed.ocrText)
    let textHash = sha256Hex(normalizedText)
    let materialTextChange = textHash != session.lastOcrHash
    let staleHistoricalFrame =
      session.lastHistoricalFrameAt == nil
      || processed.capturedAt.timeIntervalSince(session.lastHistoricalFrameAt!) >= 60

    if materialTextChange || staleHistoricalFrame {
      let frameIndex = session.nextFrameIndex
      session.nextFrameIndex += 1
      session.lastHistoricalFrameAt = processed.capturedAt
      let frameURL = session.directory.appendingPathComponent(
        "frame-\(frameIndex)-\(minuteBucket(processed.capturedAt))Z.jpg")
      try writeJPEG(storageImage, to: frameURL)

      if materialTextChange {
        session.lastOcrHash = textHash
        try appendOCRRecord(
          SparseFrameOCRRecord(
            version: 1,
            displayId: processed.displayId,
            capturedAt: processed.capturedAt,
            frameIndex: frameIndex,
            persistedFramePath: frameURL.path,
            ocrTextLength: processed.ocrText.count,
            ocrTextHash: textHash,
            ocrTextTruncated: processed.ocrTextTruncated,
            normalizedText: includeOcrText ? normalizedText : nil
          ),
          to: session.ocrURL
        )
      }
    }

    sessions[processed.displayId] = session
    try pruneExpiredArtifacts(now: processed.capturedAt)
  }

  private func createSession(for processed: ProcessedFrame) throws -> SparseFrameSession {
    let startedAt = fileTimestamp(processed.capturedAt)
    let prefix = "\(startedAt)-display-\(processed.displayId)"
    let directory = root.appendingPathComponent(prefix, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let markerURL = root.appendingPathComponent("\(prefix).capture")
    FileManager.default.createFile(atPath: markerURL.path, contents: Data())
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)

    let metadataURL = root.appendingPathComponent("\(prefix).capture.json")
    let metadata = SparseFrameSegmentMetadata(
      version: 1,
      displayId: processed.displayId,
      segmentStartedAt: processed.capturedAt,
      widthPx: processed.widthPx,
      heightPx: processed.heightPx,
      retentionHours: retentionHours,
      includesRawOcrText: includeOcrText,
      visualRedactionEnabled: visualRedactionEnabled
    )
    try jsonEncoder.encode(metadata).write(to: metadataURL, options: .atomic)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)

    return SparseFrameSession(
      prefix: prefix,
      directory: directory,
      latestURL: root.appendingPathComponent("\(prefix)-latest.jpg"),
      ocrURL: root.appendingPathComponent("\(prefix).ocr.jsonl")
    )
  }

  private func appendOCRRecord(_ record: SparseFrameOCRRecord, to url: URL) throws {
    var data = try jsonEncoder.encode(record)
    data.append(0x0A)
    if FileManager.default.fileExists(atPath: url.path) {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } else {
      try data.write(to: url, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
  }

  private func writeJPEG(_ image: CGImage, to url: URL) throws {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      throw SparseFrameStoreError.jpegDestinationCreateFailed(url.path)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw SparseFrameStoreError.jpegWriteFailed(url.path)
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func pruneExpiredArtifacts(now: Date) throws {
    guard retentionHours > 0 else { return }
    let cutoff = now.addingTimeInterval(-retentionHours * 3600)
    let urls = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    for url in urls {
      guard
        let values = try? url.resourceValues(forKeys: [
          .contentModificationDateKey,
          .isDirectoryKey,
        ])
      else {
        continue
      }
      guard let modified = values.contentModificationDate, modified < cutoff else { continue }
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func normalize(_ text: String) -> String {
    text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func fileTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
    return formatter.string(from: date)
  }

  private func minuteBucket(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm"
    return formatter.string(from: date)
  }
}

struct SparseFrameStoreOptions: Sendable, Equatable {
  let root: URL
  let retentionHours: Double
  let includeOcrText: Bool
  let visualRedactionEnabled: Bool
}

enum SparseFrameVisualRedactor {
  static func mask(
    image: CGImage,
    regions: [OCRTextRegion],
    paddingPixels: CGFloat = 2
  ) -> CGImage {
    guard !regions.isEmpty else { return image }
    let width = image.width
    let height = image.height
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return image
    }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    context.draw(image, in: bounds)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    for region in regions {
      let rect = pixelRect(
        normalized: region.normalizedBoundingBox,
        width: width,
        height: height
      )
      .insetBy(dx: -paddingPixels, dy: -paddingPixels)
      .intersection(bounds)
      guard !rect.isNull, !rect.isEmpty else { continue }
      context.fill(rect)
    }
    return context.makeImage() ?? image
  }

  static func pixelRect(normalized: CGRect, width: Int, height: Int) -> CGRect {
    let imageWidth = CGFloat(width)
    let imageHeight = CGFloat(height)
    let x = normalized.minX * imageWidth
    let y = (1 - normalized.maxY) * imageHeight
    return CGRect(
      x: x,
      y: y,
      width: normalized.width * imageWidth,
      height: normalized.height * imageHeight
    )
  }
}

private struct SparseFrameSession: Sendable {
  let prefix: String
  let directory: URL
  let latestURL: URL
  let ocrURL: URL
  var nextFrameIndex = 0
  var lastOcrHash: String?
  var lastHistoricalFrameAt: Date?
}

private struct SparseFrameSegmentMetadata: Codable {
  let version: Int
  let displayId: UInt32
  let segmentStartedAt: Date
  let widthPx: Int
  let heightPx: Int
  let retentionHours: Double
  let includesRawOcrText: Bool
  let visualRedactionEnabled: Bool
}

private struct SparseFrameOCRRecord: Codable {
  let version: Int
  let displayId: UInt32
  let capturedAt: Date
  let frameIndex: Int
  let persistedFramePath: String
  let ocrTextLength: Int
  let ocrTextHash: String
  let ocrTextTruncated: Bool
  let normalizedText: String?
}

enum SparseFrameStoreError: Error, LocalizedError {
  case jpegDestinationCreateFailed(String)
  case jpegWriteFailed(String)

  var errorDescription: String? {
    switch self {
    case .jpegDestinationCreateFailed(let path):
      return "failed to create sparse frame JPEG destination at \(path)"
    case .jpegWriteFailed(let path):
      return "failed to write sparse frame JPEG at \(path)"
    }
  }
}

extension AgentConfig {
  var sparseFrameStoreRootURL: URL? {
    guard let raw = sparseFrameStorageRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else {
      return nil
    }
    let expanded: String
    if raw == "~" {
      expanded = NSHomeDirectory()
    } else if raw.hasPrefix("~/") {
      expanded = NSHomeDirectory() + String(raw.dropFirst())
    } else {
      expanded = raw
    }
    return URL(fileURLWithPath: expanded, isDirectory: true)
  }
}
