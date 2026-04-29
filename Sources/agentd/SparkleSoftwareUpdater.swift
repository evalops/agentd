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

struct SparkleUpdateMenuPresentation: Equatable {
  let title: String
  let statusLine: String
  let toolTip: String
  let symbolName: String
  let isConfigured: Bool

  init(configuration: SparkleUpdaterConfiguration) {
    self.isConfigured = configuration.isConfigured
    if configuration.isConfigured {
      self.title = "Check for Updates…"
      self.statusLine = "Updates: Enabled"
      self.toolTip = "Check for a signed EvalOps agentd update."
      self.symbolName = "arrow.down.circle"
    } else {
      self.title = "Updates Not Configured"
      self.statusLine = "Updates: Local build"
      self.toolTip = configuration.disabledReason
      self.symbolName = "arrow.down.circle.dotted"
    }
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

  var menuPresentation: SparkleUpdateMenuPresentation {
    SparkleUpdateMenuPresentation(configuration: configuration)
  }

  func configure(menuItem: NSMenuItem) {
    let presentation = menuPresentation
    menuItem.title = presentation.title
    menuItem.image = Self.menuSymbol(presentation.symbolName)
    menuItem.toolTip = presentation.toolTip

    guard let updaterController else {
      menuItem.target = nil
      menuItem.action = nil
      menuItem.isEnabled = false
      return
    }

    menuItem.target = updaterController
    menuItem.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
    menuItem.isEnabled = updaterController.updater.canCheckForUpdates
  }

  private static func menuSymbol(_ symbolName: String) -> NSImage? {
    let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    image?.isTemplate = true
    return image
  }
}
