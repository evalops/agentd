// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Sparkle

struct SparkleUpdaterConfiguration: Equatable {
  let feedURL: URL?
  let publicEDKey: String

  var isConfigured: Bool {
    feedURL != nil && !publicEDKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var disabledReason: String {
    let missingFeed = feedURL == nil
    let missingKey = publicEDKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    switch (missingFeed, missingKey) {
    case (true, true):
      return "Sparkle update feed and public key are not configured for this build."
    case (true, false):
      return "Sparkle update feed is not configured for this build."
    case (false, true):
      return "Sparkle public key is not configured for this build."
    case (false, false):
      return ""
    }
  }

  static func read(from infoDictionary: [String: Any]) -> SparkleUpdaterConfiguration {
    let feed = (infoDictionary["SUFeedURL"] as? String)
      .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    let publicKey = infoDictionary["SUPublicEDKey"] as? String ?? ""
    return SparkleUpdaterConfiguration(feedURL: feed, publicEDKey: publicKey)
  }
}

@MainActor
final class SparkleSoftwareUpdater {
  private let configuration: SparkleUpdaterConfiguration
  private let updaterController: SPUStandardUpdaterController?

  init(bundle: Bundle = .main) {
    let configuration = SparkleUpdaterConfiguration.read(from: bundle.infoDictionary ?? [:])
    self.configuration = configuration
    if configuration.isConfigured {
      self.updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
      )
    } else {
      self.updaterController = nil
    }
  }

  func configure(menuItem: NSMenuItem) {
    guard let updaterController else {
      menuItem.target = nil
      menuItem.action = nil
      menuItem.isEnabled = false
      menuItem.toolTip = configuration.disabledReason
      return
    }

    menuItem.target = updaterController
    menuItem.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
    menuItem.isEnabled = updaterController.updater.canCheckForUpdates
    menuItem.toolTip = "Check for a signed EvalOps agentd update."
  }
}
