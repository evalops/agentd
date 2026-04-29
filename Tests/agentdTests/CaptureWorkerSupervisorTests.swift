// SPDX-License-Identifier: BUSL-1.1

import Foundation
import XCTest

@testable import agentd

final class CaptureWorkerSupervisorTests: XCTestCase {
  func testTerminatesWorkerWithTermDuringGraceWindow() throws {
    let supervisor = CaptureWorkerSupervisor()
    let output = Pipe()
    let pid = try supervisor.start(
      CaptureWorkerProcessSpec(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        arguments: ["-e", "$|=1; print \"ready\\n\"; sleep 30"],
        standardOutput: output
      )
    )
    XCTAssertTrue(waitForReadyLine(from: output))

    let result = supervisor.terminate(graceSeconds: 2)

    XCTAssertEqual(result.pid, pid)
    XCTAssertTrue(result.termSent)
    XCTAssertFalse(result.killSent)
    XCTAssertTrue(result.exited)
    XCTAssertEqual(supervisor.stats().starts, 1)
    XCTAssertEqual(supervisor.stats().terminations, 1)
    XCTAssertEqual(supervisor.stats().forceKills, 0)
  }

  func testEscalatesToKillWhenWorkerIgnoresTerm() throws {
    let supervisor = CaptureWorkerSupervisor()
    let output = Pipe()
    let pid = try supervisor.start(
      CaptureWorkerProcessSpec(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        arguments: ["-e", "$|=1; $SIG{TERM}=sub{}; print \"ready\\n\"; sleep 30"],
        standardOutput: output
      )
    )
    XCTAssertTrue(waitForReadyLine(from: output))

    let result = supervisor.terminate(graceSeconds: 0.05)

    XCTAssertEqual(result.pid, pid)
    XCTAssertTrue(result.termSent)
    XCTAssertTrue(result.killSent)
    XCTAssertTrue(result.exited)
    XCTAssertEqual(supervisor.stats().starts, 1)
    XCTAssertEqual(supervisor.stats().terminations, 1)
    XCTAssertEqual(supervisor.stats().forceKills, 1)
  }

  func testRejectsSecondStartWhileWorkerIsRunning() throws {
    let supervisor = CaptureWorkerSupervisor()
    let pid = try supervisor.start(
      CaptureWorkerProcessSpec(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["30"]
      )
    )

    defer { _ = supervisor.terminate(graceSeconds: 1) }
    XCTAssertThrowsError(
      try supervisor.start(
        CaptureWorkerProcessSpec(
          executableURL: URL(fileURLWithPath: "/bin/sleep"),
          arguments: ["30"]
        )
      )
    ) { error in
      XCTAssertEqual(error as? CaptureWorkerSupervisorError, .alreadyRunning(pid: pid))
    }
  }

  private func waitForReadyLine(from pipe: Pipe, timeoutSeconds: TimeInterval = 2) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    let buffer = ReadyLineBuffer()
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      if buffer.appendAndContainsReadyLine(data) {
        semaphore.signal()
      }
    }
    let ready = semaphore.wait(timeout: .now() + timeoutSeconds) == .success
    pipe.fileHandleForReading.readabilityHandler = nil
    return ready
  }
}

private final class ReadyLineBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()

  func appendAndContainsReadyLine(_ data: Data) -> Bool {
    lock.withLock {
      buffer.append(data)
      return String(data: buffer, encoding: .utf8)?.contains("ready\n") == true
    }
  }
}
