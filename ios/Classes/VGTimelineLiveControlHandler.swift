// VGTimelineLiveControlHandler.swift
// vanguard_media_engine — Audio Track Interaction Programme S-P1
//
// Owns all parsing, dispatch, error creation, stale-target checking, and
// runtime adaptation for the `timeline_setFilterChain` MethodChannel route.
//
// Architecture:
//   - A timeline-specific error factory is defined here; no waveform code is
//     referenced.
//   - `VGTimelineLiveFilterTarget` is a lightweight value abstraction providing
//     an immutable textureId and an apply closure. The production adapter wraps
//     VanguardGraphRuntime. Test code can inject any conformer.
//   - The handler stores no filter-chain or lifecycle state.
//   - All FlutterResult deliveries happen exactly once on the main thread.
//   - Off-main invocations dispatch to the main thread exactly once.
//   - textureId is parsed as a strict non-negative signed 64-bit integer:
//     booleans, floating-point values, negatives, and overflow are all rejected.

import Flutter

// ─── Timeline-specific Flutter error factory ─────────────────────────────────
//
// Intentionally separate from VGWCFlutterErrorFactory (waveform handler).
// Do not reference or reuse that type here.

typealias VGTLCFlutterErrorFactory = (
    _ code: String,
    _ message: String?,
    _ details: Any?
) -> Any

private let _vgtlcProductionErrorFactory: VGTLCFlutterErrorFactory = { code, message, details in
    FlutterError(code: code, message: message, details: details)
}

// ─── Error code constants ─────────────────────────────────────────────────────

private let kErrInvalidArg    = "INVALID_ARG"
private let kErrNoTimeline    = "NO_TIMELINE"
private let kErrStaleTimeline = "STALE_TIMELINE"
private let kErrUnknownFilter = "UNKNOWN_FILTER"

// ─── Lightweight target abstraction ─────────────────────────────────────────
//
// Decouples the handler from VanguardGraphRuntime so the handler can be tested
// without injecting the concrete runtime.

/// A lightweight, immutable description of the currently active timeline target.
///
/// - `textureId`: the Flutter texture ID registered for this runtime instance.
/// - `apply`: a closure that forwards a filter-specs array to the native
///   runtime's `setFilterChain(fromSpecs:unknown:)` and returns `(applied, unknownType)`.
struct VGTimelineLiveFilterTarget {
    let textureId: Int64
    /// Calls the native runtime's filter-chain application method.
    /// Returns `(true, nil)` on full success, `(false, type)` on unknown type.
    let apply: (_ specs: [[String: Any]]) -> (applied: Bool, unknownType: String?)
}

// ─── Production adapter ───────────────────────────────────────────────────────

/// Wraps a `VanguardGraphRuntime` in a `VGTimelineLiveFilterTarget`.
///
/// The runtime's `setFilterChain(fromSpecs:unknown:)` is the sole authority
/// for filter-type validation and chain application. No allowlist is duplicated
/// in Swift.
func vgtlcProductionTarget(
    runtime: VanguardGraphRuntime
) -> VGTimelineLiveFilterTarget {
    VGTimelineLiveFilterTarget(
        textureId: runtime.textureId
    ) { specs in
        var unknownType: NSString? = nil
        let applied = runtime.setFilterChain(fromSpecs: specs, unknown: &unknownType)
        return (applied, unknownType as String?)
    }
}

// ─── VGTimelineLiveControlHandler ────────────────────────────────────────────

/// Handles the `timeline_setFilterChain` MethodChannel route.
///
/// The plugin retains one instance and provides a target provider closure that
/// resolves the current `_timelineRuntime` at call time.
///
/// **Thread safety**: `handle(call:args:result:)` may be called from any
/// thread. If already on the main thread, it proceeds synchronously. If off
/// main, it dispatches once to `DispatchQueue.main`. All `result` invocations
/// are delivered exactly once on the main thread.
final class VGTimelineLiveControlHandler {

    // MARK: – Dependencies

    /// Resolves the currently active timeline target at call time.
    /// Returns `nil` when no timeline is active (`NO_TIMELINE`).
    private let targetProvider: () -> VGTimelineLiveFilterTarget?

    /// Produces `FlutterError`-compatible values. Injected for testing.
    private let errorFactory: VGTLCFlutterErrorFactory

    // MARK: – Init

    /// Creates a handler.
    ///
    /// - Parameters:
    ///   - targetProvider: Called on the main thread at handle time to obtain
    ///     the current timeline target. Must be callable on the main thread.
    ///   - errorFactory: Produces `FlutterError`-compatible values.
    ///     Defaults to the production factory.
    init(
        targetProvider: @escaping () -> VGTimelineLiveFilterTarget?,
        errorFactory: @escaping VGTLCFlutterErrorFactory = _vgtlcProductionErrorFactory
    ) {
        self.targetProvider = targetProvider
        self.errorFactory   = errorFactory
    }

    // MARK: – Public route handler

    /// Handles the `timeline_setFilterChain` call.
    ///
    /// Called by `VanguardMediaEnginePlugin.handle(_:result:)`.
    ///
    /// - Parameters:
    ///   - args: The unpacked arguments dictionary from the MethodCall.
    ///   - result: The Flutter result callback; delivered exactly once on main.
    func handle(args: [String: Any]?, result: @escaping FlutterResult) {
        // Ensure main-thread execution — dispatch exactly once.
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
               "VGTimelineLiveControlHandler: _handleOnMain must run on main thread")

        // ── 1. Parse textureId strictly ───────────────────────────────────────
        //
        // Contract: non-negative signed 64-bit integer.
        //
        // Rejection rules (preserving native-runtime authority; no leniency):
        //   - Missing key or wrong container type → INVALID_ARG
        //   - Bool (NSNumber bridged from Bool) → INVALID_ARG
        //   - Floating-point (NSNumber bridged from Double/Float) → INVALID_ARG
        //   - Negative value → INVALID_ARG
        //   - Overflow (value > Int64.max) → INVALID_ARG
        //
        // NSNumber.int64Value is intentionally NOT used because it silently
        // truncates booleans (true→1, false→0) and floating-point values, and
        // wraps overflowing integers. Instead, CFNumber type inspection is used
        // to verify the stored numeric type before reading the value.

        guard let rawTextureId = args?["textureId"] else {
            result(errorFactory(kErrInvalidArg,
                                "timeline_setFilterChain: missing textureId", nil))
            return
        }

        // Reject Bool bridged as NSNumber (CFBooleanRef / kCFNumberCharType)
        if rawTextureId is Bool {
            result(errorFactory(kErrInvalidArg,
                                "timeline_setFilterChain: textureId must be an integer, got Bool", nil))
            return
        }

        guard let number = rawTextureId as? NSNumber else {
            result(errorFactory(kErrInvalidArg,
                                "timeline_setFilterChain: textureId must be a number", nil))
            return
        }

        // Reject floating-point NSNumber types (Double / Float).
        // CFNumberGetType returns the type used to store the value; comparing
        // against known integer types ensures we reject 1.0 passed as Double.
        let cfType = CFNumberGetType(number as CFNumber)
        let isFloatingPoint = (cfType == .floatType || cfType == .doubleType ||
                               cfType == .float32Type || cfType == .float64Type ||
                               cfType == .cgFloatType)
        if isFloatingPoint {
            result(errorFactory(kErrInvalidArg,
                                "timeline_setFilterChain: textureId must be an integer, got floating-point", nil))
            return
        }

        // Overflow guard: read as Decimal so values > Int64.max don't wrap.
        let decimal = number.decimalValue
        let maxDecimal = Decimal(Int64.max)
        if decimal > maxDecimal || decimal < 0 {
            result(errorFactory(kErrInvalidArg,
                                "timeline_setFilterChain: textureId out of non-negative Int64 range", nil))
            return
        }

        let requestedTextureId = number.int64Value  // safe after all guards above

        if requestedTextureId < 0 {
            // Defensive — already caught above, but belt-and-braces.
            result(errorFactory(kErrInvalidArg,
                                "timeline_setFilterChain: textureId must be non-negative", nil))
            return
        }

        // ── 2. Parse filters payload ──────────────────────────────────────────
        //
        // Must be an ordered array of dictionaries (may be empty to clear).

        guard let filterDicts = args?["filters"] as? [[String: Any]] else {
            result(errorFactory(kErrInvalidArg,
                                "timeline_setFilterChain: filters must be an ordered array of dicts", nil))
            return
        }

        // ── 3. Resolve active target ──────────────────────────────────────────

        guard let target = targetProvider() else {
            result(errorFactory(kErrNoTimeline,
                                "timeline_setFilterChain: no active timeline target", nil))
            return
        }

        // ── 4. Stale-target check ─────────────────────────────────────────────

        guard target.textureId == requestedTextureId else {
            result(errorFactory(kErrStaleTimeline,
                                "timeline_setFilterChain: requested textureId \(requestedTextureId) " +
                                "does not match active target \(target.textureId)", nil))
            return
        }

        // ── 5. Delegate to the native runtime (sole filter authority) ─────────
        //
        // Empty filterDicts clears the chain — this is intentional and must
        // reach the runtime unchanged.
        //
        // The runtime's setFilterChain(fromSpecs:unknown:) owns:
        //   - filter-type recognition (lut, beauty, segmentation)
        //   - node construction using the CVPixelBufferPool + MTLDevice
        //   - unknown-type reporting via the *unknown out-parameter

        let (applied, unknownType) = target.apply(filterDicts)

        if applied {
            result(nil)
        } else {
            let badType = unknownType ?? "(nil)"
            result(errorFactory(kErrUnknownFilter,
                                "timeline_setFilterChain: unrecognised filter type: \(badType)", nil))
        }
    }
}
