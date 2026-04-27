import AppKit
import Foundation

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var paused: Bool = false
    private let onPauseToggle: @Sendable (Bool) -> Void
    private let onFlushNow: @Sendable () -> Void
    private let onOpenBatchesDir: @Sendable () -> Void
    private let onQuit: @Sendable () -> Void

    init(
        onPauseToggle: @escaping @Sendable (Bool) -> Void,
        onFlushNow: @escaping @Sendable () -> Void,
        onOpenBatchesDir: @escaping @Sendable () -> Void,
        onQuit: @escaping @Sendable () -> Void
    ) {
        self.onPauseToggle = onPauseToggle
        self.onFlushNow = onFlushNow
        self.onOpenBatchesDir = onOpenBatchesDir
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configure()
    }

    private func configure() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "agentd recording")
            button.image?.isTemplate = true
            button.toolTip = "agentd — capturing"
        }

        let pauseItem = NSMenuItem(title: "Pause Capture", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.keyEquivalentModifierMask = [.command, .option, .control]
        pauseItem.target = self
        menu.addItem(pauseItem)

        let flushItem = NSMenuItem(title: "Flush Batch Now", action: #selector(flush), keyEquivalent: "f")
        flushItem.keyEquivalentModifierMask = [.command, .option, .control]
        flushItem.target = self
        menu.addItem(flushItem)

        menu.addItem(.separator())

        let revealItem = NSMenuItem(title: "Reveal Batches in Finder", action: #selector(reveal), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "agentd \(Bundle.main.appVersion) — local-only", action: nil, keyEquivalent: "")
        about.isEnabled = false
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
    @objc private func quit() { onQuit() }
}

private extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}
