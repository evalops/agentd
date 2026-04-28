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
  private var capture: CaptureService!
  private var menuBar: MenuBarController!
  private var userPaused = false
  private var captureRunning = false
  private var controlState = ChronicleControlState()
  private var flushTimer: Timer?
  private var idleTimer: Timer?
  private var heartbeatTimer: Timer?
  private var idleMode = false

  init() {
    let cfg = ConfigStore.load()
    self.policyBaseConfig = cfg
    self.config = cfg

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
    let permissions = PermissionSnapshot.current(promptForAccessibility: true)
    if !permissions.accessibilityTrusted {
      Log.app.warning("Accessibility not granted yet — window-context will be empty until granted")
    }

    let pipeline = pipeline
    capture = CaptureService { [pipeline] frame in
      let ctx = await MainActor.run { WindowContextProbe.current() }
      await pipeline.consume(frame, context: ctx)
    } onFrameDropped: { [pipeline] in
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
        let dir = FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".evalops/agentd/batches")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
      },
      onQuit: {
        Task { @MainActor in NSApp.terminate(nil) }
      }
    )

    await registerWithChronicle(permissions: permissions)
    await reconcileCaptureState()

    scheduleFlushTimer()
    idleTimer = Timer.scheduledTimer(
      withTimeInterval: max(1, config.idlePollSeconds), repeats: true
    ) { [weak self] _ in
      Task { @MainActor in await self?.pollIdleState() }
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

  private func pollIdleState() async {
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
    return HeartbeatRequest(
      deviceId: config.deviceId,
      organizationId: config.organizationId,
      pendingFrameCount: pending.frameCount + local.fileCount,
      pendingBytes: pending.estimatedBytes + local.bytes
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
    config = next
    await pipeline.updateConfig(next)
    if intervalChanged {
      scheduleFlushTimer()
    }
    if captureRunning {
      await capture.updateFps(idleMode ? config.idleFps : config.captureFps)
    }
    await reconcileCaptureState()
    updateMenuStatus()
  }

  private func reconcileCaptureState() async {
    let shouldPause = userPaused || controlState.serverPaused
    if shouldPause, captureRunning {
      await capture.stop()
      captureRunning = false
      idleMode = false
    } else if !shouldPause, !captureRunning {
      do {
        try await capture.start(targetFps: config.captureFps)
        captureRunning = true
      } catch {
        controlState.lastError = error.localizedDescription
        Log.app.error("capture start failed: \(error.localizedDescription, privacy: .public)")
      }
    }
    updateMenuStatus()
  }

  private func scheduleFlushTimer() {
    flushTimer?.invalidate()
    let interval = max(1, config.batchIntervalSeconds)
    let pipeline = pipeline
    flushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
      Task { await pipeline.flush() }
    }
  }

  private func updateMenuStatus() {
    let detail: String
    if userPaused {
      detail = "paused by user"
    } else if controlState.serverPaused {
      detail = "paused by policy"
    } else if captureRunning {
      detail = controlState.registered ? "capturing, registered" : "capturing"
    } else if let error = controlState.lastError {
      detail = "stopped: \(error)"
    } else {
      detail = "stopped"
    }
    menuBar?.setStatus(
      paused: userPaused || controlState.serverPaused || !captureRunning,
      detail: detail,
      localOnly: config.localOnly,
      policyVersion: controlState.lastPolicyVersion
    )
  }
}

struct PermissionSnapshot: Sendable, Equatable {
  let accessibilityTrusted: Bool
  let screenCaptureTrusted: Bool

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

// Status-bar-only app — no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
