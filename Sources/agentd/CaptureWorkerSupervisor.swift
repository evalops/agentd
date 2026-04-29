// SPDX-License-Identifier: BUSL-1.1

import Darwin
import Foundation

struct CaptureWorkerProcessSpec: Sendable, Equatable {
  let executableURL: URL
  let arguments: [String]
  let environment: [String: String]?

  init(
    executableURL: URL,
    arguments: [String] = [],
    environment: [String: String]? = nil
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
  }
}

struct CaptureWorkerTerminationResult: Sendable, Equatable {
  let pid: Int32
  let termSent: Bool
  let killSent: Bool
  let exited: Bool
  let terminationStatus: Int32?
}

struct CaptureWorkerSupervisorStats: Sendable, Equatable {
  let starts: Int
  let terminations: Int
  let forceKills: Int
  let lastPid: Int32?
  let lastExitStatus: Int32?

  static let empty = CaptureWorkerSupervisorStats(
    starts: 0,
    terminations: 0,
    forceKills: 0,
    lastPid: nil,
    lastExitStatus: nil
  )
}

enum CaptureWorkerSupervisorError: Error, LocalizedError, Equatable {
  case alreadyRunning(pid: Int32)
  case notRunning

  var errorDescription: String? {
    switch self {
    case .alreadyRunning(let pid):
      return "capture worker is already running pid=\(pid)"
    case .notRunning:
      return "capture worker is not running"
    }
  }
}

final class CaptureWorkerSupervisor: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var starts = 0
  private var terminations = 0
  private var forceKills = 0
  private var lastPid: Int32?
  private var lastExitStatus: Int32?

  func start(_ spec: CaptureWorkerProcessSpec) throws -> Int32 {
    let process = Process()
    process.executableURL = spec.executableURL
    process.arguments = spec.arguments
    process.environment = spec.environment

    return try lock.withLock {
      if let current = self.process, current.isRunning {
        throw CaptureWorkerSupervisorError.alreadyRunning(pid: current.processIdentifier)
      }
      try process.run()
      self.process = process
      self.starts += 1
      self.lastPid = process.processIdentifier
      Log.capture.info(
        "capture worker started pid=\(process.processIdentifier, privacy: .public)"
      )
      return process.processIdentifier
    }
  }

  func terminate(graceSeconds: TimeInterval) -> CaptureWorkerTerminationResult {
    let target = lock.withLock { () -> Process? in
      guard let process = self.process else { return nil }
      self.process = nil
      return process
    }
    guard let target else {
      return CaptureWorkerTerminationResult(
        pid: -1,
        termSent: false,
        killSent: false,
        exited: true,
        terminationStatus: nil
      )
    }

    let pid = target.processIdentifier
    Log.capture.info("terminating capture worker safely with TERM pid=\(pid, privacy: .public)")
    target.terminate()
    let exitedAfterTerm = Self.wait(for: target, timeoutSeconds: max(0, graceSeconds))
    if exitedAfterTerm {
      Log.capture.info("capture worker terminated safely with TERM pid=\(pid, privacy: .public)")
      return recordTermination(process: target, pid: pid, killSent: false, exited: true)
    }

    Log.capture.error(
      "terminating capture worker forcefully with KILL pid=\(pid, privacy: .public)")
    Darwin.kill(pid, SIGKILL)
    let exitedAfterKill = Self.wait(for: target, timeoutSeconds: 2)
    if exitedAfterKill {
      Log.capture.error(
        "capture worker forcefully terminated pid=\(pid, privacy: .public)"
      )
    }
    return recordTermination(process: target, pid: pid, killSent: true, exited: exitedAfterKill)
  }

  func stats() -> CaptureWorkerSupervisorStats {
    lock.withLock {
      CaptureWorkerSupervisorStats(
        starts: starts,
        terminations: terminations,
        forceKills: forceKills,
        lastPid: lastPid,
        lastExitStatus: lastExitStatus
      )
    }
  }

  private func recordTermination(
    process: Process,
    pid: Int32,
    killSent: Bool,
    exited: Bool
  ) -> CaptureWorkerTerminationResult {
    let status = exited ? process.terminationStatus : nil
    lock.withLock {
      terminations += 1
      if killSent {
        forceKills += 1
      }
      lastPid = pid
      lastExitStatus = status
    }
    return CaptureWorkerTerminationResult(
      pid: pid,
      termSent: true,
      killSent: killSent,
      exited: exited,
      terminationStatus: status
    )
  }

  private static func wait(for process: Process, timeoutSeconds: TimeInterval) -> Bool {
    guard process.isRunning else { return true }
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      process.waitUntilExit()
      group.leave()
    }
    return group.wait(timeout: .now() + timeoutSeconds) == .success
  }
}
