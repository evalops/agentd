// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation

@MainActor
final class MenuBarController: NSObject {
  private let statusItem: NSStatusItem
  private let menu = NSMenu()
  private var captureStateItem: NSMenuItem?
  private var pauseItem: NSMenuItem?
  private var permissionItem: NSMenuItem?
  private var screenRecordingItem: NSMenuItem?
  private var accessibilityItem: NSMenuItem?
  private var aboutItem: NSMenuItem?
  private var launchAtLoginItem: NSMenuItem?
  private var paused: Bool = false
  private var needsPermission: Bool = false
  private let onPauseToggle: @Sendable (Bool) -> Void
  private let onFlushNow: @Sendable () -> Void
  private let onOpenBatchesDir: @Sendable () -> Void
  private let onOpenDiagnostics: @Sendable () -> Void
  private let onDeleteQueuedBatches: @Sendable () -> Void
  private let onRefreshPermissions: @Sendable () -> Void
  private let onOpenScreenRecordingSettings: @Sendable () -> Void
  private let onOpenAccessibilitySettings: @Sendable () -> Void
  private let onRelaunch: @Sendable () -> Void
  private let onLaunchAtLoginToggle: @Sendable (Bool) -> Void
  private let onQuit: @Sendable () -> Void

  init(
    onPauseToggle: @escaping @Sendable (Bool) -> Void,
    onFlushNow: @escaping @Sendable () -> Void,
    onOpenBatchesDir: @escaping @Sendable () -> Void,
    onOpenDiagnostics: @escaping @Sendable () -> Void,
    onDeleteQueuedBatches: @escaping @Sendable () -> Void,
    onRefreshPermissions: @escaping @Sendable () -> Void,
    onOpenScreenRecordingSettings: @escaping @Sendable () -> Void,
    onOpenAccessibilitySettings: @escaping @Sendable () -> Void,
    onRelaunch: @escaping @Sendable () -> Void,
    onLaunchAtLoginToggle: @escaping @Sendable (Bool) -> Void,
    onQuit: @escaping @Sendable () -> Void
  ) {
    self.onPauseToggle = onPauseToggle
    self.onFlushNow = onFlushNow
    self.onOpenBatchesDir = onOpenBatchesDir
    self.onOpenDiagnostics = onOpenDiagnostics
    self.onDeleteQueuedBatches = onDeleteQueuedBatches
    self.onRefreshPermissions = onRefreshPermissions
    self.onOpenScreenRecordingSettings = onOpenScreenRecordingSettings
    self.onOpenAccessibilitySettings = onOpenAccessibilitySettings
    self.onRelaunch = onRelaunch
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

    let captureStateItem = NSMenuItem(title: "Status: Starting…", action: nil, keyEquivalent: "")
    captureStateItem.isEnabled = false
    self.captureStateItem = captureStateItem
    menu.addItem(captureStateItem)

    menu.addItem(.separator())

    let pauseItem = NSMenuItem(
      title: "Pause Capture", action: #selector(togglePause), keyEquivalent: "p")
    pauseItem.keyEquivalentModifierMask = [.command, .option, .control]
    pauseItem.target = self
    self.pauseItem = pauseItem
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

    let permissionItem = NSMenuItem(
      title: "Permissions: Checking…", action: nil, keyEquivalent: "")
    permissionItem.isEnabled = false
    self.permissionItem = permissionItem
    menu.addItem(permissionItem)

    let refreshPermissionsItem = NSMenuItem(
      title: "Check Permission Status", action: #selector(refreshPermissions), keyEquivalent: "")
    refreshPermissionsItem.target = self
    menu.addItem(refreshPermissionsItem)

    let screenRecordingItem = NSMenuItem(
      title: "Open Screen & System Audio Recording Settings",
      action: #selector(openScreenRecordingSettings),
      keyEquivalent: ""
    )
    screenRecordingItem.target = self
    self.screenRecordingItem = screenRecordingItem
    menu.addItem(screenRecordingItem)

    let accessibilityItem = NSMenuItem(
      title: "Open Accessibility Settings",
      action: #selector(openAccessibilitySettings),
      keyEquivalent: ""
    )
    accessibilityItem.target = self
    self.accessibilityItem = accessibilityItem
    menu.addItem(accessibilityItem)

    let relaunchItem = NSMenuItem(
      title: "Relaunch agentd", action: #selector(relaunch), keyEquivalent: "")
    relaunchItem.target = self
    menu.addItem(relaunchItem)

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
    updateStatusButton(detail: paused ? "paused" : "capturing")
    pauseItem?.title = paused ? "Resume Capture" : "Pause Capture"
    onPauseToggle(paused)
  }

  @objc private func flush() { onFlushNow() }
  @objc private func reveal() { onOpenBatchesDir() }
  @objc private func openDiagnostics() { onOpenDiagnostics() }
  @objc private func deleteQueuedBatches() { onDeleteQueuedBatches() }
  @objc private func refreshPermissions() { onRefreshPermissions() }
  @objc private func openScreenRecordingSettings() { onOpenScreenRecordingSettings() }
  @objc private func openAccessibilitySettings() { onOpenAccessibilitySettings() }
  @objc private func relaunch() { onRelaunch() }
  @objc private func toggleLaunchAtLogin() {
    let next = !(launchAtLoginItem?.state == .on)
    launchAtLoginItem?.state = next ? .on : .off
    onLaunchAtLoginToggle(next)
  }
  @objc private func quit() { onQuit() }

  func setStatus(
    paused: Bool,
    detail: String,
    permissions: PermissionSnapshot,
    localOnly: Bool,
    policyVersion: String?
  ) {
    self.paused = paused
    needsPermission = !permissions.allTrusted
    updateStatusButton(detail: detail)
    pauseItem?.title = paused ? "Resume Capture" : "Pause Capture"
    captureStateItem?.title = "Status: \(detail)"
    permissionItem?.title = "Permissions: \(permissions.menuSummary)"
    screenRecordingItem?.isEnabled = !permissions.screenCaptureTrusted
    accessibilityItem?.isEnabled = !permissions.accessibilityTrusted
    let mode = localOnly ? "local-only" : "managed"
    let policy = policyVersion.map { " policy \($0)" } ?? ""
    aboutItem?.title = "agentd \(Bundle.main.appVersion) — \(mode)\(policy)"
    launchAtLoginItem?.state = LaunchAtLoginController.isEnabled ? .on : .off
  }

  private func statusSymbol(paused: Bool, needsPermission: Bool) -> String {
    if needsPermission { return "exclamationmark.triangle.fill" }
    return paused ? "pause.circle" : "circle.fill"
  }

  private func accessibilityDescription(paused: Bool, needsPermission: Bool) -> String {
    if needsPermission { return "agentd permissions needed" }
    return paused ? "agentd paused" : "agentd recording"
  }

  private func updateStatusButton(detail: String) {
    if let button = statusItem.button {
      button.image = NSImage(
        systemSymbolName: statusSymbol(paused: paused, needsPermission: needsPermission),
        accessibilityDescription: accessibilityDescription(
          paused: paused, needsPermission: needsPermission)
      )
      button.image?.isTemplate = true
      button.toolTip = needsPermission ? "agentd — permissions needed" : "agentd — \(detail)"
    }
  }
}

extension Bundle {
  var appVersion: String {
    (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
  }
}
