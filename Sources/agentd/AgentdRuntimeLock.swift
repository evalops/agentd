// SPDX-License-Identifier: BUSL-1.1

import Darwin
import Foundation

final class AgentdRuntimeLock: @unchecked Sendable {
  private let fd: Int32
  let url: URL

  private init(fd: Int32, url: URL) {
    self.fd = fd
    self.url = url
  }

  static func acquire(purpose: String, now: Date = Date()) throws -> AgentdRuntimeLock {
    let url = lockURL
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
    guard fd >= 0 else {
      throw RuntimeLockError.openFailed(String(cString: strerror(errno)))
    }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      let message = String(cString: strerror(errno))
      close(fd)
      throw RuntimeLockError.alreadyHeld(message)
    }

    let metadata = RuntimeLockMetadata(
      pid: ProcessInfo.processInfo.processIdentifier,
      purpose: purpose,
      acquiredAt: now
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(metadata)
    _ = ftruncate(fd, 0)
    _ = lseek(fd, 0, SEEK_SET)
    data.withUnsafeBytes { buffer in
      _ = write(fd, buffer.baseAddress, buffer.count)
    }
    return AgentdRuntimeLock(fd: fd, url: url)
  }

  static var lockURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".evalops/agentd/agentd-runtime.lock")
  }

  deinit {
    _ = flock(fd, LOCK_UN)
    close(fd)
  }
}

private struct RuntimeLockMetadata: Codable {
  let pid: Int32
  let purpose: String
  let acquiredAt: Date
}

enum RuntimeLockError: Error, LocalizedError {
  case openFailed(String)
  case alreadyHeld(String)

  var errorDescription: String? {
    switch self {
    case .openFailed(let message):
      return "could not open agentd runtime lock: \(message)"
    case .alreadyHeld:
      return "agentd is already running or another diagnostic capture is active"
    }
  }
}
