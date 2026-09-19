// VGGreenScreenFilterNode.h
// vanguard_media_engine — UMF camera graph green screen (iOS-first MVP)
//
// Live green-screen filter node for the active UMF camera graph.
//
// What this node is:
//   A plain graph transform node (input CVPixelBuffer → output CVPixelBuffer)
//   that keys the incoming camera frame with a per-frame person matte and
//   emits the keyed frame in one of two output modes fixed at init:
//     • solidColor — the subject composited over an opaque solid background
//       colour (the original MVP behaviour; pixel output unchanged).
//     • alpha      — the camera foreground RGB with the refined matte written
//       to the output alpha channel (32BGRA, straight alpha, NO background
//       composite). This is the independent 1-in/1-out "keyed stream" a
//       downstream multi-input compositor (for example a Duet compositor
//       node) blends over its own background. The node never composites two
//       streams itself and never learns what consumes its output.
//   It is inserted into the camera graph by
//   VGCameraGraphSession.setCameraFilterChainFromSpecs: for spec type
//   "greenScreen" and is wrapped by VGCameraGraphFactory exactly like every
//   other VGMetalFilterNode (VGLegacyFilterAdapter). Recording sink, photo sink,
//   platform-view fan-out and the renderer sink all receive the keyed frame
//   because they sit downstream of the filter chain.
//
// What this node is NOT:
//   • Not a camera owner. It never starts, stops, switches or configures the
//     AVCaptureSession, never registers a Flutter texture and owns no ARSession.
//   • Not Duet-owned and not Duet-specific. It has no Duet imports and no Duet
//     parameters; it is callable from any camera-graph surface.
//   • Not a compositor. In alpha mode it hands the keyed stream downstream; it
//     does not know or care what the alpha is blended over.
//   • Not an orientation authority. Frames arrive already oriented/mirrored by
//     the camera source; no rotation or mirroring is applied here and the matte
//     is computed on the frame exactly as received.
//
// MVP / proof scope (read before quoting results):
//   • Output modes (spec `backgroundType`, see VGGreenScreenFilterNodeOutputMode):
//       "solidColor" + `argb` — subject over an opaque solid colour. The alpha
//                               byte of `argb` is ignored; output alpha is 255.
//       "alpha"               — foreground RGB + refined matte in alpha. `argb`
//                               is not part of the contract and is ignored if
//                               present (reported as 0). No image or video
//                               backgrounds in either mode.
//   • Alpha encoding (alpha mode): STRAIGHT (un-premultiplied). A is the
//     refined matte (255 = subject, 0 = background, feather in between); RGB
//     is the camera pixel wherever A > 0. Fully transparent pixels (A = 0)
//     carry RGB = 0 (Core Image un-premultiplies a transparent working pixel
//     to zero), which a straight-alpha source-over, C = C_fg·A + C_bg·(1−A),
//     never reads. Feeding this buffer to a premultiplied-alpha compositor —
//     including the Flutter Texture preview — misreads it, so preview
//     appearance in alpha mode proves nothing about keying. The encoding is
//     produced by a dedicated CIContext with kCIContextOutputPremultiplied =
//     NO (see "Alpha output construction" below) and VERIFIED ONCE at init,
//     on a synthetic input, by the alpha byte self-test (see "Alpha byte
//     self-test" below and `alphaByteSelfTestPassed`). -diagnosticsSnapshot
//     `alphaEncoding` reports "straight" ONLY when that self-test passed;
//     otherwise "unverified". Live camera frame bytes are not measured.
//   • Matte: Apple Vision person segmentation, quality level FAST, evaluated
//     SYNCHRONOUSLY inside processBuffer:atTime:device: on the graph execution
//     queue (stateless: a fresh VNGeneratePersonSegmentationRequest and
//     VNImageRequestHandler per frame, nothing retained between frames). The
//     raw OneComponent8 mask is bilinearly scaled to the frame extent.
//   • Edge refinement: S1 PRESENT in both output modes. The scaled matte runs
//     through the proven production S1 refinement pipeline of
//     VGDuetPreviewCompositor (same stage order, same constants, ported as
//     private CoreImage recipes; no Duet import): morphology close
//     (CIMorphologyMaximum→Minimum, r 1.0) → feather (CIGaussianBlur r 4.0) →
//     trimap smoothstep(0.10, 0.90) → guided edge preserve (CIEdges 2.0 → blur
//     1.5 → smoothstep(0.08, 0.34) on the camera frame, restoring the feathered
//     mask over the trimapped one where the frame has strong edges) → output
//     stage (CIBlendWithMask over the solid colour, or the straight-alpha
//     construction). Every stage fails open to its input mask and the frame
//     log AND -diagnosticsSnapshot report morphologyCloseApplied /
//     featherApplied / trimapApplied / guidedEdgeApplied. S4/S5/tightAlphaR1
//     lab candidates are NOT ported.
//   • Non-claims (still true after S1 and alpha mode): NO temporal smoothing;
//     NO image or video backgrounds; NO Duet proof (this node is not on the
//     Duet path and nothing consumes its alpha yet); NO recording/export/photo
//     proof of the keyed output beyond the graph topology argument above; NO
//     TikTok-grade matte parity; NO byte-level proof of the alpha encoding on
//     LIVE camera frames (the one-time synthetic self-test at init proves the
//     construction on a synthetic input only). S1 improves edge quality over
//     the raw FAST matte; it does not prove parity — do not present it as such.
//   • Latency: the synchronous Vision call is charged to the graph execution
//     queue. VGCameraGraphSession's drop-latest backpressure keeps the queue
//     from backing up, so a slow frame lowers preview frame rate rather than
//     accumulating lag. estimatedGPUCostMs is a deliberate overestimate.
//
// Matte source availability:
//   VNGeneratePersonSegmentationRequest requires iOS 15. On earlier systems
//   the node still constructs (so filter-chain validation stays atomic and
//   deterministic) but `matteSource` is Unavailable and every frame is passed
//   through unchanged. This is logged once with a PROOF_UNAVAILABLE marker.
//
// Fail-open contract (matches the other CIImage-based filter nodes):
//   Any per-frame failure — Vision request error, no observation, unexpected
//   mask format, CIImage wrap failure, CIBlendWithMask / CIColorMatrix
//   unavailable or nil output, straight-alpha CIContext unavailable (alpha
//   mode, reason "alpha_straight_context_unavailable"), pool exhaustion,
//   pool/frame dimension mismatch, or post-invalidate — returns the INPUT
//   buffer (+1 retained) so the preview
//   shows the unkeyed camera instead of a dropped or corrupted frame. Failures
//   are logged with throttling and counted in failOpenCount. Identical in
//   both output modes.
//
// Colour management:
//   Mirrors the proven live green-screen paths (VGDuetPreviewCompositor,
//   VGARKitLiveGreenScreenPreviewCoordinator, VGLiveGreenScreenStaticBackground
//   Renderer): the CIContext has NO working colour space and rendering passes a
//   NULL output colour space, so foreground pixels are copied byte-identical
//   where the matte is 255 and the solid colour is written with its raw sRGB
//   component values. Alpha mode renders through a second context with the
//   same options plus kCIContextOutputPremultiplied = NO and the same NULL
//   colour space; solidColor keeps the shared context unchanged.
//
// CIBlendWithMask parameter mapping (same as the proven paths above):
//   solidColor mode:
//     inputImage           = camera frame (foreground)
//     inputBackgroundImage = solid colour (background)
//     inputMaskImage       = person matte, 255/white = subject → foreground shown
//   alpha mode ("Alpha output construction"):
//     inputImage           = camera frame (foreground, alpha 1)
//     inputBackgroundImage = the SAME camera frame with alpha forced to 0 by
//                            CIColorMatrix (RGB untouched)
//     inputMaskImage       = refined person matte m
//     CIBlendWithMask is a per-component mix, so the result is
//     (fg.rgb·m + fg.rgb·(1−m), 1·m + 0·(1−m)) = (fg.rgb, m) in straight
//     terms. Core Image's WORKING representation is premultiplied, however
//     (CIColorMatrix re-premultiplies after zeroing alpha), so the working
//     value is (fg.rgb·m, m); rendered through the shared context (default
//     kCIContextOutputPremultiplied = YES) the bytes measured on device were
//     premultiplied — edge (100,64,24,128) for a (200,128,48) foreground at
//     m = 128. Alpha mode therefore renders through a dedicated context with
//     kCIContextOutputPremultiplied = NO, which un-premultiplies on output and
//     writes (fg.rgb, m) wherever m > 0 (≤ 1 LSB half-float rounding inside
//     the feather band) and (0,0,0,0) where m = 0. If that context cannot be
//     created, alpha frames fail open ("alpha_straight_context_unavailable")
//     rather than emitting premultiplied bytes, and the alpha byte self-test
//     below reports the same condition. Live frame bytes are not measured;
//     the physical harness asserts telemetry (including the self-test result)
//     only.
//
// Alpha byte self-test (alpha mode only; ONCE inside the designated
// initialiser, before any frame):
//   Deterministic byte-level proof of the construction above. A 48×16
//   synthetic opaque foreground (every pixel R=200 G=128 B=48) and a 48×16
//   OneComponent8 matte in three vertical bands (0 | 128 | 255 = background |
//   edge | foreground) go through the SAME _VGGSFNStraightAlphaKeyedImage
//   helper and the SAME un-premultiplied render call (NULL colour space) as
//   the alpha frame path, into a zero-filled 32BGRA CVPixelBuffer whose band
//   centres are then read back on the CPU. Pass requires A ≤ 2 in the
//   background band, A ≥ 253 with RGB == (200,128,48) ± 2 in the foreground
//   band, and 16 ≤ A ≤ 239 with RGB == (200,128,48) ± 2 in the edge band. A
//   premultiplied output halves the edge RGB, so that check is the decisive
//   straight-vs-premultiplied evidence; background RGB is reported but not
//   evaluated (un-premultiplying a transparent pixel yields 0). The result is
//   immutable for the node's lifetime (alphaByteSelfTestPassed /
//   alphaByteSelfTestReason / alphaByteSelfTestWidth / alphaByteSelfTestHeight,
//   also in -diagnosticsSnapshot) and is logged once with
//   IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_ALPHA_BYTE_SELF_TEST. A failed
//   self-test does not stop the alpha path (frames still render through the
//   same call) but `alphaEncoding` reports "unverified" instead of "straight"
//   and the harness fails on the telemetry. solidColor mode does not run it and
//   reports NO / "not_applicable" / 0×0. The self-test allocates three tiny
//   buffers that are released before init returns; it touches no pool, no
//   camera state and no telemetry lock, and it does not depend on Vision.
//
// Buffer ownership (DEC-44 / RR-28, same as VGROIEntropySuppressionFilterNode):
//   • The pool passed at init is CFRetained (+1) by the node and released in
//     dealloc, so an in-flight frame can never observe a released pool during a
//     session teardown race.
//   • processBuffer:atTime:device: returns a +1 CVPixelBuffer owned by the
//     caller. Passthrough returns the input with an extra +1 retain.
//   • processEnvelope:device: takes/returns VGFrameEnvelope by value; it never
//     releases envelope.payload.videoBuffer (runtime-owned).
//   • The input buffer is never retained beyond the duration of the call: the
//     VNImageRequestHandler that references it is a local of that call.
//
// Threading:
//   processBuffer:atTime:device: is stateless per frame — apart from the
//   lock-guarded telemetry counters described below — and may be called from
//   any serial graph queue. invalidate is terminal, idempotent, lock-free,
//   allocation-free and safe from any thread; after it every frame passes
//   through. Nothing asynchronous is ever in flight, so there is nothing to
//   cancel or wait for.
//
// Diagnostics / native telemetry (read-only, thread-safe):
//   -diagnosticsSnapshot returns a fresh immutable dictionary describing the
//   node's fixed configuration (including outputMode / backgroundType /
//   alphaEncoding and the alpha byte self-test result) and what it has done
//   so far: frame, processed and fail-open
//   counts, the last fail-open reason, and — for the last successfully keyed
//   frame — the source/matte dimensions, the four S1 stage flags, and
//   last/mean/max Vision, blend-render and total latency in ms. The counters
//   are written on the graph execution queue and read under a tiny
//   os_unfair_lock (plain scalar copies only; no allocation while the lock is
//   held), so a snapshot may be taken from any thread. The camera graph
//   exposes it through VGCameraGraphSession -greenScreenDiagnosticsSnapshot,
//   which reads it on the session queue. Taking a snapshot never changes node
//   behaviour, never touches buffers or the pool, and allocates only the
//   returned dictionary; the per-frame path allocates nothing for telemetry.
//   processedFrameCount and the latency statistics cover successfully
//   keyed/rendered frames only — fail-open frames are counted separately in
//   failOpenCount and never contribute to the latency averages.
//
// Implementation note:
//   The @implementation lives in VGCameraGraphSession.m (see the comment-only
//   VGGreenScreenFilterNode.m) so the class compiles without a Pods project
//   regeneration — the same precedent as VGOfflineFilterBundle and
//   VGStillImageFilterFactory.

#pragma once

#import "VanguardFilterNode.h"
#import <UMF/VGMetalFilterNode.h>
#import <UMF/VGFrameEnvelope.h>
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Spec `backgroundType` selecting solid-colour output. Value: @"solidColor".
/// Requires `parameters.argb`.
FOUNDATION_EXPORT NSString * const VGGreenScreenFilterNodeBackgroundTypeSolidColor;

/// Spec `backgroundType` selecting alpha output. Value: @"alpha".
/// `parameters.argb` is not part of the contract and is ignored if present.
FOUNDATION_EXPORT NSString * const VGGreenScreenFilterNodeBackgroundTypeAlpha;

/// Which matte source the node settled on at init (fixed for its lifetime).
typedef NS_ENUM(NSInteger, VGGreenScreenFilterNodeMatteSource) {
    /// Apple Vision person segmentation, quality FAST, synchronous per frame.
    VGGreenScreenFilterNodeMatteSourceVisionPersonFast = 0,
    /// VNGeneratePersonSegmentationRequest unavailable (iOS < 15). Every frame
    /// passes through unchanged; no keying is performed.
    VGGreenScreenFilterNodeMatteSourceUnavailable = 1,
};

/// Output mode of the node (fixed for its lifetime). Chosen by
/// VGCameraGraphSession from the spec's `backgroundType`.
typedef NS_ENUM(NSInteger, VGGreenScreenFilterNodeOutputMode) {
    /// Subject composited over an opaque solid colour (CIBlendWithMask).
    /// Output alpha is 255 everywhere; `backgroundARGB` is used.
    VGGreenScreenFilterNodeOutputModeSolidColor = 0,
    /// Foreground RGB preserved, refined matte written to the alpha channel
    /// (straight alpha, NOT premultiplied — see the header comment). No
    /// background composite; `backgroundARGB` is ignored and reported as 0.
    VGGreenScreenFilterNodeOutputModeAlpha = 1,
};

/// Green-screen filter node for the UMF camera graph (MVP): solid-colour or
/// straight-alpha keyed output.
///
/// Designated initialiser is `-initWithPool:device:outputMode:backgroundARGB:`.
@interface VGGreenScreenFilterNode : NSObject <VanguardFilterNode, VGMetalFilterNode>

// ─── VGMediaNode / VGMetalFilterNode required properties ──────────────────────

/// Stable node identifier (UUID string, set at init time).
@property (nonatomic, readonly, copy) NSString *nodeId;

/// Node type tag for logging. Value: @"VGGreenScreenFilterNode".
@property (nonatomic, readonly, copy) NSString *nodeType;

/// Human-readable name. Value: @"GreenScreen".
@property (nonatomic, readonly, copy) NSString *filterName;

/// When NO, returns the input unchanged (zero cost). Default: YES.
@property (nonatomic, assign) BOOL enabled;

/// YES — synchronous Vision inference per frame is the most expensive node in
/// the chain and is the first candidate for thermal shedding.
@property (nonatomic, readonly) BOOL isExpensive;

/// Conservative per-frame estimate (Vision FAST + S1 matte refinement +
/// CIBlendWithMask render at 1080p). Overestimate on purpose; the physical run
/// is the measurement.
@property (nonatomic, readonly) float estimatedGPUCostMs;

// ─── Node configuration (immutable after init) ────────────────────────────────

/// Output mode selected at init. See VGGreenScreenFilterNodeOutputMode.
@property (nonatomic, readonly) VGGreenScreenFilterNodeOutputMode outputMode;

/// Background colour as 0xAARRGGBB (solidColor mode). The alpha byte is
/// ignored (always opaque). Always 0 in alpha mode.
@property (nonatomic, readonly) uint32_t backgroundARGB;

/// Matte source selected at init. See VGGreenScreenFilterNodeMatteSource.
@property (nonatomic, readonly) VGGreenScreenFilterNodeMatteSource matteSource;

// ─── Alpha byte self-test result (immutable after init) ───────────────────────

/// YES when the one-time synthetic alpha byte self-test run inside init (alpha
/// mode only; see the "Alpha byte self-test" header comment) read back
/// straight-alpha bytes: background A ≈ 0, foreground A ≈ 255, edge
/// 0 < A < 255, foreground RGB preserved in the edge and foreground bands.
/// Gates `alphaEncoding` == "straight". Always NO in solidColor mode
/// (`alphaByteSelfTestReason` == "not_applicable").
@property (nonatomic, readonly) BOOL alphaByteSelfTestPassed;

/// "not_applicable" (solidColor) | "pass <samples>" | "fail:<codes> <samples>"
/// | an allocation/render failure code. <samples> lists the expected RGB and
/// the background/edge/foreground RGBA bytes actually read back.
@property (nonatomic, readonly, copy) NSString *alphaByteSelfTestReason;

/// Synthetic test image size (48×16 in alpha mode; 0×0 in solidColor mode).
@property (nonatomic, readonly) NSUInteger alphaByteSelfTestWidth;
@property (nonatomic, readonly) NSUInteger alphaByteSelfTestHeight;

// ─── Designated initialiser ───────────────────────────────────────────────────

/// Designated initialiser. Never returns nil.
///
/// @param pool            Session-owned CVPixelBufferPool (BGRA, camera
///                        dimensions). Retained (+1) by the node. May be NULL
///                        for unit tests; then every frame passes through
///                        (the camera graph always supplies a pool — see
///                        VGCameraGraphSession pass-1 resource contract).
/// @param device          The shared MTLDevice backing the CIContext.
/// @param outputMode      SolidColor or Alpha. Any other value is treated as
///                        SolidColor (never trapped: construction must stay
///                        deterministic for atomic filter-chain validation).
/// @param backgroundARGB  Solid background colour as 0xAARRGGBB (alpha byte
///                        ignored). Ignored — and stored as 0 — in alpha mode.
- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                  outputMode:(VGGreenScreenFilterNodeOutputMode)outputMode
              backgroundARGB:(uint32_t)backgroundARGB NS_DESIGNATED_INITIALIZER;

/// Convenience: the original solid-colour initialiser. Identical to the
/// designated initialiser with outputMode = SolidColor.
- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
              backgroundARGB:(uint32_t)backgroundARGB;

- (instancetype)init NS_UNAVAILABLE;

// ─── Diagnostics (read-only native telemetry) ────────────────────────────────

/// Thread-safe, read-only telemetry snapshot. Never returns nil. See the
/// "Diagnostics / native telemetry" header comment for the contract. Keys:
///   nodeId, filterName, enabled (BOOL)
///   matteSource                  "visionPersonFast" | "unavailable"
///   proofLevel, edgeRefinement   both "S1"
///   outputMode                   "solidColor" | "alpha"
///   backgroundType               the spec backgroundType the mode was built
///                                from: "solidColor" | "alpha"
///   alphaEncoding                "opaque" (solidColor: alpha is 255) |
///                                "straight" (alpha mode: RGB not premultiplied
///                                by A — reported ONLY when the self-test
///                                below passed through the alpha render path) |
///                                "unverified" (alpha mode: self-test failed;
///                                do not treat the bytes as straight)
///   alphaByteSelfTestPassed      BOOL — alpha mode: the one-time synthetic
///                                byte self-test at init read back straight
///                                alpha; solidColor: always NO
///   alphaByteSelfTestReason      "not_applicable" (solidColor) |
///                                "pass <samples>" | "fail:<codes> <samples>"
///                                | allocation/render failure code
///   alphaByteSelfTestWidth,
///   alphaByteSelfTestHeight      NSNumber, synthetic image size (48×16 in
///                                alpha mode; 0 in solidColor)
///   backgroundARGB               NSNumber, the 0xAARRGGBB given at init
///                                (always 0 in alpha mode)
///   frameCount                   frames that entered processing while enabled
///                                and not invalidated (counted before the
///                                matte-source / pool / dimension checks)
///   processedFrameCount          frames that completed the keyed render path
///   failOpenCount                fail-open events
///   lastFailOpenReason           "none" until the first fail-open
///   sourceWidth, sourceHeight, matteWidth, matteHeight   last keyed frame
///   morphologyCloseApplied, featherApplied, trimapApplied,
///   guidedEdgeApplied, allS1StagesApplied                last keyed frame
///   allS1StagesAppliedFrameCount keyed frames where all four stages applied
///   lastVisionMs, meanVisionMs, maxVisionMs
///   lastBlendRenderMs, meanBlendRenderMs, maxBlendRenderMs
///   lastTotalMs, meanTotalMs, maxTotalMs
///                                (means over processed frames; 0 when none)
- (NSDictionary<NSString *, id> *)diagnosticsSnapshot;

@end

NS_ASSUME_NONNULL_END
