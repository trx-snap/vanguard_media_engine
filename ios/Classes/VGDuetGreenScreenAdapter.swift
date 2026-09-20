// VGDuetGreenScreenAdapter.swift
// VG-DUET-GREEN-SCREEN: Duet foreground-provider seam and the graph-backed
// GreenScreen foreground provider that is the current iOS Duet production path.
//
// Contents:
//   - VGDuetForegroundCompositeMode, VGDuetForegroundSample,
//     VGDuetForegroundProviderFault and the VGDuetForegroundProvider protocol are
//     what the Duet render loop and the Duet coordinator depend on.  The provider
//     decides per sample HOW its frame is composited (`compositeMode`); the
//     coordinator only owns layout geometry, the PiP fallback on fault, and event
//     emission.
//   - VGDuetGraphGreenScreenForegroundProvider is the production provider: a
//     graph-only VGCameraGraphSession running a VGGreenScreenFilterNode (alpha
//     output) delivers an already-keyed, straight-alpha BGRA frame per callback.
//     The old legacy matte adapter path (VanguardMLSegmenter/VanguardMaskStore
//     wrapped by a Duet-owned adapter) has been retired; this file no longer
//     contains it.
//
// `.straightAlpha` (VGDuetForegroundCompositeMode):
//   - `compositeMode` replaces "matte present, therefore keyed" as the keying
//     decision.  The render loop keys on the mode, never on raw matte presence.
//   - `.straightAlpha` lets a provider hand the render loop a frame that is ALREADY
//     keyed upstream (BGRA with straight, non-premultiplied alpha, no matte).  The
//     graph-backed provider emits it in production for GreenScreen.

import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import os.lock

// MARK: - Duet foreground-provider seam

/// How the Duet render loop must composite a foreground sample's `frame`.
/// Decided per sample by the provider, never by the layout mode and never by
/// raw matte presence (Phase 4B-A).
enum VGDuetForegroundCompositeMode {
    /// `frame` is opaque BGRA; composite it as the plain camera overlay.  Any
    /// `matte` the sample carries is released but never composited.
    case opaque
    /// `frame` is opaque BGRA and `matte` is its single-channel keying matte; use
    /// the matte-keyed CIBlendWithMask path.  A `.matteKeyed` sample whose `matte`
    /// is nil fails open to the `.opaque` overlay in the render loop.
    case matteKeyed
    /// `frame` was keyed upstream and already carries STRAIGHT (non-premultiplied)
    /// alpha in BGRA; source-over it onto the canvas.  No matte is used and no
    /// mask refinement runs.  The graph-backed provider emits this in production
    /// for GreenScreen.
    case straightAlpha
}

/// One foreground sample handed to the Duet render loop per render pass.
///
/// Ownership (CoreFoundation, not ARC): `frame` and `matte` each carry a +1
/// retain that the render loop MUST balance exactly once after compositing by
/// calling `release()`, whatever `compositeMode` says.  Keying is decided by
/// `compositeMode`, not by whether `matte` is nil: the provider decides how its
/// frame is composited; the layout mode never does.
struct VGDuetForegroundSample {
    /// +1 retained live foreground (camera) frame, BGRA.  Opaque for `.opaque`
    /// and `.matteKeyed`; straight-alpha for `.straightAlpha`.
    let frame: Unmanaged<CVPixelBuffer>
    /// +1 retained single-channel keying matte for `frame`.  Consulted only when
    /// `compositeMode == .matteKeyed`; otherwise carried for release only.
    let matte: Unmanaged<CVPixelBuffer>?
    /// How the render loop composites `frame` (see `VGDuetForegroundCompositeMode`).
    let compositeMode: VGDuetForegroundCompositeMode

    /// Balances both retains exactly once.  Call after compositing; any thread.
    /// Independent of `compositeMode`.
    func release() {
        frame.release()
        matte?.release()
    }
}

/// Metadata a provider attaches to a keying fault so the Duet coordinator can
/// emit its fallback event without hardcoding backend names or reasons.
struct VGDuetForegroundProviderFault {
    /// Backend that was keying before the fault (`previousBackend` on the wire).
    let previousBackend: String
    /// Machine-readable fault reason (`reason` on the wire).
    let reason: String
}

/// Foreground source for the Duet preview.  Owns the live camera frames and the
/// optional keyer, decides per sample how its frame is composited
/// (`VGDuetForegroundSample.compositeMode`), and reports keying faults.  The Duet
/// coordinator owns only layout geometry, the PiP fallback layout on fault, and
/// event emission.
///
/// Threading:
///   - `start`, `setKeyingEnabled`, `stop` and the `onFault` callback are main-thread.
///   - `sampleRetained()` may be called from the main thread or the render queue.
protocol VGDuetForegroundProvider: AnyObject {

    /// Called on the main thread after the provider has ALREADY turned keying off
    /// for the faulted keyer.  Fires at most once per keying activation.
    var onFault: ((VGDuetForegroundProviderFault) -> Void)? { get set }

    /// Bring up the foreground source.  When `keyingEnabled`, the keyer is started
    /// before the first camera frame is observed.  Idempotent; no-op after `stop()`.
    func start(keyingEnabled: Bool)

    /// Enable or disable keying without restarting the foreground source.
    /// Idempotent per state; no-op after `stop()`.
    func setKeyingEnabled(_ enabled: Bool)

    /// Terminal and idempotent.  Keying is turned off (keyer invalidated) BEFORE
    /// the camera stops, so no late frame is observed into an invalidated keyer.
    func stop()

    /// One +1 retained foreground sample, or nil when no camera frame has arrived
    /// yet.  The caller MUST call `release()` on a non-nil result exactly once and
    /// composite `frame` according to the sample's `compositeMode`.
    func sampleRetained() -> VGDuetForegroundSample?
}

// MARK: - VGDuetGraphGreenScreenForegroundProvider

/// Graph-backed provider: a graph-only `VGCameraGraphSession` running a
/// `VGGreenScreenFilterNode` (alpha output) delivers an ALREADY-keyed, straight-alpha
/// BGRA frame per callback — no `VanguardMLSegmenter` matte, no `VanguardMetalRenderer`,
/// no Flutter texture. Emits `.straightAlpha` while keying is enabled and `.opaque`
/// while it is not; `matte` is always nil (this provider never produces one).
///
/// Lifecycle (see `VGCameraGraphSession.h` / `VanguardCameraMediaSource.h` contracts):
///   - `start`: builds a front `VanguardCameraMediaSource` (30 fps), locks portrait,
///     then a graph-only
///     `VGCameraGraphSession(source:processedFrameReceiver:initialFilterSpecs:)` with
///     `initialFilterSpecs` set to the alpha greenScreen spec when `keyingEnabled`,
///     else nil. Session creation is all-or-nothing per attempt: a specs/resource
///     failure fails that attempt entirely (no graph, no camera start touched by
///     it). When `keyingEnabled` and the keyed attempt fails, this provider retries
///     once with an unkeyed graph (`initialFilterSpecs` nil) on the same source: a
///     keying fault means "not keyed", not "no foreground feed" (see `_fault()`).
///     `source`/`session` are stored, and `_keyingEnabled` set accordingly, only
///     after whichever attempt succeeds; if both attempts fail, `source`/`session`
///     are left nil. Session creation itself starts the scheduler, which starts the
///     underlying `AVCaptureSession` via the source's `startProducing` — this
///     provider does not call `source.start()` itself.
///   - `setKeyingEnabled`: hot-applies or clears the greenScreen spec on the live
///     graph via `setCameraFilterChainFromSpecs:`; never restarts the camera.
///   - `stop`: terminal and idempotent. Clears `onFault`, best-effort clears the
///     filter chain, invalidates the graph session (detaches its owned video
///     callback; per contract this does NOT stop the camera), THEN stops the
///     camera source, then releases the latest buffer.
///
/// Threading:
///   - `start`, `setKeyingEnabled`, `stop` and `onFault` are main-thread only.
///   - `onFrame(_:pts:)` / `setPreviewFPS(_:)` arrive on the graph execution queue
///     (`com.vanguard.cameraGraphExecution`) via `VGPlatformViewSinkAdapter`, at +0;
///     this provider retains before storing and releases the prior occupant outside
///     the lock.
///   - `sampleRetained()` is lock-guarded; callable from main or the render queue.
final class VGDuetGraphGreenScreenForegroundProvider: NSObject, VGDuetForegroundProvider, VanguardCameraFrameReceiver {

    /// `previousBackend` reported on fault.
    static let backendName = "cameraGraphGreenScreen"
    /// `reason` reported when graph creation or a keying-enable apply fails.
    static let faultReasonGraphUnavailable = "graph_green_screen_unavailable"

    /// Single-element spec array applying the alpha-output green screen filter
    /// (Dart contract: `VGFilterSpecs.greenScreenAlpha` — backgroundType "alpha"
    /// ignores argb entirely; see `VGCameraGraphSession.setCameraFilterChainFromSpecs:`).
    private static let greenScreenAlphaSpecs: [[String: Any]] = [
        ["type": "greenScreen", "enabled": true, "parameters": ["backgroundType": "alpha"]]
    ]

    var onFault: ((VGDuetForegroundProviderFault) -> Void)?

    /// Guards `_latestBuffer` and `_keyingEnabled` for the graph-queue `onFrame(_:pts:)`
    /// writer and the main/render-queue `sampleRetained()` reader.
    private var _lock = os_unfair_lock_s()
    private var _latestBuffer: CVPixelBuffer?
    private var _keyingEnabled = false

    /// Main-thread only. Non-nil exactly while a graph is live (between a
    /// successful `start()` and `stop()`).
    private var _source: VanguardCameraMediaSource?
    private var _session: VGCameraGraphSession?

    /// Main-thread lifecycle flags. `_stopped` is terminal.
    private var _started = false
    private var _stopped = false

    override init() {
        super.init()
    }

    // MARK: Lifecycle (main thread)

    func start(keyingEnabled: Bool) {
        assert(Thread.isMainThread)
        guard !_started, !_stopped else { return }
        _started = true

        let source = VanguardCameraMediaSource(position: .front, frameRate: 30)
        source.lockPreviewOrientationToPortrait()

        let initialSpecs: [[String: Any]]? = keyingEnabled ? Self.greenScreenAlphaSpecs : nil

        // Session construction is all-or-nothing per attempt: reaching the store
        // below means the requested initial filter chain (if any) is already
        // committed and the scheduler has already started the source.
        if let session = _makeSession(source: source, specs: initialSpecs, failureContext: "") {
            _source = source
            _session = session
            os_unfair_lock_lock(&_lock)
            _keyingEnabled = keyingEnabled
            os_unfair_lock_unlock(&_lock)
            return
        }

        guard keyingEnabled else {
            // Unkeyed (or disabled-keying) attempt failed outright; there is no
            // further fallback below unkeyed.
            _fault()
            return
        }

        // Keyed graph creation failed: a keying fault must mean "not keyed", not
        // "no foreground feed" (see `_fault()`). Retry once, unkeyed, on the same
        // source so the coordinator can fall back to PiP while the camera feed
        // continues.
        NSLog("[VGDuetGraphGreenScreenForegroundProvider] keyed graph failed; attempting unkeyed fallback")
        if let session = _makeSession(source: source, specs: nil, failureContext: " unkeyed fallback") {
            _source = source
            _session = session
            os_unfair_lock_lock(&_lock)
            _keyingEnabled = false
            os_unfair_lock_unlock(&_lock)
            _fault()
            return
        }

        // Both the keyed attempt and the unkeyed fallback failed: no live
        // source/session to store. `_fault()` reports the keying fault; there is
        // no session to clear a filter chain on and no source/session to stop
        // (provider.stop() only stops a source that was actually stored).
        os_unfair_lock_lock(&_lock)
        _keyingEnabled = false
        os_unfair_lock_unlock(&_lock)
        _fault()
    }

    /// Attempts one `VGCameraGraphSession` construction, logging and returning nil
    /// on failure. `failureContext` is prefixed into the log line to distinguish
    /// which attempt (keyed / unkeyed fallback) failed; leaving it "" preserves the
    /// original single-attempt log wording exactly.
    private func _makeSession(source: VanguardCameraMediaSource,
                               specs: [[String: Any]]?,
                               failureContext: String) -> VGCameraGraphSession? {
        do {
            return try VGCameraGraphSession(source: source,
                                             processedFrameReceiver: self,
                                             initialFilterSpecs: specs)
        } catch {
            NSLog("[VGDuetGraphGreenScreenForegroundProvider]\(failureContext) graph session creation failed: \(error)")
            return nil
        }
    }

    func setKeyingEnabled(_ enabled: Bool) {
        assert(Thread.isMainThread)
        guard !_stopped, let session = _session else { return }

        os_unfair_lock_lock(&_lock)
        let currentlyEnabled = _keyingEnabled
        os_unfair_lock_unlock(&_lock)
        guard currentlyEnabled != enabled else { return }

        do {
            try session.setCameraFilterChainFromSpecs(enabled ? Self.greenScreenAlphaSpecs : [])
            os_unfair_lock_lock(&_lock)
            _keyingEnabled = enabled
            os_unfair_lock_unlock(&_lock)
        } catch {
            NSLog("[VGDuetGraphGreenScreenForegroundProvider] setKeyingEnabled(\(enabled)) failed: \(error)")
            // Only an enable failure is a backend-unavailable fault; a disable
            // failure leaves the previous committed chain in place (the graph
            // never mutates on a rejected spec) and is not reported.
            if enabled {
                _fault()
            }
        }
    }

    func stop() {
        assert(Thread.isMainThread)
        guard !_stopped else { return }
        _stopped = true
        onFault = nil

        if let session = _session {
            // Best-effort keying-off before invalidation: keying off before
            // camera teardown.
            try? session.setCameraFilterChainFromSpecs([])
            // Detaches the graph-owned video callback; per contract this does
            // NOT stop the camera — the explicit source.stop() below does that.
            session.invalidate()
        }
        _session = nil

        _source?.stop()
        _source = nil

        os_unfair_lock_lock(&_lock)
        _keyingEnabled = false
        let old = _latestBuffer
        _latestBuffer = nil
        os_unfair_lock_unlock(&_lock)
        if let old = old {
            Unmanaged.passUnretained(old).release()
        }
    }

    // MARK: VanguardCameraFrameReceiver (graph execution queue)

    /// Delivered at +0 (`VGPlatformViewSinkAdapter` contract): retain before
    /// storing, then release the prior occupant outside the lock. No heavy work.
    @objc(onFrame:pts:) func onFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        _ = Unmanaged.passUnretained(pixelBuffer).retain()
        os_unfair_lock_lock(&_lock)
        let old = _latestBuffer
        _latestBuffer = pixelBuffer
        os_unfair_lock_unlock(&_lock)
        if let old = old {
            Unmanaged.passUnretained(old).release()
        }
    }

    /// No-op: this provider drives no MTKView / Flutter texture.
    @objc(setPreviewFPS:) func setPreviewFPS(_ fps: Int) {}

    // MARK: Sample (main thread or render queue)

    func sampleRetained() -> VGDuetForegroundSample? {
        os_unfair_lock_lock(&_lock)
        let buffer = _latestBuffer
        if let b = buffer { _ = Unmanaged.passUnretained(b).retain() }
        let keyingEnabled = _keyingEnabled
        os_unfair_lock_unlock(&_lock)
        guard let buffer = buffer else { return nil }
        return VGDuetForegroundSample(
            frame:         Unmanaged.passUnretained(buffer),
            matte:         nil,
            compositeMode: keyingEnabled ? .straightAlpha : .opaque)
    }

    // MARK: Private (main thread)

    /// Ensures `keyingEnabled` is false, best-effort clears the filter chain if
    /// a session is live, then reports the fault. Does NOT invalidate/stop the
    /// graph or camera — a fault means "not keyed", not "no foreground feed";
    /// the coordinator falls back to PiP layout while the (unkeyed) camera feed
    /// continues.
    private func _fault() {
        assert(Thread.isMainThread)
        os_unfair_lock_lock(&_lock)
        let wasKeyingEnabled = _keyingEnabled
        _keyingEnabled = false
        os_unfair_lock_unlock(&_lock)
        if wasKeyingEnabled, let session = _session {
            try? session.setCameraFilterChainFromSpecs([])
        }
        onFault?(VGDuetForegroundProviderFault(
            previousBackend: Self.backendName,
            reason:          Self.faultReasonGraphUnavailable))
    }
}
