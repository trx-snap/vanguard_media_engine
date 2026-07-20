// VGPluginLifecycleObserver.swift
// Vanguard Media Engine — Phase 2 Step 8 / Audio Slice O
//
// Owns all NotificationCenter observer registrations that were previously
// inline in VanguardMediaEnginePlugin.register(with:).
//
// Design constraints:
//   - Holds weak references to both plugin and registry to avoid retain cycles.
//   - Holds a strong reference to audioLifecycleCoordinator (coordinator does
//     not retain the observer; no cycle).
//   - All block-based observer tokens are stored in `observerTokens: [NSObjectProtocol]`
//     and each token is individually removed in deinit via the injected center.
//   - Accepts an injected NotificationCenter (defaulting to .default) to allow
//     deterministic token-removal auditing in tests.
//   - Interruption type/options and route reason are parsed from their raw NSNumber
//     values before constructing Swift enums, avoiding bridging failures on
//     some SDK versions.
//   - Never modifies lifecycle policy, state transitions, or result mapping.
//
// Observers managed:
//   1. didReceiveMemoryWarning  — renderers + registry.pauseMutedSessions()
//   2. willResignActive         — camera stop (A3 belt-and-suspenders)
//   3. didBecomeActive          — (NEW ORDER) audio coordinator first, then camera
//   4. didEnterBackground       — NEW: audio lifecycle coordinator
//   5. AVAudioSession.interruption — renderers + registry + audio coordinator
//   6. AVAudioSession.routeChange  — Bluetooth diagnostic + audio coordinator
//   7. thermalStateDidChange    — 3-tier filter/encoder/runtime controller

import UIKit
import AVFoundation

final class VGPluginLifecycleObserver: NSObject {

    // ── Weak back-references ──────────────────────────────────────────────────

    private weak var registry: VGSessionRegistry?
    private weak var plugin: VanguardMediaEnginePlugin?

    // ── Strong audio lifecycle coordinator ───────────────────────────────────
    // Plugin → observer (strong) → coordinator
    // coordinator → handler (weak)
    // No cycle.

    #if VG_USE_V2_GRAPH
    private let audioLifecycleCoordinator: VGAudioLifecycleCoordinator
    #endif

    // ── Block-observer token storage ──────────────────────────────────────────
    // Every token returned by addObserver(forName:object:queue:using:) is stored
    // here and removed individually in deinit via the injected center.

    private var observerTokens: [NSObjectProtocol] = []

    // ── Injected NotificationCenter (default: .default) ───────────────────────
    // Inject a spy in tests to verify token add/remove counts without a
    // heavyweight abstraction.

    private let notificationCenter: NotificationCenter

    // ── Init ──────────────────────────────────────────────────────────────────

    #if VG_USE_V2_GRAPH
    init(registry: VGSessionRegistry,
         plugin: VanguardMediaEnginePlugin,
         audioLifecycleCoordinator: VGAudioLifecycleCoordinator,
         notificationCenter: NotificationCenter = .default) {
        self.registry                  = registry
        self.plugin                    = plugin
        self.audioLifecycleCoordinator = audioLifecycleCoordinator
        self.notificationCenter        = notificationCenter
        super.init()

        // ── G-02-T3: Audio session pre-activation ────────────────────────────
        DispatchQueue.global(qos: .userInitiated).async {
            VanguardFileMediaSource.preActivateAudioSession()
        }

        registerObservers()
    }
    #else
    init(registry: VGSessionRegistry,
         plugin: VanguardMediaEnginePlugin,
         notificationCenter: NotificationCenter = .default) {
        self.registry           = registry
        self.plugin             = plugin
        self.notificationCenter = notificationCenter
        super.init()

        DispatchQueue.global(qos: .userInitiated).async {
            VanguardFileMediaSource.preActivateAudioSession()
        }

        registerObservers()
    }
    #endif

    deinit {
        // Remove every stored block-based token individually.
        // This is the correct cleanup path — removeObserver(self) is a no-op
        // for block-based observers registered with addObserver(forName:...).
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
    }

    // ── Private ───────────────────────────────────────────────────────────────

    private func registerObservers() {

        // ── P0-T5a: Memory pressure ──────────────────────────────────────────
        let memToken = notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let plugin = self.plugin, let registry = self.registry else { return }
            plugin.renderers.values.forEach { $0.handleMemoryPressure() }
            registry.pauseMutedSessions()
            #if VG_USE_V2_GRAPH
            plugin._timelineRuntime?.flushTimelineCaches()
            #endif
            plugin.audioPlaybackService.stop()
        }
        observerTokens.append(memToken)

        // ── A3: willResignActive — camera stop ────────────────────────────────
        let resignToken = notificationCenter.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let plugin = self?.plugin else { return }
            if plugin.currentMode == .camera {
                NSLog("[VanguardPlugin] willResignActive — stopping camera session")
                plugin.cameraSource?.stop()
            }
        }
        observerTokens.append(resignToken)

        // ── A3/Slice O: didBecomeActive ───────────────────────────────────────
        // CRITICAL ORDER:
        //   1. Forward to audio lifecycle coordinator unconditionally.
        //   2. Then conditionally resume camera.
        // The camera guard must not suppress audio forwarding.
        let activeToken = notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            // 1. Audio lifecycle coordinator — unconditional.
            #if VG_USE_V2_GRAPH
            self.audioLifecycleCoordinator.didBecomeActive()
            #endif

            // 2. Camera resume — guarded by mode and session state.
            guard let plugin = self.plugin,
                  plugin.currentMode == .camera,
                  let src = plugin.cameraSource,
                  !src.captureSession.isRunning else { return }
            NSLog("[VanguardPlugin] didBecomeActive — resuming camera session")
            src.start()
        }
        observerTokens.append(activeToken)

        // ── Slice O: didEnterBackground ───────────────────────────────────────
        let bgToken = notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            #if VG_USE_V2_GRAPH
            self?.audioLifecycleCoordinator.didEnterBackground()
            #endif
        }
        observerTokens.append(bgToken)

        // ── P0-T8: Audio session interruption ─────────────────────────────────
        // Parse type from raw NSNumber to avoid SDK bridging failures.
        let interruptToken = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let plugin   = self.plugin,
                  let registry = self.registry else { return }

            // Raw-value extraction — do NOT cast directly to Swift enum.
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                                as? NSNumber else { return }
            guard let type = AVAudioSession.InterruptionType(rawValue: rawType.uintValue)
            else { return }

            switch type {
            case .began:
                // Existing: pause renderers, registry runtimes, export, standalone player.
                plugin.renderers.values.forEach { $0.pause() }
                registry.allRuntimes().forEach { $0.pause() }
                plugin.activeExportSession?.suspend()
                plugin.activeExportSession = nil
                plugin.audioPlaybackService.pause()

                // Slice O: audio lifecycle coordinator.
                #if VG_USE_V2_GRAPH
                self.audioLifecycleCoordinator.interruptionBegan()
                #endif

            case .ended:
                // Do NOT auto-resume renderers/playback — require explicit user action.
                // Slice O: audio lifecycle coordinator handles recovery.
                #if VG_USE_V2_GRAPH
                self.audioLifecycleCoordinator.interruptionEnded()
                #endif

            @unknown default: break
            }
        }
        observerTokens.append(interruptToken)

        // ── P1-T10 / Slice O: Audio session route change ──────────────────────
        // Forward .newDeviceAvailable and .oldDeviceUnavailable to the lifecycle
        // coordinator. Ignore .categoryChange (prevents recursive recovery).
        // Leave .routeConfigurationChange to the existing engine-config path.
        let routeToken = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            // Raw-value extraction — do NOT cast directly to Swift enum.
            guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
                                  as? NSNumber else { return }
            guard let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason.uintValue)
            else { return }

            // Existing Bluetooth diagnostic (all relevant reasons).
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable:
                let session = AVAudioSession.sharedInstance()
                let isBluetooth = session.currentRoute.inputs.contains {
                    $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP
                }
                NSLog("[Vanguard] Route changed (%lu) — isBluetooth=%d",
                      reason.rawValue, isBluetooth ? 1 : 0)
                // Forward to audio lifecycle coordinator.
                #if VG_USE_V2_GRAPH
                self?.audioLifecycleCoordinator.routeChanged(reason)
                #endif

            case .categoryChange:
                // Ignored: generated by session category transitions; forwarding
                // would cause recursive recovery.
                break

            default:
                break
            }
        }
        observerTokens.append(routeToken)

        // ── G-04: Thermal degradation — 3-tier controller ────────────────────
        let thermalToken = notificationCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let plugin = self.plugin, let registry = self.registry else { return }
            let state = ProcessInfo.processInfo.thermalState
            NSLog("[Vanguard] Thermal change → %ld", state.rawValue)
            switch state {
            case .nominal, .fair:
                plugin.renderers.values.forEach { $0.filterChainEnabled = true }
                plugin.streamingEncoder?.setBitrateKbps(4000)
                registry.allRuntimes().forEach { $0.setRuntimeThermalState(state) }
            case .serious:
                plugin.renderers.values.forEach { renderer in
                    renderer.filterChainEnabled = true
                }
                plugin.streamingEncoder?.setBitrateKbps(2000)
                NSLog("[Vanguard] Thermal Serious — segmentation suppressed by MLGate interval")
                registry.allRuntimes().forEach { $0.setRuntimeThermalState(state) }
            case .critical:
                plugin.renderers.values.forEach { $0.replaceFilterChain([]) }
                plugin.streamingEncoder?.setBitrateKbps(800)
                NSLog("[Vanguard] Thermal Critical — filter chain safely invalidated")
                registry.allRuntimes().forEach { $0.setRuntimeThermalState(state) }
            @unknown default: break
            }
            plugin.notifyThermalStateChanged(state)
        }
        observerTokens.append(thermalToken)
    }
}
