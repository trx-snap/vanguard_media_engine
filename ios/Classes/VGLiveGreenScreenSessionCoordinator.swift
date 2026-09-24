// VGLiveGreenScreenSessionCoordinator.swift
// Generic live green-screen: single active session owner. Caller-agnostic —
// live meeting/calling, going live, camera, or any other surface starts one
// session through the public Dart API; nothing here is scoped to Duet.
//
// Owns, per session: Flutter preview texture, static background buffer, the
// current foreground rect, and exactly ONE of two segmentation engines:
//   - ARKit engine (iOS production default when supported):
//     VGARKitLiveGreenScreenPreviewCoordinator over the session's texture —
//     ARFaceTrackingConfiguration + .personSegmentation, a full-resolution
//     ARMatteGenerator matte per frame refined through the production
//     VGMatteRefinementPipeline live mask pipeline (session
//     liveMatteRefinementMode; the same caller-agnostic pipeline the adapter
//     path's VGLiveGreenScreenCompositor runs internally), CoreImage composite
//     into the current foreground rect over the current background. It owns
//     the camera through its ARSession; no VGLiveGreenScreenCameraSource exists while
//     it runs.
//   - Adapter path (fallback, and every explicitly requested adapter backend):
//     VGLiveGreenScreenMaskProviderAdapter (Vision Fast; or LiteRT/Metal over
//     selfie_multiclass_256x256.tflite with heuristic fallback; or diagnostics
//     options for Vision Balanced / Vision Accurate / litertSelfie),
//     VGLiveGreenScreenCameraSource (front camera ingress), VGLiveGreenScreenCompositor,
//     VGLiveGreenScreenRenderLoop.
// An ARSession and a VGLiveGreenScreenCameraSource are never running at the same time.
//
// Backend selection (`iosSegmentationBackend`, diagnostics options; "auto" by
// default):
//   "auto"   → ARKit when ARFaceTrackingConfiguration.isSupported and
//              .personSegmentation is supported and the engine starts; else
//              Vision Fast (adapter). If the ARKit engine fails at runtime the
//              session falls back to Vision Fast on the same texture /
//              background / foreground rect and emits a `green_screen_degraded`
//              event (ios_arkit → ios_ml; keying continues).
//   "arkit"  → explicit ARKit, no Vision fallback: unsupported, a failed start,
//              or a runtime failure takes the degraded-unkeyed path with the
//              exact reason (an A/B run never reports another provider).
//   "visionFast" | "visionBalanced" | "visionAccurate" | "litert" | "litertSelfie"
//            → the existing adapter path, unchanged.
//
// Lifecycle:
//   startSession     → busy check → static background → texture register →
//                      backend resolution → ARKit engine start | (adapter
//                      start → camera start (frames observed into the adapter)
//                      → render loop start) → {sessionId, textureId, width,
//                      height}.
//   updateBackground → rebuild the static buffer and swap it on the engine /
//                      loop; the camera, segmenter, and texture are NOT
//                      restarted.
//   updateTransform  → recompute the foreground rect through
//                      VGDuetLayoutGeometry.greenScreen(canvasWidth:canvasHeight:transform:)
//                      and swap it on the engine / loop.
//   stopSession      → idempotent for unknown/already-stopped ids.
//   takePhoto        → still photo of the composited output
//                      (VG-LIVE-GREENSCREEN-PHOTO): the latest composited
//                      CVPixelBuffer the session texture already presents
//                      (adapter presentHandler / ARKit engine, the same
//                      buffer the recorder taps) is retained under the
//                      texture lock and JPEG-encoded on a background queue;
//                      the reply lands on main only after the file exists
//                      and is non-empty. Never the raw camera, never a
//                      texture screenshot; the preview and any recording
//                      keep running.
//   diagnostics      → diagnostic-only read of the active engine's matte
//                      latency / publication telemetry plus the camera's
//                      selected session preset for the active session id
//                      (session_not_found otherwise). No state change. The
//                      ARKit engine is reported with providerKind "arkit",
//                      providerMode "arkit_face_matte_full", timingSemantics
//                      "arkit_matte_generator_spans", segmentationEngine
//                      "arkit"; the adapter path keeps its existing identity.
//   setDiagnosticsOptions
//                    → diagnostic-only (not public Dart API). Rejected with
//                      live_busy while a session is active. Stores
//                      {iosFastMetalPrecision, iosSegmentationBackend,
//                      iosLiveMatteRefinement} for the
//                      NEXT startSession only: that start consumes them
//                      (adapter fastMetalPrecision → LiteRT Metal
//                      allow_precision_loss; iosSegmentationBackend → "auto"
//                      (default, see above) | "arkit" | visionFast | litert |
//                      visionBalanced | ...; iosLiveMatteRefinement →
//                      VGMatteRefinementPipeline.LiveMatteRefinementMode,
//                      "s4SoftAlphaR2" (production live default,
//                      VGMatteRefinementPipeline.defaultLiveMatteRefinementMode;
//                      runs when no option is sent) | "s1" (explicit S1-only
//                      fallback, the previous default) | "tightAlphaR1" (opt-in
//                      RND candidate) | "s4GuidedAlphaR1" (opt-in S4 R1
//                      guided-alpha RND live mode); applied on BOTH engines — the adapter
//                      path's VGLiveGreenScreenCompositor (which owns a
//                      VGMatteRefinementPipeline internally) and the ARKit
//                      engine's own VGMatteRefinementPipeline refiner
//                      (StartRequest.liveMatteRefinementMode, the same
//                      refinement pipeline) — and echoed in diagnostics with the
//                      ARKit per-stage applied flags; diagnostics can override next start)
//                      and the pending values reset to the defaults. Never alters a
//                      running session.
//   disposeAll       → plugin detach; releases the active session and drops
//                      any pending diagnostics options.
//
// Terminal order (stop / dispose):
//   render loop stop → adapter invalidate → camera observer clear → camera stop
//   → ARKit engine frame delivery stop (delegate nil, ARSession pause, bounded
//   in-flight render drain) → texture invalidate → texture unregister → ARKit
//   engine ARSession / Metal / CoreImage resources released → active session
//   cleared. Only the components the session actually created exist; every
//   step is idempotent.
//
// Segmentation failure (the adapter could create no mask provider at all):
// keying is disabled, the adapter is invalidated, and the loop keeps presenting
// the unkeyed live camera over the same background. `onLiveGreenScreenEvent`
// receives a degraded payload whose `reason` / `failureReason` carry the
// adapter's exact setup failure (for example model_asset_missing). Before the
// adapter is released its last diagnostics snapshot is cached on the session
// (`terminalDiagnostics`), so a later `diagnostics(sessionId:)` still reports
// providerKind / providerMode / segmentationBackend / failureReason /
// sampleCount / maskPublishCount instead of a bare "released" placeholder.
// LiteRT-unavailable → heuristic fallback is NOT a
// failure (the adapter logs IOS_LIVE_GREENSCREEN_MASK_PROVIDER_FALLBACK). A
// diagnostics-requested Vision backend that is unavailable (iOS < 15) has no
// fallback and takes this same segmentation-failure path by design. Model
// warm-up is NOT a failure: until the first fresh mask lands the compositor
// already shows the unkeyed camera, so start never waits on the model. A stale
// mask (older than `maskMaxAgeSeconds` of camera time) is withheld by the
// adapter, so the loop presents that frame unkeyed instead of mis-keyed.
//
// ARKit engine failure after start (render / ARSession / capture failure):
// the engine reports it once on main (`onTerminalFailure`); the coordinator
// stops the engine (frame delivery off, in-flight render drained, ARSession
// released — the camera is free before any AVCapture path starts), caches its
// final summary on the session (`arkitTerminalDiagnostics`, merged into later
// diagnostics under `arkitEngine`), and then either starts the Vision Fast
// adapter pipeline on the same texture ("auto": still keyed, degraded event
// ios_arkit → ios_ml) or the camera-only unkeyed pipeline ("arkit": degraded
// event ios_arkit → unkeyed through the segmentation-failure path). The
// session is never stopped by the engine and the camera is never left locked.
//
// Mask/camera PTS pairing: the render loop fetches the mask (with the camera
// PTS it was computed from) first, then the camera provider returns the
// history frame nearest that PTS (VGLiveGreenScreenCameraSource.snapshotRetained(near:
// maxDeltaSeconds:), window `maskPairingMaxDeltaSeconds`). With no numeric
// PTS or no frame in the window it returns the latest frame, so a render is
// never dropped. The first aligned pair logs
// IOS_LIVE_GREENSCREEN_PTS_ALIGNED_PAIR_FIRST with the achieved |delta| ms.
//
// Threading: all public methods run on the main thread (Flutter plugin thread).

import ARKit
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Flutter
import Foundation
import ImageIO
import os.lock

// MARK: - Start request

/// Validated video background arguments for a live GreenScreen session.
/// Parsed and validated by `VGLiveGreenScreenMethodHandler.parseBackground`
/// when `background.type` is "video" or "videoFile".
struct VGLiveGreenScreenVideoSpec {
    /// Absolute local file path. Guaranteed non-empty by the method handler.
    let filePath: String
    /// Scale mode (aspectFill default; aspectFit when explicitly requested).
    let scaleMode: VGLiveGreenScreenBackgroundScaleMode
}

/// Validated `startLiveGreenScreenSession` arguments (built by the handler).
struct VGLiveGreenScreenStartRequest {
    let canvasWidth: Int
    let canvasHeight: Int
    /// Solid-color or still-image background. For video backgrounds this is a
    /// solid-black placeholder used only while the first video frame decodes;
    /// the actual content is supplied by `videoBackground`.
    let background: VGLiveGreenScreenBackgroundSpec
    /// Non-nil when the caller requested a video background.
    let videoBackground: VGLiveGreenScreenVideoSpec?
    /// nil → full-canvas identity (foregroundTransform omitted or malformed).
    let foregroundTransform: NativeForegroundTransform?
}

// MARK: - Diagnostics options (diagnostic-only; not public Dart API)

/// Options accepted by `setLiveGreenScreenDiagnosticsOptions`. They apply to
/// the next session start only and never alter an active session.
struct VGLiveGreenScreenDiagnosticsOptions {
    /// Forwarded to VGLiveGreenScreenMaskProviderAdapter(fastMetalPrecision:…)
    /// and from there to VGLiteRTMaskProvider metalAllowPrecisionLoss (Metal
    /// delegate allow_precision_loss). false = production float32 path.
    /// Echoed but not applied when a Vision backend is selected.
    var iosFastMetalPrecision: Bool = false

    /// Segmentation backend for the next start. "auto" (default) resolves to
    /// the ARKit engine when the device supports front-camera face tracking
    /// with person segmentation, else to the Vision Fast adapter; "arkit"
    /// forces the ARKit engine (no Vision fallback); every other value is
    /// forwarded unchanged to VGLiveGreenScreenMaskProviderAdapter
    /// (…segmentationBackend:) — "visionFast" | "litert" (selectable alternate
    /// LiteRT/Metal path) | "visionBalanced" | "visionAccurate" | "litertSelfie".
    /// Validated by the method handler against
    /// VGLiveGreenScreenSessionCoordinator.segmentationBackendAuto / …ARKit and
    /// the VGLiveGreenScreenSegmentationBackend* constants before reaching here.
    var iosSegmentationBackend: String = VGLiveGreenScreenSessionCoordinator.segmentationBackendAuto

    /// Live matte refinement mode for the NEXT session start only (see
    /// VGMatteRefinementPipeline.LiveMatteRefinementMode). Default "s4SoftAlphaR2"
    /// (VGMatteRefinementPipeline.defaultLiveMatteRefinementMode) is the production
    /// live pipeline: S1 stages plus the S4 soft R2 refinement; "s1" is the explicit
    /// fallback that runs exactly the previous S1-only production path, byte-for-byte
    /// unchanged; "tightAlphaR1" opts into the bounded CoreImage post-pass A/B candidate
    /// ("A tight alpha"); "s4GuidedAlphaR1" opts into the S4 R1 guided-alpha RND
    /// candidate live (physical comparison only; never the default). Validated by the
    /// method handler against VGMatteRefinementPipeline.LiveMatteRefinementMode.allCases
    /// before reaching here.
    var iosLiveMatteRefinement: String = VGMatteRefinementPipeline.defaultLiveMatteRefinementMode.rawValue

    static let `default` = VGLiveGreenScreenDiagnosticsOptions()

    /// Wire shape echoed back to the caller:
    /// {iosFastMetalPrecision, iosSegmentationBackend, iosLiveMatteRefinement}.
    var payload: [String: Any] {
        return [
            "iosFastMetalPrecision":  iosFastMetalPrecision,
            "iosSegmentationBackend": iosSegmentationBackend,
            "iosLiveMatteRefinement": iosLiveMatteRefinement,
        ]
    }
}

// MARK: - Video background player errors

private enum VGVideoBackgroundError: Error, LocalizedError {
    case noVideoTrack
    case zeroDuration
    case readerInitFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "Video file contains no video track."
        case .zeroDuration:
            return "Video file has zero or indeterminate duration."
        case .readerInitFailed(let msg):
            return "Video reader initialisation failed: \(msg)"
        }
    }
}

// MARK: - Video background player

/// Decodes a looping local video file and vends the latest BGRA frame for the
/// live GreenScreen render loop to poll non-blocking on the main thread.
///
/// Lifecycle:
///   1. Call `validateAndGetDuration()` synchronously (safe on the main thread
///      for local files). Throws on missing track, zero duration, or reader
///      setup failure. Returns video duration in seconds.
///   2. Call `start()` to begin the decode loop on `decodeQueue`.
///   3. Call `latestFrame()` on any thread at any time (non-blocking).
///   4. Call `release()` to stop. Idempotent; safe from any thread.
///
/// Real-time pacing: the decode loop records `loopStartTime = CACurrentMediaTime()`
/// before each pass, then for every decoded frame sleeps until
/// `loopStartTime + framePTSSeconds` before vending the buffer. At EOF
/// `loopStartTime` advances by `videoDuration` so the next loop begins
/// seamlessly. The last decoded frame is retained across the brief reset
/// so the render loop never sees nil mid-loop.
private final class VGLiveGreenScreenVideoBackgroundPlayer {

    private let url: URL
    /// Duration in seconds, set by validateAndGetDuration(). Used by the
    /// decode loop to advance loopStartTime at EOF.
    private(set) var videoDuration: Double = 0

    private let decodeQueue = DispatchQueue(
        label: "com.connects.vanguard.livegreenscreen.videobg.decode",
        qos: .userInteractive)

    // os_unfair_lock protecting _latestFrame and _isReleased.
    private var _lock = os_unfair_lock_s()
    private var _latestFrame: CVPixelBuffer?
    private var _isReleased = false

    // Retained after validateAndGetDuration() for reuse in the decode loop.
    private var preparedAsset: AVURLAsset?
    private var preparedTrack: AVAssetTrack?

    // Decode-queue state; nil while not reading.
    private var assetReader: AVAssetReader?
    private var trackOutput: AVAssetReaderVideoCompositionOutput?

    // MARK: Init

    init(url: URL) {
        self.url = url
    }

    // MARK: Public

    /// Synchronous pre-flight validation. Must be called on the main thread
    /// before `start()`. For local files the AVAsset track load and a brief
    /// startReading probe are fast (< ~10 ms). Throws `VGVideoBackgroundError`
    /// on failure so the caller can fail closed before allocating any session
    /// resources.
    ///
    /// - Returns: video duration in seconds (also stored in `videoDuration`).
    @discardableResult
    func validateAndGetDuration() throws -> Double {
        let asset = AVURLAsset(url: url,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw VGVideoBackgroundError.noVideoTrack
        }
        let dur = CMTimeGetSeconds(asset.duration)
        guard dur.isFinite, dur > 0 else {
            throw VGVideoBackgroundError.zeroDuration
        }
        // Probe: verify AVAssetReader can be initialised and started.
        let probeSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let probeComposition = AVMutableVideoComposition(propertiesOf: asset)
        let probeOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track],
                                                              videoSettings: probeSettings)
        probeOutput.videoComposition    = probeComposition
        probeOutput.alwaysCopiesSampleData = false
        let probeReader: AVAssetReader
        do {
            probeReader = try AVAssetReader(asset: asset)
        } catch {
            throw VGVideoBackgroundError.readerInitFailed(error.localizedDescription)
        }
        guard probeReader.canAdd(probeOutput) else {
            throw VGVideoBackgroundError.readerInitFailed("Cannot add output to probe AVAssetReader")
        }
        probeReader.add(probeOutput)
        probeReader.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 0.1, preferredTimescale: 600))
        guard probeReader.startReading() else {
            throw VGVideoBackgroundError.readerInitFailed(
                probeReader.error?.localizedDescription ?? "startReading failed on probe reader")
        }
        probeReader.cancelReading()

        self.videoDuration   = dur
        self.preparedAsset   = asset
        self.preparedTrack   = track
        return dur
    }

    /// Begins the real-time decode loop on `decodeQueue`.
    /// Must only be called after a successful `validateAndGetDuration()`.
    func start() {
        decodeQueue.async { [weak self] in
            self?.runDecodeLoop()
        }
    }

    /// Returns the most recently decoded video frame, or nil before the first
    /// frame is ready or after `release()`. Non-blocking; safe on any thread.
    func latestFrame() -> CVPixelBuffer? {
        os_unfair_lock_lock(&_lock)
        let frame = _latestFrame
        os_unfair_lock_unlock(&_lock)
        return frame
    }

    /// Idempotent terminal teardown. After this call `latestFrame()` returns nil.
    /// Safe to call from any thread.
    func release() {
        os_unfair_lock_lock(&_lock)
        _isReleased  = true
        _latestFrame = nil
        os_unfair_lock_unlock(&_lock)
        // Cancel the reader on the decode queue so copyNextSampleBuffer()
        // unblocks promptly rather than waiting for the next frame interval.
        decodeQueue.async { [weak self] in self?.cancelReader() }
    }

    // MARK: Private – real-time decode loop (runs entirely on decodeQueue)

    private func runDecodeLoop() {
        os_unfair_lock_lock(&_lock)
        let released = _isReleased
        os_unfair_lock_unlock(&_lock)
        guard !released else { return }

        guard let asset = preparedAsset, let track = preparedTrack else { return }
        let duration = videoDuration

        // Wall-clock reference: video t=0 maps to this host time.
        // Advances by `duration` at each EOF for seamless looping.
        var loopStartTime = CACurrentMediaTime()

        outerLoop: while true {
            os_unfair_lock_lock(&_lock)
            let stop = _isReleased
            os_unfair_lock_unlock(&_lock)
            guard !stop else { break }

            guard setupReader(asset: asset, track: track) else { break }

            guard let output = trackOutput, let reader = assetReader else { break }

            while reader.status == .reading {
                os_unfair_lock_lock(&_lock)
                let stop = _isReleased
                os_unfair_lock_unlock(&_lock)
                if stop { cancelReader(); break outerLoop }

                guard let sampleBuffer = output.copyNextSampleBuffer() else {
                    // EOF: advance loop reference time and start next pass.
                    break
                }

                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let ptsSeconds = CMTimeGetSeconds(pts)
                guard ptsSeconds.isFinite else { continue }

                // Pace to real-time: sleep until the frame's wall-clock moment.
                let targetWallTime = loopStartTime + ptsSeconds
                let sleepSeconds   = targetWallTime - CACurrentMediaTime()
                if sleepSeconds > 0.001 {
                    Thread.sleep(forTimeInterval: min(sleepSeconds, 0.5))
                }

                if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    os_unfair_lock_lock(&_lock)
                    if !_isReleased { _latestFrame = imageBuffer }
                    os_unfair_lock_unlock(&_lock)
                }
            }

            // EOF (or reader failed). Advance the loop start reference by the
            // video duration so the next loop begins at exactly the right
            // wall-clock offset for seamless playback. Resync to wall clock
            // if duration drifted past current time.
            let now = CACurrentMediaTime()
            if now >= loopStartTime + duration {
                loopStartTime = now
            } else {
                loopStartTime += duration
            }
        }

        cancelReader()
        preparedAsset = nil
        preparedTrack = nil
    }

    private func setupReader(asset: AVURLAsset, track: AVAssetTrack) -> Bool {
        cancelReader()
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let videoComposition = AVMutableVideoComposition(propertiesOf: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track],
                                                         videoSettings: outputSettings)
        output.videoComposition    = videoComposition
        output.alwaysCopiesSampleData = false

        guard let reader = try? AVAssetReader(asset: asset) else {
            NSLog("[VGLiveGreenScreenVideoBackgroundPlayer] AVAssetReader init failed for %@",
                  url.lastPathComponent)
            return false
        }
        guard reader.canAdd(output) else {
            NSLog("[VGLiveGreenScreenVideoBackgroundPlayer] Cannot add output for %@",
                  url.lastPathComponent)
            return false
        }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: .positiveInfinity)
        guard reader.startReading() else {
            NSLog("[VGLiveGreenScreenVideoBackgroundPlayer] startReading failed: %@",
                  reader.error?.localizedDescription ?? "unknown")
            return false
        }
        assetReader = reader
        trackOutput = output
        return true
    }

    private func cancelReader() {
        if let r = assetReader, r.status == .reading { r.cancelReading() }
        assetReader = nil
        trackOutput = nil
    }
}

// MARK: - Coordinator

final class VGLiveGreenScreenSessionCoordinator {

    // MARK: Error codes (mirror the Dart VGLiveGreenScreenErrorCode wire values)

    static let errorInvalidArg        = "INVALID_ARG"
    static let errorLiveBusy          = "live_busy"
    static let errorCompositionFailed = "composition_failed"
    static let errorSessionNotFound   = "session_not_found"
    // Recording (VG-LIVE-GREENSCREEN-RECORDING).
    static let errorRecordingActive    = "recording_active"
    static let errorRecordingNotActive = "recording_not_active"
    static let errorRecordingFailed    = "recording_failed"
    static let errorDiskFull           = "disk_full"

    /// Minimum free space on the recording volume before a recording may start.
    private static let minFreeDiskBytesForRecording: Int64 = 200 * 1024 * 1024
    /// Temporary-directory subfolder used when the caller supplies no outputPath.
    private static let defaultRecordingDirectoryName = "vanguard_live_green_screen"

    // Still photo (VG-LIVE-GREENSCREEN-PHOTO).

    /// JPEG quality for a still photo of the composited output (matches the
    /// MultiCam composited-still and camera photo sinks).
    private static let photoJPEGQuality: Double = 0.9
    /// Serial background queue for JPEG encoding + file I/O of still photos:
    /// never the main (plugin) thread and never the engine render path.
    private static let photoEncodeQueue = DispatchQueue(
        label: "com.connects.vanguard.livegreenscreen.photo", qos: .userInitiated)
    /// Dedicated CIContext for still-photo encoding (CIContext is thread-safe).
    /// Working color space disabled so the composited BGRA pixels are encoded
    /// exactly as the texture presents them, with no color matching.
    private static let photoCIContext = CIContext(options: [
        CIContextOption.workingColorSpace: NSNull(),
    ])

    // MARK: Event payload values

    /// `event` wire name parsed by VGLiveGreenScreenEvent on the Dart side.
    static let eventDegraded            = "green_screen_degraded"
    /// `previousBackend` / `currentBackend` values: the adapter (Vision /
    /// LiteRT) path, the ARKit engine, and no keying at all.
    static let backendIosMl             = "ios_ml"
    static let backendIosARKit          = "ios_arkit"
    static let backendUnkeyed           = "unkeyed"
    /// Failure category of the degraded event (`failureCategory`), and the
    /// `reason` fallback when the adapter reported no exact failure reason.
    static let reasonSegmentationFailure = "segmentation_failure"
    /// Failure category of the degraded event emitted when the ARKit engine
    /// failed at runtime and the "auto" session moved to the Vision Fast
    /// adapter (keying continues on a lower rung).
    static let reasonARKitEngineFailure  = "arkit_engine_failure"
    /// `terminalState` diagnostics value while keying is active.
    static let terminalStateKeyed        = "keyed"
    /// `terminalState` diagnostics value after the segmentation failure path.
    static let terminalStateDegraded     = "degraded_unkeyed"
    /// `failureReason` / `terminalReason` value while no failure exists.
    static let noFailureReason           = "none"
    private static let degradedUserMessage =
        "Green screen is unavailable on this device. Showing the live camera over the background."
    private static let arkitFallbackUserMessage =
        "Green screen switched to the standard segmenter."

    // MARK: Segmentation backend selectors owned by this coordinator
    // (accepted by setLiveGreenScreenDiagnosticsOptions next to the adapter's
    // VGLiveGreenScreenSegmentationBackend* constants).

    /// Default: the ARKit engine when supported, else the Vision Fast adapter.
    static let segmentationBackendAuto  = "auto"
    /// Explicit ARKit engine; no Vision fallback (degraded unkeyed instead).
    static let segmentationBackendARKit = "arkit"
    /// `segmentationEngine` diagnostics values.
    static let segmentationEngineARKit   = "arkit"
    static let segmentationEngineAdapter = "adapter"

    /// Maximum camera-time lag between the latest submitted frame and the mask
    /// handed to the compositor. Older masks are withheld (frame renders unkeyed).
    static let maskMaxAgeSeconds: TimeInterval =
        VGLiveGreenScreenMaskProviderAdapter.defaultMaxMaskAgeSeconds

    /// Maximum |cameraFramePTS − maskSourcePTS| for a history frame to be paired
    /// with the mask instead of the latest frame (~3.6 frames at 30 fps).
    static let maskPairingMaxDeltaSeconds: Double = 0.12

    // MARK: Session

    private final class LiveSession {
        let sessionId: String
        let textureId: Int64
        let texture: VGDuetPreviewTexture
        let canvasWidth: Int
        let canvasHeight: Int

        /// Segmentation backend requested for this session (diagnostics
        /// options at start; "auto" by default). Kept so diagnostics can
        /// still echo it after the engine / adapter has been released.
        let requestedSegmentationBackend: String

        /// Backend actually driving the session now: "arkit" while the ARKit
        /// engine runs, or the adapter backend ("visionFast" after an "auto"
        /// resolution or fallback; the explicit value otherwise).
        var effectiveSegmentationBackend: String

        /// Why `effectiveSegmentationBackend` was chosen (diagnostics only):
        /// arkit_default | arkit_explicit | explicit |
        /// vision_default_arkit_unsupported(reason) |
        /// vision_fallback_after_arkit_start_failure(reason) |
        /// vision_fallback_after_arkit_runtime_failure(reason) |
        /// arkit_explicit_unavailable(reason) | arkit_explicit_runtime_failure(reason).
        var segmentationBackendSelection: String

        /// Live matte refinement mode requested for this session (diagnostics options
        /// at start; "s4SoftAlphaR2", the production default, when no option was sent).
        /// Kept so diagnostics can always echo it,
        /// independent of the compositor / adapter lifecycle.
        let requestedLiveMatteRefinement: String

        /// Diagnostics options consumed at start, kept so an ARKit → adapter
        /// fallback builds the adapter / compositor exactly as a direct adapter
        /// start would have.
        let fastMetalPrecision: Bool
        let liveMatteRefinementMode: VGMatteRefinementPipeline.LiveMatteRefinementMode

        /// Current full-canvas static background and foreground rect (top-left
        /// origin). Updated by updateBackground / updateTransform and reused
        /// verbatim when a fallback pipeline starts mid-session.
        var background: CVPixelBuffer
        var foregroundRect: CGRect
        /// Active video background player. Non-nil only when the current
        /// background is a video; nil for solidColor and image backgrounds.
        var videoPlayer: VGLiveGreenScreenVideoBackgroundPlayer?
        /// Spec of the most-recently accepted video background (kept so
        /// describe() can name it in log markers).
        var videoFilePath: String?

        // Adapter path components (nil while the ARKit engine drives the session).
        var cameraSource: VGLiveGreenScreenCameraSource?
        var adapter: VGLiveGreenScreenMaskProviderAdapter?
        var renderLoop: VGLiveGreenScreenRenderLoop?
        // ARKit path component (nil on the adapter path).
        var arkitEngine: VGARKitLiveGreenScreenPreviewCoordinator?
        /// Final ARKit engine summary cached when the engine failed at runtime
        /// and the session moved to the adapter path (diagnostics only).
        var arkitTerminalDiagnostics: [String: Any]?
        /// False after the terminal segmentation failure path ran.
        var isKeyed = true
        /// Exact adapter failure reason captured by the terminal segmentation
        /// failure path (nil while keyed).
        var terminalReason: String?
        /// Adapter diagnostics snapshot + session state cached by
        /// `handleAdapterFailure` immediately BEFORE the adapter was
        /// invalidated and dropped. Merged into every later
        /// `diagnostics(sessionId:)` reply so the failure is still observable
        /// after release. nil while the adapter is alive.
        var terminalDiagnostics: [String: Any]?
        /// Set once the first PTS-aligned mask/camera pair was logged (main thread).
        var loggedFirstAlignedPair = false

        // Recording (VG-LIVE-GREENSCREEN-RECORDING): at most one recorder per
        // session, main-thread owned. The adapter path's presentHandler and the
        // ARKit engine's onCompositedFrame both feed `recorder` the same
        // composited buffer the texture shows; the microphone capture feeds it
        // audio, which the recorder drops until the first video frame anchors t0.
        var recorder: VGLiveGreenScreenRecorder?
        var microphone: VGLiveGreenScreenMicrophoneCapture?

        init(sessionId: String,
             textureId: Int64,
             texture: VGDuetPreviewTexture,
             canvasWidth: Int,
             canvasHeight: Int,
             requestedSegmentationBackend: String,
             requestedLiveMatteRefinement: String,
             fastMetalPrecision: Bool,
             liveMatteRefinementMode: VGMatteRefinementPipeline.LiveMatteRefinementMode,
             background: CVPixelBuffer,
             foregroundRect: CGRect) {
            self.sessionId    = sessionId
            self.textureId    = textureId
            self.texture      = texture
            self.canvasWidth  = canvasWidth
            self.canvasHeight = canvasHeight
            self.requestedSegmentationBackend = requestedSegmentationBackend
            self.effectiveSegmentationBackend = requestedSegmentationBackend
            self.segmentationBackendSelection = "pending"
            self.requestedLiveMatteRefinement = requestedLiveMatteRefinement
            self.fastMetalPrecision = fastMetalPrecision
            self.liveMatteRefinementMode = liveMatteRefinementMode
            self.background = background
            self.foregroundRect = foregroundRect
        }
    }

    // MARK: State

    private let textureRegistry: FlutterTextureRegistry?

    /// Emits an `onLiveGreenScreenEvent` payload to Dart. The plugin-supplied
    /// closure hops to the main thread before calling `channel.invokeMethod`.
    private let onLiveGreenScreenEvent: (([String: Any]) -> Void)?

    private let backgroundRenderer = VGLiveGreenScreenStaticBackgroundRenderer()

    /// At most one live session at a time.
    private var activeSession: LiveSession?

    /// Diagnostic-only options for the next start (see setDiagnosticsOptions).
    /// Consumed by the start that builds a session; reset by disposeAll.
    private var pendingDiagnosticsOptions = VGLiveGreenScreenDiagnosticsOptions.default

    // MARK: - Init

    init(textureRegistry: FlutterTextureRegistry? = nil,
         onLiveGreenScreenEvent: (([String: Any]) -> Void)? = nil) {
        self.textureRegistry        = textureRegistry
        self.onLiveGreenScreenEvent = onLiveGreenScreenEvent
    }

    // MARK: - start

    func startSession(_ request: VGLiveGreenScreenStartRequest,
                      reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)

        guard activeSession == nil else {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorLiveBusy,
                message: "startLiveGreenScreenSession: a live green-screen session is already active.",
                details: nil))
            return
        }
        guard let registry = textureRegistry else {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorCompositionFailed,
                message: "startLiveGreenScreenSession: textureRegistry not available.",
                details: nil))
            return
        }

        // Validate video decodability before allocating any session resources
        // (texture, camera, ARKit engine) so a missing track or corrupt file
        // fails with nothing to unwind. validateAndGetDuration() is synchronous
        // and fast for local files (< ~10 ms AVAsset track probe + brief read).
        if let videoSpec = request.videoBackground {
            let probePlayer = VGLiveGreenScreenVideoBackgroundPlayer(
                url: URL(fileURLWithPath: videoSpec.filePath))
            do {
                try probePlayer.validateAndGetDuration()
            } catch {
                let desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                reply(nil, FlutterError(
                    code:    VGLiveGreenScreenSessionCoordinator.errorInvalidArg,
                    message: "startLiveGreenScreenSession: background video is not decodable: \(desc)",
                    details: nil))
                return
            }
        }

        // Build the static background before allocating the texture or camera
        // so a rejected image path fails with nothing to unwind.
        let background: CVPixelBuffer
        do {
            background = try backgroundRenderer.build(spec: request.background,
                                                      canvasWidth: request.canvasWidth,
                                                      canvasHeight: request.canvasHeight)
        } catch {
            reply(nil, VGLiveGreenScreenSessionCoordinator.flutterError(
                from: error, route: "startLiveGreenScreenSession"))
            return
        }

        let width  = request.canvasWidth
        let height = request.canvasHeight

        // Diagnostic-only options are consumed by exactly this start; a later
        // start without a fresh setDiagnosticsOptions call runs the defaults.
        let diagnosticsOptions = pendingDiagnosticsOptions
        pendingDiagnosticsOptions = .default

        // Fail open to the production default (Soft R2) if the stored string is somehow
        // not a known raw value (the method handler already validates it exactly; this is
        // defense in depth). Explicit "s1" still resolves to the S1-only fallback.
        let liveMatteRefinementMode = VGMatteRefinementPipeline.LiveMatteRefinementMode(
            rawValue: diagnosticsOptions.iosLiveMatteRefinement)
            ?? VGMatteRefinementPipeline.defaultLiveMatteRefinementMode

        let rects = VGDuetLayoutGeometry.greenScreen(canvasWidth: CGFloat(width),
                                                     canvasHeight: CGFloat(height),
                                                     transform: request.foregroundTransform)

        let texture   = VGDuetPreviewTexture()
        let textureId = registry.register(texture)
        let sessionId = "ios_live_gs_" + UUID().uuidString.lowercased()
        let session = LiveSession(sessionId: sessionId,
                                  textureId: textureId,
                                  texture: texture,
                                  canvasWidth: width,
                                  canvasHeight: height,
                                  requestedSegmentationBackend: diagnosticsOptions.iosSegmentationBackend,
                                  requestedLiveMatteRefinement: diagnosticsOptions.iosLiveMatteRefinement,
                                  fastMetalPrecision: diagnosticsOptions.iosFastMetalPrecision,
                                  liveMatteRefinementMode: liveMatteRefinementMode,
                                  background: background,
                                  foregroundRect: rects.camera)
        // The session is active from here: every engine failure callback
        // (always asynchronous on main) resolves against `activeSession`.
        activeSession = session

        // Create and validate the video player. validateAndGetDuration() was
        // already run above as a probe; running it a second time on the real
        // player object captures the prepared asset and track for the decode loop.
        if let videoSpec = request.videoBackground {
            let player = VGLiveGreenScreenVideoBackgroundPlayer(
                url: URL(fileURLWithPath: videoSpec.filePath))
            do {
                try player.validateAndGetDuration()
            } catch {
                // Should not happen (probe passed above), but fail closed.
                // release() unregisters the texture and nils activeSession.
                release(session)
                let desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                reply(nil, FlutterError(
                    code:    VGLiveGreenScreenSessionCoordinator.errorInvalidArg,
                    message: "startLiveGreenScreenSession: background video validation failed unexpectedly: \(desc)",
                    details: nil))
                return
            }
            session.videoPlayer   = player
            session.videoFilePath = videoSpec.filePath
            player.start()
            NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_VIDEO_BG_STARTED sessionId=\(sessionId) filePath=\(videoSpec.filePath) duration=\(player.videoDuration)s")
        }

        // Backend resolution. Exactly one engine is created: the ARKit engine
        // owns the camera through its ARSession and no VGLiveGreenScreenCameraSource
        // exists while it runs; the adapter path owns the camera through
        // VGLiveGreenScreenCameraSource and no ARSession exists.
        let requestedBackend = diagnosticsOptions.iosSegmentationBackend
        let wantsARKit =
            (requestedBackend == VGLiveGreenScreenSessionCoordinator.segmentationBackendAuto && request.videoBackground == nil)
            || requestedBackend == VGLiveGreenScreenSessionCoordinator.segmentationBackendARKit
        var arkitFailureReason: String?
        if wantsARKit {
            let faceTrackingSupported = ARFaceTrackingConfiguration.isSupported
            let facePersonSegmentationSupported = ARFaceTrackingConfiguration.supportsFrameSemantics(.personSegmentation)
            NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_ARKIT_CAPABILITY sessionId=\(sessionId) requestedSegmentationBackend=\(requestedBackend) faceTrackingSupported=\(faceTrackingSupported) facePersonSegmentationSupported=\(facePersonSegmentationSupported)")
            if !faceTrackingSupported {
                arkitFailureReason = "face_tracking_unsupported"
            } else if !facePersonSegmentationSupported {
                arkitFailureReason = "face_person_segmentation_unsupported"
            } else {
                arkitFailureReason = startARKitEngine(session: session, registry: registry)
            }
        }

        if wantsARKit, arkitFailureReason == nil {
            // ARKit engine started successfully.
            session.effectiveSegmentationBackend = VGLiveGreenScreenSessionCoordinator.segmentationBackendARKit
            session.segmentationBackendSelection =
                requestedBackend == VGLiveGreenScreenSessionCoordinator.segmentationBackendAuto
                ? "arkit_default" : "arkit_explicit"

            // Video backgrounds require the adapter render loop's frame provider;
            // the ARKit engine does not support dynamic per-frame background updates.
            // Fail closed: release the session and return INVALID_ARG.
            if request.videoBackground != nil {
                NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_VIDEO_BG_ARKIT_REJECTED sessionId=\(sessionId) reason=arkit_engine_does_not_support_video_background")
                release(session)  // tears down ARKit engine, video player, texture, and clears activeSession
                reply(nil, FlutterError(
                    code:    VGLiveGreenScreenSessionCoordinator.errorInvalidArg,
                    message: "startLiveGreenScreenSession: video backgrounds are not supported when the ARKit segmentation engine is active; use a solidColor or image background, or force the Vision backend via diagnosticsOptions.iosSegmentationBackend.",
                    details: nil))
                return
            }
        } else if requestedBackend == VGLiveGreenScreenSessionCoordinator.segmentationBackendARKit {
            // Explicit ARKit could not start: no Vision fallback by design (an
            // A/B run never reports numbers from another provider). The
            // camera-only pipeline presents the unkeyed camera over the
            // background and the segmentation-failure path records the exact
            // reason (degraded event ios_arkit → unkeyed).
            let reason = arkitFailureReason ?? "unknown"
            session.effectiveSegmentationBackend = VGLiveGreenScreenSessionCoordinator.segmentationBackendARKit
            session.segmentationBackendSelection = "arkit_explicit_unavailable(\(reason))"
            startCameraPipeline(session: session, registry: registry, adapter: nil)
            handleAdapterFailure(
                session: session,
                adapterDiagnostics: VGLiveGreenScreenSessionCoordinator.arkitUnavailableDiagnostics(
                    failureReason: "arkit_unavailable: \(reason)", engineSummary: nil),
                previousBackend: VGLiveGreenScreenSessionCoordinator.backendIosARKit)
        } else {
            // Adapter path: the explicitly requested adapter backend, or Vision
            // Fast when "auto" could not use ARKit (unsupported device, or the
            // engine failed to start — the fallback happens before start replies).
            let backend: String
            if requestedBackend == VGLiveGreenScreenSessionCoordinator.segmentationBackendAuto {
                backend = VGLiveGreenScreenSegmentationBackendVisionFast
                if request.videoBackground != nil {
                    session.segmentationBackendSelection = "vision_default_video_background"
                    NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_VIDEO_BG_VISION_SELECTION sessionId=\(sessionId) segmentationBackend=\(backend)")
                } else {
                    let reason = arkitFailureReason ?? "unknown"
                    let unsupported = reason == "face_tracking_unsupported" || reason == "face_person_segmentation_unsupported"
                    session.segmentationBackendSelection = unsupported
                        ? "vision_default_arkit_unsupported(\(reason))"
                        : "vision_fallback_after_arkit_start_failure(\(reason))"
                    NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_ARKIT_UNAVAILABLE_VISION_DEFAULT sessionId=\(sessionId) reason=\(reason) segmentationBackend=\(backend)")
                }
            } else {
                backend = requestedBackend
                session.segmentationBackendSelection = "explicit"
            }
            session.effectiveSegmentationBackend = backend
            let adapter = VGLiveGreenScreenMaskProviderAdapter(
                fastMetalPrecision:  diagnosticsOptions.iosFastMetalPrecision,
                segmentationBackend: backend)
            startCameraPipeline(session: session, registry: registry, adapter: adapter)
        }

        let engineName = session.arkitEngine != nil
            ? VGLiveGreenScreenSessionCoordinator.segmentationEngineARKit
            : VGLiveGreenScreenSessionCoordinator.segmentationEngineAdapter
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_SESSION_STARTED sessionId=\(sessionId) textureId=\(textureId) canvas=\(width)x\(height) foregroundRect=\(VGLiveGreenScreenSessionCoordinator.describe(rects.camera)) segmentationEngine=\(engineName) maskSource=\(session.effectiveSegmentationBackend)_\(engineName)(pending) requestedSegmentationBackend=\(requestedBackend) segmentationBackend=\(session.effectiveSegmentationBackend) segmentationBackendSelection=\(session.segmentationBackendSelection) fastMetalPrecision=\(diagnosticsOptions.iosFastMetalPrecision) liveMatteRefinement=\(diagnosticsOptions.iosLiveMatteRefinement)")

        let descriptor: [String: Any] = [
            "sessionId": sessionId,
            "textureId": textureId,
            "width":     width,
            "height":    height,
        ]
        reply(descriptor, nil)
    }

    // MARK: - updateBackground

    func updateBackground(sessionId: String,
                          background spec: VGLiveGreenScreenBackgroundSpec,
                          videoBackground videoSpec: VGLiveGreenScreenVideoSpec?,
                          reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId,
                                                 route: "updateLiveGreenScreenBackground",
                                                 reply: reply) else { return }

        // ── Video background ─────────────────────────────────────────────────
        if let videoSpec = videoSpec {
            // Video backgrounds require the adapter render loop's frame provider.
            // The ARKit engine does not support dynamic per-frame background updates;
            // fail closed without touching the active background.
            if session.arkitEngine != nil {
                reply(nil, FlutterError(
                    code:    VGLiveGreenScreenSessionCoordinator.errorInvalidArg,
                    message: "updateLiveGreenScreenBackground: video backgrounds are not supported when the ARKit segmentation engine is active; use a solidColor or image background.",
                    details: nil))
                return
            }
            // Validate the new video before touching anything on the session
            // so a missing track or corrupt file leaves the previous background
            // fully alive (fail-open on update, fail-closed on start).
            let newPlayer = VGLiveGreenScreenVideoBackgroundPlayer(
                url: URL(fileURLWithPath: videoSpec.filePath))
            do {
                try newPlayer.validateAndGetDuration()
            } catch {
                let desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                reply(nil, FlutterError(
                    code:    VGLiveGreenScreenSessionCoordinator.errorInvalidArg,
                    message: "updateLiveGreenScreenBackground: background video is not decodable: \(desc)",
                    details: nil))
                return
            }
            // Validation passed: hand over atomically.
            // Release the old player BEFORE starting the new one so only one
            // decode queue is running at a time.
            session.videoPlayer?.release()
            session.videoPlayer   = newPlayer
            session.videoFilePath = videoSpec.filePath
            newPlayer.start()
            let provider: VGLiveGreenScreenRenderLoop.BackgroundFrameProvider = { [weak newPlayer] in
                newPlayer?.latestFrame()
            }
            session.renderLoop?.updateVideoBackgroundProvider(provider)
            NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_BACKGROUND_UPDATED sessionId=\(sessionId) type=video filePath=\(videoSpec.filePath) duration=\(newPlayer.videoDuration)s")
            reply(nil, nil)
            return
        }

        // ── Static background (solidColor or image) ───────────────────────────
        let buffer: CVPixelBuffer
        do {
            buffer = try backgroundRenderer.build(spec: spec,
                                                  canvasWidth: session.canvasWidth,
                                                  canvasHeight: session.canvasHeight)
        } catch {
            // Leave the session's existing background fully alive on error.
            reply(nil, VGLiveGreenScreenSessionCoordinator.flutterError(
                from: error, route: "updateLiveGreenScreenBackground"))
            return
        }
        // Tear down any active video player when switching away from video.
        if session.videoPlayer != nil {
            session.videoPlayer?.release()
            session.videoPlayer   = nil
            session.videoFilePath = nil
            // Clear the provider on the render loop so it reverts to the
            // static background buffer.
            session.renderLoop?.updateVideoBackgroundProvider(nil)
        }
        // Atomic swap on the live engine; camera / segmenter / texture untouched.
        // The session keeps the current buffer so a mid-session fallback
        // pipeline starts on exactly this background.
        session.background = buffer
        if let engine = session.arkitEngine {
            engine.updateBackground(buffer)
        } else {
            session.renderLoop?.updateBackground(buffer)
        }
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_BACKGROUND_UPDATED sessionId=\(sessionId) type=\(VGLiveGreenScreenSessionCoordinator.describe(spec)) segmentationEngine=\(session.arkitEngine != nil ? VGLiveGreenScreenSessionCoordinator.segmentationEngineARKit : VGLiveGreenScreenSessionCoordinator.segmentationEngineAdapter)")
        reply(nil, nil)
    }

    // MARK: - updateTransform

    func updateTransform(sessionId: String,
                         transform: NativeForegroundTransform?,
                         reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId,
                                                 route: "updateLiveGreenScreenTransform",
                                                 reply: reply) else { return }
        let rects = VGDuetLayoutGeometry.greenScreen(canvasWidth: CGFloat(session.canvasWidth),
                                                     canvasHeight: CGFloat(session.canvasHeight),
                                                     transform: transform)
        session.foregroundRect = rects.camera
        if let engine = session.arkitEngine {
            engine.updateForegroundRect(rects.camera)
        } else {
            session.renderLoop?.updateForegroundRect(rects.camera)
        }
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_TRANSFORM_UPDATED sessionId=\(sessionId) foregroundRect=\(VGLiveGreenScreenSessionCoordinator.describe(rects.camera)) segmentationEngine=\(session.arkitEngine != nil ? VGLiveGreenScreenSessionCoordinator.segmentationEngineARKit : VGLiveGreenScreenSessionCoordinator.segmentationEngineAdapter)")
        reply(nil, nil)
    }

    // MARK: - stop

    /// Idempotent: an unknown or already-stopped id completes normally.
    func stopSession(sessionId: String,
                     reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = activeSession, session.sessionId == sessionId else {
            reply(nil, nil)
            return
        }
        release(session)
        reply(nil, nil)
    }

    // MARK: - recording (VG-LIVE-GREENSCREEN-RECORDING)

    /// Starts recording the composited output of the session to an MP4.
    /// Replies once the writer is running and the frame tap is installed;
    /// the first composited video frame then anchors the recording timeline
    /// (t0), and microphone audio captured before it is dropped. Fails closed
    /// with nothing recording and no file left behind: `recording_active`,
    /// `disk_full`, `INVALID_ARG` (bad / existing outputPath) or
    /// `recording_failed` (writer could not be created). Missing microphone
    /// permission or an audio capture start failure degrades to video-only.
    func startRecording(sessionId: String,
                        outputPath: String?,
                        reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        let route = "startLiveGreenScreenRecording"
        guard let session = resolveActiveSession(sessionId: sessionId, route: route, reply: reply) else { return }
        if session.recorder != nil {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorRecordingActive,
                message: "\(route): a recording is already active on session '\(sessionId)'.",
                details: nil))
            return
        }
        let fm = FileManager.default
        let finalURL: URL
        if let outputPath = outputPath {
            guard outputPath.hasPrefix("/") else {
                reply(nil, FlutterError(
                    code:    VGLiveGreenScreenSessionCoordinator.errorInvalidArg,
                    message: "\(route): 'outputPath' must be an absolute local path (got '\(outputPath)').",
                    details: nil))
                return
            }
            if fm.fileExists(atPath: outputPath) {
                reply(nil, FlutterError(
                    code:    VGLiveGreenScreenSessionCoordinator.errorInvalidArg,
                    message: "\(route): 'outputPath' already exists: \(outputPath)",
                    details: nil))
                return
            }
            finalURL = URL(fileURLWithPath: outputPath)
        } else {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(VGLiveGreenScreenSessionCoordinator.defaultRecordingDirectoryName, isDirectory: true)
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            finalURL = dir.appendingPathComponent("live_gs_\(String(sessionId.suffix(8)))_\(stamp).mp4")
        }
        let parentDir = finalURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorRecordingFailed,
                message: "\(route): cannot create the recording directory \(parentDir.path): \(error.localizedDescription)",
                details: nil))
            return
        }
        let freeBytes = VGLiveGreenScreenSessionCoordinator.availableDiskSpaceBytes(forPath: parentDir.path)
        if freeBytes >= 0, freeBytes < VGLiveGreenScreenSessionCoordinator.minFreeDiskBytesForRecording {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorDiskFull,
                message: "\(route): insufficient free space (\(freeBytes / (1024 * 1024)) MB free; \(VGLiveGreenScreenSessionCoordinator.minFreeDiskBytesForRecording / (1024 * 1024)) MB required).",
                details: nil))
            return
        }

        // Microphone: video-only when not authorized. The writer still gets an
        // audio input only when we intend to feed it.
        let micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        let recorder: VGLiveGreenScreenRecorder
        do {
            recorder = try VGLiveGreenScreenRecorder(finalURL: finalURL,
                                                     width: session.canvasWidth,
                                                     height: session.canvasHeight,
                                                     includeAudio: micAuthorized)
        } catch {
            // Nothing was mutated on the session; the recorder cleaned up its temp.
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorRecordingFailed,
                message: "\(route): the recording writer could not be started: \(error.localizedDescription)",
                details: nil))
            return
        }
        session.recorder = recorder

        var audioLane = "disabled:microphone_not_authorized"
        if micAuthorized {
            let mic = VGLiveGreenScreenMicrophoneCapture { [weak recorder] sampleBuffer in
                recorder?.appendAudioSampleBuffer(sampleBuffer)
            }
            if mic.start() {
                session.microphone = mic
                audioLane = "aac_mono"
            } else {
                audioLane = "disabled:microphone_capture_start_failed"
            }
        }

        // Frame tap. Adapter path: startCameraPipeline's presentHandler reads
        // `session.recorder` on main for every presented frame. ARKit path:
        // the engine's render-queue tap feeds the recorder directly; the weak
        // capture means a stopped/canceled recorder simply stops receiving.
        session.arkitEngine?.onCompositedFrame = { [weak recorder] pixelBuffer in
            recorder?.appendVideoFrame(pixelBuffer)
        }

        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_RECORDING_STARTED sessionId=\(sessionId) file=\(finalURL.path) size=\(session.canvasWidth)x\(session.canvasHeight) audio=\(audioLane) segmentationEngine=\(session.arkitEngine != nil ? VGLiveGreenScreenSessionCoordinator.segmentationEngineARKit : VGLiveGreenScreenSessionCoordinator.segmentationEngineAdapter)")
        reply(nil, nil)
    }

    /// Stops the active recording: detaches the frame tap and microphone,
    /// finishes the writer, and commits ".tmp" → final only after the writer
    /// completed with a non-empty file. Replies with
    /// `{filePath, durationMs, fileSizeBytes, width, height, hasAudio}` or
    /// `recording_failed` (partial deleted); `recording_not_active` when no
    /// recording is running. The preview keeps running.
    func stopRecording(sessionId: String,
                       reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        let route = "stopLiveGreenScreenRecording"
        guard let session = resolveActiveSession(sessionId: sessionId, route: route, reply: reply) else { return }
        guard let recorder = session.recorder else {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorRecordingNotActive,
                message: "\(route): no recording is active on session '\(sessionId)'.",
                details: nil))
            return
        }
        detachRecordingSources(session)
        session.recorder = nil
        let width = session.canvasWidth
        let height = session.canvasHeight
        let sid = session.sessionId
        recorder.finish { result in
            // Completion is delivered on main.
            switch result {
            case .success(let outcome):
                NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_RECORDING_COMMITTED sessionId=\(sid) file=\(outcome.filePath) bytes=\(outcome.fileSizeBytes) durationMs=\(outcome.durationMs) audio=\(outcome.hasAudio)")
                reply([
                    "filePath":      outcome.filePath,
                    "durationMs":    outcome.durationMs,
                    "fileSizeBytes": outcome.fileSizeBytes,
                    "width":         width,
                    "height":        height,
                    "hasAudio":      outcome.hasAudio,
                ], nil)
            case .failure(let error):
                NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_RECORDING_FAILED sessionId=\(sid) reason=\(error.localizedDescription)")
                reply(nil, FlutterError(
                    code:    VGLiveGreenScreenSessionCoordinator.errorRecordingFailed,
                    message: "\(route): the recording could not be committed (\(error.localizedDescription)); the partial file was deleted.",
                    details: nil))
            }
        }
    }

    /// Discards the active recording (partial deleted). Idempotent: completes
    /// normally when no recording is running. The preview keeps running.
    func cancelRecording(sessionId: String,
                         reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId,
                                                 route: "cancelLiveGreenScreenRecording",
                                                 reply: reply) else { return }
        discardRecording(session, reason: "cancel")
        reply(nil, nil)
    }

    // MARK: - still photo (VG-LIVE-GREENSCREEN-PHOTO)

    /// Captures the composited output of the session as one JPEG at
    /// `outputPath` and replies with `{filePath, width, height, fileSizeBytes}`.
    ///
    /// The frame is the latest composited CVPixelBuffer the session texture
    /// already presents (both engines hand every composited frame to
    /// `texture.update(pixelBuffer:)`; the recorder taps the same buffer), so
    /// the photo is exactly what the preview shows: never the raw camera,
    /// never a Flutter texture screenshot, never an export-time recomposition.
    ///
    /// Threading: the snapshot is retained under the texture lock on main (a
    /// pointer read); JPEG encoding and file I/O run on `photoEncodeQueue`;
    /// the reply always lands on main. The retained buffer is a strong ARC
    /// reference captured by the encode block and released on every path when
    /// that block completes. The preview and any active recording are not
    /// touched.
    ///
    /// Fails closed with `session_not_found`, `INVALID_ARG` (relative /
    /// existing outputPath) or `recording_failed` (no composited frame yet,
    /// unwritable directory, JPEG encode failure, write failure, or an empty
    /// file after the write); no partial file is left at `outputPath`.
    func takePhoto(sessionId: String,
                   outputPath: String,
                   reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        let route = "takeLiveGreenScreenPhoto"
        guard let session = resolveActiveSession(sessionId: sessionId, route: route, reply: reply) else { return }
        guard outputPath.hasPrefix("/") else {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorInvalidArg,
                message: "\(route): 'outputPath' must be an absolute local path (got '\(outputPath)').",
                details: nil))
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: outputPath) {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorInvalidArg,
                message: "\(route): 'outputPath' already exists: \(outputPath)",
                details: nil))
            return
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        let parentDir = outputURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorRecordingFailed,
                message: "\(route): cannot create the photo directory \(parentDir.path): \(error.localizedDescription)",
                details: nil))
            return
        }

        // Snapshot: strong reference to the latest composited frame, taken
        // under the texture lock (retain only; no encoding inside the lock).
        guard let snapshot = session.texture.latestPixelBufferRetained() else {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorRecordingFailed,
                message: "\(route): no composited frame has been presented yet on session '\(sessionId)'.",
                details: nil))
            return
        }
        let width  = CVPixelBufferGetWidth(snapshot)
        let height = CVPixelBufferGetHeight(snapshot)
        let sid = session.sessionId
        let engine = session.arkitEngine != nil
            ? VGLiveGreenScreenSessionCoordinator.segmentationEngineARKit
            : VGLiveGreenScreenSessionCoordinator.segmentationEngineAdapter
        let quality = VGLiveGreenScreenSessionCoordinator.photoJPEGQuality
        let startTime = CFAbsoluteTimeGetCurrent()

        // Encode + write off the main / render path. `snapshot` is the only
        // session-derived object captured; it is released when this block
        // finishes on every path below.
        VGLiveGreenScreenSessionCoordinator.photoEncodeQueue.async {
            let fail: (String) -> Void = { reason in
                // Never leave a partial at the final path.
                try? fm.removeItem(at: outputURL)
                NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_PHOTO_FAILED sessionId=\(sid) reason=\(reason)")
                DispatchQueue.main.async {
                    reply(nil, FlutterError(
                        code:    VGLiveGreenScreenSessionCoordinator.errorRecordingFailed,
                        message: "\(route): \(reason)",
                        details: nil))
                }
            }
            guard width > 0, height > 0 else {
                fail("the composited frame has an invalid size (\(width)x\(height)).")
                return
            }
            let ciImage = CIImage(cvPixelBuffer: snapshot)
            let colorSpace = ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            let qualityKey = CIImageRepresentationOption(
                rawValue: kCGImageDestinationLossyCompressionQuality as String)
            let options: [CIImageRepresentationOption: Any] = [qualityKey: quality]
            guard let jpegData = VGLiveGreenScreenSessionCoordinator.photoCIContext.jpegRepresentation(
                of: ciImage, colorSpace: colorSpace, options: options),
                  !jpegData.isEmpty else {
                fail("JPEG encoding of the composited frame failed.")
                return
            }
            do {
                try jpegData.write(to: outputURL, options: .atomic)
            } catch {
                fail("the photo could not be written to \(outputPath): \(error.localizedDescription)")
                return
            }
            // Validate the committed file before replying: exists and non-empty.
            guard let attrs = try? fm.attributesOfItem(atPath: outputPath),
                  let sizeNumber = attrs[.size] as? NSNumber,
                  sizeNumber.int64Value > 0 else {
                fail("the written photo is missing or empty at \(outputPath).")
                return
            }
            let fileSizeBytes = sizeNumber.int64Value
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_PHOTO_COMMITTED sessionId=\(sid) file=\(outputPath) size=\(width)x\(height) bytes=\(fileSizeBytes) segmentationEngine=\(engine) elapsedMs=\(String(format: "%.1f", elapsedMs))")
            DispatchQueue.main.async {
                reply([
                    "filePath":      outputPath,
                    "width":         width,
                    "height":        height,
                    "fileSizeBytes": fileSizeBytes,
                ], nil)
            }
        }
    }

    /// Stops feeding the recorder: clears the ARKit tap and stops the
    /// microphone. The adapter presentHandler stops on its own once
    /// `session.recorder` is nil.
    private func detachRecordingSources(_ session: LiveSession) {
        assert(Thread.isMainThread)
        session.arkitEngine?.onCompositedFrame = nil
        session.microphone?.stop()
        session.microphone = nil
    }

    /// Cancels the recorder (writer canceled, ".tmp" deleted) after detaching
    /// its sources. No-op without an active recorder.
    private func discardRecording(_ session: LiveSession, reason: String) {
        assert(Thread.isMainThread)
        detachRecordingSources(session)
        guard let recorder = session.recorder else { return }
        session.recorder = nil
        recorder.cancel()
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_RECORDING_DISCARDED sessionId=\(session.sessionId) reason=\(reason)")
    }

    /// Free bytes on the volume holding `path`, or -1 when unknown (never
    /// blocks a recording on an unreadable attribute).
    private static func availableDiskSpaceBytes(forPath path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber else {
            return -1
        }
        return free.int64Value
    }

    // MARK: - diagnostics (diagnostic-only; physical smoke telemetry)

    /// Returns the adapter's aggregated segmentation timing / matte publication
    /// snapshot for the active session, plus session identity. Read-only: no
    /// lifecycle state changes.
    ///
    /// Always present at top level, in every state:
    ///   isKeyed, degraded (= !isKeyed), terminalState ("keyed" |
    ///   "degraded_unkeyed"), terminalReason / failureReason ("none" while no
    ///   failure), segmentationBackend, providerKind, providerMode,
    ///   sampleCount, maskPublishCount, lastMaskCoveragePercent, adapterReleased.
    /// After the segmentation-degraded path released the adapter, the
    /// snapshot cached by `handleAdapterFailure` (taken while the adapter was
    /// still alive) is merged in, so the exact failure reason and the
    /// provider state at failure time remain observable instead of a bare
    /// "released" placeholder.
    func diagnostics(sessionId: String,
                     reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId,
                                                 route: "getLiveGreenScreenDiagnostics",
                                                 reply: reply) else { return }
        let engineName = session.arkitEngine != nil
            ? VGLiveGreenScreenSessionCoordinator.segmentationEngineARKit
            : VGLiveGreenScreenSessionCoordinator.segmentationEngineAdapter
        var cameraSelectedSessionPreset =
            session.cameraSource?.selectedSessionPreset ?? "unknown"
        var payload: [String: Any] = [
            "sessionId":                    session.sessionId,
            "textureId":                    session.textureId,
            "isKeyed":                      session.isKeyed,
            "degraded":                     !session.isKeyed,
            "terminalState":                session.isKeyed
                ? VGLiveGreenScreenSessionCoordinator.terminalStateKeyed
                : VGLiveGreenScreenSessionCoordinator.terminalStateDegraded,
            "terminalReason":               session.terminalReason
                ?? VGLiveGreenScreenSessionCoordinator.noFailureReason,
            "failureReason":                session.terminalReason
                ?? VGLiveGreenScreenSessionCoordinator.noFailureReason,
            "requestedSegmentationBackend": session.requestedSegmentationBackend,
            "segmentationBackend":          session.effectiveSegmentationBackend,
            "segmentationBackendSelection": session.segmentationBackendSelection,
            "segmentationEngine":           engineName,
            "liveMatteRefinement":          session.requestedLiveMatteRefinement,
            "adapterReleased":              session.adapter == nil && session.arkitEngine == nil,
            "maskMaxAgeSeconds":            VGLiveGreenScreenSessionCoordinator.maskMaxAgeSeconds,
        ]
        if let engine = session.arkitEngine {
            // Live ARKit engine: its snapshot is authoritative and is mapped
            // onto the adapter-compatible keys (providerKind "arkit",
            // providerMode "arkit_face_matte_full", timingSemantics
            // "arkit_matte_generator_spans", sampleCount / maskPublishCount =
            // published composited frames) so no reader can mistake it for
            // Vision. The ARSession video format stands in for the capture
            // session preset.
            let snapshot = engine.diagnosticsSnapshot()
            for (key, value) in VGLiveGreenScreenSessionCoordinator.arkitDiagnosticsPayload(session: session,
                                                                                            snapshot: snapshot) {
                payload[key] = value
            }
            cameraSelectedSessionPreset = "arkit_face_\(snapshot["videoFormatWidth"] ?? 0)x\(snapshot["videoFormatHeight"] ?? 0)@\(snapshot["videoFormatFramesPerSecond"] ?? 0)"
        } else if let adapter = session.adapter {
            // Live adapter: its snapshot is authoritative (failureReason is
            // "none" there unless a failure is in flight).
            for (key, value) in adapter.diagnosticsSnapshot() {
                payload[key] = value
            }
            if let arkitTerminal = session.arkitTerminalDiagnostics {
                // The session started on ARKit and fell back: keep the engine's
                // final summary observable next to the live adapter numbers.
                payload["arkitEngine"] = arkitTerminal
            }
        } else if let terminal = session.terminalDiagnostics {
            // Engine / adapter released by the segmentation failure path:
            // report the snapshot cached at failure time, never a blank
            // placeholder.
            for (key, value) in terminal {
                payload[key] = value
            }
        } else {
            // Defensive: an active session without an engine and without a
            // cached terminal snapshot is not a state this coordinator
            // produces; say so explicitly rather than looking healthy.
            payload["providerKind"]           = "released"
            payload["providerMode"]           = "released"
            payload["sampleCount"]            = 0
            payload["maskPublishCount"]       = 0
            payload["lastMaskCoveragePercent"] = -1
            payload["terminalReason"]         = "adapter_released_without_terminal_diagnostics"
            payload["failureReason"]          = "adapter_released_without_terminal_diagnostics"
        }
        payload["cameraSelectedSessionPreset"] = cameraSelectedSessionPreset
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_DIAGNOSTICS sessionId=\(session.sessionId) isKeyed=\(session.isKeyed) terminalState=\(payload["terminalState"] ?? "?") failureReason=\(payload["failureReason"] ?? "?") adapterReleased=\(payload["adapterReleased"] ?? false) segmentationEngine=\(engineName) cameraSelectedSessionPreset=\(cameraSelectedSessionPreset) providerKind=\(payload["providerKind"] ?? "?") providerMode=\(payload["providerMode"] ?? "?") requestedSegmentationBackend=\(session.requestedSegmentationBackend) segmentationBackend=\(payload["segmentationBackend"] ?? "?") segmentationBackendSelection=\(session.segmentationBackendSelection) liveMatteRefinement=\(payload["liveMatteRefinement"] ?? "?") timingSemantics=\(payload["timingSemantics"] ?? "?") fastMetalPrecision=\(payload["fastMetalPrecision"] ?? false) metalAllowPrecisionLoss=\(payload["metalAllowPrecisionLoss"] ?? false) sampleCount=\(payload["sampleCount"] ?? 0) avgTotalMs=\(payload["avgTotalMs"] ?? -1) maxTotalMs=\(payload["maxTotalMs"] ?? -1) avgInferenceMs=\(payload["avgInferenceMs"] ?? -1) avgInputCopyMs=\(payload["avgInputCopyMs"] ?? -1) avgInvokeMs=\(payload["avgInvokeMs"] ?? -1) avgOutputAccessMs=\(payload["avgOutputAccessMs"] ?? -1) avgCadenceMs=\(payload["avgCadenceMs"] ?? -1) maskPublishCount=\(payload["maskPublishCount"] ?? 0) lastMaskCoveragePercent=\(payload["lastMaskCoveragePercent"] ?? -1) firstMaskLatencyMs=\(payload["firstMaskLatencyMs"] ?? -1) avgMatteGenerationMs=\(payload["avgMatteGenerationMs"] ?? "n/a") avgCompositeMs=\(payload["avgCompositeMs"] ?? "n/a") effectiveFps=\(payload["effectiveFps"] ?? "n/a") maskRefinementPath=\(payload["maskRefinementPath"] ?? "n/a") maskRefinementApplied=\(payload["maskRefinementApplied"] ?? "n/a") maskMorphologyCloseApplied=\(payload["maskMorphologyCloseApplied"] ?? "n/a") maskFeatherApplied=\(payload["maskFeatherApplied"] ?? "n/a") maskTrimapApplied=\(payload["maskTrimapApplied"] ?? "n/a") maskGuidedEdgeApplied=\(payload["maskGuidedEdgeApplied"] ?? "n/a") liveTightAlphaR1Applied=\(payload["liveTightAlphaR1Applied"] ?? "n/a") liveS4GuidedAlphaR1Applied=\(payload["liveS4GuidedAlphaR1Applied"] ?? "n/a") liveS4GuidedAlphaApplied=\(payload["liveS4GuidedAlphaApplied"] ?? "n/a")")
        reply(payload, nil)
    }

    // MARK: - diagnostics options (diagnostic-only; next start only)

    /// Stores diagnostic-only options for the next `startSession`. Rejected
    /// with `live_busy` while a session is active, so the options can never
    /// change a running session. Replies with the stored options
    /// ({iosFastMetalPrecision, iosSegmentationBackend}). Not part of the
    /// public Dart API.
    func setDiagnosticsOptions(_ options: VGLiveGreenScreenDiagnosticsOptions,
                               reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        if let session = activeSession {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorLiveBusy,
                message: "setLiveGreenScreenDiagnosticsOptions: a live green-screen session is already active (id '\(session.sessionId)'); stop it before changing diagnostics options.",
                details: nil))
            return
        }
        pendingDiagnosticsOptions = options
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_DIAGNOSTICS_OPTIONS_SET iosFastMetalPrecision=\(options.iosFastMetalPrecision) iosSegmentationBackend=\(options.iosSegmentationBackend) iosLiveMatteRefinement=\(options.iosLiveMatteRefinement) appliesTo=next_start")
        reply(options.payload, nil)
    }

    // MARK: - Teardown (plugin detach)

    func disposeAll() {
        assert(Thread.isMainThread)
        if let session = activeSession {
            release(session)
        }
        activeSession = nil
        pendingDiagnosticsOptions = .default
    }

    // MARK: - Private: release

    /// Terminal order: render loop stop → adapter invalidate → camera observer
    /// clear → camera stop → ARKit engine frame delivery stop (delegate nil,
    /// ARSession pause, bounded in-flight render drain) → texture invalidate →
    /// texture unregister → ARKit engine ARSession / Metal / CoreImage
    /// resources released → active nil. Only the components the session
    /// created exist (adapter path xor ARKit engine); every step is idempotent.
    private func release(_ session: LiveSession) {
        assert(Thread.isMainThread)

        // A recording never survives its session: discard it (partial deleted)
        // before any frame source is torn down.
        discardRecording(session, reason: "session_release")

        // Clear the video provider before stopping the render loop so the
        // loop cannot call into a player that is being torn down.
        session.renderLoop?.updateVideoBackgroundProvider(nil)
        session.videoPlayer?.release()
        session.videoPlayer   = nil
        session.videoFilePath = nil

        session.renderLoop?.stop()
        session.renderLoop = nil

        session.adapter?.invalidate()
        session.adapter = nil

        session.cameraSource?.setFrameObserver(nil)
        session.cameraSource?.stop()
        session.cameraSource = nil

        let engine = session.arkitEngine
        engine?.onTerminalFailure = nil
        engine?.stopFrameDelivery()

        session.texture.invalidate()
        textureRegistry?.unregisterTexture(session.textureId)

        if let engine = engine {
            _ = engine.stop()
            session.arkitEngine = nil
        }

        if activeSession === session {
            activeSession = nil
        }
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_SESSION_RELEASED sessionId=\(session.sessionId) textureId=\(session.textureId) segmentationEngine=\(engine != nil ? VGLiveGreenScreenSessionCoordinator.segmentationEngineARKit : VGLiveGreenScreenSessionCoordinator.segmentationEngineAdapter)")
    }

    // MARK: - Private: engines

    /// Starts the ARKit engine on the session's texture with the session's
    /// current background, foreground rect, and live matte refinement mode
    /// (the engine refines its matte through its own VGMatteRefinementPipeline
    /// instance — the same refinement pipeline the VGLiveGreenScreenCompositor
    /// `startCameraPipeline` builds runs internally). Returns nil on success
    /// (the engine is stored on the session) or the engine's exact start
    /// failure reason; a failed start registers and retains nothing.
    private func startARKitEngine(session: LiveSession,
                                  registry: FlutterTextureRegistry) -> String? {
        assert(Thread.isMainThread)
        let engineRequest = VGARKitLiveGreenScreenPreviewCoordinator.StartRequest(
            canvasWidth: session.canvasWidth,
            canvasHeight: session.canvasHeight,
            targetFps: VGARKitLiveGreenScreenPreviewCoordinator.productionTargetFps,
            displayOrientationMode: VGARKitLiveGreenScreenPreviewCoordinator.defaultOrientationMode,
            displayOrientation: VGARKitLiveGreenScreenPreviewCoordinator.defaultDisplayOrientation,
            background: session.background,
            foregroundRect: session.foregroundRect,
            liveMatteRefinementMode: session.liveMatteRefinementMode)
        let engine = VGARKitLiveGreenScreenPreviewCoordinator(request: engineRequest,
                                                              textureRegistry: registry,
                                                              texture: session.texture,
                                                              textureId: session.textureId,
                                                              sessionId: session.sessionId)
        engine.onTerminalFailure = { [weak self, weak session, weak engine] reason in
            guard let self = self, let session = session, let engine = engine else { return }
            self.handleARKitEngineFailure(session: session, engine: engine, reason: reason)
        }
        switch engine.start() {
        case .started(let descriptor):
            session.arkitEngine = engine
            NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_ARKIT_ENGINE_STARTED sessionId=\(session.sessionId) textureId=\(session.textureId) providerKind=\(VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsProviderKind) providerMode=\(VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsProviderMode) orientationMode=\(descriptor["orientationMode"] ?? "?") targetFps=\(descriptor["targetFps"] ?? 0) videoFormat=\(descriptor["videoFormatWidth"] ?? 0)x\(descriptor["videoFormatHeight"] ?? 0)@\(descriptor["videoFormatFramesPerSecond"] ?? 0) foregroundRect=\(VGLiveGreenScreenSessionCoordinator.describe(session.foregroundRect)) liveMatteRefinement=\(descriptor["liveMatteRefinement"] ?? "?") maskRefinementPath=\(descriptor["maskRefinementPath"] ?? "?")")
            return nil
        case .failed(let failure):
            let reason = failure["failureReason"] as? String ?? "unknown"
            NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_ARKIT_ENGINE_START_FAILED sessionId=\(session.sessionId) reason=\(reason)")
            return reason
        }
    }

    /// Starts the adapter-path pipeline on the session's texture: optional
    /// mask adapter (nil → camera-only, unkeyed presentation), VGLiveGreenScreenCameraSource
    /// front camera ingress, VGLiveGreenScreenCompositor, VGLiveGreenScreenRenderLoop,
    /// all on the session's current background and foreground rect. Never
    /// called while an ARKit engine is alive on the session.
    private func startCameraPipeline(session: LiveSession,
                                     registry: FlutterTextureRegistry,
                                     adapter: VGLiveGreenScreenMaskProviderAdapter?) {
        assert(Thread.isMainThread)
        assert(session.arkitEngine == nil)

        let compositor = VGLiveGreenScreenCompositor(canvasWidth: Double(session.canvasWidth),
                                                 canvasHeight: Double(session.canvasHeight),
                                                 liveMatteRefinementMode: session.liveMatteRefinementMode)

        // Mask adapter BEFORE camera start so frames are routed to the provider
        // from the first delivered frame. The unavailable handler is wired
        // before start(); provider setup runs asynchronously and warm-up is not
        // a failure (frames are dropped until the provider is selected).
        if let adapter = adapter {
            session.adapter = adapter
            adapter.onProviderUnavailable = { [weak self, weak session] adapterDiagnostics in
                guard let self = self, let session = session else { return }
                self.handleAdapterFailure(session: session, adapterDiagnostics: adapterDiagnostics)
            }
            adapter.start()
        }

        // Camera ingress: observer wired before start() so no frame is missed.
        // Live green-screen requests 960x540 iFrame capture first (vs. the
        // 1080p-first default used by every other camera/Duet caller) — this
        // RND latency path preserves 16:9 aspect while further reducing
        // capture/input cost than 720p; segmentation and compositing do not
        // need full 1080p. Where iFrame960x540 is unsupported the source falls
        // back to 720p before its generic 1080p-first default.
        let camera = VGLiveGreenScreenCameraSource(sessionPresets: [
            AVCaptureSession.Preset.iFrame960x540.rawValue,
            AVCaptureSession.Preset.hd1280x720.rawValue,
        ])
        session.cameraSource = camera
        if let adapter = adapter {
            // Observer runs synchronously on the capture queue; the adapter's submit
            // is non-blocking (the provider retains and dispatches internally).
            camera.setFrameObserver { [weak adapter] pixelBuffer, pts in
                adapter?.submitFrame(pixelBuffer, presentationTime: pts)
            }
        }
        camera.start()
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_CAMERA_STARTED sessionId=\(session.sessionId) cameraSelectedSessionPreset=\(camera.selectedSessionPreset ?? "unknown") keyed=\(adapter != nil)")

        // Presents go texture → textureFrameAvailable on main. Providers hold
        // the session weakly so the loop never keeps a released session alive.
        let texture   = session.texture
        let textureId = session.textureId
        // When the session has a live video player, wire its frame provider so
        // the render loop polls it on every render tick (non-blocking).
        let videoProvider: VGLiveGreenScreenRenderLoop.BackgroundFrameProvider?
        if let player = session.videoPlayer {
            videoProvider = { [weak player] in player?.latestFrame() }
        } else {
            videoProvider = nil
        }

        let loop = VGLiveGreenScreenRenderLoop(
            compositor:     compositor,
            background:     session.background,
            foregroundRect: session.foregroundRect,
            cameraFrameProvider: { [weak session] preferredPTS in
                guard let session = session, let camera = session.cameraSource else { return nil }
                // Pair to the mask's source PTS when it is numeric; otherwise,
                // or when no history frame is inside the window, use the latest.
                if let pts = preferredPTS, pts.isNumeric,
                   let match = camera.snapshotRetainedWithPTS(
                       near: pts,
                       maxDeltaSeconds: VGLiveGreenScreenSessionCoordinator.maskPairingMaxDeltaSeconds) {
                    if !session.loggedFirstAlignedPair {
                        session.loggedFirstAlignedPair = true
                        let absDeltaMs = abs(CMTimeGetSeconds(match.pts) - CMTimeGetSeconds(pts)) * 1000.0
                        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_PTS_ALIGNED_PAIR_FIRST sessionId=\(session.sessionId) absDeltaMs=\(String(format: "%.2f", absDeltaMs)) maskSourcePtsSeconds=\(String(format: "%.4f", CMTimeGetSeconds(pts))) cameraPtsSeconds=\(String(format: "%.4f", CMTimeGetSeconds(match.pts))) maxPairingDeltaMs=\(Int((VGLiveGreenScreenSessionCoordinator.maskPairingMaxDeltaSeconds * 1000.0).rounded()))")
                    }
                    return match.frame
                }
                return camera.snapshotRetained()
            },
            maskProvider: { [weak session] in
                // The adapter returns an owned (+1) CVPixelBuffer that ARC manages
                // in `mask`; passRetained adds the +1 the loop releases after
                // compositing, and `mask` drops its own reference on scope exit.
                // sourcePTS is written only alongside a returned mask.
                var sourcePTS = CMTime.invalid
                guard let mask = session?.adapter?.latestMaskRetained(
                    maxAgeSeconds: VGLiveGreenScreenSessionCoordinator.maskMaxAgeSeconds,
                    sourcePTSOut: &sourcePTS)
                else { return nil }
                return VGLiveGreenScreenRenderLoop.MaskSnapshot(buffer: Unmanaged.passRetained(mask),
                                                                sourcePTS: sourcePTS)
            },
            presentHandler: { [weak session] pixelBuffer in
                texture.update(pixelBuffer: pixelBuffer)
                registry.textureFrameAvailable(textureId)
                // Recording tap (main thread): the same composited buffer the
                // texture just received. nil recorder costs nothing.
                session?.recorder?.appendVideoFrame(pixelBuffer)
            },
            backgroundFrameProvider: videoProvider)
        session.renderLoop = loop
        loop.start()
    }

    /// Called on main (once) when the active ARKit engine failed after start.
    /// Stops the engine completely first (frame delivery off, in-flight render
    /// drained, ARSession and Metal resources released) so the camera is free
    /// before any AVCapture path starts, caches its final summary, then either
    /// continues keyed on the Vision Fast adapter pipeline ("auto") or takes
    /// the degraded-unkeyed segmentation-failure path ("arkit" explicit). The
    /// session, its texture, background, and foreground rect are unchanged.
    private func handleARKitEngineFailure(session: LiveSession,
                                          engine: VGARKitLiveGreenScreenPreviewCoordinator,
                                          reason: String) {
        assert(Thread.isMainThread)
        guard session === activeSession, session.arkitEngine === engine else { return }

        engine.onTerminalFailure = nil
        let summary = engine.stop()
        session.arkitEngine = nil
        session.arkitTerminalDiagnostics = summary
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_ARKIT_ENGINE_FAILED sessionId=\(session.sessionId) reason=\(reason) requestedSegmentationBackend=\(session.requestedSegmentationBackend) publishedFrames=\(summary["publishedFrames"] ?? 0) renderFailureCount=\(summary["renderFailureCount"] ?? 0)")

        guard let registry = textureRegistry else {
            // Not reachable after a successful start (the registry was needed
            // to start); logged so a frozen texture is never silent.
            NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_ARKIT_FALLBACK_UNAVAILABLE sessionId=\(session.sessionId) reason=texture_registry_missing")
            return
        }

        if session.requestedSegmentationBackend == VGLiveGreenScreenSessionCoordinator.segmentationBackendARKit {
            // Explicit ARKit: no Vision fallback by design. Camera-only pipeline
            // + segmentation-failure path (degraded event ios_arkit → unkeyed).
            session.segmentationBackendSelection = "arkit_explicit_runtime_failure(\(reason))"
            startCameraPipeline(session: session, registry: registry, adapter: nil)
            handleAdapterFailure(
                session: session,
                adapterDiagnostics: VGLiveGreenScreenSessionCoordinator.arkitUnavailableDiagnostics(
                    failureReason: "arkit_runtime_failure: \(reason)", engineSummary: summary),
                previousBackend: VGLiveGreenScreenSessionCoordinator.backendIosARKit)
            return
        }

        // "auto": keep keying on the Vision Fast adapter pipeline — same
        // texture, same current background and foreground rect, same
        // diagnostics options a direct adapter start would have used.
        let backend = VGLiveGreenScreenSegmentationBackendVisionFast
        session.effectiveSegmentationBackend = backend
        session.segmentationBackendSelection = "vision_fallback_after_arkit_runtime_failure(\(reason))"
        let adapter = VGLiveGreenScreenMaskProviderAdapter(
            fastMetalPrecision:  session.fastMetalPrecision,
            segmentationBackend: backend)
        startCameraPipeline(session: session, registry: registry, adapter: adapter)
        let failureReason = "arkit_runtime_failure: \(reason)"
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_ARKIT_FALLBACK_TO_VISION sessionId=\(session.sessionId) reason=\(reason) segmentationBackend=\(backend) — keying continues on the adapter path")

        // Degraded event: keying continues on a lower rung (ios_arkit → ios_ml),
        // mirroring the Dart `degraded` semantics ("moved to a lower rung; the
        // camera is still keyed").
        onLiveGreenScreenEvent?([
            "event":               VGLiveGreenScreenSessionCoordinator.eventDegraded,
            "type":                "degraded",
            "sessionId":           session.sessionId,
            "previousBackend":     VGLiveGreenScreenSessionCoordinator.backendIosARKit,
            "currentBackend":      VGLiveGreenScreenSessionCoordinator.backendIosMl,
            "reason":              failureReason,
            "failureCategory":     VGLiveGreenScreenSessionCoordinator.reasonARKitEngineFailure,
            "failureReason":       failureReason,
            "segmentationBackend": backend,
            "providerKind":        "pending",
            "providerMode":        "pending",
            "userMessage":         VGLiveGreenScreenSessionCoordinator.arkitFallbackUserMessage,
        ])
    }

    /// Synthetic "no provider" diagnostics for an explicit ARKit request that
    /// could not start or failed at runtime, shaped like the adapter's
    /// `onProviderUnavailable` snapshot so `handleAdapterFailure` caches and
    /// reports it exactly as it would a Vision / LiteRT setup failure. The
    /// engine's final summary (when it ran) travels under `arkitEngine`.
    private static func arkitUnavailableDiagnostics(failureReason: String,
                                                    engineSummary: [String: Any]?) -> [String: Any] {
        let published = engineSummary?["publishedFrames"] as? Int ?? 0
        var diagnostics: [String: Any] = [
            "providerKind":            "unavailable",
            "providerMode":            "arkit_unavailable",
            "segmentationBackend":     segmentationBackendARKit,
            "timingSemantics":         "none",
            "failureReason":           failureReason,
            "modelName":               VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsModelName,
            "mattePath":               VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsMattePath,
            "sampleCount":             published,
            "maskPublishCount":        published,
            "lastMaskCoveragePercent": -1,
        ]
        if let engineSummary = engineSummary {
            diagnostics["arkitEngine"] = engineSummary
        }
        return diagnostics
    }

    /// Maps a live ARKit engine snapshot onto the diagnostics keys the adapter
    /// path reports (see VGLiveGreenScreenMaskProviderAdapter.diagnosticsSnapshot)
    /// and keeps every engine-specific key verbatim (avgMatteGenerationMs,
    /// p95MatteGenerationMs, avgCompositeMs, p95CompositeMs, effectiveFps,
    /// publishedFrames, droppedBusyFrames, skippedNoMaskFrames, throttledFrames,
    /// droppedPoolExhaustedFrames, videoFormat*, engineState, foregroundRect,
    /// liveMatteRefinement, maskRefinementPath, maskRefinementApplied,
    /// maskMorphologyCloseApplied, maskFeatherApplied, maskTrimapApplied,
    /// maskGuidedEdgeApplied, liveTightAlphaR1Applied, liveS4GuidedAlphaR1Applied,
    /// liveS4GuidedAlphaApplied, …).
    /// Timing semantics "arkit_matte_generator_spans": invoke = ARMatteGenerator
    /// generateMatte + GPU wait, inputCopy = 0, outputAccess = matte texture →
    /// CVPixelBuffer copy, policy = CoreImage blend + render, total = matte +
    /// composite per published frame.
    private static func arkitDiagnosticsPayload(session: LiveSession,
                                                snapshot: [String: Any]) -> [String: Any] {
        var payload: [String: Any] = [:]
        for (key, value) in snapshot where key != "pass" && key != "proofBoundary" {
            payload[key] = value
        }
        func number(_ key: String) -> Double? {
            return (snapshot[key] as? NSNumber)?.doubleValue
        }
        func sum(_ a: Double?, _ b: Double?) -> Double {
            guard let a = a, let b = b else { return -1 }
            return a + b
        }
        let published    = snapshot["publishedFrames"] as? Int ?? 0
        let avgMatte     = number("avgMatteGenerationMs")
        let maxMatte     = number("maxMatteGenerationMs")
        let avgCopy      = number("avgMatteCopyMs")
        let maxCopy      = number("maxMatteCopyMs")
        let avgComposite = number("avgCompositeMs")
        let maxComposite = number("maxCompositeMs")

        payload["providerKind"]                     = VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsProviderKind
        payload["providerMode"]                     = VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsProviderMode
        payload["timingSemantics"]                  = VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsTimingSemantics
        payload["segmentationBackend"]              = segmentationBackendARKit
        payload["failureReason"]                    = (snapshot["failureReason"] as? String) ?? noFailureReason
        payload["modelName"]                        = VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsModelName
        payload["mattePath"]                        = VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsMattePath
        payload["inputGeometry"]                    = "aspectFill"
        payload["fastMetalPrecision"]               = session.fastMetalPrecision
        payload["metalAllowPrecisionLossRequested"] = session.fastMetalPrecision
        payload["metalAllowPrecisionLoss"]          = false
        payload["active"]                           = (snapshot["engineState"] as? String) == "running"
        payload["sampleCount"]                      = published
        payload["maskPublishCount"]                 = published
        payload["lastMaskCoveragePercent"]          = -1
        payload["lastMaskWidth"]                    = snapshot["matteWidth"] ?? 0
        payload["lastMaskHeight"]                   = snapshot["matteHeight"] ?? 0
        payload["avgTotalMs"]                       = sum(avgMatte, avgComposite)
        payload["maxTotalMs"]                       = sum(maxMatte, maxComposite)
        payload["avgInferenceMs"]                   = avgMatte ?? -1
        payload["maxInferenceMs"]                   = maxMatte ?? -1
        payload["avgInputCopyMs"]                   = 0
        payload["avgInvokeMs"]                      = avgMatte ?? -1
        payload["maxInvokeMs"]                      = maxMatte ?? -1
        payload["avgOutputAccessMs"]                = avgCopy ?? -1
        payload["maxOutputAccessMs"]                = maxCopy ?? -1
        payload["avgPolicyMs"]                      = (avgComposite != nil && avgCopy != nil) ? avgComposite! - avgCopy! : -1
        payload["avgCadenceMs"]                     = number("avgPublishIntervalMs") ?? -1
        payload["firstMaskLatencyMs"]               = number("firstMaskLatencyMs") ?? -1
        payload["firstPublishLatencyMs"]            = number("firstPublishLatencyMs") ?? -1
        return payload
    }

    // MARK: - Private: segmentation failure

    /// Called on main when VGLiveGreenScreenMaskProviderAdapter could create no
    /// mask provider at all (neither LiteRT nor the heuristic fallback), or —
    /// with a synthetic snapshot (`arkitUnavailableDiagnostics`) — when an
    /// explicitly requested ARKit engine was unavailable or failed. Keying
    /// is disabled and rendering continues unkeyed over the same background;
    /// the session is NOT stopped.
    ///
    /// `adapterDiagnostics` is the adapter's snapshot handed over by
    /// `onProviderUnavailable` (providerKind "unavailable", exact
    /// `failureReason`, …). It is cached on the session — together with the
    /// session fields that must outlive the adapter — BEFORE the adapter is
    /// invalidated and dropped, so `diagnostics(sessionId:)` and the degraded
    /// event can both report why keying failed. `previousBackend` names the
    /// backend that was keying before (ios_ml for the adapter, ios_arkit for
    /// the ARKit engine) in the degraded event.
    private func handleAdapterFailure(session: LiveSession,
                                      adapterDiagnostics: [String: Any],
                                      previousBackend: String = VGLiveGreenScreenSessionCoordinator.backendIosMl) {
        assert(Thread.isMainThread)
        guard session === activeSession, session.isKeyed else { return }
        session.isKeyed = false

        // ── 1. Capture everything we still can while the adapter is alive ───
        // Start from a fresh snapshot of the live adapter, then overlay the
        // one the adapter handed us (same state; the callback copy wins).
        var cached: [String: Any] = session.adapter?.diagnosticsSnapshot() ?? [:]
        for (key, value) in adapterDiagnostics {
            cached[key] = value
        }
        let snapshotReason = cached["failureReason"] as? String
        let adapterReason  = session.adapter?.failureReason
        let exactReason: String? = [snapshotReason, adapterReason]
            .compactMap { $0 }
            .first { !$0.isEmpty && $0 != VGLiveGreenScreenSessionCoordinator.noFailureReason }
        let terminalReason = exactReason ?? "unknown"
        session.terminalReason = terminalReason

        // Session fields that must survive the adapter release. Values already
        // present in the adapter snapshot (providerKind, providerMode,
        // segmentationBackend, sampleCount, maskPublishCount,
        // lastMaskCoveragePercent, …) are kept; only what the adapter cannot
        // know about the session is added or normalised here.
        cached["isKeyed"]             = false
        cached["degraded"]            = true
        cached["terminalState"]       = VGLiveGreenScreenSessionCoordinator.terminalStateDegraded
        cached["terminalReason"]      = terminalReason
        cached["failureReason"]       = terminalReason
        cached["failureCategory"]     = VGLiveGreenScreenSessionCoordinator.reasonSegmentationFailure
        cached["adapterReleased"]     = true
        if cached["segmentationBackend"] == nil {
            cached["segmentationBackend"] = session.requestedSegmentationBackend
        }
        if cached["providerKind"] == nil {
            cached["providerKind"] = "unavailable"
        }
        if cached["providerMode"] == nil {
            cached["providerMode"] = cached["providerKind"] ?? "unavailable"
        }
        if cached["sampleCount"] == nil             { cached["sampleCount"] = 0 }
        if cached["maskPublishCount"] == nil        { cached["maskPublishCount"] = 0 }
        if cached["lastMaskCoveragePercent"] == nil { cached["lastMaskCoveragePercent"] = -1 }
        session.terminalDiagnostics = cached

        let providerKindName = cached["providerKind"] as? String ?? "unavailable"
        let providerModeName = cached["providerMode"] as? String ?? providerKindName
        let backendName      = cached["segmentationBackend"] as? String ?? session.requestedSegmentationBackend

        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_SEGMENTATION_DEGRADED sessionId=\(session.sessionId) failureReason=\(terminalReason) providerKind=\(providerKindName) providerMode=\(providerModeName) segmentationBackend=\(backendName) sampleCount=\(cached["sampleCount"] ?? 0) maskPublishCount=\(cached["maskPublishCount"] ?? 0) — continuing unkeyed over the same background")

        // ── 2. Stop feeding the segmenter and release it; camera and texture stay up.
        session.cameraSource?.setFrameObserver(nil)
        session.adapter?.invalidate()
        session.adapter = nil
        session.renderLoop?.setKeyingEnabled(false)

        // ── 3. Degraded event: `reason` is the exact adapter failure reason
        // (mirrors the Android payload, where `reason` is e.g.
        // mlkit_init_failed); `failureCategory` keeps the generic
        // segmentation_failure classification and `failureReason` repeats the
        // exact reason under an explicit key.
        onLiveGreenScreenEvent?([
            "event":               VGLiveGreenScreenSessionCoordinator.eventDegraded,
            "type":                "degraded",
            "sessionId":           session.sessionId,
            "previousBackend":     previousBackend,
            "currentBackend":      VGLiveGreenScreenSessionCoordinator.backendUnkeyed,
            "reason":              exactReason ?? VGLiveGreenScreenSessionCoordinator.reasonSegmentationFailure,
            "failureCategory":     VGLiveGreenScreenSessionCoordinator.reasonSegmentationFailure,
            "failureReason":       terminalReason,
            "segmentationBackend": backendName,
            "providerKind":        providerKindName,
            "providerMode":        providerModeName,
            "userMessage":         VGLiveGreenScreenSessionCoordinator.degradedUserMessage,
        ])
    }

    // MARK: - Private helpers

    private func resolveActiveSession(sessionId: String,
                                      route: String,
                                      reply: @escaping (Any?, FlutterError?) -> Void) -> LiveSession? {
        guard let session = activeSession, session.sessionId == sessionId else {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorSessionNotFound,
                message: "\(route): no active live green-screen session with id '\(sessionId)'.",
                details: nil))
            return nil
        }
        return session
    }

    private static func flutterError(from error: Error, route: String) -> FlutterError {
        if let bg = error as? VGLiveGreenScreenBackgroundError {
            let code: String
            switch bg.kind {
            case .invalidArgument:   code = errorInvalidArg
            case .compositionFailed: code = errorCompositionFailed
            }
            return FlutterError(code: code, message: "\(route): \(bg.message)", details: nil)
        }
        return FlutterError(code: errorCompositionFailed,
                            message: "\(route): \(error.localizedDescription)",
                            details: nil)
    }

    /// Compact "x,y wxh" rect description for log markers (whole pixels).
    private static func describe(_ rect: CGRect) -> String {
        return "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) \(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }

    private static func describe(_ spec: VGLiveGreenScreenBackgroundSpec) -> String {
        switch spec {
        case .solidColor(let argb):
            return "solidColor(0x" + String(UInt32(bitPattern: argb), radix: 16, uppercase: true) + ")"
        case .image(_, let mode):
            return mode == .aspectFill ? "image(aspectFill)" : "image(aspectFit)"
        }
    }
}

// MARK: - VGLiveGreenScreenRecorder (file-private; VG-LIVE-GREENSCREEN-RECORDING)
//
// One instance == one recording == one MP4. AVAssetWriter writes to
// "<final>.tmp"; `finish` commits the temp to the final path only after the
// writer completed and the file is non-empty; `cancel` (and every failure
// path) deletes the temp and never touches the final path.
//
// Timeline: the FIRST composited video frame anchors t0 (host clock) and is
// written at PTS 0; every later video PTS is host-now minus t0. Audio sample
// buffers (AVCaptureAudioDataOutput, host-clock timestamps) are retimed to
// the same t0; any buffer that would land before PTS 0 -- captured before the
// first video frame or before t0 existed -- is dropped. Both tracks are kept
// strictly monotonic, so no out-of-order PTS is ever appended.
//
// Packaging note: defined here (not in its own source file) so it compiles
// through the existing Pods project without a project mutation.

fileprivate final class VGLiveGreenScreenRecorder {

    struct Outcome {
        let filePath: String
        let durationMs: Int
        let fileSizeBytes: Int
        let hasAudio: Bool
    }

    private struct RecorderError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    let finalURL: URL
    let tmpURL: URL
    let width: Int
    let height: Int
    let includesAudio: Bool

    private let writerQueue = DispatchQueue(label: "com.connects.vanguard.livegreenscreen.recorder",
                                            qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?

    // writerQueue-confined state.
    private var originHostTime: CMTime?
    private var lastVideoPTS: CMTime = .invalid
    private var lastAudioPTS: CMTime = .invalid
    private var videoFramesAppended = 0
    private var videoFramesDropped = 0
    private var audioBuffersAppended = 0
    private var isFinishing = false
    private var isCancelled = false
    private var loggedVideoAppendFailure = false
    private var loggedAudioAppendFailure = false

    init(finalURL: URL, width: Int, height: Int, includeAudio: Bool,
         averageBitRate: Int = 10_000_000) throws {
        self.finalURL = finalURL
        self.tmpURL = URL(fileURLWithPath: finalURL.path + ".tmp")
        self.width = width
        self.height = height
        self.includesAudio = includeAudio

        let fm = FileManager.default
        if fm.fileExists(atPath: tmpURL.path) {
            try? fm.removeItem(at: tmpURL)
        }

        let assetWriter = try AVAssetWriter(outputURL: tmpURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(vInput) else {
            try? fm.removeItem(at: tmpURL)
            throw RecorderError(reason: "cannot_add_video_input")
        }
        assetWriter.add(vInput)
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput,
                                                                sourcePixelBufferAttributes: nil)

        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(aInput) {
                assetWriter.add(aInput)
                self.audioInput = aInput
            } else {
                NSLog("[VGLiveGreenScreenRecorder] audio input rejected by AVAssetWriter; recording video-only")
            }
        }

        guard assetWriter.startWriting() else {
            let error = assetWriter.error
            try? fm.removeItem(at: tmpURL)
            throw error ?? RecorderError(reason: "asset_writer_start_failed")
        }

        self.writer = assetWriter
        self.videoInput = vInput
        self.adaptor = pixelAdaptor
    }

    // MARK: Video

    /// Appends one composited frame. Safe from any thread; the host time is
    /// sampled synchronously so queueing latency never skews the timeline.
    func appendVideoFrame(_ pixelBuffer: CVPixelBuffer) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        writerQueue.async { [self] in
            guard let writer = self.writer,
                  let input = self.videoInput,
                  let adaptor = self.adaptor,
                  !self.isFinishing, !self.isCancelled,
                  writer.status == .writing else { return }

            if self.originHostTime == nil {
                self.originHostTime = now
                writer.startSession(atSourceTime: .zero)
                NSLog("[VGLiveGreenScreenRecorder] IOS_LIVE_GREENSCREEN_RECORDING_FIRST_FRAME t0Host=\(String(format: "%.6f", CMTimeGetSeconds(now)))")
            }
            guard let origin = self.originHostTime else { return }
            let pts = CMTimeSubtract(now, origin)
            guard pts >= .zero else { return }
            if self.lastVideoPTS.isValid, pts <= self.lastVideoPTS { return }
            guard input.isReadyForMoreMediaData else {
                self.videoFramesDropped += 1
                return
            }
            if adaptor.append(pixelBuffer, withPresentationTime: pts) {
                self.lastVideoPTS = pts
                self.videoFramesAppended += 1
            } else if !self.loggedVideoAppendFailure {
                self.loggedVideoAppendFailure = true
                NSLog("[VGLiveGreenScreenRecorder] appendVideo failed: status=%ld error=%@",
                      writer.status.rawValue, String(describing: writer.error))
            }
        }
    }

    // MARK: Audio

    /// Appends one captured microphone buffer, retimed to the recording
    /// timeline. Dropped while no video frame has anchored t0 and for any
    /// buffer that would land before PTS 0 or behind the last appended one.
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [self] in
            guard let writer = self.writer,
                  let input = self.audioInput,
                  let origin = self.originHostTime,
                  !self.isFinishing, !self.isCancelled,
                  writer.status == .writing else { return }

            let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard rawPTS.isNumeric else { return }
            let pts = CMTimeSubtract(rawPTS, origin)
            guard pts >= .zero else { return }
            if self.lastAudioPTS.isValid, pts <= self.lastAudioPTS { return }
            guard let retimed = VGLiveGreenScreenRecorder.retimed(sampleBuffer, to: pts) else { return }
            guard input.isReadyForMoreMediaData else { return }
            if input.append(retimed) {
                self.lastAudioPTS = pts
                self.audioBuffersAppended += 1
            } else if !self.loggedAudioAppendFailure {
                self.loggedAudioAppendFailure = true
                NSLog("[VGLiveGreenScreenRecorder] appendAudio failed: status=%ld error=%@",
                      writer.status.rawValue, String(describing: writer.error))
            }
        }
    }

    // MARK: Finish / cancel

    /// Finishes the writer and commits the temp to `finalURL`; `completion`
    /// is delivered on the main thread exactly once. Every failure deletes
    /// the temp and leaves nothing at the final path.
    func finish(completion: @escaping (Result<Outcome, Error>) -> Void) {
        writerQueue.async { [self] in
            guard !self.isFinishing, !self.isCancelled, let writer = self.writer else {
                self.deliver(.failure(RecorderError(reason: "recorder_not_active")), completion)
                return
            }
            self.isFinishing = true

            guard self.originHostTime != nil, self.videoFramesAppended > 0 else {
                // No video frame ever anchored the session: AVAssetWriter must
                // never be asked to finish a session that was not started.
                if writer.status == .writing { writer.cancelWriting() }
                self.releaseWriter()
                self.removeTemp()
                self.deliver(.failure(RecorderError(reason: "no_video_frames")), completion)
                return
            }
            guard writer.status == .writing else {
                let error = writer.error ?? RecorderError(reason: "writer_status_\(writer.status.rawValue)")
                if writer.status == .writing { writer.cancelWriting() }
                self.releaseWriter()
                self.removeTemp()
                self.deliver(.failure(error), completion)
                return
            }

            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            let tmp = self.tmpURL
            let finalFile = self.finalURL
            let durationMs = Int((CMTimeGetSeconds(self.lastVideoPTS) * 1000.0).rounded())
            let hasAudio = self.audioBuffersAppended > 0
            let framesAppended = self.videoFramesAppended
            let framesDropped = self.videoFramesDropped
            writer.finishWriting { [self] in
                self.writerQueue.async {
                    self.releaseWriter()
                    guard writer.status == .completed else {
                        let error = writer.error ?? RecorderError(reason: "finish_writing_failed_status_\(writer.status.rawValue)")
                        self.removeTemp()
                        self.deliver(.failure(error), completion)
                        return
                    }
                    let fm = FileManager.default
                    let attrs = try? fm.attributesOfItem(atPath: tmp.path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    guard size > 0 else {
                        self.removeTemp()
                        self.deliver(.failure(RecorderError(reason: "empty_output")), completion)
                        return
                    }
                    if fm.fileExists(atPath: finalFile.path) {
                        try? fm.removeItem(at: finalFile)
                    }
                    do {
                        try fm.moveItem(at: tmp, to: finalFile)
                    } catch {
                        self.removeTemp()
                        self.deliver(.failure(RecorderError(reason: "commit_move_failed: \(error.localizedDescription)")), completion)
                        return
                    }
                    let finalAttrs = try? fm.attributesOfItem(atPath: finalFile.path)
                    let finalSize = (finalAttrs?[.size] as? NSNumber)?.int64Value ?? 0
                    guard finalSize > 0 else {
                        try? fm.removeItem(at: finalFile)
                        self.deliver(.failure(RecorderError(reason: "empty_output_after_commit")), completion)
                        return
                    }
                    NSLog("[VGLiveGreenScreenRecorder] IOS_LIVE_GREENSCREEN_RECORDING_FINALIZED file=\(finalFile.lastPathComponent) bytes=\(finalSize) durationMs=\(durationMs) framesAppended=\(framesAppended) framesDropped=\(framesDropped) audioBuffers=\(self.audioBuffersAppended)")
                    self.deliver(.success(Outcome(filePath: finalFile.path,
                                                  durationMs: durationMs,
                                                  fileSizeBytes: Int(finalSize),
                                                  hasAudio: hasAudio)), completion)
                }
            }
        }
    }

    /// Discards the recording: cancels the writer and deletes the temp.
    /// Idempotent; never touches `finalURL`.
    func cancel() {
        writerQueue.async { [self] in
            guard !self.isCancelled else { return }
            self.isCancelled = true
            if let writer = self.writer, writer.status == .writing {
                writer.cancelWriting()
            }
            self.releaseWriter()
            self.removeTemp()
            NSLog("[VGLiveGreenScreenRecorder] IOS_LIVE_GREENSCREEN_RECORDING_DISCARDED file=\(self.finalURL.lastPathComponent) framesAppended=\(self.videoFramesAppended)")
        }
    }

    // MARK: Private

    private func releaseWriter() {
        writer = nil
        videoInput = nil
        adaptor = nil
        audioInput = nil
    }

    private func removeTemp() {
        let fm = FileManager.default
        if fm.fileExists(atPath: tmpURL.path) {
            try? fm.removeItem(at: tmpURL)
        }
    }

    private func deliver(_ result: Result<Outcome, Error>,
                         _ completion: @escaping (Result<Outcome, Error>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    /// Copies `sampleBuffer` with its presentation time replaced by `pts`
    /// (duration preserved, no decode timestamp), so the writer sees
    /// recording-relative timing while the PCM bytes pass through untouched.
    private static func retimed(_ sampleBuffer: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                           sampleBuffer: sampleBuffer,
                                                           sampleTimingEntryCount: 1,
                                                           sampleTimingArray: &timing,
                                                           sampleBufferOut: &copy)
        guard status == noErr else { return nil }
        return copy
    }
}

// MARK: - VGLiveGreenScreenMicrophoneCapture (file-private; VG-LIVE-GREENSCREEN-RECORDING)
//
// Audio-only AVCaptureSession delivering raw microphone sample buffers
// (host-clock timestamps) to the recorder, which retimes them to its own t0.
// Independent of the video source: it runs alongside the adapter path's
// VGLiveGreenScreenCameraSource or the ARKit engine's ARSession without
// touching either. Packaged in this file for the same Pods-project reason as
// the recorder above.

fileprivate final class VGLiveGreenScreenMicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    typealias AudioBufferHandler = (CMSampleBuffer) -> Void

    private let captureQueue = DispatchQueue(label: "com.connects.vanguard.livegreenscreen.mic",
                                             qos: .userInitiated)
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var onAudioBuffer: AudioBufferHandler?
    private var isCapturing = false

    init(onAudioBuffer: @escaping AudioBufferHandler) {
        self.onAudioBuffer = onAudioBuffer
        super.init()
    }

    deinit {
        let session = captureSession
        let output = audioOutput
        output?.setSampleBufferDelegate(nil, queue: nil)
        if let s = session, s.isRunning {
            captureQueue.async { s.stopRunning() }
        }
    }

    /// Builds the audio capture graph synchronously (so the caller learns
    /// whether a microphone lane exists) and starts it asynchronously.
    /// Returns false, with nothing running, when no microphone device/input
    /// is available or the output cannot be attached.
    func start() -> Bool {
        var configured = false
        captureQueue.sync { [self] in
            guard !self.isCapturing else { configured = true; return }
            let session = AVCaptureSession()
            guard let mic = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: mic),
                  session.canAddInput(input) else {
                NSLog("[VGLiveGreenScreenMicrophoneCapture] microphone device/input unavailable; recording video-only")
                return
            }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: self.captureQueue)
            guard session.canAddOutput(output) else {
                NSLog("[VGLiveGreenScreenMicrophoneCapture] audio data output rejected; recording video-only")
                return
            }
            session.addOutput(output)
            self.captureSession = session
            self.audioOutput = output
            self.isCapturing = true
            configured = true
        }
        if configured, let session = captureSession, !session.isRunning {
            captureQueue.async { session.startRunning() }
        }
        return configured
    }

    /// Stops delivery synchronously on the capture queue (so no buffer can be
    /// handed out after this returns), then stops the session asynchronously.
    func stop() {
        captureQueue.sync { [self] in
            self.isCapturing = false
            self.onAudioBuffer = nil
        }
        let session = captureSession
        let output = audioOutput
        captureSession = nil
        audioOutput = nil
        output?.setSampleBufferDelegate(nil, queue: nil)
        if let s = session, s.isRunning {
            captureQueue.async { s.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isCapturing, let handler = onAudioBuffer else { return }
        handler(sampleBuffer)
    }
}
