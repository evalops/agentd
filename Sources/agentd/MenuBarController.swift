// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation

@MainActor
final class MenuBarController: NSObject {
  private let statusItem: NSStatusItem
  private let menu = NSMenu()
  private var aboutItem: NSMenuItem?
  private var launchAtLoginItem: NSMenuItem?
  private var paused: Bool = false
  private let onPauseToggle: @Sendable (Bool) -> Void
  private let onFlushNow: @Sendable () -> Void
  private let onOpenBatchesDir: @Sendable () -> Void
  private let onOpenDiagnostics: @Sendable () -> Void
  private let onDeleteQueuedBatches: @Sendable () -> Void
  private let onLaunchAtLoginToggle: @Sendable (Bool) -> Void
  private let onQuit: @Sendable () -> Void

  init(
    onPauseToggle: @escaping @Sendable (Bool) -> Void,
    onFlushNow: @escaping @Sendable () -> Void,
    onOpenBatchesDir: @escaping @Sendable () -> Void,
    onOpenDiagnostics: @escaping @Sendable () -> Void,
    onDeleteQueuedBatches: @escaping @Sendable () -> Void,
    onLaunchAtLoginToggle: @escaping @Sendable (Bool) -> Void,
    onQuit: @escaping @Sendable () -> Void
  ) {
    self.onPauseToggle = onPauseToggle
    self.onFlushNow = onFlushNow
    self.onOpenBatchesDir = onOpenBatchesDir
    self.onOpenDiagnostics = onOpenDiagnostics
    self.onDeleteQueuedBatches = onDeleteQueuedBatches
    self.onLaunchAtLoginToggle = onLaunchAtLoginToggle
    self.onQuit = onQuit
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    configure()
  }

  private func configure() {
    if let button = statusItem.button {
      button.image = NSImage(
        systemSymbolName: "circle.fill", accessibilityDescription: "agentd recording")
      button.image?.isTemplate = true
      button.toolTip = "agentd — capturing"
    }

    let pauseItem = NSMenuItem(
      title: "Pause Capture", action: #selector(togglePause), keyEquivalent: "p")
    pauseItem.keyEquivalentModifierMask = [.command, .option, .control]
    pauseItem.target = self
    menu.addItem(pauseItem)

    let flushItem = NSMenuItem(
      title: "Flush Batch Now", action: #selector(flush), keyEquivalent: "f")
    flushItem.keyEquivalentModifierMask = [.command, .option, .control]
    flushItem.target = self
    menu.addItem(flushItem)

    menu.addItem(.separator())

    let revealItem = NSMenuItem(
      title: "Reveal Batches in Finder", action: #selector(reveal), keyEquivalent: "")
    revealItem.target = self
    menu.addItem(revealItem)

    let diagnosticsItem = NSMenuItem(
      title: "Open Diagnostics Report", action: #selector(openDiagnostics), keyEquivalent: "d")
    diagnosticsItem.keyEquivalentModifierMask = [.command, .option, .control]
    diagnosticsItem.target = self
    menu.addItem(diagnosticsItem)

    let deleteItem = NSMenuItem(
      title: "Delete Queued Batches", action: #selector(deleteQueuedBatches), keyEquivalent: "")
    deleteItem.target = self
    menu.addItem(deleteItem)

    menu.addItem(.separator())

    let launchItem = NSMenuItem(
      title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    launchItem.target = self
    launchAtLoginItem = launchItem
    menu.addItem(launchItem)

    menu.addItem(.separator())

    let about = NSMenuItem(
      title: "agentd \(Bundle.main.appVersion) — local-only", action: nil, keyEquivalent: "")
    about.isEnabled = false
    aboutItem = about
    menu.addItem(about)

    menu.addItem(.separator())

    let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)

    statusItem.menu = menu
  }

  @objc private func togglePause() {
    paused.toggle()
    if let button = statusItem.button {
      button.image = NSImage(
        systemSymbolName: paused ? "pause.circle" : "circle.fill",
        accessibilityDescription: paused ? "agentd paused" : "agentd recording"
      )
      button.image?.isTemplate = true
      button.toolTip = paused ? "agentd — paused" : "agentd — capturing"
    }
    if let item = menu.items.first {
      item.title = paused ? "Resume Capture" : "Pause Capture"
    }
    onPauseToggle(paused)
  }

  @objc private func flush() { onFlushNow() }
  @objc private func reveal() { onOpenBatchesDir() }
  @objc private func openDiagnostics() { onOpenDiagnostics() }
  @objc private func deleteQueuedBatches() { onDeleteQueuedBatches() }
  @objc private func toggleLaunchAtLogin() {
    let next = !(launchAtLoginItem?.state == .on)
    launchAtLoginItem?.state = next ? .on : .off
    onLaunchAtLoginToggle(next)
  }
  @objc private func quit() { onQuit() }

  func setStatus(paused: Bool, detail: String, localOnly: Bool, policyVersion: String?) {
    self.paused = paused
    if let button = statusItem.button {
      button.image = NSImage(
        systemSymbolName: paused ? "pause.circle" : "circle.fill",
        accessibilityDescription: paused ? "agentd paused" : "agentd recording"
      )
      button.image?.isTemplate = true
      button.toolTip = "agentd — \(detail)"
    }
    if let item = menu.items.first {
      item.title = paused ? "Resume Capture" : "Pause Capture"
    }
    let mode = localOnly ? "local-only" : "managed"
    let policy = policyVersion.map { " policy \($0)" } ?? ""
    aboutItem?.title = "agentd \(Bundle.main.appVersion) — \(mode)\(policy)"
    launchAtLoginItem?.state = LaunchAtLoginController.isEnabled ? .on : .off
  }
}

extension Bundle {
  var appVersion: String {
    (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
  }
}
