// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
  private let statusItem: NSStatusItem
  private let menu = NSMenu()
  private let headerView = MenuHeaderView()
  private var captureStateItem: NSMenuItem?
  private var pauseItem: NSMenuItem?
  private var permissionItem: NSMenuItem?
  private var refreshPermissionsItem: NSMenuItem?
  private var permissionSetupItem: NSMenuItem?
  private var screenRecordingItem: NSMenuItem?
  private var accessibilityItem: NSMenuItem?
  private var checkForUpdatesItem: NSMenuItem?
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
  private let onOpenPermissionSetup: @Sendable () -> Void
  private let onOpenScreenRecordingSettings: @Sendable () -> Void
  private let onOpenAccessibilitySettings: @Sendable () -> Void
  private let onRelaunch: @Sendable () -> Void
  private let onLaunchAtLoginToggle: @Sendable (Bool) -> Void
  private let updateStatusProvider: @MainActor () -> SparkleUpdateMenuPresentation
  private let configureUpdatesMenuItem: @MainActor (NSMenuItem) -> Void
  private let onQuit: @Sendable () -> Void

  init(
    onPauseToggle: @escaping @Sendable (Bool) -> Void,
    onFlushNow: @escaping @Sendable () -> Void,
    onOpenBatchesDir: @escaping @Sendable () -> Void,
    onOpenDiagnostics: @escaping @Sendable () -> Void,
    onDeleteQueuedBatches: @escaping @Sendable () -> Void,
    onRefreshPermissions: @escaping @Sendable () -> Void,
    onOpenPermissionSetup: @escaping @Sendable () -> Void,
    onOpenScreenRecordingSettings: @escaping @Sendable () -> Void,
    onOpenAccessibilitySettings: @escaping @Sendable () -> Void,
    onRelaunch: @escaping @Sendable () -> Void,
    onLaunchAtLoginToggle: @escaping @Sendable (Bool) -> Void,
    updateStatusProvider: @escaping @MainActor () -> SparkleUpdateMenuPresentation,
    configureUpdatesMenuItem: @escaping @MainActor (NSMenuItem) -> Void,
    onQuit: @escaping @Sendable () -> Void
  ) {
    self.onPauseToggle = onPauseToggle
    self.onFlushNow = onFlushNow
    self.onOpenBatchesDir = onOpenBatchesDir
    self.onOpenDiagnostics = onOpenDiagnostics
    self.onDeleteQueuedBatches = onDeleteQueuedBatches
    self.onRefreshPermissions = onRefreshPermissions
    self.onOpenPermissionSetup = onOpenPermissionSetup
    self.onOpenScreenRecordingSettings = onOpenScreenRecordingSettings
    self.onOpenAccessibilitySettings = onOpenAccessibilitySettings
    self.onRelaunch = onRelaunch
    self.onLaunchAtLoginToggle = onLaunchAtLoginToggle
    self.updateStatusProvider = updateStatusProvider
    self.configureUpdatesMenuItem = configureUpdatesMenuItem
    self.onQuit = onQuit
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    configure()
  }

  private func configure() {
    menu.minimumWidth = 340
    menu.delegate = self

    if let button = statusItem.button {
      button.image = NSImage(
        systemSymbolName: "circle.fill", accessibilityDescription: "agentd recording")
      button.image?.isTemplate = true
      button.toolTip = "agentd — capturing"
    }

    let headerItem = NSMenuItem()
    headerItem.view = headerView
    menu.addItem(headerItem)

    let captureStateItem = NSMenuItem(title: "Status: Starting…", action: nil, keyEquivalent: "")
    captureStateItem.isEnabled = false
    self.captureStateItem = captureStateItem
    menu.addItem(captureStateItem)

    menu.addItem(.separator())
    addSectionTitle("Capture")

    let pauseItem = makeItem(
      title: "Pause Capture",
      symbolName: "pause.circle",
      action: #selector(togglePause),
      keyEquivalent: "p"
    )
    pauseItem.keyEquivalentModifierMask = [.command, .option, .control]
    self.pauseItem = pauseItem
    menu.addItem(pauseItem)

    let flushItem = makeItem(
      title: "Flush Batch Now",
      symbolName: "paperplane",
      action: #selector(flush),
      keyEquivalent: "f"
    )
    flushItem.keyEquivalentModifierMask = [.command, .option, .control]
    menu.addItem(flushItem)

    menu.addItem(.separator())
    addSectionTitle("Data")

    let revealItem = makeItem(
      title: "Reveal Batches",
      symbolName: "folder",
      action: #selector(reveal)
    )
    menu.addItem(revealItem)

    let diagnosticsItem = makeItem(
      title: "Diagnostics Report",
      symbolName: "stethoscope",
      action: #selector(openDiagnostics),
      keyEquivalent: "d"
    )
    diagnosticsItem.keyEquivalentModifierMask = [.command, .option, .control]
    menu.addItem(diagnosticsItem)

    let deleteItem = makeItem(
      title: "Delete Queued Batches",
      symbolName: "trash",
      action: #selector(deleteQueuedBatches)
    )
    menu.addItem(deleteItem)

    menu.addItem(.separator())
    addSectionTitle("Permissions")

    let permissionItem = NSMenuItem(
      title: "Permissions: Checking…", action: nil, keyEquivalent: "")
    permissionItem.isEnabled = false
    self.permissionItem = permissionItem
    menu.addItem(permissionItem)

    let refreshPermissionsItem = makeItem(
      title: "Refresh Permissions",
      symbolName: "arrow.clockwise",
      action: #selector(refreshPermissions)
    )
    self.refreshPermissionsItem = refreshPermissionsItem
    menu.addItem(refreshPermissionsItem)

    let permissionSetupItem = makeItem(
      title: "Permission Setup",
      symbolName: "lock.shield",
      action: #selector(openPermissionSetup)
    )
    self.permissionSetupItem = permissionSetupItem
    menu.addItem(permissionSetupItem)

    let screenRecordingItem = makeItem(
      title: "Screen Recording Settings",
      symbolName: "record.circle",
      action: #selector(openScreenRecordingSettings)
    )
    self.screenRecordingItem = screenRecordingItem
    menu.addItem(screenRecordingItem)

    let accessibilityItem = makeItem(
      title: "Accessibility Settings",
      symbolName: "figure.wave",
      action: #selector(openAccessibilitySettings)
    )
    self.accessibilityItem = accessibilityItem
    menu.addItem(accessibilityItem)

    menu.addItem(.separator())
    addSectionTitle("App")

    let launchItem = makeItem(
      title: "Launch at Login",
      symbolName: "power",
      action: #selector(toggleLaunchAtLogin)
    )
    launchAtLoginItem = launchItem
    menu.addItem(launchItem)

    let checkForUpdatesItem = makeItem(
      title: "Check for Updates…",
      symbolName: "arrow.down.circle",
      action: nil
    )
    configureUpdatesMenuItem(checkForUpdatesItem)
    self.checkForUpdatesItem = checkForUpdatesItem
    menu.addItem(checkForUpdatesItem)

    let relaunchItem = makeItem(
      title: "Relaunch",
      symbolName: "arrow.trianglehead.clockwise",
      action: #selector(relaunch)
    )
    menu.addItem(relaunchItem)

    menu.addItem(.separator())

    let about = NSMenuItem(
      title: "agentd \(Bundle.main.appVersion) — local-only", action: nil, keyEquivalent: "")
    about.isEnabled = false
    aboutItem = about
    menu.addItem(about)

    menu.addItem(.separator())

    let quit = makeItem(
      title: "Quit",
      symbolName: "xmark.circle",
      action: #selector(quit),
      keyEquivalent: "q"
    )
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
  @objc private func openPermissionSetup() { onOpenPermissionSetup() }
  @objc private func openScreenRecordingSettings() { onOpenScreenRecordingSettings() }
  @objc private func openAccessibilitySettings() { onOpenAccessibilitySettings() }
  @objc private func relaunch() { onRelaunch() }
  @objc private func toggleLaunchAtLogin() {
    let next = !(launchAtLoginItem?.state == .on)
    launchAtLoginItem?.state = next ? .on : .off
    onLaunchAtLoginToggle(next)
  }
  @objc private func quit() { onQuit() }

  func menuWillOpen(_ menu: NSMenu) {
    onRefreshPermissions()
  }

  func setStatus(
    paused: Bool,
    detail: String,
    permissions: PermissionSnapshot,
    localOnly: Bool,
    policyVersion: String?
  ) {
    let presentation = MenuStatusPresentation(
      paused: paused,
      detail: detail,
      permissions: permissions,
      localOnly: localOnly,
      policyVersion: policyVersion,
      appVersion: Bundle.main.appVersion
    )
    self.paused = paused
    needsPermission = !permissions.allTrusted
    updateStatusButton(detail: detail)
    pauseItem?.title = paused ? "Resume Capture" : "Pause Capture"
    pauseItem?.image = menuSymbol(paused ? "play.circle" : "pause.circle")
    captureStateItem?.title = presentation.statusLine
    permissionItem?.title = presentation.permissionsLine
    permissionItem?.image = menuSymbol(
      permissions.allTrusted ? "checkmark.shield" : "exclamationmark.triangle")
    refreshPermissionsItem?.image = menuSymbol(
      permissions.allTrusted ? "checkmark.circle" : "arrow.clockwise")
    permissionSetupItem?.image = menuSymbol(
      permissions.allTrusted ? "checkmark.shield" : "lock.shield")
    screenRecordingItem?.title =
      permissions.screenCaptureTrusted
      ? "Screen Recording Granted"
      : "Screen Recording Settings"
    screenRecordingItem?.image = menuSymbol(
      permissions.screenCaptureTrusted ? "checkmark.circle" : "record.circle")
    screenRecordingItem?.isEnabled = !permissions.screenCaptureTrusted
    accessibilityItem?.title =
      permissions.accessibilityTrusted
      ? "Accessibility Granted"
      : "Accessibility Settings"
    accessibilityItem?.image = menuSymbol(
      permissions.accessibilityTrusted ? "checkmark.circle" : "figure.wave")
    accessibilityItem?.isEnabled = !permissions.accessibilityTrusted
    aboutItem?.title = presentation.aboutLine
    headerView.update(presentation, updates: updateStatusProvider())
    launchAtLoginItem?.state = LaunchAtLoginController.isEnabled ? .on : .off
    if let checkForUpdatesItem {
      configureUpdatesMenuItem(checkForUpdatesItem)
    }
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

  @discardableResult
  private func addSectionTitle(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title.uppercased(), action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(
      string: title.uppercased(),
      attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )
    menu.addItem(item)
    return item
  }

  private func makeItem(
    title: String,
    symbolName: String,
    action: Selector?,
    keyEquivalent: String = ""
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = self
    item.image = menuSymbol(symbolName)
    return item
  }

  private func menuSymbol(_ symbolName: String) -> NSImage? {
    let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    image?.isTemplate = true
    return image
  }
}

struct MenuStatusPresentation: Equatable {
  let title: String
  let subtitle: String
  let detail: String
  let badgeText: String
  let statusLine: String
  let permissionsLine: String
  let aboutLine: String
  let symbolName: String

  init(
    paused: Bool,
    detail: String,
    permissions: PermissionSnapshot,
    localOnly: Bool,
    policyVersion: String?,
    appVersion: String
  ) {
    self.detail = detail
    let mode = localOnly ? "local-only" : "managed"
    let policy = policyVersion.map { " policy \($0)" } ?? ""
    self.subtitle = "\(mode)\(policy)"
    self.title = permissions.allTrusted ? "EvalOps agentd" : "EvalOps agentd needs permissions"
    self.statusLine = "Status: \(detail)"
    self.permissionsLine = "Permissions: \(permissions.menuSummary)"
    self.aboutLine = "agentd \(appVersion) — \(mode)\(policy)"
    if !permissions.allTrusted {
      self.badgeText = "Setup"
      self.symbolName = "exclamationmark.triangle.fill"
    } else if paused {
      self.badgeText = "Paused"
      self.symbolName = "pause.circle"
    } else {
      self.badgeText = "Capturing"
      self.symbolName = "circle.fill"
    }
  }
}

@MainActor
private final class MenuHeaderView: NSView {
  private let materialView = NSVisualEffectView()
  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "EvalOps agentd")
  private let subtitleLabel = NSTextField(labelWithString: "local-only")
  private let badgeLabel = NSTextField(labelWithString: "Starting")
  private let detailLabel = NSTextField(labelWithString: "Starting…")
  private let permissionLabel = NSTextField(labelWithString: "Permissions: Checking…")
  private let updateLabel = NSTextField(labelWithString: "Updates: Checking…")

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 112))
    translatesAutoresizingMaskIntoConstraints = false
    build()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 340, height: 112)
  }

  func update(_ presentation: MenuStatusPresentation, updates: SparkleUpdateMenuPresentation) {
    titleLabel.stringValue = presentation.title
    subtitleLabel.stringValue = presentation.subtitle
    badgeLabel.stringValue = presentation.badgeText
    detailLabel.stringValue = presentation.detail
    permissionLabel.stringValue = presentation.permissionsLine
    updateLabel.stringValue = updates.statusLine
    iconView.image = NSImage(
      systemSymbolName: presentation.symbolName,
      accessibilityDescription: presentation.title
    )
    iconView.contentTintColor =
      presentation.symbolName == "exclamationmark.triangle.fill"
      ? .systemYellow
      : .controlAccentColor
    badgeLabel.textColor =
      presentation.symbolName == "exclamationmark.triangle.fill"
      ? .controlTextColor
      : .controlAccentColor
    badgeLabel.layer?.backgroundColor =
      presentation.symbolName == "exclamationmark.triangle.fill"
      ? NSColor.systemYellow.withAlphaComponent(0.22).cgColor
      : NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
  }

  private func build() {
    materialView.material = .menu
    materialView.blendingMode = .withinWindow
    materialView.state = .active
    materialView.translatesAutoresizingMaskIntoConstraints = false
    materialView.wantsLayer = true
    materialView.layer?.cornerRadius = 10
    materialView.layer?.masksToBounds = true
    materialView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
    materialView.layer?.borderWidth = 0.5
    addSubview(materialView)

    iconView.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
    iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
    iconView.contentTintColor = .controlAccentColor
    iconView.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingTail

    subtitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
    subtitleLabel.textColor = .secondaryLabelColor
    subtitleLabel.lineBreakMode = .byTruncatingTail

    badgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
    badgeLabel.alignment = .center
    badgeLabel.textColor = .controlAccentColor
    badgeLabel.wantsLayer = true
    badgeLabel.layer?.cornerRadius = 8
    badgeLabel.layer?.masksToBounds = true
    badgeLabel.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
    badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
    badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
    detailLabel.textColor = .labelColor
    detailLabel.lineBreakMode = .byTruncatingTail

    permissionLabel.font = .systemFont(ofSize: 11, weight: .regular)
    permissionLabel.textColor = .secondaryLabelColor
    permissionLabel.lineBreakMode = .byTruncatingTail

    updateLabel.font = .systemFont(ofSize: 11, weight: .regular)
    updateLabel.textColor = .tertiaryLabelColor
    updateLabel.lineBreakMode = .byTruncatingTail

    let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
    titleStack.orientation = .vertical
    titleStack.alignment = .leading
    titleStack.spacing = 1
    titleStack.translatesAutoresizingMaskIntoConstraints = false

    let row = NSStackView(views: [iconView, titleStack])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 9
    row.translatesAutoresizingMaskIntoConstraints = false

    let detailRow = NSStackView(views: [detailLabel, badgeLabel])
    detailRow.orientation = .horizontal
    detailRow.alignment = .centerY
    detailRow.distribution = .fill
    detailRow.spacing = 8
    detailRow.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [row, detailRow, permissionLabel, updateLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 5
    stack.translatesAutoresizingMaskIntoConstraints = false
    materialView.addSubview(stack)

    NSLayoutConstraint.activate([
      materialView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      materialView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      materialView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      materialView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      iconView.widthAnchor.constraint(equalToConstant: 24),
      iconView.heightAnchor.constraint(equalToConstant: 24),
      badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 58),
      badgeLabel.heightAnchor.constraint(equalToConstant: 18),
      stack.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 10),
      stack.bottomAnchor.constraint(equalTo: materialView.bottomAnchor, constant: -9),
      titleStack.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
      detailRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
      permissionLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
      updateLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
    ])
  }
}

extension Bundle {
  var appVersion: String {
    (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
  }
}
