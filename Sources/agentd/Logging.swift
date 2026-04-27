// SPDX-License-Identifier: BUSL-1.1

import Foundation
import OSLog

enum Log {
  static let subsystem = "dev.evalops.agentd"
  static let app = Logger(subsystem: subsystem, category: "app")
  static let capture = Logger(subsystem: subsystem, category: "capture")
  static let ocr = Logger(subsystem: subsystem, category: "ocr")
  static let scrub = Logger(subsystem: subsystem, category: "scrub")
  static let policy = Logger(subsystem: subsystem, category: "policy")
  static let submit = Logger(subsystem: subsystem, category: "submit")
}
