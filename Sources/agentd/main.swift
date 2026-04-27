import AppKit
import Foundation

@MainActor
final class AppController {
    private let config: AgentConfig
    private let pipeline: FramePipeline
    private let submitter: Submitter
    private var capture: CaptureService!
    private var menuBar: MenuBarController!
    private var paused = false
    private var flushTimer: Timer?

    init() {
        let cfg = ConfigStore.load()
        self.config = cfg

        let submitter = Submitter(endpoint: cfg.endpoint, localOnly: cfg.localOnly)
        self.submitter = submitter

        self.pipeline = FramePipeline(config: cfg) { batch in
            await submitter.submit(batch)
        }
    }

    func boot() async {
        if !WindowContextProbe.axTrustedPrompt() {
            Log.app.warning("Accessibility not granted yet — window-context will be empty until granted")
        }

        let pipeline = pipeline
        capture = CaptureService { [pipeline] frame in
            let ctx = await MainActor.run { WindowContextProbe.current() }
            await pipeline.consume(frame, context: ctx)
        }

        menuBar = MenuBarController(
            onPauseToggle: { [weak self] paused in
                Task { @MainActor in await self?.applyPause(paused) }
            },
            onFlushNow: { [weak self] in
                Task { await self?.pipeline.flush() }
                _ = self
            },
            onOpenBatchesDir: {
                let dir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".evalops/agentd/batches")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            },
            onQuit: {
                Task { @MainActor in NSApp.terminate(nil) }
            }
        )

        do {
            try await capture.start(targetFps: config.captureFps)
        } catch {
            Log.app.error("capture start failed: \(error.localizedDescription, privacy: .public)")
        }

        let interval = config.batchIntervalSeconds
        flushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { await pipeline.flush() }
        }

        Log.app.info("agentd booted device=\(self.config.deviceId, privacy: .public) localOnly=\(self.config.localOnly, privacy: .public)")
    }

    private func applyPause(_ paused: Bool) async {
        guard paused != self.paused else { return }
        self.paused = paused
        if paused {
            await capture.stop()
        } else {
            try? await capture.start(targetFps: config.captureFps)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let c = AppController()
        controller = c
        Task { await c.boot() }
    }
}

// Status-bar-only app — no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
