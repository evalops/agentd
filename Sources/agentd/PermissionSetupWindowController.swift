// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation

@MainActor
final class PermissionSetupWindowController: NSWindowController {
  private let currentPermissions: @MainActor @Sendable () -> PermissionSnapshot
  private let onOpenScreenRecordingSettings: @MainActor @Sendable () -> Void
  private let onOpenAccessibilitySettings: @MainActor @Sendable () -> Void
  private let onRelaunch: @MainActor @Sendable () -> Void

  private let screenStatus = NSTextField(labelWithString: "")
  private let accessibilityStatus = NSTextField(labelWithString: "")
  private let bundlePath = NSTextField(labelWithString: Bundle.main.bundleURL.path)
  private let recheckButton = NSButton(title: "Recheck", target: nil, action: nil)

  init(
    currentPermissions: @escaping @MainActor @Sendable () -> PermissionSnapshot,
    onOpenScreenRecordingSettings: @escaping @MainActor @Sendable () -> Void,
    onOpenAccessibilitySettings: @escaping @MainActor @Sendable () -> Void,
    onRelaunch: @escaping @MainActor @Sendable () -> Void
  ) {
    self.currentPermissions = currentPermissions
    self.onOpenScreenRecordingSettings = onOpenScreenRecordingSettings
    self.onOpenAccessibilitySettings = onOpenAccessibilitySettings
    self.onRelaunch = onRelaunch

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 248),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "agentd Permissions"
    window.isReleasedWhenClosed = false
    window.center()

    super.init(window: window)
    window.contentView = makeContentView()
    refresh()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show() {
    refresh()
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func makeContentView() -> NSView {
    let root = NSView()

    let title = NSTextField(labelWithString: "Permission Setup")
    title.font = .systemFont(ofSize: 17, weight: .semibold)

    let subtitle = NSTextField(labelWithString: "Bundle identity")
    subtitle.font = .systemFont(ofSize: 11, weight: .medium)
    subtitle.textColor = .secondaryLabelColor

    bundlePath.lineBreakMode = .byTruncatingMiddle
    bundlePath.toolTip = Bundle.main.bundleURL.path
    bundlePath.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

    let screenButton = makeActionButton(
      title: "Open Screen Recording",
      action: #selector(openScreenRecordingSettings)
    )
    let accessibilityButton = makeActionButton(
      title: "Open Accessibility",
      action: #selector(openAccessibilitySettings)
    )
    let relaunchButton = makeActionButton(title: "Relaunch", action: #selector(relaunch))
    recheckButton.target = self
    recheckButton.action = #selector(recheck)

    let screenRow = makePermissionRow(
      name: "Screen Recording",
      status: screenStatus,
      action: screenButton
    )
    let accessibilityRow = makePermissionRow(
      name: "Accessibility",
      status: accessibilityStatus,
      action: accessibilityButton
    )

    let pathStack = NSStackView(views: [subtitle, bundlePath])
    pathStack.orientation = .vertical
    pathStack.alignment = .leading
    pathStack.spacing = 4

    let buttonStack = NSStackView(views: [recheckButton, relaunchButton])
    buttonStack.orientation = .horizontal
    buttonStack.alignment = .centerY
    buttonStack.spacing = 8

    let stack = NSStackView(views: [title, screenRow, accessibilityRow, pathStack, buttonStack])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    root.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -22),
      bundlePath.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])

    return root
  }

  private func makePermissionRow(name: String, status: NSTextField, action: NSButton) -> NSView {
    let label = NSTextField(labelWithString: name)
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.widthAnchor.constraint(equalToConstant: 142).isActive = true

    status.font = .systemFont(ofSize: 13)
    status.widthAnchor.constraint(equalToConstant: 96).isActive = true

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [label, status, spacer, action])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    row.widthAnchor.constraint(equalToConstant: 476).isActive = true
    return row
  }

  private func makeActionButton(title: String, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    return button
  }

  @objc private func recheck() {
    refresh()
  }

  @objc private func openScreenRecordingSettings() {
    onOpenScreenRecordingSettings()
  }

  @objc private func openAccessibilitySettings() {
    onOpenAccessibilitySettings()
  }

  @objc private func relaunch() {
    onRelaunch()
  }

  private func refresh() {
    let permissions = currentPermissions()
    update(status: screenStatus, trusted: permissions.screenCaptureTrusted)
    update(status: accessibilityStatus, trusted: permissions.accessibilityTrusted)
    recheckButton.toolTip = permissions.menuSummary
  }

  private func update(status: NSTextField, trusted: Bool) {
    status.stringValue = trusted ? "Ready" : "Needs access"
    status.textColor = trusted ? .systemGreen : .systemOrange
  }
}
