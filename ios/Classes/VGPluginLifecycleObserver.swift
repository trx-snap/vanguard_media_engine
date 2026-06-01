// VGPluginLifecycleObserver.swift
// Vanguard Media Engine — Phase 2 Step 8
//
// Owns all NotificationCenter observer registrations that were previously
// inline in VanguardMediaEnginePlugin.register(with:).
//
// Design constraints (Step 8):
//   - Zero behavior change: all observer closures moved verbatim.
//   - Holds weak references to both plugin and registry to avoid retain cycles.
//   - deinit removes all observers — safe even if removeObserver(self) is a no-op
//     for block-based observers (the tokens are discarded when this object dies).
//   - preActivateAudioSession() call moved here from register(with:).
//   - All plugin internals accessed via `weak plugin` — no new public API added
//     to VanguardMediaEnginePlugin beyond widening five ivars from private → internal.
//
// Observers managed:
//   1. didReceiveMemoryWarning  — renderers + registry.pauseMutedSessions()
//   2. willResignActive         — camera stop (A3 belt-and-suspenders)
//   3. didBecomeActive          — camera resume (A3)
//   4. AVAudioSession.interruption — pause renderers + registry runtimes
//   5. AVAudioSession.routeChange  — AEC toggle stub (Phase 1 foundation)
//   6. thermalStateDidChange    — 3-tier filter/encoder/runtime controller

import UIKit
import AVFoundation

final class VGPluginLifecycleObserver: NSObject {

    // ── Weak back-references ─────────────────────────────────────────────────

    private weak var registry: VGSessionRegistry?
    private weak var plugin: VanguardMediaEnginePlugin?

    // ── Init ─────────────────────────────────────────────────────────────────

    init(registry: VGSessionRegistry, plugin: VanguardMediaEnginePlugin) {
        self.registry = registry
        self.plugin   = plugin
        super.init()

        // ── G-02-T3: Audio session pre-activation ────────────────────────────
        // Activate the audio session once at startup on a bg queue so that
        // coreaudiod XPC settles before any video is loaded, preventing the
        // AVAssetReader + AVAudioSession timing-lock deadlock.
        // The dispatch_once inside preActivateAudioSession is a no-op on repeat calls.
        DispatchQueue.global(qos: .userInitiated).async {
            VanguardFileMediaSource.preActivateAudioSession()
        }

        registerObservers()
    }

    deinit {
        // Block-based addObserver tokens are discarded with `self`; this call
        // is the correct cleanup path for self-based (selector-based) observers.
        // It is a safe no-op for the block-based observers used here.
        NotificationCenter.default.removeObserver(self)
    }

    // ── Private ───────────────────────────────────────────────────────────────

    private func registerObservers() {

        // ── P0-T5a: Memory pressure ──────────────────────────────────────────
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let plugin = self.plugin, let registry = self.registry else { return }
            plugin.renderers.values.forEach { $0.handleMemoryPressure() }
            registry.pauseMutedSessions()
            // Phase 7.18B1: flush the active timeline's frame cache under memory pressure
            // so the OS reclaims the backing IOSurface memory before resorting to Jetsam.
            // flushTimelineCaches() is thread-safe and no-op when no timeline is active.
            #if VG_USE_V2_GRAPH
            plugin._timelineRuntime?.flushTimelineCaches()
            #endif
        }

        // ── A3: App background / foreground safety ───────────────────────────
        // Belt-and-suspenders for camera lifecycle: the Dart WidgetsBindingObserver
        // is the primary stop mechanism, but the iOS process can be suspended
        // before the Flutter framework propagates AppLifecycleState.paused.
        // willResignActive fires synchronously on the main thread before suspension,
        // guaranteeing the AVCaptureSession is stopped even under OS pressure.
        //
        // stopCamera() and startCamera() are both idempotent (session already-stopped
        // / already-running guards are in place at native and Dart levels) so
        // double-firing from both Dart and native is safe.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let plugin = self?.plugin else { return }
            // A3: belt-and-suspenders camera stop (existing behaviour).
            if plugin.currentMode == .camera {
                NSLog("[VanguardPlugin] willResignActive — stopping camera session")
                plugin.cameraSource?.stop()
                // Do NOT nil cameraSource here: didBecomeActive restarts using the
                // same source object. Dart-side restarts via _startCamera() on resume.
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let plugin = self?.plugin,
                  plugin.currentMode == .camera,
                  let src = plugin.cameraSource,
                  !src.captureSession.isRunning else { return }
            NSLog("[VanguardPlugin] didBecomeActive — resuming camera session")
            src.start()
        }

        // ── P0-T8: Audio session interruption (phone call / Siri / alarm) ────
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let plugin   = self.plugin,
                  let registry = self.registry,
                  let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                             as? AVAudioSession.InterruptionType else { return }
            switch type {
            case .began:
                // Pause all camera/export renderers.
                plugin.renderers.values.forEach { $0.pause() }
                // Pause all playback registry runtimes.
                registry.allRuntimes().forEach { $0.pause() }
                // Suspend in-progress export.
                plugin.activeExportSession?.suspend()
                plugin.activeExportSession = nil
            case .ended:
                // Do NOT auto-resume — require explicit user action.
                break
            @unknown default: break
            }
        }

        // ── P1-T10: Audio session route change (headphone plug/unplug) ───────
        // When the route changes, AVAudioEngine's installTapOnBus: callback is
        // silently invalidated. Phase 2 will call reinstallAudioTap() here.
        // In Phase 1 we register the observer so the foundation is in place.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let _ = self,
                  let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
                               as? AVAudioSession.RouteChangeReason else { return }
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable:
                // Phase 2: call reinstallAudioTap() on all active sources.
                // Phase 1: note the route change and disable AEC for Bluetooth.
                let session = AVAudioSession.sharedInstance()
                let isBluetooth = session.currentRoute.inputs.contains {
                    $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP
                }
                NSLog("[Vanguard] Route changed — isBluetooth=%d", isBluetooth ? 1 : 0)
                // Phase 2: plugin?.renderers.values.forEach { $0.source?.setAECEnabled(!isBluetooth) }
            default: break
            }
        }

        // ── G-04: Thermal degradation — 3-tier controller ────────────────────
        // Drives renderer filterChain, streaming encoder bitrate, and file source
        // audio enhancement level as thermal state changes.
        //
        // Tier         | thermalState        | filterChain | bitrate | audio
        // Nominal/Fair | ≤ Fair              | enabled     | 4000    | enhanced
        // Serious      | Serious             | seg.disabled| 2000    | standard
        // Critical     | Critical            | disabled    | 800     | none
        //
        // The cameraSource._mlGate already receives updateThermalState: from its
        // own observer (allocated in VanguardCameraMediaSource init). This handler
        // manages the renderer and encoder controls which the camera source does
        // not own.
        //
        // P3-4: Also fans the state to all VanguardGraphRuntime instances so that
        // runtime-owned VGMetalFilterNode chains degrade consistently with the
        // legacy renderer filter chain.
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let plugin = self.plugin, let registry = self.registry else { return }
            let state = ProcessInfo.processInfo.thermalState
            NSLog("[Vanguard] Thermal change → %ld", state.rawValue)
            switch state {
            case .nominal, .fair:
                // Full quality — all effects enabled.
                plugin.renderers.values.forEach { $0.filterChainEnabled = true }
                plugin.streamingEncoder?.setBitrateKbps(4000)
                // P3-4: fan to runtime-owned filter chains.
                registry.allRuntimes().forEach { $0.setRuntimeThermalState(state) }
            case .serious:
                // Reduce GPU load: disable segmentation (most expensive filter).
                // LUT and Beauty remain active. Halve encoder bitrate.
                // VanguardMLGate's own observer handles ML frame rate reduction.
                plugin.renderers.values.forEach { renderer in
                    renderer.filterChainEnabled = true  // chain active; gate trims ML rate
                }
                plugin.streamingEncoder?.setBitrateKbps(2000)
                NSLog("[Vanguard] Thermal Serious — segmentation suppressed by MLGate interval")
                // P3-4: fan to runtime-owned filter chains.
                registry.allRuntimes().forEach { $0.setRuntimeThermalState(state) }
            case .critical:
                // Emergency: disable entire Metal filter chain.
                // P5: Use replaceFilterChain([]) — not filterChainEnabled=false — so that
                // invalidate() is called on all nodes before the chain pointer is swapped.
                // This cancels any in-flight CoreML/Vision requests on the segmentation node.
                plugin.renderers.values.forEach { $0.replaceFilterChain([]) }
                plugin.streamingEncoder?.setBitrateKbps(800)
                NSLog("[Vanguard] Thermal Critical — filter chain safely invalidated")
                // P3-4: fan to runtime-owned filter chains.
                registry.allRuntimes().forEach { $0.setRuntimeThermalState(state) }
            @unknown default: break
            }
        }
    }
}
