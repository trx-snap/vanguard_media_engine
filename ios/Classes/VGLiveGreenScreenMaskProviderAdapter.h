// VGLiveGreenScreenMaskProviderAdapter.h
// Generic live green-screen: person-matte source for one live session.
// Caller-agnostic — live meeting/calling, going live, camera, or any other
// surface that starts a generic live green-screen session. Nothing here is
// scoped to Duet.
//
// What it replaces: the VanguardMLSegmenter path (no VanguardSegmentation
// .mlmodelc ships, so it silently fell back to Vision balanced person
// segmentation). This adapter uses Apple Vision person segmentation (Vision
// Fast) as the iOS production default, or the package's selectable LiteRT/TFLite +
// Metal delegate provider (VGLiteRTMaskProvider) with the bundled
// selfie_multiclass_256x256.tflite resolved through VGMLModelBundle.
//
// Ownership / composition:
//   VGLiveGreenScreenMaskProviderAdapter
//     ├─ VGLiteRTMaskProvider          (model + interpreter + Metal delegate)  — backend "litert" (selectable alternate)
//     │    └─ VGLiveGreenScreenPersonMattePolicy (tensor → full-person matte)
//     ├─ VGHeuristicMaskProvider       (fallback ONLY when LiteRT is not ready)
//     ├─ VGLiveGreenScreenVisionMaskProvider (VNGeneratePersonSegmentationRequest)
//     │                                 — backend "visionFast" (iOS production default);
//     │                                   backends "visionBalanced" / "visionAccurate"
//     │                                   (diagnostic comparison backends)
//     └─ VGLiteRTMaskProvider          (selfie_segmentation_landscape.tflite — the Android
//                                       production MediaPipe CPU model — aspect-fit input,
//                                       direct single-channel person-confidence matte, no policy)
//                                       — backend "litertSelfie" (diagnostic measurement only)
//
// Backend selection (segmentationBackend, fixed at init; see the constants
// below). `init` and `initWithFastMetalPrecision:` always select "visionFast"
// (iOS production default); only the diagnostics-options route can request
// LiteRT as an alternate backend or VisionBalanced / VisionAccurate /
// litertSelfie for diagnostics, and only for the next session start.
//
// Provider selection happens once, asynchronously, after start():
//   backend "litert":
//   - model asset resolved + LiteRT ready → kind = LiteRT
//     (IOS_LIVE_GREENSCREEN_MASK_PROVIDER_LITERT_READY)
//   - otherwise                          → kind = HeuristicFallback
//     (IOS_LIVE_GREENSCREEN_MASK_PROVIDER_FALLBACK reason=…). The heuristic
//     provider is a Vision-landmark face/neck skin rasterizer: it yields a
//     matte, never a blank one, but it covers the face region only.
//   backend "visionFast" / "visionBalanced" / "visionAccurate":
//   - Vision person segmentation available → kind = Vision
//     (IOS_LIVE_GREENSCREEN_MASK_PROVIDER_VISION_READY quality=fast|balanced|accurate)
//   - otherwise (iOS < 15)               → kind = Unavailable. There is NO
//     heuristic fallback for a Vision request: an A/B run must never report
//     numbers produced by a different provider than the one requested.
//   backend "litertSelfie":
//   - small selfie model asset resolved + LiteRT ready (contract validated,
//     warm-up invoke passed) → kind = LiteRT
//     (IOS_LIVE_GREENSCREEN_MASK_PROVIDER_LITERT_READY model=selfie_segmentation_landscape
//     mattePath=person_confidence_direct); diagnostics providerMode is
//     prefixed litert_selfie so it can never be confused with "litert".
//   - otherwise                          → kind = Unavailable, NO heuristic
//     fallback (same rule as Vision). The model carries a MediaPipe custom op
//     that only the Metal delegate can execute, so this backend is expected
//     to be Unavailable on the simulator.
//   any backend:
//   - no provider could be created       → kind = Unavailable, `failureReason`
//     is persisted (readable from diagnosticsSnapshot for the rest of the
//     adapter's life, even after invalidate) and onProviderUnavailable fires
//     on main with that snapshot (IOS_LIVE_GREENSCREEN_MASK_PROVIDER_UNAVAILABLE).
//   The heuristic provider is NOT passed into VGLiteRTMaskProvider as its
//   internal fallback: the provider forwards frames to that fallback whenever
//   an inference is in flight, which would run Vision landmark detection on
//   dropped frames for no benefit during a live call.
//
// Mask contract exposed to the render loop:
//   latestMaskRetained(maxAgeSeconds:) returns a +1 retained
//   kCVPixelFormatType_OneComponent8 buffer (255 = subject) whose aspect
//   ratio matches the camera frame, or NULL when no matte exists yet, the
//   provider published an invalid/empty matte, or the matte is stale. The
//   bytes are copied once per published VGSkinMask into a pooled, IOSurface-
//   backed buffer that the adapter caches and re-hands (+1) on every render
//   until the next matte lands — no per-render allocation and no reference to
//   provider-owned memory ever escapes.
//   latestMaskRetained(maxAgeSeconds:sourcePTSOut:) is the same contract and
//   additionally reports the camera PTS the matte was computed from, so the
//   render loop can pair the matte with the camera frame of the same instant
//   (VGDuetCameraSource.snapshotRetained(near:maxDeltaSeconds:)) instead of
//   keying the newest frame with an older matte.
//
// Staleness: measured as (last submitted camera PTS − matte source PTS) when
// both are numeric, otherwise wall-clock time since the matte was first
// observed. A stale matte returns NULL so the compositor presents the unkeyed
// camera instead of keying with a mismatched matte.
//
// Threading:
//   start / invalidate            — main thread (coordinator lifecycle).
//   submitFrame:presentationTime: — camera capture queue; non-blocking
//                                   (LiteRT / Vision retain + dispatch to their
//                                   own serial queue, or swap a pending slot).
//   latestMaskRetained            — render loop snapshot (main) — any thread is safe.
//   diagnosticsSnapshot           — any thread.
//   All lifecycle/matte state is guarded by one os_unfair_lock; the provider
//   call in submitFrame runs under that lock so invalidate can never race a
//   provider that is mid-submit. Diagnostic aggregates live under a second,
//   independent os_unfair_lock fed from the provider's serial queue
//   (VGLiteRTMaskProvider.onTimingSample / VGLiveGreenScreenVisionMaskProvider
//   .onTimingSample — same sample struct); lock order is lifecycle → diag,
//   never the reverse.

#pragma once
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CMTime.h>
#import "VGFaceNeckBeautyMaskPolicy.h"

NS_ASSUME_NONNULL_BEGIN

/// Which mask source the adapter settled on (readable for log markers).
typedef NS_ENUM(NSInteger, VGLiveGreenScreenMaskProviderKind) {
    /// start() called; asynchronous provider setup has not completed yet.
    VGLiveGreenScreenMaskProviderKindPending = 0,
    /// VGLiteRTMaskProvider is active: with VGLiveGreenScreenPersonMattePolicy
    /// for backend "litert", or on the direct person-confidence path for the
    /// diagnostic-only backend "litertSelfie" (see diagnosticsSnapshot
    /// providerMode / mattePath to tell them apart).
    VGLiveGreenScreenMaskProviderKindLiteRT = 1,
    /// LiteRT was unavailable; VGHeuristicMaskProvider (face-region matte) is active.
    VGLiveGreenScreenMaskProviderKindHeuristicFallback = 2,
    /// No provider could be created; onProviderUnavailable was fired.
    VGLiveGreenScreenMaskProviderKindUnavailable = 3,
    /// VGLiveGreenScreenVisionMaskProvider (Apple Vision person segmentation:
    /// iOS production default backend "visionFast", or diagnostic-only "visionBalanced" / "visionAccurate") is active.
    VGLiveGreenScreenMaskProviderKindVision = 4,
};

// ─── Segmentation backend selectors ──────────────────────────────────────────
// Exact strings accepted by initWithFastMetalPrecision:segmentationBackend: and
// by the setLiveGreenScreenDiagnosticsOptions `iosSegmentationBackend` wire key.

/// Selectable alternate: VGLiteRTMaskProvider + VGLiveGreenScreenPersonMattePolicy
/// (heuristic fallback when LiteRT is not ready). Value: "litert".
FOUNDATION_EXPORT NSString * const VGLiveGreenScreenSegmentationBackendLiteRT;
/// iOS production default: VGLiveGreenScreenVisionMaskProvider, quality fast. Value: "visionFast".
FOUNDATION_EXPORT NSString * const VGLiveGreenScreenSegmentationBackendVisionFast;
/// VGLiveGreenScreenVisionMaskProvider, quality balanced (diagnostic comparison backend). Value: "visionBalanced".
FOUNDATION_EXPORT NSString * const VGLiveGreenScreenSegmentationBackendVisionBalanced;
/// VGLiveGreenScreenVisionMaskProvider, quality accurate (Vision's full-
/// resolution, slowest level; diagnostic comparison backend). Value: "visionAccurate".
FOUNDATION_EXPORT NSString * const VGLiveGreenScreenSegmentationBackendVisionAccurate;
/// VGLiteRTMaskProvider on selfie_segmentation_landscape.tflite (the Android
/// production MediaPipe CPU model): aspect-fit input geometry, direct
/// single-channel person-confidence matte at the model output aspect, no
/// policy, no temporal smoothing, no heuristic fallback (diagnostic
/// measurement only). Value: "litertSelfie".
FOUNDATION_EXPORT NSString * const VGLiveGreenScreenSegmentationBackendLiteRTSelfie;

// ─── VGLiveGreenScreenPersonMattePolicy ──────────────────────────────────────

/// Full-person matte policy for MediaPipe Selfie Multiclass output.
///
/// Injected into VGLiteRTMaskProvider through its `policy:` initializer in
/// place of the default face+neck beauty policy (which deliberately keys only
/// face/neck skin and would drop hair, body, and clothes from a green-screen
/// matte). Per model pixel: subject = 1 − P(background), smoothed with a
/// motion-adaptive temporal EMA at model resolution, then bilinearly resampled
/// to the camera frame's aspect ratio (short side = 256) and remapped through
/// a soft edge band [edgeLow, edgeHigh] into 0…255.
///
/// VGSkinMask.faceCount is used as a validity flag by the adapter:
/// 1 = valid person matte (may legitimately be all background), 0 = invalid.
///
/// Threading: same contract as the base class — call processTensor:… and
/// resetTemporalState only from one serial queue (the provider's ML queue).
@interface VGLiveGreenScreenPersonMattePolicy : VGFaceNeckBeautyMaskPolicy

/// Subject probability at or below this maps to 0 (background). Default 0.35.
@property (nonatomic) float edgeLow;

/// Subject probability at or above this maps to 255 (subject). Default 0.65.
@property (nonatomic) float edgeHigh;

/// Temporal EMA weight of the new frame when the scene is still. Rises toward
/// 1.0 (no smoothing) as inter-frame motion grows. Default 0.5.
@property (nonatomic) float baseTemporalAlpha;

- (instancetype)init NS_DESIGNATED_INITIALIZER;

@end

// ─── VGLiveGreenScreenMaskProviderAdapter ────────────────────────────────────

@interface VGLiveGreenScreenMaskProviderAdapter : NSObject

/// Fired once on the main thread if no mask provider could be created at all.
/// Cleared by invalidate. Never fires for the heuristic-fallback case.
///
/// The argument is the adapter's `diagnosticsSnapshot` taken at the moment of
/// the failure (providerKind "unavailable", `failureReason` set to the exact
/// setup failure, plus the requested `segmentationBackend`, sampleCount,
/// maskPublishCount, …). The owner is expected to invalidate the adapter from
/// this callback, so the snapshot is the last chance to preserve WHY the
/// provider failed before the adapter is released.
@property (nonatomic, copy, nullable) void (^onProviderUnavailable)(NSDictionary<NSString *, id> *diagnostics);

/// Terminal provider setup failure reason, or nil while no failure exists.
/// Set exactly once (before providerKind becomes Unavailable and before
/// onProviderUnavailable fires) and never cleared, including by invalidate,
/// so the owner can still read it from a released adapter. Values are the
/// stable reason strings logged by IOS_LIVE_GREENSCREEN_MASK_PROVIDER_UNAVAILABLE
/// (for example "model_asset_missing", "vision_person_segmentation_unavailable",
/// "unknown_segmentation_backend(...)"). The heuristic-fallback case is NOT a
/// failure and leaves this nil (its reason is only logged as
/// IOS_LIVE_GREENSCREEN_MASK_PROVIDER_FALLBACK).
@property (atomic, readonly, copy, nullable) NSString *failureReason;

/// Selected mask source. Pending until asynchronous setup completes.
@property (atomic, readonly) VGLiveGreenScreenMaskProviderKind providerKind;

/// RND / diagnostic toggle for the LiteRT Metal delegate precision, fixed at
/// init and forwarded by start() to VGLiteRTMaskProvider metalAllowPrecisionLoss
/// (TFLGpuDelegateOptions.allow_precision_loss). NO — the default and what the
/// plain `init` produces — is full float32 precision, the unchanged production
/// behaviour. YES is "fast Metal": the delegate may compute in float16. No
/// effect on the heuristic fallback, on simulator builds, or on a Vision
/// backend (the request is still echoed by diagnostics; never applied).
@property (atomic, readonly) BOOL fastMetalPrecision;

/// Requested segmentation backend, fixed at init: one of the
/// VGLiveGreenScreenSegmentationBackend* constants ("visionFast" for `init` /
/// `initWithFastMetalPrecision:`). Echoed by diagnosticsSnapshot as
/// `segmentationBackend`; the provider actually running is `providerKind`.
@property (atomic, readonly, copy) NSString *segmentationBackend;

/// Default staleness bound used by callers that do not pick their own.
@property (class, nonatomic, readonly) NSTimeInterval defaultMaxMaskAgeSeconds;

/// Production initializer: backend "visionFast", fastMetalPrecision = NO (full
/// float32 precision).
- (instancetype)init;

/// Backend "visionFast" with the Metal precision option.
///
/// @param fastMetalPrecision  YES opts into the Metal delegate's allow_precision_loss
///                            ("fast Metal") when a LiteRT backend is active; NO is
///                            the float32 path. Ignored for Vision backends.
- (instancetype)initWithFastMetalPrecision:(BOOL)fastMetalPrecision;

/// Designated initializer (backend selection).
///
/// @param fastMetalPrecision   As above. Ignored (but echoed) for Vision backends.
/// @param segmentationBackend  Exactly one of VGLiveGreenScreenSegmentationBackendVisionFast
///                             ("visionFast", production default), …LiteRT ("litert",
///                             selectable alternate), …VisionBalanced ("visionBalanced"),
///                             …VisionAccurate ("visionAccurate"), or
///                             …LiteRTSelfie ("litertSelfie"). Any other
///                             string resolves to providerKind = Unavailable at
///                             start() (reason unknown_segmentation_backend);
///                             callers validate before reaching this class.
- (instancetype)initWithFastMetalPrecision:(BOOL)fastMetalPrecision
                       segmentationBackend:(NSString *)segmentationBackend NS_DESIGNATED_INITIALIZER;

/// Begin asynchronous provider setup. Idempotent; no-op after invalidate.
/// Never blocks on model load: frames submitted before setup completes are
/// dropped and latestMaskRetained returns NULL until the first matte lands.
- (void)start;

/// Terminal and idempotent. Stops accepting frames, invalidates the active
/// provider(s), releases the cached matte buffer and pool, clears the callback.
- (void)invalidate;

/// Submit one camera frame for segmentation. Non-blocking. No-op unless the
/// adapter is active and a provider has been selected. Does not retain the
/// buffer beyond the provider's own retain.
- (void)submitFrame:(CVPixelBufferRef)pixelBuffer presentationTime:(CMTime)pts;

/// Returns a +1 retained OneComponent8 matte (255 = subject) or NULL when no
/// fresh, valid matte is available. The caller MUST release the result.
/// Equivalent to latestMaskRetainedWithMaxAgeSeconds:sourcePTSOut: with NULL.
- (nullable CVPixelBufferRef)latestMaskRetainedWithMaxAgeSeconds:(NSTimeInterval)maxAgeSeconds
    CF_RETURNS_RETAINED NS_SWIFT_NAME(latestMaskRetained(maxAgeSeconds:));

/// Same contract and staleness rule as latestMaskRetainedWithMaxAgeSeconds:,
/// additionally reporting the source PTS of the returned matte.
///
/// @param maxAgeSeconds  Staleness bound (see header).
/// @param sourcePTSOut   Optional. Written ONLY when a retained buffer is
///                       returned: the camera presentation timestamp of the
///                       frame the matte was computed from (may be non-numeric
///                       if the provider had no PTS). Untouched on NULL return.
- (nullable CVPixelBufferRef)latestMaskRetainedWithMaxAgeSeconds:(NSTimeInterval)maxAgeSeconds
                                                    sourcePTSOut:(nullable CMTime *)sourcePTSOut
    CF_RETURNS_RETAINED NS_SWIFT_NAME(latestMaskRetained(maxAgeSeconds:sourcePTSOut:));

/// Diagnostic-only snapshot of matte latency and publication telemetry,
/// aggregated over the whole session so far. Safe from any thread; cheap
/// (no allocation beyond the returned dictionary). Values are NSNumber or
/// NSString; durations are milliseconds; -1 means "no data yet".
///
/// Keys:
///   providerKind            "pending" | "litert" | "vision" | "heuristic_fallback" | "unavailable"
///   providerMode            providerKind refined by the attached inference backend:
///                           "litert_metal_fp32" | "litert_metal_fp16" |
///                           "litert_cpu_simulator" | "litert_selfie_metal_fp32" |
///                           "litert_selfie_metal_fp16" | "litert_selfie_cpu_simulator" |
///                           "vision_fast" | "vision_balanced" |
///                           "vision_accurate" | "heuristic_fallback" | "unavailable" | "pending"
///   segmentationBackend     NSString — the requested backend fixed at init:
///                           "litert" | "visionFast" | "visionBalanced" | "visionAccurate" | "litertSelfie"
///   failureReason           NSString — terminal provider setup failure reason
///                           (see the `failureReason` property), "none" while no
///                           failure exists. Present in every state, including
///                           after invalidate.
///   modelName               NSString — asset base name of the running LiteRT model
///                           ("selfie_multiclass_256x256" | "selfie_segmentation_landscape"),
///                           "none" for every other kind
///   mattePath               NSString — VGLiteRTMaskProvider.mattePath of the running
///                           LiteRT provider ("multiclass_policy" | "person_confidence_direct"),
///                           "none" otherwise
///   inputGeometry           NSString — "stretch" | "aspectFit" (LiteRT), "none" otherwise
///   modelInputWidth/modelInputHeight/modelInputChannels
///   modelOutputWidth/modelOutputHeight/modelOutputChannels
///                           tensor contract of the running LiteRT model (0 otherwise)
///   timingSemantics         what the per-frame span keys below measure:
///                           "litert_tflite_spans"  — inputCopy = TfLiteTensorCopyFromBuffer,
///                                                    invoke = TfLiteInterpreterInvoke,
///                                                    outputAccess = TfLiteTensorData,
///                                                    policy = VGLiveGreenScreenPersonMattePolicy
///                           "vision_request_spans" — inputCopy = 0 (none),
///                                                    invoke = VNImageRequestHandler performRequests:,
///                                                    outputAccess = observation / pixel-buffer lookup,
///                                                    policy = OneComponent8 row copy into VGSkinMask
///                           "none"                 — heuristic / unavailable / pending (no samples)
///   fastMetalPrecision      BOOL — this adapter's fastMetalPrecision init option
///                           (the requested "fast Metal" mode) as captured by start();
///                           echoed for every backend, applied only to LiteRT
///   metalAllowPrecisionLossRequested  BOOL — same value as fastMetalPrecision,
///                           under the provider-side option name
///   metalAllowPrecisionLoss BOOL — precision option of the LiteRT provider
///                           actually running (NO unless providerKind == litert
///                           and the request was honoured; always NO for Vision)
///   active                  BOOL — start() ran and invalidate() has not
///   providerSetupMs         provider selection/build time (-1 until selected)
///   sampleCount             per-frame timing samples received (LiteRT or Vision)
///   avgTotalMs/maxTotalMs/minTotalMs       end-to-end provider-queue time per frame
///   avgInferenceMs/maxInferenceMs/minInferenceMs   inputCopy + invoke (legacy combined span)
///   avgInputCopyMs/maxInputCopyMs/minInputCopyMs   TfLiteTensorCopyFromBuffer (0 for Vision)
///   avgInvokeMs/maxInvokeMs/minInvokeMs            TfLiteInterpreterInvoke | Vision perform
///   avgOutputAccessMs/maxOutputAccessMs/minOutputAccessMs
///                           output tensor pointer access (GPU → host readback lands here)
///                           | Vision observation lookup
///   avgPolicyMs             matte-build policy | Vision mask copy
///   avgPreMs / avgPostMs    preprocessing / (output access + policy)
///   avgCadenceMs/maxCadenceMs/cadenceSampleCount   publish-to-publish gap (positive only)
///   firstTotalMs/lastTotalMs/lastInferenceMs/lastCadenceMs
///   lastInputCopyMs/lastInvokeMs/lastOutputAccessMs
///   lastPtsSeconds/lastFrameIndex
///   firstPublishLatencyMs   start() → first provider publish (provider queue)
///   firstMaskLatencyMs      start() → first valid matte cached for the compositor
///   maskPublishCount        valid mattes copied into the pooled cache
///   lastMaskCoveragePercent subject coverage of the last cached matte (0…100)
///   lastMaskWidth/lastMaskHeight
- (NSDictionary<NSString *, id> *)diagnosticsSnapshot;

@end

NS_ASSUME_NONNULL_END
