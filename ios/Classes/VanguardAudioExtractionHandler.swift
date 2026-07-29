// VanguardAudioExtractionHandler.swift
// vanguard_media_engine — Phase 10-C Slice T Gate 6A
//
// Managed audio extraction handler.
//
// Owns:
//   - A private serial state queue for all registry mutations.
//   - A registry of active audio-extraction exporter abstractions keyed by operationId.
//   - A bounded recent-terminal set for distinguishing alreadyTerminal vs notFound.
//   - Terminal/cancellation bookkeeping to prevent double-completion.
//
// VanguardMediaEnginePlugin holds one instance of this handler and routes only:
//   beginAudioExtraction   → handler.handleBegin(args:result:)
//   cancelAudioExtraction  → handler.handleCancel(args:result:)
//
// No extraction state or policy lives in the plugin.
//
// Quiescence contract (RR-189 / Slice T):
//   - Terminal completion fires exactly once per operation.
//   - cancellationCompleted is returned ONLY from the exporter completion path,
//     after reader and writer are both terminal and no future write is possible.
//     Calling cancel() on the exporter merely requests cancellation — the result
//     is deferred to the terminal completion block.
//   - All pending cancelAudioExtraction FlutterResults are stored on the registry
//     entry and flushed exactly once when terminal completion fires.
//   - Multiple/racing cancel calls are all enqueued; exactly one flush occurs.
//   - If the exporter is already isFinished when cancel arrives, alreadyTerminal
//     is returned immediately without queueing a waiter.
//   - Terminal-race semantics: an accepted cancel resolves cancellationCompleted
//     after quiescence. The begin result retains its actual terminal outcome
//     (success, failure, or cancelled) — these are independent events. A racing
//     success or failure completion does not prevent cancellationCompleted, and
//     cancellationCompleted does not guarantee the begin result is cancelled.
//   - Cancel after terminal returns alreadyTerminal; unknown ID returns notFound.
//   - File-preservation invariant: native may remove its own partial output
//     while quiescing after cancelWriting. Dart must perform an authoritative
//     idempotent cancelReservation after receiving any cancel acknowledgement.
//
// Trim validation:
//   - Both start and end must be finite (not NaN, not ±Inf).
//   - start must be >= 0.
//   - If both are present, end must be > start.
//   - end-only trim is supported as [0, end).
//
// Error mapping:
//   - ReaderSetup(7) / ReaderStart(9) / runtime reader failure → readFailure
//   - WriterSetup(8) / WriterStart(10) / WriterFailed(11) / OutputMissing(12) → writeFailure
//
// Modularity:
//   - This handler owns registry and lifecycle.
//   - VGAudioOnlyExporter owns AVAssetReader/Writer execution and quiescence.
//   - Plugin remains a thin router.

import Flutter
import AVFoundation

// MARK: - Testability seam: exporter protocol, production adapter, factory

/// Internal protocol that abstracts VGAudioOnlyExporter for native unit tests.
/// Defines startWithCompletion as the internal seam name; the production adapter
/// delegates to the Swift-imported start(completion:) API. Only the three
/// operations required by the handler are surfaced.
internal protocol _VGAudioExporterProtocol: AnyObject {
    /// True once the export pipeline has reached a terminal state (success,
    /// failure, or cancellation). Mirrors VGAudioOnlyExporter.isFinished.
    var isFinished: Bool { get }

    /// Begins the export. The completion block receives the manifest on success
    /// or a non-nil error on failure/cancellation — exactly matching the
    /// production VGAudioOnlyExporter completion shape.
    func startWithCompletion(
        _ completion: @escaping (VGAudioExportManifest?, Error?) -> Void
    )

    /// Requests cancellation of the running export pipeline. Does not resolve
    /// the begin result; resolution happens from the terminal completion block.
    func cancel()
}

/// Private production adapter that owns one concrete VGAudioOnlyExporter and
/// forwards the three protocol operations to it.
private final class _VGAudioExporterAdapter: _VGAudioExporterProtocol {

    private let _exporter: VGAudioOnlyExporter

    init(exporter: VGAudioOnlyExporter) {
        _exporter = exporter
    }

    var isFinished: Bool { _exporter.isFinished }

    func startWithCompletion(
        _ completion: @escaping (VGAudioExportManifest?, Error?) -> Void
    ) {
        _exporter.start(completion: completion)
    }

    func cancel() {
        _exporter.cancel()
    }
}

/// Internal factory type used by the handler to create exporter instances.
/// Accepting this type through the internal initializer lets @testable native
/// tests substitute a fake factory without exposing any mutable property.
internal final class _VGAudioExporterFactory {

    /// Creates an exporter for the given asset, profile, output URL, and
    /// optional trim range. The production implementation returns a
    /// _VGAudioExporterAdapter wrapping a concrete VGAudioOnlyExporter.
    let make: (
        AVAsset,
        VGAudioExportProfile,
        URL,
        CMTimeRange?
    ) -> any _VGAudioExporterProtocol

    init(
        make: @escaping (AVAsset, VGAudioExportProfile, URL, CMTimeRange?) -> any _VGAudioExporterProtocol
    ) {
        self.make = make
    }
}

/// The production exporter factory. Creates a concrete VGAudioOnlyExporter
/// wrapped in the private adapter.
private func _makeProductionFactory() -> _VGAudioExporterFactory {
    _VGAudioExporterFactory { asset, profile, outputURL, trimRange in
        let concreteExporter: VGAudioOnlyExporter
        if let range = trimRange {
            concreteExporter = VGAudioOnlyExporter(
                asset: asset,
                profile: profile,
                outputURL: outputURL,
                trimRange: range
            )
        } else {
            concreteExporter = VGAudioOnlyExporter(
                asset: asset,
                profile: profile,
                outputURL: outputURL
            )
        }
        return _VGAudioExporterAdapter(exporter: concreteExporter)
    }
}

/// Internal factory type returning `Any` for FlutterError test seam.
internal typealias VGAEFlutterErrorFactory = (_ code: String, _ message: String?, _ details: Any?) -> Any

private let _productionFlutterErrorFactory: VGAEFlutterErrorFactory = { code, message, details in
    FlutterError(code: code, message: message, details: details)
}

// MARK: - VanguardAudioExtractionHandler

final class VanguardAudioExtractionHandler {

    // ── Serial state queue ────────────────────────────────────────────────────
    //
    // All reads and mutations of _registry and _recentTerminals happen on this
    // queue. VGAudioOnlyExporter completion callbacks are bridged onto this
    // queue before touching shared state. Completion back to Flutter fires on
    // the main thread.

    private let _stateQueue = DispatchQueue(
        label: "com.vanguard.extraction.handler.state",
        qos: .userInitiated
    )

    // ── Exporter factory ──────────────────────────────────────────────────────
    //
    // Immutably retained. The production initializer installs the concrete
    // adapter factory. The internal initializer accepts a substitute for tests.

    private let _exporterFactory: _VGAudioExporterFactory
    private let _flutterErrorFactory: VGAEFlutterErrorFactory

    // ── Operation registry ────────────────────────────────────────────────────

    private struct _ExtractionEntry {
        let exporter:    any _VGAudioExporterProtocol
        let outputPath:  String          // retained so success result has the path
        let beginResult: FlutterResult
        var beginFired:  Bool = false    // guard: fires exactly once

        // Pending cancel FlutterResults, stored until terminal completion fires.
        // All are resolved simultaneously from _handleExporterCompletion.
        var pendingCancelResults: [FlutterResult] = []
    }

    /// Active operations. Mutations serialized on _stateQueue.
    private var _registry: [String: _ExtractionEntry] = [:]

    // ── Recent-terminal bookkeeping ────────────────────────────────────────────
    //
    // Bounded FIFO of operation IDs that have reached a terminal state. Used to
    // distinguish:
    //   cancel(knownTerminalId)  → alreadyTerminal
    //   cancel(unknownId)         → notFound
    //
    // Capped at 256 entries; oldest entry dropped when cap is reached.

    private var _recentTerminals: [String] = []
    private let _terminalCap = 256

    // MARK: - Initializers

    /// Production entry point. Uses the concrete VGAudioOnlyExporter pipeline.
    /// Unchanged from the pre-seam public surface.
    init() {
        _exporterFactory = _makeProductionFactory()
        _flutterErrorFactory = _productionFlutterErrorFactory
    }

    /// Internal initializer for @testable native tests. Accepts a substitute
    /// factory and error factory so tests can inject fakes without any mutable properties.
    internal init(
        exporterFactory: _VGAudioExporterFactory,
        flutterErrorFactory: @escaping VGAEFlutterErrorFactory
    ) {
        _exporterFactory = exporterFactory
        _flutterErrorFactory = flutterErrorFactory
    }

    // MARK: - Public API

    /// Handles the `beginAudioExtraction` MethodChannel call.
    ///
    /// Validates args, builds the exporter, registers the operation, and starts
    /// the export. Calls result() exactly once via the terminal completion block.
    func handleBegin(args: [String: Any]?, result: @escaping FlutterResult) {

        // ── Argument validation (on calling thread / main thread) ─────────────

        guard let operationId = args?["operationId"] as? String, !operationId.isEmpty else {
            result(_flutterErrorFactory("invalidArgument",
                                        "operationId is required and must be non-empty",
                                        nil))
            return
        }
        guard let sourcePath = args?["sourcePath"] as? String, !sourcePath.isEmpty else {
            result(_flutterErrorFactory("invalidArgument",
                                        "sourcePath is required and must be non-empty",
                                        nil))
            return
        }
        guard let outputPath = args?["outputPath"] as? String, !outputPath.isEmpty else {
            result(_flutterErrorFactory("invalidArgument",
                                        "outputPath is required and must be non-empty",
                                        nil))
            return
        }

        // ── Trim validation ───────────────────────────────────────────────────
        // Both bounds must be finite (not NaN, not ±Inf). start >= 0.
        // end-only trim is supported as [0, end). If both present, end > start.

        let trimStartSeconds = args?["trimStartSeconds"] as? Double
        let trimEndSeconds   = args?["trimEndSeconds"]   as? Double

        if let start = trimStartSeconds {
            guard start.isFinite else {
                result(_flutterErrorFactory("invalidArgument",
                                            "trimStartSeconds must be a finite number",
                                            nil))
                return
            }
            guard start >= 0 else {
                result(_flutterErrorFactory("invalidArgument",
                                            "trimStartSeconds must be >= 0",
                                            nil))
                return
            }
        }

        if let end = trimEndSeconds {
            guard end.isFinite else {
                result(_flutterErrorFactory("invalidArgument",
                                            "trimEndSeconds must be a finite number",
                                            nil))
                return
            }
            guard end > 0 else {
                result(_flutterErrorFactory("invalidArgument",
                                            "trimEndSeconds must be > 0",
                                            nil))
                return
            }
            // When both are present, end must be strictly greater than start.
            let effectiveStart = trimStartSeconds ?? 0.0
            guard end > effectiveStart else {
                result(_flutterErrorFactory("invalidArgument",
                                            "trimEndSeconds must be > trimStartSeconds",
                                            nil))
                return
            }
        }

        // ── Duplicate-ID check + registration (serialized on state queue) ─────

        _stateQueue.async { [weak self] in
            guard let self = self else { return }

            if self._registry[operationId] != nil {
                DispatchQueue.main.async {
                    result(self._flutterErrorFactory("operationAlreadyExists",
                                                     "An active operation with id '\(operationId)' already exists",
                                                     nil))
                }
                return
            }

            // ── Build asset and profile ───────────────────────────────────────

            let sourceURL = URL(fileURLWithPath: sourcePath)
            let asset     = AVURLAsset(url: sourceURL,
                                       options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

            // Use the factory default M4A/AAC profile — codec selection is not
            // exposed in this batch.
            let profile   = VGAudioExportProfile.m4aDefault()
            let outputURL = URL(fileURLWithPath: outputPath)

            // ── Build CMTimeRange if trim bounds provided ──────────────────────
            // end-only: effectiveStart = 0; start-only: range = [start, +∞).
            // Both present: range = [start, end).

            let trimRange: CMTimeRange? = {
                guard trimStartSeconds != nil || trimEndSeconds != nil else { return nil }
                let effectiveStart = trimStartSeconds ?? 0.0
                let startCM = CMTimeMakeWithSeconds(effectiveStart, preferredTimescale: 44100)
                if let end = trimEndSeconds {
                    let endCM = CMTimeMakeWithSeconds(end, preferredTimescale: 44100)
                    return CMTimeRangeFromTimeToTime(start: startCM, end: endCM)
                }
                // start only — reader will run to end of asset.
                return CMTimeRangeMake(start: startCM, duration: CMTime.positiveInfinity)
            }()

            // ── Create exporter via injected factory ──────────────────────────

            let exporter = self._exporterFactory.make(asset, profile, outputURL, trimRange)

            // ── Register entry BEFORE starting ────────────────────────────────
            // Ensures a racing cancelAudioExtraction sees the entry and can
            // enqueue its FlutterResult before terminal completion fires.

            let entry = _ExtractionEntry(exporter: exporter,
                                         outputPath: outputPath,
                                         beginResult: result)
            self._registry[operationId] = entry

            // ── Start exporter ────────────────────────────────────────────────

            exporter.startWithCompletion { [weak self] manifest, error in
                // Completion fires on VGAudioOnlyExporter's private serial queue.
                // Bridge onto our state queue before touching shared state.
                self?._stateQueue.async {
                    self?._handleExporterCompletion(
                        operationId: operationId,
                        manifest: manifest,
                        error: error
                    )
                }
            }
        }
    }

    /// Handles the `cancelAudioExtraction` MethodChannel call.
    ///
    /// Does NOT return cancellationCompleted immediately. Instead, it stores
    /// the FlutterResult on the registry entry and flushes all pending cancel
    /// results from the terminal completion path, after quiescence. This
    /// ensures cancellationCompleted is returned only after reader and writer
    /// are both fully terminal.
    func handleCancel(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let operationId = args?["operationId"] as? String, !operationId.isEmpty else {
            result(_flutterErrorFactory("invalidArgument",
                                        "operationId is required and must be non-empty",
                                        nil))
            return
        }

        _stateQueue.async { [weak self] in
            guard let self = self else { return }

            if var entry = self._registry[operationId] {
                // ── isFinished guard ──────────────────────────────────────────
                // If the exporter has already reached a terminal state but
                // _handleExporterCompletion has not yet run (completion is
                // still bridging onto _stateQueue), treat it as alreadyTerminal
                // so we do not queue a waiter that will never be flushed.
                if entry.exporter.isFinished {
                    DispatchQueue.main.async {
                        result(["disposition": "alreadyTerminal"])
                    }
                    return
                }

                // ── Append waiter and persist BEFORE requesting cancel ────────
                // Persisting before cancel() ensures that if the exporter fires
                // its completion synchronously (or nearly so) on another thread,
                // _handleExporterCompletion sees the waiter in the registry.
                entry.pendingCancelResults.append(result)
                self._registry[operationId] = entry

                // Request cancellation AFTER the entry is persisted.
                // Do NOT resolve result here — cancellationCompleted is sent
                // only from _handleExporterCompletion after quiescence.
                entry.exporter.cancel()
            } else if self._recentTerminals.contains(operationId) {
                DispatchQueue.main.async {
                    result(["disposition": "alreadyTerminal"])
                }
            } else {
                DispatchQueue.main.async {
                    result(["disposition": "notFound"])
                }
            }
        }
    }

    // MARK: - Private: exporter completion (called on _stateQueue)

    /// Resolves the begin FlutterResult exactly once, flushes all pending
    /// cancel FlutterResults with cancellationCompleted, and updates bookkeeping.
    private func _handleExporterCompletion(
        operationId: String,
        manifest: VGAudioExportManifest?,
        error: Error?
    ) {
        guard var entry = _registry[operationId] else {
            // Entry was already removed. Defensive guard — should not occur.
            return
        }
        guard !entry.beginFired else { return }
        entry.beginFired = true
        _registry[operationId] = entry   // persist fired flag before removal

        // Move from active registry → recent-terminal set.
        let pendingCancels = entry.pendingCancelResults
        _registry.removeValue(forKey: operationId)
        _recordTerminal(operationId: operationId)

        let capturedBeginResult = entry.beginResult
        let capturedPath        = entry.outputPath

        // ── Flush all pending cancel FlutterResults (cancellationCompleted) ───
        // These are resolved here, after quiescence, regardless of whether
        // the operation succeeded or was truly cancelled. If the begin result
        // also fires success/failure, that is not contradictory — the cancel
        // result only acknowledges that the cancel request was processed and
        // the pipeline is now terminal.
        if !pendingCancels.isEmpty {
            DispatchQueue.main.async {
                for cancelResult in pendingCancels {
                    cancelResult(["disposition": "cancellationCompleted"])
                }
            }
        }

        // ── Resolve begin FlutterResult ───────────────────────────────────────
        if manifest != nil {
            // Success — return the output path retained from begin args.
            // VGAudioExportManifest does not carry the output URL itself.
            let map: [String: Any] = ["outputPath": capturedPath]
            DispatchQueue.main.async { capturedBeginResult(map) }
        } else if let nsError = error as NSError? {
            let code = _mapExporterError(nsError)
            DispatchQueue.main.async {
                capturedBeginResult(self._flutterErrorFactory(code,
                                                              nsError.localizedDescription,
                                                              nil))
            }
        } else {
            DispatchQueue.main.async {
                capturedBeginResult(self._flutterErrorFactory("internalFailure",
                                                              "Exporter completed with no manifest and no error",
                                                              nil))
            }
        }
    }

    // MARK: - Private: recent-terminal bookkeeping

    private func _recordTerminal(operationId: String) {
        if _recentTerminals.count >= _terminalCap {
            _recentTerminals.removeFirst()
        }
        _recentTerminals.append(operationId)
    }

    // MARK: - Private: error code mapping

    /// Maps VGAudioOnlyExporterErrorCode integer to a normalized Dart error code
    /// string. Never exposes raw platform error strings or domain names publicly.
    ///
    /// Mapping:
    ///   invalidArgument:  InvalidSource(1), InvalidOutputURL(2), InvalidProfile(3),
    ///                     UnsupportedCodec(5), UnsupportedFormat(6)
    ///   noAudioTrack:     NoAudioTrack(4)
    ///   readFailure:      ReaderSetup(7), ReaderStart(9)
    ///   writeFailure:     WriterSetup(8), WriterStart(10), WriterFailed(11),
    ///                     OutputMissing(12)
    ///   cancelled:        Cancelled(13)
    ///   internalFailure:  any unknown code or unknown domain
    private func _mapExporterError(_ error: NSError) -> String {
        guard error.domain == VGAudioOnlyExporterErrorDomain else {
            return "internalFailure"
        }
        switch VGAudioOnlyExporterErrorCode(rawValue: error.code) {
        case .invalidSource, .invalidOutputURL, .invalidProfile,
             .unsupportedCodec, .unsupportedFormat:
            return "invalidArgument"
        case .noAudioTrack:
            return "noAudioTrack"
        case .readerSetup, .readerStart:
            // Reader setup and reader startup failures.
            return "readFailure"
        case .readerRuntimeFailure:
            // Runtime reader failure during the sample pump.
            return "readFailure"
        case .writerSetup, .writerStart, .writerFailed, .outputMissing:
            return "writeFailure"
        case .cancelled:
            return "cancelled"
        case .none:
            return "internalFailure"
        @unknown default:
            return "internalFailure"
        }
    }
}
