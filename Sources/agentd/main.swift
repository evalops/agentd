// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation

@MainActor
final class AppController {
  private let policyBaseConfig: AgentConfig
  private var config: AgentConfig
  private let pipeline: FramePipeline
  private let submitter: Submitter
  private let controlClient: ChronicleControlClient?
  private var runtimeLock: AgentdRuntimeLock?
  private var capture: CaptureService!
  private var menuBar: MenuBarController!
  private var userPaused = false
  private var captureRunning = false
  private var controlState = ChronicleControlState()
  private var scheduledPauseWindows: [ScheduledPauseWindow] = []
  private var policySource: String?
  private var flushTimer: Timer?
  private var idleTimer: Timer?
  private var heartbeatTimer: Timer?
  private var pauseWindowTimer: Timer?
  private var captureRetryTimer: Timer?
  private var foregroundPrivacyTimer: Timer?
  private var eventCaptureTimer: Timer?
  private var captureHealthTimer: Timer?
  private var eventMonitors: [Any] = []
  private var typingPauseTimer: Timer?
  private var scrollStopTimer: Timer?
  private var foregroundPrivacyPauseReason: String?
  private var eventCaptureScheduler: EventCaptureScheduler
  private var captureHealthWatchdog = CaptureHealthWatchdog()
  private var eventCaptureInFlight = false
  private var idleMode = false

  init() {
    let cfg = ConfigStore.load()
    self.policyBaseConfig = cfg
    self.config = cfg
    self.eventCaptureScheduler = EventCaptureScheduler(config: cfg)

    let submitter: Submitter
    do {
      submitter = try Submitter(
        endpoint: cfg.endpoint,
        localOnly: cfg.localOnly,
        authMode: cfg.auth,
        secretBroker: cfg.secretBroker,
        maxBatchBytes: cfg.maxBatchBytes,
        maxBatchAgeDays: cfg.maxBatchAgeDays,
        deviceId: cfg.deviceId,
        encryptLocalBatches: cfg.encryptLocalBatches
      )
    } catch {
      Log.submit.fault(
        "submitter config rejected: \(error.localizedDescription, privacy: .public); forcing local-only"
      )
      submitter = try! Submitter(
        endpoint: cfg.endpoint,
        localOnly: true,
        authMode: .none,
        maxBatchBytes: cfg.maxBatchBytes,
        maxBatchAgeDays: cfg.maxBatchAgeDays,
        deviceId: cfg.deviceId,
        encryptLocalBatches: false
      )
    }
    self.submitter = submitter

    self.pipeline = FramePipeline(config: cfg) { batch in
      await submitter.submit(batch)
    }

    if cfg.localOnly {
      self.controlClient = nil
    } else {
      do {
        self.controlClient = try ChronicleControlClient(
          submitBatchEndpoint: cfg.endpoint,
          authMode: cfg.auth
        )
      } catch {
        Log.app.error(
          "chronicle control disabled: \(error.localizedDescription, privacy: .public)"
        )
        self.controlClient = nil
      }
    }
  }

  func boot() async {
    do {
      runtimeLock = try AgentdRuntimeLock.acquire(purpose: "daemon")
    } catch {
      controlState.lastError = error.localizedDescription
      Log.app.fault(
        "agentd runtime lock unavailable: \(error.localizedDescription, privacy: .public)")
      NSApp.terminate(nil)
      return
    }

    let permissions = PermissionSnapshot.current(promptForAccessibility: true)
    if !permissions.accessibilityTrusted {
      Log.app.warning("Accessibility not granted yet — window-context will be empty until granted")
    }

    let pipeline = pipeline
    capture = CaptureService { [pipeline] frame in
      let ctx = await MainActor.run { WindowContextProbe.current() }
      let axText = await MainActor.run { AccessibilityTextExtractor.current(context: ctx) }
      await pipeline.consume(frame, context: ctx, accessibilityText: axText)
    } onFrameDropped: { [pipeline] _ in
      await pipeline.recordBackpressureDrop()
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
        Task { @MainActor [weak self] in
          guard let self else { return }
          let dir = await self.submitter.batchDirectoryURL()
          try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
      },
      onOpenDiagnostics: { [weak self] in
        Task { @MainActor in await self?.openDiagnosticsReport() }
      },
      onDeleteQueuedBatches: { [weak self] in
        Task { @MainActor in await self?.deleteQueuedBatches() }
      },
      onRefreshPermissions: { [weak self] in
        Task { @MainActor in self?.updateMenuStatus() }
      },
      onOpenScreenRecordingSettings: {
        Task { @MainActor in
          AppController.openSystemSettingsPane("Privacy_ScreenCapture")
        }
      },
      onOpenAccessibilitySettings: {
        Task { @MainActor in
          AppController.openSystemSettingsPane("Privacy_Accessibility")
        }
      },
      onRelaunch: {
        Task { @MainActor in
          AppController.relaunchApplication()
        }
      },
      onLaunchAtLoginToggle: { enabled in
        do {
          try LaunchAtLoginController.setEnabled(enabled)
        } catch {
          Log.app.error(
            "launch-at-login update failed: \(error.localizedDescription, privacy: .public)"
          )
        }
      },
      onQuit: {
        Task { @MainActor in NSApp.terminate(nil) }
      }
    )

    await registerWithChronicle(permissions: permissions)
    await pollForegroundPrivacyState()
    await reconcileCaptureState()

    scheduleFlushTimer()
    foregroundPrivacyTimer = Timer.scheduledTimer(
      withTimeInterval: max(1, min(2, config.idlePollSeconds)), repeats: true
    ) { [weak self] _ in
      Task { @MainActor in await self?.pollForegroundPrivacyState() }
    }
    idleTimer = Timer.scheduledTimer(
      withTimeInterval: max(1, config.idlePollSeconds), repeats: true
    ) { [weak self] _ in
      Task { @MainActor in await self?.pollIdleState() }
    }
    scheduleEventCaptureInfrastructure()
    captureHealthTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) {
      [weak self] _ in
      Task { @MainActor in await self?.pollCaptureHealth() }
    }
    if controlClient != nil {
      heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
        Task { @MainActor in await self?.sendHeartbeat() }
      }
    }

    Log.app.info(
      "agentd booted device=\(self.config.deviceId, privacy: .public) localOnly=\(self.config.localOnly, privacy: .public)"
    )
  }

  private func applyPause(_ paused: Bool) async {
    userPaused = paused
    await reconcileCaptureState()
  }

  private func pollForegroundPrivacyState() async {
    let next = ForegroundPrivacyPauseDetector.reason(
      context: WindowContextProbe.current(),
      config: config
    )
    guard next != foregroundPrivacyPauseReason else { return }
    foregroundPrivacyPauseReason = next
    if let next {
      Log.capture.notice(
        "foreground privacy pause engaged reason=\(next, privacy: .public); releasing capture streams"
      )
    } else {
      Log.capture.notice("foreground privacy pause cleared")
    }
    await reconcileCaptureState()
  }

  private func pollIdleState() async {
    guard !config.eventCaptureEnabled else { return }
    guard captureRunning else { return }
    let idleSeconds = CGEventSource.secondsSinceLastEventType(
      .combinedSessionState,
      eventType: CGEventType(rawValue: ~0)!
    )
    let shouldIdle = idleSeconds >= config.idleThresholdSeconds
    guard shouldIdle != idleMode else { return }

    idleMode = shouldIdle
    let fps = shouldIdle ? config.idleFps : config.captureFps
    await capture.updateFps(fps)
    Log.capture.info(
      "adaptive fps mode=\(shouldIdle ? "idle" : "active", privacy: .public) fps=\(fps, privacy: .public)"
    )
  }

  private func registerWithChronicle(permissions: PermissionSnapshot) async {
    guard let controlClient else {
      updateMenuStatus()
      return
    }
    do {
      let response = try await controlClient.register(
        makeRegisterRequest(permissions: permissions)
      )
      controlState.registered = true
      controlState.lastError = nil
      if let device = response.device {
        apply(device: device)
      }
      if let policy = response.policy {
        await apply(policy: policy)
      }
      Log.app.info("chronicle device registered")
    } catch {
      controlState.lastError = error.localizedDescription
      Log.app.error("chronicle register failed: \(error.localizedDescription, privacy: .public)")
    }
    updateMenuStatus()
  }

  private func sendHeartbeat() async {
    guard let controlClient else { return }
    do {
      let response = try await controlClient.heartbeat(await makeHeartbeatRequest())
      controlState.registered = true
      controlState.lastError = nil
      var devicePauseChanged = false
      if let device = response.device {
        devicePauseChanged = apply(device: device)
      }
      if let policy = response.policy {
        await apply(policy: policy)
      } else if devicePauseChanged {
        await reconcileCaptureState()
      }
    } catch {
      controlState.lastError = error.localizedDescription
      Log.app.warning("chronicle heartbeat failed: \(error.localizedDescription, privacy: .public)")
    }
    updateMenuStatus()
  }

  private func makeRegisterRequest(permissions: PermissionSnapshot) -> RegisterDeviceRequest {
    RegisterDeviceRequest(
      deviceId: config.deviceId,
      organizationId: config.organizationId,
      workspaceId: config.workspaceId,
      userId: config.userId,
      hostname: Host.current().localizedName ?? "unknown",
      appVersion: Bundle.main.appVersion,
      metadata: [
        "capture_state": captureRunning ? "capturing" : "stopped",
        "capture_all_displays": String(config.captureAllDisplays),
        "selected_display_ids": config.selectedDisplayIds.map(String.init).joined(separator: ","),
        "local_only": String(config.localOnly),
        "secret_broker_enabled": String(config.secretBroker != nil),
        "accessibility_trusted": String(permissions.accessibilityTrusted),
        "screen_capture_preflight": String(permissions.screenCaptureTrusted),
      ]
    )
  }

  private func makeHeartbeatRequest() async -> HeartbeatRequest {
    let pending = await pipeline.pendingStats()
    let local = await submitter.localBatchStats()
    let pauseState = effectivePauseState()
    return HeartbeatRequest(
      deviceId: config.deviceId,
      organizationId: config.organizationId,
      pendingFrameCount: pending.frameCount,
      pendingBytes: pending.estimatedBytes + local.bytes,
      paused: pauseState.paused,
      pauseReason: pauseState.reason
    )
  }

  @discardableResult
  private func apply(device: ChronicleDevice) -> Bool {
    controlState.apply(device: device)
  }

  private func apply(policy: CapturePolicy) async {
    if !policy.policyVersion.isEmpty {
      controlState.lastPolicyVersion = policy.policyVersion
    }
    if !policy.sourcePolicyRef.isEmpty {
      policySource = policy.sourcePolicyRef
    }
    scheduledPauseWindows = policy.scheduledPauseWindows
    if policy.captureMode == .paused {
      controlState.serverPaused = true
      controlState.serverPauseReason =
        policy.sourcePolicyRef.isEmpty
        ? "policy"
        : policy.sourcePolicyRef
    } else if controlState.serverPaused, policy.captureMode != .unspecified {
      controlState.serverPaused = false
      controlState.serverPauseReason = nil
    }

    let next = policyBaseConfig.applying(policy: policy)
    let intervalChanged = next.batchIntervalSeconds != config.batchIntervalSeconds
    let captureScopeChanged =
      next.captureAllDisplays != config.captureAllDisplays
      || next.selectedDisplayIds != config.selectedDisplayIds
    config = next
    eventCaptureScheduler.updateConfig(next)
    await pipeline.updateConfig(next)
    scheduleEventCaptureInfrastructure()
    if intervalChanged {
      scheduleFlushTimer()
    }
    if captureRunning, captureScopeChanged {
      await capture.stop()
      captureRunning = false
      idleMode = false
    }
    if captureRunning, !config.eventCaptureEnabled {
      await capture.updateFps(idleMode ? config.idleFps : config.captureFps)
    }
    await pollForegroundPrivacyState()
    await reconcileCaptureState()
  }

  private func reconcileCaptureState() async {
    let pauseState = effectivePauseState()
    let shouldPause = pauseState.paused
    if shouldPause, captureRunning {
      captureRetryTimer?.invalidate()
      captureRetryTimer = nil
      if config.eventCaptureEnabled {
        eventCaptureInFlight = false
      } else {
        await capture.stop()
      }
      captureHealthWatchdog.observeCaptureStopped()
      captureRunning = false
      idleMode = false
    } else if !shouldPause, !captureRunning {
      if config.eventCaptureEnabled {
        captureRunning = true
        captureHealthWatchdog.observeCaptureStopped()
        scheduleEventCaptureInfrastructure()
        schedulePauseWindowTimer()
        updateMenuStatus()
        return
      }
      do {
        try await capture.start(
          targetFps: config.captureFps,
          captureAllDisplays: config.captureAllDisplays,
          selectedDisplayIds: config.selectedDisplayIds
        )
        captureRunning = true
        captureHealthWatchdog.observeCaptureStarted()
        captureRetryTimer?.invalidate()
        captureRetryTimer = nil
      } catch {
        controlState.lastError = error.localizedDescription
        Log.app.error("capture start failed: \(error.localizedDescription, privacy: .public)")
        scheduleCaptureRetry()
      }
    }
    schedulePauseWindowTimer()
    updateMenuStatus()
  }

  private func pollCaptureHealth() async {
    let displayStats = await capture.displayStats()
    let staleAfter = max(30, config.batchIntervalSeconds * 2)
    guard
      let decision = captureHealthWatchdog.evaluate(
        captureRunning: captureRunning,
        eventCaptureEnabled: config.eventCaptureEnabled,
        displayStats: displayStats,
        staleAfterSeconds: staleAfter
      )
    else { return }

    captureHealthWatchdog.recordRestart(decision)
    Log.capture.error(
      "capture health restart display=\(decision.displayId.map(String.init) ?? "none", privacy: .public) reason=\(decision.reason, privacy: .public)"
    )
    await capture.stop()
    captureRunning = false
    idleMode = false
    await reconcileCaptureState()
  }

  private func scheduleCaptureRetry() {
    guard !config.eventCaptureEnabled else { return }
    guard captureRetryTimer == nil else { return }
    captureRetryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) {
      [weak self] _ in
      Task { @MainActor in
        self?.captureRetryTimer = nil
        await self?.reconcileCaptureState()
      }
    }
  }

  private func effectivePauseState(now: Date = Date()) -> EffectivePauseState {
    PauseStateResolver.resolve(
      userPaused: userPaused,
      scheduledWindows: scheduledPauseWindows,
      foregroundPrivacyReason: foregroundPrivacyPauseReason,
      policyPaused: controlState.serverPaused,
      policyReason: controlState.serverPauseReason,
      now: now
    )
  }

  private func schedulePauseWindowTimer(now: Date = Date()) {
    pauseWindowTimer?.invalidate()
    guard
      let transition = PauseStateResolver.nextTransition(
        after: now,
        scheduledWindows: scheduledPauseWindows
      )
    else {
      pauseWindowTimer = nil
      return
    }
    let interval = max(0.25, transition.timeIntervalSince(now) + 0.1)
    pauseWindowTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) {
      [weak self] _ in
      Task { @MainActor in await self?.reconcileCaptureState() }
    }
  }

  private func openDiagnosticsReport() async {
    let permissions = PermissionSnapshot.current(promptForAccessibility: false)
    let pending = await pipeline.pendingStats()
    let ocrCacheStats = await pipeline.ocrCacheStats()
    let textSourceStats = await pipeline.textSourceStats()
    let localStats = await submitter.localBatchStats()
    let localBatches = await submitter.localBatchSummaries()
    let lastSubmitResult = await submitter.lastSubmitResult()
    let captureDisplayStats = await capture.displayStats()
    let captureHealthStats = captureHealthWatchdog.stats()
    let snapshot = DiagnosticsSnapshot(
      generatedAt: Date(),
      appVersion: Bundle.main.appVersion,
      captureState: effectivePauseState().detail,
      permissions: permissions,
      config: config,
      policyVersion: controlState.lastPolicyVersion,
      policySource: policySource,
      controlError: controlState.lastError,
      pendingStats: pending,
      ocrCacheStats: ocrCacheStats,
      textSourceStats: textSourceStats,
      eventCaptureStats: eventCaptureScheduler.stats(),
      localBatchStats: localStats,
      localBatches: localBatches,
      captureDisplayStats: captureDisplayStats,
      captureHealthStats: captureHealthStats,
      lastSubmitResult: lastSubmitResult
    )
    do {
      let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".evalops/agentd/diagnostics")
      let report = try DiagnosticsReport.write(snapshot, directory: dir)
      NSWorkspace.shared.activateFileViewerSelecting([report])
    } catch {
      Log.app.error("diagnostics report failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func deleteQueuedBatches() async {
    let removed = await submitter.deleteLocalBatches()
    Log.submit.notice("deleted queued local batches count=\(removed, privacy: .public)")
    updateMenuStatus()
  }

  private func scheduleFlushTimer() {
    flushTimer?.invalidate()
    let interval = max(1, config.batchIntervalSeconds)
    let pipeline = pipeline
    let submitter = submitter
    flushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
      Task {
        await pipeline.flush()
        _ = await submitter.retryLocalBatches()
      }
    }
  }

  private func scheduleEventCaptureTimer() {
    eventCaptureTimer?.invalidate()
    guard config.eventCaptureEnabled else {
      eventCaptureTimer = nil
      return
    }
    eventCaptureTimer = Timer.scheduledTimer(
      withTimeInterval: max(0.1, config.eventCapturePollSeconds),
      repeats: true
    ) { [weak self] _ in
      Task { @MainActor in await self?.pollEventCaptureTriggers() }
    }
  }

  private func scheduleEventCaptureInfrastructure() {
    scheduleEventCaptureTimer()
    installNativeEventMonitors()
  }

  private func installNativeEventMonitors() {
    for monitor in eventMonitors {
      NSEvent.removeMonitor(monitor)
    }
    eventMonitors.removeAll()
    typingPauseTimer?.invalidate()
    typingPauseTimer = nil
    scrollStopTimer?.invalidate()
    scrollStopTimer = nil

    guard config.eventCaptureEnabled else { return }
    let clickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] _ in
      Task { @MainActor in await self?.requestEventCapture(.click) }
    }
    let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
      Task { @MainActor in self?.scheduleTypingPauseTrigger() }
    }
    let scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) {
      [weak self] _ in
      Task { @MainActor in self?.scheduleScrollStopTrigger() }
    }
    eventMonitors = [clickMonitor, keyMonitor, scrollMonitor].compactMap { $0 }
    if eventMonitors.count < 3 {
      Log.capture.warning(
        "native event capture monitors unavailable; polling triggers remain active")
    }
  }

  private func scheduleTypingPauseTrigger() {
    typingPauseTimer?.invalidate()
    typingPauseTimer = Timer.scheduledTimer(
      withTimeInterval: max(0.1, config.eventCaptureDebounceSeconds),
      repeats: false
    ) { [weak self] _ in
      Task { @MainActor in await self?.requestEventCapture(.typingPause) }
    }
  }

  private func scheduleScrollStopTrigger() {
    scrollStopTimer?.invalidate()
    scrollStopTimer = Timer.scheduledTimer(
      withTimeInterval: max(0.1, config.eventCaptureDebounceSeconds),
      repeats: false
    ) { [weak self] _ in
      Task { @MainActor in await self?.requestEventCapture(.scrollStop) }
    }
  }

  private func requestEventCapture(_ trigger: EventCaptureTrigger) async {
    guard captureRunning, config.eventCaptureEnabled, !effectivePauseState().paused else { return }
    guard let accepted = eventCaptureScheduler.request(trigger, now: Date()) else { return }
    await captureEvent(trigger: accepted)
  }

  private func pollEventCaptureTriggers() async {
    guard captureRunning, config.eventCaptureEnabled, !effectivePauseState().paused else { return }
    let triggers = eventCaptureScheduler.observe(
      context: WindowContextProbe.current(),
      clipboardChangeCount: NSPasteboard.general.changeCount,
      now: Date()
    )
    guard let trigger = triggers.first else { return }
    await captureEvent(trigger: trigger)
  }

  private func captureEvent(trigger: EventCaptureTrigger) async {
    guard !eventCaptureInFlight else { return }
    eventCaptureInFlight = true
    eventCaptureScheduler.recordCaptureStarted()
    do {
      let frame = try await CaptureService.captureOneFrame(
        targetFps: max(1, config.captureFps),
        captureAllDisplays: config.captureAllDisplays,
        selectedDisplayIds: config.selectedDisplayIds,
        timeoutSeconds: config.eventCaptureTimeoutSeconds,
        onFrameDropped: { [pipeline] _ in await pipeline.recordBackpressureDrop() }
      )
      let context = WindowContextProbe.current()
      let axText = AccessibilityTextExtractor.current(context: context)
      await pipeline.consume(frame, context: context, accessibilityText: axText)
      eventCaptureScheduler.recordCaptureSucceeded()
      Log.capture.info("event capture succeeded trigger=\(trigger.rawValue, privacy: .public)")
    } catch {
      eventCaptureScheduler.recordCaptureFailed()
      Log.capture.error(
        "event capture failed trigger=\(trigger.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
    }
    eventCaptureInFlight = false
    updateMenuStatus()
  }

  private func updateMenuStatus() {
    let detail: String
    let pauseState = effectivePauseState()
    if pauseState.paused {
      detail = pauseState.detail
    } else if captureRunning, config.eventCaptureEnabled {
      detail = controlState.registered ? "event capture armed, registered" : "event capture armed"
    } else if captureRunning {
      detail = controlState.registered ? "capturing, registered" : "capturing"
    } else if let error = controlState.lastError {
      detail = "stopped: \(error)"
    } else {
      detail = "stopped"
    }
    menuBar?.setStatus(
      paused: pauseState.paused || !captureRunning,
      detail: detail,
      permissions: PermissionSnapshot.current(promptForAccessibility: false),
      localOnly: config.localOnly,
      policyVersion: controlState.lastPolicyVersion
    )
  }

  private static func openSystemSettingsPane(_ pane: String) {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    else { return }
    NSWorkspace.shared.open(url)
  }

  private static func relaunchApplication() {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
      NSApp.terminate(nil)
      return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-n", Bundle.main.bundleURL.path]
    do {
      try process.run()
    } catch {
      Log.app.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
    }
    NSApp.terminate(nil)
  }
}

struct PermissionSnapshot: Sendable, Equatable, Codable {
  let accessibilityTrusted: Bool
  let screenCaptureTrusted: Bool

  var allTrusted: Bool {
    accessibilityTrusted && screenCaptureTrusted
  }

  var menuSummary: String {
    if allTrusted { return "Ready" }
    return "Needs \(missingPermissionNames.joined(separator: " + "))"
  }

  private var missingPermissionNames: [String] {
    var names: [String] = []
    if !screenCaptureTrusted {
      names.append("Screen Recording")
    }
    if !accessibilityTrusted {
      names.append("Accessibility")
    }
    return names
  }

  @MainActor
  static func current(promptForAccessibility: Bool) -> PermissionSnapshot {
    PermissionSnapshot(
      accessibilityTrusted: promptForAccessibility
        ? WindowContextProbe.axTrustedPrompt()
        : AXIsProcessTrusted(),
      screenCaptureTrusted: CGPreflightScreenCaptureAccess()
    )
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

if DiagnosticCLI.shouldHandle(CommandLine.arguments) {
  let code = await DiagnosticCLI.run(arguments: CommandLine.arguments)
  exit(code)
}

// Status-bar-only app — no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
