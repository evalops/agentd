// SPDX-License-Identifier: BUSL-1.1

import Foundation
import XCTest

@testable import agentd

final class CaptureWorkerSupervisorTests: XCTestCase {
  func testTerminatesWorkerWithTermDuringGraceWindow() throws {
    let supervisor = CaptureWorkerSupervisor()
    let pid = try supervisor.start(
      CaptureWorkerProcessSpec(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["30"]
      )
    )

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
    let pid = try supervisor.start(
      CaptureWorkerProcessSpec(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "trap '' TERM; sleep 30"]
      )
    )

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
}
