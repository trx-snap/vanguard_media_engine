// VGGreenScreenFilterNode.h
// vanguard_media_engine — UMF camera graph green screen (iOS-first MVP)
//
// Live green-screen filter node for the active UMF camera graph.
//
// What this node is:
//   A plain graph transform node (input CVPixelBuffer → output CVPixelBuffer)
//   that keys the incoming camera frame over an opaque solid background colour
//   using a per-frame person matte. It is inserted into the camera graph by
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
//   • Not an orientation authority. Frames arrive already oriented/mirrored by
//     the camera source; no rotation or mirroring is applied here and the matte
//     is computed on the frame exactly as received.
//
// MVP / proof scope (read before quoting results):
//   • Background: solid colour only (`backgroundType` = "solidColor", `argb`).
//     The alpha byte of `argb` is ignored — the background is always opaque.
//   • Matte: Apple Vision person segmentation, quality level FAST, evaluated
//     SYNCHRONOUSLY inside processBuffer:atTime:device: on the graph execution
//     queue (stateless: a fresh VNGeneratePersonSegmentationRequest and
//     VNImageRequestHandler per frame, nothing retained between frames). The
//     raw OneComponent8 mask is bilinearly scaled to the frame extent.
//   • Edge refinement: S1 PRESENT. The scaled matte runs through the proven
//     production S1 refinement pipeline of VGDuetPreviewCompositor (same stage
//     order, same constants, ported as private CoreImage recipes; no Duet
//     import): morphology close (CIMorphologyMaximum→Minimum, r 1.0) → feather
//     (CIGaussianBlur r 4.0) → trimap smoothstep(0.10, 0.90) → guided edge
//     preserve (CIEdges 2.0 → blur 1.5 → smoothstep(0.08, 0.34) on the camera
//     frame, restoring the feathered mask over the trimapped one where the
//     frame has strong edges) → CIBlendWithMask. Every stage fails open to its
//     input mask and the frame log AND -diagnosticsSnapshot report
//     morphologyCloseApplied / featherApplied / trimapApplied /
//     guidedEdgeApplied. S4/S5/tightAlphaR1 lab candidates are NOT ported.
//   • Non-claims (still true after S1): NO temporal smoothing; NO image or
//     video backgrounds; NO Duet proof (this node is not on the Duet path);
//     NO recording/export/photo proof of the keyed output beyond the graph
//     topology argument above; NO TikTok-grade matte parity. S1 improves edge
//     quality over the raw FAST matte; it does not prove parity — do not
//     present it as such.
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
//   mask format, CIImage wrap failure, CIBlendWithMask unavailable/nil output,
//   pool exhaustion, pool/frame dimension mismatch, or post-invalidate — returns
//   the INPUT buffer (+1 retained) so the preview shows the unkeyed camera
//   instead of a dropped or corrupted frame. Failures are logged with throttling.
//
// Colour management:
//   Mirrors the proven live green-screen paths (VGDuetPreviewCompositor,
//   VGARKitLiveGreenScreenPreviewCoordinator, VGLiveGreenScreenStaticBackground
//   Renderer): the CIContext has NO working colour space and rendering passes a
//   NULL output colour space, so foreground pixels are copied byte-identical
//   where the matte is 255 and the solid colour is written with its raw sRGB
//   component values.
//
// CIBlendWithMask parameter mapping (same as the proven paths above):
//   inputImage           = camera frame (foreground)
//   inputBackgroundImage = solid colour (background)
//   inputMaskImage       = person matte, 255/white = subject → foreground shown
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
//   node's fixed configuration and what it has done so far: frame, processed
//   and fail-open counts, the last fail-open reason, and — for the last
//   successfully keyed frame — the source/matte dimensions, the four S1 stage
//   flags, and last/mean/max Vision, blend-render and total latency in ms.
//   The counters are written on the graph execution queue and read under a
//   tiny os_unfair_lock (plain scalar copies only; no allocation while the
//   lock is held), so a snapshot may be taken from any thread. The camera
//   graph exposes it through VGCameraGraphSession -greenScreenDiagnosticsSnapshot,
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

/// The only `backgroundType` accepted by this slice. Value: @"solidColor".
FOUNDATION_EXPORT NSString * const VGGreenScreenFilterNodeBackgroundTypeSolidColor;

/// Which matte source the node settled on at init (fixed for its lifetime).
typedef NS_ENUM(NSInteger, VGGreenScreenFilterNodeMatteSource) {
    /// Apple Vision person segmentation, quality FAST, synchronous per frame.
    VGGreenScreenFilterNodeMatteSourceVisionPersonFast = 0,
    /// VNGeneratePersonSegmentationRequest unavailable (iOS < 15). Every frame
    /// passes through unchanged; no keying is performed.
    VGGreenScreenFilterNodeMatteSourceUnavailable = 1,
};

/// Solid-background green-screen filter node for the UMF camera graph (MVP).
///
/// Designated initialiser is `-initWithPool:device:backgroundARGB:`.
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

/// Background colour as 0xAARRGGBB. The alpha byte is ignored (always opaque).
@property (nonatomic, readonly) uint32_t backgroundARGB;

/// Matte source selected at init. See VGGreenScreenFilterNodeMatteSource.
@property (nonatomic, readonly) VGGreenScreenFilterNodeMatteSource matteSource;

// ─── Designated initialiser ───────────────────────────────────────────────────

/// Designated initialiser. Never returns nil.
///
/// @param pool            Session-owned CVPixelBufferPool (BGRA, camera
///                        dimensions). Retained (+1) by the node. May be NULL
///                        for unit tests; then every frame passes through
///                        (the camera graph always supplies a pool — see
///                        VGCameraGraphSession pass-1 resource contract).
/// @param device          The shared MTLDevice backing the CIContext.
/// @param backgroundARGB  Solid background colour as 0xAARRGGBB (alpha ignored).
- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
              backgroundARGB:(uint32_t)backgroundARGB NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

// ─── Diagnostics (read-only native telemetry) ────────────────────────────────

/// Thread-safe, read-only telemetry snapshot. Never returns nil. See the
/// "Diagnostics / native telemetry" header comment for the contract. Keys:
///   nodeId, filterName, enabled (BOOL)
///   matteSource                  "visionPersonFast" | "unavailable"
///   proofLevel, edgeRefinement   both "S1"
///   backgroundARGB               NSNumber, the 0xAARRGGBB given at init
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
