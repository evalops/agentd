// SPDX-License-Identifier: BUSL-1.1

import Foundation

struct ActivityOptions: Equatable {
  var sinceHours: Double
  var batchDirectory: URL

  init(
    sinceHours: Double = 24,
    batchDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".evalops/agentd/batches")
  ) {
    self.sinceHours = sinceHours
    self.batchDirectory = batchDirectory
  }

  static func parse(_ arguments: [String]) throws -> ActivityOptions {
    var options = ActivityOptions()
    var index = 0
    while index < arguments.count {
      let flag = arguments[index]
      switch flag {
      case "--since":
        index += 1
        guard index < arguments.count,
          let hours = Double(arguments[index]),
          hours > 0
        else {
          throw DiagnosticCLIError.usage("--since requires a positive hour value")
        }
        options.sinceHours = hours
      case "--batch-dir":
        index += 1
        guard index < arguments.count else {
          throw DiagnosticCLIError.usage("--batch-dir requires a path")
        }
        options.batchDirectory = URL(fileURLWithPath: arguments[index])
      case "--help", "-h":
        throw DiagnosticCLIError.usage("")
      default:
        throw DiagnosticCLIError.usage("unknown activity flag '\(flag)'")
      }
      index += 1
    }
    return options
  }
}

struct ActivitySummary: Codable, Sendable {
  let generatedAt: Date
  let since: Date
  let until: Date
  let batchDirectory: String
  let batchCount: Int
  let nonemptyBatchCount: Int
  let frameCount: Int
  let droppedCounts: DropCounts
  let droppedReasonCounts: [String: Int]
  let apps: [ActivityAppSummary]
  let windows: [ActivityWindowSummary]

  static func run(options: ActivityOptions = ActivityOptions(), now: Date = Date()) async throws
    -> ActivitySummary
  {
    try summarize(options: options, now: now)
  }

  private static func summarize(options: ActivityOptions, now: Date) throws -> ActivitySummary {
    let since = now.addingTimeInterval(-options.sinceHours * 3_600)
    let files = try batchFiles(in: options.batchDirectory)
    var batchCount = 0
    var nonemptyBatchCount = 0
    var frameCount = 0
    var dropped = DropCounts(secret: 0, duplicate: 0, deniedApp: 0, deniedPath: 0)
    var droppedReasonCounts: [String: Int] = [:]
    var appCounters: [ActivityAppKey: Int] = [:]
    var windowCounters: [ActivityWindowKey: ActivityWindowAccumulator] = [:]

    for file in files {
      guard let batch = try? decodeSubmitBatchRequest(Data(contentsOf: file)).batch else {
        continue
      }
      guard batch.endedAt >= since, batch.startedAt <= now else { continue }

      batchCount += 1
      if !batch.frames.isEmpty {
        nonemptyBatchCount += 1
      }
      frameCount += batch.frames.count
      dropped = dropped.adding(batch.droppedCounts)
      for (reason, count) in batch.droppedReasonCounts {
        droppedReasonCounts[reason, default: 0] += count
      }
      for frame in batch.frames {
        appCounters[
          ActivityAppKey(appName: frame.appName, bundleId: frame.bundleId),
          default: 0
        ] += 1

        let documentPath = URLPrivacyRedactor.redactDocumentPath(frame.documentPath)
        let key = ActivityWindowKey(
          appName: frame.appName,
          bundleId: frame.bundleId,
          windowTitle: frame.windowTitle,
          documentPath: documentPath
        )
        var accumulator = windowCounters[key] ?? ActivityWindowAccumulator()
        accumulator.record(frame)
        windowCounters[key] = accumulator
      }
    }

    return ActivitySummary(
      generatedAt: now,
      since: since,
      until: now,
      batchDirectory: options.batchDirectory.path,
      batchCount: batchCount,
      nonemptyBatchCount: nonemptyBatchCount,
      frameCount: frameCount,
      droppedCounts: dropped,
      droppedReasonCounts: droppedReasonCounts.sortedByKey(),
      apps: appCounters.map { key, count in
        ActivityAppSummary(appName: key.appName, bundleId: key.bundleId, frameCount: count)
      }.sorted(),
      windows: windowCounters.map { key, accumulator in
        ActivityWindowSummary(
          appName: key.appName,
          bundleId: key.bundleId,
          windowTitle: key.windowTitle,
          documentPath: key.documentPath,
          frameCount: accumulator.frameCount,
          firstSeenAt: accumulator.firstSeenAt,
          lastSeenAt: accumulator.lastSeenAt
        )
      }.sorted()
    )
  }

  private static func batchFiles(in directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
}

struct ActivityAppSummary: Codable, Sendable, Equatable, Comparable {
  let appName: String
  let bundleId: String
  let frameCount: Int

  static func < (lhs: ActivityAppSummary, rhs: ActivityAppSummary) -> Bool {
    if lhs.appName != rhs.appName { return lhs.appName < rhs.appName }
    return lhs.bundleId < rhs.bundleId
  }
}

struct ActivityWindowSummary: Codable, Sendable, Equatable, Comparable {
  let appName: String
  let bundleId: String
  let windowTitle: String
  let documentPath: String?
  let frameCount: Int
  let firstSeenAt: Date
  let lastSeenAt: Date

  static func < (lhs: ActivityWindowSummary, rhs: ActivityWindowSummary) -> Bool {
    if lhs.windowTitle != rhs.windowTitle { return lhs.windowTitle < rhs.windowTitle }
    if lhs.appName != rhs.appName { return lhs.appName < rhs.appName }
    return lhs.bundleId < rhs.bundleId
  }
}

private struct ActivityAppKey: Hashable {
  let appName: String
  let bundleId: String
}

private struct ActivityWindowKey: Hashable {
  let appName: String
  let bundleId: String
  let windowTitle: String
  let documentPath: String?
}

private struct ActivityWindowAccumulator {
  private(set) var frameCount = 0
  private(set) var firstSeenAt = Date.distantFuture
  private(set) var lastSeenAt = Date.distantPast

  mutating func record(_ frame: ProcessedFrame) {
    frameCount += 1
    firstSeenAt = min(firstSeenAt, frame.capturedAt)
    lastSeenAt = max(lastSeenAt, frame.capturedAt)
  }
}

extension DropCounts {
  fileprivate func adding(_ other: DropCounts) -> DropCounts {
    DropCounts(
      secret: secret + other.secret,
      duplicate: duplicate + other.duplicate,
      deniedApp: deniedApp + other.deniedApp,
      deniedPath: deniedPath + other.deniedPath,
      droppedBackpressure: droppedBackpressure + other.droppedBackpressure
    )
  }
}

extension Dictionary where Key == String, Value == Int {
  fileprivate func sortedByKey() -> [String: Int] {
    Dictionary(uniqueKeysWithValues: sorted { $0.key < $1.key })
  }
}
