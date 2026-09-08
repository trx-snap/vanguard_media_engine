// VGTimelineAudioMixControlHandler.swift
// vanguard_media_engine — V-B1/V-B2: Per-track live audio mix-gain control handler.
//
// Owns all parsing, stale-target checking, and runtime forwarding for the
// `timeline_setAudioMixGain` MethodChannel route.
//
// Architecture mirrors VGTimelineLiveControlHandler exactly:
//   - A timeline-specific error factory is defined here.
//   - VGTimelineAudioMixTarget is a lightweight value abstraction providing an
//     immutable textureId and a forward closure. The production adapter wraps
//     VanguardGraphRuntime. Test code can inject any conformer.
//   - The handler stores no per-track gain or lifecycle state.
//   - All FlutterResult deliveries happen exactly once on the main thread.
//   - Off-main invocations dispatch to the main thread exactly once.
//   - textureId is parsed as a strict non-negative signed 64-bit integer:
//     booleans, floating-point values, negatives, and overflow are all rejected.

import Flutter

// ─── Timeline-specific Flutter error factory ─────────────────────────────────

typealias VGTLAMFlutterErrorFactory = (
    _ code: String,
    _ message: String?,
    _ details: Any?
) -> Any

private let _vgtlamProductionErrorFactory: VGTLAMFlutterErrorFactory = { code, message, details in
    FlutterError(code: code, message: message, details: details)
}

// ─── Error code constants ─────────────────────────────────────────────────────

private let kErrInvalidArg    = "INVALID_ARG"
private let kErrStaleTimeline = "STALE_TIMELINE"

// ─── Lightweight target abstraction ─────────────────────────────────────────

/// A lightweight, immutable description of the currently active timeline target.
///
/// - `textureId`: the Flutter texture ID registered for this runtime instance.
/// - `setMixGain`: a closure that forwards a trackId + gain to the native
///   runtime's `setMixGainForTrackId(_:gain:)`.
struct VGTimelineAudioMixTarget {
    let textureId: Int64
    /// Forwards the gain update to the native runtime. Fire-and-forget on the
    /// native scheduler queue.
    let setMixGain: (_ trackId: String, _ gain: Float) -> Void
}

// ─── Production adapter ───────────────────────────────────────────────────────

/// Wraps a `VanguardGraphRuntime` in a `VGTimelineAudioMixTarget`.
func vgtlamProductionTarget(
    runtime: VanguardGraphRuntime
) -> VGTimelineAudioMixTarget {
    VGTimelineAudioMixTarget(
        textureId: runtime.textureId
    ) { trackId, gain in
        runtime.setMixGain(trackId: trackId, gain: gain)
    }
}

// ─── VGTimelineAudioMixControlHandler ────────────────────────────────────────

/// Handles the `timeline_setAudioMixGain` MethodChannel route.
///
/// The plugin retains one instance and provides a target provider closure that
/// resolves the runtime registered for the requested textureId at call time
/// (Phase 10F Slice 4A addressed routing). A nil target means the requested
/// session is not active and is reported as `STALE_TIMELINE`.
///
/// **Thread safety**: `handle(args:result:)` may be called from any thread.
/// If already on the main thread, it proceeds synchronously. If off main, it
/// dispatches once to `DispatchQueue.main`. All `result` invocations are
/// delivered exactly once on the main thread.
final class VGTimelineAudioMixControlHandler {

    // MARK: – Dependencies

    /// Resolves the timeline target for the requested textureId at call time.
    /// Returns `nil` when that session is not active (`STALE_TIMELINE`).
    private let targetProvider: (Int64) -> VGTimelineAudioMixTarget?

    /// Produces `FlutterError`-compatible values. Injected for testing.
    private let errorFactory: VGTLAMFlutterErrorFactory

    // MARK: – Init

    init(
        targetProvider: @escaping (Int64) -> VGTimelineAudioMixTarget?,
        errorFactory: @escaping VGTLAMFlutterErrorFactory = _vgtlamProductionErrorFactory
    ) {
        self.targetProvider = targetProvider
        self.errorFactory   = errorFactory
    }

    // MARK: – Public route handler

    /// Handles the `timeline_setAudioMixGain` call.
    ///
    /// Called by `VanguardMediaEnginePlugin.handle(_:result:)`.
    func handle(args: [String: Any]?, result: @escaping FlutterResult) {
        if Thread.isMainThread {
            _handleOnMain(args: args, result: result)
        } else {
            DispatchQueue.main.async { [self] in
                self._handleOnMain(args: args, result: result)
            }
        }
    }

    // MARK: – Private main-thread implementation

    private func _handleOnMain(args: [String: Any]?, result: @escaping FlutterResult) {
        assert(Thread.isMainThread,
               "VGTimelineAudioMixControlHandler: _handleOnMain must run on main thread")

        // ── 1. Parse textureId strictly ───────────────────────────────────────
        //
        // Replicates the strict integer parsing in VGTimelineLiveControlHandler:
        //   - Missing key or wrong container type → INVALID_ARG
        //   - Bool (NSNumber bridged from Bool) → INVALID_ARG
        //   - Floating-point NSNumber → INVALID_ARG
        //   - Negative or overflow → INVALID_ARG

        guard let rawTextureId = args?["textureId"] else {
            result(errorFactory(kErrInvalidArg,
                                "timeline_setAudioMixGain: missing textureId", nil))
            return
        }

        guard let number = rawTextureId as? NSNumber else {
            result(errorFactory(kErrInvalidArg,
                                "timeline_setAudioMixGain: textureId must be a number", nil))
            return
        }

        // Reject CFBoolean (Bool bridged as NSNumber).
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            result(errorFactory(kErrInvalidArg,
                                "timeline_setAudioMixGain: textureId must be an integer, got Bool", nil))
            return
        }

        // Reject floating-point NSNumber types.
        let cfType = CFNumberGetType(number as CFNumber)
        let isFloatingPoint = (cfType == .floatType || cfType == .doubleType ||
                               cfType == .float32Type || cfType == .float64Type ||
                               cfType == .cgFloatType)
        if isFloatingPoint {
            result(errorFactory(kErrInvalidArg,
                                "timeline_setAudioMixGain: textureId must be an integer, got floating-point", nil))
            return
        }

        // Overflow guard.
        let decimal = number.decimalValue
        let maxDecimal = Decimal(Int64.max)
        if decimal > maxDecimal || decimal < 0 {
            result(errorFactory(kErrInvalidArg,
                                "timeline_setAudioMixGain: textureId out of non-negative Int64 range", nil))
            return
        }

        let requestedTextureId = number.int64Value  // safe after all guards above

        if requestedTextureId < 0 {
            result(errorFactory(kErrInvalidArg,
                                "timeline_setAudioMixGain: textureId must be non-negative", nil))
            return
        }

        // ── 2. Parse trackId ──────────────────────────────────────────────────

        guard let trackId = args?["trackId"] as? String, !trackId.isEmpty else {
            result(errorFactory(kErrInvalidArg,
                                "timeline_setAudioMixGain: missing or empty trackId", nil))
            return
        }

        // ── 3. Parse gain ─────────────────────────────────────────────────────

        guard let gainNum = args?["gain"] as? NSNumber else {
            result(errorFactory(kErrInvalidArg,
                                "timeline_setAudioMixGain: gain must be a number", nil))
            return
        }
        let gain = Float(max(0.0, min(1.0, gainNum.doubleValue)))

        // ── 4. Resolve addressed target ───────────────────────────────────────
        //
        // Phase 10F Slice 4A: the provider resolves by requested textureId. A
        // nil result means the addressed session is not active — STALE_TIMELINE.

        guard let target = targetProvider(requestedTextureId) else {
            result(errorFactory(kErrStaleTimeline,
                                "timeline_setAudioMixGain: textureId \(requestedTextureId) " +
                                "is not an active timeline session", nil))
            return
        }

        // ── 5. Stale-target check (defensive; provider already matched) ───────

        guard target.textureId == requestedTextureId else {
            result(errorFactory(kErrStaleTimeline,
                                "timeline_setAudioMixGain: requested textureId \(requestedTextureId) " +
                                "does not match active target \(target.textureId)", nil))
            return
        }

        // ── 6. Forward to native runtime ──────────────────────────────────────

        target.setMixGain(trackId, gain)
        result(nil)
    }
}
