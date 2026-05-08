// SPDX-License-Identifier: BUSL-1.1

import Foundation

enum EndpointRedaction {
  static func redact(_ endpoint: URL) -> String {
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    components?.query = nil
    components?.user = nil
    components?.password = nil
    return components?.url?.absoluteString ?? "[redacted]"
  }
}
