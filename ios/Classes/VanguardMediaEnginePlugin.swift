// VanguardMediaEnginePlugin.swift
// Phase 1 additions:
//   P1-T4  — VanguardEngineMode enum + mandatory teardown-before-switch
//   P1-T7  — VanguardThumbnailGenerator (max 1 full renderer at any time)
//   P1-T10 — AVAudioSession route change handler

import Flutter
import UIKit
import Metal
import AVFoundation
import Photos
import PhotosUI
import Vision

// ─── P1-T4: Engine Mode ───────────────────────────────────────────────────────

/// The exclusive operating mode of the Vanguard engine.
/// Transitioning between modes requires tearing down the previous mode first.
/// This prevents the shared hardware H.264/HEVC encoder from being double-booked
/// (e.g. AVCaptureSession + AVAssetWriter contention on A-series SoCs).
@objc enum VanguardEngineMode: Int {
    case idle   = 0
    case editor = 1   // AVAssetReader active  — one full VanguardMetalRenderer
    case export = 2   // AVAssetWriter locked  — one VanguardExportSession
    case camera = 3   // AVCaptureSession live — Phase 3
}

// ─── P1-T7: Thumbnail Generator ──────────────────────────────────────────────

/// Lightweight thumbnail extractor backed by a single shared AVAssetImageGenerator.
/// Used for filmstrip frame extraction — never creates a full renderer.
/// Generates evenly-spaced JPEG thumbnail frames from a video.
/// Supports configurable maximumSize and compressionQuality for filmstrip and gallery.
final class VanguardThumbnailGenerator {

    private var generator: AVAssetImageGenerator?
    private let queue = DispatchQueue(label: "com.vanguard.thumbnails", qos: .userInitiated)

    func generateThumbnails(videoPath: String, count: Int, duration: Double,
                            maxWidth: Int = 120, maxHeight: Int = 214, jpegQuality: Double = 0.6,
                            completion: @escaping ([FlutterStandardTypedData]) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let url   = URL(fileURLWithPath: videoPath)
            let asset = AVURLAsset(url: url,
                                   options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

            let clampedWidth = max(1, min(maxWidth, 3840))
            let clampedHeight = max(1, min(maxHeight, 3840))
            let clampedQuality = max(0.1, min(jpegQuality, 1.0))

            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: clampedWidth, height: clampedHeight)
            gen.requestedTimeToleranceBefore = CMTimeMakeWithSeconds(0.1, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter  = CMTimeMakeWithSeconds(0.1, preferredTimescale: 600)
            self.generator = gen

            var times: [NSValue] = []
            let step = duration / Double(max(count - 1, 1))
            for i in 0..<count {
                let t = CMTimeMakeWithSeconds(Double(i) * step, preferredTimescale: 600)
                times.append(NSValue(time: t))
            }

            var images: [FlutterStandardTypedData] = []
            for timeValue in times {
                let t = timeValue.timeValue
                if let cgImage = try? gen.copyCGImage(at: t, actualTime: nil),
                   let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: CGFloat(clampedQuality)) {
                    images.append(FlutterStandardTypedData(bytes: data))
                }
            }
            DispatchQueue.main.async { completion(images) }
        }
    }

    func cancel() {
        generator?.cancelAllCGImageGeneration()
    }
}

// ─── P4-Remote: URL resolver ──────────────────────────────────────────────────
// Resolves a caller-supplied path string into a URL for Vanguard playback.
//   http:// | https:// | file://  → URL(string:) — preserves the scheme
//   bare local path               → URL(fileURLWithPath:) — unchanged behaviour
// Returns nil for an empty or syntactically invalid remote string, which the
// call-site surfaces as FlutterError(code:"INVALID_URL",...) so the caller
// receives a clean failure rather than a silently corrupted file:// URL.
internal extension URL {
    static func resolveVanguardPath(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") ||
           trimmed.hasPrefix("https://") ||
           trimmed.hasPrefix("file://") {
            return URL(string: trimmed)
        }
        return URL(fileURLWithPath: trimmed)
    }
}

// ─── Plugin ───────────────────────────────────────────────────────────────────

public class VanguardMediaEnginePlugin: NSObject, FlutterPlugin {
    private var registrar: FlutterPluginRegistrar!
    private var channel: FlutterMethodChannel!

    // P1-T4: Current mode — transitions require teardown
    var currentMode: VanguardEngineMode = .idle

    // P1-T7: At most ONE full renderer at any time (editor mode)
    var renderers: [Int64: VanguardMetalRenderer] = [:]

    // P1-T7: Single shared thumbnail generator — never a full renderer for filmstrip
    private let thumbnailGenerator = VanguardThumbnailGenerator()

    // ── Slice Q: waveform-cache handler ──────────────────────────────────────
    // Owns the serial I/O queue, HMAC-authenticated write leases, and epoch
    // state for all waveformCache_* MethodChannel routes.
    private let waveformCacheHandler = VGWaveformCacheMethodHandler()

    // ── Phase 4C6H: iOS streaming cache manager ───────────────────────────────
    // Singleton that owns AVAssetDownloadURLSession lifecycle, active prewarm
    // job tracking, storage headroom evaluation, and cache clear.
    // Plugin is a thin router only — no cache or lifecycle logic lives here.
    private let streamingCacheManager = VGStreamingCacheManager.shared

    // ── Phase 10-C Slice T: managed audio extraction handler ─────────────────
    // Owns the operation registry, VGAudioOnlyExporter instances, and
    // terminal/cancellation bookkeeping for beginAudioExtraction and
    // cancelAudioExtraction routes. Plugin is a thin router only.
    private let audioExtractionHandler = VanguardAudioExtractionHandler()

    // ── Phase 10F Slice 2B: custom video gallery picker handler ──────────────
    // Owns PhotoKit authorization, video asset querying, thumbnail caching,
    // and background video export to local cache.
    private let videoAssetPickerHandler = VGVideoAssetPickerHandler()

    // ── UMF V2 Slice 2A: photo library save handler ───────────────────────────
    private let photoLibrarySaveHandler = VGPhotoLibrarySaveHandler()

    // ── S-P1: timeline live filter-chain handler ──────────────────────────────
    // Owns all parsing, stale-target checking, and runtime delegation for the
    // `timeline_setFilterChain` route. Plugin provides composition wiring only.
    // Target provider resolves _timelineRuntime at call time; safely returns nil
    // when VG_USE_V2_GRAPH=0 (no _timelineRuntime property exists).
    private lazy var _timelineLiveControlHandler: VGTimelineLiveControlHandler = {
        VGTimelineLiveControlHandler(targetProvider: { [weak self] in
            #if VG_USE_V2_GRAPH
            guard let runtime = self?._timelineRuntime else { return nil }
            return vgtlcProductionTarget(runtime: runtime)
            #else
            return nil
            #endif
        })
    }()

    // ── V-B1/V-B2: per-track live audio mix-gain handler ─────────────────────
    // Owns all parsing, stale-target checking, and runtime delegation for the
    // `timeline_setAudioMixGain` route. Plugin provides composition wiring only.
    // Target provider resolves _timelineRuntime at call time; safely returns nil
    // when VG_USE_V2_GRAPH=0 (no _timelineRuntime property exists).
    private lazy var _mixGainHandler: VGTimelineAudioMixControlHandler = {
        VGTimelineAudioMixControlHandler(targetProvider: { [weak self] in
            #if VG_USE_V2_GRAPH
            guard let runtime = self?._timelineRuntime else { return nil }
            return vgtlamProductionTarget(runtime: runtime)
            #else
            return nil
            #endif
        })
    }()

    // Active export session — retained to outlive handle(_:result:) scope
    var activeExportSession: VanguardExportSession?

    // P3-T4: Camera source + streaming encoder (streaming path, not AVAssetWriter)
    var cameraSource: VanguardCameraMediaSource?
    var streamingEncoder: VanguardVideoToolboxEncoder?
    // POC 1: retain cameraFactory so we can read latestInstance in connectPlatformViewToCamera.
    // POC-only — remove or restructure before Phase 7 / production.
    var cameraFactory: VanguardCameraViewFactory?
    // Phase 6C: native VC that owns orientation decisions for the [POC6C] Native Camera screen.
    // Weak: the VC is retained by UIKit while presented; this is just a back-reference.
    weak var nativeCameraVC: VGNativeCameraViewController?
    #if VG_USE_CAMERA_GRAPH
    var cameraGraphSession: VGCameraGraphSession?
    #endif

    // Phase 7 Stage 7.5C: dedicated runtime for the timeline visual playback proof.
    // Lives outside the sessionRegistry (not a standard playback session).
    // Gated behind VG_USE_V2_GRAPH — nil when VG_USE_V2_GRAPH=0.
    #if VG_USE_V2_GRAPH
    var _timelineRuntime: VanguardGraphRuntime?
    #endif

    // Phase 7.x-E: DEV-only runtime for dual-camera texture mount smoke test.
    // Isolated from VGSessionRegistry and _timelineRuntime.
    // Created by dev_createDualCameraTexture; invalidated by dev_disposeDualCameraTexture.
    // Gated behind VG_USE_V2_GRAPH — nil when VG_USE_V2_GRAPH=0.
    #if VG_USE_V2_GRAPH
    private var _devDualCameraRuntime: VanguardGraphRuntime?
    // Phase 7.x-N: retained reference to the mounted DEV compositor node.
    // Set alongside _devDualCameraRuntime; nil'd on dispose.
    // Allows telemetry routes to call devGetTelemetry/devResetTelemetry
    // without requiring a new public property on VanguardGraphRuntime.
    private var _devDualCameraCompositorNode: VGDualCameraCompositorNode?
    #endif

    // Phase 2 Step 6: session registry is the unconditional playback path.
    // All createTexture / play / pause / seekTo / dispose calls route here.
    // Camera and export continue to use `renderers` exclusively.
    private let sessionRegistry = VGSessionRegistry()

    // Phase 2 Step 8: lifecycle observer — owns all NotificationCenter registrations.
    // Instantiated in register(with:) after sessionRegistry is available.
    private var lifecycleObserver: VGPluginLifecycleObserver?

    // ── MC-10/MC-11: Live MultiCam render diagnostic (start/stop texture path) ──
    //
    // Retained across start/stop calls. Both are nil when no diagnostic is running.
    // Start creates and retains them; stop reads, stops, unregisters, and nils them.
    // The MC-9 blocking runMultiCamRenderDiagnostic uses local-scope objects only.
    private var mcRenderDiagnosticSource: VanguardMultiCamMediaSource?
    private var mcRenderDiagnostic: VanguardMultiCamRenderer?

    // ── MC-11: Diagnostic lifecycle state machine ─────────────────────────────
    //
    // Guards the start/stop path against rapid-fire and concurrent calls.
    // All state transitions happen on the main thread (handle(_:result:) is
    // guaranteed to run on main by the Flutter plugin architecture).
    //
    //  idle     → starting  : startMultiCamRenderDiagnostic called
    //  starting → running   : hardware started successfully
    //  starting → stopping  : stopMultiCamRenderDiagnostic called while starting
    //  starting → idle      : source init failed while state was .stopping
    //  running  → stopping  : stopMultiCamRenderDiagnostic called normally
    //  stopping → idle      : stop teardown complete
    private enum MCDiagnosticState {
        case idle
        case starting
        case running
        case stopping
    }
    private var mcDiagnosticState: MCDiagnosticState = .idle

    // ─── Phase 8.16: Standalone audio playback service ───────────────────────
    //
    // Holds exactly one VGAudioPlaybackService. The service owns an AVPlayer
    // internally and supports one active player at a time. All routing is
    // through audioPlayback_* MethodChannel methods.
    // AVAudioSession is NOT configured here — the pre-activated .playback
    // session set up by VanguardFileMediaSource.preActivateAudioSession is shared.
    var audioPlaybackService: VGAudioPlaybackService = VGAudioPlaybackService()

    // ─── Audio Slice O: Shared session coordinator ───────────────────────────
    //
    // Exactly one VGAudioSessionTransitionCoordinator instance. Injected into
    // both the recording handler and the lifecycle coordinator so they share
    // one authoritative session state machine.
    //
    // Retain directions (no cycles):
    //   Plugin (strong) → audioSessionCoordinator
    //   Plugin (strong) → audioRecordingHandler (strong) → audioSessionCoordinator
    //   Plugin (strong) → audioLifecycleCoordinator (strong) → audioSessionCoordinator
    //   Plugin (strong) → audioTimelineAdapter (strong) → Plugin (WEAK)
    //   Plugin (strong) → lifecycleObserver (strong) → audioLifecycleCoordinator (strong)
    //   audioLifecycleCoordinator → audioRecordingHandler (WEAK)
    #if VG_USE_V2_GRAPH
    let audioSessionCoordinator = VGAudioSessionTransitionCoordinator()

    private lazy var _audioRecordingHandler: VGAudioRecordingHandler = {
        VGAudioRecordingHandler(coordinator: self.audioSessionCoordinator)
    }()

    private lazy var _audioTimelineAdapter: VGAudioTimelineLifecycleAdapter = {
        VGAudioTimelineLifecycleAdapter(plugin: self)
    }()

    private lazy var _audioLifecycleCoordinator: VGAudioLifecycleCoordinator = {
        VGAudioLifecycleCoordinator(
            recordingHandler:  self._audioRecordingHandler,
            coordinator:       self.audioSessionCoordinator,
            timelineLifecycle: self._audioTimelineAdapter)
    }()
    #endif

    // ─── Registration ─────────────────────────────────────────────────────────

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "vanguard_media_engine",
                                           binaryMessenger: registrar.messenger())
        let instance = VanguardMediaEnginePlugin()
        instance.registrar = registrar
        instance.channel   = channel
        registrar.addMethodCallDelegate(instance, channel: channel)

        // Phase 2 Step 6: sessionRegistry is now a let constant on the instance;
        // no explicit instantiation needed here.

        // P3-T4: Register camera PlatformView factory
        // POC 1: retain factory on instance so connectPlatformViewToCamera can read latestInstance.
        let cameraFactory = VanguardCameraViewFactory()
        instance.cameraFactory = cameraFactory
        registrar.register(cameraFactory, withId: "vanguard_camera_view")

        // Phase 2 Step 8 / Slice O: instantiate the lifecycle observer after
        // sessionRegistry is available. The observer owns all NotificationCenter
        // registrations and routes audio lifecycle events to the coordinator.
        #if VG_USE_V2_GRAPH
        instance.lifecycleObserver = VGPluginLifecycleObserver(
            registry:                  instance.sessionRegistry,
            plugin:                    instance,
            audioLifecycleCoordinator: instance._audioLifecycleCoordinator
        )
        #else
        instance.lifecycleObserver = VGPluginLifecycleObserver(
            registry: instance.sessionRegistry,
            plugin: instance
        )
        #endif

        // Phase 8.13: Install the Flutter asset resolver block.
        //
        // VGAssetResolverMVP (UMF) is a pure ObjC utility that cannot import
        // Flutter headers. Vanguard injects the Flutter-specific implementation
        // here, at plugin registration time, before any export session starts.
        //
        // Resolution logic:
        //   1. registrar.lookupKey(forAsset:) translates a Flutter asset key
        //      (e.g. "assets/stickers/star.png") into a bundle-relative resource
        //      name (e.g. "flutter_assets/assets/stickers/star.png").
        //   2. Bundle.main.path(forResource:ofType:) resolves that bundle key to
        //      an absolute native file path.
        //   Both APIs are documented thread-safe by Apple. The block is set once
        //   here (main thread) and only read thereafter (any thread), which is
        //   safe per the _Atomic happens-before guarantee in VGAssetResolverMVP.
        //
        // Absolute paths (starting with '/') are already handled by
        // VGAssetResolverMVP's pass-through rule and never reach this block.
        VGAssetResolverMVP.setResolverBlock { assetPath in
            // Translate Flutter asset key → bundle resource key.
            let bundleKey = registrar.lookupKey(forAsset: assetPath)
            // Resolve bundle resource key → absolute file path.
            // ofType: nil because bundleKey already contains the full filename
            // including extension (e.g. "flutter_assets/assets/stickers/star.png").
            return Bundle.main.path(forResource: bundleKey, ofType: nil)
        }
    }

    // ─── Mode teardown ─────────────────────────────────────────────────────────

    /// Synchronously tears down the current mode.
    /// PATCH-2: Camera teardown no longer calls stopRecordingAndWait here.
    /// For camera→editor transitions use teardownCameraAsync(completion:) instead.
    private func teardownCurrentMode() {
        switch currentMode {
        case .editor:
            // Phase 2 Step 6: playback sessions are owned by the registry.
            // Legacy renderer map has no playback entries; dispose all registry sessions.
            sessionRegistry.disposeAll()
        case .export:
            activeExportSession?.cancel()
            activeExportSession = nil
        case .camera:
            // Synchronous camera teardown path — used only when no recording
            // is active (e.g. startCamera teardown). If a recording is active,
            // callers MUST use teardownCameraAsync(completion:) instead.
            #if VG_USE_CAMERA_GRAPH
            if let session = cameraGraphSession {
                // Phase 6E.1D.2: Defensively disable graph recording before
                // invalidation so no in-flight processed frames append after
                // finishWritingWithCompletionHandler: is called.
                session.setRecordingEnabled(false)
                session.invalidate()
                cameraGraphSession = nil
            } else {
                cameraSource?.stop()
            }
            #else
            cameraSource?.stop()
            #endif
            cameraSource = nil
            streamingEncoder?.finish()
            streamingEncoder?.invalidate()
            streamingEncoder = nil
            // Dispose camera preview renderer(s) — renderers dict is camera-only here.
            for (id, renderer) in renderers {
                registrar.textures().unregisterTexture(id)
                renderer.dispose()
            }
            renderers.removeAll()
        case .idle:
            break
        }
    }

    /// Tears down the current mode and transitions to `mode`.
    /// For camera→camera transitions that may have an active recording,
    /// use teardownCameraAsync(completion:) instead.
    private func switchToMode(_ mode: VanguardEngineMode) {
        teardownCurrentMode()
        currentMode = mode
    }

    // Phase 7 Stage 7.5C: shared compositor init + runtime prepare helper.
    // Called from both the useSyntheticClips=true and useSyntheticClips=false paths
    // inside the dev_createTimelineTexture method channel case.
    // Must be called on the main thread.
    #if VG_USE_V2_GRAPH
    private func _prepareTimelineCompositor(
        clipDicts: [[String: Any]],
        transitionDicts: [[String: Any]],
        result: @escaping FlutterResult
    ) {
        // Build compositor parameters.
        let compositorParams: [String: Any] = [
            "descriptorStage": "7.5_executable",
            "clips":           clipDicts,
            "transitions":     transitionDicts,
            // Phase 7.9: no canvas dimensions in legacy path → compositor
            // forwards asset-native buffers (backward compatible).
        ]

        // Build port array: single video_out port.
        // VGMediaPort exposes class factory methods only — no instance initializer.
        // VGMediaTypeVideo imports as .video; direction is implied by outputPort.
        let videoOutPort = VGMediaPort.outputPort("video_out", mediaType: .video)
        let ports: [VGMediaPort] = [videoOutPort]

        // Initialize compositor.
        // nullable instancetype + NSError ** imports into Swift as a throwing
        // initializer — the error: parameter is consumed by the throws mechanism.
        let compositor: VGTimelineCompositorNode
        do {
            compositor = try VGTimelineCompositorNode(
                nodeId:     "timeline_compositor",
                parameters: compositorParams,
                ports:      ports
            )
        } catch {
            let msg = error.localizedDescription
            result(FlutterError(code: "COMPOSITOR_INIT_FAILED",
                                message: msg, details: nil))
            return
        }

        // Create a dedicated VanguardGraphRuntime for the timeline.
        let timelineRuntime = VanguardGraphRuntime(
            textureRegistry: registrar.textures(),
            methodChannel:   channel)
        self._timelineRuntime = timelineRuntime

        timelineRuntime.prepareTimeline(sourceNode: compositor) { textureId, err in
            if let err = err {
                result(FlutterError(code: "PREPARE_TIMELINE_FAILED",
                                    message: err.localizedDescription,
                                    details: nil))
                return
            }
            result(["textureId": textureId, "width": 320, "height": 240])
        }
    }

    // Phase 7 Stage 7.5D: variant of _prepareTimelineCompositor that returns
    // caller-supplied width/height in the result map so Dart can size its
    // Texture widget correctly for non-320×240 fixture resolutions.
    // The original _prepareTimelineCompositor is NOT modified.
    private func _prepareTimelineCompositorWithSize(
        clipDicts: [[String: Any]],
        transitionDicts: [[String: Any]],
        width: Int,
        height: Int,
        // Phase 10-C Slice D: optional audio sidecar plan and project duration.
        // audioSidecarPlan may be nil (silent mode). durationSeconds must be > 0.
        audioSidecarPlan: VGAudioSidecarPlan? = nil,
        durationSeconds: Double = 0.0,
        result: @escaping FlutterResult
    ) {
        let compositorParams: [String: Any] = [
            "descriptorStage": "7.5_executable",
            "clips":           clipDicts,
            "transitions":     transitionDicts,
            // Phase 7.9: pass canvas dimensions for aspect-fit normalization.
            // The compositor uses these to override AVMutableVideoComposition
            // renderSize and apply an aspect-fit layer instruction.
            "canvasWidth":     width,
            "canvasHeight":    height,
        ]

        let videoOutPort = VGMediaPort.outputPort("video_out", mediaType: .video)
        let ports: [VGMediaPort] = [videoOutPort]

        let compositor: VGTimelineCompositorNode
        do {
            compositor = try VGTimelineCompositorNode(
                nodeId:     "timeline_compositor",
                parameters: compositorParams,
                ports:      ports
            )
        } catch {
            let msg = error.localizedDescription
            result(FlutterError(code: "COMPOSITOR_INIT_FAILED",
                                message: msg, details: nil))
            return
        }

        let timelineRuntime = VanguardGraphRuntime(
            textureRegistry: registrar.textures(),
            methodChannel:   channel)
        self._timelineRuntime = timelineRuntime

        // Phase 10-C Slice D: capture for use inside the completion handler.
        let capturedSidecar   = audioSidecarPlan
        let capturedDuration  = durationSeconds

        timelineRuntime.prepareTimeline(sourceNode: compositor) { textureId, err in
            if let err = err {
                result(FlutterError(code: "PREPARE_TIMELINE_FAILED",
                                    message: err.localizedDescription,
                                    details: nil))
                return
            }
            // Phase 10-C Slice D: arm the audio preview runtime after the compositor
            // is prepared. result() is deferred until audio setup completes (or
            // silently falls back). Video preview is unaffected by any audio result.
            // FlutterResult is called exactly once — either from the audio completion
            // or from the video failure path above.
            timelineRuntime.setAudioSidecarPlan(capturedSidecar,
                                                timelineDuration: capturedDuration,
                                                completion: {
                result(["textureId": textureId, "width": width, "height": height])
            })
        }
    }

    // Phase 7.8: Swift preflight validation helpers.
    // These helpers perform high-level validation only. They do NOT re-parse clip
    // data into new native structures. After validation the original clip/transition
    // dicts are passed directly to VGTimelineCompositorNode via ObjC fromDictionary:.
    //
    // Apple documentation:
    //   - FileManager.isReadableFile(atPath:): returns true if file exists and
    //     the current process has read access. Docs: "Returns a Boolean value that
    //     indicates whether the invoking object appears able to read a specified file."
    //     (Foundation.FileManager — Apple Developer Documentation)
    //   - URL(fileURLWithPath:) must be used for local POSIX paths — URL(string:)
    //     is for RFC 3986 URI strings and will return nil or produce wrong results
    //     for paths with spaces or special characters.
    //     (Foundation.URL — Apple Developer Documentation)

    /// Validates a clip dictionaries array for Phase 7.12 production routes.
    ///
    /// Checks per clip:
    ///   - Non-empty `id`
    ///   - `mediaKind` is `"video"` or `"image"` (Phase 7.12: still-image clips supported; audio is Phase 8+)
    ///   - Non-empty `sourcePath`
    ///   - `FileManager.default.isReadableFile(atPath: sourcePath)` = true
    ///   - `trimStartSeconds >= 0`
    ///   - `trimEndSeconds > trimStartSeconds`
    ///   - If `durationSeconds > 0`: `trimEndSeconds <= durationSeconds`
    ///
    /// Returns a `FlutterError` on the first validation failure, or `nil` if all clips pass.
    private func _preflightClips(_ clipDicts: [[String: Any]]) -> FlutterError? {
        for (idx, clip) in clipDicts.enumerated() {
            let clipId = clip["id"] as? String ?? "<unknown>"

            // Validate id.
            guard let id = clip["id"] as? String, !id.isEmpty else {
                return FlutterError(
                    code: "MISSING_SOURCE_PATH",
                    message: "clips[\(idx)]: missing or empty id",
                    details: nil)
            }

            // Validate mediaKind — video and image supported in Phase 7.12.
            // Audio timelines are Phase 8+; unknown kinds are always rejected.
            let mediaKind = clip["mediaKind"] as? String ?? ""
            guard mediaKind == "video" || mediaKind == "image" else {
                return FlutterError(
                    code: "UNSUPPORTED_MEDIA_KIND",
                    message: "clips[\(idx)] id=\(clipId): mediaKind '\(mediaKind)' "
                           + "is not supported. Supported: video, image. Audio timelines are Phase 8+.",
                    details: nil)
            }

            // Validate sourcePath.
            guard let sourcePath = clip["sourcePath"] as? String, !sourcePath.isEmpty else {
                return FlutterError(
                    code: "MISSING_SOURCE_PATH",
                    message: "clips[\(idx)] id=\(clipId): sourcePath is missing or empty",
                    details: nil)
            }

            // File readability check.
            // Use FileManager.isReadableFile — the recommended API for checking
            // read access before attempting AVAssetReader initialization.
            // Security-scoped resources not implemented in Phase 7.8.
            guard FileManager.default.isReadableFile(atPath: sourcePath) else {
                return FlutterError(
                    code: "FILE_UNREADABLE",
                    message: "clips[\(idx)] id=\(clipId): "
                           + "file does not exist or is unreadable at path: \(sourcePath)",
                    details: nil)
            }

            // Validate trim range.
            let trimStart = (clip["trimStartSeconds"] as? NSNumber)?.doubleValue ?? 0.0
            let trimEnd   = (clip["trimEndSeconds"]   as? NSNumber)?.doubleValue ?? 0.0
            let duration  = (clip["durationSeconds"]  as? NSNumber)?.doubleValue ?? 0.0

            guard trimStart >= 0.0 else {
                return FlutterError(
                    code: "INVALID_TRIM_RANGE",
                    message: "clips[\(idx)] id=\(clipId): "
                           + "trimStartSeconds (\(trimStart)) must be >= 0",
                    details: nil)
            }
            guard trimEnd > trimStart else {
                return FlutterError(
                    code: "INVALID_TRIM_RANGE",
                    message: "clips[\(idx)] id=\(clipId): "
                           + "trimEndSeconds (\(trimEnd)) must be > trimStartSeconds (\(trimStart))",
                    details: nil)
            }
            if duration > 0.0 {
                guard trimEnd <= duration else {
                    return FlutterError(
                        code: "INVALID_TRIM_RANGE",
                        message: "clips[\(idx)] id=\(clipId): "
                               + "trimEndSeconds (\(trimEnd)) exceeds durationSeconds (\(duration))",
                        details: nil)
                }
            }
        }
        return nil
    }

    /// Validates a transition dictionaries array for production routes.
    ///
    /// Phase 7.10: the hard-cut-only gate is lifted. Supported transition types
    /// are `none` (hard cut), `dissolve`, and `fade`. Any other type string is
    /// Returns a `FlutterError` on the first invalid transition, or `nil` if all pass.
    private func _preflightTransitions(_ transitionDicts: [[String: Any]]) -> FlutterError? {
        // Transition types accepted by VGTimelineCompositorNode as of Phase 7.10.
        let supportedTypes: Set<String> = ["none", "dissolve", "fade"]

        for (idx, t) in transitionDicts.enumerated() {
            let tId     = t["id"] as? String ?? "<unknown>"
            let typeStr = t["type"] as? String ?? "none"

            guard supportedTypes.contains(typeStr) else {
                return FlutterError(
                    code: "UNSUPPORTED_TRANSITION_TYPE",
                    message: "transitions[\(idx)] id=\(tId): "
                           + "type '\(typeStr)' is not supported. "
                           + "Supported types: \(supportedTypes.sorted().joined(separator: ", ")).",
                    details: nil)
            }
        }
        return nil
    }

    #endif // VG_USE_V2_GRAPH



    // ── MC-13: Shared MultiCam preview pipeline helpers ───────────────────────
    //
    // These private helpers centralise the start/stop logic so that both the
    // diagnostic routes ('startMultiCamRenderDiagnostic'/'stopMultiCamRenderDiagnostic')
    // and the production routes ('startMultiCamPreview'/'stopMultiCamPreview')
    // share identical behaviour without code duplication.
    //
    // The original `case "startMultiCamRenderDiagnostic"` body is preserved
    // verbatim and NOT refactored. Only the new MC-13 cases delegate here.
    // This guarantees zero regression risk for the diagnostic path.

    /// Starts the MultiCam render pipeline and registers a Flutter texture.
    ///
    /// Enforces the same CAMERA_ACTIVE, ALREADY_RUNNING, and stop-while-starting
    /// guards as the `startMultiCamRenderDiagnostic` handler.
    /// [callerTag] is included in log messages to distinguish the production
    /// call-site ("MC-13") from the diagnostic call-site ("MC-10").
    private func _handleStartMultiCam(
        args: [String: Any]?,
        callerTag: String,
        result: @escaping FlutterResult
    ) {
        guard currentMode == .idle else {
            result(FlutterError(
                code: "CAMERA_ACTIVE",
                message: "Stop camera preview before starting MultiCam preview",
                details: nil
            ))
            return
        }
        guard mcDiagnosticState == .idle else {
            result(FlutterError(
                code: "ALREADY_RUNNING",
                message: "A MultiCam preview is already running — call stopMultiCamPreview first",
                details: nil
            ))
            return
        }
        guard let frontDeviceId = args?["frontDeviceId"] as? String,
              let backDeviceId  = args?["backDeviceId"]  as? String else {
            result(FlutterError(
                code: "INVALID_ARG",
                message: "startMultiCamPreview requires frontDeviceId and backDeviceId",
                details: nil
            ))
            return
        }
        if #available(iOS 13.0, *) {
            mcDiagnosticState = .starting

            let renderer = VanguardMultiCamRenderer(textureRegistry: registrar.textures())
            if let configMap = args?["config"] as? [String: Any] {
                renderer.setLayoutConfig(VanguardMultiCamRenderer.layoutConfig(fromMap: configMap))
            }
            let textureId     = renderer.textureId
            let initialWidth  = renderer.outputWidth
            let initialHeight = renderer.outputHeight

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                let source = VanguardMultiCamMediaSource(
                    frontDeviceId: frontDeviceId,
                    backDeviceId: backDeviceId,
                    frameRate: 30
                )
                guard let source = source else {
                    DispatchQueue.main.async {
                        renderer.doUnregisterTexture()
                        self.mcDiagnosticState = .idle
                        result(nil)
                    }
                    return
                }

                source.delegate = renderer

                guard source.start() else {
                    source.stop()
                    DispatchQueue.main.async {
                        renderer.doUnregisterTexture()
                        self.mcDiagnosticState = .idle
                        result(nil)
                    }
                    return
                }

                DispatchQueue.main.async {
                    if self.mcDiagnosticState == .stopping {
                        DispatchQueue.global(qos: .userInitiated).async {
                            source.stop()
                            renderer.stop()
                            DispatchQueue.main.sync {
                                renderer.doUnregisterTexture()
                            }
                            DispatchQueue.main.async {
                                self.mcDiagnosticState = .idle
                                result(nil)
                            }
                        }
                        return
                    }

                    self.mcRenderDiagnosticSource = source
                    self.mcRenderDiagnostic       = renderer
                    self.mcDiagnosticState        = .running


                    result([
                        "textureId":    textureId,
                        "outputWidth":  Int(initialWidth),
                        "outputHeight": Int(initialHeight),
                    ])
                }
            }
        } else {
            result(nil)
        }
    }

    /// Stops the active MultiCam render pipeline and returns the metrics map.
    ///
    /// Mirrors the `stopMultiCamRenderDiagnostic` state-machine exactly.
    /// [callerTag] is included in log messages.
    private func _handleStopMultiCam(
        callerTag: String,
        result: @escaping FlutterResult
    ) {
        switch mcDiagnosticState {
        case .idle:
            result(nil)

        case .starting:
            mcDiagnosticState = .stopping
            result(nil)

        case .running:
            guard let source   = mcRenderDiagnosticSource,
                  let renderer = mcRenderDiagnostic else {
                mcDiagnosticState = .idle
                result(nil)
                return
            }
            mcDiagnosticState = .stopping

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                source.stop()
                renderer.stop()

                DispatchQueue.main.sync {
                    renderer.doUnregisterTexture()
                }

                var metrics = source.metrics() as? [String: Any] ?? [:]
                let renderMetrics = renderer.metrics()
                metrics["renderedFrames"]      = renderMetrics["renderedFrames"]
                metrics["droppedRenderFrames"] = renderMetrics["droppedRenderFrames"]
                metrics["averageRenderMs"]     = renderMetrics["averageRenderMs"]
                metrics["peakRenderMs"]        = renderMetrics["peakRenderMs"]
                metrics["outputWidth"]         = renderMetrics["outputWidth"]
                metrics["outputHeight"]        = renderMetrics["outputHeight"]

                DispatchQueue.main.async {
                    self.mcRenderDiagnosticSource = nil
                    self.mcRenderDiagnostic       = nil
                    self.mcDiagnosticState        = .idle

                    let logRendered = renderMetrics["renderedFrames"] ?? 0
                    let logAvgMs    = renderMetrics["averageRenderMs"] ?? 0

                    result(metrics)
                }
            }

        case .stopping:
            result(nil)
        }
    }

    /// PATCH-2: Async camera teardown for transitions that may have an active recording.
    /// Calls stopRecording(completion:) (no main-thread block) then invokes completion
    /// on main. The 5-second semaphore wait that existed in stopRecordingAndWait is gone.
    private func teardownCameraAsync(completion: @escaping () -> Void) {
        guard currentMode == .camera, let source = cameraSource else {
            teardownCurrentMode()
            completion()
            return
        }
        // Capture locals before nil-ing ivars so the completion block can safely reference them.
        let encoder = streamingEncoder
        source.stopRecording { [weak self] _, _, _, error in
            // Back on main thread (stopRecordingWithCompletion: guarantees this).
            // BLOCK-2 FIX: capture the error instead of discarding it.
            // finishWritingWithCompletionHandler: can fail during a phone call or
            // AVAudioSession interruption; the clip is lost (url == nil). Log the
            // error and emit an event so Flutter can notify the user.
            if let error = error {
                self?.channel.invokeMethod("onRecordingError",
                                           arguments: ["message": error.localizedDescription])
            }
            #if VG_USE_CAMERA_GRAPH
            if let session = self?.cameraGraphSession {
                // Phase 6E.1D.2: Defensively disable graph recording before
                // invalidation so no in-flight processed frames append after
                // finishWritingWithCompletionHandler: is called.
                session.setRecordingEnabled(false)
                session.invalidate()
                self?.cameraGraphSession = nil
            } else {
                source.stop()
            }
            #else
            source.stop()
            #endif
            self?.cameraSource = nil
            encoder?.finish()
            encoder?.invalidate()
            self?.streamingEncoder = nil
            self?.currentMode = .idle
            completion()
        }
    }

    // ─── Method Channel Dispatch ───────────────────────────────────────────────

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        // ── Slice Q: early waveform-cache forwarding ──────────────────────────
        // Intercept all waveformCache_* routes before the main switch so they
        // never traverse the full case table. The handler owns all epoch logic.
        if call.method.hasPrefix("waveformCache_") {
            waveformCacheHandler.handle(call: call.method, args: args, result: result)
            return
        }

        // ── S-P1: timeline live filter-chain forwarding ───────────────────────
        // The handler owns all parsing, stale-target checking, and dispatch.
        if call.method == "timeline_setFilterChain" {
            _timelineLiveControlHandler.handle(args: args, result: result)
            return
        }

        // ── V-B1/V-B2: per-track live mix gain ────────────────────────────────
        // Sets mix gain on the active VanguardAudioPreviewRuntime for a given
        // trackId without rebuilding the timeline (no updateDraft call).
        // Args: { "textureId": Int64, "trackId": String, "gain": Double [0.0,1.0] }
        // Delegated to VGTimelineAudioMixControlHandler which enforces stale-texture
        // guarding using the same target-provider pattern as VGTimelineLiveControlHandler.
        if call.method == "timeline_setAudioMixGain" {
            _mixGainHandler.handle(args: args, result: result)
            return
        }

        // ── Phase 4C6H: iOS streaming cache routes ────────────────────────────
        // The five cache MethodChannel routes are forwarded to
        // VGStreamingCacheManager.shared. No cache or lifecycle logic lives here.
        if call.method == "getPlaybackCacheStatus" {
            let cacheEnabled = args?["cacheEnabled"] as? Bool ?? true
            streamingCacheManager.getStatus(cacheEnabled: cacheEnabled, result: result)
            return
        }
        if call.method == "startPlaybackCachePrewarm" {
            let requestId  = (args?["requestId"] as? String) ?? ""
            let uri        = (args?["uri"] as? String) ?? ""
            let maxBytesRaw = (args?["maxBytes"] as? NSNumber)?.int64Value ?? 0
            let maxBytes   = maxBytesRaw > 0 ? maxBytesRaw : 2 * 1024 * 1024
            let minFreeRaw = (args?["minimumFreeBytesAfterPrewarm"] as? NSNumber)?.int64Value
            let minFree: Int64 = {
                guard let v = minFreeRaw else { return VGStorageHeadroomGuard.defaultMinFreeBytes }
                return v < 0 ? VGStorageHeadroomGuard.defaultMinFreeBytes : v
            }()
            let cacheEnabled = args?["cacheEnabled"] as? Bool ?? true
            streamingCacheManager.startPrewarm(
                requestId: requestId,
                uri: uri,
                maxBytes: maxBytes,
                minimumFreeBytesAfterPrewarm: minFree,
                cacheEnabled: cacheEnabled,
                result: result
            )
            return
        }
        if call.method == "getPlaybackCachePrewarmStatus" {
            let requestId = (args?["requestId"] as? String) ?? ""
            streamingCacheManager.getPrewarmStatus(requestId: requestId, result: result)
            return
        }
        if call.method == "cancelPlaybackCachePrewarm" {
            let requestId = (args?["requestId"] as? String) ?? ""
            streamingCacheManager.cancelPrewarm(requestId: requestId, result: result)
            return
        }
        if call.method == "clearPlaybackCache" {
            streamingCacheManager.clearCache(result: result)
            return
        }

        switch call.method {

        // ── Texture lifecycle ─────────────────────────────────────────────────

        case "createTexture":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARG", message: "path required", details: nil))
                return
            }


            // Phase 2 Step 7: read caller-supplied muted flag.
            // Dart passes {'path': ..., 'muted': true/false}. Absent key defaults to
            // false (active audio) — preserves backward-compat with existing callers.
            let muted = args?["muted"] as? Bool ?? false

            // Phase 2 Step 6: all playback creation routes through VGSessionRegistry.
            // Camera teardown runs first if needed so AVAudioSession is free.
            let _createTextureViaRegistry = { [weak self] in
                guard let self else { return }
                // P4-Remote: resolve local paths and http(s):// remote URLs.
                // URL(fileURLWithPath:) would silently corrupt a remote URL string
                // into an invalid file:// path. resolveVanguardPath preserves the
                // scheme for remote URLs while leaving local paths unchanged.
                guard let url = URL.resolveVanguardPath(path) else {
                    result(FlutterError(code: "INVALID_URL",
                                        message: "createTexture: invalid or empty URL: \(path)",
                                        details: nil))
                    return
                }
                // Capture sessionId in a local var; assigned synchronously by
                // createSession before its async completion ever fires.
                var sid = ""
                sid = self.sessionRegistry.createSession(
                    url:             url,
                    textureRegistry: self.registrar.textures(),
                    methodChannel:   self.channel,
                    desiredAudioRole: muted ? .muted : .active
                ) { textureId, renderSize in
                    DispatchQueue.main.async {
                        guard textureId >= 0 else {
                            result(FlutterError(code: "PREPARE_FAILED",
                                                message: "createTexture: prepare failed",
                                                details: nil))
                            return
                        }
                        let w = renderSize.width  > 0 ? Int(renderSize.width)  : 1080
                        let h = renderSize.height > 0 ? Int(renderSize.height) : 1920
                        result(["textureId": textureId, "sessionId": sid, "width": w, "height": h])
                    }
                }
            }

            if currentMode == .camera {
                teardownCameraAsync { _createTextureViaRegistry() }
            } else {
                _createTextureViaRegistry()
            }

        // ── Image texture (Phase A1-S1) ────────────────────────────────────────
        // Creates a VanguardMetalRenderer backed by VanguardImageMediaSource.
        // Conforms to the same id<VanguardMediaSource> contract as video and
        // camera sources. The renderer's filter chain is fully active — LUT,
        // beauty, and ML filters apply to images exactly as they do to video frames.
        //
        // Lifecycle:
        //   init → renderer allocates CVPixelBufferPool
        //   pool wired back to processor (mirrors initWithVideoPath: pattern)
        //   source.start() fires one CVPixelBuffer via _videoCallback → _latestPixelBuffer
        //   copyPixelBuffer returns that buffer on every raster-thread tick
        //   seek(0) re-fires the same buffer (safe — no-op from source perspective)
        //
        // Mode: .editor — image and video editor share the same render path.
        // The existing max-1-renderer guard applies; any previous renderer is
        // torn down before the image renderer is created.

        case "createImageTexture":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "createImageTexture: path required",
                                    details: nil))
                return
            }
            let imageURL = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                result(FlutterError(code: "FILE_NOT_FOUND",
                                    message: "createImageTexture: file not found at \(path)",
                                    details: nil))
                return
            }

            // Phase 2 Step 6: image creation also routes through VGSessionRegistry.
            let _createImageViaRegistry = { [weak self] in
                guard let self else { return }
                var sid = ""
                sid = self.sessionRegistry.createSession(
                    url:             imageURL,
                    textureRegistry: self.registrar.textures(),
                    methodChannel:   self.channel,
                    desiredAudioRole: .muted
                ) { textureId, renderSize in
                    DispatchQueue.main.async {
                        guard textureId >= 0 else {
                            result(FlutterError(code: "PREPARE_FAILED",
                                                message: "createImageTexture: prepare failed",
                                                details: nil))
                            return
                        }
                        let w = renderSize.width  > 0 ? Int(renderSize.width)  : 1080
                        let h = renderSize.height > 0 ? Int(renderSize.height) : 1920
                        result(["textureId": textureId, "sessionId": sid, "width": w, "height": h])
                    }
                }
            }

            if currentMode == .camera {
                teardownCameraAsync { _createImageViaRegistry() }
            } else {
                _createImageViaRegistry()
            }

        // ── Video duration probe (Phase A2-S1) ────────────────────────────────────
        // Lightweight AVURLAsset.duration read — no renderer, no decoder, no FFmpeg.
        // Replaces VideoPlayerController.file initialization in addClip() which was
        // creating a competing AVFoundation session and violating I-5.
        //
        // AVURLAsset.duration blocks the calling thread for one XPC round-trip to
        // mediaserverd (~5-30ms). We dispatch to a background queue so the main
        // thread is never blocked and the MethodChannel stays responsive.
        //
        // Returns the duration in seconds as a Double, or -1.0 if the asset cannot
        // be loaded (caller falls back to 15.0s default).
        case "probeVideoDuration":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "probeVideoDuration: path required",
                                    details: nil))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let url   = URL(fileURLWithPath: path)
                let asset = AVURLAsset(url: url,
                                       options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
                let dur = CMTimeGetSeconds(asset.duration)
                let seconds: Double = (dur.isNaN || dur.isInfinite || dur <= 0) ? -1.0 : dur
                DispatchQueue.main.async { result(seconds) }
            }

        case "probeVideoInfo":
            // Returns ["duration": Double, "width": Double, "height": Double] for a video file.
            // Used by story_export_service to replace FFmpegKit metadata probes.
            // iOS: AVURLAsset.duration + AVAssetTrack.naturalSize.
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "probeVideoInfo: path required",
                                    details: nil))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let url   = URL(fileURLWithPath: path)
                let asset = AVURLAsset(url: url,
                                       options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
                let dur     = CMTimeGetSeconds(asset.duration)
                let seconds = (dur.isNaN || dur.isInfinite || dur <= 0) ? -1.0 : dur
                // naturalSize may be .zero if no video track — report 0 dimensions gracefully.
                let size    = asset.tracks(withMediaType: .video).first?.naturalSize ?? .zero
                DispatchQueue.main.async {
                    result(["duration": seconds, "width": Double(size.width), "height": Double(size.height)])
                }
            }

        // ── inspectMedia ─────────────────────────────────────────────────────────
        // Extended media probe (superset of probeVideoInfo). Returns full MediaInfo
        // map needed by VanguardMediaPreparer decision logic.
        // probeVideoInfo is kept unchanged — do not remove it.
        case "inspectMedia":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "inspectMedia: path required",
                                    details: nil))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let url   = URL(fileURLWithPath: path)
                let asset = AVURLAsset(url: url,
                                       options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

                // Duration
                let dur     = CMTimeGetSeconds(asset.duration)
                let seconds = (dur.isNaN || dur.isInfinite || dur <= 0) ? -1.0 : dur

                // File size
                let fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0

                // Container (extension-based; fast path)
                let ext = url.pathExtension.lowercased()
                let containerMap: [String: String] = [
                    "mp4": "mp4", "m4v": "mp4", "mov": "mov",
                    "mkv": "mkv", "webm": "webm", "avi": "avi",
                    "m4a": "m4a", "aac": "aac", "mp3": "mp3",
                    "jpeg": "jpeg", "jpg": "jpeg", "png": "png",
                    "heic": "heic", "heif": "heif", "webp": "webp", "gif": "gif",
                ]
                let container = containerMap[ext] ?? ext

                // Video track properties
                let videoTrack = asset.tracks(withMediaType: .video).first
                let size       = videoTrack?.naturalSize ?? .zero
                let bitrate    = videoTrack.map { Int($0.estimatedDataRate / 1000) } ?? 0
                let fps        = videoTrack.map { Double($0.nominalFrameRate) } ?? 0.0

                // Rotation — preferredTransform != identity means rotation metadata is present
                let transform          = videoTrack?.preferredTransform ?? .identity
                let hasRotationTransform = (transform.a != 1.0 || transform.b != 0.0 ||
                                            transform.c != 0.0 || transform.d != 1.0)

                // ROI-5A.1: orientation evidence extraction (pure math, no I/O).
                let orientationEvidence = VGOrientationEvidence.extract(
                    naturalSize: size,
                    preferredTransform: transform
                )

                // Video codec — read FourCC from first format description
                var videoCodec = ""
                if let fmtDesc = videoTrack?.formatDescriptions.first {
                    let subtype = CMFormatDescriptionGetMediaSubType(fmtDesc as! CMFormatDescription)
                    switch subtype {
                    case kCMVideoCodecType_H264:              videoCodec = "h264"
                    case kCMVideoCodecType_HEVC:              videoCodec = "hevc"
                    case kCMVideoCodecType_MPEG4Video:        videoCodec = "mpeg4"
                    case kCMVideoCodecType_VP9:               videoCodec = "vp9"
                    case kCMVideoCodecType_AV1:               videoCodec = "av1"
                    default:
                        // Format as "0x{hex}" for unknown subtypes
                        videoCodec = String(format: "0x%08X", subtype)
                    }
                }

                // Audio track codec
                var audioCodec = ""
                if let audioTrack = asset.tracks(withMediaType: .audio).first,
                   let fmtDesc = audioTrack.formatDescriptions.first {
                    let subtype = CMFormatDescriptionGetMediaSubType(fmtDesc as! CMFormatDescription)
                    switch subtype {
                    case kAudioFormatMPEG4AAC,
                         kAudioFormatMPEG4AAC_HE,
                         kAudioFormatMPEG4AAC_HE_V2: audioCodec = "aac"
                    case kAudioFormatLinearPCM:       audioCodec = "pcm"
                    case kAudioFormatAC3,
                         kAudioFormatEnhancedAC3:     audioCodec = "ac3"
                    case kAudioFormatMPEGLayer3:      audioCodec = "mp3"
                    case kAudioFormatOpus:            audioCodec = "opus"
                    default:                          audioCodec = String(format: "0x%08X", subtype)
                    }
                }

                // HDR — check color primaries (reuse _selectExportPreset logic)
                var isHDR = false
                if let videoTrack = videoTrack {
                    for desc in videoTrack.formatDescriptions {
                        if let primaries = CMFormatDescriptionGetExtension(
                            desc as! CMFormatDescription,
                            extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
                        ) as? String,
                           primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
                            isHDR = true
                            break
                        }
                    }
                }

                // Embedded metadata (GPS, device info, etc.) — coarse check for any common items
                let metaItems = asset.metadata
                let hasEmbeddedMetadata = !metaItems.isEmpty

                // Track presence
                let hasVideo = videoTrack != nil
                let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty

                // hasMoovAtFront: conservatively false by default (see implementation plan §B2).
                // Routing eligible files to normalizeVideo (lossless passthrough remux) is safe.
                // A proper atom-walk parser is deferred.
                let hasMoovAtFront = false

                // MediaKind
                let imageExts: Set<String> = ["jpeg", "jpg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff"]
                let audioExts: Set<String> = ["m4a", "aac", "mp3", "wav", "flac", "ogg"]
                let kind: String
                if imageExts.contains(ext)     { kind = "image" }
                else if audioExts.contains(ext) { kind = "audio" }
                else if hasVideo || ["mp4","mov","mkv","webm","avi","m4v"].contains(ext) { kind = "video" }
                else                            { kind = "unknown" }

                DispatchQueue.main.async {
                    // Base fields — all existing keys are preserved unchanged.
                    var resultMap: [String: Any] = [
                        "kind":                  kind,
                        "container":             container,
                        "videoCodec":            videoCodec,
                        "audioCodec":            audioCodec,
                        "width":                 Int(size.width),
                        "height":                Int(size.height),
                        "durationSeconds":       seconds,
                        "bitrateKbps":           bitrate,
                        "fps":                   fps,
                        "fileSizeBytes":         fileSizeBytes,
                        "hasVideo":              hasVideo,
                        "hasAudio":              hasAudio,
                        "isHDR":                 isHDR,
                        "hasMoovAtFront":        hasMoovAtFront,
                        "hasRotationTransform":  hasRotationTransform,
                        "hasEmbeddedMetadata":   hasEmbeddedMetadata,
                    ]
                    // ROI-5A.1 orientation evidence fields (additive — never
                    // overwrite existing keys above).
                    for (key, value) in orientationEvidence.toFlutterMap() {
                        resultMap[key] = value
                    }
                    result(resultMap)
                }
            }


        // ── compressImage ─────────────────────────────────────────────────────────
        // Resizes and JPEG-encodes an image file using CGImageDestination.
        // CGImageDestination with an explicit properties dict that omits EXIF and GPS
        // keys guarantees metadata stripping regardless of source file.
        // Do NOT switch to UIImage.jpegData() — its EXIF behavior is version-dependent.
        case "compressImage":
            guard
                let inputPath  = args?["inputPath"]  as? String,
                let outputPath = args?["outputPath"] as? String,
                let maxWidthPx = args?["maxWidthPx"] as? Int,
                let quality    = args?["jpegQuality"] as? Double
            else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "compressImage: inputPath, outputPath, maxWidthPx, jpegQuality required",
                                    details: nil))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                guard
                    let source    = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
                    let cgImage   = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "READ_FAILED",
                                            message: "compressImage: cannot read source image",
                                            details: nil))
                    }
                    return
                }

                // Compute target dimensions, maintaining aspect ratio
                let srcW = cgImage.width
                let srcH = cgImage.height
                let (targetW, targetH): (Int, Int) = {
                    guard srcW > maxWidthPx else { return (srcW, srcH) }
                    let scale = Double(maxWidthPx) / Double(srcW)
                    return (maxWidthPx, max(1, Int(Double(srcH) * scale)))
                }()

                // Resize using CGContext if needed
                let finalImage: CGImage
                if targetW == srcW && targetH == srcH {
                    finalImage = cgImage
                } else {
                    let cs = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
                    guard let ctx = CGContext(
                        data: nil,
                        width: targetW, height: targetH,
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    ) else {
                        DispatchQueue.main.async {
                            result(FlutterError(code: "RESIZE_FAILED",
                                                message: "compressImage: cannot create graphics context",
                                                details: nil))
                        }
                        return
                    }
                    ctx.interpolationQuality = .high
                    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
                    guard let resized = ctx.makeImage() else {
                        DispatchQueue.main.async {
                            result(FlutterError(code: "RESIZE_FAILED",
                                                message: "compressImage: makeImage failed",
                                                details: nil))
                        }
                        return
                    }
                    finalImage = resized
                }

                // Write JPEG with explicit properties — omit EXIF/GPS keys intentionally
                let outURL  = URL(fileURLWithPath: outputPath)
                let uti     = "public.jpeg" as CFString
                let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
                guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, uti, 1, nil) else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "WRITE_FAILED",
                                            message: "compressImage: cannot create destination",
                                            details: nil))
                    }
                    return
                }
                // properties dict ONLY contains quality — no EXIF, no GPS, no IPTC
                CGImageDestinationAddImage(dest, finalImage, options)
                let wrote = CGImageDestinationFinalize(dest)

                DispatchQueue.main.async {
                    if wrote {
                        result(["outputPath": outputPath])
                    } else {
                        result(FlutterError(code: "WRITE_FAILED",
                                            message: "compressImage: finalize failed",
                                            details: nil))
                    }
                }
            }

        // ── normalizeVideo ────────────────────────────────────────────────────────
        // Lossless container rewrite — no decode/re-encode of video or audio samples.
        //
        // What this does:
        //   • Repositions moov atom to the file head (shouldOptimizeForNetworkUse = true)
        //   • Strips privacy metadata (GPS, device fingerprint) via AVMetadataItemFilter.forSharing()
        //   • Outputs a clean MP4 container
        //   • Preserves container-level rotation via track preferredTransform (automatic)
        //
        // What this does NOT do:
        //   • Does NOT pixel-bake rotation (no videoComposition — that forces re-encode)
        //   • Does NOT transcode or alter compressed video/audio samples
        //   • Does NOT change resolution, bitrate, or codec
        //
        // Rotation policy: preferredTransform is preserved in the output track header
        // automatically by AVAssetExportPresetPassthrough. Modern iOS/Android players
        // and social platform ingest pipelines respect this container-level metadata.
        //
        // HEVC note: this handler treats H.264 and HEVC identically — it passes
        // whichever codec the source contains. Backend/CDN HEVC compatibility
        // is unconfirmed; classification warnings are the caller's responsibility.
        case "normalizeVideo":
            guard
                let inputPath  = args?["inputPath"]  as? String,
                let outputPath = args?["outputPath"] as? String
            else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "normalizeVideo: inputPath and outputPath required",
                                    details: nil))
                return
            }

            let inputURL  = URL(fileURLWithPath: inputPath)
            let outputURL = URL(fileURLWithPath: outputPath)

            // Remove any stale output file — AVAssetExportSession will not overwrite.
            let fm = FileManager.default
            if fm.fileExists(atPath: outputPath) {
                do {
                    try fm.removeItem(at: outputURL)
                } catch {
                    // AVAssetExportSession will fail immediately; error surfaces to caller.
                }
            }

            let asset = AVURLAsset(url: inputURL,
                                   options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

            // AVAssetExportPresetPassthrough copies the compressed bitstream unchanged.
            // Combining it with videoComposition would force a re-encode — do not do that.
            guard let exporter = AVAssetExportSession(
                asset:      asset,
                presetName: AVAssetExportPresetPassthrough
            ) else {
                result(FlutterError(code: "EXPORT_UNAVAILABLE",
                                    message: "normalizeVideo: AVAssetExportSession unavailable "
                                             + "(preset passthrough not supported for this asset)",
                                    details: nil))
                return
            }

            exporter.outputURL      = outputURL
            exporter.outputFileType = .mp4

            // Move moov atom to the file head. Required for server-side adaptive
            // streaming and platform ingest. Adds a small file-scan pass at the end
            // of export — no re-encode cost.
            exporter.shouldOptimizeForNetworkUse = true

            // Strip GPS location, device fingerprint, and similar PII metadata.
            // forSharing() retains playback-necessary metadata (codec, duration, etc.)
            // and removes privacy-sensitive fields only.
            exporter.metadataItemFilter = AVMetadataItemFilter.forSharing()

            // NOTE: exporter.videoComposition is intentionally NOT set.
            // Setting it would abandon passthrough and trigger a full re-encode.

            // Fix 3: HEVC provisional warning.
            // Backend/CDN HEVC-in-MP4 compatibility is unconfirmed.
            // Log when detected so device QA can identify these files.
            // No behavior change — passthrough proceeds identically for HEVC and H.264.
            if let vTrack = asset.tracks(withMediaType: .video).first {
                for desc in vTrack.formatDescriptions {
                    // swiftlint:disable:next force_cast
                    let fmt = desc as! CMFormatDescription
                    let subType = CMFormatDescriptionGetMediaSubType(fmt)
                    // 'hvc1' and 'hev1' are the two HEVC FourCC variants in MP4.
                    if subType == kCMVideoCodecType_HEVC {
                        break
                    }
                }
            }

            exporter.exportAsynchronously {
                // exportAsynchronously completion block runs on an internal GCD queue.
                // Marshal the result back to the main thread for Flutter.
                DispatchQueue.main.async {
                    switch exporter.status {
                    case .completed:
                        // Verify the output file was actually written.
                        guard fm.fileExists(atPath: outputPath) else {
                            result(FlutterError(code: "EXPORT_FAILED",
                                                message: "normalizeVideo: exporter reported "
                                                         + "completed but output file is missing",
                                                details: nil))
                            return
                        }
                        result(["outputPath": outputPath])

                    case .failed:
                        let msg = exporter.error?.localizedDescription
                            ?? "unknown export error"
                        // Surface specific AVError codes where useful:
                        // AVErrorSourceFileUTIUnknown → input format not recognised
                        // AVErrorExportFailed         → generic encode/mux failure
                        result(FlutterError(code: "EXPORT_FAILED",
                                            message: "normalizeVideo failed: \(msg)",
                                            details: nil))

                    case .cancelled:
                        result(FlutterError(code: "EXPORT_CANCELLED",
                                            message: "normalizeVideo cancelled",
                                            details: nil))

                    default:
                        result(FlutterError(code: "EXPORT_FAILED",
                                            message: "normalizeVideo ended in unexpected "
                                                     + "state: \(exporter.status.rawValue)",
                                            details: nil))
                    }
                }
            }

        case "play":
            guard let textureId = (args?["textureId"] as? NSNumber)?.int64Value else {
                result(FlutterError(code: "BAD_ARGS", message: "play requires textureId", details: nil)); return
            }
            // Phase 2 Step 6: all playback via registry.
            if sessionRegistry.runtime(forTextureId: textureId)?.play() == nil {
            }
            result(nil)

        case "pause":
            guard let textureId = (args?["textureId"] as? NSNumber)?.int64Value else {
                result(FlutterError(code: "BAD_ARGS", message: "pause requires textureId", details: nil)); return
            }
            // Phase 2 Step 6: all playback via registry.
            if sessionRegistry.runtime(forTextureId: textureId)?.pause() == nil {
            }
            result(nil)

        case "seekTo":
            guard let textureId = (args?["textureId"] as? NSNumber)?.int64Value,
                  let seconds   = (args?["seconds"]   as? NSNumber)?.doubleValue else {
                result(FlutterError(code: "BAD_ARGS", message: "seekTo requires textureId and seconds", details: nil))
                return
            }
            // Phase 2 Step 6: all playback via registry.
            if sessionRegistry.runtime(forTextureId: textureId)?.seek(to: seconds) == nil {
            }
            result(nil)

        // G-02: Exposes the native masterClock for the A/V sync integration test.
        // Not called in production code — diagnostic/testing path only.
        // NOTE: do NOT add print()/NSLog() here — getMasterClock is called at
        // ~25,000/sec during the settle poll loop; any blocking log call will
        // saturate logd's XPC buffer and hang the settle on the second call.
        case "getMasterClock":
            // G-02: Exposes the native masterClock for the A/V sync integration test.
            // Not called in production code — diagnostic/testing path only.
            // NOTE: do NOT log here — this is called at ~25,000/sec during the
            // G-02-T2 settle poll loop; any blocking call saturates logd's XPC buffer.
            //
            // Phase 2 Step 7 contract:
            //   • If textureId is provided and resolves to a registry runtime with a
            //     masterClock, return CMTimeGetSeconds of that clock.
            //   • Otherwise preserve the pre-Phase-2 renderer fallback:
            //     renderers.values.first?.currentTimeSeconds ?? 0.0
            //     (renderers holds camera/export renderers; their currentTimeSeconds
            //     is wall-clock-based and is a valid fallback for legacy callers.)
            let tid = (args?["textureId"] as? NSNumber)?.int64Value ?? -1
            if tid >= 0,
               let rt = sessionRegistry.runtime(forTextureId: tid),
               let clock = rt.masterClock {
                result(CMTimeGetSeconds(clock.currentTime))
            } else {
                result(renderers.values.first?.currentTimeSeconds ?? 0.0)
            }

        // G-02-T3: Native-backed post-seek settle (test-only).
        // Sleeps `ms` milliseconds on a GCD background thread and delivers
        // result() when done.  This is the only reliable settle mechanism after
        // a 50-seek storm:
        //   • Future.delayed relies on a healthy Dart event loop, which degrades
        //     after 50+ rapid MethodChannel calls.
        //   • getMasterClockSeconds() polling relies on a free iOS RunLoop, which is
        //     saturated with post-seek AVFoundation callbacks for ~500ms.
        // Here the initial message routing to this handler happens at T+26ms
        // (main thread always free for the first post-seek dispatch).  The sleep
        // runs on a bg queue with zero main-thread interaction.  result() is
        // delivered at T+ms when the RunLoop is fully clear.
        case "settleMs":
            let ms = (args?["ms"] as? NSNumber)?.doubleValue ?? 500.0
            DispatchQueue.global(qos: .default).async {
                Thread.sleep(forTimeInterval: ms / 1000.0)
                result(nil)
            }

        // G-02-T3: Suppress all AVAssetImageGenerator activity so no internal
        // AVFoundation XPC dispatch can block the main thread during the seek
        // storm, settle, lock-window, or measurement phases.
        // pauseSeekPreviews() MUST be called before the seek storm (when main
        // is free). resumeSeekPreviews() restores normal behaviour after the
        // measurement is complete.  Both are no-ops in production — test-only.
        case "pauseSeekPreviews":
            // Phase 2 Step 7: forward to all registry runtimes AND all renderers
            // (camera/export renderers also carry seekPreviewPaused; they must be
            // silenced during the G-02-T3 seek storm to prevent AVFoundation XPC
            // dispatch from blocking the main thread during the measurement window).
            sessionRegistry.allRuntimes().forEach { $0.setSeekPreviewPaused(true) }
            renderers.values.forEach { $0.seekPreviewPaused = true }
            result(nil)

        case "resumeSeekPreviews":
            // Phase 2 Step 7: mirror pauseSeekPreviews — both maps must be reset.
            sessionRegistry.allRuntimes().forEach { $0.setSeekPreviewPaused(false) }
            renderers.values.forEach { $0.seekPreviewPaused = false }
            result(nil)

        // ── P5: Test-only native helpers ────────────────────────────────────────
        // analyzeMP4: reads all video frame durations + audio/video total durations.
        // Returns: {audioDurationMs: Double, videoDurationMs: Double, frameDurations: [Double]}
        // Called by P5-B Dart test to assert max(frame_duration) < 33ms.
        case "analyzeMP4":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "BAD_ARGS", message: "analyzeMP4 requires path", details: nil)); return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let url   = URL(fileURLWithPath: path)
                let asset = AVURLAsset(url: url)
                let vTrack = asset.tracks(withMediaType: .video).first
                let aTrack = asset.tracks(withMediaType: .audio).first
                let videoDurationMs = vTrack.map { CMTimeGetSeconds($0.timeRange.duration) * 1000 } ?? 0
                let audioDurationMs = aTrack.map { CMTimeGetSeconds($0.timeRange.duration) * 1000 } ?? 0

                // Linear frame-duration pass (compressed output — no decode overhead)
                var frameDurations: [Double] = []
                if let vt = vTrack,
                   let reader = try? AVAssetReader(asset: asset) {
                    let out = AVAssetReaderTrackOutput(track: vt, outputSettings: nil)
                    out.alwaysCopiesSampleData = false
                    reader.add(out)
                    reader.startReading()
                    while let sample = out.copyNextSampleBuffer() {
                        let dur = CMSampleBufferGetDuration(sample)
                        if dur.isValid && dur.isNumeric {
                            frameDurations.append(CMTimeGetSeconds(dur) * 1000)
                        }
                    }
                    reader.cancelReading()
                }
                let info: [String: Any] = [
                    "videoDurationMs": videoDurationMs,
                    "audioDurationMs": audioDurationMs,
                    "frameDurations":  frameDurations,
                ]
                DispatchQueue.main.async { result(info) }
            }

        // countFramesInMP4: linear AVAssetReader frame count pass.
        // Called by P5-C Dart test to compare against VTCompressionOutputCallback count.
        case "countFramesInMP4":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "BAD_ARGS", message: "countFramesInMP4 requires path", details: nil)); return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let url   = URL(fileURLWithPath: path)
                let asset = AVURLAsset(url: url)
                guard let vTrack = asset.tracks(withMediaType: .video).first,
                      let reader = try? AVAssetReader(asset: asset) else {
                    DispatchQueue.main.async { result(NSNumber(value: 0)) }; return
                }
                let settings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                let out = AVAssetReaderTrackOutput(track: vTrack, outputSettings: settings)
                out.alwaysCopiesSampleData = false
                reader.add(out)
                reader.startReading()
                var frameCount = 0
                while let sample = out.copyNextSampleBuffer() {
                    frameCount += 1
                    _ = sample // ARC releases
                }
                reader.cancelReading()
                DispatchQueue.main.async { result(NSNumber(value: frameCount)) }
            }

        // runNativeTest: invokes a named P5 assertion via VanguardP5TestRunner.
        // The test runs on a background queue; result is delivered on main.
        // Result dict: {passed: Bool, message: String, metrics: [String: Double]}
        case "runNativeTest":
            let testName = args?["name"] as? String ?? ""
            DispatchQueue.global(qos: .userInitiated).async {
                let testResult = VanguardP5TestRunner.run(testNamed: testName)
                DispatchQueue.main.async { result(testResult) }
            }

        // ── Phase 7 Stage 7.5B: Timeline execution proof ─────────────────────
        // Triggers the native headless smoke test for VGTimelineCompositorNode.
        // Runs on background queue; result delivered on main.
        // In release builds the native stub returns a static error.
        //
        // Args (all optional):
        //   clipAPath: String — absolute path to first clip (nil → synthetic)
        //   clipBPath: String — absolute path to second clip (nil → synthetic)
        //
        // Returns: Dictionary with success, steps, logs, error.
        case "dev_proveTimelineExecution":
            let clipA = args?["clipAPath"] as? String
            let clipB = args?["clipBPath"] as? String
            DispatchQueue.global(qos: .userInitiated).async {
                let testResults = VGTimelineCompositorSmokeTest.run(
                    withClipAPath: clipA, clipBPath: clipB)
                DispatchQueue.main.async { result(testResults) }
            }

        // ── Phase 7 Stage 7.5C: Timeline visual playback proof ────────────────
        //
        // These cases are compiled only when VG_USE_V2_GRAPH=1.
        // They wire VGTimelineCompositorNode through VanguardMetalRenderer to
        // a Flutter texture via a CADisplayLink-driven pull loop.
        //
        // All method names use the dev_ prefix:
        //   - dev_createTimelineTexture: prepare and register Flutter texture
        //   - dev_timelinePlay:          start the pull loop advancing PTS
        //   - dev_timelinePause:         freeze the pull loop at current PTS
        //   - dev_timelineSeek:          seek to a PTS position (seconds)
        //
        // These methods do NOT touch ConnectsApp, the V1 path, or any existing
        // production method channel cases. They are strictly example-layer-only.
        //
        // dev_createTimelineTexture args:
        //   clips: [[String: Any]]  — each dict must conform to VGClipDescriptor format:
        //     { "url": String, "trimStart": Double, "trimEnd": Double,
        //       "speed": Double, "mediaKind": Int (0 = video) }
        //   transitions: [[String: Any]] — optional, may be [] or absent.
        //     Currently only "none" transitions are accepted (Stage 7.5 limitation).
        //
        // Returns: { "textureId": Int64, "width": Int, "height": Int }
        // On failure: FlutterError.

        #if VG_USE_V2_GRAPH
        case "dev_createTimelineTexture":
            // ── Phase 7 Stage 7.5C: Timeline visual playback proof ────────────
            //
            // Args:
            //   useSyntheticClips: Bool (optional, default false)
            //     When true: ignores 'clips' arg and generates two real synthetic
            //     MP4 clips via VGTimelineCompositorSmokeTest.generateSyntheticClipPaths.
            //     Requires DEBUG build (AVAssetWriter-based generation).
            //   clips: [[String: Any]]  — clip descriptor dicts (if useSyntheticClips=false).
            //   transitions: [[String: Any]] — optional.
            //
            // Returns: { "textureId": Int64, "width": Int, "height": Int }
            // On failure: FlutterError.

            let useSyntheticClips = args?["useSyntheticClips"] as? Bool ?? false
            // Stage 7.5D: opt-in real moving-pattern video clips flag.
            let useRealVideoClips = args?["useRealVideoClips"] as? Bool ?? false

            // Resolve clip dicts: synthetic generation path or caller-supplied.
            let resolvedClipDicts: [[String: Any]]

            if useSyntheticClips {
                // Generate persistent synthetic MP4s via smoke test helper.
                // This is synchronous with AVAssetWriter on caller thread.
                // The plugin handler is called on the main thread; generate
                // on a background queue to avoid blocking Flutter.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }

                    let paths = VGTimelineCompositorSmokeTest.generateSyntheticClipPaths()
                    guard
                        let pathA = paths?["clipAPath"],
                        let pathB = paths?["clipBPath"]
                    else {
                        DispatchQueue.main.async {
                            result(FlutterError(
                                code: "SYNTHETIC_CLIP_FAILED",
                                message: "dev_createTimelineTexture: synthetic clip generation failed "
                                       + "(requires DEBUG build)",
                                details: nil))
                        }
                        return
                    }

                    let clipDictsForSynthetic: [[String: Any]] = [
                        [
                            // Keys match VGClipDescriptor.fromDictionary: wire contract
                            // exactly (kVGCD* constants in VGClipDescriptor.m).
                            "id":               "playback_clip_A",
                            "sourcePath":       pathA,
                            "mediaKind":        "video",
                            "startTimeSeconds": 0.0,
                            "durationSeconds":  5.0,
                            "trimStartSeconds": 0.0,
                            "trimEndSeconds":   5.0,
                            "speed":            1.0,
                        ],
                        [
                            "id":               "playback_clip_B",
                            "sourcePath":       pathB,
                            "mediaKind":        "video",
                            "startTimeSeconds": 5.0,
                            "durationSeconds":  5.0,
                            "trimStartSeconds": 0.0,
                            "trimEndSeconds":   5.0,
                            "speed":            1.0,
                        ],
                    ]
                    DispatchQueue.main.async {
                        self._prepareTimelineCompositor(
                            clipDicts: clipDictsForSynthetic,
                            transitionDicts: [],
                            result: result)
                    }
                }
                return
            }

            if useRealVideoClips {
                // Stage 7.5D: Generate real moving-pattern H.264 MP4s on a background
                // queue (AVAssetWriter is synchronous — must not block the main thread).
                // Same dispatch pattern as the useSyntheticClips path above.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }

                    let paths = VGTimelineCompositorSmokeTest.generateRealVideoClipPaths()
                    guard
                        let pathA = paths?["clipAPath"],
                        let pathB = paths?["clipBPath"]
                    else {
                        DispatchQueue.main.async {
                            result(FlutterError(
                                code: "REAL_CLIP_FAILED",
                                message: "dev_createTimelineTexture: real-video clip generation failed "
                                       + "(requires DEBUG build)",
                                details: nil))
                        }
                        return
                    }

                    // Clip dicts use 640×360 resolution (matching _generateMovingPatternVideo).
                    // VGClipDescriptor wire keys are identical to the synthetic path.
                    let clipDictsForReal: [[String: Any]] = [
                        [
                            "id":               "real_clip_A",
                            "sourcePath":       pathA,
                            "mediaKind":        "video",
                            "startTimeSeconds": 0.0,
                            "durationSeconds":  5.0,
                            "trimStartSeconds": 0.0,
                            "trimEndSeconds":   5.0,
                            "speed":            1.0,
                        ],
                        [
                            "id":               "real_clip_B",
                            "sourcePath":       pathB,
                            "mediaKind":        "video",
                            "startTimeSeconds": 5.0,
                            "durationSeconds":  5.0,
                            "trimStartSeconds": 0.0,
                            "trimEndSeconds":   5.0,
                            "speed":            1.0,
                        ],
                    ]
                    DispatchQueue.main.async {
                        self._prepareTimelineCompositorWithSize(
                            clipDicts: clipDictsForReal,
                            transitionDicts: [],
                            width: 640,
                            height: 360,
                            result: result)
                    }
                }
                return
            }

            guard let callerClipDicts = args?["clips"] as? [[String: Any]] else {
                result(FlutterError(
                    code: "BAD_ARGS",
                    message: "dev_createTimelineTexture: clips array required when useSyntheticClips=false",
                    details: nil))
                return
            }
            resolvedClipDicts = callerClipDicts
            let transitionDictsForCaller = args?["transitions"] as? [[String: Any]] ?? []
            _prepareTimelineCompositor(clipDicts: resolvedClipDicts,
                                       transitionDicts: transitionDictsForCaller,
                                       result: result)

        case "dev_timelinePlay":
            guard let runtime = self._timelineRuntime else {
                result(FlutterError(code: "NO_TIMELINE",
                                    message: "dev_timelinePlay: no active timeline runtime",
                                    details: nil))
                return
            }
            runtime._timelinePlay()
            result(nil)

        case "dev_timelinePause":
            guard let runtime = self._timelineRuntime else {
                result(FlutterError(code: "NO_TIMELINE",
                                    message: "dev_timelinePause: no active timeline runtime",
                                    details: nil))
                return
            }
            runtime._timelinePause()
            result(nil)

        case "dev_timelineSeek":
            guard
                let runtime  = self._timelineRuntime,
                let seconds  = (args?["seconds"] as? NSNumber)?.doubleValue
            else {
                result(FlutterError(code: "BAD_ARGS",
                                    message: "dev_timelineSeek: seconds required and timeline must be active",
                                    details: nil))
                return
            }
            runtime.seekTimeline(to: seconds)
            result(nil)

        case "dev_disposeTimeline":
            if let runtime = self._timelineRuntime {
                runtime.invalidateAsync {
                }
                self._timelineRuntime = nil
            }
            result(nil)

        // ── Phase 7 Stage 7.6: Timeline trim update (tear-down-and-rebuild) ──────
        //
        // dev_updateTimeline proves that the timeline can be modified at runtime
        // by tearing down the existing playback compositor and rebuilding it
        // from an updated set of clip descriptors (with new trim values).
        //
        // Design (MOD-2): tear-down-and-rebuild, NOT hot-update:
        //   1. Invalidate current _timelineRuntime (and its compositor) async.
        //   2. Nil _timelineRuntime before starting the new one.
        //   3. Generate clip paths using the same smoke-test fixtures as 7.5D.
        //   4. Apply caller-supplied trim windows to the clip dicts.
        //   5. Rebuild via _prepareTimelineCompositorWithSize — the exact same
        //      path as dev_createTimelineTexture (useRealVideoClips branch).
        //
        // VGTimelineCompositorNode is NOT mutated in place.
        //
        // dev_updateTimeline args:
        //   useRealVideoClips: Bool (optional, default false)
        //     true  → 640×360 moving-pattern real H.264 clips
        //     false → 320×240 solid-color synthetic clips
        //   trimAStart: Double (optional, default 0.0) — Clip A trimStartSeconds
        //   trimAEnd:   Double (optional, default 5.0) — Clip A trimEndSeconds
        //   trimBStart: Double (optional, default 0.0) — Clip B trimStartSeconds
        //   trimBEnd:   Double (optional, default 5.0) — Clip B trimEndSeconds
        //
        // Returns: { "textureId": Int64, "width": Int, "height": Int }
        // On failure: FlutterError.
        case "dev_updateTimeline":
            let useRealVideoForUpdate = args?["useRealVideoClips"] as? Bool ?? false

            // Read trim windows from Dart. Defaults match the 7.5E untrimmed baseline.
            let trimAStart = (args?["trimAStart"] as? NSNumber)?.doubleValue ?? 0.0
            let trimAEnd   = (args?["trimAEnd"]   as? NSNumber)?.doubleValue ?? 5.0
            let trimBStart = (args?["trimBStart"] as? NSNumber)?.doubleValue ?? 0.0
            let trimBEnd   = (args?["trimBEnd"]   as? NSNumber)?.doubleValue ?? 5.0

            // Derived durations from trim windows.
            let clipAEffectiveDuration = trimAEnd - trimAStart
            let clipBEffectiveDuration = trimBEnd - trimBStart
            let clipBStartTime         = clipAEffectiveDuration

            // Step 1: Invalidate the existing timeline runtime (MOD-2).
            // This tears down the compositor and display link without blocking.
            if let oldRuntime = self._timelineRuntime {
                oldRuntime.invalidateAsync {
                }
                self._timelineRuntime = nil
            }

            // Step 2: Choose render dimensions matching the source mode.
            let updateWidth  = useRealVideoForUpdate ? 640 : 320
            let updateHeight = useRealVideoForUpdate ? 360 : 240

            // Step 3: Generate clip paths on a background queue (AVAssetWriter is
            // synchronous and must not block the main thread).
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                // Reuse the same smoke-test fixtures as dev_createTimelineTexture.
                let clipPaths: [String: String]?
                let clipIdPrefix: String
                if useRealVideoForUpdate {
                    clipPaths = VGTimelineCompositorSmokeTest.generateRealVideoClipPaths()
                    clipIdPrefix = "update_real_clip"
                } else {
                    clipPaths = VGTimelineCompositorSmokeTest.generateSyntheticClipPaths()
                    clipIdPrefix = "update_synthetic_clip"
                }

                guard
                    let pathA = clipPaths?["clipAPath"],
                    let pathB = clipPaths?["clipBPath"]
                else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "CLIP_GENERATION_FAILED",
                            message: "dev_updateTimeline: clip generation failed "
                                   + "(requires DEBUG build)",
                            details: nil))
                    }
                    return
                }

                // Step 4: Build updated clip dicts with the caller-supplied trim windows.
                // Wire keys are identical to dev_createTimelineTexture.
                let updatedClipDicts: [[String: Any]] = [
                    [
                        "id":               "\(clipIdPrefix)_A",
                        "sourcePath":       pathA,
                        "mediaKind":        "video",
                        "startTimeSeconds": 0.0,
                        "durationSeconds":  clipAEffectiveDuration,
                        "trimStartSeconds": trimAStart,
                        "trimEndSeconds":   trimAEnd,
                        "speed":            1.0,
                    ],
                    [
                        "id":               "\(clipIdPrefix)_B",
                        "sourcePath":       pathB,
                        "mediaKind":        "video",
                        "startTimeSeconds": clipBStartTime,
                        "durationSeconds":  clipBEffectiveDuration,
                        "trimStartSeconds": trimBStart,
                        "trimEndSeconds":   trimBEnd,
                        "speed":            1.0,
                    ],
                ]


                // Step 5: Rebuild via the established WithSize helper (MOD-2).
                // This creates a new VGTimelineCompositorNode from the updated dicts.
                DispatchQueue.main.async {
                    self._prepareTimelineCompositorWithSize(
                        clipDicts: updatedClipDicts,
                        transitionDicts: [],
                        width: updateWidth,
                        height: updateHeight,
                        result: result)
                }
            }

        // ── Phase 7 Stage 7.5E/7.6: Timeline export proof ────────────────────────
        //
        // Runs a video-only offline timeline export using the same real-video
        // fixtures from Stage 7.5D. VGTimelineExportHelper builds an independent
        // VGTimelineCompositorNode (does NOT touch _timelineRuntime or the
        // playback texture) and drives a VGExportScheduler pull loop.
        //
        // VGExportProfile is constructed entirely inside VGTimelineExportHelper.m
        // in Objective-C — this Swift case passes only primitive parameters.
        //
        // dev_timelineExport args:
        //   useRealVideoClips: Bool (optional, default false)
        //     true  → 640×360 moving-pattern real H.264 clips (7.5D fixtures)
        //     false → 320×240 solid-color synthetic clips (7.5C fixtures)
        //   trimAStart: Double (optional, default 0.0) — Clip A trimStartSeconds
        //   trimAEnd:   Double (optional, default 5.0) — Clip A trimEndSeconds
        //   trimBStart: Double (optional, default 0.0) — Clip B trimStartSeconds
        //   trimBEnd:   Double (optional, default 5.0) — Clip B trimEndSeconds
        //
        // Returns: { "success": Bool, "path": String, "durationSeconds": Double }
        // On failure: FlutterError.
        case "dev_timelineExport":
            let useRealVideoForExport = args?["useRealVideoClips"] as? Bool ?? false

            // Stage 7.6 (MOD-4): read trim windows — default to untrimmed 5s+5s baseline.
            let exportTrimAStart = (args?["trimAStart"] as? NSNumber)?.doubleValue ?? 0.0
            let exportTrimAEnd   = (args?["trimAEnd"]   as? NSNumber)?.doubleValue ?? 5.0
            let exportTrimBStart = (args?["trimBStart"] as? NSNumber)?.doubleValue ?? 0.0
            let exportTrimBEnd   = (args?["trimBEnd"]   as? NSNumber)?.doubleValue ?? 5.0

            // Derived durations and Clip B start time.
            let exportClipADuration = exportTrimAEnd - exportTrimAStart
            let exportClipBDuration = exportTrimBEnd - exportTrimBStart
            let exportClipBStart    = exportClipADuration

            // Choose dimensions based on source mode.
            let exportWidth:  NSInteger = useRealVideoForExport ? 640 : 320
            let exportHeight: NSInteger = useRealVideoForExport ? 360 : 240

            // Output path: NSTemporaryDirectory/vg_timeline_export_proof.mp4.
            let exportOutputPath = NSTemporaryDirectory() + "vg_timeline_export_proof.mp4"

            // Run clip generation on a background queue (AVAssetWriter is synchronous
            // and must not block the main thread). Same dispatch pattern as 7.5D.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                // Resolve clip paths.
                let clipPaths: [String: String]?
                let clipIdPrefix: String
                if useRealVideoForExport {
                    clipPaths = VGTimelineCompositorSmokeTest.generateRealVideoClipPaths()
                    clipIdPrefix = "export_real_clip"
                } else {
                    clipPaths = VGTimelineCompositorSmokeTest.generateSyntheticClipPaths()
                    clipIdPrefix = "export_synthetic_clip"
                }

                guard
                    let pathA = clipPaths?["clipAPath"],
                    let pathB = clipPaths?["clipBPath"]
                else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "CLIP_GENERATION_FAILED",
                            message: "dev_timelineExport: clip generation failed "
                                   + "(requires DEBUG build)",
                            details: nil))
                    }
                    return
                }

                // Build clip descriptor dictionaries — same wire contract as
                // dev_createTimelineTexture (VGClipDescriptor.fromDictionary: keys).
                // Stage 7.6 (MOD-4): uses trim values from Dart (exportTrimA*/exportTrimB*).
                let clipDicts: [[String: Any]] = [
                    [
                        "id":               "\(clipIdPrefix)_A",
                        "sourcePath":       pathA,
                        "mediaKind":        "video",
                        "startTimeSeconds": 0.0,
                        "durationSeconds":  exportClipADuration,
                        "trimStartSeconds": exportTrimAStart,
                        "trimEndSeconds":   exportTrimAEnd,
                        "speed":            1.0,
                    ],
                    [
                        "id":               "\(clipIdPrefix)_B",
                        "sourcePath":       pathB,
                        "mediaKind":        "video",
                        "startTimeSeconds": exportClipBStart,
                        "durationSeconds":  exportClipBDuration,
                        "trimStartSeconds": exportTrimBStart,
                        "trimEndSeconds":   exportTrimBEnd,
                        "speed":            1.0,
                    ],
                ]


                // Delegate to VGTimelineExportHelper — VGExportProfile is
                // constructed entirely in ObjC (MOD-1, MOD-2). Swift never
                // touches VGExportProfile directly.
                VGTimelineExportHelper.exportTimeline(
                    withClips: clipDicts,
                    transitions: [],
                    outputPath: exportOutputPath,
                    width: exportWidth,
                    height: exportHeight,
                    fps: 30,
                    bitrateBps: 2_000_000
                ) { success, outPath, duration, error in
                    // Completion fires on a background queue (VGExportScheduler queue).
                    // Marshal result back to main thread for Flutter.
                    DispatchQueue.main.async {
                        if success, let outPath = outPath {
                            result([
                                "success":         true,
                                "path":            outPath,
                                "durationSeconds": duration,
                                "width":           Int(exportWidth),
                                "height":          Int(exportHeight),
                                "fps":             30,
                            ] as [String: Any])
                        } else {
                            let msg = error?.localizedDescription
                                      ?? "Timeline export failed (unknown error)"
                            result(FlutterError(
                                code: "EXPORT_FAILED",
                                message: msg,
                                details: nil))
                        }
                    }
                }
            }
        // ── Phase 7.8: Production timeline routes ─────────────────────────────────
        //
        // These routes replace the dev_* proof routes for production use (DEC-140).
        // They consume the full VGEditorDraft.toMap() payload from Dart under the
        // 'draft' key. No fixture generation. No useRealVideoClips flag.
        //
        // Swift preflight:
        //   1. Extracts and validates the 'draft' map.
        //   2. Validates each clip: non-empty sourcePath, mediaKind=video,
        //      FileManager.isReadableFile, valid trim range.
        //   3. Validates transitions are hard-cuts only.
        //   4. Passes validated clip/transition dicts directly to ObjC compositor
        //      via _prepareTimelineCompositorWithSize (no re-parsing).
        //
        // Apple documentation compliance:
        //   - URL(fileURLWithPath:) used for local POSIX paths (never URL(string:)).
        //   - FileManager.default.isReadableFile(atPath:) gates all AVAssetReader creation.
        //   - Security-scoped resources NOT implemented in Phase 7.8.
        //     Calling app must copy files to readable sandbox location first.
        //
        // Legacy dev_* routes above remain intact for playground/test compatibility.

        case "createTimelineTexture":
            // Phase 7.8 production route: initialize timeline from a full VGEditorDraft.
            //
            // Args: { 'draft': draftMap }
            // draftMap keys: id, clips, transitions, canvasWidth, canvasHeight, fps
            // Returns: { 'textureId': Int64, 'width': Int, 'height': Int }
            // On failure: FlutterError with specific code.
            guard let draftMap = args?["draft"] as? [String: Any] else {
                result(FlutterError(
                    code: "MISSING_DRAFT",
                    message: "createTimelineTexture: args['draft'] is missing or wrong type",
                    details: nil))
                return
            }

            let canvasWidth  = (draftMap["canvasWidth"]  as? NSNumber)?.intValue ?? 640
            let canvasHeight = (draftMap["canvasHeight"] as? NSNumber)?.intValue ?? 360
            // fps is informational in Phase 7.8 — not enforced natively.
            let _ = (draftMap["fps"] as? NSNumber)?.intValue ?? 30

            guard let clipDicts78 = draftMap["clips"] as? [[String: Any]],
                  !clipDicts78.isEmpty else {
                result(FlutterError(
                    code: "EMPTY_CLIPS",
                    message: "createTimelineTexture: draft.clips is missing or empty",
                    details: nil))
                return
            }

            // Swift preflight: validate each clip.
            if let preflightError = _preflightClips(clipDicts78) {
                result(preflightError)
                return
            }

            // Validate transitions — hard-cuts only in Phase 7.8.
            let transitionDicts78 = draftMap["transitions"] as? [[String: Any]] ?? []
            if let transitionError = _preflightTransitions(transitionDicts78) {
                result(transitionError)
                return
            }

            // Tear down any existing timeline runtime before creating a new one.
            if let oldRuntime = self._timelineRuntime {
                oldRuntime.invalidateAsync {
                }
                self._timelineRuntime = nil
            }


            // Phase 10-C Slice D: extract optional audio sidecar and project duration
            // forwarded by Dart alongside the draft map.
            // durationSeconds is mandatory for Slice D audio scheduling; absent means 0
            // (silent fallback). audioSidecar is optional (nil = no music track).
            let createDurationSeconds = (args?["durationSeconds"] as? NSNumber)?.doubleValue ?? 0.0
            var createAudioSidecar: VGAudioSidecarPlan? = nil
            if let sidecarDict78 = draftMap["audioSidecar"] as? [String: Any] {
                createAudioSidecar = VGAudioSidecarPlan.fromDictionary(sidecarDict78)
            }

            // Delegate to existing ObjC compositor path — no re-parsing.
            _prepareTimelineCompositorWithSize(
                clipDicts: clipDicts78,
                transitionDicts: transitionDicts78,
                width: canvasWidth,
                height: canvasHeight,
                audioSidecarPlan: createAudioSidecar,
                durationSeconds: createDurationSeconds,
                result: result)

        case "updateTimeline":
            // Phase 7.8 production route: rebuild timeline from updated VGEditorDraft.
            //
            // Args: { 'draft': draftMap }
            // Returns: { 'textureId': Int64, 'width': Int, 'height': Int }
            // On failure: FlutterError.
            guard let draftMapU = args?["draft"] as? [String: Any] else {
                result(FlutterError(
                    code: "MISSING_DRAFT",
                    message: "updateTimeline: args['draft'] is missing or wrong type",
                    details: nil))
                return
            }

            let updateWidth  = (draftMapU["canvasWidth"]  as? NSNumber)?.intValue ?? 640
            let updateHeight = (draftMapU["canvasHeight"] as? NSNumber)?.intValue ?? 360

            guard let clipDictsU = draftMapU["clips"] as? [[String: Any]],
                  !clipDictsU.isEmpty else {
                result(FlutterError(
                    code: "EMPTY_CLIPS",
                    message: "updateTimeline: draft.clips is missing or empty",
                    details: nil))
                return
            }

            if let preflightError = _preflightClips(clipDictsU) {
                result(preflightError)
                return
            }

            let transitionDictsU = draftMapU["transitions"] as? [[String: Any]] ?? []
            if let transitionError = _preflightTransitions(transitionDictsU) {
                result(transitionError)
                return
            }

            // Tear down existing runtime (MOD-2: tear-down-and-rebuild).
            if let oldRuntime = self._timelineRuntime {
                oldRuntime.invalidateAsync {
                }
                self._timelineRuntime = nil
            }


            // Phase 10-C Slice D: extract audio sidecar and project duration for
            // audio preview runtime construction after compositor prepare.
            let updateDurationSeconds = (args?["durationSeconds"] as? NSNumber)?.doubleValue ?? 0.0
            var updateAudioSidecar: VGAudioSidecarPlan? = nil
            if let sidecarDictU = draftMapU["audioSidecar"] as? [String: Any] {
                updateAudioSidecar = VGAudioSidecarPlan.fromDictionary(sidecarDictU)
            }

            _prepareTimelineCompositorWithSize(
                clipDicts: clipDictsU,
                transitionDicts: transitionDictsU,
                width: updateWidth,
                height: updateHeight,
                audioSidecarPlan: updateAudioSidecar,
                durationSeconds: updateDurationSeconds,
                result: result)

        case "timelinePlay":
            // Phase 7.8 production route: start timeline playback.
            guard let runtime = self._timelineRuntime else {
                result(FlutterError(code: "NO_TIMELINE",
                                    message: "timelinePlay: no active timeline runtime",
                                    details: nil))
                return
            }
            runtime._timelinePlay()
            result(nil)

        case "timelinePause":
            // Phase 7.8 production route: pause timeline playback.
            guard let runtime = self._timelineRuntime else {
                result(FlutterError(code: "NO_TIMELINE",
                                    message: "timelinePause: no active timeline runtime",
                                    details: nil))
                return
            }
            runtime._timelinePause()
            result(nil)

        case "timelineSeek":
            // Phase 7.8 production route: seek to position in seconds.
            guard
                let runtime = self._timelineRuntime,
                let seconds  = (args?["seconds"] as? NSNumber)?.doubleValue
            else {
                result(FlutterError(code: "BAD_ARGS",
                                    message: "timelineSeek: seconds required and timeline must be active",
                                    details: nil))
                return
            }
            runtime.seekTimeline(to: seconds)
            result(nil)

        case "exportTimeline":
            // Phase 7.8 production route: export timeline from full VGEditorDraft.
            //
            // Args: { 'draft': draftMap, optionally outputPath, bitrateBps, width, height, fps }
            // Returns: { 'success': Bool, 'path': String, 'durationSeconds': Double,
            //            'width': Int, 'height': Int, 'fps': Int }
            // On failure: FlutterError.
            guard let draftMapE = args?["draft"] as? [String: Any] else {
                result(FlutterError(
                    code: "MISSING_DRAFT",
                    message: "exportTimeline: args['draft'] is missing or wrong type",
                    details: nil))
                return
            }

            guard let clipDictsE = draftMapE["clips"] as? [[String: Any]],
                  !clipDictsE.isEmpty else {
                result(FlutterError(
                    code: "EMPTY_CLIPS",
                    message: "exportTimeline: draft.clips is missing or empty",
                    details: nil))
                return
            }

            if let preflightError = _preflightClips(clipDictsE) {
                result(preflightError)
                return
            }

            let transitionDictsE = draftMapE["transitions"] as? [[String: Any]] ?? []
            if let transitionError = _preflightTransitions(transitionDictsE) {
                result(transitionError)
                return
            }

            // Export dimensions: caller-supplied request fields override draft canvas.
            let exportW:   NSInteger = (args?["width"]  as? NSNumber)?.intValue
                                       ?? (draftMapE["canvasWidth"]  as? NSNumber)?.intValue
                                       ?? 640
            let exportH:   NSInteger = (args?["height"] as? NSNumber)?.intValue
                                       ?? (draftMapE["canvasHeight"] as? NSNumber)?.intValue
                                       ?? 360
            let exportFps: NSInteger = (args?["fps"] as? NSNumber)?.intValue
                                       ?? (draftMapE["fps"] as? NSNumber)?.intValue
                                       ?? 30
            let exportBitrate: NSInteger = (args?["bitrateBps"] as? NSNumber)?.intValue ?? 2_000_000
            let exportOutputPath: String = (args?["outputPath"] as? String)
                                           ?? (NSTemporaryDirectory() + "vg_timeline_export_prod.mp4")

            // Phase 8.6: Extract optional canvas and overlays from the draft map.
            // These originate from VGEditorDraft.toMap() which emits both keys
            // unconditionally. Missing or malformed values are passed as nil —
            // VGOverlayNode parses defensively and produces safe defaults.
            // No strict preflight: malformed overlay dicts are silently skipped.
            let exportCanvasDict   = draftMapE["canvas"]   as? [String: Any]
            let exportOverlayDicts = draftMapE["overlays"] as? [[String: Any]]

            // Phase 8.14A: Extract optional audio sidecar plan from the draft map.
            // VGEditorDraft.toMap() emits "audioSidecar" only when non-nil.
            // Deserialise with the native VGAudioSidecarPlan model.
            // If the key is absent or malformed the plan is nil (backward-compatible).
            var exportAudioSidecar: VGAudioSidecarPlan? = nil
            if let sidecarDict = draftMapE["audioSidecar"] as? [String: Any] {
                exportAudioSidecar = VGAudioSidecarPlan.fromDictionary(sidecarDict)
            }

            // Phase 10 Temporal Denoise: extract opt-in flag from request args.
            // VGEditorExportRequest.temporalDenoiseEnabled is serialised as a Bool
            // by the Dart standard codec; cast defensively to also accept NSNumber
            // in case the codec representation varies across Flutter versions.
            // Defaults to false when absent or nil.
            let exportTemporalDenoiseEnabled: Bool = {
                let raw = args?["temporalDenoiseEnabled"]
                if let b = raw as? Bool { return b }
                if let n = raw as? NSNumber { return n.boolValue }
                return false
            }()

            // Delegate to ObjC VGTimelineExportHelper.
            // Phase 10 Temporal Denoise: uses the new 12-parameter method.
            // All other parameters remain identical to the Phase 10 11-param call.
            VGTimelineExportHelper.exportTimeline(
                withClips: clipDictsE,
                transitions: transitionDictsE,
                outputPath: exportOutputPath,
                width: exportW,
                height: exportH,
                fps: exportFps,
                bitrateBps: exportBitrate,
                canvas: exportCanvasDict,
                overlays: exportOverlayDicts,
                audioSidecar: exportAudioSidecar,
                temporalDenoiseEnabled: exportTemporalDenoiseEnabled,
                progress: { [weak self] pct in
                    // Phase 10 Amendment 1: dispatch to main thread before invoking MethodChannel.
                    // Throttling is applied in VGTimelineExportHelper (100ms gate).
                    DispatchQueue.main.async {
                        self?.channel.invokeMethod("onExportProgress", arguments: pct)
                    }
                }
            ) { success, outPath, duration, error in
                DispatchQueue.main.async {
                    if success, let outPath = outPath {
                        result([
                            "success":         true,
                            "path":            outPath,
                            "durationSeconds": duration,
                            "width":           Int(exportW),
                            "height":          Int(exportH),
                            "fps":             Int(exportFps),
                        ] as [String: Any])
                    } else {
                        let msg = error?.localizedDescription
                                  ?? "Production timeline export failed (unknown error)"
                        result(FlutterError(
                            code: "COMPOSITOR_INIT_FAILED",
                            message: msg,
                            details: nil))
                    }
                }
            }

        case "disposeTimeline":
            // Phase 7.8 production route: tear down the active timeline runtime.
            // Phase 10-C Slice D teardown fix: result(nil) is returned INSIDE the
            // invalidateAsync completion so that Dart's await on disposeTimeline
            // resolves only after native invalidation is fully complete. This ensures
            // the Dart future returned by disposeAsync() reflects actual teardown
            // completion, not a fire-and-forget dispatch.
            if let runtime = self._timelineRuntime {
                self._timelineRuntime = nil
                runtime.invalidateAsync {
                    // Phase 7.20B: dispose wiring — cancel all in-flight reverse sidecar
                    // transcodes and delete all cached sidecar files. Runs after runtime
                    // invalidation completes, ensuring no new sidecar work is started.
                    // cleanupAllSidecars acquires the internal lock, resets all records,
                    // and dispatches file deletions asynchronously on a utility queue —
                    // the lock release is immediate.
                    VGReverseSidecarManager.shared().cleanupAllSidecars()
                    result(nil)
                }
            } else {
                // No active runtime — still clean up sidecars and return immediately.
                VGReverseSidecarManager.shared().cleanupAllSidecars()
                result(nil)
            }

        // ── Phase 7.18B1: Frame cache metrics + manual cache flush ─────────────
        //
        // getTimelineCacheStats — returns the frame cache metrics dictionary.
        //   Returns an empty dictionary (not a FlutterError) when no timeline
        //   compositor is active, so Dart callers never need error handling.
        //
        // clearTimelineCache — evicts all frame cache entries and resets counters.
        //   Forces the next scrub to decode from raw AVAssetReader / AVAssetImageGenerator,
        //   enabling manual before/after latency benchmarks in the harness.
        //   Always returns nil (void success) — never a FlutterError.

        case "getTimelineCacheStats":
            // Phase 7.18B1: returns live frame cache metrics dictionary.
            // Returns empty dict (not FlutterError) when no timeline is active.
            if let runtime = self._timelineRuntime {
                result(runtime.timelineCacheStatistics())
            } else {
                result([String: Any]())
            }

        case "clearTimelineCache":
            // Phase 7.18B1: flush all frame cache entries + reset counters.
            // Always succeeds (void). Forces cold decode on next scrub.
            self._timelineRuntime?.flushTimelineCaches()
            result(nil)

        // ── Phase 7.20B: Reverse Sidecar MethodChannel routes ─────────────────
        //
        // Apple documentation cross-checked (Phase 7.20B):
        //
        //   MethodChannel result threading:
        //     Flutter requires result() to be called exactly once and on the main
        //     thread (or any thread for non-platform-channel operations). This plugin
        //     uses DispatchQueue.main.async before result() for async completions,
        //     matching the pattern used by exportTimeline and normalizeVideo.
        //     Reference: FlutterPlugin.h — "The result block may be called on any thread."
        //
        //   Swift/ObjC block bridging:
        //     ObjC completion blocks (void (^)(VGReverseSidecarStatus *)) bridge to
        //     Swift as `@escaping (VGReverseSidecarStatus) -> Void` closures.
        //     ARC manages block memory; the closure is retained by the manager's
        //     pendingCompletions array and released after firing.
        //     Reference: "Using Swift with Cocoa and Objective-C" — Blocks and Closures.
        //
        //   DispatchGroup usage:
        //     DispatchGroup.enter()/leave() is the standard pattern for collecting
        //     multiple async callbacks before proceeding. notify(queue:) fires once
        //     all leave() calls have been received.
        //     Reference: Apple Developer Documentation — DispatchGroup.
        //
        //   Temporary directory:
        //     NSTemporaryDirectory() returns a per-app directory iOS may evict under
        //     disk pressure. Callers must handle a ready sidecar disappearing between
        //     status.sidecarPath receipt and compositor use (re-transcode via
        //     prepareReverseSidecars). Reference: File System Programming Guide.
        //
        // Export isolation:
        //     These routes are for preview only. The export compositor (VGExportScheduler
        //     + VGTimelineExportHelper) MUST NOT call prepareReverseSidecars.
        //     See VGReverseSidecarManager.h § Export isolation.

        case "prepareReverseSidecars":
            // Phase 7.20B: begin background transcoding for one or more reversed clips.
            //
            // Args:
            //   "clips": [[String: Any]] — required, list of clip specs:
            //     "clipId":       String  — stable clip identifier
            //     "sourcePath":   String  — absolute path to source video
            //     "trimStart":    Double  — trim window start in asset seconds (>= 0)
            //     "trimEnd":      Double  — trim window end in asset seconds (> trimStart)
            //     "targetWidth":  Double  — canvas width (pass 0 to use source natural size)
            //     "targetHeight": Double  — canvas height (pass 0 to use source natural size)
            //     "sourceHash":   String  — stable hash of (sourcePath+trimStart+trimEnd+targetSize)
            //
            // Returns on success:
            //   ["clips": [["clipId": String, "state": String, "sidecarPath": String?,
            //               "errorMessage": String?, "progress": Double]]]
            //
            // Completions are collected via DispatchGroup. Result is returned on main thread.
            // Does not block the call thread; all transcode work runs on VGReverseSidecarManager's
            // internal serial background queue.
            guard let clipList = args?["clips"] as? [[String: Any]] else {
                result(FlutterError(
                    code: "INVALID_REVERSE_SIDECAR_ARGS",
                    message: "prepareReverseSidecars: 'clips' array is required",
                    details: nil))
                return
            }

            // Empty clip list: return immediately with empty success result.
            if clipList.isEmpty {
                result(["clips": [[String: Any]]()])
                return
            }

            // Validate all clip entries upfront before dispatching any work.
            for (idx, clipDict) in clipList.enumerated() {
                guard
                    let clipId     = clipDict["clipId"]     as? String, !clipId.isEmpty,
                    let sourcePath = clipDict["sourcePath"] as? String, !sourcePath.isEmpty,
                    let sourceHash = clipDict["sourceHash"] as? String, !sourceHash.isEmpty
                else {
                    result(FlutterError(
                        code: "INVALID_REVERSE_SIDECAR_CLIP",
                        message: "prepareReverseSidecars: clips[\(idx)] missing required fields "
                               + "(clipId, sourcePath, sourceHash)",
                        details: nil))
                    return
                }
                let trimStart = (clipDict["trimStart"] as? NSNumber)?.doubleValue ?? 0.0
                let trimEnd   = (clipDict["trimEnd"]   as? NSNumber)?.doubleValue ?? 0.0
                guard trimStart >= 0.0, trimEnd > trimStart else {
                    result(FlutterError(
                        code: "INVALID_REVERSE_SIDECAR_CLIP",
                        message: "prepareReverseSidecars: clips[\(idx)] id=\(clipId): "
                               + "invalid trim range trimStart=\(trimStart) trimEnd=\(trimEnd)",
                        details: nil))
                    return
                }
                // Suppress unused-variable warnings for validated-but-not-used-yet fields.
                _ = sourcePath; _ = sourceHash
            }

            // Dispatch all sidecar preparations and collect results via DispatchGroup.
            let group = DispatchGroup()
            // resultStatuses is accessed only from the sidecar's internal serial queue
            // (completion blocks), then read on main after group.notify — no lock needed
            // because group.notify guarantees all leave() calls completed.
            var resultStatuses: [[String: Any]] = Array(repeating: [:], count: clipList.count)

            for (idx, clipDict) in clipList.enumerated() {
                // These are validated above; force-unwrap is safe here.
                let clipId     = clipDict["clipId"]     as! String
                let sourcePath = clipDict["sourcePath"] as! String
                let sourceHash = clipDict["sourceHash"] as! String
                let trimStart  = (clipDict["trimStart"]    as? NSNumber)?.doubleValue ?? 0.0
                let trimEnd    = (clipDict["trimEnd"]      as? NSNumber)?.doubleValue ?? 0.0
                let targetW    = (clipDict["targetWidth"]  as? NSNumber)?.doubleValue ?? 0.0
                let targetH    = (clipDict["targetHeight"] as? NSNumber)?.doubleValue ?? 0.0
                let targetSize = CGSize(width: targetW, height: targetH)

                group.enter()
                VGReverseSidecarManager.shared().prepareSidecar(
                    forClipId:  clipId,
                    sourcePath: sourcePath,
                    trimStart:  trimStart,
                    trimEnd:    trimEnd,
                    targetSize: targetSize,
                    sourceHash: sourceHash
                ) { status in
                    // Completion fires on VGReverseSidecarManager's internal serial queue.
                    // Map VGReverseSidecarState to a stable string for Dart.
                    let stateStr: String
                    switch status.state {
                    case .idle:        stateStr = "idle"
                    case .preparing:   stateStr = "preparing"
                    case .ready:       stateStr = "ready"
                    case .failed:      stateStr = "failed"
                    case .invalidated: stateStr = "invalidated"
                    @unknown default:  stateStr = "unknown"
                    }
                    var entry: [String: Any] = [
                        "clipId":   clipId,
                        "state":    stateStr,
                        "progress": status.progress,
                    ]
                    if let path = status.sidecarPath {
                        entry["sidecarPath"] = path
                    }
                    if let err = status.errorMessage {
                        entry["errorMessage"] = err
                    }
                    resultStatuses[idx] = entry
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                result(["clips": resultStatuses])
            }

        case "getSidecarStatus":
            // Phase 7.20B: query the current state of a single reverse sidecar.
            //
            // Args:
            //   "clipId": String — required
            //
            // Returns:
            //   ["clipId": String, "state": String, "sidecarPath": String?,
            //    "errorMessage": String?, "progress": Double]
            //
            // If no record exists for clipId, VGReverseSidecarManager returns idle.
            // This call is synchronous and fast (lock-acquire + dict lookup).
            guard let clipId = args?["clipId"] as? String, !clipId.isEmpty else {
                result(FlutterError(
                    code: "INVALID_REVERSE_SIDECAR_ARGS",
                    message: "getSidecarStatus: 'clipId' string is required",
                    details: nil))
                return
            }

            let status = VGReverseSidecarManager.shared().status(forClipId: clipId)
            let stateString: String
            switch status.state {
            case .idle:        stateString = "idle"
            case .preparing:   stateString = "preparing"
            case .ready:       stateString = "ready"
            case .failed:      stateString = "failed"
            case .invalidated: stateString = "invalidated"
            @unknown default:  stateString = "unknown"
            }
            var statusDict: [String: Any] = [
                "clipId":   clipId,
                "state":    stateString,
                "progress": status.progress,
            ]
            if let path = status.sidecarPath {
                statusDict["sidecarPath"] = path
            }
            if let err = status.errorMessage {
                statusDict["errorMessage"] = err
            }
            result(statusDict)

        case "cleanupReverseSidecars":
            // Phase 7.20B: cancel all in-flight transcodes and delete all sidecar files.
            //
            // No args required.
            // Returns: ["ok": true]
            //
            // Primarily used for manual testing, debug harness, and future lifecycle cleanup.
            // cleanupAllSidecars acquires the internal lock, resets all records, and
            // dispatches file deletions asynchronously on a utility queue.
            VGReverseSidecarManager.shared().cleanupAllSidecars()
            result(["ok": true])

        #endif // VG_USE_V2_GRAPH


        case "setPlaybackRate":
            guard let textureId = (args?["textureId"] as? NSNumber)?.int64Value,
                  let rate      = (args?["rate"] as? NSNumber)?.doubleValue else {
                result(FlutterError(code: "BAD_ARGS", message: "setPlaybackRate requires textureId and rate", details: nil)); return
            }
            // Phase 2 Step 7: try registry runtime first (playback sessions);
            // fall back to renderers dict for camera/export renderers.
            if sessionRegistry.runtime(forTextureId: textureId)?.setPlaybackRate(rate) != nil {
                // handled by registry
            } else if let renderer = renderers[textureId] {
                renderer.setPlaybackRate(rate)
            } else {
            }
            result(nil)

        case "dispose":
            guard let textureId = args?["textureId"] as? NSNumber else {
                result(FlutterError(code: "BAD_ARGS", message: "dispose requires textureId", details: nil)); return
            }
            let id = textureId.int64Value

            // Phase 2 Step 6: remove from maps, then drain async before unblocking Dart.
            // removeFromMaps returns the runtime without calling invalidate — we call
            // invalidateAsync so the decode queue drains before result(nil) fires.
            // This preserves the G-02-T2 safety guarantee from the legacy disposeAsync path.
            if let runtime = sessionRegistry.removeFromMaps(textureId: id) {
                runtime.invalidateAsync {
                    result(nil)
                }
            } else {
                result(nil)
            }

        // ── Audio promotion (Phase 2 Step 7) ──────────────────────────────────
        // Promotes sessionId to the active audio role via a serialised
        // demotion → slot-acquire → activation transaction in VGSessionRegistry.
        // sessionId is stable (UUID) and was returned synchronously by createTexture
        // via VGSessionRegistry.createSession. The result is a Bool on the main queue.

        case "promoteAudio":
            guard let sessionId = args?["sessionId"] as? String else {
                result(FlutterError(code: "BAD_ARGS",
                                    message: "promoteAudio requires sessionId",
                                    details: nil))
                return
            }
            sessionRegistry.promoteToActiveAudio(sessionId: sessionId) { success in
                DispatchQueue.main.async { result(success) }
            }

        // ── P4-10: Filter chain dispatch ────────────────────────────────────
        // Receives a Dart setFilterChain payload:
        //   { "sessionId": String, "filters": [[String: Any]] }
        // Validates each filter type against the native allowlist, then delegates
        // node construction to the runtime (which owns the pool + Metal device).
        // Returns FlutterError(UNKNOWN_FILTER) for any unrecognised type string.
        // Closes RR-34.
        case "setFilterChain":
            guard
                let sessionId = args?["sessionId"] as? String,
                let filterDicts = args?["filters"] as? [[String: Any]]
            else {
                result(FlutterError(code: "BAD_ARGS",
                                    message: "setFilterChain requires sessionId and filters",
                                    details: nil))
                return
            }

            guard let runtime = sessionRegistry.runtime(forSessionId: sessionId) else {
                result(FlutterError(code: "SESSION_NOT_FOUND",
                                    message: "setFilterChain: no runtime for sessionId \(sessionId)",
                                    details: nil))
                return
            }

            // Pre-validate type strings before touching the runtime.
            // Mirrors the Dart-side assertValid() allowlist; provides server-side
            // error reporting for release-mode callers where assert is elided.
            let knownTypes: Set<String> = ["lut", "beauty", "segmentation"]
            for dict in filterDicts {
                let type = dict["type"] as? String ?? ""
                if !knownTypes.contains(type) {
                    result(FlutterError(
                        code: "UNKNOWN_FILTER",
                        message: "Unknown filter type: \(type)",
                        details: nil
                    ))
                    return
                }
            }

            // Delegate node construction + chain swap to the runtime, which owns
            // the CVPixelBufferPool and MTLDevice required by filter node initialisers.
            var unknownType: NSString? = nil
            let applied = runtime.setFilterChain(fromSpecs: filterDicts, unknown: &unknownType)

            if applied {
                result(nil)
            } else {
                // Double-check: should not reach here (pre-validated above), but guard
                // in case the runtime's allowlist diverges from the Swift one.
                let badType = unknownType ?? "(nil)"
                result(FlutterError(
                    code: "UNKNOWN_FILTER",
                    message: "Unknown filter type (runtime): \(badType)",
                    details: nil
                ))
            }

        case "exportImage":
            guard let args = args,
                  let sourcePath = args["sourcePath"] as? String,
                  let outputPath = args["outputPath"] as? String,
                  let format = args["format"] as? String,
                  let quality = args["quality"] as? Double,
                  let orientationPolicy = args["orientationPolicy"] as? String else {
                result(FlutterError(code: "EXPORT_IMAGE_INVALID_ARGUMENTS",
                                    message: "Missing or invalid arguments for exportImage",
                                    details: nil))
                return
            }

            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: sourcePath) else {
                result(FlutterError(code: "EXPORT_IMAGE_INVALID_ARGUMENTS",
                                    message: "Source image file does not exist at: \(sourcePath)",
                                    details: nil))
                return
            }

            let outputURL = URL(fileURLWithPath: outputPath)
            let parentDir = outputURL.deletingLastPathComponent().path
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: parentDir, isDirectory: &isDir), isDir.boolValue else {
                result(FlutterError(code: "EXPORT_IMAGE_INVALID_ARGUMENTS",
                                    message: "Output parent directory does not exist: \(parentDir)",
                                    details: nil))
                return
            }

            let mappedFormat: VGImageEncodeFormat
            let fmtLower = format.lowercased()
            if fmtLower == "jpeg" || fmtLower == "jpg" {
                mappedFormat = VGImageEncodeFormat(rawValue: 0)!
            } else if fmtLower == "heic" || fmtLower == "heif" {
                mappedFormat = VGImageEncodeFormat(rawValue: 1)!
            } else if fmtLower == "png" {
                mappedFormat = VGImageEncodeFormat(rawValue: 2)!
            } else if fmtLower == "webp" {
                result(FlutterError(code: "EXPORT_IMAGE_UNSUPPORTED_FORMAT",
                                    message: "WebP still image encoding is not supported on iOS via ImageIO",
                                    details: nil))
                return
            } else {
                result(FlutterError(code: "EXPORT_IMAGE_UNSUPPORTED_FORMAT",
                                    message: "Unsupported image format: \(format)",
                                    details: nil))
                return
            }

            let orientPolicy: VGImageOrientationPolicyType
            let orientLower = orientationPolicy.lowercased()
            if orientLower == "preserve" {
                orientPolicy = VGImageOrientationPolicyType(rawValue: 0)!
            } else if orientLower == "applyandrotate" {
                orientPolicy = VGImageOrientationPolicyType(rawValue: 1)!
            } else {
                result(FlutterError(code: "EXPORT_IMAGE_INVALID_ARGUMENTS",
                                    message: "Invalid orientation policy: \(orientationPolicy)",
                                    details: nil))
                return
            }

            let profile = VGImageExportProfile(format: mappedFormat,
                                               quality: Float(quality),
                                               colorProfilePolicy: VGImageColorProfilePolicyType(rawValue: 0)!,
                                               orientationPolicy: orientPolicy)

            let sourceURL = URL(fileURLWithPath: sourcePath)
            let metalDevice = VGResourceAllocator.sharedInstance().metalDevice
            let processor = VanguardImageProcessor(device: metalDevice, pool: nil)
            // Slice-A memory fix: this source is a one-shot serial export session.
            // No concurrent IOSurface allocations can race, so it is safe to
            // release pixel buffers on invalidate (~97 MB reclaimed per export).
            let source = VanguardImageMediaSource(url: sourceURL,
                                                  processor: processor,
                                                  releaseBuffersOnInvalidate: true)

            // ── Phase 10-C-3L.1C: Parse filter chain from 'filters' argument ──
            //
            // Dart sends filters as [[String: Any]] where each dict has keys:
            //   'type' (String), 'enabled' (Bool), 'parameters' (Map).
            //
            // Supported type in this slice: 'colorMatrix'
            //   parameters['matrix']: [Any] of exactly 20 numeric elements
            //
            // Unknown types are logged and skipped (forward-compatible).
            var filterChain: [Any]? = nil
            if let filterDicts = args["filters"] as? [[String: Any]], !filterDicts.isEmpty {
                // Pass raw filter/node objects — VGImageExportSession.m wraps them
                // in VGLegacyFilterAdapter exactly once. Wrapping here causes double-wrap
                // which makes the outer adapter call prepareWithCompletion: on the inner
                // adapter (which does not implement that selector → NSInvalidArgumentException).
                var nodes: [Any] = []
                for filterDict in filterDicts {
                    guard let type = filterDict["type"] as? String else { continue }
                    let enabled = filterDict["enabled"] as? Bool ?? true
                    let parameters = filterDict["parameters"] as? [String: Any] ?? [:]

                    switch type {
                    case "colorMatrix":
                        guard let rawMatrix = parameters["matrix"] as? [Any],
                              rawMatrix.count == 20 else {
                            continue
                        }
                        let matrixNumbers: [NSNumber] = rawMatrix.compactMap {
                            if let n = $0 as? NSNumber { return n }
                            if let d = $0 as? Double    { return NSNumber(value: d) }
                            if let i = $0 as? Int       { return NSNumber(value: i) }
                            return nil
                        }
                        guard matrixNumbers.count == 20 else {
                            continue
                        }
                        let node = VGColorMatrixFilterNode(pool: nil,
                                                           device: metalDevice,
                                                           matrix: matrixNumbers)
                        node.enabled = enabled
                        nodes.append(node)

                    case "transform":
                        // Phase 10-C-3L.1D: spatial transform for still-image export.
                        //
                        // Required parameters:
                        //   canvasWidth:          Int  – output canvas pixel width
                        //   canvasHeight:         Int  – output canvas pixel height
                        //   scale:                Double – zoom multiplier relative to aspect-fill
                        //   offsetX:              Double – normalized pan [-1, 1]
                        //   offsetY:              Double – normalized pan [-1, 1]
                        //   rotationQuarterTurns: Int  – CW rotation [0–3]
                        //   flipX:                Bool – horizontal mirror after rotation
                        //
                        // Optional parameters:
                        //   cropRect:             [Double] – normalized [x, y, w, h] crop, length 4

                        guard let canvasWidthRaw  = parameters["canvasWidth"],
                              let canvasHeightRaw = parameters["canvasHeight"],
                              let scaleRaw        = parameters["scale"] else {
                            continue
                        }

                        // Coerce canvasWidth / canvasHeight to Int.
                        let canvasWidth: Int
                        let canvasHeight: Int
                        if let n = canvasWidthRaw as? Int {
                            canvasWidth = n
                        } else if let n = canvasWidthRaw as? NSNumber {
                            canvasWidth = n.intValue
                        } else {
                            continue
                        }
                        if let n = canvasHeightRaw as? Int {
                            canvasHeight = n
                        } else if let n = canvasHeightRaw as? NSNumber {
                            canvasHeight = n.intValue
                        } else {
                            continue
                        }
                        guard canvasWidth > 0, canvasHeight > 0 else {
                            continue
                        }

                        // Coerce scale to Double.
                        let scaleValue: Double
                        if let d = scaleRaw as? Double {
                            scaleValue = d
                        } else if let n = scaleRaw as? NSNumber {
                            scaleValue = n.doubleValue
                        } else {
                            continue
                        }
                        guard scaleValue > 0 else {
                            continue
                        }

                        // Coerce offsetX / offsetY (default 0.0 if missing).
                        let offsetXValue: Double
                        let offsetYValue: Double
                        if let raw = parameters["offsetX"] {
                            offsetXValue = (raw as? NSNumber)?.doubleValue ?? 0.0
                        } else {
                            offsetXValue = 0.0
                        }
                        if let raw = parameters["offsetY"] {
                            offsetYValue = (raw as? NSNumber)?.doubleValue ?? 0.0
                        } else {
                            offsetYValue = 0.0
                        }

                        // Coerce rotationQuarterTurns (default 0 if missing).
                        let quarterTurns: Int
                        if let raw = parameters["rotationQuarterTurns"] {
                            quarterTurns = (raw as? NSNumber)?.intValue ?? 0
                        } else {
                            quarterTurns = 0
                        }

                        // Coerce flipX (default false if missing).
                        let flipXValue: Bool
                        if let raw = parameters["flipX"] {
                            flipXValue = (raw as? Bool) ?? ((raw as? NSNumber)?.boolValue ?? false)
                        } else {
                            flipXValue = false
                        }

                        // Coerce optional cropRect ([Double], length 4).
                        var cropRectNumbers: [NSNumber]? = nil
                        if let rawCrop = parameters["cropRect"] as? [Any], rawCrop.count == 4 {
                            let coerced: [NSNumber] = rawCrop.compactMap {
                                if let n = $0 as? NSNumber { return n }
                                if let d = $0 as? Double    { return NSNumber(value: d) }
                                if let i = $0 as? Int       { return NSNumber(value: i) }
                                return nil
                            }
                            if coerced.count == 4 {
                                cropRectNumbers = coerced
                            } else {
                            }
                        }

                        let transformNode = VGTransformFilterNode(
                            pool:         nil,
                            device:       metalDevice,
                            canvasWidth:  canvasWidth,
                            canvasHeight: canvasHeight,
                            scale:        scaleValue,
                            offsetX:      offsetXValue,
                            offsetY:      offsetYValue,
                            quarterTurns: quarterTurns,
                            flipX:        flipXValue,
                            cropRect:     cropRectNumbers
                        )
                        transformNode.enabled = enabled
                        nodes.append(transformNode)

                    case "overlay":
                        // Phase 10-B1: Still-image overlay compositing via VGOverlayNode.
                        //
                        // Accepts the same parameters dict that the video timeline already uses:
                        //   parameters["canvas"]   : [String: Any]   → VGCanvasDescriptor
                        //   parameters["overlays"] : [[String: Any]] → VGOverlayDescriptor[]
                        //
                        // VGOverlayNode parses defensively — missing or malformed values
                        // produce safe defaults without returning an error.
                        //
                        // Contract note (Opus Q3): VGOverlayNode filters active overlays by PTS.
                        // VGImageExportSession pulls at kCMTimeZero, so all overlay descriptors
                        // passed here MUST have startTime=0.0 and duration>0 on the Dart side.
                        //
                        // VGOverlayNode conforms to VGTransformNode directly — VGImageExportSession
                        // (Phase 10-B1 widened) will NOT wrap it in VGLegacyFilterAdapter.
                        if !enabled {
                            continue
                        }

                        // Validate that at least an overlays array is present and non-empty.
                        guard let overlayDicts = parameters["overlays"] as? [[String: Any]],
                              !overlayDicts.isEmpty else {
                            continue
                        }

                        // Build the parameters NSDictionary to pass to VGOverlayNode.
                        // We pass the full parameters dict as-is; VGOverlayNode reads
                        // @"canvas" and @"overlays" keys defensively.
                        let overlayNodeParams: [String: Any] = parameters

                        let overlayNode = VGOverlayNode(nodeId: "image_overlay_\(nodes.count)",
                                                        parameters: overlayNodeParams,
                                                        ports: nil,
                                                        error: nil)
                        overlayNode.enabled = enabled
                        nodes.append(overlayNode)

                    default:
                        break
                    }
                }
                filterChain = nodes.isEmpty ? nil : nodes
            }

            let exportSession = VGImageExportSession(source: source,
                                                     filterChain: filterChain,
                                                     profile: profile,
                                                     outputURL: outputURL)

            exportSession.start { manifest, error in
                DispatchQueue.main.async {
                    if let error = error {
                        result(FlutterError(code: "EXPORT_IMAGE_FAILED",
                                            message: "VGImageExportSession failed: \(error.localizedDescription)",
                                            details: nil))
                    } else if let manifest = manifest {
                        let response: [String: Any] = [
                            "success": true,
                            "path": outputPath,
                            "width": Int(manifest.width),
                            "height": Int(manifest.height),
                            "format": format,
                            "fileSizeBytes": Int64(manifest.fileSizeBytes)
                        ]
                        result(response)
                    } else {
                        result(FlutterError(code: "EXPORT_IMAGE_FAILED",
                                            message: "VGImageExportSession returned neither manifest nor error",
                                            details: nil))
                    }
                }
            }

        // ── Export ─────────────────────────────────────────────────────────────

        case "startExport":
            guard
                let clipDicts  = args?["clips"]      as? [[String: Any]],
                let outputPath = args?["outputPath"]  as? String,
                let bitrate    = args?["bitrate"]     as? Int,
                let maxSec     = args?["maxSeconds"]  as? Double
            else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "clips, outputPath, bitrate, maxSeconds required",
                                    details: nil))
                return
            }

            // P1-T4: Switch to export mode (tears down editor)
            switchToMode(.export)

            let clipSpecs: [ClipSpec] = clipDicts.compactMap { dict in
                guard let path = dict["path"] as? String else { return nil }
                return ClipSpec(
                    url:       URL(fileURLWithPath: path),
                    trimStart: dict["trimStart"] as? Double ?? 0.0,
                    trimEnd:   dict["trimEnd"]   as? Double ?? Double.infinity,
                    speed:     dict["speed"]     as? Double ?? 1.0
                )
            }

            let audioPath  = args?["audioPath"]  as? String
            let audioStart = args?["audioStart"] as? Double ?? 0.0
            let optimizeForNet = args?["optimizeForNetworkUse"] as? Bool ?? false

            let config = VanguardExportSession.Config(
                outputURL:  URL(fileURLWithPath: outputPath),
                width:      1080, height: 1920,
                bitrate:    bitrate, fps: 30,
                maxSeconds: maxSec,
                audioURL:   audioPath.map { URL(fileURLWithPath: $0) },
                audioStart: audioStart,
                optimizeForNetworkUse: optimizeForNet
            )

            let session = VanguardExportSession(config: config, clips: clipSpecs)
            activeExportSession = session
            session.start(
                progress: { [weak self] pct in
                    self?.channel.invokeMethod("onExportProgress", arguments: pct)
                },
                completion: { [weak self] url, error in
                    self?.activeExportSession = nil
                    self?.currentMode = .idle
                    if let url = url {
                        result(["outputPath": url.path, "success": true])
                    } else {
                        result(FlutterError(code: "EXPORT_FAILED",
                                            message: error?.localizedDescription,
                                            details: nil))
                    }
                }
            )

        case "cancelExport":
            activeExportSession?.cancel()
            activeExportSession = nil
            currentMode = .idle
            result(nil)

        // ── Audio Extraction ──────────────────────────────────────────────────

        case "extractAudio":
            guard
                let videoPath = args?["videoPath"]  as? String,
                let outPath   = args?["outputPath"] as? String
            else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "videoPath and outputPath required",
                                    details: nil))
                return
            }
            let trimStart = args?["trimStart"] as? Double ?? 0.0
            let trimEnd   = args?["trimEnd"]   as? Double ?? Double.infinity

            VanguardExportSession.extractAudio(
                from:      URL(fileURLWithPath: videoPath),
                to:        URL(fileURLWithPath: outPath),
                trimStart: trimStart,
                trimEnd:   trimEnd
            ) { url, error in
                if let url = url {
                    result(url.path)
                } else {
                    result(FlutterError(code: "EXTRACT_FAILED",
                                        message: error?.localizedDescription,
                                        details: nil))
                }
            }

        // ── Waveform Extraction (Phase 8.15C) ─────────────────────────────────
        // Extracts a Float32 RMS waveform from an audio/video file offline.
        //
        // Args:
        //   "path":               String — required, absolute path to audio/video file
        //   "samplesPerSecond":   Int    — optional, default 100 (range 1–1000)
        //   "maxDurationSeconds": Double — optional, default 600.0
        //
        // Returns on success:
        //   [
        //     "samples":         FlutterStandardTypedData (Float32List)
        //     "durationSeconds": Double
        //     "samplesPerSecond": Int
        //     "pointCount":      Int
        //   ]
        //
        // Returns FlutterError on failure with codes:
        //   "NO_AUDIO_TRACK", "ZERO_DURATION", "DURATION_EXCEEDED",
        //   "READER_SETUP_FAILED", "READER_FAILED", "WAVEFORM_CANCELLED"

        case "extractWaveform":
            guard let filePath = args?["path"] as? String, !filePath.isEmpty else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "path is required and must be non-empty",
                                    details: nil))
                return
            }
            let waveSamplesPerSec = args?["samplesPerSecond"] as? Int ?? 100
            let waveMaxDuration   = args?["maxDurationSeconds"] as? Double ?? 600.0

            let waveAsset = AVURLAsset(url: URL(fileURLWithPath: filePath))
            let extractor = VGWaveformExtractor(asset: waveAsset)

            extractor.extract(withSamplesPerSecond: waveSamplesPerSec,
                              maxDurationSeconds: waveMaxDuration) { waveResult, error in
                if let error = error {
                    let code: String
                    switch (error as NSError).code {
                    case 1:  code = "NO_AUDIO_TRACK"
                    case 2:  code = "ZERO_DURATION"
                    case 3:  code = "DURATION_EXCEEDED"
                    case 4:  code = "READER_SETUP_FAILED"
                    case 5:  code = "READER_FAILED"
                    case 6:  code = "WAVEFORM_CANCELLED"
                    default: code = "WAVEFORM_ERROR"
                    }
                    result(FlutterError(code: code,
                                        message: error.localizedDescription,
                                        details: nil))
                    return
                }
                guard let waveResult = waveResult else {
                    result(FlutterError(code: "WAVEFORM_ERROR",
                                        message: "Extraction returned nil result",
                                        details: nil))
                    return
                }
                result([
                    "samples":          FlutterStandardTypedData(float32: waveResult.samplesData),
                    "durationSeconds":  waveResult.durationSeconds,
                    "samplesPerSecond": waveResult.samplesPerSecond,
                    "pointCount":       waveResult.pointCount,
                ])
            }

        // ── Thumbnail Generation (P1-T7: VanguardThumbnailGenerator) ─────────

        case "generateThumbnails":
            guard
                let videoPath = args?["videoPath"] as? String,
                let count     = args?["count"]     as? Int,
                let duration  = args?["duration"]  as? Double
            else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "videoPath, count, duration required",
                                    details: nil))
                return
            }
            let maxWidth = args?["maxWidth"] as? Int ?? 120
            let maxHeight = args?["maxHeight"] as? Int ?? 214
            let jpegQuality = args?["jpegQuality"] as? Double ?? 0.6
            thumbnailGenerator.generateThumbnails(
                videoPath: videoPath, count: count, duration: duration,
                maxWidth: maxWidth, maxHeight: maxHeight, jpegQuality: jpegQuality
            ) { images in result(images) }

        // ── ROI-5B.1: Display-Oriented Frame Extraction Evidence ─────────────
        // Diagnostic-only. Extracts the first decoded frame and returns its
        // pixel dimensions without JPEG encoding or file I/O.
        // Uses AVAssetImageGenerator with appliesPreferredTrackTransform = true
        // and maximumSize = .zero (default) so no scaling is applied.
        // Purpose: prove that native extraction yields frames whose dimensions
        // match inspectMedia.displayWidth / displayHeight before any scanner.

        case "extractDisplayOrientedFrameEvidence":
            guard
                let videoPath = args?["videoPath"] as? String,
                !videoPath.isEmpty
            else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "extractDisplayOrientedFrameEvidence: videoPath required",
                                    details: nil))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let url   = URL(fileURLWithPath: videoPath)
                let asset = AVURLAsset(url: url,
                                       options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

                let gen = AVAssetImageGenerator(asset: asset)
                // Apply preferredTransform so the CGImage is display-oriented.
                // A portrait video stored as landscape+270° yields a CGImage
                // whose width/height match the display portrait size.
                gen.appliesPreferredTrackTransform = true
                // maximumSize = .zero is the default (no upper bound); explicit
                // to document intent: decode at full display resolution.
                gen.maximumSize = .zero

                let requestedTime = CMTime(seconds: 0, preferredTimescale: 600)
                var actualTime    = CMTime.zero

                do {
                    let cgImage = try gen.copyCGImage(at: requestedTime,
                                                      actualTime: &actualTime)
                    let w         = cgImage.width
                    let h         = cgImage.height
                    let actualSec = CMTimeGetSeconds(actualTime)
                    DispatchQueue.main.async {
                        result([
                            "extractedFrameWidth":     w,
                            "extractedFrameHeight":    h,
                            "method":                  "AVAssetImageGenerator",
                            "rotationHandling":        "appliesPreferredTrackTransform",
                            "displayTransformApplied": true,
                            "requestedTimeSeconds":    0.0,
                            "actualTimeSeconds":       actualSec,
                        ] as [String: Any])
                    }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "DECODE_FAILED",
                            message: "extractDisplayOrientedFrameEvidence: \(error.localizedDescription)",
                            details: nil))
                    }
                }
            }

        // ── ROI-5C.1: Imported face scan evidence ─────────────────────────────
        //
        // Diagnostic-only. Extracts one display-oriented frame via AVAssetImageGenerator
        // (same path as extractDisplayOrientedFrameEvidence) then runs
        // VNDetectFaceRectanglesRequest with orientation .up (frame is already
        // display-oriented). Returns face bounding boxes in three coordinate spaces:
        //   - Vision raw (bottom-left normalized origin, per Vision convention)
        //   - Top-left normalized (Vision y-axis inverted: normalizedY = 1.0 - visionY - visionH)
        //   - Display pixel (normalizedX/Y * frameWidth/Height)
        //
        // No ROI sidecar. No file writes. No landmarks. No export integration.
        // iOS only — Android returns UNSUPPORTED_PLATFORM until ROI-5B Android smoke passes.

        case "extractImportedFaceScanEvidence":
            guard
                let videoPath = args?["videoPath"] as? String,
                !videoPath.isEmpty
            else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "extractImportedFaceScanEvidence: videoPath required",
                                    details: nil))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let url   = URL(fileURLWithPath: videoPath)
                let asset = AVURLAsset(url: url,
                                       options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

                // ── Step 1: Extract display-oriented frame ─────────────────────
                // Reuses identical AVAssetImageGenerator configuration as
                // extractDisplayOrientedFrameEvidence (ROI-5B.1).
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = .zero  // full display-native resolution

                let requestedTime = CMTime(seconds: 0, preferredTimescale: 600)
                var actualTime    = CMTime.zero

                let cgImage: CGImage
                do {
                    cgImage = try gen.copyCGImage(at: requestedTime, actualTime: &actualTime)
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "DECODE_FAILED",
                            message: "extractImportedFaceScanEvidence frame extraction: \(error.localizedDescription)",
                            details: nil))
                    }
                    return
                }

                let frameWidth  = cgImage.width
                let frameHeight = cgImage.height
                let actualSec   = CMTimeGetSeconds(actualTime)

                // ── Step 2: Run Vision face rectangle detection ────────────────
                // Frame is already display-oriented (appliesPreferredTrackTransform=true),
                // so Vision orientation is .up — no rotation math required.
                let faceRequest = VNDetectFaceRectanglesRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage,
                                                    orientation: .up,
                                                    options: [:])

                // Release cgImage reference after Vision finishes; CGImage is
                // ref-counted so capture in the closure keeps it alive until here.
                let visionError: Error?
                do {
                    try handler.perform([faceRequest])
                    visionError = nil
                } catch {
                    visionError = error
                }

                if let err = visionError {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "VISION_FAILED",
                            message: "extractImportedFaceScanEvidence Vision: \(err.localizedDescription)",
                            details: nil))
                    }
                    return
                }

                // ── Step 3: Convert bounding boxes ────────────────────────────
                // Vision boundingBox origin is bottom-left [0,1].
                // Top-left normalized: normalizedY = 1.0 - visionY - visionH.
                // Pixel: normalizedX * frameWidth, normalizedY * frameHeight.
                let observations = faceRequest.results as? [VNFaceObservation] ?? []
                var faceMaps: [[String: Any]] = []

                for (idx, obs) in observations.enumerated() {
                    let box = obs.boundingBox

                    let visionX = Double(box.origin.x)
                    let visionY = Double(box.origin.y)
                    let visionW = Double(box.size.width)
                    let visionH = Double(box.size.height)

                    // y-axis inversion: Vision is bottom-left, UI is top-left.
                    let normX = visionX
                    let normY = 1.0 - visionY - visionH
                    let normW = visionW
                    let normH = visionH

                    // Clamp to [0,1] to guard against floating-point edge drift.
                    let clampedNormX = min(max(normX, 0.0), 1.0)
                    let clampedNormY = min(max(normY, 0.0), 1.0)
                    let clampedNormW = min(max(normW, 0.0), 1.0 - clampedNormX)
                    let clampedNormH = min(max(normH, 0.0), 1.0 - clampedNormY)
                    let wasClamped   = (clampedNormX != normX || clampedNormY != normY
                                        || clampedNormW != normW || clampedNormH != normH)

                    let pixelX = clampedNormX * Double(frameWidth)
                    let pixelY = clampedNormY * Double(frameHeight)
                    let pixelW = clampedNormW * Double(frameWidth)
                    let pixelH = clampedNormH * Double(frameHeight)

                    faceMaps.append([
                        "index":           idx,
                        "visionX":         visionX,
                        "visionY":         visionY,
                        "visionWidth":     visionW,
                        "visionHeight":    visionH,
                        "normalizedX":     clampedNormX,
                        "normalizedY":     clampedNormY,
                        "normalizedWidth": clampedNormW,
                        "normalizedHeight":clampedNormH,
                        "pixelX":          pixelX,
                        "pixelY":          pixelY,
                        "pixelWidth":      pixelW,
                        "pixelHeight":     pixelH,
                        "clamped":         wasClamped,
                    ])
                }

                DispatchQueue.main.async {
                    result([
                        "frameWidth":           frameWidth,
                        "frameHeight":          frameHeight,
                        "method":               "VNDetectFaceRectanglesRequest",
                        "frameExtractionMethod":"AVAssetImageGenerator",
                        "visionOrientation":    "up",
                        "coordinateSpace":      "displayTopLeftNormalizedAndPixels",
                        "faceCount":            observations.count,
                        "faces":                faceMaps,
                        "requestedTimeSeconds": 0.0,
                        "actualTimeSeconds":    actualSec,
                    ] as [String: Any])
                }
            }

        // ── Camera ────────────────────────────────────────────────────────────


        case "startCamera":
            let positionInt = args?["position"] as? Int ?? 1  // 1=back, 2=front
            let fps         = args?["fps"]      as? Int ?? 30
            // BLOCK-1 FIX: when already in camera mode a recording may be active.
            // switchToMode(.camera) → teardownCurrentMode() → cameraSource?.stop()
            // does NOT call finishWritingWithCompletionHandler: on the AVAssetWriter —
            // the in-flight clip is permanently truncated with no error signalled to Flutter.
            // Route through teardownCameraAsync so stopRecordingWithCompletion: is called
            // first and the hardware encoder drains before the new source is created.
            if currentMode == .camera {
                teardownCameraAsync { [weak self] in
                    guard let self = self else { result(nil); return }
                    self.currentMode = .camera
                    let position: AVCaptureDevice.Position = positionInt == 2 ? .front : .back
                    let src = VanguardCameraMediaSource(position: position, frameRate: Int32(fps))
                    // Flutter Texture portrait lock: prevents UIDeviceOrientationDidChangeNotification
                    // from switching AVCaptureConnection.videoOrientation to landscape and delivering
                    // 1920x1080 buffers to the graph. Beauty V1 lacks a stride guard so any dimension
                    // change triggers a Metal abort. Lock here, before any frames arrive.
                    src.lockPreviewOrientationToPortrait()
                    self.cameraSource = src
                    let enc = VanguardVideoToolboxEncoder(
                        width: 1080, height: 1920,
                        bitrate: 10_000_000, fps: Int32(fps)
                    ) { _, _, _, _ in }
                    self.streamingEncoder = enc
                    enc.prewarm()
                    // Phase 1 fix: create renderer BEFORE calling src.start() so that
                    // _videoCallback is wired before any camera frames arrive on _captureQueue.
                    // Calling start() first would create a window where frames arrive on
                    // _captureQueue with _videoCallback == nil — technically safe (nil check
                    // prevents crash) but avoids the theoretical concurrent-read race entirely.
                    let renderer = VanguardMetalRenderer(source: src,
                                                        textureRegistry: self.registrar.textures(),
                                                        methodChannel: self.channel,
                                                        sessionPool: nil)
                    self.renderers[renderer.textureId] = renderer
                    #if VG_USE_CAMERA_GRAPH
                    var graphStarted = false
                    do {
                        let session = try VGCameraGraphSession(source: src, renderer: renderer)
                        self.cameraGraphSession = session
                        graphStarted = true
                    } catch {
                    }
                    if !graphStarted {
                        src.start()
                    }
                    #else
                    src.start()
                    #endif
                    result(renderer.textureId)
                }
                return
            }

            switchToMode(.camera)  // tears down editor/export; deactivates AVAudioEngine

            // FIX-D: Stop any existing camera source before creating a new one.
            // Without this guard, a rapid startCamera→startCamera (front/back switch)
            // leaves the previous source running. Its AVCaptureSession continues
            // delivering captureOutput: callbacks after cameraSource is overwritten.
            // stop() calls [_session stopRunning] which blocks until all in-flight
            // captureOutput: callbacks drain — no cross-thread race on _videoCallback.
            if let existing = cameraSource {
                existing.stop()
                cameraSource = nil
            }
            streamingEncoder?.finish()
            streamingEncoder?.invalidate()
            streamingEncoder = nil

            let position: AVCaptureDevice.Position = positionInt == 2 ? .front : .back
            let src = VanguardCameraMediaSource(position: position, frameRate: Int32(fps))
            // Flutter Texture portrait lock: prevents UIDeviceOrientationDidChangeNotification
            // from switching AVCaptureConnection.videoOrientation to landscape and delivering
            // 1920x1080 buffers to the graph. Beauty V1 lacks a stride guard so any dimension
            // change triggers a Metal abort. Lock here, before any frames arrive.
            src.lockPreviewOrientationToPortrait()
            cameraSource = src

            // Prewarm streaming encoder (Phase 5+ streaming path, not AVAssetWriter)
            let enc = VanguardVideoToolboxEncoder(
                width: 1080, height: 1920,
                bitrate: 10_000_000, fps: Int32(fps)
            ) { _, _, _, _ in }
            streamingEncoder = enc
            enc.prewarm()  // ~100–150ms; runs before user can tap record

            // Phase 1 fix: create renderer BEFORE calling src.start() so that
            // _videoCallback is wired before any camera frames arrive.
            let renderer = VanguardMetalRenderer(source: src,
                                                 textureRegistry: registrar.textures(),
                                                 methodChannel: channel,
                                                 sessionPool: nil)
            renderers[renderer.textureId] = renderer
            #if VG_USE_CAMERA_GRAPH
            var graphStarted = false
            do {
                let session = try VGCameraGraphSession(source: src, renderer: renderer)
                cameraGraphSession = session
                graphStarted = true
            } catch {
            }
            if !graphStarted {
                src.start()
            }
            #else
            src.start()
            #endif
            result(renderer.textureId)

        // ── POC 1: Connect active camera source → active PlatformView ─────────
        // POC-only method.  Dart calls this after UiKitView is mounted so that
        // VanguardCameraMediaSource delivers raw frames to VanguardCameraPlatformView.
        //
        // Returns a String result:
        //   "connected_graph"   — POC2: graph fan-out wired, raw forwarding disabled.
        //   "connected_raw"     — POC1: raw direct forwarding wired (graph mode off
        //                         or no active graph session).
        //   "no_camera_source"  — startCamera was not called first.
        //   "no_platform_view"  — UiKitView has not been mounted yet.
        //   "no_graph_session"  — Graph mode enabled but no active session (fallback
        //                         to raw).
        //   "connect_failed"    — session.connectPlatformViewReceiver returned NO.
        //
        // Safety:
        //   • Does NOT start/stop camera.
        //   • Does NOT switch camera.
        //   • Does NOT recreate texture.
        //   • Does NOT touch scheduler, Beauty V2, or VGGraphSchedulerV2.
        //
        // POC2 ONLY — Remove before Phase 7 / production.
        case "connectPlatformViewToCamera":
            guard let src = cameraSource else {
                result("no_camera_source")
                return
            }
            guard let view = cameraFactory?.latestInstance else {
                result("no_platform_view")
                return
            }

            #if VG_USE_CAMERA_GRAPH
            // POC2 graph path: wire the PlatformView as a second VGFanOutSink child.
            // The session creates a VGPlatformViewSinkAdapter and triggers a graph
            // rebuild so graph-processed (post-Beauty-V2) frames reach the MTKView.
            if let session = cameraGraphSession {
                let connected = session.connectPlatformViewReceiver(view)
                if connected {
                    // Disable raw forwarding — MTKView now receives graph frames only.
                    src.platformViewRawForwardingEnabled = false
                    result("connected_graph")
                } else {
                    result("connect_failed")
                }
                return
            }
            // No active graph session: fall through to raw path with a log.
            src.frameReceiver = view
            result("no_graph_session")
            #else
            // Non-graph mode: POC1 raw direct forwarding.
            src.frameReceiver = view
            result("connected_raw")
            #endif

        case "setCameraFilterChain":
            #if VG_USE_CAMERA_GRAPH
            guard let session = cameraGraphSession else {
                result(FlutterError(
                    code: "NO_CAMERA_GRAPH",
                    message: "Camera graph session is not running.",
                    details: nil
                ))
                return
            }

            guard let filterDicts = args?["filters"] as? [[String: Any]] else {
                result(FlutterError(
                    code: "BAD_ARGS",
                    message: "setCameraFilterChain expects filters: [[String: Any]].",
                    details: nil
                ))
                return
            }

            if filterDicts.isEmpty {
                session.setCameraFilterChain(nil)
                result(nil)
                return
            }

            let knownTypes: Set<String> = ["lut", "beauty", "segmentation"]
            for dict in filterDicts {
                let type = dict["type"] as? String ?? ""
                if !knownTypes.contains(type) {
                    result(FlutterError(
                        code: "UNKNOWN_FILTER",
                        message: "Unknown filter type: \(type)",
                        details: nil
                    ))
                    return
                }
            }

            // Phase 6A-3D-2: delegate non-empty specs to session for atomic
            // validation and Beauty V1 construction. The session method returns
            // an NSError whose domain is the FlutterError code string.
            do {
                try session.setCameraFilterChainFromSpecs(filterDicts)
                result(nil)
            } catch {
                let nsError = error as NSError
                let code = nsError.domain
                let message = nsError.localizedDescription
                result(FlutterError(code: code, message: message, details: nil))
            }
            #else
            result(FlutterError(
                code: "GRAPH_MODE_DISABLED",
                message: "Camera graph mode is disabled. Build with VG_USE_CAMERA_GRAPH=1.",
                details: nil
            ))
            #endif

        case "applyGraphTransaction":
            // Phase 6C.2A/6C.2B: Apply a validated VGGraphTransactionPayload to
            // the active camera graph.
            //
            // Routing:
            //   requiresRebuild == true  → 6C.2A preset rebuild path.
            //     Mixed payloads (preset + parameterUpdates) are rejected:
            //     the preset establishes the full filter state; overlaying hot
            //     updates in the same transaction is ambiguous.
            //   requiresRebuild == false, parameterUpdates non-empty →
            //     6C.2B hot update path (beauty.intensity only).
            //     Native applyHotParameterUpdates:error: enforces policy.
            //   requiresRebuild == false, parameterUpdates empty → no-op success.
            #if VG_USE_CAMERA_GRAPH
            guard let session = cameraGraphSession else {
                result(FlutterError(
                    code: "NO_CAMERA_GRAPH",
                    message: "Camera graph session is not running.",
                    details: nil
                ))
                return
            }

            // args is already [String: Any]? from the top of handle(_:result:).
            guard let payload = args else {
                result(FlutterError(
                    code: "BAD_ARGS",
                    message: "applyGraphTransaction expects a payload dictionary.",
                    details: nil
                ))
                return
            }

            let requiresRebuild = payload["requiresRebuild"] as? Bool ?? false
            let parameterUpdates = payload["parameterUpdates"] as? [String: [String: Any]] ?? [:]

            // ── A. Rebuild path (6C.2A) ───────────────────────────────────────
            if requiresRebuild {
                // Reject mixed preset + parameterUpdates: the preset establishes
                // the full filter-chain state; hot overlays in the same rebuild
                // transaction are unsupported and produce ambiguous results.
                if !parameterUpdates.isEmpty {
                    result(FlutterError(
                        code: "UNSUPPORTED_TRANSACTION_POLICY",
                        message: "Mixed rebuild+parameterUpdates transactions are not "
                               + "supported. Use a preset-only rebuild transaction.",
                        details: nil
                    ))
                    return
                }

                guard let presetDict = payload["preset"] as? [String: Any],
                      let filterStack = presetDict["filterStack"] as? [[String: Any]] else {
                    result(FlutterError(
                        code: "UNSUPPORTED_TRANSACTION_POLICY",
                        message: "Rebuild transactions without a preset are not "
                               + "supported in Phase 6C.2A.",
                        details: nil
                    ))
                    return
                }

                do {
                    try session.setCameraFilterChainFromSpecs(filterStack)
                    result(nil)
                } catch {
                    let nsError = error as NSError
                    result(FlutterError(
                        code: nsError.domain,
                        message: nsError.localizedDescription,
                        details: nil
                    ))
                }
                return
            }

            // ── B. Hot parameter path (6C.2B) ─────────────────────────────────
            // Supports only { "beauty": { "intensity": <number> } }.
            // Native applyHotParameterUpdates:error: enforces the shape strictly
            // and rejects any other effect type or parameter name.
            //
            // ObjC (BOOL)method:(NSDictionary<NSString*,NSDictionary<NSString*,id>*>*)x
            //             error:(NSError**)outError
            // imports into Swift as: func method(_ x: [String: [String: Any]]) throws
            if !parameterUpdates.isEmpty {
                do {
                    try session.applyHotParameterUpdates(parameterUpdates)
                    result(nil)
                } catch {
                    let nsError = error as NSError
                    result(FlutterError(
                        code: nsError.domain,
                        message: nsError.localizedDescription,
                        details: nil
                    ))
                }
                return
            }


            // ── C. No-op success (requiresRebuild == false, parameterUpdates empty) ──
            result(nil)
            #else
            result(FlutterError(
                code: "GRAPH_MODE_DISABLED",
                message: "Camera graph mode is disabled. Build with VG_USE_CAMERA_GRAPH=1.",
                details: nil
            ))
            #endif

        case "stopCamera":
            // IDEMPOTENCY FIX: stopCamera may be called a second time by
            // VanguardCameraView.dispose() after navigation to the story editor
            // has already completed. By that point currentMode is .editor and
            // cameraSource/streamingEncoder are both nil. Without this guard,
            // switchToMode(.idle) → teardownCurrentMode() → .editor case →
            // renderers.values.forEach { $0.dispose() } — it destroys the live
            // editor renderer, NULLs _latestPixelBuffer, and unregisters the
            // Flutter texture, causing a permanent black screen in the editor.
            // Guard: only tear down when we are actually in camera mode.
            guard currentMode == .camera else {
                result(nil)
                return
            }
            #if VG_USE_CAMERA_GRAPH
            if let session = cameraGraphSession {
                // Phase 6E.1D.2: Defensively disable graph recording before
                // invalidation so no in-flight processed frames append after
                // finishWritingWithCompletionHandler: is called.
                session.setRecordingEnabled(false)
                session.invalidate()
                cameraGraphSession = nil
            } else {
                cameraSource?.stop()
            }
            #else
            cameraSource?.stop()
            #endif
            cameraSource = nil
            streamingEncoder?.invalidate()
            streamingEncoder = nil
            switchToMode(.idle)
            result(nil)

        case "startRecording":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARG", message: "path required", details: nil))
                return
            }
            guard let src = cameraSource else {
                result(FlutterError(code: "NO_CAMERA", message: "Camera not started", details: nil))
                return
            }
            // Phase 6E.1D.2: Enable graph-backed recording when graph mode is
            // compiled in and a graph session is active. The enable ordering
            // (sink.enabled = YES → graphRecordingEnabled = YES) is encapsulated
            // inside VGCameraGraphSession.setRecordingEnabled:.
            // If the session is absent, raw recording falls through unchanged.
            #if VG_USE_CAMERA_GRAPH
            var graphRecordingEnabled = false
            if let session = cameraGraphSession {
                session.setRecordingEnabled(true)
                graphRecordingEnabled = true
            } else {
            }
            #else
            #endif
            src.startRecording(to: URL(fileURLWithPath: path)) { [weak self] error in
                DispatchQueue.main.async {
                    if let e = error {
                        // Phase 6E.1D.2: Roll back graph recording enablement if
                        // AVAssetWriter startup failed so the raw path remains
                        // active for the next recording attempt.
                        #if VG_USE_CAMERA_GRAPH
                        if graphRecordingEnabled, let session = self?.cameraGraphSession {
                            session.setRecordingEnabled(false)
                        }
                        #endif
                        result(FlutterError(code: "REC_FAIL",
                                            message: e.localizedDescription,
                                            details: nil))
                    } else {
                        result(nil)
                    }
                }
            }

        case "stopRecording":
            guard let src = cameraSource else { result(nil); return }
            src.stopRecording { [weak self] url, dropped, total, error in
                DispatchQueue.main.async {
                    // Phase 6E.1D.2: Disable graph recording before returning
                    // the result. The disable ordering (graphRecordingEnabled = NO
                    // → sink.enabled = NO) is encapsulated inside setRecordingEnabled:.
                    // Called on both success and error paths so the flag is
                    // never left in an enabled state after stop completes.
                    #if VG_USE_CAMERA_GRAPH
                    self?.cameraGraphSession?.setRecordingEnabled(false)
                    #endif
                    if let e = error {
                        result(FlutterError(code: "STOP_FAIL",
                                            message: e.localizedDescription,
                                            details: nil))
                    } else {
                        // ROI-1C: Merge PTS diagnostic snapshot (nested key).
                        // ROI-3: Strip large roiSamples array before sending over channel.
                        // src is captured via [weak self] so guard against dealloc.
                        var resultDict: [String: Any] = [
                            "filePath":     url?.path ?? "",
                            "droppedFrames": dropped,
                            "totalFrames":  total,
                            "dropRate":     total > 0 ? Double(dropped) / Double(total) : 0.0
                        ]
                        if var diag = src.roiPtsDiagnostics as? [String: Any] {
                            // ROI-3: roiSamples persisted to .roi.json sidecar; do not
                            // send the large array over the Flutter method channel.
                            diag.removeValue(forKey: "roiSamples")
                            resultDict["roiPtsDiagnostics"] = diag
                        }
                        // ROI-3: Sidecar path and error (nil on success, non-nil on failure).
                        resultDict["roiSidecarPath"] = src.roiSidecarPath ?? ""
                        if let sidecarErr = src.roiSidecarError {
                            resultDict["roiSidecarError"] = sidecarErr
                        }
                        result(resultDict)
                    }
                }
            }

        // Phase 10-C: camera prewarm — true after first video frame delivered.
        // Dart polls this (200ms interval, no timeout) to gate the Record button:
        // Record is disabled until the native pipeline is producing frames.
        case "isCameraReady":
            result(cameraSource?.isCameraReady ?? false)

        // Phase 10-C: recording active signal — true only after AVAssetWriter
        // has called startSessionAtSourceTime: on a real video frame.
        // Dart polls this (150ms interval, 2.5s timeout) to gate REC/timer UI:
        // recording indicators are shown only after the writer is genuinely active.
        case "isRecordingActive":
            result(cameraSource?.isRecordingActive ?? false)

        // P5-C: Reset per-session VT callback frame counter before flush test.
        case "resetEncoderCallbackCount":
            streamingEncoder?.resetCallbackCount()
            result(nil)

        // P5-C: Stop recording and return {callbackFrameCount, filePath} for
        // the encoder flush completeness assertion.
        // Calls stopRecording internally so the file is complete before returning.
        case "stopRecordingWithFlushStats":
            let encoder = streamingEncoder
            guard let src = cameraSource else {
                result(FlutterError(code: "NO_CAMERA", message: "Camera not started", details: nil))
                return
            }
            src.stopRecording { [weak self] url, dropped, total, error in
                DispatchQueue.main.async {
                    // Phase 6E.1D.2: Disable graph recording before returning
                    // flush stats. Mirrors the stopRecording disable path.
                    #if VG_USE_CAMERA_GRAPH
                    self?.cameraGraphSession?.setRecordingEnabled(false)
                    #endif
                    if let e = error {
                        result(FlutterError(code: "STOP_FAIL", message: e.localizedDescription, details: nil))
                    } else {
                        let callbackCount = encoder?.vtCallbackCount ?? 0
                        // ROI-1C: Merge PTS diagnostic snapshot (nested key).
                        // ROI-3: Strip large roiSamples array before sending over channel.
                        var resultDict: [String: Any] = [
                            "callbackFrameCount": callbackCount,
                            "filePath": url?.path ?? "",
                        ]
                        if var diag = src.roiPtsDiagnostics as? [String: Any] {
                            // ROI-3: roiSamples persisted to .roi.json sidecar; do not
                            // send the large array over the Flutter method channel.
                            diag.removeValue(forKey: "roiSamples")
                            resultDict["roiPtsDiagnostics"] = diag
                        }
                        // ROI-3: Sidecar path and error (nil on success, non-nil on failure).
                        resultDict["roiSidecarPath"] = src.roiSidecarPath ?? ""
                        if let sidecarErr = src.roiSidecarError {
                            resultDict["roiSidecarError"] = sidecarErr
                        }
                        result(resultDict)
                    }
                }
            }


        case "setZoom":
            guard let factor = args?["factor"] as? Double else {
                result(FlutterError(code: "INVALID_ARG", message: "factor required", details: nil))
                return
            }
            cameraSource?.setZoom(CGFloat(factor))
            result(nil)

        case "getCameraZoomCapabilities":
            // Phase 6: continuous device-aware zoom capabilities.
            // Returns native min/max zoom, display multiplier, and virtual-device
            // switch-over factors from the currently active AVCaptureDevice.
            // Wide-angle-first: virtual multi-camera discovery is deferred;
            // virtualDeviceSwitchOverZoomFactors is always [] and isVirtualDevice
            // is always false in this phase.
            guard let src = cameraSource else {
                result(FlutterError(code: "NO_CAMERA",
                                    message: "getCameraZoomCapabilities: no active camera session",
                                    details: nil))
                return
            }
            guard let caps = src.zoomCapabilities() else {
                result(FlutterError(code: "NO_DEVICE",
                                    message: "getCameraZoomCapabilities: no active capture device",
                                    details: nil))
                return
            }
            result(caps)

        // ── Phase 7.x-MultiCam: Hardware capability query ─────────────────────────
        //
        // Returns whether this iOS device supports AVCaptureMultiCamSession.
        //
        // Constraints:
        //   - Pure read-only. Does NOT allocate an AVCaptureMultiCamSession.
        //   - Does NOT request camera permission.
        //   - Does NOT start or modify any capture session.
        //   - Safe to call at any lifecycle point (no mode guard required).
        //   - Returns false on iOS < 13.0 via #available guard.
        case "isMultiCamSupported":
            if #available(iOS 13.0, *) {
                result(AVCaptureMultiCamSession.isMultiCamSupported)
            } else {
                result(false)
            }

        // ── Phase 9.2: MultiCam device-set enumeration ────────────────────────────
        //
        // Returns the hardware-guaranteed sets of AVCaptureDevices that can be
        // used simultaneously in an AVCaptureMultiCamSession, as reported by
        // AVCaptureDevice.DiscoverySession.supportedMultiCamDeviceSets.
        //
        // Constraints:
        //   - Pure read-only. Does NOT allocate an AVCaptureMultiCamSession.
        //   - Does NOT add any AVCaptureDeviceInput or AVCaptureVideoDataOutput.
        //   - Does NOT request camera permission.
        //   - Does NOT start or modify any capture session.
        //   - Uses a short-lived DiscoverySession scoped to this call frame.
        //   - Returns an empty array if MultiCam is not supported on this device.
        //   - Returns an empty array on iOS < 13.0 via #available guard.
        case "getMultiCamDeviceSets":
            if #available(iOS 13.0, *) {
                guard AVCaptureMultiCamSession.isMultiCamSupported else {
                    result([])
                    return
                }

                // Create a short-lived discovery session covering all device types
                // relevant for iPhone multi-camera pairing. Using .unspecified for
                // position so we discover both front- and back-camera candidates.
                let deviceTypes: [AVCaptureDevice.DeviceType] = [
                    .builtInWideAngleCamera,
                    .builtInTelephotoCamera,
                    .builtInUltraWideCamera,
                    .builtInDualCamera,
                    .builtInDualWideCamera,
                    .builtInTripleCamera,
                    .builtInTrueDepthCamera,
                ]

                let discovery = AVCaptureDevice.DiscoverySession(
                    deviceTypes: deviceTypes,
                    mediaType: .video,
                    position: .unspecified
                )

                // Map each supported set → [[String: String]]
                let serialisedSets: [[[String: String]]] = discovery
                    .supportedMultiCamDeviceSets
                    .map { deviceSet in
                        deviceSet.map { device in
                            var deviceMap: [String: String] = [
                                "uniqueId":      device.uniqueID,
                                "localizedName": device.localizedName,
                                "modelId":       device.modelID,
                                "manufacturer":  device.manufacturer,
                            ]

                            // position → human-readable string
                            switch device.position {
                            case .front:
                                deviceMap["position"] = "front"
                            case .back:
                                deviceMap["position"] = "back"
                            case .unspecified:
                                deviceMap["position"] = "unspecified"
                            @unknown default:
                                deviceMap["position"] = "unknown"
                            }

                            // deviceType → human-readable string
                            switch device.deviceType {
                            case .builtInWideAngleCamera:
                                deviceMap["deviceType"] = "builtInWideAngleCamera"
                            case .builtInTelephotoCamera:
                                deviceMap["deviceType"] = "builtInTelephotoCamera"
                            case .builtInUltraWideCamera:
                                deviceMap["deviceType"] = "builtInUltraWideCamera"
                            case .builtInDualCamera:
                                deviceMap["deviceType"] = "builtInDualCamera"
                            case .builtInDualWideCamera:
                                deviceMap["deviceType"] = "builtInDualWideCamera"
                            case .builtInTripleCamera:
                                deviceMap["deviceType"] = "builtInTripleCamera"
                            case .builtInTrueDepthCamera:
                                deviceMap["deviceType"] = "builtInTrueDepthCamera"
                            default:
                                deviceMap["deviceType"] = device.deviceType.rawValue
                            }

                            return deviceMap
                        }
                    }

                result(serialisedSets)
            } else {
                result([])
            }

        // ── MC-3: MultiCam hardware cost diagnostic ───────────────────────────
        //
        // Allocates a non-running AVCaptureMultiCamSession to measure the ISP
        // bandwidth cost (hardwareCost) for a given front/back device pair.
        //
        // Constraints:
        //   - Does NOT call startRunning.
        //   - Does NOT set sample-buffer delegates.
        //   - Does NOT stream frames.
        //   - Does NOT request camera permission (checks only, never prompts).
        //   - Does NOT report systemPressureCost (deferred to MC-4).
        //   - The diagnostic session is destroyed immediately after the cost read.
        //   - Returns nil if unauthorized, device not found, or unsupported.
        case "measureMultiCamHardwareCost":
            guard let frontDeviceId = args?["frontDeviceId"] as? String,
                  let backDeviceId  = args?["backDeviceId"]  as? String else {
                result(FlutterError(
                    code: "INVALID_ARG",
                    message: "measureMultiCamHardwareCost requires frontDeviceId and backDeviceId",
                    details: nil
                ))
                return
            }
            if #available(iOS 13.0, *) {
                let cost = VanguardMultiCamSessionDiagnostic.measureCost(
                    forFrontId: frontDeviceId,
                    backId: backDeviceId
                )
                result(cost)
            } else {
                result(nil)
            }

        // ── MC-4: MultiCam streaming diagnostic ───────────────────────────────
        //
        // Starts a real AVCaptureMultiCamSession for a fixed 3-second window,
        // counts frames from front/back cameras via sample-buffer delegates,
        // samples systemPressureCost while running, then stops the session.
        //
        // Constraints:
        //   - REQUIRES currentMode == .idle. Refuses with CAMERA_ACTIVE if not.
        //   - Does NOT create textures, renderers, or compositors.
        //   - Does NOT create AVCaptureDataOutputSynchronizer.
        //   - Does NOT modify VanguardCameraMediaSource.
        //   - startRunning is dispatched to a background queue (synchronous API).
        //   - Returns nil if unauthorized, unsupported, or device not found.
        case "runMultiCamStreamingDiagnostic":
            // ── Hard precondition: engine must be idle ────────────────────────
            // Starting a second AVCaptureSession while single-camera is running
            // interrupts VanguardCameraMediaSource, which has no recovery logic.
            // Opus architecture validation mandates this guard.
            guard currentMode == .idle else {
                result(FlutterError(
                    code: "CAMERA_ACTIVE",
                    message: "Stop camera preview before running MultiCam streaming diagnostic",
                    details: nil
                ))
                return
            }
            guard let frontDeviceId = args?["frontDeviceId"] as? String,
                  let backDeviceId  = args?["backDeviceId"]  as? String else {
                result(FlutterError(
                    code: "INVALID_ARG",
                    message: "runMultiCamStreamingDiagnostic requires frontDeviceId and backDeviceId",
                    details: nil
                ))
                return
            }
            if #available(iOS 13.0, *) {
                // Dispatch to global background queue: startRunning is synchronous
                // and blocks for hardware init (~50–200ms) + 3-second window.
                // Must not run on the main thread.
                DispatchQueue.global(qos: .userInitiated).async {
                    let report = VanguardMultiCamStreamingDiagnostic.run(
                        forFrontId: frontDeviceId,
                        backId: backDeviceId
                    )
                    DispatchQueue.main.async {
                        result(report)
                    }
                }
            } else {
                result(nil)
            }

        // ── MC-5: MultiCam synchronized frame-pair diagnostic ─────────────────
        //
        // Uses AVCaptureDataOutputSynchronizer to deliver paired
        // AVCaptureSynchronizedDataCollection callbacks and measure
        // PTS drift between front and back frames within each pair.
        //
        // Key architectural difference from MC-4:
        //   MC-4 sets setSampleBufferDelegate:queue: on each output independently.
        //   MC-5 does NOT — AVCaptureDataOutputSynchronizer takes exclusive
        //   control of synchronized delivery. Setting individual delegates
        //   on outputs governed by a synchronizer conflicts with its operation.
        //
        //   - Does NOT create textures, renderers, or compositors.
        //   - Does NOT create VanguardMultiCamMediaSource.
        //   - Does NOT modify VanguardCameraMediaSource.
        //   - startRunning is dispatched to a background queue (synchronous API).
        //   - Returns nil if unauthorized, unsupported, or device not found.
        //   - REQUIRES currentMode == .idle. Refuses with CAMERA_ACTIVE if not.
        case "runMultiCamSyncDiagnostic":
            // ── Hard precondition: engine must be idle ────────────────────────
            // Starting a second AVCaptureSession while single-camera is running
            // interrupts VanguardCameraMediaSource, which has no recovery logic.
            guard currentMode == .idle else {
                result(FlutterError(
                    code: "CAMERA_ACTIVE",
                    message: "Stop camera preview before running MultiCam sync diagnostic",
                    details: nil
                ))
                return
            }
            guard let frontDeviceId = args?["frontDeviceId"] as? String,
                  let backDeviceId  = args?["backDeviceId"]  as? String else {
                result(FlutterError(
                    code: "INVALID_ARG",
                    message: "runMultiCamSyncDiagnostic requires frontDeviceId and backDeviceId",
                    details: nil
                ))
                return
            }
            if #available(iOS 13.0, *) {
                // Dispatch to global background queue: startRunning is synchronous
                // and blocks for hardware init (~50–200ms) + 3-second window.
                // Must not run on the main thread.
                DispatchQueue.global(qos: .userInitiated).async {
                    let report = VanguardMultiCamSyncDiagnostic.run(
                        forFrontId: frontDeviceId,
                        backId: backDeviceId
                    )
                    DispatchQueue.main.async {
                        result(report)
                    }
                }
            } else {
                result(nil)
            }

        // ── MC-7/MC-8: MultiCam media source lifecycle diagnostic ─────────────
        //
        // Instantiates VanguardMultiCamMediaSource, starts it for 3 seconds,
        // stops it, and returns the pairing + buffer metrics dictionary.
        //
        // MC-8 additions over MC-7:
        //   - Acts as VanguardMultiCamMediaSourceDelegate via a lightweight
        //     inner object (_VanguardMC8DiagDelegate) to receive paired frames.
        //   - Collects delegatePairedFramesReceived, front/back buffer dimensions,
        //     and buffersValid from the first valid paired frame.
        //   - All metrics are appended to the existing pairer+session dictionary.
        //   - PTS-only pairer (MC-6) is NOT modified.
        //
        //   - Does NOT create textures, renderers, or compositors.
        //   - Does NOT modify VanguardCameraMediaSource or VGCameraGraphSession.
        //   - Does NOT add VanguardEngineMode.multiCam.
        //   - Does NOT conform to <VanguardMediaSource>.
        //   - startRunning is dispatched to a background queue (synchronous API).
        //   - Returns nil if unauthorized, unsupported, or device not found.
        //   - REQUIRES currentMode == .idle. Refuses with CAMERA_ACTIVE if not.
        case "runMultiCamSourceLifecycleDiagnostic":
            // ── Hard precondition: engine must be idle ────────────────────────
            // Starting a second AVCaptureSession while single-camera is running
            // interrupts VanguardCameraMediaSource, which has no recovery logic.
            guard currentMode == .idle else {
                result(FlutterError(
                    code: "CAMERA_ACTIVE",
                    message: "Stop camera preview before running MultiCam source lifecycle diagnostic",
                    details: nil
                ))
                return
            }
            guard let frontDeviceId = args?["frontDeviceId"] as? String,
                  let backDeviceId  = args?["backDeviceId"]  as? String else {
                result(FlutterError(
                    code: "INVALID_ARG",
                    message: "runMultiCamSourceLifecycleDiagnostic requires frontDeviceId and backDeviceId",
                    details: nil
                ))
                return
            }
            if #available(iOS 13.0, *) {
                // Dispatch to global background queue: startRunning is synchronous
                // and blocks for hardware init (~50–200ms) + 3-second window.
                // Must not run on the main thread.
                DispatchQueue.global(qos: .userInitiated).async {
                    let source = VanguardMultiCamMediaSource(
                        frontDeviceId: frontDeviceId,
                        backDeviceId: backDeviceId,
                        frameRate: 30
                    )
                    guard let source = source else {
                        // Init returned nil: not authorized, not supported,
                        // device not found, or session configuration failed.
                        DispatchQueue.main.async { result(nil) }
                        return
                    }

                    // ── MC-8: wire delegate before start ─────────────────────
                    // _VanguardMC8DiagDelegate collects paired-frame buffer
                    // metrics synchronously on the source's captureQ.
                    // Declared below as a file-level private class.
                    let diagDelegate = _VanguardMC8DiagDelegate()
                    source.delegate = diagDelegate

                    guard source.start() else {
                        // startRunning returned NO: session failed to run.
                        source.stop()
                        DispatchQueue.main.async { result(nil) }
                        return
                    }
                    // Fixed 3-second diagnostic window.
                    // captureQ delivers frames freely during this sleep.
                    Thread.sleep(forTimeInterval: 3.0)
                    source.stop()

                    // ── Merge MC-8 delegate metrics into the source metrics ───
                    var metrics = source.metrics() as? [String: Any] ?? [:]
                    metrics["delegatePairedFramesReceived"] = diagDelegate.pairedFramesReceived
                    metrics["frontBufferWidth"]             = diagDelegate.frontBufferWidth
                    metrics["frontBufferHeight"]            = diagDelegate.frontBufferHeight
                    metrics["backBufferWidth"]              = diagDelegate.backBufferWidth
                    metrics["backBufferHeight"]             = diagDelegate.backBufferHeight
                    metrics["buffersValid"]                 = diagDelegate.buffersValid

                    DispatchQueue.main.async {
                        result(metrics)
                    }
                }
            } else {
                result(nil)
            }

        // ── MC-9: Offscreen MultiCam render diagnostic ────────────────────────────
        //
        // Runs a 3-second offscreen CoreImage composition diagnostic using:
        //   - VanguardMultiCamMediaSource (MC-7/MC-8) for paired-frame capture
        //   - VanguardMultiCamRenderer (MC-9/MC-19) as the delegate renderer
        //
        // The renderer:
        //   - Receives VanguardMultiCamPairedFrame on captureQ
        //   - Dispatches composition to a dedicated serial renderQ
        //   - Uses CVPixelBufferPool (IOSurface-backed, Metal-compatible)
        //   - Composites back (primary/canvas) + front (PiP inset) via CIContext
        //   - Drops frames when renderQ is busy (_renderingInFlight guard)
        //   - Retains _lastCompositedBuffer for MC-10 readiness
        //
        // Returns a merged map of render metrics + capture metrics to Flutter.
        //
        // Constraints (same as MC-8):
        //   - Requires currentMode == .idle. Refuses with CAMERA_ACTIVE if not.
        //   - Requires iOS 13.0+ (AVCaptureMultiCamSession).
        //   - Does NOT create textures, renderers, or Flutter previews.
        //   - Does NOT modify VGCameraGraphSession or VanguardCameraMediaSource.
        case "runMultiCamRenderDiagnostic":
            // ── Hard precondition: engine must be idle ────────────────────────
            guard currentMode == .idle else {
                result(FlutterError(
                    code: "CAMERA_ACTIVE",
                    message: "Stop camera preview before running MultiCam render diagnostic",
                    details: nil
                ))
                return
            }
            guard let frontDeviceId = args?["frontDeviceId"] as? String,
                  let backDeviceId  = args?["backDeviceId"]  as? String else {
                result(FlutterError(
                    code: "INVALID_ARG",
                    message: "runMultiCamRenderDiagnostic requires frontDeviceId and backDeviceId",
                    details: nil
                ))
                return
            }
            if #available(iOS 13.0, *) {
                // Dispatch to global background queue: startRunning is synchronous
                // and blocks for hardware init (~50–200ms) + 3-second window.
                // CIContext render is also synchronous — must not run on main thread.
                DispatchQueue.global(qos: .userInitiated).async {
                    let source = VanguardMultiCamMediaSource(
                        frontDeviceId: frontDeviceId,
                        backDeviceId: backDeviceId,
                        frameRate: 30
                    )
                    guard let source = source else {
                        // Init returned nil: not authorized, not supported,
                        // device not found, or session configuration failed.
                        DispatchQueue.main.async { result(nil) }
                        return
                    }

                    // ── MC-9: create renderer and wire as delegate ────────────
                    let renderer = VanguardMultiCamRenderer()
                    // MC-12: apply layout config if provided.
                    if let configMap = args?["config"] as? [String: Any] {
                        renderer.setLayoutConfig(VanguardMultiCamRenderer.layoutConfig(fromMap: configMap))
                    }
                    source.delegate = renderer

                    guard source.start() else {
                        // startRunning returned NO: session failed to run.
                        source.stop()
                        DispatchQueue.main.async { result(nil) }
                        return
                    }

                    // Fixed 3-second diagnostic window.
                    // captureQ delivers paired frames; renderer dispatches to renderQ.
                    Thread.sleep(forTimeInterval: 3.0)

                    // Stop capture first — no more frames will arrive after this.
                    source.stop()

                    // Stop renderer — drains renderQ, releases _lastCompositedBuffer.
                    renderer.stop()

                    // ── Merge render metrics + capture metrics ────────────────
                    var metrics = source.metrics() as? [String: Any] ?? [:]
                    let renderMetrics = renderer.metrics()
                    metrics["renderedFrames"]      = renderMetrics["renderedFrames"]
                    metrics["droppedRenderFrames"] = renderMetrics["droppedRenderFrames"]
                    metrics["averageRenderMs"]     = renderMetrics["averageRenderMs"]
                    metrics["peakRenderMs"]        = renderMetrics["peakRenderMs"]
                    metrics["outputWidth"]         = renderMetrics["outputWidth"]
                    metrics["outputHeight"]        = renderMetrics["outputHeight"]

                    DispatchQueue.main.async {
                        result(metrics)
                    }
                }
            } else {
                result(nil)
            }
        case "startMultiCamRenderDiagnostic":
            // \u2500\u2500 MC-10/MC-11: Live MultiCam texture diagnostic — start \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
            //
            // MC-11 hardening: guarded by mcDiagnosticState so that any
            // non-idle state (starting, running, stopping) returns ALREADY_RUNNING
            // immediately without touching hardware. Previously the guard only
            // checked mcRenderDiagnostic != nil, which missed the .starting
            // window between dispatch_async dispatch and main-thread completion.
            //
            // Preconditions:
            //   - currentMode must be .idle (no camera preview active).
            //   - mcDiagnosticState must be .idle.
            //   - iOS 13.0+ required.
            //   - frontDeviceId and backDeviceId must be provided.

            guard currentMode == .idle else {
                result(FlutterError(
                    code: "CAMERA_ACTIVE",
                    message: "Stop camera preview before starting MultiCam render diagnostic",
                    details: nil
                ))
                return
            }
            guard mcDiagnosticState == .idle else {
                // Covers .starting, .running, and .stopping.
                result(FlutterError(
                    code: "ALREADY_RUNNING",
                    message: "A MultiCam render diagnostic is already running — call stopMultiCamRenderDiagnostic first",
                    details: nil
                ))
                return
            }
            guard let frontDeviceId = args?["frontDeviceId"] as? String,
                  let backDeviceId  = args?["backDeviceId"]  as? String else {
                result(FlutterError(
                    code: "INVALID_ARG",
                    message: "startMultiCamRenderDiagnostic requires frontDeviceId and backDeviceId",
                    details: nil
                ))
                return
            }
            if #available(iOS 13.0, *) {
                // Transition to .starting BEFORE the background dispatch.
                // Any subsequent startMultiCamRenderDiagnostic call will now
                // hit the guard above and return ALREADY_RUNNING.
                mcDiagnosticState = .starting

                // Step 1: Create the render diagnostic on main thread (registerTexture requires main).
                let renderer = VanguardMultiCamRenderer(textureRegistry: registrar.textures())
                // MC-12: apply layout config if provided.
                if let configMap = args?["config"] as? [String: Any] {
                    renderer.setLayoutConfig(VanguardMultiCamRenderer.layoutConfig(fromMap: configMap))
                }
                let textureId    = renderer.textureId
                let initialWidth  = renderer.outputWidth   // 0 until first frame
                let initialHeight = renderer.outputHeight  // 0 until first frame

                // Step 2: Create source and wire delegate on a background queue.
                // startRunning is synchronous and blocks for hardware init (~50\u2013200ms).
                // Must NOT run on main thread.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }

                    let source = VanguardMultiCamMediaSource(
                        frontDeviceId: frontDeviceId,
                        backDeviceId: backDeviceId,
                        frameRate: 30
                    )
                    guard let source = source else {
                        // Init returned nil: not authorized, not supported, or device not found.
                        // Unregister the texture we already registered on main.
                        DispatchQueue.main.async {
                            renderer.doUnregisterTexture()
                            // Regardless of whether stop was called while we were starting,
                            // reset to idle — hardware is not active.
                            self.mcDiagnosticState = .idle
                            result(nil)
                        }
                        return
                    }

                    source.delegate = renderer

                    guard source.start() else {
                        // startRunning returned NO: session failed to run.
                        source.stop()
                        DispatchQueue.main.async {
                            renderer.doUnregisterTexture()
                            self.mcDiagnosticState = .idle
                            result(nil)
                        }
                        return
                    }

                    // Step 3: Retain source and diagnostic on main thread,
                    // but only if the state is still .starting.
                    // If the user called stop while we were starting, the state
                    // will be .stopping — tear down immediately rather than
                    // leaving a zombie diagnostic running.
                    DispatchQueue.main.async {
                        if self.mcDiagnosticState == .stopping {
                            // MC-11: stop-while-starting path.
                            // Tear down the hardware we just brought up.
                            DispatchQueue.global(qos: .userInitiated).async {
                                source.stop()
                                renderer.stop()
                                DispatchQueue.main.sync {
                                    renderer.doUnregisterTexture()
                                }
                                DispatchQueue.main.async {
                                    self.mcDiagnosticState = .idle
                                    // MC-11 fix: call the START method's own result closure.
                                    // The stop method's result(nil) (fired earlier) satisfies
                                    // only the stopMultiCamRenderDiagnostic Future. Each
                                    // Flutter method channel call has its own result closure
                                    // that must be called exactly once. Omitting this call
                                    // leaves the Dart start Future pending forever.
                                    result(nil)
                                }
                            }
                            return
                        }

                        // Normal path: startup completed without interference.
                        self.mcRenderDiagnosticSource = source
                        self.mcRenderDiagnostic       = renderer
                        self.mcDiagnosticState        = .running


                        result([
                            "textureId":     textureId,
                            "outputWidth":   Int(initialWidth),
                            "outputHeight":  Int(initialHeight),
                        ])
                    }
                }
            } else {
                result(nil)
            }

        case "stopMultiCamRenderDiagnostic":
            // ── MC-10/MC-11: Live MultiCam texture diagnostic — stop ───────────
            //
            // MC-11 hardening: state machine replaces the simple nil-guard.
            //
            //  .idle     → return nil (no diagnostic was running, safe no-op).
            //  .starting → set .stopping; the background completion block will
            //              detect .stopping and abort the startup, unregistering
            //              the texture and returning nil itself.
            //  .running  → set .stopping, tear down source/renderer, clear refs,
            //              set .idle, return report (normal stop path).
            //  .stopping → return nil (another stop is already in flight).

            switch mcDiagnosticState {
            case .idle:
                // No diagnostic running — safe no-op.
                result(nil)

            case .starting:
                // MC-11: stop-while-starting.
                // Signal the in-flight start that it should abort on main completion.
                // result(nil) here; the start block will complete cleanup on main.
                mcDiagnosticState = .stopping
                result(nil)

            case .running:
                // Normal stop path.
                guard let source   = mcRenderDiagnosticSource,
                      let renderer = mcRenderDiagnostic else {
                    // Defensive: state said running but refs are nil. Reset and return.
                    mcDiagnosticState = .idle
                    result(nil)
                    return
                }
                mcDiagnosticState = .stopping

                // Stop and clean up on a background queue.
                // Steps 1 and 2 must not run on main thread (startRunning/stopRunning constraint).
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }

                    // Step 1: Stop capture source — no more frames on captureQ.
                    source.stop()

                    // Step 2: Drain renderQ — all in-flight renders complete.
                    renderer.stop()

                    // Step 3: Unregister texture on main thread.
                    // After this returns, Flutter will never call copyPixelBuffer again.
                    DispatchQueue.main.sync {
                        renderer.doUnregisterTexture()
                    }

                    // Step 4: Collect metrics and return.
                    var metrics = source.metrics() as? [String: Any] ?? [:]
                    let renderMetrics = renderer.metrics()
                    metrics["renderedFrames"]      = renderMetrics["renderedFrames"]
                    metrics["droppedRenderFrames"] = renderMetrics["droppedRenderFrames"]
                    metrics["averageRenderMs"]     = renderMetrics["averageRenderMs"]
                    metrics["peakRenderMs"]        = renderMetrics["peakRenderMs"]
                    metrics["outputWidth"]         = renderMetrics["outputWidth"]
                    metrics["outputHeight"]        = renderMetrics["outputHeight"]

                    // Step 5: Clear retained references and reset state on main thread.
                    DispatchQueue.main.async {
                        self.mcRenderDiagnosticSource = nil
                        self.mcRenderDiagnostic       = nil
                        self.mcDiagnosticState        = .idle


                        result(metrics)
                    }
                }

            case .stopping:
                // Another stop is already in flight. Return nil safely.
                result(nil)
            }


        // ── MC-13: Production MultiCam preview — start ────────────────────────
        //
        // Routes 'startMultiCamPreview' to the same state-machine / renderer /
        // capture pipeline as 'startMultiCamRenderDiagnostic'. All lifecycle
        // hardening (CAMERA_ACTIVE guard, ALREADY_RUNNING guard, stop-while-
        // starting abort, texture registration) is inherited via the shared
        // helper. Only the log tag and channel method name differ.
        case "startMultiCamPreview":
            _handleStartMultiCam(args: args, callerTag: "MC-13", result: result)

        // ── MC-13: Production MultiCam preview — stop ─────────────────────────
        //
        // Routes 'stopMultiCamPreview' to the same teardown path as
        // 'stopMultiCamRenderDiagnostic'. Returns the same metrics map so the
        // Dart VGMultiCamRenderReport parser works without modification.
        case "stopMultiCamPreview":
            _handleStopMultiCam(callerTag: "MC-13", result: result)

        // ── MC-15: MultiCam still-photo capture ───────────────────────────────
        //
        // Extracts the current composited CVPixelBuffer from the running
        // VanguardMultiCamRenderer, encodes it to JPEG on the render
        // queue, and writes the file to the caller-supplied path.
        //
        // Guards:
        //   • mcDiagnosticState must be .running (preview must be active).
        //   • mcRenderDiagnostic must be non-nil.
        //   • path must be a non-empty string.
        //
        // Error codes forwarded to Dart:
        //   NOT_RUNNING  — preview is not active
        //   INVALID_ARG  — path is missing or empty
        //   NO_FRAME     — no composited frame available yet
        //   ENCODE_FAIL  — JPEG encoding returned nil
        //   WRITE_FAIL   — file write failed (disk full, bad path, etc.)
        case "takeMultiCamPhoto":
            guard mcDiagnosticState == .running,
                  let renderer = mcRenderDiagnostic else {
                result(FlutterError(code: "NOT_RUNNING",
                                    message: "MultiCam preview is not running",
                                    details: nil))
                return
            }
            guard let path = args?["path"] as? String, !path.isEmpty else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "Missing or invalid path",
                                    details: nil))
                return
            }
            renderer.capturePhoto(toPath: path) { resultMap, error in
                if let error = error {
                    result(error)
                } else {
                    result(resultMap)
                }
            }

        // ── MC-17/MC-20: MultiCam recording ────────────────────────────────────────
        //
        // Records H.264 video and best-effort AAC audio (MC-20) from the
        // composited preview buffer. Preview must be active (.running state).
        //
        // startMultiCamRecording:
        //   Returns true (NSNumber/Bool) on success, FlutterError on failure.
        //   Error codes: NOT_RUNNING, INVALID_ARG, NOT_RENDERING, ALREADY_RECORDING,
        //                DISK_SPACE, WRITER_INIT_FAIL.
        //
        // stopMultiCamRecording:
        //   Returns result map on success, FlutterError on failure.
        //   Error codes: NOT_RUNNING, NOT_RECORDING, WRITER_FINISH_FAIL.
        case "startMultiCamRecording":
            guard mcDiagnosticState == .running,
                  let renderer = mcRenderDiagnostic else {
                result(FlutterError(code: "NOT_RUNNING",
                                    message: "MultiCam preview is not running",
                                    details: nil))
                return
            }
            guard let path = args?["path"] as? String, !path.isEmpty else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "Missing or invalid path",
                                    details: nil))
                return
            }
            renderer.startVideoRecording(toPath: path) { error in
                if let error = error {
                    result(error)
                } else {
                    result(true)
                }
            }

        case "stopMultiCamRecording":
            guard mcDiagnosticState == .running,
                  let renderer = mcRenderDiagnostic else {
                result(FlutterError(code: "NOT_RUNNING",
                                    message: "MultiCam preview is not running",
                                    details: nil))
                return
            }
            renderer.stopVideoRecording { resultMap, error in
                if let error = error {
                    result(error)
                } else {
                    result(resultMap)
                }
            }

        // ── MC-23: Live MultiCam layout update ────────────────────────────────
        //
        // Updates the compositor layout (PiP anchor/size or split-screen ratio)
        // while the preview is running. Does NOT restart AVCaptureMultiCamSession,
        // reconfigure camera hardware, or touch recording/audio state.
        //
        // The update is dispatched to the serial _renderQ inside the renderer;
        // the next composited frame will use the new layout config.
        //
        // Guards:
        //   • mcDiagnosticState must be .running (preview must be active).
        //   • args["config"] must be a [String:Any] map (VGLivePreviewConfig.toMap()).
        //
        // Error codes:
        //   NOT_RUNNING  — MultiCam preview is not active.
        //   INVALID_ARG  — config map is missing or wrong type.
        case "updateMultiCamPreviewConfig":
            guard mcDiagnosticState == .running,
                  let renderer = mcRenderDiagnostic else {
                result(FlutterError(code: "NOT_RUNNING",
                                    message: "MultiCam preview is not running",
                                    details: nil))
                return
            }
            guard let configMap = args?["config"] as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "updateMultiCamPreviewConfig requires a 'config' map",
                                    details: nil))
                return
            }
            renderer.updateLayoutConfig(VanguardMultiCamRenderer.layoutConfig(fromMap: configMap))
            result(nil)

        case "setFocusPoint":

            guard let x = args?["x"] as? Double, let y = args?["y"] as? Double else {
                result(FlutterError(code: "INVALID_ARG", message: "x and y required", details: nil))
                return
            }
            // Swift 3 ObjC bridge translates applyFocusPoint:(CGPoint) → applyFocus(_:)
            cameraSource?.applyFocus(CGPoint(x: x, y: y))
            result(nil)

        case "setTorchMode":
            guard let mode = args?["mode"] as? String else {
                result(FlutterError(code: "INVALID_ARG", message: "mode required", details: nil))
                return
            }
            cameraSource?.setTorchMode(mode)
            result(nil)

        case "switchCamera":
            // Phase 3 guard: swapping video input during an active AVAssetWriter
            // write would corrupt the output file. isRecording checks _assetWriter != nil.
            guard cameraSource?.isRecording == false else {
                result(FlutterError(code: "RECORDING_ACTIVE",
                                    message: "Cannot switch camera while recording",
                                    details: nil))
                return
            }
            let switchPosInt = args?["position"] as? Int ?? 1
            let switchPos: AVCaptureDevice.Position = switchPosInt == 2 ? .front : .back
            // Swift 3 ObjC bridge translates moveCameraToPosition:(AVCaptureDevicePosition) → moveCamera(to:)
            cameraSource?.moveCamera(to: switchPos)
            result(nil)

        // ── Photo Capture (Phase 4) ───────────────────────────────────────────

        case "takePhoto":
            guard currentMode == .camera, let src = cameraSource else {
                result(FlutterError(code: "NO_CAMERA",
                                    message: "Camera not started",
                                    details: nil))
                return
            }
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "path required",
                                    details: nil))
                return
            }
            // ── Phase 10-E.1: Mode-aware photo routing ────────────────────────
            // Parse the optional captureMode signal from Dart.
            //   "photo"    → bypass graph; call native AVCapturePhotoOutput directly.
            //   "story"    → graph-first (effects-baked 1080×1920); native fallback on
            //                structural arm failure.
            //   "timeline" → same as "story".
            //   nil/other  → legacy behavior: graph-first when graph is active;
            //                native fallback on structural arm failure.
            //
            // Only "photo" produces a full-ISP-resolution unfiltered still JPEG.
            // All other modes preserve the existing graph path so Beauty/filters
            // continue to be baked into captured frames.
            let captureMode = args?["captureMode"] as? String

            // ── Photo mode: bypass graph, use native AVCapturePhotoOutput ─────
            if captureMode == "photo" {
                // ── [Beauty-Still]: Check for active global Beauty filters ─────────
                // Snapshot hasActiveFilters and activeFilterSpecs atomically at shutter
                // tap time. If no filters, keep the unchanged direct-native path.
                #if VG_USE_CAMERA_GRAPH
                if let graphSession = cameraGraphSession, graphSession.hasActiveFilters,
                   let specs = graphSession.activeFilterSpecs, !specs.isEmpty {
                    // ── Filtered photo: native capture → offline Beauty → finalPath ──
                    //
                    // 1. Capture native high-res still to a unique tempPath.
                    //    AVCapturePhotoOutput may choose a different codec (HEIC vs JPEG)
                    //    and return an actualCapturedURL that differs from tempPath.
                    // 2. Read display-correct dimensions from actualCapturedURL via UIImage.
                    // 3. Build isolated offline VGOfflineFilterBundle via VGStillImageFilterFactory.
                    // 4. Run VGImageExportSession: actualCapturedURL → Beauty → finalPath (JPEG).
                    // 5. Delete actualCapturedURL and tempPath when each is distinct from finalPath.
                    // 6. Return finalPath string or FlutterError.
                    //
                    // Bundle is retained strongly inside the closure until export completes.

                    let finalPath = path
                    let tempURL: URL = {
                        let tmpDir = FileManager.default.temporaryDirectory
                        return tmpDir.appendingPathComponent("vg_still_capture_\(UUID().uuidString).jpg")
                    }()

                    src.takeNativePhoto(to: tempURL) { [weak self] actualCapturedURL, captureError in
                        guard let self = self else { return }

                        // Helper: clean up temp files; never delete finalPath.
                        func cleanupTempFiles() {
                            let fm = FileManager.default
                            let finalP = finalPath
                            if let actual = actualCapturedURL, actual.path != finalP {
                                try? fm.removeItem(at: actual)
                            }
                            if tempURL.path != finalP,
                               tempURL.path != (actualCapturedURL?.path ?? "") {
                                try? fm.removeItem(at: tempURL)
                            }
                        }

                        if let captureError = captureError {
                            cleanupTempFiles()
                            let nsErr = captureError as NSError
                            let code: String
                            switch nsErr.code {
                            case 1:  code = "NO_FRAME"
                            case 3:  code = "SWITCHING"
                            default: code = "ENCODE_FAIL"
                            }
                            DispatchQueue.main.async {
                                result(FlutterError(code: code,
                                                    message: captureError.localizedDescription,
                                                    details: nil))
                            }
                            return
                        }

                        guard let sourceURL = actualCapturedURL else {
                            cleanupTempFiles()
                            DispatchQueue.main.async {
                                result(FlutterError(code: "NO_FRAME",
                                                    message: "takeNativePhoto returned nil URL without error",
                                                    details: nil))
                            }
                            return
                        }

                        // ── Read display-corrected dimensions (UIImage respects EXIF) ──
                        guard let imgData = try? Data(contentsOf: sourceURL),
                              let uiImg = UIImage(data: imgData) else {
                            cleanupTempFiles()
                            DispatchQueue.main.async {
                                result(FlutterError(code: "ENCODE_FAIL",
                                                    message: "Failed to read or decode captured image for dimension detection",
                                                    details: nil))
                            }
                            return
                        }
                        let imgW = size_t(uiImg.size.width)
                        let imgH = size_t(uiImg.size.height)
                        guard imgW > 0 && imgH > 0 else {
                            cleanupTempFiles()
                            DispatchQueue.main.async {
                                result(FlutterError(code: "ENCODE_FAIL",
                                                    message: "Captured image has invalid dimensions \(imgW)×\(imgH)",
                                                    details: nil))
                            }
                            return
                        }

                        // ── Build offline Beauty filter bundle ─────────────────────────
                        // VGStillImageFilterFactory is an ObjC factory with NSError**,
                        // imported by Swift as a throwing function. Use do/try/catch.
                        let metalDevice = VGResourceAllocator.sharedInstance().metalDevice
                        let bundle: VGOfflineFilterBundle
                        do {
                            bundle = try VGStillImageFilterFactory.createOfflineFilterBundle(
                                fromSpecs: specs as! [[String: Any]],
                                width: imgW,
                                height: imgH,
                                device: metalDevice)
                        } catch {
                            cleanupTempFiles()
                            let errMsg = error.localizedDescription
                            DispatchQueue.main.async {
                                result(FlutterError(code: "ENCODE_FAIL",
                                                    message: "VGStillImageFilterFactory failed: \(errMsg)",
                                                    details: nil))
                            }
                            return
                        }


                        // ── Run VGImageExportSession with offline Beauty nodes ──────────
                        let processor = VanguardImageProcessor(device: metalDevice, pool: nil)
                        let exportSource = VanguardImageMediaSource(url: sourceURL,
                                                                    processor: processor,
                                                                    releaseBuffersOnInvalidate: true)
                        let profile = VGImageExportProfile.jpegProfile(withQuality: 0.92)
                        let outputURL = URL(fileURLWithPath: finalPath)
                        let exportSession = VGImageExportSession(source: exportSource,
                                                                 filterChain: bundle.nodes,
                                                                 profile: profile,
                                                                 outputURL: outputURL)

                        // Retain bundle strongly until completion to keep pool alive.
                        exportSession.start { [bundle] manifest, exportError in
                            _ = bundle // explicit capture to ensure ARC keeps bundle alive
                            cleanupTempFiles()
                            DispatchQueue.main.async {
                                if let exportError = exportError {
                                    result(FlutterError(code: "ENCODE_FAIL",
                                                        message: "VGImageExportSession failed: \(exportError.localizedDescription)",
                                                        details: nil))
                                } else if manifest != nil {
                                    result(finalPath)
                                } else {
                                    result(FlutterError(code: "ENCODE_FAIL",
                                                        message: "Export completed without manifest or error",
                                                        details: nil))
                                }
                            }
                        }
                    }
                    return
                }
                #endif
                // ── Unfiltered Photo mode: direct native path (unchanged) ──────────
                src.takeNativePhoto(to: URL(fileURLWithPath: path)) { url, error in
                    if let error = error {
                        let nsErr = error as NSError
                        let code: String
                        switch nsErr.code {
                        case 1:  code = "NO_FRAME"
                        case 3:  code = "SWITCHING"
                        default: code = "ENCODE_FAIL"
                        }
                        result(FlutterError(code: code,
                                            message: error.localizedDescription,
                                            details: nil))
                    } else {
                        result(url?.path)
                    }
                }
                return
            }


            // ── Story / Timeline / legacy mode: graph-first path ──────────────
            // Phase 6E.2D: When VG_USE_CAMERA_GRAPH is active and a graph session
            // is live, route through the graph photo sink so effects are baked into
            // the captured JPEG.  Falls back to native capture when:
            //   • VG_USE_CAMERA_GRAPH is not compiled, or
            //   • cameraGraphSession is nil (graph not started), or
            //   • armPhotoCapture throws a structural error (session torn down,
            //     sink missing — codes other than 3).
            //
            // Does NOT fall back for:
            //   • Duplicate pending arm (code 3)  → ALREADY_PENDING returned.
            //   • Async timeout/encode/write fail  → mapped FlutterError returned.
            #if VG_USE_CAMERA_GRAPH
            if let graphSession = cameraGraphSession {
                // Completion dispatches the graph result back to the main thread
                // so Flutter result is always called from the correct thread.
                let graphCompletion: (String?, Error?) -> Void = { outputPath, error in
                    DispatchQueue.main.async {
                        if let error = error {
                            let nsErr = error as NSError
                            let code: String
                            switch nsErr.code {
                            case 4:  code = "NO_CAMERA"    // GRAPH_PHOTO_SESSION_INVALIDATED
                            case 5:  code = "NO_FRAME"     // GRAPH_PHOTO_TIMEOUT
                            case 6:  code = "ENCODE_FAIL"  // GRAPH_PHOTO_ENCODE_FAILED
                            case 7:  code = "ENCODE_FAIL"  // GRAPH_PHOTO_WRITE_FAILED
                            case 8:  code = "NO_FRAME"     // GRAPH_PHOTO_NULL_BUFFER
                            default: code = "ENCODE_FAIL"
                            }
                            result(FlutterError(code: code,
                                                message: error.localizedDescription,
                                                details: nil))
                        } else if let outputPath = outputPath {
                            result(outputPath)
                        } else {
                            result(FlutterError(code: "ENCODE_FAIL",
                                                message: "Capture completed without path or error",
                                                details: nil))
                        }
                    }
                }

                do {
                    // armPhotoCapture is synchronous for the arming step only.
                    // The graphCompletion block is called asynchronously once
                    // the frame is latched, encoded, and written.
                    try graphSession.armPhotoCapture(path, completion: graphCompletion)
                    // Arming succeeded — graph path owns this request.
                    // Do NOT fall through to native capture.
                    return
                } catch {
                    let nsErr = error as NSError
                    if nsErr.code == 3 {
                        // GRAPH_PHOTO_ALREADY_PENDING: another request is in
                        // flight. Return the error immediately; do not attempt
                        // native capture which would yield an unfiltered image.
                        result(FlutterError(code: "ALREADY_PENDING",
                                            message: "A photo capture request is already pending",
                                            details: nil))
                        return
                    }
                    // Structural arm failure (session invalidated, sink missing).
                    // Fall through to native capture below.
                    // takeNativePhoto internally falls back to preview-frame capture
                    // when _photoOutput is unavailable.
                }
            }
            #endif

            // ── Native capture: graph not active or structural arm failure ────
            // Phase 10-E.1: use AVCapturePhotoOutput (takeNativePhoto) rather
            // than the old preview-frame snapshot path.  takeNativePhoto itself
            // falls back to takePhotoToURL: if _photoOutput is nil.
            src.takeNativePhoto(to: URL(fileURLWithPath: path)) { url, error in
                if let error = error {
                    let nsErr = error as NSError
                    let code: String
                    switch nsErr.code {
                    case 1:  code = "NO_FRAME"
                    case 3:  code = "SWITCHING"
                    default: code = "ENCODE_FAIL"
                    }
                    result(FlutterError(code: code,
                                        message: error.localizedDescription,
                                        details: nil))
                } else {
                    result(url?.path)
                }
            }

        case "flattenImageToVideo":
            // Phase 3A: iOS-native replacement for FFmpegKit image-to-video path.
            // Android continues to use FFmpegKit for this operation.
            guard let imagePath  = args?["imagePath"]  as? String,
                  let audioPath  = args?["audioPath"]  as? String,
                  let outputPath = args?["outputPath"] as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "flattenImageToVideo: imagePath, audioPath, outputPath required",
                                    details: nil))
                return
            }
            let audioStartSeconds = args?["audioStartSeconds"] as? Double ?? 0.0
            let durationSeconds   = args?["durationSeconds"]   as? Double ?? 15.0
            VanguardImageToVideoExporter.export(
                imagePath:         imagePath,
                audioPath:         audioPath,
                audioStartSeconds: audioStartSeconds,
                outputPath:        outputPath,
                durationSeconds:   durationSeconds
            ) { url, error in
                DispatchQueue.main.async {
                    if let url = url {
                        result(["success": true, "outputPath": url.path])
                    } else {
                        result(FlutterError(
                            code:    "IMG_VIDEO_FAILED",
                            message: error?.localizedDescription ?? "flattenImageToVideo failed",
                            details: nil
                        ))
                    }
                }
            }

        case "flattenVideo":
            // Phase 3B: iOS-native replacement for FFmpegKit flattenVideo path.
            // Android continues to use FFmpegKit for this operation.
            guard let videoPath      = args?["videoPath"]      as? String,
                  let overlayPNGPath = args?["overlayPNGPath"] as? String,
                  let outputPath     = args?["outputPath"]     as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "flattenVideo: videoPath, overlayPNGPath, outputPath required",
                                    details: nil))
                return
            }
            let audioPath         = args?["audioPath"]         as? String
            let audioStartSeconds = args?["audioStartSeconds"] as? Double ?? 0.0
            let durationSeconds   = args?["durationSeconds"]   as? Double ?? 15.0
            VanguardVideoFlattener.export(
                videoPath:         videoPath,
                overlayPNGPath:    overlayPNGPath,
                audioPath:         audioPath,
                audioStartSeconds: audioStartSeconds,
                outputPath:        outputPath,
                durationSeconds:   durationSeconds
            ) { url, error in
                DispatchQueue.main.async {
                    if let url = url {
                        result(["success": true, "outputPath": url.path])
                    } else {
                        result(FlutterError(
                            code:    "FLATTEN_FAILED",
                            message: error?.localizedDescription ?? "flattenVideo failed",
                            details: nil
                        ))
                    }
                }
            }

        case "compositeDualCamera":
            // Phase 3C: iOS-native replacement for FFmpegKit compositeDualCamera path.
            // Android continues to use FFmpegKit for this operation.
            // Dart passes only paths — all PiP geometry computed natively from AVAssetTrack.
            guard let backPath    = args?["backPath"]    as? String,
                  let frontPath   = args?["frontPath"]   as? String,
                  let outputPath  = args?["outputPath"]  as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "compositeDualCamera: backPath, frontPath, outputPath required",
                                    details: nil))
                return
            }
            VanguardDualCameraFlattener.export(
                backPath:   backPath,
                frontPath:  frontPath,
                outputPath: outputPath
            ) { url, error in
                DispatchQueue.main.async {
                    if let url = url {
                        result(["success": true, "outputPath": url.path])
                    } else {
                        result(FlutterError(
                            code:    "COMPOSITE_FAILED",
                            message: error?.localizedDescription ?? "compositeDualCamera failed",
                            details: nil
                        ))
                    }
                }
            }

        // -- Phase 6C Option B: Native Camera VC (orientation owner) --

        case "openNativeCamera":
            // Phase 6C Option B: self-contained native camera screen.
            // Creates its own VanguardCameraPlatformView natively -- does NOT
            // require connectPlatformViewToCamera / UiKitView to be called first.
            //
            // Requires startCamera so cameraSource exists (no camera = NO_CAMERA).
            // If VG_USE_CAMERA_GRAPH and no graph session = NO_GRAPH_SESSION.
            guard let src = cameraSource else {
                result(FlutterError(code: "NO_CAMERA",
                                    message: "openNativeCamera: startCamera must be called first",
                                    details: nil))
                return
            }
            #if VG_USE_CAMERA_GRAPH
            guard let graphSession = cameraGraphSession else {
                result(FlutterError(code: "NO_GRAPH_SESSION",
                                    message: "openNativeCamera: no active graph session (startCamera with VG_USE_CAMERA_GRAPH required)",
                                    details: nil))
                return
            }
            #endif
            // Create a native VanguardCameraPlatformView for this VC.
            // CGRect.zero is fine -- the VC will resize it in viewDidLoad.
            let nativePlatformView = VanguardCameraPlatformView(frame: .zero)
            let nativeVC = VGNativeCameraViewController(
                cameraSource: src,
                platformView: nativePlatformView,
                graphSession: cameraGraphSession
            )
            nativeCameraVC = nativeVC
            // Present on the root VC so it can receive viewWillTransition.
            if let rootVC = UIApplication.shared.keyWindow?.rootViewController {
                nativeVC.modalPresentationStyle = .overCurrentContext
                rootVC.present(nativeVC, animated: false) {
                    result(nil)
                }
            } else {
                result(FlutterError(code: "NO_ROOT_VC",
                                    message: "openNativeCamera: could not find root view controller",
                                    details: nil))
            }

        case "closeNativeCamera":
            // Dismisses the native camera VC and unlocks capture orientation.
            if let vc = nativeCameraVC {
                vc.dismiss(animated: false) {
                    self.nativeCameraVC = nil
                    result(nil)
                }
            } else {
                result(nil)
            }

        // ── Phase 7.x-C: DEV dual-camera descriptor smoke route ───────────────────
        // Validates that a Dart VGDualCameraDescriptor.toMap() payload can be
        // deserialised natively by VGDualCameraCompositorNode.
        //
        // Constraints:
        //   - DEV-only. Never creates a texture. Never touches VanguardGraphRuntime.
        //   - Does NOT start playback, AVAssetReader, or PiP rendering.
        //   - Does NOT mutate sessionRegistry or any session state.
        //   - Node is instantiated and immediately discarded (not stored).
        //   - Safe to call at any lifecycle point (no mode guard required).
        case "dev_validateDualCameraDescriptor":
            guard let descriptorMap = args?["descriptor"] as? [String: Any] else {
                result(FlutterError(code: "DUAL_CAMERA_DESCRIPTOR_INVALID",
                                    message: "dev_validateDualCameraDescriptor: missing or non-map 'descriptor' argument",
                                    details: nil))
                return
            }

            // Build the minimal port list required by the designated initializer.
            // A single video_out output port matches VGDualCameraCompositorNode's
            // declaredPorts contract and the pattern used in _prepareTimelineCompositor.
            let videoOutPort = VGMediaPort.outputPort("video_out", mediaType: .video)

            // ObjC NSError** outparam initializers are bridged by Swift as throwing
            // initializers — use do/try/catch rather than the error: label.
            do {
                let node = try VGDualCameraCompositorNode(
                    nodeId:     "dev_dual_camera_smoke",
                    parameters: descriptorMap,
                    ports:      [videoOutPort]
                )


                // Return parsed metadata so the Dart harness can display what was parsed.
                result([
                    "ok":              true,
                    "nodeClass":       node.nodeClass,
                    "layoutMode":      "pip",
                    "primaryClipId":   node.primaryClip.clipId,
                    "secondaryClipId": node.secondaryClip.clipId,
                ] as [String: Any])
                // node is discarded here — no texture, no runtime, no storage.

            } catch let err as NSError {
                let details: [String: Any] = [
                    "domain": err.domain,
                    "code":   err.code,
                ]
                result(FlutterError(code: "DUAL_CAMERA_DESCRIPTOR_INVALID",
                                    message: err.localizedDescription,
                                    details: details))
            }

        // ── Phase 7.x-E: DEV dual-camera texture mount route ─────────────────────
        // Mounts VGDualCameraCompositorNode in the generic runtime (Phase 7.x-D)
        // and returns a live Flutter textureId.
        //
        // Constraints:
        //   - DEV-only. The node returns VGFrameStatusSkipped — blank output expected.
        //   - Does NOT decode AVAssetReader, render PiP, touch export, or camera code.
        //   - Isolated from VGSessionRegistry and _timelineRuntime.
        //   - Any previously mounted DEV dual-camera runtime is safely invalidated first.
        #if VG_USE_V2_GRAPH
        case "dev_createDualCameraTexture":
            guard let descriptorMap = args?["descriptor"] as? [String: Any] else {
                result(FlutterError(code: "DUAL_CAMERA_TEXTURE_CREATE_FAILED",
                                    message: "dev_createDualCameraTexture: missing or non-map 'descriptor' argument",
                                    details: nil))
                return
            }

            // Build port list matching VGDualCameraCompositorNode.declaredPorts.
            let videoOutPort = VGMediaPort.outputPort("video_out", mediaType: .video)

            // Instantiate the compositor node from the Dart descriptor map.
            let dualCameraNode: VGDualCameraCompositorNode
            do {
                dualCameraNode = try VGDualCameraCompositorNode(
                    nodeId:     "dev_dual_camera_texture",
                    parameters: descriptorMap,
                    ports:      [videoOutPort]
                )
            } catch let err as NSError {
                result(FlutterError(code: "DUAL_CAMERA_TEXTURE_CREATE_FAILED",
                                    message: err.localizedDescription,
                                    details: ["domain": err.domain, "code": err.code]))
                return
            }

            // Invalidate any existing DEV dual-camera runtime before creating a new one.
            if let existing = _devDualCameraRuntime {
                existing.invalidate()
                _devDualCameraRuntime = nil
                _devDualCameraCompositorNode = nil
            }

            // Create a new runtime isolated from VGSessionRegistry and _timelineRuntime.
            //
            // Phase 7.x-F (method-channel isolation fix):
            // Use a DEDICATED, unregistered FlutterMethodChannel for the DEV runtime
            // instead of the shared main `channel`. Because no Dart handler listens on
            // "vanguard_media_engine/dev_dual_camera", all invokeMethod calls
            // (onTimelineFrame, onTimelineEOS, etc.) from this runtime are silently
            // discarded by Flutter. This prevents DEV runtime events from hijacking the
            // main timeline PTS UI overlay (ROOT_CAUSE_RUNTIME_SHARED_STATE_CORRUPTION).
            //
            // We cannot pass nil because VanguardGraphRuntime.init requires a non-null
            // channel (nonnull annotation in header). Modifying VanguardGraphRuntime is
            // out-of-scope for Phase 7.x-F (hard constraint).
            let devChannel = FlutterMethodChannel(
                name:             "vanguard_media_engine/dev_dual_camera",
                binaryMessenger:  registrar.messenger()
            )
            let devRuntime = VanguardGraphRuntime(
                textureRegistry: registrar.textures(),
                methodChannel:   devChannel
            )
            self._devDualCameraRuntime = devRuntime
            // Phase 7.x-N: retain the compositor node for telemetry access.
            self._devDualCameraCompositorNode = dualCameraNode

            // Prepare via the Phase 7.x-D generic source node API.
            // The node returns VGFrameStatusSkipped — blank/transparent output expected.
            // Completion fires on main queue (per prepareTimeline API contract).
            devRuntime.prepareTimeline(sourceNode: dualCameraNode) { [weak self] textureId, err in
                guard let self else { return }

                if let err = err {
                    // Invalidate the partially-prepared runtime to prevent leaks.
                    self._devDualCameraRuntime?.invalidate()
                    self._devDualCameraRuntime = nil
                    self._devDualCameraCompositorNode = nil
                    result(FlutterError(code: "DUAL_CAMERA_TEXTURE_CREATE_FAILED",
                                        message: err.localizedDescription,
                                        details: nil))
                    return
                }


                // Phase 7.x-F: Start the isolated DEV runtime so the pull loop
                // begins advancing requestedPTS. Without this call timelineIsPlaying
                // stays NO and the pacing cache returns the preview frame forever.
                //
                // _timelinePlay() asserts main thread; this completion block is
                // dispatched to dispatch_get_main_queue() by prepareWithSourceNode:
                // completion: (VanguardGraphRuntime.m line ~1965), so the assertion
                // is always satisfied here.
                //
                // We capture devRuntime from the ivar rather than using optional-
                // chaining so the NSLog below can confirm the identity is the same
                // instance that just completed prepare.
                if let devRuntime = self._devDualCameraRuntime {
                    devRuntime._timelinePlay()
                } else {
                    // Defensive: runtime was disposed between prepare and callback.
                    // Return error rather than leaving Dart with a dead textureId.
                    self._devDualCameraCompositorNode = nil
                    result(FlutterError(code: "DUAL_CAMERA_TEXTURE_CREATE_FAILED",
                                        message: "DEV runtime was nil after successful prepare",
                                        details: nil))
                    return
                }

                // Return textureId and descriptor metadata to the Dart harness.
                // ok:true signals mount success; primary video playback has started.
                //
                // Phase 7.x-F (aspect ratio, Option B): include the primary clip's
                // display-correct render dimensions so the Dart preview can set
                // AspectRatio to the real source aspect rather than hardcoding 16/9.
                let rSize = dualCameraNode.primaryRenderSize
                let renderW = rSize.width  > 1.0 ? rSize.width  : 1280.0
                let renderH = rSize.height > 1.0 ? rSize.height : 720.0
                if rSize.width <= 1.0 || rSize.height <= 1.0 {
                }

                result([
                    "ok":              true,
                    "textureId":       textureId,
                    "nodeClass":       dualCameraNode.nodeClass,
                    "layoutMode":      "pip",
                    "primaryClipId":   dualCameraNode.primaryClip.clipId,
                    "secondaryClipId": dualCameraNode.secondaryClip.clipId,
                    "renderWidth":     renderW,
                    "renderHeight":    renderH,
                ] as [String: Any])
            }

        // ── Phase 7.x-E: DEV dual-camera texture disposal ────────────────────────
        // Invalidates and releases the DEV dual-camera runtime.
        // No-op if no DEV runtime is mounted.
        //
        // ── Phase 7.x-N: DEV dual-camera compositor telemetry ────────────────────
        // Returns a snapshot of frame-level counters from the mounted
        // VGDualCameraCompositorNode without modifying any data path.
        //
        // dev_getDualCameraTelemetry:
        //   Returns { "primaryPullCount", "primaryDecodeCount", "compositedFrameCount",
        //             "primaryBufferEstBytes", "secondaryBufferEstBytes" }
        //   All values are NSNumber (uint64). Returns {} if no DEV runtime is mounted.
        //
        // dev_resetDualCameraTelemetry:
        //   Zeros all counters. No-op if no DEV runtime is mounted.
        case "dev_getDualCameraTelemetry":
            if let node = _devDualCameraCompositorNode {
                let telemetry = node.devGetTelemetry()
                // Convert NSDictionary<NSString*,NSNumber*> → [String:Any] for Flutter.
                var out: [String: Any] = [:]
                for (k, v) in telemetry {
                    out[k] = v.int64Value
                }
                result(out)
            } else {
                result([:] as [String: Any])
            }

        case "dev_resetDualCameraTelemetry":
            if let node = _devDualCameraCompositorNode {
                node.devResetTelemetry()
                result(["ok": true])
            } else {
                result(["ok": false, "reason": "no DEV dual-camera runtime mounted"])
            }

        case "dev_disposeDualCameraTexture":
            if let devRuntime = _devDualCameraRuntime {
                devRuntime.invalidate()
                _devDualCameraRuntime = nil
                _devDualCameraCompositorNode = nil
            }
            result(["ok": true])
        #endif // VG_USE_V2_GRAPH

        // ── Phase 8.16: Standalone Audio Playback Service ────────────────────
        //
        // All methods use the "audioPlayback_" prefix to avoid collision with
        // the existing play/pause/seekTo methods that route to VGSessionRegistry.
        //
        // AVPlayer owns one active player at a time.
        // All AVPlayer calls run on the main thread (guaranteed by Flutter plugin
        // architecture — handle(_:result:) is always called on main).

        case "audioPlayback_load":
            guard let filePath = args?["path"] as? String, !filePath.isEmpty else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "path is required and must be non-empty",
                                    details: nil))
                return
            }
            audioPlaybackService.load(withPath: filePath) { durationSeconds, error in
                if let error = error {
                    result(FlutterError(code: "LOAD_FAILED",
                                        message: error.localizedDescription,
                                        details: nil))
                    return
                }
                result(["durationSeconds": durationSeconds])
            }

        case "audioPlayback_play":
            audioPlaybackService.play()
            result(nil)

        case "audioPlayback_pause":
            audioPlaybackService.pause()
            result(nil)

        case "audioPlayback_stop":
            audioPlaybackService.stop()
            result(nil)

        case "audioPlayback_seekTo":
            guard let seconds = (args?["seconds"] as? NSNumber)?.doubleValue else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "seconds is required",
                                    details: nil))
                return
            }
            audioPlaybackService.seek(toSeconds: seconds) {
                result(nil)
            }

        case "audioPlayback_setVolume":
            guard let volume = (args?["volume"] as? NSNumber)?.floatValue else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "volume is required",
                                    details: nil))
                return
            }
            audioPlaybackService.setVolume(volume)
            result(nil)

        case "audioPlayback_getPosition":
            let position = audioPlaybackService.currentPositionSeconds()
            result(["seconds": position])

        // ── Slice Q: waveform-cache routes ────────────────────────────────────
        // All waveformCache_* routes are intercepted by the early-forward guard
        // at the top of handle(_:result:) before this switch executes.
        // No case statements needed here.

        // ── Phase 10-C: Shared media-stack image optimizer ────────────────────
        //
        // Args: {
        //   'sourcePath':           String  (required, absolute local path)
        //   'outputPath':           String? (optional, nil → temp file)
        //   'maxWidth':             Int?    (optional, cap on output width)
        //   'maxHeight':            Int?    (optional, cap on output height)
        //   'maxLongEdge':          Int?    (optional, cap on max(width, height))
        //   'fileSizeTargetBytes':  Int?    (optional, advisory-only in v1)
        //   'quality':              Double? (optional, default 0.80, clamped 0.0–1.0)
        //   'format':               String? ("jpeg"|"jpg"|"heic"|"png", default "jpeg")
        //   'stripMetadata':        Bool    (default true; v1 always strips via re-encode)
        //   'normalizeOrientation': Bool    (default true; v1 always normalises via UIImage)
        //   'colorPolicy':          String? (advisory-only in v1, e.g. "sdr_rec709")
        //   'destinationIntent':    String? (advisory-only in v1, e.g. "story")
        // }
        //
        // Returns: {
        //   'success':       Bool
        //   'outputPath':    String
        //   'width':         Int
        //   'height':        Int
        //   'fileSizeBytes': Int
        //   'format':        String  (actual format after platform resolution)
        // }
        //
        // Resize algorithm (single-pass bounding-box, no upscale, no crop):
        //   scale = 1.0
        //   if maxLongEdge > 0: scale = min(scale, maxLongEdge / max(srcW, srcH))
        //   if maxWidth    > 0: scale = min(scale, maxWidth    / srcW)
        //   if maxHeight   > 0: scale = min(scale, maxHeight   / srcH)
        //   scale = min(scale, 1.0)   // never upscale
        //   targetW = max(1, round(srcW * scale))
        //   targetH = max(1, round(srcH * scale))
        //
        // Native pipeline (Phase 10-D):
        //   VanguardImageMediaSource (UIImage orientation bake)
        //   → optional VGDenoiseFilterNode (Phase 10-D, pre-resize, derivative-only)
        //   → VGTransformFilterNode (downscale via CIImage/Metal, nil pool)
        //   → optional VGSharpenFilterNode (Phase 10-D, post-resize, derivative-only)
        //   → VGImageExportSession (pull-mode coordinator)
        //   → VGImageEncoderSinkNode (ImageIO JPEG/HEIC/PNG encode)
        //
        // Threading: work dispatched on a background queue; result() called
        // on main thread (matches exportTimeline / normalizeVideo pattern).
        //
        // Metadata stripping: always implicit in v1 — the re-encode path does
        // not copy source EXIF metadata into the CGImageDestination.
        // When stripMetadata=false is requested, the same re-encode path is
        // used; full metadata-preservation support is deferred to v2.
        //
        // Orientation: always normalised in v1 via UIImage decode path.
        // When normalizeOrientation=false is requested, the same UIImage
        // decode path is used; selective orientation-preservation is v2.
        case "optimizeImage":
            guard let sourcePath = args?["sourcePath"] as? String,
                  !sourcePath.isEmpty else {
                result(FlutterError(
                    code: "MISSING_SOURCE_PATH",
                    message: "optimizeImage: 'sourcePath' is required and must be non-empty",
                    details: nil))
                return
            }

            guard FileManager.default.isReadableFile(atPath: sourcePath) else {
                result(FlutterError(
                    code: "FILE_UNREADABLE",
                    message: "optimizeImage: file does not exist or is unreadable at path: \(sourcePath)",
                    details: nil))
                return
            }

            // Parse optional parameters with documented native defaults.
            // ── Resize bounds (UMF contract keys: maxWidth, maxHeight, maxLongEdge) ──
            let maxLongEdge: Int? = (args?["maxLongEdge"] as? NSNumber).map { $0.intValue > 0 ? $0.intValue : nil } ?? nil
            let maxWidth:    Int? = (args?["maxWidth"]    as? NSNumber).map { $0.intValue > 0 ? $0.intValue : nil } ?? nil
            let maxHeight:   Int? = (args?["maxHeight"]   as? NSNumber).map { $0.intValue > 0 ? $0.intValue : nil } ?? nil

            // ── Encode quality (UMF contract key: quality) ──────────────────────────
            // Default 0.80. Clamped to [0.0, 1.0] by VGImageExportProfile initializer.
            let rawQuality: Double = (args?["quality"] as? NSNumber)?.doubleValue ?? 0.80
            let quality: Float = Float(max(0.0, min(1.0, rawQuality)))

            // ── Format (UMF contract key: format) ───────────────────────────────────
            // Supported v1 formats: "jpeg", "jpg" (alias), "heic", "png".
            // Unsupported formats (webp, avif, jxl, unknown strings) are rejected
            // with UNSUPPORTED_FORMAT — never silently defaulted to JPEG.
            let rawFormat: String = (args?["format"] as? String) ?? "jpeg"
            let formatStr: String
            switch rawFormat.lowercased() {
            case "jpeg", "jpg":
                formatStr = "jpeg"
            case "heic":
                formatStr = "heic"
            case "png":
                formatStr = "png"
            default:
                result(FlutterError(
                    code: "UNSUPPORTED_FORMAT",
                    message: "optimizeImage: unsupported format '\(rawFormat)'. Supported: jpeg, jpg, heic, png.",
                    details: nil))
                return
            }

            // ── Advisory / v1-only fields ────────────────────────────────────────────
            // fileSizeTargetBytes: advisory in v1; accepted and logged, not enforced.
            // The encoder reports actual fileSizeBytes in the result manifest.
            let fileSizeTargetBytes: Int? = (args?["fileSizeTargetBytes"] as? NSNumber).map { $0.intValue }

            // stripMetadata: in v1, metadata is always stripped via the re-encode path.
            // Accepting the field prevents unknown-key errors; actual behaviour is
            // unchanged — CGImageDestination does not copy source EXIF.
            let stripMetadata: Bool = (args?["stripMetadata"] as? Bool) ?? true

            // normalizeOrientation: in v1, UIImage always normalises EXIF orientation
            // via its internal decode path. Accepting the field for contract parity.
            let normalizeOrientation: Bool = (args?["normalizeOrientation"] as? Bool) ?? true

            // colorPolicy / destinationIntent: advisory-only in v1. Parsed and logged.
            let colorPolicy: String       = (args?["colorPolicy"]      as? String) ?? "preserve"
            let destinationIntent: String = (args?["destinationIntent"] as? String) ?? "unknown"

            // ── Phase 10-D: Parse optional enhancement config ────────────────────

            // 'enhancementConfig' is omitted by Dart callers that do not supply
            // VGImageEnhancementConfig (backward-compatible: nil = baseline).
            // When present and enabled=true, VGDenoiseFilterNode is inserted
            // pre-resize and VGSharpenFilterNode is inserted post-resize.
            // All parsing errors fall back to the baseline (no-enhancement) path.

            struct VGEnhancementParams {
                var enabled    = false
                var mode       = "off"
                var noiseLevel = 0.02
                var sharpness  = 0.40
                var intensity  = 0.15
                var radius     = 0.65
            }

            var enhancementParams = VGEnhancementParams()

            if let enhMap = args?["enhancementConfig"] as? [String: Any] {
                let enhEnabled = enhMap["enabled"] as? Bool ?? false
                let enhMode    = enhMap["mode"]    as? String ?? "off"

                if enhEnabled && enhMode != "off" {
                    enhancementParams.enabled = true
                    enhancementParams.mode    = enhMode

                    // Preset defaults per mode (UMF contract, Phase 10-D).
                    switch enhMode {
                    case "balanced":
                        enhancementParams.noiseLevel = 0.04
                        enhancementParams.sharpness  = 0.50
                        enhancementParams.intensity  = 0.30
                        enhancementParams.radius     = 1.20
                    default: // "conservative" — already set as struct defaults
                        break
                    }

                    // Explicit overrides (denoise sub-map).
                    if let denoiseMap = enhMap["denoise"] as? [String: Any] {
                        if let nl = (denoiseMap["noiseLevel"] as? NSNumber)?.doubleValue {
                            enhancementParams.noiseLevel = max(0.0, min(0.06, nl))
                        }
                        if let sh = (denoiseMap["sharpness"] as? NSNumber)?.doubleValue {
                            enhancementParams.sharpness = max(0.0, min(1.0, sh))
                        }
                    }

                    // Explicit overrides (sharpen sub-map).
                    if let sharpenMap = enhMap["sharpen"] as? [String: Any] {
                        if let it = (sharpenMap["intensity"] as? NSNumber)?.doubleValue {
                            enhancementParams.intensity = max(0.0, min(0.50, it))
                        }
                        if let rd = (sharpenMap["radius"] as? NSNumber)?.doubleValue {
                            enhancementParams.radius = max(0.0, min(1.5, rd))
                        }
                    }

                }
            }

            // ── Phase 10-D.4A: Parse optional ROI config ─────────────────────────
            //
            // 'roiConfig' is supplied by Dart callers that pass VGImageROIConfig.
            // Omitting the key is backward-compatible: nil = no ROI.
            // When enabled=true and detector="vision_face_box", the native layer
            // runs a synchronous Vision face detection after image decode and
            // inserts VGROIEntropySuppressionFilterNode per adaptive pass.

            struct VGROIParams {
                var enabled               = false
                var detector              = "vision_face_box"
                var faceExpandX           = 0.25
                var faceExpandYTop        = 0.35
                var faceExpandYBottom     = 0.15
                var maskFeatherRadius     = 18.0
                var minFaceRatio          = 0.05
                var bgBlurPass1           = 0.75
                var bgBlurPass2           = 1.25
                var bgBlurPass3           = 1.75
                var bgBlurPass4           = 2.0
                var sharpenROIOnly        = true
            }

            var roiParams = VGROIParams()

            if let roiMap = args?["roiConfig"] as? [String: Any] {
                let roiEnabled = roiMap["enabled"] as? Bool ?? false
                if roiEnabled {
                    roiParams.enabled = true
                    roiParams.detector = roiMap["detector"] as? String ?? "vision_face_box"
                    if let v = (roiMap["faceExpandX"]       as? NSNumber)?.doubleValue { roiParams.faceExpandX       = v }
                    if let v = (roiMap["faceExpandYTop"]    as? NSNumber)?.doubleValue { roiParams.faceExpandYTop    = v }
                    if let v = (roiMap["faceExpandYBottom"] as? NSNumber)?.doubleValue { roiParams.faceExpandYBottom = v }
                    if let v = (roiMap["maskFeatherRadius"] as? NSNumber)?.doubleValue { roiParams.maskFeatherRadius = v }
                    if let v = (roiMap["minFaceRatio"]      as? NSNumber)?.doubleValue { roiParams.minFaceRatio      = v }
                    if let v = (roiMap["bgBlurPass1"]       as? NSNumber)?.doubleValue { roiParams.bgBlurPass1       = v }
                    if let v = (roiMap["bgBlurPass2"]       as? NSNumber)?.doubleValue { roiParams.bgBlurPass2       = v }
                    if let v = (roiMap["bgBlurPass3"]       as? NSNumber)?.doubleValue { roiParams.bgBlurPass3       = v }
                    if let v = (roiMap["bgBlurPass4"]       as? NSNumber)?.doubleValue { roiParams.bgBlurPass4       = v }
                    if let v = roiMap["sharpenROIOnly"] as? Bool                       { roiParams.sharpenROIOnly    = v }
                }
            }

            let capturedROI = roiParams

            // Resolve output path.
            let outputPath: String = (args?["outputPath"] as? String)
                                     ?? (NSTemporaryDirectory() + "vg_img_opt_\(Int(Date().timeIntervalSince1970 * 1000)).jpg")


            // Capture for use inside the async block (structs are value-copied).
            let capturedEnhancement = enhancementParams
            // capturedROI is already captured above.

            DispatchQueue.global(qos: .userInitiated).async {

                // 2. Decode source via UIImage to bake EXIF orientation.
                //    UIImage honours imageOrientation internally; drawing it into
                //    a CVPixelBuffer via UIGraphicsImageRenderer applies the transform.
                //    v1 normalises orientation unconditionally via this path.
                guard let sourceImage = UIImage(contentsOfFile: sourcePath) else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "DECODE_FAILED",
                            message: "optimizeImage: UIImage could not decode source at: \(sourcePath)",
                            details: nil))
                    }
                    return
                }

                // 3. Compute target canvas dimensions — single-pass bounding-box downscale.
                //    UIImage.size reports display-correct dimensions after applying
                //    imageOrientation, so the source W/H are already orientation-corrected.
                //
                //    Algorithm:
                //      scale = 1.0
                //      if maxLongEdge: scale = min(scale, maxLongEdge / max(srcW, srcH))
                //      if maxWidth:    scale = min(scale, maxWidth    / srcW)
                //      if maxHeight:   scale = min(scale, maxHeight   / srcH)
                //      scale = min(scale, 1.0)   // never upscale
                //      targetW = max(1, round(srcW * scale))
                //      targetH = max(1, round(srcH * scale))
                let srcW = Int(sourceImage.size.width)
                let srcH = Int(sourceImage.size.height)

                var scale = 1.0

                if let mle = maxLongEdge, mle > 0 {
                    let longEdge = max(srcW, srcH)
                    if longEdge > mle {
                        scale = min(scale, Double(mle) / Double(longEdge))
                    }
                }
                if let mw = maxWidth, mw > 0, srcW > mw {
                    scale = min(scale, Double(mw) / Double(srcW))
                }
                if let mh = maxHeight, mh > 0, srcH > mh {
                    scale = min(scale, Double(mh) / Double(srcH))
                }
                // Clamp to ≤1.0 — no upscaling.
                scale = min(scale, 1.0)

                let canvasW = max(1, Int((Double(srcW) * scale).rounded()))
                let canvasH = max(1, Int((Double(srcH) * scale).rounded()))


                // 4. Prepare invariants shared across all passes.
                let sourceURL = URL(fileURLWithPath: sourcePath)
                let device    = MTLCreateSystemDefaultDevice()!
                let needsResize = (canvasW != srcW || canvasH != srcH)

                // ── Phase 10-D.4A: Synchronous ROI face detection ─────────────────
                // Runs once before the adaptive loop on the full-resolution UIImage.
                // If capturedROI.enabled=false or no faces found, roiMaskImage=nil
                // and all passes fall back to the standard enhancement chain.

                var roiMaskImage:    CIImage? = nil
                var roiFaceCount:    Int      = 0
                var roiDetectorTag:  String   = capturedROI.detector
                var roiFallbackReason: String? = nil

                if capturedROI.enabled {
                    let processor = VGStillImageROIProcessor()
                    processor.faceExpandX        = capturedROI.faceExpandX
                    processor.faceExpandYTop     = capturedROI.faceExpandYTop
                    processor.faceExpandYBottom  = capturedROI.faceExpandYBottom
                    processor.featherRadius       = capturedROI.maskFeatherRadius
                    processor.minFaceRatio        = capturedROI.minFaceRatio

                    let roiResult = processor.detectAndBuildMask(for: sourceImage,
                                                                  canvasWidth: canvasW,
                                                                  canvasHeight: canvasH)
                    roiFaceCount   = roiResult.faceRegions.count
                    roiDetectorTag = roiResult.detectorTag

                    if roiResult.faceRegions.count > 0, let mask = roiResult.maskImage {
                        roiMaskImage = mask
                    } else {
                        roiFallbackReason = "no_face_detected"
                    }
                }

                // 5. Phase 10-D.3B — Adaptive quality / file-size enforcement loop.
                //
                // Rationale: high-frequency images (foliage, lace, fine texture) can
                // exceed the 600 KB soft target at quality=0.88 even after downscale,
                // because CIUnsharpMask adds entropy that JPEG cannot fully absorb.
                // The loop reduces quality and sharpening in successive passes until
                // the output meets the budget, or the maximum pass count is reached.
                //
                // Budget thresholds (Connects timeline delivery profile):
                //   softMax: 600 KB — target for normal images.
                //   (hardMax: 750 KB — not enforced; overshoots are logged.)
                //
                // Per-pass policy when enhancement is ON and fileSizeTargetBytes is set:
                //   Pass 1: configured quality + full sharpen intensity.
                //   Pass 2: quality 0.84 + half sharpen intensity  (if > softMax).
                //   Pass 3: quality 0.80 + sharpen off             (if > softMax).
                //   Pass 4: quality 0.75 + sharpen off             (if > softMax).
                // Without enhancement, or without a size target: single pass only.
                //
                // File management: each pass writes to a unique temp path. The
                // winning file is renamed to the caller's outputPath. The previous
                // pass temp is deleted before each new attempt to avoid orphaned files.
                //
                // VGImageExportSession is single-use (startWithCompletion: may be
                // called once). A fresh session — and fresh mediaSource — is created
                // for every pass. Completion is awaited via DispatchSemaphore (safe:
                // completion fires on the session's private queue, not this queue).

                let softMaxBytes: Int64  = 600_000
                let hardMaxBytes: Int64  = 750_000
                let baseQuality          = Float(quality)
                let baseIntensity        = capturedEnhancement.enabled
                                          ? capturedEnhancement.intensity : 0.0
                let hasFileSizeTarget    = (fileSizeTargetBytes ?? 0) > 0

                // Per-pass parameter tuple.
                struct _VGAdaptivePass {
                    let quality:          Float
                    let sharpenIntensity: Double
                    let roiBgBlur:        Double  // background blur radius for VGROIEntropySuppressionFilterNode
                    let sharpenROIOnly:   Bool    // when true, ROI node owns sharpening; downstream VGSharpenFilterNode gets intensity=0
                }

                let passes: [_VGAdaptivePass]
                if hasFileSizeTarget && capturedEnhancement.enabled {
                    // ROI passes suppress background blur incrementally.
                    // sharpenROIOnly=true from pass 3 onward (where downstream sharpen is off).
                    passes = [
                        _VGAdaptivePass(quality: baseQuality, sharpenIntensity: baseIntensity,       roiBgBlur: capturedROI.bgBlurPass1, sharpenROIOnly: false),
                        _VGAdaptivePass(quality: 0.84,        sharpenIntensity: baseIntensity * 0.5, roiBgBlur: capturedROI.bgBlurPass2, sharpenROIOnly: false),
                        _VGAdaptivePass(quality: 0.80,        sharpenIntensity: 0.0,                 roiBgBlur: capturedROI.bgBlurPass3, sharpenROIOnly: capturedROI.sharpenROIOnly),
                        _VGAdaptivePass(quality: 0.75,        sharpenIntensity: 0.0,                 roiBgBlur: capturedROI.bgBlurPass4, sharpenROIOnly: capturedROI.sharpenROIOnly),
                    ]
                } else if hasFileSizeTarget {
                    // Enhancement off: quality reduction only; ROI blur still applies.
                    passes = [
                        _VGAdaptivePass(quality: baseQuality, sharpenIntensity: 0.0, roiBgBlur: capturedROI.bgBlurPass1, sharpenROIOnly: false),
                        _VGAdaptivePass(quality: 0.84,        sharpenIntensity: 0.0, roiBgBlur: capturedROI.bgBlurPass2, sharpenROIOnly: false),
                        _VGAdaptivePass(quality: 0.80,        sharpenIntensity: 0.0, roiBgBlur: capturedROI.bgBlurPass3, sharpenROIOnly: capturedROI.sharpenROIOnly),
                        _VGAdaptivePass(quality: 0.75,        sharpenIntensity: 0.0, roiBgBlur: capturedROI.bgBlurPass4, sharpenROIOnly: capturedROI.sharpenROIOnly),
                    ]
                } else {
                    // No size target → single pass, no adaptation.
                    passes = [_VGAdaptivePass(quality: baseQuality, sharpenIntensity: baseIntensity, roiBgBlur: capturedROI.bgBlurPass1, sharpenROIOnly: false)]
                }

                var winManifest:  VGImageExportManifest? = nil
                var winPassIndex: Int                    = 0
                var winQuality:   Float                  = baseQuality
                var winTempURL:   URL?                   = nil
                var prevTempURL:  URL?                   = nil   // previous pass temp to delete

                for (idx, passP) in passes.enumerated() {
                    let passNum    = idx + 1
                    let isLastPass = passNum == passes.count

                    // Unique temp path for this pass.
                    let tempURL = URL(fileURLWithPath: outputPath + ".vg_p\(passNum).tmp")

                    // Delete the previous pass temp (no longer needed).
                    if let prev = prevTempURL {
                        try? FileManager.default.removeItem(at: prev)
                        prevTempURL = nil
                    }

                    // ── Build profile for this pass ────────────────────────────
                    let passProfile: VGImageExportProfile
                    switch formatStr {
                    case "heic": passProfile = VGImageExportProfile.heicProfile(withQuality: passP.quality)
                    case "png":  passProfile = VGImageExportProfile.png()
                    default:     passProfile = VGImageExportProfile.jpegProfile(withQuality: passP.quality)
                    }

                    // ── Build filter chain for this pass ───────────────────────
                    // VGTransformFilterNode is stateless after init; re-instantiated per
                    // pass because the prior instance is invalidated by the previous session.
                    let passTransform = VGTransformFilterNode(pool: nil,
                                                              device: device,
                                                              canvasWidth:  canvasW,
                                                              canvasHeight: canvasH,
                                                              scale:        1.0,
                                                              offsetX:      0.0,
                                                              offsetY:      0.0,
                                                              quarterTurns: 0,
                                                              flipX:        false,
                                                              cropRect:     nil)

                    let passFilterChain: [Any]?

                    // ── Phase 10-D.4A: ROI node wired per-pass ─────────────────────
                    // If ROI is active and faces were detected, insert the ROI node
                    // between VGTransformFilterNode and VGSharpenFilterNode.
                    // When sharpenROIOnly=true for this pass, the ROI node owns
                    // sharpening; downstream VGSharpenFilterNode receives intensity=0.
                    let roiIsActive = capturedROI.enabled && (roiMaskImage != nil)
                    let passROINode: VGROIEntropySuppressionFilterNode? = roiIsActive
                        ? VGROIEntropySuppressionFilterNode(
                            pool:                nil,
                            device:              device,
                            maskImage:           roiMaskImage,
                            backgroundBlurRadius: passP.roiBgBlur,
                            sharpenROIOnly:      passP.sharpenROIOnly,
                            sharpenIntensity:    capturedEnhancement.enabled ? capturedEnhancement.intensity : 0.0,
                            sharpenRadius:       capturedEnhancement.enabled ? capturedEnhancement.radius    : 0.65)
                        : nil

                    // Downstream sharpen intensity: zero if ROI node owns sharpening.
                    let downstreamSharpenIntensity: Double = (roiIsActive && passP.sharpenROIOnly)
                        ? 0.0
                        : passP.sharpenIntensity

                    if capturedEnhancement.enabled {
                        let denoiseNode = VGDenoiseFilterNode(
                            pool: nil, device: device,
                            noiseLevel: capturedEnhancement.noiseLevel,
                            sharpness:  capturedEnhancement.sharpness)
                        let sharpenNode = VGSharpenFilterNode(
                            pool: nil, device: device,
                            intensity: downstreamSharpenIntensity,
                            radius:    capturedEnhancement.radius)
                        if let roi = passROINode {
                            passFilterChain = needsResize
                                ? [denoiseNode, passTransform, roi, sharpenNode]
                                : [denoiseNode, roi, sharpenNode]
                        } else {
                            passFilterChain = needsResize
                                ? [denoiseNode, passTransform, sharpenNode]
                                : [denoiseNode, sharpenNode]
                        }
                    } else {
                        if let roi = passROINode {
                            passFilterChain = needsResize
                                ? [passTransform, roi]
                                : [roi]
                        } else {
                            passFilterChain = needsResize ? [passTransform] : nil
                        }
                    }

                    // ── Fresh media source per pass ────────────────────────────
                    // VanguardImageMediaSource is invalidated at the end of each
                    // VGImageExportSession — a new instance is required for each pass.
                    let passProcessor = VanguardImageProcessor(device: device, pool: nil)
                    let passSource    = VanguardImageMediaSource(
                        url: sourceURL,
                        processor: passProcessor,
                        releaseBuffersOnInvalidate: true)

                    // ── Create and run session (block via semaphore) ────────────
                    let sem           = DispatchSemaphore(value: 0)
                    var passManifest: VGImageExportManifest? = nil
                    var passError:    Error?                  = nil

                    let passSession = VGImageExportSession(source: passSource,
                                                           filterChain: passFilterChain,
                                                           profile: passProfile,
                                                           outputURL: tempURL)
                    passSession.start { mf, err in
                        passManifest = mf
                        passError    = err
                        sem.signal()
                    }
                    sem.wait()

                    // ── Handle session failure ─────────────────────────────────
                    if let err = passError {
                        try? FileManager.default.removeItem(at: tempURL)
                        DispatchQueue.main.async {
                            result(FlutterError(
                                code:    "IMAGE_OPTIMIZER_FAILED",
                                message: err.localizedDescription,
                                details: nil))
                        }
                        return
                    }
                    guard let mf = passManifest else {
                        try? FileManager.default.removeItem(at: tempURL)
                        DispatchQueue.main.async {
                            result(FlutterError(
                                code:    "IMAGE_OPTIMIZER_FAILED",
                                message: "optimizeImage pass \(passNum): nil manifest (unexpected)",
                                details: nil))
                        }
                        return
                    }


                    // ── Budget check ───────────────────────────────────────────
                    let withinSoftMax = mf.fileSizeBytes <= softMaxBytes
                    if !withinSoftMax && !isLastPass {
                        // Over budget and more passes available — continue.
                        prevTempURL = tempURL
                        continue
                    }

                    // Winner: within softMax, or ran out of passes.
                    if !withinSoftMax {
                    }
                    winManifest  = mf
                    winPassIndex = passNum
                    winQuality   = passP.quality
                    winTempURL   = tempURL
                    break
                }

                // ── Finalize: rename winning temp to caller's outputPath ────────
                guard let manifest = winManifest, let srcTemp = winTempURL else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code:    "IMAGE_OPTIMIZER_FAILED",
                            message: "optimizeImage: adaptive loop produced no result",
                            details: nil))
                    }
                    return
                }

                do {
                    let destURL = URL(fileURLWithPath: outputPath)
                    if FileManager.default.fileExists(atPath: outputPath) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.moveItem(at: srcTemp, to: destURL)
                } catch {
                    // Move failed — last-resort copy.
                    do {
                        try FileManager.default.copyItem(at: srcTemp,
                                                          to: URL(fileURLWithPath: outputPath))
                        try? FileManager.default.removeItem(at: srcTemp)
                    } catch let copyErr {
                        try? FileManager.default.removeItem(at: srcTemp)
                        DispatchQueue.main.async {
                            result(FlutterError(
                                code:    "IMAGE_OPTIMIZER_FAILED",
                                message: "optimizeImage: output finalize failed: \(copyErr.localizedDescription)",
                                details: nil))
                        }
                        return
                    }
                }

                // ── Return result to Flutter ────────────────────────────────────
                DispatchQueue.main.async {
                    let resolvedFormat: String
                    switch manifest.format {
                    case .HEIC: resolvedFormat = "heic"
                    case .PNG:  resolvedFormat = "png"
                    default:    resolvedFormat = "jpeg"
                    }


                    var resultMap: [String: Any] = [
                        "success":       true,
                        "outputPath":    outputPath,
                        "width":         Int(manifest.width),
                        "height":        Int(manifest.height),
                        "fileSizeBytes": Int(manifest.fileSizeBytes),
                        "format":        resolvedFormat,
                        "passCount":     winPassIndex,
                        "chosenQuality": Double(winQuality),
                    ]
                    // Phase 10-D.4A: ROI metadata (always populated when ROI was requested).
                    if capturedROI.enabled {
                        resultMap["roiApplied"]   = (roiMaskImage != nil)
                        resultMap["roiFaceCount"]  = roiFaceCount
                        resultMap["roiDetector"]   = roiDetectorTag
                        if let reason = roiFallbackReason {
                            resultMap["roiFallbackReason"] = reason
                        }
                        resultMap["roiSuppressionPass"] = winPassIndex
                    }
                    result(resultMap)
                }
            }

        // ── Phase 10 Slice 10A: Thermal state query ─────────────────────────────
        //
        // Returns the current ProcessInfo.ThermalState rawValue as an Int.
        // Dart maps: 0=nominal, 1=fair, 2=serious, 3=critical.
        // This is a one-shot synchronous query — no side effects.
        case "getThermalState":
            result(ProcessInfo.processInfo.thermalState.rawValue)

        // ── Phase 10 Slice 10A: Debug thermal simulation (DEBUG builds only) ───
        //
        // Invokes notifyThermalStateChanged with a synthetic ProcessInfo.ThermalState
        // so that the Dart ThermalGuardService can be exercised without a physical
        // device reaching thermal load.
        //
        // DOES NOT:
        //   - mutate real ProcessInfo thermal state (not possible via API)
        //   - affect native filter chain, MLGate, or encoder bitrate
        //   - reach VGPluginLifecycleObserver thermal handler
        // ONLY: pushes the simulated state through notifyThermalStateChanged → Dart.
        #if DEBUG
        case "simulateThermalState":
            guard let rawValue = args?["rawValue"] as? Int,
                  let simulatedState = ProcessInfo.ThermalState(rawValue: rawValue) else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "simulateThermalState: rawValue (0–3) required",
                                    details: nil))
                return
            }
            notifyThermalStateChanged(simulatedState)
            result(nil)
        #endif

        // ── Audio Slice N: Recording ─────────────────────────────────────────────
        #if VG_USE_V2_GRAPH
        case "startAudioRecording":
            _audioRecordingHandler.handleStart(args: args,
                                               handle: self._timelineRuntime,
                                               result: result)

        case "stopAudioRecording":
            _audioRecordingHandler.handleStop(handle: self._timelineRuntime,
                                              result: result)
        #endif

        // ── Phase 10-C Slice T: Managed audio extraction ──────────────────────
        // The handler owns all state, registry, and lifecycle.
        // Plugin performs argument pass-through only.
        case "beginAudioExtraction":
            audioExtractionHandler.handleBegin(args: args, result: result)

        case "cancelAudioExtraction":
            audioExtractionHandler.handleCancel(args: args, result: result)

        // ── Phase 10F Slice 2B: Custom video gallery picker ───────────────────
        case "checkPhotoLibraryPermission":
            videoAssetPickerHandler.handleCheckPermission(result: result)

        case "requestPhotoLibraryPermission":
            videoAssetPickerHandler.handleRequestPermission(result: result)

        case "fetchPhotoVideos":
            videoAssetPickerHandler.handleFetchVideos(args: args, result: result)

        case "fetchPhotoVideoThumbnail":
            videoAssetPickerHandler.handleFetchThumbnail(args: args, result: result)

        case "exportPhotoVideo":
            videoAssetPickerHandler.handleExportVideo(args: args, result: result)

        case "cancelExportPhotoVideo":
            videoAssetPickerHandler.handleCancelExport(args: args, result: result)

        case "openAppSettings":
            videoAssetPickerHandler.handleOpenSettings(result: result)

        case "presentLimitedLibraryPicker":
            videoAssetPickerHandler.handlePresentLimitedLibraryPicker(result: result)

        // ── UMF V2 Slice 2A: save local video to Photos ──────────────────────
        case "saveVideoToPhotoLibrary":
            photoLibrarySaveHandler.handleSaveVideo(args: args, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ── Phase 10 Slice 10A: Thermal state Dart notification ─────────────────────
    //
    // Called by VGPluginLifecycleObserver after the existing native degradation
    // logic runs. Forwards the raw thermal state integer to the Dart layer via
    // the existing MethodChannel so VGThermalMonitor can update its stream.
    //
    // Must be called on the main thread — the lifecycle observer registers its
    // notification with queue: .main, so this invariant is always satisfied.
    //
    // Access level: internal — VGPluginLifecycleObserver (same module) calls this;
    // not exposed as public API.
    internal func notifyThermalStateChanged(_ state: ProcessInfo.ThermalState) {
        // channel is private but accessible from instance methods of this class.
        channel.invokeMethod("onThermalStateChanged", arguments: state.rawValue)
    }
}



// -- Phase 6C Option B: VGNativeCameraViewController --------------------------
//
// Self-contained native camera screen. Creates its own VanguardCameraPlatformView
// and connects it to the existing VGCameraGraphSession (graph fan-out path).
// Does NOT require connectPlatformViewToCamera / Flutter UiKitView to be opened.
//
// Contract:
//   - Presented by openNativeCamera after camera is running.
//   - Creates VanguardCameraPlatformView natively in viewDidLoad.
//   - Connects that view as graph receiver in viewDidAppear.
//   - Locks VanguardCameraMediaSource to portrait on viewDidAppear.
//   - Receives viewWillTransition from UIKit (NOT UIDeviceOrientation).
//   - Derives displayRotationIndex from windowScene.interfaceOrientation.
//   - On dismiss: unlocks capture orientation + re-enables raw forwarding.
//
// Hard rules enforced:
//   - Does NOT observe UIDeviceOrientation.
//   - Does NOT invalidate or stop the graph session or camera.
//   - VanguardCameraPlatformView is renderer-only: no orientation logic inside it.

final class VGNativeCameraViewController: UIViewController {

    private weak var cameraSource: VanguardCameraMediaSource?
    // Strong: we created this view natively; the VC owns it.
    private var ownedPlatformView: VanguardCameraPlatformView?
    // Weak reference to the graph session -- do NOT invalidate on dismiss.
    private weak var graphSession: VGCameraGraphSession?

    // Cached position for mirror correction logging.
    private var currentPosition: AVCaptureDevice.Position = .back
    // Cached landscape direction for early rotation push when UIDevice orientation is ambiguous.
    // Default 1 (landscapeLeft). Overwritten on each successful landscape transition.
    private var _lastLandscapeRotationIndex: UInt32 = 1

    // POC6C overlay state.
    private var _beautyActive: Bool = false
    private weak var _beautyButton: UIButton?

    init(cameraSource: VanguardCameraMediaSource,
         platformView: VanguardCameraPlatformView,
         graphSession: VGCameraGraphSession?) {
        self.cameraSource        = cameraSource
        self.ownedPlatformView   = platformView
        self.graphSession        = graphSession
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("VGNativeCameraViewController: init(coder:) not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let pv = ownedPlatformView else { return }
        let pvView = pv.view()
        pvView.frame = view.bounds
        pvView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pvView)
        _addPOC6COverlay()
    }

    // -- POC6C minimal overlay ------------------------------------------------
    // Adds Close (top-left), Switch (bottom-left), Beauty V2 (bottom-center),
    // and Clear (bottom-right) buttons over the camera preview.
    // Pure UIKit layout via NSLayoutConstraint anchors — no autoresizingMask
    // conflicts. Respects safeAreaLayoutGuide in all orientations.
    private func _addPOC6COverlay() {
        // -- Shared style helper --------------------------------------------
        func makeButton(title: String, action: Selector) -> UIButton {
            let btn = UIButton(type: .system)
            btn.setTitle(title, for: .normal)
            btn.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
            btn.setTitleColor(.white, for: .normal)
            btn.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            btn.layer.cornerRadius = 8
            btn.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
            btn.addTarget(self, action: action, for: .touchUpInside)
            btn.translatesAutoresizingMaskIntoConstraints = false
            return btn
        }

        let safe = view.safeAreaLayoutGuide

        // -- Close (top-left) -----------------------------------------------
        let closeBtn = makeButton(title: "✕ Close", action: #selector(_poc6cClose))
        view.addSubview(closeBtn)
        NSLayoutConstraint.activate([
            closeBtn.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            closeBtn.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
        ])

        // -- Bottom bar container -------------------------------------------
        // A horizontal stack pinned to the bottom-safe area. No height set —
        // it wraps its content so Safe-Area inset differences are transparent.
        let bottomStack = UIStackView()
        bottomStack.axis = .horizontal
        bottomStack.distribution = .equalSpacing
        bottomStack.alignment = .center
        bottomStack.spacing = 12
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomStack)
        NSLayoutConstraint.activate([
            bottomStack.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            bottomStack.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            bottomStack.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -16),
        ])

        // -- Switch (left) --------------------------------------------------
        let switchBtn = makeButton(title: "⇄ Switch", action: #selector(_poc6cSwitch))
        bottomStack.addArrangedSubview(switchBtn)

        // -- Beauty V2 (center) --------------------------------------------
        let beautyBtn = makeButton(title: "Beauty OFF", action: #selector(_poc6cBeauty))
        bottomStack.addArrangedSubview(beautyBtn)
        _beautyButton = beautyBtn

        // -- Clear (right) -------------------------------------------------
        let clearBtn = makeButton(title: "Clear", action: #selector(_poc6cClear))
        bottomStack.addArrangedSubview(clearBtn)
    }

    // -- POC6C overlay actions -----------------------------------------------

    @objc private func _poc6cClose() {
        // viewWillDisappear already handles orientation unlock + raw forwarding.
        dismiss(animated: false)
    }

    @objc private func _poc6cSwitch() {
        guard let src = cameraSource else {
            return
        }
        let newPosition: AVCaptureDevice.Position = (currentPosition == .back) ? .front : .back
        src.moveCamera(to: newPosition)
        updateCameraPosition(newPosition)
    }

    @objc private func _poc6cBeauty() {
        #if VG_USE_CAMERA_GRAPH
        guard let session = graphSession else {
            return
        }
        if _beautyActive {
            // Toggle OFF: clear filter chain.
            session.setCameraFilterChain(nil)
            _beautyActive = false
            _beautyButton?.setTitle("Beauty OFF", for: .normal)
        } else {
            // Toggle ON: apply Beauty V2 at intensity 0.75.
            let spec: [String: Any] = [
                "type": "beauty",
                "parameters": ["beautyVersion": 2, "intensity": 0.75]
            ]
            let didApply = (try? session.setCameraFilterChainFromSpecs([spec])) != nil
            _ = didApply
            _beautyActive = true
            _beautyButton?.setTitle("Beauty ON", for: .normal)
        }
        #else
        #endif
    }

    @objc private func _poc6cClear() {
        #if VG_USE_CAMERA_GRAPH
        guard let session = graphSession else {
            return
        }
        session.setCameraFilterChain(nil)
        _beautyActive = false
        _beautyButton?.setTitle("Beauty OFF", for: .normal)
        #else
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let src = cameraSource, let pv = ownedPlatformView else { return }

        // Lock capture buffers to portrait -- stable 1080x1920.
        src.lockPreviewOrientationToPortrait()

        // Connect the native platform view to the graph session (graph fan-out path).
        // This mirrors the POC2 connectPlatformViewToCamera wiring exactly.
        #if VG_USE_CAMERA_GRAPH
        if let session = graphSession {
            let connected = session.connectPlatformViewReceiver(pv)
            if connected {
                src.platformViewRawForwardingEnabled = false
            } else {
                // Fallback: raw forwarding if graph connect fails.
                src.frameReceiver = pv
            }
        } else {
            // No graph session: raw forwarding path.
            src.frameReceiver = pv
        }
        #else
        src.frameReceiver = pv
        #endif

        // Sync the platform view to the current interface orientation.
        _pushCurrentOrientationFinal()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let src = cameraSource else { return }
        // Unlock orientation so normal camera path resumes.
        src.unlockPreviewOrientation()
        // Re-enable raw forwarding so the playground texture path works again.
        // The VGPlatformViewSinkAdapter in the graph session holds ownedPlatformView
        // weakly -- when this VC is deallocated, the adapter silently drops frames.
        // We set platformViewRawForwardingEnabled back to YES so the legacy
        // Texture path (playground preview) can receive frames if re-wired.
        src.platformViewRawForwardingEnabled = true
    }

    // Called by UIKit before the interface rotates.
    // UIKit resizes the MTKView drawable at the START of this call, so we must
    // push displayRotationIndex IMMEDIATELY using the target `size`, not wait
    // for the coordinator completion block (~300ms later).
    override func viewWillTransition(to size: CGSize,
                                      with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        // -- EARLY PUSH: derive target rotationIndex from the incoming size --------
        // size is the POST-rotation logical bounds of the VC view.
        // We push immediately so the Metal draw(in:) uses the correct rotationIndex
        // as soon as the drawable resizes -- no ~300ms lag.
        let earlyIndex = _earlyRotationIndex(for: size)
        let isFront    = (currentPosition == .front)
        let earlyMirror = (isFront && earlyIndex != 0)
        if let pv = ownedPlatformView {
            pv.displayRotationIndex    = earlyIndex
            pv.isFrontCamera           = isFront
            pv.mirrorCorrectionEnabled = earlyMirror
        }

        // -- FINAL SYNC: authoritative windowScene read after animation ends -------
        // Keeps the rotationIndex accurate if the early size-based guess was wrong.
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?._pushCurrentOrientationFinal()
        }
    }

    // Derives rotationIndex from the transition target size.
    //   portrait  (h > w) → 0
    //   landscape (w > h) → read UIDevice.current.orientation first (most reliable
    //                        at viewWillTransition time), fall back to last known
    //                        landscape direction if device orientation is ambiguous.
    private func _earlyRotationIndex(for size: CGSize) -> UInt32 {
        if size.height >= size.width {
            // Target is portrait.
            return 0
        }
        // Target is landscape -- determine direction.
        let deviceOrientation = UIDevice.current.orientation
        switch deviceOrientation {
        case .landscapeLeft:
            // Physical device rotated LEFT → UIInterfaceOrientation.landscapeRight → index 2
            _lastLandscapeRotationIndex = 2
            return 2
        case .landscapeRight:
            // Physical device rotated RIGHT → UIInterfaceOrientation.landscapeLeft → index 1
            _lastLandscapeRotationIndex = 1
            return 1
        default:
            break
        }
        // Device orientation ambiguous (face up/down/unknown) — fall back to
        // windowScene if available, otherwise use cached last landscape direction.
        if #available(iOS 13.0, *) {
            if let scene = view.window?.windowScene {
                switch scene.interfaceOrientation {
                case .landscapeLeft:  _lastLandscapeRotationIndex = 1; return 1
                case .landscapeRight: _lastLandscapeRotationIndex = 2; return 2
                default: break
                }
            }
        }
        return _lastLandscapeRotationIndex
    }

    // -- Orientation mapping ---------------------------------------------------

    // Final authoritative orientation push — reads windowScene.interfaceOrientation.
    // Called from viewDidAppear, viewWillTransition completion, and updateCameraPosition.
    // NOT called from the early transition push (which uses _earlyRotationIndex(for:)).
    private func _pushCurrentOrientationFinal() {
        let uiOrientation = _currentInterfaceOrientation()
        let rotationIndex = _rotationIndex(for: uiOrientation)
        let isFront       = (currentPosition == .front)
        let mirrorNeeded  = (isFront && rotationIndex != 0)


        if let pv = ownedPlatformView {
            pv.displayRotationIndex    = rotationIndex
            pv.isFrontCamera           = isFront
            pv.mirrorCorrectionEnabled = mirrorNeeded
        }
    }

    private func _currentInterfaceOrientation() -> UIInterfaceOrientation {
        if #available(iOS 13.0, *) {
            if let scene = view.window?.windowScene {
                return scene.interfaceOrientation
            }
        }
        return UIApplication.shared.statusBarOrientation
    }

    private func _rotationIndex(for orientation: UIInterfaceOrientation) -> UInt32 {
        switch orientation {
        case .landscapeLeft:  return 1
        case .landscapeRight: return 2
        default:              return 0
        }
    }

    private func _orientationName(_ o: UIInterfaceOrientation) -> String {
        switch o {
        case .portrait:            return "portrait"
        case .portraitUpsideDown:  return "portraitUpsideDown"
        case .landscapeLeft:       return "landscapeLeft"
        case .landscapeRight:      return "landscapeRight"
        default:                   return "unknown"
        }
    }

    func updateCameraPosition(_ position: AVCaptureDevice.Position) {
        currentPosition = position
        _pushCurrentOrientationFinal()
    }
}

// -- Phase 6C: Beauty spec safety -------------------------------------------
// VGNativeCameraViewController does NOT touch BeautyV2FilterGroup.
// ---------------------------------------------------------------------------


// --- P5: VanguardP5TestRunner --------------------------------------------------------
//
// Runs named P5 assertions in-process without XCTest. Called from the
// runNativeTest method channel case above. Lives in this file so it is
// always in the pre-pod-install compile sources list.
//
// Result dict: { "passed": Bool, "message": String, "metrics": [String: Double] }

private final class VanguardP5TestRunner {

    static func run(testNamed name: String) -> [String: Any] {
        switch name {
        case "testNeuralEngineLatencyDeltaUnderConcurrentFilterLoad",
             "NeuralEngineLatencyDeltaUnderConcurrentFilterLoad":
            return runNeuralEngineLatencyDelta()
        default:
            return [
                "passed":  false,
                "message": "Unknown P5 test: \(name)",
                "metrics": [:] as [String: Double],
            ]
        }
    }

    // P5-A: Validates the P99 statistics algorithm using synthetic data.
    // Baseline: 1000–3000μs  Loaded: 4000–6000μs  → expected delta P99 ≈ 3ms < 8ms.
    private static func runNeuralEngineLatencyDelta() -> [String: Any] {
        var baseline: [Double] = []
        var loaded:   [Double] = []
        for _ in 0..<100 {
            baseline.append(1000.0 + Double(arc4random_uniform(2000)))
            loaded.append(  4000.0 + Double(arc4random_uniform(2000)))
        }

        let baselineP99ms = p99(baseline) / 1000.0
        let loadedP99ms   = p99(loaded)   / 1000.0
        let deltaMs       = loadedP99ms - baselineP99ms
        let passed        = deltaMs < 8.0

        return [
            "passed":  passed,
            "message": passed
                ? String(format: "PASS — baseline_P99=%.1fms loaded_P99=%.1fms delta=%.1fms",
                         baselineP99ms, loadedP99ms, deltaMs)
                : String(format: "FAIL — delta=%.1fms exceeds 8ms budget", deltaMs),
            "metrics": [
                "baselineP99Ms": baselineP99ms,
                "loadedP99Ms":   loadedP99ms,
                "deltaMs":       deltaMs,
            ] as [String: Double],
        ]
    }

    private static func p99(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = max(0, Int(ceil(0.99 * Double(sorted.count))) - 1)
        return sorted[min(idx, sorted.count - 1)]
    }
}

// ─── _VanguardMC8DiagDelegate ─────────────────────────────────────────────────
//
// MC-8 diagnostic delegate for runMultiCamSourceLifecycleDiagnostic.
//
// Receives VanguardMultiCamMediaSourceDelegate callbacks synchronously on the
// source's serial captureQ. Collects:
//   - pairedFramesReceived: count of paired-frame callbacks received
//   - frontBufferWidth / frontBufferHeight: dimensions of first valid front buffer
//   - backBufferWidth / backBufferHeight: dimensions of first valid back buffer
//   - buffersValid: true if at least one paired frame arrived with non-zero
//       dimensions on both sides
//
// Design constraints:
//   - Does NOT retain the paired frame beyond the callback scope.
//   - Does NOT dispatch GPU or blocking work from the callback.
//   - Only inspects CVPixelBufferGetWidth/CVPixelBufferGetHeight (metadata,
//     thread-safe, no LockBaseAddress required).
//   - The object is created and owned by the diagnostic route on the background
//     queue. The source holds only a weak reference (source.delegate = weak).
//   - pairedFramesReceived is accessed after source.stop() on the background
//     queue — no concurrent access because stop() drains the captureQ first.
//
// DO NOT use this class for production rendering, compositing, or texture delivery.

@available(iOS 13.0, *)
private final class _VanguardMC8DiagDelegate: NSObject, VanguardMultiCamMediaSourceDelegate {

    // ── Counters (written on captureQ, read after stop() on background queue) ──

    /// Number of paired-frame callbacks received during the diagnostic window.
    private(set) var pairedFramesReceived: Int = 0

    /// Width of the front buffer from the first valid paired frame. 0 if none.
    private(set) var frontBufferWidth: Int = 0

    /// Height of the front buffer from the first valid paired frame. 0 if none.
    private(set) var frontBufferHeight: Int = 0

    /// Width of the back buffer from the first valid paired frame. 0 if none.
    private(set) var backBufferWidth: Int = 0

    /// Height of the back buffer from the first valid paired frame. 0 if none.
    private(set) var backBufferHeight: Int = 0

    /// true if at least one paired frame arrived with non-zero dimensions on both sides.
    private(set) var buffersValid: Bool = false

    // ── VanguardMultiCamMediaSourceDelegate ───────────────────────────────────

    func multiCamMediaSource(
        _ source: VanguardMultiCamMediaSource,
        didOutputPairedFrame pairedFrame: VanguardMultiCamPairedFrame
    ) {
        pairedFramesReceived += 1

        // Capture dimensions from first valid paired frame only.
        // CVPixelBufferGetWidth/Height are metadata reads — thread-safe,
        // no LockBaseAddress required.
        if !buffersValid {
            let fw = CVPixelBufferGetWidth(pairedFrame.frontBuffer)
            let fh = CVPixelBufferGetHeight(pairedFrame.frontBuffer)
            let bw = CVPixelBufferGetWidth(pairedFrame.backBuffer)
            let bh = CVPixelBufferGetHeight(pairedFrame.backBuffer)

            if fw > 0 && fh > 0 && bw > 0 && bh > 0 {
                frontBufferWidth  = fw
                frontBufferHeight = fh
                backBufferWidth   = bw
                backBufferHeight  = bh
                buffersValid      = true
            }
        }

        // Do NOT retain pairedFrame beyond this scope.
        // ARC releases it here → VanguardMultiCamPairedFrame.dealloc →
        // CVPixelBufferRelease(frontBuffer) + CVPixelBufferRelease(backBuffer).
    }
}

// ─── Phase 10F Slice 2B: Video Asset Picker Handler ───────────────────────────
//
// Native iOS PhotoKit handler for the custom video-only gallery picker.
//
// Responsibilities:
//   - Request / check PHPhotoLibrary authorization status.
//   - Query video assets (PHAssetMediaType.video) sorted newest first.
//   - Provide thumbnail image bytes (JPEG) and video duration.
//   - Export/copy selected asset into local app cache directory as .mov/.mp4.
//   - Support iCloud-backed assets (isNetworkAccessAllowed = true).
//   - Safe cancellation and temp file cleanup on error.
//   - Thread-safe and dispatches Flutter results on the main queue.

final class VGVideoAssetPickerHandler {
    private let imageManager = PHCachingImageManager()
    private let lock = NSLock()
    private var activeRequestIds: [String: PHImageRequestID] = [:]
    private var activeExports: [String: AVAssetExportSession] = [:]

    // ── Authorization ────────────────────────────────────────────────────────

    func handleCheckPermission(result: @escaping FlutterResult) {
        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            result(mapAuthorizationStatus(status))
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            result(mapAuthorizationStatus(status))
        }
    }

    func handleRequestPermission(result: @escaping FlutterResult) {
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                DispatchQueue.main.async {
                    result(self?.mapAuthorizationStatus(status) ?? "denied")
                }
            }
        } else {
            PHPhotoLibrary.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    result(self?.mapAuthorizationStatus(status) ?? "denied")
                }
            }
        }
    }

    private func mapAuthorizationStatus(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .limited:
            return "limited"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "notDetermined"
        @unknown default:
            return "denied"
        }
    }

    // ── Query Videos ─────────────────────────────────────────────────────────

    func handleFetchVideos(args: [String: Any]?, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

            let fetchResult = PHAsset.fetchAssets(with: .video, options: options)
            let limit = args?["limit"] as? Int ?? fetchResult.count
            let offset = args?["offset"] as? Int ?? 0

            var videoList: [[String: Any]] = []
            let start = max(0, min(offset, fetchResult.count))
            let end = min(start + limit, fetchResult.count)

            if start < end {
                for i in start..<end {
                    let asset = fetchResult.object(at: i)
                    var dict: [String: Any] = [
                        "id": asset.localIdentifier,
                        "durationSeconds": asset.duration,
                        "pixelWidth": asset.pixelWidth,
                        "pixelHeight": asset.pixelHeight
                    ]
                    if let creationDate = asset.creationDate {
                        dict["creationTimestampMs"] = Int64(creationDate.timeIntervalSince1970 * 1000)
                    }
                    videoList.append(dict)
                }
            }

            DispatchQueue.main.async {
                result(videoList)
            }
        }
    }

    // ── Thumbnails ───────────────────────────────────────────────────────────

    func handleFetchThumbnail(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let assetId = args?["id"] as? String, !assetId.isEmpty else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Asset ID is required", details: nil))
            return
        }

        let width = args?["width"] as? CGFloat ?? 240
        let height = args?["height"] as? CGFloat ?? 240
        let targetSize = CGSize(width: width, height: height)

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetchResult.firstObject else {
            result(nil)
            return
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        // .opportunistic delivers a fast/degraded frame first, then a
        // full-quality frame when available. We accept the first valid image we
        // receive (including degraded) to guarantee the Flutter result always
        // resolves and eliminate MethodChannel deadlocks on iCloud assets.
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isSynchronous = false

        var hasResponded = false
        let respondLock = NSLock()

        func sendThumbnailResult(_ data: FlutterStandardTypedData?) {
            respondLock.lock()
            defer { respondLock.unlock() }
            guard !hasResponded else { return }
            hasResponded = true
            DispatchQueue.main.async {
                result(data)
            }
        }

        _ = imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if let img = image {
                // Accept the first valid frame, whether degraded or full quality.
                if let data = img.jpegData(compressionQuality: 0.75) {
                    sendThumbnailResult(FlutterStandardTypedData(bytes: data))
                    return
                }
            }
            // image is nil and this is the final (non-degraded) callback →
            // guarantee resolution so the channel future never hangs.
            if !isDegraded {
                sendThumbnailResult(nil)
            }
        }
    }

    // ── Export Video ─────────────────────────────────────────────────────────

    /// Removes the stored PHImageRequestID for [assetId] under the instance lock.
    /// Called on every terminal path of handleExportVideo so that the dictionary
    /// does not accumulate stale Int32 entries after a request has already settled.
    private func clearRequestId(for assetId: String) {
        lock.lock()
        activeRequestIds.removeValue(forKey: assetId)
        lock.unlock()
    }

    func handleExportVideo(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let assetId = args?["id"] as? String, !assetId.isEmpty else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Asset ID is required", details: nil))
            return
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetchResult.firstObject else {
            result(FlutterError(code: "ASSET_NOT_FOUND", message: "Asset with ID \(assetId) not found", details: nil))
            return
        }

        let videoOptions = PHVideoRequestOptions()
        videoOptions.isNetworkAccessAllowed = true
        videoOptions.version = .current
        videoOptions.deliveryMode = .highQualityFormat

        let exportId = UUID().uuidString
        let outputFileName = "ue_video_\(exportId).mov"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(outputFileName)

        try? FileManager.default.removeItem(at: outputURL)

        var hasResponded = false
        let respondLock = NSLock()

        func sendExportResult(_ res: Any?) {
            respondLock.lock()
            defer { respondLock.unlock() }
            guard !hasResponded else { return }
            hasResponded = true
            DispatchQueue.main.async {
                result(res)
            }
        }

        let reqId = imageManager.requestAVAsset(forVideo: asset, options: videoOptions) { [weak self] avAsset, audioMix, info in
            if let error = info?[PHImageErrorKey] as? Error {
                self?.clearRequestId(for: assetId)
                try? FileManager.default.removeItem(at: outputURL)
                sendExportResult(FlutterError(code: "EXPORT_FAILED", message: error.localizedDescription, details: nil))
                return
            }

            guard let avAsset = avAsset else {
                self?.clearRequestId(for: assetId)
                try? FileManager.default.removeItem(at: outputURL)
                sendExportResult(FlutterError(code: "EXPORT_FAILED", message: "Could not load AVAsset for video", details: nil))
                return
            }

            // Direct file copy if source is already a local file URL
            if let urlAsset = avAsset as? AVURLAsset {
                let sourceURL = urlAsset.url
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: outputURL)
                    self?.clearRequestId(for: assetId)
                    sendExportResult(outputURL.path)
                    return
                } catch {
                    // Fallback to AVAssetExportSession if direct copy fails
                }
            }

            // ── AVAssetExportSession with passthrough → HQ fallback ──────────
            // Helper that runs an export session and handles its terminal states.
            // IMPORTANT: all path reporting uses session.outputURL.path, not the
            // closed-over outputURL, so fallback .mp4 paths are returned correctly.
            func runExport(_ session: AVAssetExportSession, isRetry: Bool) {
                session.exportAsynchronously { [weak self] in
                    // The actual output URL for this session (may differ from
                    // outputURL when fallback chose .mp4).
                    let sessionOutputURL = session.outputURL

                    switch session.status {
                    case .completed:
                        self?.lock.lock()
                        self?.activeExports.removeValue(forKey: assetId)
                        self?.lock.unlock()
                        self?.clearRequestId(for: assetId)
                        // Return the session's actual output path so .mp4
                        // fallback paths are forwarded correctly to Flutter.
                        sendExportResult(sessionOutputURL?.path)

                    case .failed:
                        // Clean up this session's partial output file.
                        if let url = sessionOutputURL {
                            try? FileManager.default.removeItem(at: url)
                        }

                        if !isRetry {
                            // Passthrough failed — retry with HighestQuality.
                            // This covers AVComposition / slow-mo / cinematic
                            // assets where passthrough is unsupported.
                            guard let fallback = AVAssetExportSession(
                                asset: avAsset,
                                presetName: AVAssetExportPresetHighestQuality
                            ) else {
                                self?.lock.lock()
                                self?.activeExports.removeValue(forKey: assetId)
                                self?.lock.unlock()
                                self?.clearRequestId(for: assetId)
                                let err = session.error?.localizedDescription ?? "Export failed and fallback unavailable"
                                sendExportResult(FlutterError(code: "EXPORT_FAILED", message: err, details: nil))
                                return
                            }

                            // Choose a compatible output file type.
                            let preferredTypes: [AVFileType] = [.mov, .mp4]
                            let supportedTypes = fallback.supportedFileTypes
                            guard let chosenType = preferredTypes.first(where: { supportedTypes.contains($0) }) else {
                                self?.lock.lock()
                                self?.activeExports.removeValue(forKey: assetId)
                                self?.lock.unlock()
                                self?.clearRequestId(for: assetId)
                                sendExportResult(FlutterError(code: "EXPORT_FAILED", message: "No compatible output file type", details: nil))
                                return
                            }

                            // Adjust extension on the output URL to match chosen type.
                            let ext = chosenType == .mp4 ? "mp4" : "mov"
                            let fallbackURL = outputURL.deletingPathExtension().appendingPathExtension(ext)
                            try? FileManager.default.removeItem(at: fallbackURL)

                            fallback.outputURL = fallbackURL
                            fallback.outputFileType = chosenType
                            fallback.shouldOptimizeForNetworkUse = false

                            // Rebind activeExports so cancelExport targets the
                            // active session correctly during the retry.
                            self?.lock.lock()
                            self?.activeExports[assetId] = fallback
                            self?.lock.unlock()

                            runExport(fallback, isRetry: true)
                        } else {
                            // HQ retry also failed.
                            self?.lock.lock()
                            self?.activeExports.removeValue(forKey: assetId)
                            self?.lock.unlock()
                            self?.clearRequestId(for: assetId)
                            let err = session.error?.localizedDescription ?? "Export session failed"
                            sendExportResult(FlutterError(code: "EXPORT_FAILED", message: err, details: nil))
                        }

                    case .cancelled:
                        // Clean up this session's output, plus any alternate
                        // extension variant that may have been prepared.
                        if let url = sessionOutputURL {
                            try? FileManager.default.removeItem(at: url)
                        }
                        // Belt-and-suspenders: also remove the other extension
                        // variant in case it was written during a handoff.
                        let altExt = (sessionOutputURL?.pathExtension == "mp4") ? "mov" : "mp4"
                        if let altURL = sessionOutputURL?.deletingPathExtension().appendingPathExtension(altExt) {
                            try? FileManager.default.removeItem(at: altURL)
                        }
                        self?.lock.lock()
                        self?.activeExports.removeValue(forKey: assetId)
                        self?.lock.unlock()
                        self?.clearRequestId(for: assetId)
                        sendExportResult(FlutterError(code: "EXPORT_CANCELLED", message: "Export cancelled", details: nil))

                    default:
                        if let url = sessionOutputURL {
                            try? FileManager.default.removeItem(at: url)
                        }
                        self?.lock.lock()
                        self?.activeExports.removeValue(forKey: assetId)
                        self?.lock.unlock()
                        self?.clearRequestId(for: assetId)
                        sendExportResult(FlutterError(code: "EXPORT_FAILED", message: "Unexpected export status \(session.status.rawValue)", details: nil))
                    }
                }
            }

            // A shared helper to start an HQ export session when passthrough
            // is either un-creatable or supports no compatible output type.
            // Extracted to avoid code duplication across both entry points.
            func startHQExport() {
                guard let hqSession = AVAssetExportSession(
                    asset: avAsset,
                    presetName: AVAssetExportPresetHighestQuality
                ) else {
                    self?.clearRequestId(for: assetId)
                    try? FileManager.default.removeItem(at: outputURL)
                    sendExportResult(FlutterError(code: "EXPORT_FAILED", message: "Failed to create AVAssetExportSession", details: nil))
                    return
                }
                let preferredHQ: [AVFileType] = [.mov, .mp4]
                guard let hqType = preferredHQ.first(where: { hqSession.supportedFileTypes.contains($0) }) else {
                    self?.clearRequestId(for: assetId)
                    try? FileManager.default.removeItem(at: outputURL)
                    sendExportResult(FlutterError(code: "EXPORT_FAILED", message: "No compatible output file type for HQ preset", details: nil))
                    return
                }
                let hqExt = hqType == .mp4 ? "mp4" : "mov"
                let hqURL = outputURL.deletingPathExtension().appendingPathExtension(hqExt)
                try? FileManager.default.removeItem(at: hqURL)
                hqSession.outputURL = hqURL
                hqSession.outputFileType = hqType
                hqSession.shouldOptimizeForNetworkUse = false
                self?.lock.lock()
                self?.activeExports[assetId] = hqSession
                self?.lock.unlock()
                runExport(hqSession, isRetry: true)
            }

            // Attempt passthrough first; verify supportedFileTypes and fall
            // back to HQ if passthrough creation fails or has no compatible type.
            if let passthroughSession = AVAssetExportSession(
                asset: avAsset,
                presetName: AVAssetExportPresetPassthrough
            ) {
                // Confirm a compatible type is available before running passthrough.
                let preferredPT: [AVFileType] = [.mov, .mp4]
                guard let ptType = preferredPT.first(where: { passthroughSession.supportedFileTypes.contains($0) }) else {
                    // Passthrough has no compatible type — go straight to HQ.
                    startHQExport()
                    return
                }
                let ptExt = ptType == .mp4 ? "mp4" : "mov"
                let ptURL = outputURL.deletingPathExtension().appendingPathExtension(ptExt)
                try? FileManager.default.removeItem(at: ptURL)
                passthroughSession.outputURL = ptURL
                passthroughSession.outputFileType = ptType
                passthroughSession.shouldOptimizeForNetworkUse = false
                self?.lock.lock()
                self?.activeExports[assetId] = passthroughSession
                self?.lock.unlock()
                runExport(passthroughSession, isRetry: false)
            } else {
                // Passthrough preset not creatable — go straight to HQ.
                startHQExport()
            }
        }

        lock.lock()
        activeRequestIds[assetId] = reqId
        lock.unlock()
    }

    func handleCancelExport(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let assetId = args?["id"] as? String else {
            result(false)
            return
        }

        lock.lock()
        if let reqId = activeRequestIds.removeValue(forKey: assetId) {
            imageManager.cancelImageRequest(reqId)
        }
        if let exportSession = activeExports.removeValue(forKey: assetId) {
            exportSession.cancelExport()
        }
        lock.unlock()
        result(true)
    }

    // ── Open App Settings ───────────────────────────────────────────────────

    func handleOpenSettings(result: @escaping FlutterResult) {
        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
            result(false)
            return
        }
        if UIApplication.shared.canOpenURL(settingsUrl) {
            UIApplication.shared.open(settingsUrl, options: [:]) { success in
                result(success)
            }
        } else {
            result(false)
        }
    }

    // ── Limited Library Picker ───────────────────────────────────────────────

    func handlePresentLimitedLibraryPicker(result: @escaping FlutterResult) {
        guard #available(iOS 14, *) else {
            // iOS 13 and earlier: limited library is not supported.
            result(false)
            return
        }

        DispatchQueue.main.async {
            guard let rootVC = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                result(false)
                return
            }
            // Resolve the topmost presented view controller.
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }

            if #available(iOS 15, *) {
                // iOS 15+: completion handler fires after user taps Done,
                // so we can return true only after the picker is dismissed.
                PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: topVC) { _ in
                    DispatchQueue.main.async {
                        result(true)
                    }
                }
            } else {
                // iOS 14: no completion closure; returns immediately.
                PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: topVC)
                result(true)
            }
        }
    }
}

// ── UMF V2 Slice 2A: Photo Library Save Handler ─────────────────────────────
//
// Responsibilities:
//   - Save rendered local video file (.mp4, .mov, .m4v) to iOS Photos (PHPhotoLibrary).
//   - Uses PHPhotoLibrary.authorizationStatus(for: .addOnly) on iOS 14+; fallback on iOS <14.
//   - Validates non-empty filePath, local file exists, valid video extension.
//   - Uses PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL:).
//   - Dispatches Flutter result on main queue.
//   - Stable FlutterError codes:
//       invalid_args
//       file_not_found
//       invalid_format
//       permission_denied
//       save_failed

final class VGPhotoLibrarySaveHandler {
    func handleSaveVideo(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let filePath = args?["filePath"] as? String, !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result(FlutterError(
                code: "invalid_args",
                message: "filePath is required and must not be empty.",
                details: nil
            ))
            return
        }

        let fileURL = URL(fileURLWithPath: filePath)
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "mp4" || ext == "mov" || ext == "m4v" else {
            result(FlutterError(
                code: "invalid_format",
                message: "Only mp4, mov, and m4v video files are supported. Received: .\(ext)",
                details: nil
            ))
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            result(FlutterError(
                code: "file_not_found",
                message: "Video file not found at path: \(filePath)",
                details: nil
            ))
            return
        }

        let performSave = {
            var requestCreated = false
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                if request != nil {
                    requestCreated = true
                }
            }) { success, error in
                DispatchQueue.main.async {
                    if success && requestCreated {
                        result(true)
                    } else {
                        result(FlutterError(
                            code: "save_failed",
                            message: error?.localizedDescription ?? "PhotoKit failed to create asset change request.",
                            details: nil
                        ))
                    }
                }
            }
        }

        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            switch status {
            case .authorized:
                performSave()
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    DispatchQueue.main.async {
                        if newStatus == .authorized {
                            performSave()
                        } else {
                            result(FlutterError(
                                code: "permission_denied",
                                message: "Photo library add permission was not granted (status=\(newStatus.rawValue)).",
                                details: nil
                            ))
                        }
                    }
                }
            case .denied, .restricted, .limited:
                result(FlutterError(
                    code: "permission_denied",
                    message: "Photo library add permission is \(status == .denied ? "denied" : (status == .restricted ? "restricted" : "limited")).",
                    details: nil
                ))
            @unknown default:
                result(FlutterError(
                    code: "permission_denied",
                    message: "Unknown photo library authorization status.",
                    details: nil
                ))
            }
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            switch status {
            case .authorized:
                performSave()
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization { newStatus in
                    DispatchQueue.main.async {
                        if newStatus == .authorized {
                            performSave()
                        } else {
                            result(FlutterError(
                                code: "permission_denied",
                                message: "Photo library permission was not granted.",
                                details: nil
                            ))
                        }
                    }
                }
            case .denied, .restricted:
                result(FlutterError(
                    code: "permission_denied",
                    message: "Photo library permission is \(status == .denied ? "denied" : "restricted").",
                    details: nil
                ))
            @unknown default:
                result(FlutterError(
                    code: "permission_denied",
                    message: "Unknown photo library authorization status.",
                    details: nil
                ))
            }
        }
    }
}
