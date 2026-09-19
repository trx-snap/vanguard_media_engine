// VGCameraGraphSession.m
// vanguard_media_engine — Phase 6A-2 / Phase 6A-3D-2 / Phase 6A-3G-C
//
// Implementation of VGCameraGraphSession.
// Phase 6A-3D-2 adds setCameraFilterChainFromSpecs:error: — Beauty V1 construction
// from Dart/plugin specs using the session-owned pool and Metal device.
//
// Phase 6A-3G-C: Async camera graph handoff.
// VGCameraGraphSession now acts as the renderer.frameDelegate (not _scheduler).
// Its didReceiveRawFrame: retains the incoming buffer, checks an atomic in-flight
// flag (drop-latest backpressure), and dispatches the real graph traversal
// asynchronously onto com.vanguard.cameraGraphExecution, returning immediately
// to the capture delegate queue.
//
// Ownership contract for the async path:
//   capture queue retains buffer (line ~461 in VanguardCameraMediaSource.m).
//   _onVideoFrame: passes frameToDeliver (+0 or +1 rotated) to us.
//   We call CVPixelBufferRetain to add our own +1 for the async block.
//   After we return, _onVideoFrame: releases its references (rawFrame + rotated).
//   Inside the async block: we call [scheduler didReceiveRawFrame:] which treats
//   the buffer as source-owned (does not release it). After the scheduler returns
//   we CVPixelBufferRelease our +1.
//
// Scheduler hot-swap safety:
//   The async block captures the *current* scheduler at enqueue time as a local
//   strong reference. Even if setCameraFilterChain: swaps _scheduler on the
//   session queue while a block is queued, the block executes against the
//   scheduler it was enqueued for — no stale-pointer risk.
//
// Thread safety of _graphInFlight:
//   _graphInFlight is _Atomic(BOOL). The in-flight check uses atomic_compare_
//   exchange_strong so concurrent calls from the serial capture queue are safe.
//
// UFM filter-chain timing (read-only diagnostics):
//   The async block brackets [scheduler didReceiveRawFrame:] with a monotonic
//   clock while a non-empty chain is committed, folding results into _fc*
//   aggregates owned by _graphExecutionQueue (read by
//   -filterChainDiagnosticsSnapshot). Cumulative graph/filter-chain cost, not
//   per-node cost.

#import "VGCameraGraphSession.h"
#import "VGUseCameraGraph.h"
#import "VGCameraGraphFactory.h"
#import "VGGraphSchedulerV2.h"
#import "VGFanOutSink.h"
#import "VGPlatformViewSinkAdapter.h"
#import "VGRecordingSinkNode.h"
#import "VGPhotoSinkNode.h"
#import "VanguardCameraMediaSource.h"
#import "VanguardMetalRenderer.h"
#import "VanguardBeautyFilterNode.h"
#import "BeautyV2FilterGroup.h"
#import "VGSegmentationNode.h"  // Phase 9B-5: segmentation auto-insertion before BeautyV2
#import "VGGreenScreenFilterNode.h"  // UMF camera graph green screen (spec type "greenScreen")
// [Beauty-Still]: VGOfflineFilterBundle and VGStillImageFilterFactory declarations
// are provided through VGCameraGraphSession.h (already imported above).
// Their @implementation blocks are inlined later in this file.
// VGGreenScreenFilterNode's @implementation is inlined here as well (its .m is
// comment-only) for the same Pods-project reason.

#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGFrameDelegate.h>
#import <UMF/VGResourceAllocator.h>
#import <UMF/VGNode.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGFrameEnvelope.h>
#import <stdatomic.h>
#import <time.h>                  // filter-chain timing: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
#import <os/lock.h>               // VGGreenScreenFilterNode: telemetry lock (os_unfair_lock)
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h>   // VGGreenScreenFilterNode: CIBlendWithMask composite
#import <Vision/Vision.h>         // VGGreenScreenFilterNode: person matte (iOS 15+)

// [Beauty-Still]: VGOfflineFilterBundle implementation inlined here so the class is compiled
// as part of VGCameraGraphSession.m without requiring a new Pods project source-file entry.
// The corresponding VGOfflineFilterBundle.m is intentionally empty.

@implementation VGOfflineFilterBundle {
    NSArray *_nodes;
    CVPixelBufferPoolRef _adoptedPool; // +1 owned; released in dealloc
}

@synthesize nodes = _nodes;

- (instancetype)initWithNodes:(NSArray *)nodes adoptedPool:(CVPixelBufferPoolRef)adoptedPool {
    NSParameterAssert(nodes != nil);
    NSParameterAssert(adoptedPool != NULL);
    self = [super init];
    if (!self) return nil;
    _nodes       = [nodes copy];
    _adoptedPool = adoptedPool; // Adopt: caller transferred +1; do NOT CVPixelBufferPoolRetain again.
    return self;
}

- (void)dealloc {
    if (_adoptedPool) {
        CVPixelBufferPoolRelease(_adoptedPool);
        _adoptedPool = NULL;
    }
}

@end

// ── VGStillImageFilterFactory pool helper (mirrors _VGBeautyCreatePool) ────────
static CVPixelBufferPoolRef _Nullable
_VGStillCreatePool(size_t width, size_t height) {
    NSDictionary *poolAttrs = @{(id)kCVPixelBufferPoolMinimumBufferCountKey: @2};
    NSDictionary *bufAttrs = @{
        (id)kCVPixelBufferWidthKey:               @(width),
        (id)kCVPixelBufferHeightKey:              @(height),
        (id)kCVPixelBufferPixelFormatTypeKey:     @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey:  @YES,
    };
    CVPixelBufferPoolRef pool = NULL;
    CVReturn status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        (__bridge CFDictionaryRef)poolAttrs,
        (__bridge CFDictionaryRef)bufAttrs,
        &pool);
    if (status != kCVReturnSuccess || !pool) return NULL;
    return pool; // +1 from Create — caller owns
}

// [Beauty-Still]: VGStillImageFilterFactory implementation inlined here.
// The corresponding VGStillImageFilterFactory.m is intentionally empty.

@implementation VGStillImageFilterFactory

+ (nullable VGOfflineFilterBundle *)createOfflineFilterBundleFromSpecs:(NSArray<NSDictionary *> *)specs
                                                                 width:(size_t)width
                                                                height:(size_t)height
                                                                device:(id<MTLDevice>)device
                                                                 error:(NSError * _Nullable * _Nullable)outError {
    if (outError) *outError = nil;

    if (!specs || specs.count == 0) {
        if (outError) *outError = [NSError errorWithDomain:@"VGStillImageFilterFactory" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"specs must not be empty"}];
        return nil;
    }
    if (!device) {
        if (outError) *outError = [NSError errorWithDomain:@"VGStillImageFilterFactory" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"MTLDevice must not be nil"}];
        return nil;
    }
    if (width == 0 || height == 0) {
        if (outError) *outError = [NSError errorWithDomain:@"VGStillImageFilterFactory" code:3
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"invalid dimensions %zux%zu", width, height]}];
        return nil;
    }

    // Pass 1: validate all specs before constructing anything.
    // Supported: type=="beauty" with faceAwareEnabled != true.
    // Rejected: any other type OR faceAwareEnabled==true.
    for (NSDictionary *spec in specs) {
        NSString *type = spec[@"type"];
        if (![type isKindOfClass:[NSString class]] || ![type isEqualToString:@"beauty"]) {
            NSString *badType = [type isKindOfClass:[NSString class]] ? type : @"(nil)";
            if (outError) {
                *outError = [NSError errorWithDomain:@"VGStillImageFilterFactory" code:10
                    userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:
                            @"Unsupported filter type '%@'. Only 'beauty' is supported for offline still export.",
                            badType]}];
            }
            NSLog(@"[VGStillImageFilterFactory] Unsupported type '%@' — aborting", badType);
            return nil;
        }
        NSDictionary *params = spec[@"parameters"];
        if ([params isKindOfClass:[NSDictionary class]]) {
            id faceAwareVal = params[@"faceAwareEnabled"];
            if ([faceAwareVal isKindOfClass:[NSNumber class]] && [faceAwareVal boolValue]) {
                if (outError) {
                    *outError = [NSError errorWithDomain:@"VGStillImageFilterFactory" code:11
                        userInfo:@{NSLocalizedDescriptionKey:
                            @"faceAwareEnabled=true is not supported for offline still export in this slice."}];
                }
                NSLog(@"[VGStillImageFilterFactory] faceAwareEnabled=true rejected");
                return nil;
            }
        }
    }

    // Create the dimension-matched output pool (+1 from Create, transferred to bundle).
    CVPixelBufferPoolRef outputPool = _VGStillCreatePool(width, height);
    if (!outputPool) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGStillImageFilterFactory" code:20
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Failed to create CVPixelBufferPool for %zux%zu", width, height]}];
        }
        return nil;
    }

    // Pass 2: construct nodes.
    NSMutableArray *nodes = [NSMutableArray arrayWithCapacity:specs.count];
    for (NSDictionary *spec in specs) {
        NSDictionary *params = spec[@"parameters"];
        BOOL enabled = (spec[@"enabled"] != nil) ? [spec[@"enabled"] boolValue] : YES;
        float intensity = 0.75f;
        if ([params[@"intensity"] isKindOfClass:[NSNumber class]]) {
            intensity = [params[@"intensity"] floatValue];
        }
        BOOL wantV2 = [params[@"beautyVersion"] isKindOfClass:[NSNumber class]]
                      && [params[@"beautyVersion"] integerValue] == 2;
        if (wantV2) {
            BeautyV2FilterGroup *v2 = [[BeautyV2FilterGroup alloc] initWithPool:outputPool
                                                                         device:device];
            if (!v2) {
                CVPixelBufferPoolRelease(outputPool);
                if (outError) *outError = [NSError errorWithDomain:@"VGStillImageFilterFactory" code:21
                    userInfo:@{NSLocalizedDescriptionKey: @"BeautyV2FilterGroup init returned nil"}];
                return nil;
            }
            v2.intensity = intensity;
            v2.enabled = enabled;
            [nodes addObject:(id)v2];
        } else {
            VanguardBeautyFilterNode *v1 = [[VanguardBeautyFilterNode alloc] initWithPool:outputPool
                                                                                   device:device];
            if (!v1) {
                CVPixelBufferPoolRelease(outputPool);
                if (outError) *outError = [NSError errorWithDomain:@"VGStillImageFilterFactory" code:22
                    userInfo:@{NSLocalizedDescriptionKey: @"VanguardBeautyFilterNode init returned nil"}];
                return nil;
            }
            v1.intensity = intensity;
            v1.enabled = enabled;
            [nodes addObject:(id)v1];
        }
    }

    NSLog(@"[VGStillImageFilterFactory] Built %lu offline node(s) for %zux%zu still",
          (unsigned long)nodes.count, width, height);
    // Transfer +1 pool ownership to the bundle — do NOT release here.
    return [[VGOfflineFilterBundle alloc] initWithNodes:[nodes copy] adoptedPool:outputPool];
}

@end

// ─── VGGreenScreenFilterNode (UMF camera graph green screen, iOS-first MVP) ──
//
// Implementation inlined here so the class compiles without a Pods project
// regeneration (VGGreenScreenFilterNode.m is comment-only). Contract, scope
// and explicit non-claims are documented in VGGreenScreenFilterNode.h.
//
// Processing contract (processBuffer:atTime:device:):
//   1. enabled=NO or invalidated → CVPixelBufferRetain(input); return input.
//   2. Matte source unavailable (iOS < 15), NULL pool, or zero-dimension input
//      → passthrough (fail open), logged.
//   3. Synchronous Vision person segmentation (FAST) on the input exactly as
//      received (no orientation passed: the camera source already oriented and
//      mirrored the frame). Error / no observation / wrong format → passthrough.
//   4. CIImage wrap of the input (foreground) and the OneComponent8 matte; the
//      matte is scaled (non-uniform) to the frame extent.
//   5. S1 matte refinement over the scaled matte — the proven production order
//      and constants of VGDuetPreviewCompositor, ported verbatim:
//        morphology close (r 1.0) → feather (r 4.0) → trimap smoothstep
//        (0.10/0.90) → guided edge preserve (CIEdges 2.0, blur 1.5,
//        smoothstep 0.08/0.34, guided by the camera frame itself).
//      Each stage fails open to its input mask and reports an applied flag.
//      S4/S5/tightAlphaR1 lab candidates are deliberately NOT ported.
//   6. CIBlendWithMask: inputImage = foreground, inputBackgroundImage = solid
//      colour, inputMaskImage = refined matte (255 = subject → foreground).
//   7. Pool buffer allocation; its dimensions must equal the frame's, else
//      passthrough (logged once).
//   8. Render with a NULL colour space into the pool buffer; return it (+1).
//
// Logging markers (grep in device logs):
//   IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_NODE_CREATED
//   IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_PROOF_UNAVAILABLE   (iOS < 15 only, once)
//   IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_FRAME               (frames 1-3, then every 60th)
//   IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_FAIL_OPEN           (events 1-3, then every 60th)
//
// Native telemetry (no log dependency): -diagnosticsSnapshot (contract in the
// header). Per-frame counters are plain scalars written under _telemetryLock
// at the end of a successful keyed render (step 7 below) and on fail-open;
// nothing is allocated for telemetry on the frame path.

NSString * const VGGreenScreenFilterNodeBackgroundTypeSolidColor = @"solidColor";

static const uint64_t kVGGreenScreenFilterLogInterval = 60;

// Shared CIContext with NO working colour space (raw bytes in, raw bytes out):
// the same options as the proven live green-screen renderers in this package
// (VGDuetPreviewCompositor, VGARKitLiveGreenScreenPreviewCoordinator). The
// device passed on first use backs the context for the process lifetime.
static CIContext *_VGGSFNSharedCIContext(id<MTLDevice> device) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *opts = @{
            kCIContextWorkingColorSpace:  [NSNull null],
            kCIContextCacheIntermediates: @NO,
        };
        ctx = device ? [CIContext contextWithMTLDevice:device options:opts]
                     : [CIContext contextWithOptions:opts];
    });
    return ctx;
}

// ─── S1 matte refinement (ported from VGDuetPreviewCompositor, production) ───
//
// Stage order and constants are the proven live green-screen S1 pipeline:
//   morphology close → feather → trimap → guided edge preserve → CIBlendWithMask
// Every stage is a pure CIImage recipe (lazy; the GPU work lands in the single
// render at the end of processBuffer:). Each stage returns its refined mask and
// sets *applied = YES, or returns its INPUT mask unchanged with *applied = NO
// (fail open) when a filter is unavailable, produces nil, or the inputs are
// degenerate. Nothing here allocates buffers, touches the pool or the device,
// or retains anything beyond the call. S4/S5/tightAlphaR1 are NOT ported.

static const CGFloat kVGGSFNMorphologyCloseRadius = 1.0;   // dilate then erode
static const CGFloat kVGGSFNFeatherRadius         = 4.0;   // CIGaussianBlur px
static const CGFloat kVGGSFNTrimapLow             = 0.10;  // smoothstep(low, high)
static const CGFloat kVGGSFNTrimapHigh            = 0.90;
static const CGFloat kVGGSFNGuidedEdgeIntensity   = 2.0;   // CIEdges
static const CGFloat kVGGSFNGuidedEdgeBlurRadius  = 1.5;   // CIGaussianBlur px
static const CGFloat kVGGSFNGuidedEdgeLow         = 0.08;  // smoothstep(low, high)
static const CGFloat kVGGSFNGuidedEdgeHigh        = 0.34;

// smoothstep(low, high, m) on R, G, B (alpha identity), cropped to `rect`:
//   CIColorMatrix (linear ramp t = (m - low) / (high - low))
//   → CIColorClamp (t ∈ [0, 1]) → CIColorPolynomial (3t² − 2t³).
// Returns nil on any filter failure so callers fail open to their input.
static CIImage * _Nullable _VGGSFNSmoothstep(CIImage *image, CGFloat low, CGFloat high, CGRect rect) {
    if (!image || high <= low) return nil;
    const CGFloat scale = 1.0 / (high - low);
    const CGFloat bias  = -low * scale;

    CIFilter *ramp = [CIFilter filterWithName:@"CIColorMatrix"];
    if (!ramp) return nil;
    [ramp setValue:image forKey:kCIInputImageKey];
    [ramp setValue:[CIVector vectorWithX:scale Y:0     Z:0     W:0] forKey:@"inputRVector"];
    [ramp setValue:[CIVector vectorWithX:0     Y:scale Z:0     W:0] forKey:@"inputGVector"];
    [ramp setValue:[CIVector vectorWithX:0     Y:0     Z:scale W:0] forKey:@"inputBVector"];
    [ramp setValue:[CIVector vectorWithX:0     Y:0     Z:0     W:1] forKey:@"inputAVector"];
    [ramp setValue:[CIVector vectorWithX:bias  Y:bias  Z:bias  W:0] forKey:@"inputBiasVector"];
    CIImage *ramped = ramp.outputImage;
    if (!ramped) return nil;

    CIFilter *clamp = [CIFilter filterWithName:@"CIColorClamp"];
    if (!clamp) return nil;
    [clamp setValue:ramped forKey:kCIInputImageKey];
    [clamp setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0] forKey:@"inputMinComponents"];
    [clamp setValue:[CIVector vectorWithX:1 Y:1 Z:1 W:1] forKey:@"inputMaxComponents"];
    CIImage *clamped = clamp.outputImage;
    if (!clamped) return nil;

    CIFilter *curve = [CIFilter filterWithName:@"CIColorPolynomial"];
    if (!curve) return nil;
    CIVector *smoothstep = [CIVector vectorWithX:0 Y:0 Z:3 W:-2];   // 0 + 0t + 3t² − 2t³
    [curve setValue:clamped    forKey:kCIInputImageKey];
    [curve setValue:smoothstep forKey:@"inputRedCoefficients"];
    [curve setValue:smoothstep forKey:@"inputGreenCoefficients"];
    [curve setValue:smoothstep forKey:@"inputBlueCoefficients"];
    [curve setValue:[CIVector vectorWithX:0 Y:1 Z:0 W:0] forKey:@"inputAlphaCoefficients"];
    CIImage *curved = curve.outputImage;
    if (!curved) return nil;
    return [curved imageByCroppingToRect:rect];
}

// Stage 1 — morphological close: CIMorphologyMaximum (dilate) then
// CIMorphologyMinimum (erode), radius 1.0. Clamped to extent before dilate; the
// dilated image still carries the infinite extent, and feeding that into the
// second morphology filter crashed on-device (EXC_BAD_ACCESS), so it is cropped
// to a finite radius-padded rect before erode (NOT re-clamped), then cropped
// back to `rect`. Fills pinholes and stair-step bites before the feather.
static CIImage *_VGGSFNMorphologyClose(CIImage *mask, CGRect rect, BOOL *applied) {
    *applied = NO;
    const CGFloat radius = kVGGSFNMorphologyCloseRadius;
    if (radius <= 0 || CGRectIsEmpty(rect) || CGRectIsEmpty(mask.extent)) return mask;

    CIFilter *dilate = [CIFilter filterWithName:@"CIMorphologyMaximum"];
    if (!dilate) return mask;
    [dilate setValue:[mask imageByClampingToExtent] forKey:kCIInputImageKey];
    [dilate setValue:@(radius) forKey:kCIInputRadiusKey];
    CIImage *dilated = dilate.outputImage;
    if (!dilated) return mask;

    const CGFloat pad = MAX(radius * 2, 2);
    CIImage *boundedDilated = [dilated imageByCroppingToRect:CGRectInset(rect, -pad, -pad)];

    CIFilter *erode = [CIFilter filterWithName:@"CIMorphologyMinimum"];
    if (!erode) return mask;
    [erode setValue:boundedDilated forKey:kCIInputImageKey];
    [erode setValue:@(radius) forKey:kCIInputRadiusKey];
    CIImage *eroded = erode.outputImage;
    if (!eroded) return mask;

    *applied = YES;
    return [eroded imageByCroppingToRect:rect];
}

// Stage 2 — feather: CIGaussianBlur radius 4.0, clamped to extent before the
// blur (no edge darkening) and cropped back to `rect`.
static CIImage *_VGGSFNFeather(CIImage *mask, CGRect rect, BOOL *applied) {
    *applied = NO;
    const CGFloat radius = kVGGSFNFeatherRadius;
    if (radius <= 0 || CGRectIsEmpty(rect) || CGRectIsEmpty(mask.extent)) return mask;

    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    if (!blur) return mask;
    [blur setValue:[mask imageByClampingToExtent] forKey:kCIInputImageKey];
    [blur setValue:@(radius) forKey:kCIInputRadiusKey];
    CIImage *blurred = blur.outputImage;
    if (!blurred) return mask;

    *applied = YES;
    return [blurred imageByCroppingToRect:rect];
}

// Stage 3 — trimap: smoothstep(0.10, 0.90, m). Values ≤ low become solid
// background, ≥ high solid foreground, the band between stays soft.
static CIImage *_VGGSFNTrimap(CIImage *mask, CGRect rect, BOOL *applied) {
    *applied = NO;
    if (CGRectIsEmpty(rect) || CGRectIsEmpty(mask.extent)) return mask;
    CIImage *curved = _VGGSFNSmoothstep(mask, kVGGSFNTrimapLow, kVGGSFNTrimapHigh, rect);
    if (!curved) return mask;
    *applied = YES;
    return curved;
}

// Stage 4 — guided edge preserve: restores the pre-trimap `feathered` mask over
// the `trimapped` mask wherever the camera frame (`guide`) has a strong edge,
// keeping thin detail (hair, fingers) while flat regions stay cleanly keyed.
// Edge confidence = CIEdges(guide ∩ rect, 2.0) → CIGaussianBlur 1.5 →
// smoothstep(0.08, 0.34); composite = CIBlendWithMask(feathered over trimapped
// using that confidence). Fails open to `trimapped`.
static CIImage *_VGGSFNGuidedEdgePreserve(CIImage *trimapped, CIImage *feathered,
                                          CIImage *guide, CGRect rect, BOOL *applied) {
    *applied = NO;
    if (CGRectIsEmpty(rect) || CGRectIsEmpty(trimapped.extent) ||
        CGRectIsEmpty(feathered.extent) || CGRectIsEmpty(guide.extent)) {
        return trimapped;
    }

    CIFilter *edges = [CIFilter filterWithName:@"CIEdges"];
    if (!edges) return trimapped;
    [edges setValue:[guide imageByCroppingToRect:rect] forKey:kCIInputImageKey];
    [edges setValue:@(kVGGSFNGuidedEdgeIntensity) forKey:kCIInputIntensityKey];
    CIImage *edgeImage = edges.outputImage;
    if (!edgeImage) return trimapped;

    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    if (!blur) return trimapped;
    [blur setValue:[edgeImage imageByClampingToExtent] forKey:kCIInputImageKey];
    [blur setValue:@(kVGGSFNGuidedEdgeBlurRadius) forKey:kCIInputRadiusKey];
    CIImage *blurredEdges = blur.outputImage;
    if (!blurredEdges) return trimapped;

    CIImage *edgeConfidence = _VGGSFNSmoothstep(blurredEdges, kVGGSFNGuidedEdgeLow,
                                                kVGGSFNGuidedEdgeHigh, rect);
    if (!edgeConfidence) return trimapped;

    CIFilter *blend = [CIFilter filterWithName:@"CIBlendWithMask"];
    if (!blend) return trimapped;
    [blend setValue:feathered      forKey:kCIInputImageKey];
    [blend setValue:trimapped      forKey:kCIInputBackgroundImageKey];
    [blend setValue:edgeConfidence forKey:kCIInputMaskImageKey];
    CIImage *blended = blend.outputImage;
    if (!blended) return trimapped;

    *applied = YES;
    return [blended imageByCroppingToRect:rect];
}

@interface VGGreenScreenFilterNode ()
- (nullable VNPixelBufferObservation *)_personMatteObservationForBuffer:(CVPixelBufferRef)input
                                                                  error:(NSError * _Nullable * _Nullable)outError
    API_AVAILABLE(ios(15.0));
- (CVPixelBufferRef)_failOpenWithInput:(CVPixelBufferRef)input reason:(NSString *)reason;
@end

@implementation VGGreenScreenFilterNode {
    CVPixelBufferPoolRef _pool;               // +1 owned; released in dealloc
    id<MTLDevice>        _device;
    CIImage             *_backgroundImage;    // infinite-extent solid colour; cropped per frame
    _Atomic(BOOL)        _invalidated;
    _Atomic(uint64_t)    _frameCounter;       // frames that entered processing (diagnostics)
    _Atomic(uint64_t)    _failOpenCounter;    // fail-open events (diagnostics, throttled log)
    _Atomic(BOOL)        _loggedUnavailable;
    _Atomic(BOOL)        _loggedPoolMismatch;

    // ── Telemetry (read by -diagnosticsSnapshot from any thread, written on
    //    the graph execution queue). Every field below is guarded by
    //    _telemetryLock; hold time is a handful of scalar stores/loads. The
    //    counts here cover successfully keyed/rendered frames only — frames
    //    entering processing and fail-opens use the atomics above.
    os_unfair_lock       _telemetryLock;
    uint64_t             _tmProcessedFrameCount;          // keyed + rendered frames
    uint64_t             _tmAllS1StagesAppliedFrameCount; // keyed frames with all 4 S1 stages
    size_t               _tmLastSourceWidth;
    size_t               _tmLastSourceHeight;
    size_t               _tmLastMatteWidth;
    size_t               _tmLastMatteHeight;
    BOOL                 _tmLastMorphologyCloseApplied;
    BOOL                 _tmLastFeatherApplied;
    BOOL                 _tmLastTrimapApplied;
    BOOL                 _tmLastGuidedEdgeApplied;
    double               _tmLastVisionMs;
    double               _tmSumVisionMs;
    double               _tmMaxVisionMs;
    double               _tmLastBlendRenderMs;
    double               _tmSumBlendRenderMs;
    double               _tmMaxBlendRenderMs;
    double               _tmLastTotalMs;
    double               _tmSumTotalMs;
    double               _tmMaxTotalMs;
    NSString            *_tmLastFailOpenReason;           // @"none" until the first fail-open
}

@synthesize filterName     = _filterName;
@synthesize enabled        = _enabled;
@synthesize nodeId         = _nodeId;
@synthesize nodeType       = _nodeType;
@synthesize backgroundARGB = _backgroundARGB;
@synthesize matteSource    = _matteSource;

// ─── VGMediaNode / VGMetalFilterNode cost model ───────────────────────────────

- (BOOL)isExpensive { return YES; }
- (float)estimatedGPUCostMs { return 12.0f; }
- (VGNodeRole)nodeRole { return VGNodeRoleFilter; }

// ─── Lifecycle ────────────────────────────────────────────────────────────────

- (void)prepareWithCompletion:(void (^)(NSError * _Nullable))completion {
    if (completion) completion(nil);
}

- (void)invalidate {
    // Terminal, idempotent, lock-free, allocation-free. Nothing asynchronous is
    // ever in flight (Vision runs synchronously inside processBuffer:), so there
    // is nothing to cancel; every subsequent frame passes through.
    atomic_store(&_invalidated, YES);
}

- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
              backgroundARGB:(uint32_t)backgroundARGB {
    NSParameterAssert(device != nil);
    self = [super init];
    if (!self) return nil;

    _pool           = pool ? (CVPixelBufferPoolRef)CFRetain(pool) : NULL;
    _device         = device;
    _backgroundARGB = backgroundARGB;
    _enabled        = YES;
    atomic_init(&_invalidated, NO);
    atomic_init(&_frameCounter, 0);
    atomic_init(&_failOpenCounter, 0);
    atomic_init(&_loggedUnavailable, NO);
    atomic_init(&_loggedPoolMismatch, NO);

    // Telemetry: the numeric fields start at zero from alloc; only the lock
    // and the initial fail-open reason need explicit values.
    _telemetryLock        = OS_UNFAIR_LOCK_INIT;
    _tmLastFailOpenReason = @"none";

    _nodeId     = [[NSUUID UUID] UUIDString];
    _nodeType   = @"VGGreenScreenFilterNode";
    _filterName = @"GreenScreen";

    // Solid background: raw sRGB components, alpha forced opaque. With the
    // unmanaged CIContext these component values reach the output bytes as-is.
    CGFloat r = ((backgroundARGB >> 16) & 0xFF) / 255.0;
    CGFloat g = ((backgroundARGB >>  8) & 0xFF) / 255.0;
    CGFloat b = ( backgroundARGB        & 0xFF) / 255.0;
    _backgroundImage = [CIImage imageWithColor:[CIColor colorWithRed:r green:g blue:b alpha:1.0]];

    if (@available(iOS 15.0, *)) {
        _matteSource = VGGreenScreenFilterNodeMatteSourceVisionPersonFast;
    } else {
        _matteSource = VGGreenScreenFilterNodeMatteSourceUnavailable;
    }

    NSLog(@"[VGGreenScreenFilterNode] IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_NODE_CREATED "
           "proofLevel=S1 matteSource=%@ backgroundType=solidColor "
           "backgroundARGB=0x%08X alphaByteIgnored=1 pool=%p edgeRefinement=S1 "
           "morphologyCloseRadius=%.1f featherRadius=%.1f trimapLow=%.2f trimapHigh=%.2f "
           "guidedEdgeIntensity=%.1f guidedEdgeBlurRadius=%.1f guidedEdgeLow=%.2f "
           "guidedEdgeHigh=%.2f temporalSmoothing=none matteQualityClaim=none",
          (_matteSource == VGGreenScreenFilterNodeMatteSourceVisionPersonFast)
              ? @"visionPersonFast" : @"unavailable",
          backgroundARGB, _pool,
          (double)kVGGSFNMorphologyCloseRadius, (double)kVGGSFNFeatherRadius,
          (double)kVGGSFNTrimapLow, (double)kVGGSFNTrimapHigh,
          (double)kVGGSFNGuidedEdgeIntensity, (double)kVGGSFNGuidedEdgeBlurRadius,
          (double)kVGGSFNGuidedEdgeLow, (double)kVGGSFNGuidedEdgeHigh);
    return self;
}

- (void)dealloc {
    if (_pool) {
        CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
    }
}

// ─── Fail-open helper ─────────────────────────────────────────────────────────
//
// Every failure path returns the input (+1) so the preview shows the unkeyed
// camera rather than a dropped or corrupt frame. Logged for the first 3 events
// and then every 60th so a physical run can count fail-opens without log spam.
- (CVPixelBufferRef)_failOpenWithInput:(CVPixelBufferRef)input reason:(NSString *)reason {
    uint64_t n = atomic_fetch_add(&_failOpenCounter, 1) + 1;

    // Telemetry: remember the reason for -diagnosticsSnapshot. The immutable
    // copy is taken outside the lock (a no-op retain for the immutable strings
    // callers pass), and the previous string is released outside the lock so
    // the hold is a single pointer swap.
    NSString *reasonCopy = [reason copy] ?: @"unknown";
    {
        NSString *previousReason;
        os_unfair_lock_lock(&_telemetryLock);
        previousReason = _tmLastFailOpenReason;
        _tmLastFailOpenReason = reasonCopy;
        os_unfair_lock_unlock(&_telemetryLock);
        (void)previousReason;   // released here, after the unlock
    }

    if (n <= 3 || (n % kVGGreenScreenFilterLogInterval) == 0) {
        NSLog(@"[VGGreenScreenFilterNode] IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_FAIL_OPEN "
               "reason=%@ failOpenCount=%llu frame=%llu — returning input unchanged",
              reason, (unsigned long long)n,
              (unsigned long long)atomic_load(&_frameCounter));
    }
    CVPixelBufferRetain(input);
    return input;
}

// ─── Matte: synchronous Vision person segmentation (FAST) ─────────────────────
//
// Stateless per frame: a fresh request and a fresh handler, both locals of this
// call, so nothing Vision-side survives between frames and nothing outlives the
// call (the handler's reference to the input ends when this method returns).
// No orientation is passed — the camera source already oriented/mirrored the
// frame, so the matte keeps the buffer's own orientation and lines up 1:1.
// Returns the observation (ARC-owned; keeps its pixelBuffer alive) or nil.
- (nullable VNPixelBufferObservation *)_personMatteObservationForBuffer:(CVPixelBufferRef)input
                                                                  error:(NSError * _Nullable * _Nullable)outError {
    VNGeneratePersonSegmentationRequest *request =
        [[VNGeneratePersonSegmentationRequest alloc] init];
    request.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelFast;
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8;   // 255 = person
    request.preferBackgroundProcessing = NO;

    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCVPixelBuffer:input options:@{}];
    NSError *error = nil;
    if (![handler performRequests:@[request] error:&error]) {
        if (outError) *outError = error;
        return nil;
    }
    VNPixelBufferObservation *observation = request.results.firstObject;
    if (![observation isKindOfClass:[VNPixelBufferObservation class]] || !observation.pixelBuffer) {
        return nil;
    }
    return observation;
}

// ─── VanguardFilterNode: processBuffer:atTime:device: ────────────────────────

- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)time
                           device:(id<MTLDevice>)dev {
    // Passthrough: disabled or invalidated (no buffer ops beyond the +1).
    if (!_enabled || atomic_load(&_invalidated)) {
        CVPixelBufferRetain(input);
        return input;
    }

    const uint64_t frameIndex = atomic_fetch_add(&_frameCounter, 1) + 1;
    const BOOL shouldLog = (frameIndex <= 3) || (frameIndex % kVGGreenScreenFilterLogInterval) == 0;

    if (_matteSource != VGGreenScreenFilterNodeMatteSourceVisionPersonFast) {
        BOOL expected = NO;
        if (atomic_compare_exchange_strong(&_loggedUnavailable, &expected, YES)) {
            NSLog(@"[VGGreenScreenFilterNode] IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_PROOF_UNAVAILABLE "
                   "reason=vision_person_segmentation_requires_ios15 — passthrough for the node's "
                   "lifetime; no keying is performed and nothing is proven on this system");
        }
        CVPixelBufferRetain(input);
        return input;
    }
    if (!_pool) {
        return [self _failOpenWithInput:input reason:@"pool_null"];
    }

    const size_t srcW = CVPixelBufferGetWidth(input);
    const size_t srcH = CVPixelBufferGetHeight(input);
    if (srcW == 0 || srcH == 0) {
        return [self _failOpenWithInput:input reason:@"zero_dimension_input"];
    }

    const CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();

    // ── 1. Person matte (synchronous Vision FAST) ─────────────────────────
    VNPixelBufferObservation *observation = nil;   // kept alive until render completes
    CVPixelBufferRef matteBuffer = NULL;
    size_t matteW = 0, matteH = 0;
    if (@available(iOS 15.0, *)) {
        NSError *visionError = nil;
        observation = [self _personMatteObservationForBuffer:input error:&visionError];
        if (!observation) {
            return [self _failOpenWithInput:input
                                     reason:[NSString stringWithFormat:@"vision_no_matte(%@)",
                                             visionError.localizedDescription ?: @"no_observation"]];
        }
        matteBuffer = observation.pixelBuffer;
        matteW = CVPixelBufferGetWidth(matteBuffer);
        matteH = CVPixelBufferGetHeight(matteBuffer);
        if (CVPixelBufferGetPixelFormatType(matteBuffer) != kCVPixelFormatType_OneComponent8 ||
            matteW == 0 || matteH == 0) {
            return [self _failOpenWithInput:input reason:@"vision_matte_format_unsupported"];
        }
    } else {
        // Unreachable: _matteSource is Unavailable below iOS 15 (guarded above).
        return [self _failOpenWithInput:input reason:@"vision_unavailable"];
    }
    const CFAbsoluteTime t1 = CFAbsoluteTimeGetCurrent();

    // ── 2. CIImages: foreground (input) + matte scaled to the frame extent ─
    CIImage *foreground = [CIImage imageWithCVPixelBuffer:input];
    CIImage *matte      = [CIImage imageWithCVPixelBuffer:matteBuffer];
    if (!foreground || !matte) {
        return [self _failOpenWithInput:input reason:@"ciimage_wrap_failed"];
    }
    const CGRect srcBounds = CGRectMake(0, 0, (CGFloat)srcW, (CGFloat)srcH);
    if (matteW != srcW || matteH != srcH) {
        matte = [matte imageByApplyingTransform:
                 CGAffineTransformMakeScale((CGFloat)srcW / (CGFloat)matteW,
                                            (CGFloat)srcH / (CGFloat)matteH)];
    }
    CIImage *background = [_backgroundImage imageByCroppingToRect:srcBounds];

    // ── 3. S1 matte refinement (each stage fails open to its input mask) ──
    //   close → feather → trimap → guided edge (guide = camera foreground).
    //   The guided stage needs BOTH the feathered and the trimapped masks.
    BOOL morphologyCloseApplied = NO, featherApplied = NO;
    BOOL trimapApplied = NO, guidedEdgeApplied = NO;
    CIImage *closed    = _VGGSFNMorphologyClose(matte, srcBounds, &morphologyCloseApplied);
    CIImage *feathered = _VGGSFNFeather(closed, srcBounds, &featherApplied);
    CIImage *trimapped = _VGGSFNTrimap(feathered, srcBounds, &trimapApplied);
    CIImage *refined   = _VGGSFNGuidedEdgePreserve(trimapped, feathered, foreground,
                                                   srcBounds, &guidedEdgeApplied);

    // ── 4. CIBlendWithMask ────────────────────────────────────────────────
    //   inputImage           = foreground (camera)
    //   inputBackgroundImage = solid colour
    //   inputMaskImage       = refined matte (255/white = subject → foreground)
    CIFilter *blend = [CIFilter filterWithName:@"CIBlendWithMask"];
    if (!blend) {
        return [self _failOpenWithInput:input reason:@"blend_filter_unavailable"];
    }
    [blend setValue:foreground forKey:kCIInputImageKey];
    [blend setValue:background forKey:kCIInputBackgroundImageKey];
    [blend setValue:refined    forKey:kCIInputMaskImageKey];
    CIImage *keyed = blend.outputImage;
    if (!keyed) {
        return [self _failOpenWithInput:input reason:@"blend_nil_output"];
    }
    keyed = [keyed imageByCroppingToRect:srcBounds];

    // ── 5. Output buffer from the session pool ────────────────────────────
    CVPixelBufferRef output = NULL;
    CVReturn rv = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &output);
    if (rv != kCVReturnSuccess || !output) {
        return [self _failOpenWithInput:input
                                 reason:[NSString stringWithFormat:@"pool_alloc_failed(%d)", (int)rv]];
    }
    if (CVPixelBufferGetWidth(output) != srcW || CVPixelBufferGetHeight(output) != srcH) {
        BOOL expected = NO;
        if (atomic_compare_exchange_strong(&_loggedPoolMismatch, &expected, YES)) {
            NSLog(@"[VGGreenScreenFilterNode] pool buffer %zux%zu does not match frame %zux%zu "
                   "— fail open (logged once)",
                  CVPixelBufferGetWidth(output), CVPixelBufferGetHeight(output), srcW, srcH);
        }
        CVPixelBufferRelease(output);
        return [self _failOpenWithInput:input reason:@"pool_dimension_mismatch"];
    }

    // ── 6. Render (NULL colour space: raw bytes, no colour matching) ──────
    [_VGGSFNSharedCIContext(_device) render:keyed
                            toCVPixelBuffer:output
                                     bounds:srcBounds
                                 colorSpace:NULL];
    const CFAbsoluteTime t2 = CFAbsoluteTimeGetCurrent();
    const double visionMs      = (t1 - t0) * 1000.0;
    const double blendRenderMs = (t2 - t1) * 1000.0;
    const double totalMs       = (t2 - t0) * 1000.0;
    const BOOL allS1StagesApplied =
        morphologyCloseApplied && featherApplied && trimapApplied && guidedEdgeApplied;

    // ── 7. Telemetry (keyed frames only; scalar stores under a tiny lock) ─
    //   Reached only after a successful render, so fail-open frames never
    //   count as processed and never enter the latency averages.
    os_unfair_lock_lock(&_telemetryLock);
    _tmProcessedFrameCount += 1;
    if (allS1StagesApplied) _tmAllS1StagesAppliedFrameCount += 1;
    _tmLastSourceWidth  = srcW;
    _tmLastSourceHeight = srcH;
    _tmLastMatteWidth   = matteW;
    _tmLastMatteHeight  = matteH;
    _tmLastMorphologyCloseApplied = morphologyCloseApplied;
    _tmLastFeatherApplied         = featherApplied;
    _tmLastTrimapApplied          = trimapApplied;
    _tmLastGuidedEdgeApplied      = guidedEdgeApplied;
    _tmLastVisionMs = visionMs;
    _tmSumVisionMs += visionMs;
    if (visionMs > _tmMaxVisionMs) _tmMaxVisionMs = visionMs;
    _tmLastBlendRenderMs = blendRenderMs;
    _tmSumBlendRenderMs += blendRenderMs;
    if (blendRenderMs > _tmMaxBlendRenderMs) _tmMaxBlendRenderMs = blendRenderMs;
    _tmLastTotalMs = totalMs;
    _tmSumTotalMs += totalMs;
    if (totalMs > _tmMaxTotalMs) _tmMaxTotalMs = totalMs;
    os_unfair_lock_unlock(&_telemetryLock);

    if (shouldLog) {
        NSLog(@"[VGGreenScreenFilterNode] IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_FRAME frame=%llu "
               "src=%zux%zu matte=%zux%zu matteSource=visionPersonFast edgeRefinement=S1 "
               "morphologyCloseApplied=%d featherApplied=%d trimapApplied=%d "
               "guidedEdgeApplied=%d visionMs=%.1f blendRenderMs=%.1f totalMs=%.1f "
               "pts=%.3f failOpenCount=%llu",
              (unsigned long long)frameIndex, srcW, srcH, matteW, matteH,
              (int)morphologyCloseApplied, (int)featherApplied, (int)trimapApplied,
              (int)guidedEdgeApplied,
              visionMs, blendRenderMs, totalMs,
              CMTimeGetSeconds(time),
              (unsigned long long)atomic_load(&_failOpenCounter));
    }
    (void)observation;   // lifetime: must outlive the render above
    return output;
}

// ─── VGMetalFilterNode: processEnvelope:device: ──────────────────────────────
//
// Contract (DEC-44): VGFrameEnvelope is a struct — taken and returned BY VALUE.
// Do NOT release envelope.payload.videoBuffer — the runtime owns it.

- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                             device:(id<MTLDevice>)device {
    if (!_enabled || atomic_load(&_invalidated)) {
        return envelope; // passthrough — no buffer ops
    }

    CVPixelBufferRef input = (CVPixelBufferRef)envelope.payload.videoBuffer;
    if (!input) return envelope;

    CVPixelBufferRef output = [self processBuffer:input
                                           atTime:envelope.pts
                                           device:device];

    if (output == input) {
        CVPixelBufferRelease(output); // release the extra +1 from the passthrough path
        return envelope;
    }

    if (!output) {
        VGFrameEnvelope failed = envelope;
        failed.payload.videoBuffer = NULL;
        return failed;
    }

    VGFrameEnvelope out = envelope;
    out.payload.videoBuffer = output;
    return out;
}

// ─── Diagnostics: read-only telemetry snapshot ────────────────────────────────
//
// Copies every guarded field out under _telemetryLock (scalar loads plus one
// retain of the reason string — no allocation while locked), then builds the
// dictionary outside the lock. Configuration fields are immutable after init
// and the frame / fail-open counters are atomics, so they need no lock.
// Callable from any thread; changes nothing.

- (NSDictionary<NSString *, id> *)diagnosticsSnapshot {
    os_unfair_lock_lock(&_telemetryLock);
    const uint64_t processed      = _tmProcessedFrameCount;
    const uint64_t allS1Frames    = _tmAllS1StagesAppliedFrameCount;
    const size_t   sourceWidth    = _tmLastSourceWidth;
    const size_t   sourceHeight   = _tmLastSourceHeight;
    const size_t   matteWidth     = _tmLastMatteWidth;
    const size_t   matteHeight    = _tmLastMatteHeight;
    const BOOL     closeApplied   = _tmLastMorphologyCloseApplied;
    const BOOL     featherApplied = _tmLastFeatherApplied;
    const BOOL     trimapApplied  = _tmLastTrimapApplied;
    const BOOL     guidedApplied  = _tmLastGuidedEdgeApplied;
    const double   lastVision     = _tmLastVisionMs;
    const double   sumVision      = _tmSumVisionMs;
    const double   maxVision      = _tmMaxVisionMs;
    const double   lastBlend      = _tmLastBlendRenderMs;
    const double   sumBlend       = _tmSumBlendRenderMs;
    const double   maxBlend       = _tmMaxBlendRenderMs;
    const double   lastTotal      = _tmLastTotalMs;
    const double   sumTotal       = _tmSumTotalMs;
    const double   maxTotal       = _tmMaxTotalMs;
    NSString *lastFailOpenReason  = _tmLastFailOpenReason;
    os_unfair_lock_unlock(&_telemetryLock);

    const BOOL allS1Last = closeApplied && featherApplied && trimapApplied && guidedApplied;
    const double meanVision = processed > 0 ? sumVision / (double)processed : 0.0;
    const double meanBlend  = processed > 0 ? sumBlend  / (double)processed : 0.0;
    const double meanTotal  = processed > 0 ? sumTotal  / (double)processed : 0.0;

    return @{
        @"nodeId":                       _nodeId,
        @"filterName":                   _filterName,
        @"enabled":                      _enabled ? @YES : @NO,
        @"matteSource":                  (_matteSource == VGGreenScreenFilterNodeMatteSourceVisionPersonFast)
                                             ? @"visionPersonFast" : @"unavailable",
        @"proofLevel":                   @"S1",
        @"edgeRefinement":               @"S1",
        @"backgroundARGB":               @(_backgroundARGB),
        @"frameCount":                   @(atomic_load(&_frameCounter)),
        @"processedFrameCount":          @(processed),
        @"failOpenCount":                @(atomic_load(&_failOpenCounter)),
        @"lastFailOpenReason":           lastFailOpenReason ?: @"none",
        @"sourceWidth":                  @(sourceWidth),
        @"sourceHeight":                 @(sourceHeight),
        @"matteWidth":                   @(matteWidth),
        @"matteHeight":                  @(matteHeight),
        @"morphologyCloseApplied":       closeApplied   ? @YES : @NO,
        @"featherApplied":               featherApplied ? @YES : @NO,
        @"trimapApplied":                trimapApplied  ? @YES : @NO,
        @"guidedEdgeApplied":            guidedApplied  ? @YES : @NO,
        @"allS1StagesApplied":           allS1Last      ? @YES : @NO,
        @"allS1StagesAppliedFrameCount": @(allS1Frames),
        @"lastVisionMs":                 @(lastVision),
        @"meanVisionMs":                 @(meanVision),
        @"maxVisionMs":                  @(maxVision),
        @"lastBlendRenderMs":            @(lastBlend),
        @"meanBlendRenderMs":            @(meanBlend),
        @"maxBlendRenderMs":             @(maxBlend),
        @"lastTotalMs":                  @(lastTotal),
        @"meanTotalMs":                  @(meanTotal),
        @"maxTotalMs":                   @(maxTotal),
    };
}

@end

// 3G-C: VGCameraGraphSession adopts VGFrameDelegate so it can act as the
// renderer.frameDelegate instead of _scheduler. This gives the session full
// control over the async handoff boundary.
@interface VGCameraGraphSession () <VGFrameDelegate>
- (BOOL)_queryDimensionsWidth:(size_t *)outWidth height:(size_t *)outHeight;
- (id)_sessionPool;
- (NSUInteger)_sessionPoolBytes;
@end

@implementation VGCameraGraphSession {
    VanguardCameraMediaSource *_source;
    __weak VanguardMetalRenderer *_renderer;
    VGGraphSchedulerV2 *_scheduler;
    VGGraphExecutionContext *_context;
    NSDictionary<NSString *, id<VGNode>> *_nodes;
    _Atomic(BOOL) _invalidated;
    dispatch_queue_t _sessionQueue;
    CVPixelBufferPoolRef _sessionPool;
    NSUInteger _sessionPoolBytes;

    // 3G-C: dedicated serial queue for graph execution (off capture delegate queue).
    dispatch_queue_t _graphExecutionQueue;
    // 3G-C: drop-latest backpressure flag. Set when a graph block is in-flight;
    // cleared when that block finishes. Subsequent raw frames are dropped until
    // the in-flight block completes.
    _Atomic(BOOL) _graphInFlight;

    // POC2: optional platform view sink. Set by connectPlatformViewReceiver:.
    // Retained strongly — the VGPlatformViewSinkAdapter itself holds _receiver weakly.
    VGPlatformViewSinkAdapter *_platformViewSink;

    // POC2: cache the most recent filter chain so connectPlatformViewReceiver:
    // can trigger a rebuild that preserves the current filter state.
    NSArray *_currentFilterChain;

    // [Beauty-Still]: Immutable snapshot of currently active filter specs.
    // Set only after a successful scheduler swap in _applyFilterChainInternal:.
    // Updated in-place by applyHotParameterUpdates: after live node mutation succeeds.
    // Cleared on invalidate and when filter chain is cleared.
    // All reads and writes are serialized on _sessionQueue.
    NSArray<NSDictionary *> *_activeFilterSpecs;

    // ── UFM filter-chain timing (read-only diagnostics) ──────────────────────
    // _fc* fields are owned by _graphExecutionQueue: written by the async frame
    // block and the reset block from _applyFilterChainInternal:, read via
    // dispatch_sync in -filterChainDiagnosticsSnapshot. _fcTimingActive is YES
    // only while a non-empty chain is committed.
    BOOL     _fcTimingActive;
    uint64_t _fcGraphFrameCount;
    double   _fcLastGraphTotalMs;
    double   _fcSumGraphTotalMs;
    double   _fcMaxGraphTotalMs;
    uint64_t _fcDroppedBusyBase;   // _graphDroppedBusyCounter sampled at the last reset
    // Delta-since-commit count of frames dropped by the _graphInFlight guard
    // (incremented on the capture queue in didReceiveRawFrame:).
    _Atomic(uint64_t) _graphDroppedBusyCounter;
}

// [Beauty-Still]: hasActiveFilters and activeFilterSpecs are backed by _activeFilterSpecs ivar.
// Explicit getters serialize access on _sessionQueue.

- (BOOL)hasActiveFilters {
    __block BOOL result = NO;
    dispatch_sync(_sessionQueue, ^{
        result = (self->_activeFilterSpecs.count > 0);
    });
    return result;
}

- (nullable NSArray<NSDictionary *> *)activeFilterSpecs {
    __block NSArray<NSDictionary *> *result = nil;
    dispatch_sync(_sessionQueue, ^{
        result = self->_activeFilterSpecs; // already an immutable copy
    });
    return result;
}



- (nullable instancetype)initWithSource:(VanguardCameraMediaSource *)source
                               renderer:(VanguardMetalRenderer *)renderer
                                  error:(NSError * _Nullable * _Nullable)outError
{
    // ── (a) Guard inputs ──────────────────────────────────────────────────────
    if (!source || !renderer) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGCameraGraphSession"
                                            code:100
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"VGCameraGraphSession: source and renderer must not be nil."
            }];
        }
        return nil;
    }

    self = [super init];
    if (!self) {
        return nil;
    }

    _source = source;
    _renderer = renderer;
    atomic_init(&_invalidated, NO);
    atomic_init(&_graphInFlight, NO);
    atomic_init(&_graphDroppedBusyCounter, 0);
    _sessionQueue = dispatch_queue_create("com.vanguard.cameraGraphSession",
                                          DISPATCH_QUEUE_SERIAL);
    // 3G-C: serial execution queue for graph traversal.
    // QoS userInteractive to match the AVCaptureVideoDataOutput priority; the
    // graph must keep up with camera frame delivery or the in-flight flag will
    // drop frames (expected and intentional backpressure).
    _graphExecutionQueue =
        dispatch_queue_create("com.vanguard.cameraGraphExecution",
                              dispatch_queue_attr_make_with_qos_class(
                                  DISPATCH_QUEUE_SERIAL,
                                  QOS_CLASS_USER_INTERACTIVE, 0));
    _sessionPool = NULL;
    _sessionPoolBytes = 0;

    size_t width = 0;
    size_t height = 0;
    if ([self _queryDimensionsWidth:&width height:&height]) {
        VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];
        NSUInteger poolBytes = width * height * 4 * 3;
        BOOL budgetReserved = [allocator canAllocatePoolBytes:poolBytes];
        if (budgetReserved) {
            _sessionPoolBytes = poolBytes;
        } else {
            NSLog(@"[VGCameraGraphSession] WARNING: Budget reservation of %lu bytes failed. Creating pool anyway.", (unsigned long)poolBytes);
            _sessionPoolBytes = 0;
        }
        _sessionPool = [allocator pixelBufferPoolWithWidth:width
                                                    height:height
                                                    format:kCVPixelFormatType_32BGRA
                                        minimumBufferCount:3];
    } else {
        NSLog(@"[VGCameraGraphSession] No camera dimensions available from source.");
        _sessionPool = NULL;
        _sessionPoolBytes = 0;
    }

    // ── (b) Build the camera graph via factory ────────────────────────────────
    NSError *graphError = nil;
    NSDictionary<NSString *, id> *graphData = [VGCameraGraphFactory
        buildCameraGraphWithSource:source
                       filterChain:nil
                          renderer:renderer
                             error:&graphError];
    if (!graphData) {
        if (outError) {
            *outError = graphError;
        }
        return nil;
    }

    VGGraphDescriptor *descriptor = graphData[@"descriptor"];
    NSDictionary<NSString *, id<VGNode>> *nodes = graphData[@"nodes"];
    VGExecutionPlan *plan = graphData[@"plan"];

    // ── (c) Extract the composite VGFanOutSink ────────────────────────────────
    id<VGFrameSink> fanOutSink = (id<VGFrameSink>)nodes[@"fan_out_sink"];
    if (!fanOutSink) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGCameraGraphSession"
                                            code:101
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"VGCameraGraphSession: fan_out_sink node is missing from constructed graph."
            }];
        }
        return nil;
    }

    // ── (d) Initialize Execution Context and Scheduler ────────────────────────
    _context = [[VGGraphExecutionContext alloc] initWithDescriptor:descriptor
                                                              plan:plan
                                                             nodes:nodes
                                                             clock:nil
                                                 resourceAllocator:[VGResourceAllocator sharedInstance]];

    _scheduler = [[VGGraphSchedulerV2 alloc] initWithPlan:plan
                                                    nodes:nodes
                                                  context:_context];

    // Wire the composite VGFanOutSink to the scheduler as the delivery target.
    _scheduler.sink = fanOutSink;
    _nodes = nodes;

    // ── (e) Wire and start ────────────────────────────────────────────────────
    // 3G-C: Wire the SESSION as the frameDelegate of the renderer (not _scheduler
    // directly). The session's didReceiveRawFrame: provides the async boundary that
    // moves graph traversal off the capture delegate queue.
    renderer.frameDelegate = self;

    // Start frame dispatch.
    [_scheduler startWithClock:nil];

    return self;
}

// ─── [Beauty-Still]: Private graph-apply helper returning BOOL ────────────────
//
// Extracted from setCameraFilterChain: so both the public void method and
// setCameraFilterChainFromSpecs: can detect rebuild success without breaking
// the public API.
//
// ─── UFM filter-chain timing: reset on commit ────────────────────────────────
// Enqueued async on _graphExecutionQueue after a successful scheduler swap.
// The queue is serial, so frame blocks enqueued before the swap drain first,
// keeping the aggregates scoped to the committed chain. Async because the
// caller holds _sessionQueue, which must never block on the graph queue (see
// -invalidate).
- (void)_enqueueFilterChainTimingResetActive:(BOOL)active {
    __weak __typeof(self) weakSelf = self;
    dispatch_async(_graphExecutionQueue, ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_fcTimingActive     = active;
        strongSelf->_fcGraphFrameCount  = 0;
        strongSelf->_fcLastGraphTotalMs = 0.0;
        strongSelf->_fcSumGraphTotalMs  = 0.0;
        strongSelf->_fcMaxGraphTotalMs  = 0.0;
        strongSelf->_fcDroppedBusyBase  = atomic_load(&strongSelf->_graphDroppedBusyCounter);
    });
}

// MUST be called while already on _sessionQueue (via dispatch_sync).
// Returns YES on successful scheduler swap, NO on any failure.
- (BOOL)_applyFilterChainInternal:(nullable NSArray *)filterChain {
    NSLog(@"[VGCameraGraphSession] _applyFilterChainInternal: filterChain.count=%lu",
          (unsigned long)(filterChain.count ?: 0));

    VanguardMetalRenderer *renderer = self->_renderer;
    if (!self->_source || !renderer) {
        NSLog(@"[VGCameraGraphSession] _applyFilterChainInternal skipped — source=%@ renderer=%@",
              self->_source, renderer);
        return NO;
    }

    // [Fix-4]: _currentFilterChain is assigned AFTER a successful swap, not here.
    // This ensures _currentFilterChain only ever reflects a live committed graph state.

    NSError *rebuildError = nil;
    NSDictionary<NSString *, id> *newGraph =
        [VGCameraGraphFactory buildCameraGraphWithSource:self->_source
                                             filterChain:filterChain
                                                renderer:renderer
                                        platformViewSink:self->_platformViewSink
                                                   error:&rebuildError];
    if (!newGraph) {
        NSLog(@"[VGCameraGraphSession] _applyFilterChainInternal rebuild failed: %@ — keeping current scheduler",
              rebuildError);
        return NO;
    }

    VGGraphDescriptor *newDesc = newGraph[@"descriptor"];
    NSDictionary<NSString *, id<VGNode>> *newNodes = newGraph[@"nodes"];
    VGExecutionPlan *newPlan = newGraph[@"plan"];

    id<VGFrameSink> newSink = (id<VGFrameSink>)newNodes[@"fan_out_sink"];
    if (!newSink) {
        NSLog(@"[VGCameraGraphSession] _applyFilterChainInternal fan_out_sink missing — keeping current scheduler");
        return NO;
    }

    VGGraphExecutionContext *newCtx =
        [[VGGraphExecutionContext alloc] initWithDescriptor:newDesc
                                                       plan:newPlan
                                                      nodes:newNodes
                                                      clock:nil
                                          resourceAllocator:[VGResourceAllocator sharedInstance]];

    VGGraphSchedulerV2 *newScheduler =
        [[VGGraphSchedulerV2 alloc] initWithPlan:newPlan
                                           nodes:newNodes
                                         context:newCtx];
    newScheduler.sink = newSink;

    // Structural proof only. startWithClock:nil starts the new scheduler.
    // Do NOT invalidate the old scheduler here because it would stop the
    // shared camera source.
    [newScheduler startWithClock:nil];

    // 3G-C: Swap scheduler — from this point async blocks enqueue against the
    // new scheduler.
    self->_scheduler = newScheduler;
    self->_context = newCtx;
    self->_nodes = newNodes;

    // Phase 6E.1D.1: Propagate recording-enabled state onto the new sink.
    if (self->_source.graphRecordingEnabled) {
        VGRecordingSinkNode *newRecSink =
            (VGRecordingSinkNode *)newNodes[@"camera_recording_sink"];
        if (newRecSink) {
            newRecSink.enabled = YES;
        }
    }

    // [Fix-4]: Assign _currentFilterChain only after the swap succeeds so POC2
    // graph rebuilds always reflect a live committed graph state.
    self->_currentFilterChain = [filterChain copy];

    // Reset filter-chain timing aggregates for the newly committed chain;
    // active only when non-empty (a clear disables timing).
    [self _enqueueFilterChainTimingResetActive:(filterChain.count > 0)];

    NSLog(@"[VGCameraGraphSession] _applyFilterChainInternal hot-swap complete (filterCount=%lu execOrder=%lu)",
          (unsigned long)(filterChain.count ?: 0),
          (unsigned long)newPlan.topologicalOrder.count);
    return YES;
}

// Public void API — preserved for all existing callers (graph recording, POC2, etc.).
// Calls the internal helper; return value is discarded as before.
- (void)setCameraFilterChain:(nullable NSArray *)filterChain {
    dispatch_sync(_sessionQueue, ^{
        if (atomic_load(&self->_invalidated)) {
            return;
        }
        [self _applyFilterChainInternal:filterChain];
    });
}

// ─── POC2: connectPlatformViewReceiver: ───────────────────────────────────────
//
// Wires a VanguardCameraFrameReceiver into the graph as a second VGFanOutSink child.
//
// Strategy: store a VGPlatformViewSinkAdapter as _platformViewSink ivar, then
// trigger a full graph rebuild via setCameraFilterChain: (reusing _currentFilterChain)
// so the factory builds a two-child VGFanOutSink.
//
// Also disables POC1 raw direct forwarding on the camera source to prevent
// double delivery: raw (POC1 path) + graph-processed (POC2 path).
//
// REMOVE before Phase 7 / production.
- (BOOL)connectPlatformViewReceiver:(id<VanguardCameraFrameReceiver>)receiver {
    __block BOOL success = NO;
    dispatch_sync(_sessionQueue, ^{
        if (atomic_load(&self->_invalidated)) {
            NSLog(@"[Vanguard] POC2: connectPlatformViewReceiver — session is invalidated");
            return;
        }
        if (!receiver) {
            NSLog(@"[Vanguard] POC2: connectPlatformViewReceiver — receiver is nil");
            return;
        }

        // Create (or replace) the platform view sink adapter.
        self->_platformViewSink = [[VGPlatformViewSinkAdapter alloc] initWithReceiver:receiver];
        NSLog(@"[Vanguard] POC2: VGPlatformViewSinkAdapter created — will rebuild graph");

        // ── Disable POC1 raw direct forwarding ────────────────────────────────
        // POC1 raw delivery must not run while POC2 graph fan-out is active.
        // Setting platformViewRawForwardingEnabled=NO prevents captureOutput: from
        // calling [_frameReceiver onFrame:pixelBuffer pts:pts] directly, so the
        // MTKView receives only graph-processed frames from VGFanOutSink.
        if (self->_source) {
            self->_source.platformViewRawForwardingEnabled = NO;
            NSLog(@"[Vanguard] POC2: POC1 raw forwarding DISABLED on camera source ✓");
        }

        // ── Trigger graph rebuild with two-child VGFanOutSink ─────────────────
        // setCameraFilterChain: is called on _sessionQueue (we are already on it),
        // so we cannot dispatch_sync again — call the inner implementation directly.
        VanguardMetalRenderer *renderer = self->_renderer;
        if (!self->_source || !renderer) {
            NSLog(@"[Vanguard] POC2: connectPlatformViewReceiver — source or renderer nil");
            return;
        }

        NSError *rebuildError = nil;
        NSDictionary<NSString *, id> *newGraph =
            [VGCameraGraphFactory buildCameraGraphWithSource:self->_source
                                                 filterChain:self->_currentFilterChain
                                                    renderer:renderer
                                            platformViewSink:self->_platformViewSink
                                                       error:&rebuildError];
        if (!newGraph) {
            NSLog(@"[Vanguard] POC2: connectPlatformViewReceiver graph rebuild failed: %@",
                  rebuildError);
            return;
        }

        VGGraphDescriptor *newDesc = newGraph[@"descriptor"];
        NSDictionary<NSString *, id<VGNode>> *newNodes = newGraph[@"nodes"];
        VGExecutionPlan *newPlan = newGraph[@"plan"];

        id<VGFrameSink> newSink = (id<VGFrameSink>)newNodes[@"fan_out_sink"];
        if (!newSink) {
            NSLog(@"[Vanguard] POC2: connectPlatformViewReceiver — fan_out_sink missing after rebuild");
            return;
        }

        VGGraphExecutionContext *newCtx =
            [[VGGraphExecutionContext alloc] initWithDescriptor:newDesc
                                                           plan:newPlan
                                                          nodes:newNodes
                                                          clock:nil
                                              resourceAllocator:[VGResourceAllocator sharedInstance]];

        VGGraphSchedulerV2 *newScheduler =
            [[VGGraphSchedulerV2 alloc] initWithPlan:newPlan
                                               nodes:newNodes
                                             context:newCtx];
        newScheduler.sink = newSink;
        [newScheduler startWithClock:nil];

        self->_scheduler = newScheduler;
        self->_context = newCtx;
        self->_nodes = newNodes;

        // Phase 6E.1D.1: Propagate recording-enabled state onto the new
        // VGRecordingSinkNode after a POC2 platform-view graph rebuild, for the
        // same reason as setCameraFilterChain: — the replacement node starts
        // disabled and would silently drop frames during an active recording.
        if (self->_source.graphRecordingEnabled) {
            VGRecordingSinkNode *newRecSink =
                (VGRecordingSinkNode *)newNodes[@"camera_recording_sink"];
            if (newRecSink) {
                newRecSink.enabled = YES;
            }
        }

        NSLog(@"[Vanguard] POC2: graph rebuilt with two-child VGFanOutSink — PlatformView wired ✓");
        success = YES;
    });
    return success;
}

// ─── Phase 6A-3D-2: Spec-driven filter construction ──────────────────────────
//
// Three-pass atomic validation:
//   Pass 1 — resource contract: pool and Metal device must exist.
//   Pass 2 — known-type check: every spec type must be in
//            {beauty, lut, segmentation, greenScreen}.
//   Pass 3 — constructable check: type must be camera-constructable in this
//            phase, and greenScreen parameters must satisfy their contract.
// Only after all three passes succeed are nodes constructed and the graph mutated.
//
// Known-but-unsupported types (lut, segmentation) return UNSUPPORTED_FILTER_TYPE
// without mutating the graph. "segmentation" (the old mask-store composite) is
// a separate, still-deferred type from "greenScreen" and is NOT repurposed.
// greenScreen with a malformed parameter set returns
// INVALID_GREEN_SCREEN_FILTER_SPEC; a well-formed but unsupported
// backgroundType returns UNSUPPORTED_FILTER_TYPE. Neither mutates the graph.
// Unknown types return UNKNOWN_FILTER.
// Missing pool/device returns UNSUPPORTED_CAMERA_FILTER_RESOURCE_CONTRACT.

// ─── greenScreen spec validation ─────────────────────────────────────────────
//
// Parameter contract (Dart: VGFilterSpecs.greenScreenSolidColor):
//   parameters.backgroundType  NSString — must be "solidColor" (only value in this slice)
//   parameters.argb            NSNumber — integral, 0 … 0xFFFFFFFF (0xAARRGGBB; alpha ignored)
//
// Error mapping (no graph mutation in any case):
//   INVALID_GREEN_SCREEN_FILTER_SPEC (code 4)  parameters missing / not a dictionary,
//                                              backgroundType missing / not a string,
//                                              argb missing / not a number / out of
//                                              range / non-integral
//   UNSUPPORTED_FILTER_TYPE          (code 3)  backgroundType is a string other than
//                                              "solidColor" (image/video backgrounds
//                                              are known but deferred)
static BOOL _VGValidateGreenScreenSpecParameters(id _Nullable params,
                                                 uint32_t * _Nullable outARGB,
                                                 NSError * _Nullable * _Nullable outError) {
    NSError *(^invalid)(NSString *) = ^NSError *(NSString *message) {
        return [NSError errorWithDomain:@"INVALID_GREEN_SCREEN_FILTER_SPEC"
                                   code:4
                               userInfo:@{NSLocalizedDescriptionKey: message}];
    };
    if (![params isKindOfClass:[NSDictionary class]]) {
        if (outError) *outError = invalid(@"greenScreen spec requires a 'parameters' dictionary "
                                           "with backgroundType and argb.");
        return NO;
    }
    NSDictionary *dict = (NSDictionary *)params;
    id backgroundType = dict[@"backgroundType"];
    if (![backgroundType isKindOfClass:[NSString class]]) {
        if (outError) *outError = invalid(@"greenScreen spec requires parameters.backgroundType (string).");
        return NO;
    }
    if (![backgroundType isEqualToString:VGGreenScreenFilterNodeBackgroundTypeSolidColor]) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"UNSUPPORTED_FILTER_TYPE"
                           code:3
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"greenScreen backgroundType '%@' is not supported "
                                                "for the camera graph; only 'solidColor' is "
                                                "supported in this slice.", backgroundType]
            }];
        }
        return NO;
    }
    id argb = dict[@"argb"];
    if (![argb isKindOfClass:[NSNumber class]]) {
        if (outError) *outError = invalid(@"greenScreen spec requires parameters.argb "
                                           "(integer 0xAARRGGBB).");
        return NO;
    }
    const double argbValue = [(NSNumber *)argb doubleValue];
    // The negated range test also rejects NaN.
    if (!(argbValue >= 0.0 && argbValue <= 4294967295.0) || argbValue != floor(argbValue)) {
        if (outError) *outError = invalid([NSString stringWithFormat:
            @"greenScreen parameters.argb must be an integer in 0...0xFFFFFFFF (got %@).", argb]);
        return NO;
    }
    if (outARGB) *outARGB = (uint32_t)[(NSNumber *)argb unsignedLongLongValue];
    return YES;
}

- (BOOL)setCameraFilterChainFromSpecs:(NSArray<NSDictionary *> *)specs
                                error:(NSError * _Nullable * _Nullable)outError
{
    if (outError) *outError = nil;

    // ── Empty specs: clear to passthrough ────────────────────────────────────
    // [Fix-3]: Only clear _activeFilterSpecs if the internal graph swap succeeds.
    if (!specs || specs.count == 0) {
        __block BOOL cleared = NO;
        dispatch_sync(_sessionQueue, ^{
            if (atomic_load(&self->_invalidated)) return;
            cleared = [self _applyFilterChainInternal:nil];
            if (cleared) {
                self->_activeFilterSpecs = nil;
            }
        });
        return cleared;
    }

    // ── Pass 1: resource contract ─────────────────────────────────────────────
    id<MTLDevice> metalDevice = [VGResourceAllocator sharedInstance].metalDevice;
    if (_sessionPool == NULL || !metalDevice) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"UNSUPPORTED_CAMERA_FILTER_RESOURCE_CONTRACT"
                           code:1
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    @"Camera filter construction requires a session pool and Metal device. "
                     "Pool or device is unavailable."
            }];
        }
        NSLog(@"[VGCameraGraphSession] setCameraFilterChainFromSpecs: resource contract "
               "not satisfied (pool=%p device=%@)", _sessionPool, metalDevice);
        return NO;
    }

    // ── Pass 2: known-type check ──────────────────────────────────────────────
    static NSSet<NSString *> *knownTypes;
    static dispatch_once_t knownTypesToken;
    dispatch_once(&knownTypesToken, ^{
        knownTypes = [NSSet setWithObjects:@"beauty", @"lut", @"segmentation",
                                           @"greenScreen", nil];
    });

    for (NSDictionary *spec in specs) {
        NSString *type = spec[@"type"];
        if (![type isKindOfClass:[NSString class]] || ![knownTypes containsObject:type]) {
            NSString *badType = [type isKindOfClass:[NSString class]] ? type : @"(nil)";
            if (outError) {
                *outError = [NSError
                    errorWithDomain:@"UNKNOWN_FILTER"
                               code:2
                           userInfo:@{
                    NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"Unknown filter type: %@", badType]
                }];
            }
            NSLog(@"[VGCameraGraphSession] setCameraFilterChainFromSpecs: unknown type '%@'",
                  badType);
            return NO;
        }
    }

    // ── Pass 3: constructable check ───────────────────────────────────────────
    //
    // Constructable: beauty (V1, V2, V2 face-aware) and greenScreen (solid
    // background only; parameters validated here so a bad spec is rejected
    // before any node exists).
    // lut and segmentation are known but deferred.
    for (NSDictionary *spec in specs) {
        NSString *type = spec[@"type"];
        NSDictionary *params = spec[@"parameters"];

        if ([type isEqualToString:@"lut"]) {
            if (outError) {
                *outError = [NSError
                    errorWithDomain:@"UNSUPPORTED_FILTER_TYPE"
                               code:3
                           userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"Filter type 'lut' is not yet supported for the camera graph."
                }];
            }
            NSLog(@"[VGCameraGraphSession] setCameraFilterChainFromSpecs: lut deferred");
            return NO;
        }

        if ([type isEqualToString:@"segmentation"]) {
            if (outError) {
                *outError = [NSError
                    errorWithDomain:@"UNSUPPORTED_FILTER_TYPE"
                               code:3
                           userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"Filter type 'segmentation' is not yet supported for the camera graph."
                }];
            }
            NSLog(@"[VGCameraGraphSession] setCameraFilterChainFromSpecs: segmentation deferred");
            return NO;
        }

        if ([type isEqualToString:@"greenScreen"]) {
            NSError *specError = nil;
            if (!_VGValidateGreenScreenSpecParameters(params, NULL, &specError)) {
                if (outError) *outError = specError;
                NSLog(@"[VGCameraGraphSession] setCameraFilterChainFromSpecs: greenScreen "
                       "rejected (%@): %@", specError.domain, specError.localizedDescription);
                return NO;
            }
        }

        if ([type isEqualToString:@"beauty"]) {
            // beautyVersion:2 with faceAwareEnabled is fully constructable (Phase 9B-5).
            // beautyVersion:2 without faceAware, and beauty V1, remain the default path.
        }
    }

    // ── All specs valid: construct nodes ──────────────────────────────────────
    //
    // Only reached after all three validation passes succeed.
    NSMutableArray<id<VGMetalFilterNode>> *nodes =
        [NSMutableArray arrayWithCapacity:specs.count];

    for (NSDictionary *spec in specs) {
        NSString *type   = spec[@"type"];
        NSDictionary *params = spec[@"parameters"];

        // Default enabled=YES when key is absent (Dart default).
        BOOL enabled = (spec[@"enabled"] != nil) ? [spec[@"enabled"] boolValue] : YES;

        if ([type isEqualToString:@"beauty"]) {
            BOOL wantV2 = [params[@"beautyVersion"] isKindOfClass:[NSNumber class]] &&
                          [params[@"beautyVersion"] integerValue] == 2;

            if (wantV2) {
                // ── Beauty V2 path (Phase 6A-3E-V2 / Phase 9B-5) ─────────────────────
                // BeautyV2FilterGroup owns its own intermediate pools;
                // borrows _sessionPool for final output only (matches runtime pattern).
                BeautyV2FilterGroup *v2 =
                    [[BeautyV2FilterGroup alloc] initWithPool:_sessionPool
                                                       device:metalDevice];
                if (v2) {
                    if ([params[@"intensity"] isKindOfClass:[NSNumber class]]) {
                        v2.intensity = [params[@"intensity"] floatValue];
                    }
                    // Phase 9B-5: parse faceAwareEnabled and mirror it onto the group.
                    BOOL faceAwareEnabled = NO;
                    if ([params[@"faceAwareEnabled"] isKindOfClass:[NSNumber class]]) {
                        faceAwareEnabled = [params[@"faceAwareEnabled"] boolValue];
                    }
                    v2.faceAwareEnabled = faceAwareEnabled;
                    v2.enabled = enabled;

                    // Phase 9B-5 (Phase 4F port): auto-insert VGSegmentationNode before
                    // BeautyV2FilterGroup when face-aware mode is requested.
                    // Uses the gated factory helper so VG_ML_SEGMENTATION_ENABLED controls
                    // whether the heuristic or LiteRT provider is used — gate default is OFF.
                    if (faceAwareEnabled) {
                        VGSegmentationNode *segNode =
                            [VGCameraGraphFactory makeSegmentationNodeWithPool:_sessionPool
                                                                        device:metalDevice];
                        if (segNode) {
                            segNode.enabled = enabled;
                            [nodes addObject:(id<VGMetalFilterNode>)segNode];
                            NSLog(@"[VGCameraGraphSession] VGSegmentationNode auto-inserted "
                                   "before BeautyV2 (faceAwareEnabled=1)");
                        } else {
                            NSLog(@"[VGCameraGraphSession] WARNING: VGSegmentationNode "
                                   "auto-insert failed before BeautyV2");
                        }
                    }

                    [nodes addObject:(id<VGMetalFilterNode>)v2];
                }
            } else {
                // ── Beauty V1 path (default) ──────────────────────────────────
                VanguardBeautyFilterNode *beauty =
                    [[VanguardBeautyFilterNode alloc] initWithPool:_sessionPool
                                                            device:metalDevice];
                if ([params[@"intensity"] isKindOfClass:[NSNumber class]]) {
                    beauty.intensity = [params[@"intensity"] floatValue];
                }
                beauty.enabled = enabled;
                [nodes addObject:(id<VGMetalFilterNode>)beauty];
            }
        } else if ([type isEqualToString:@"greenScreen"]) {
            // ── Green screen (solid background MVP) ───────────────────────────
            // Parameters passed pass-3 validation; re-parse only to extract argb.
            // The node borrows _sessionPool (retains it +1) and the shared Metal
            // device, exactly like the beauty nodes. It owns no camera state.
            uint32_t backgroundARGB = 0;
            NSError *specError = nil;
            if (!_VGValidateGreenScreenSpecParameters(params, &backgroundARGB, &specError)) {
                // Unreachable after pass 3 (same input). Kept so construction can
                // never proceed on an unvalidated value; still before any mutation.
                if (outError) *outError = specError;
                NSLog(@"[VGCameraGraphSession] setCameraFilterChainFromSpecs: greenScreen "
                       "failed re-validation at construction — aborting without mutation");
                return NO;
            }
            VGGreenScreenFilterNode *greenScreen =
                [[VGGreenScreenFilterNode alloc] initWithPool:_sessionPool
                                                       device:metalDevice
                                               backgroundARGB:backgroundARGB];
            greenScreen.enabled = enabled;
            [nodes addObject:(id<VGMetalFilterNode>)greenScreen];
            NSLog(@"[VGCameraGraphSession] VGGreenScreenFilterNode constructed "
                   "(backgroundType=solidColor argb=0x%08X enabled=%d matteSource=%ld)",
                  backgroundARGB, (int)enabled, (long)greenScreen.matteSource);
        }
        // Additional constructable types will be added in future phases.
    }

    NSLog(@"[VGCameraGraphSession] setCameraFilterChainFromSpecs: constructed %lu node(s)",
          (unsigned long)nodes.count);

    // [Beauty-Still]: _applyFilterChainInternal: MUST be called on _sessionQueue.
    // Wrap the entire apply + spec-commit in a single dispatch_sync so both are
    // serialized and atomic relative to property reads (hasActiveFilters, activeFilterSpecs).
    __block BOOL swapSucceeded = NO;
    dispatch_sync(_sessionQueue, ^{
        if (atomic_load(&self->_invalidated)) {
            return;
        }
        swapSucceeded = [self _applyFilterChainInternal:nodes];
        if (swapSucceeded) {
            // Deep-copy specs (including nested parameters) so the snapshot is
            // immutable and isolated from future Dart-side mutations.
            NSMutableArray<NSDictionary *> *specsCopy =
                [NSMutableArray arrayWithCapacity:specs.count];
            for (NSDictionary *spec in specs) {
                NSMutableDictionary *specCopy = [spec mutableCopy];
                id params = spec[@"parameters"];
                if ([params isKindOfClass:[NSDictionary class]]) {
                    specCopy[@"parameters"] = [(NSDictionary *)params copy];
                }
                [specsCopy addObject:[specCopy copy]];
            }
            self->_activeFilterSpecs = [specsCopy copy];
            NSLog(@"[VGCameraGraphSession] activeFilterSpecs committed (%lu spec(s))",
                  (unsigned long)self->_activeFilterSpecs.count);
        }
    });
    return swapSucceeded;
}

// ─── Phase 6E.1D.1: Graph-backed recording control ───────────────────────────
//
// Enable ordering (Opus requirement §Q6):
//   sink.enabled = YES first → then source.graphRecordingEnabled = YES
//   This ensures the graph path is ready before the raw path is gated.
//
// Disable ordering (Opus requirement §Q6):
//   source.graphRecordingEnabled = NO first → then sink.enabled = NO
//   This allows the raw path to resume before the graph path is torn down,
//   minimizing the zero-coverage window.
//
// Graph-rebuild safety: setCameraFilterChain: and connectPlatformViewReceiver:
// propagate graphRecordingEnabled onto every newly created VGRecordingSinkNode
// so that filter-chain hot-swaps during active recording do not silently revert
// the recording sink to disabled.
//
// Thread-safety:
//   Serialized via dispatch_sync on _sessionQueue.
//   MUST NOT be called from _sessionQueue (deadlock).
//   Properties graphRecordingEnabled and enabled are both atomic BOOLs —
//   visible to readers on _captureQueue and _graphExecutionQueue immediately.
- (void)setRecordingEnabled:(BOOL)enabled {
    dispatch_sync(_sessionQueue, ^{
        if (atomic_load(&self->_invalidated)) {
            return;
        }

        VGRecordingSinkNode *recordingSink =
            (VGRecordingSinkNode *)self->_nodes[@"camera_recording_sink"];

        if (enabled) {
            // ── Enable: sink first, then source gate ──────────────────────────
            // The recording sink must be ready to receive frames before the raw
            // path is gated off. If the sink is missing, do NOT gate the raw path
            // so that raw recording remains the active fallback.
            if (!recordingSink) {
                NSLog(@"[VGCameraGraphSession] setRecordingEnabled:YES — "
                       "camera_recording_sink not found in node map; "
                       "raw path will remain active (fallback preserved)");
                return;
            }
            recordingSink.enabled = YES;
            self->_source.graphRecordingEnabled = YES;
        } else {
            // ── Disable: source gate first, then sink ─────────────────────────
            // Clear the source flag before disabling the sink so that if the
            // raw path resumes (e.g., next recording session), it can append
            // without waiting for the sink to drain.
            self->_source.graphRecordingEnabled = NO;
            if (recordingSink) {
                recordingSink.enabled = NO;
            }
        }
    });
}

// ─── Phase 6E.2B: Graph-backed photo capture ─────────────────────────────────
//
// Arming protocol:
//   1. Resolve "camera_photo_sink" from the current node map.
//   2. Call armWithURL:completion:error: on the photo sink.
//   3. Schedule a 3-second timeout via dispatch_after on _sessionQueue.
//      If the timeout fires and the request is still pending, cancel it
//      with GRAPH_PHOTO_TIMEOUT.
//
// Thread-safety:
//   Serialized via dispatch_sync on _sessionQueue.
//   MUST NOT be called from _sessionQueue (deadlock).
//   The timeout block runs on _sessionQueue; it checks _invalidated before
//   calling cancelPendingRequestWithError:.
//
// Graph-rebuild safety:
//   After a rebuild, _nodes points to a fresh node map with a new
//   VGPhotoSinkNode that has no pending request. The old node's pending
//   request is cancelled by invalidate propagation through the old scheduler.

- (BOOL)armPhotoCapture:(NSString *)path
             completion:(void (^)(NSString *_Nullable, NSError *_Nullable))completion
                  error:(NSError *_Nullable *_Nullable)outError {
    __block BOOL success = NO;
    __block NSError *innerError = nil;

    dispatch_sync(_sessionQueue, ^{
        if (atomic_load(&self->_invalidated)) {
            innerError = [NSError errorWithDomain:@"VGCameraGraphSession"
                                             code:200
                                         userInfo:@{
                NSLocalizedDescriptionKey: @"armPhotoCapture: session is invalidated."
            }];
            return;
        }

        VGPhotoSinkNode *photoSink =
            (VGPhotoSinkNode *)self->_nodes[@"camera_photo_sink"];
        if (!photoSink) {
            innerError = [NSError errorWithDomain:@"VGCameraGraphSession"
                                             code:201
                                         userInfo:@{
                NSLocalizedDescriptionKey: @"armPhotoCapture: camera_photo_sink "
                                           "not found in node map."
            }];
            return;
        }

        NSError *armError = nil;
        BOOL armed = [photoSink armWithURL:path
                               completion:completion
                                    error:&armError];
        if (!armed) {
            innerError = armError;
            return;
        }

        // Schedule a 3-second timeout. If the latch has not fired by then,
        // cancel the pending request with GRAPH_PHOTO_TIMEOUT.
        // The timeout block captures photoSink strongly — even if a graph
        // rebuild replaces _nodes, the timeout acts on the correct instance.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
            self->_sessionQueue,
            ^{
                if (atomic_load(&self->_invalidated)) {
                    return;
                }
                if (![photoSink hasPendingRequest]) {
                    return;
                }
                NSError *timeoutError = [NSError errorWithDomain:@"VGPhotoSinkNode"
                                                           code:5
                                                       userInfo:@{
                    NSLocalizedDescriptionKey: @"GRAPH_PHOTO_TIMEOUT: "
                                               "No processed frame arrived within 3 seconds."
                }];
                [photoSink cancelPendingRequestWithError:timeoutError];
            });

        success = YES;
    });

    if (!success && outError && innerError) {
        *outError = innerError;
    }
    return success;
}

// ─── Phase 6C.2B: In-place hot parameter updates ─────────────────────────────
//
// Validation: strictly enforces { "beauty": { "intensity": <number> } }.
// Any other shape is rejected with UNSUPPORTED_TRANSACTION_POLICY before
// touching the session queue.
//
// Node lookup: iterates _currentFilterChain which holds the live concrete
// filter node instances (VanguardBeautyFilterNode or BeautyV2FilterGroup)
// as constructed by setCameraFilterChainFromSpecs:. No VGLegacyFilterAdapter
// unwrapping is needed or present — _currentFilterChain never contains adapters.
//
// Queue: all node access and intensity writes are serialized inside
// dispatch_sync(_sessionQueue). This is mutually exclusive with graph rebuild,
// teardown, recording enable/disable, and photo capture arming.
//
// MUST NOT be called from _sessionQueue — dispatch_sync would deadlock.

- (BOOL)applyHotParameterUpdates:(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)updates
                            error:(NSError * _Nullable * _Nullable)outError
{
    if (outError) *outError = nil;

    // ── Empty updates: no-op success ──────────────────────────────────────────
    // Swift caller handles empty-payload short-circuit before calling us,
    // but guard here defensively.
    if (!updates || updates.count == 0) {
        return YES;
    }

    // ── Phase 6C.2B policy: exactly one effect key — "beauty" ─────────────────
    if (updates.count != 1 || !updates[@"beauty"]) {
        if (outError) {
            NSString *badEffects = [updates.allKeys componentsJoinedByString:@", "];
            *outError = [NSError
                errorWithDomain:@"UNSUPPORTED_TRANSACTION_POLICY"
                           code:1
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:
                        @"applyHotParameterUpdates: only {beauty:{intensity}} is supported "
                         "in Phase 6C.2B. Received effects: %@.", badEffects]
            }];
        }
        return NO;
    }

    NSDictionary<NSString *, id> *beautyUpdates = updates[@"beauty"];

    // ── Phase 6C.2B policy: exactly one param key — "intensity" ───────────────
    if (beautyUpdates.count != 1 || !beautyUpdates[@"intensity"]) {
        if (outError) {
            NSString *badParams = [beautyUpdates.allKeys componentsJoinedByString:@", "];
            *outError = [NSError
                errorWithDomain:@"UNSUPPORTED_TRANSACTION_POLICY"
                           code:2
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:
                        @"applyHotParameterUpdates: only 'intensity' is a supported "
                         "hot parameter for beauty in Phase 6C.2B. Received: %@.", badParams]
            }];
        }
        return NO;
    }

    id rawIntensity = beautyUpdates[@"intensity"];

    // ── Validate that the value is numeric ────────────────────────────────────
    if (![rawIntensity respondsToSelector:@selector(floatValue)]) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"UNSUPPORTED_TRANSACTION_POLICY"
                           code:3
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    @"applyHotParameterUpdates: beauty.intensity value must be numeric."
            }];
        }
        return NO;
    }

    // ── Defensive clamp [0.0, 1.0] ───────────────────────────────────────────
    // Dart already clamps via VGParameterDescriptor, but native must not assume
    // callers are well-behaved (e.g. direct plugin calls, future bridging).
    float clamped = fminf(1.0f, fmaxf(0.0f, [rawIntensity floatValue]));

    // ── Serialize on session queue ────────────────────────────────────────────
    __block BOOL success = NO;
    __block NSError *innerError = nil;

    dispatch_sync(_sessionQueue, ^{
        // Guard: session must not be invalidated.
        if (atomic_load(&self->_invalidated)) {
            innerError = [NSError
                errorWithDomain:@"HOT_UPDATE_FAIL"
                           code:400
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    @"applyHotParameterUpdates: session is invalidated."
            }];
            return;
        }

        // ── Iterate _currentFilterChain ───────────────────────────────────────
        // _currentFilterChain holds the concrete filter node instances
        // (VanguardBeautyFilterNode or BeautyV2FilterGroup) — no adapter
        // wrapping is needed. These are the exact same objects the render loop
        // accesses through VGLegacyFilterAdapter, so writing intensity here is
        // immediately visible to the next frame's processEnvelope: call.
        BOOL foundBeautyNode = NO;
        for (id node in self->_currentFilterChain) {
            if ([node isKindOfClass:[VanguardBeautyFilterNode class]]) {
                ((VanguardBeautyFilterNode *)node).intensity = clamped;
                foundBeautyNode = YES;
            } else if ([node isKindOfClass:[BeautyV2FilterGroup class]]) {
                ((BeautyV2FilterGroup *)node).intensity = clamped;
                foundBeautyNode = YES;
            }
        }

        if (!foundBeautyNode) {
            innerError = [NSError
                errorWithDomain:@"HOT_UPDATE_FAIL"
                           code:404
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    @"applyHotParameterUpdates: no active beauty filter node found "
                     "in the current filter chain."
            }];
            return;
        }

        // [Beauty-Still]: Update the active spec snapshot with the new intensity
        // so the next high-res still capture uses the current slider value.
        if (self->_activeFilterSpecs.count > 0) {
            NSMutableArray<NSDictionary *> *updatedSpecs =
                [NSMutableArray arrayWithCapacity:self->_activeFilterSpecs.count];
            for (NSDictionary *spec in self->_activeFilterSpecs) {
                NSString *type = spec[@"type"];
                if ([type isEqualToString:@"beauty"]) {
                    NSMutableDictionary *specCopy = [spec mutableCopy];
                    NSDictionary *oldParams = spec[@"parameters"];
                    NSMutableDictionary *paramsCopy =
                        [oldParams isKindOfClass:[NSDictionary class]]
                        ? [oldParams mutableCopy]
                        : [NSMutableDictionary dictionary];
                    paramsCopy[@"intensity"] = @(clamped);
                    specCopy[@"parameters"] = [paramsCopy copy];
                    [updatedSpecs addObject:[specCopy copy]];
                } else {
                    [updatedSpecs addObject:spec];
                }
            }
            self->_activeFilterSpecs = [updatedSpecs copy];
        }

        success = YES;
    });

    if (!success && outError && innerError) {
        *outError = innerError;
    }
    return success;
}

// ─── UFM green screen: read-only native diagnostics ──────────────────────────
//
// Lookup source is _currentFilterChain only — the concrete node instances
// committed by the last successful _applyFilterChainInternal:. An empty
// setCameraFilterChainFromSpecs: commits a nil chain, so after a clear there
// is nothing to find and the result is nil; no node reference is cached here.
// Serialized on _sessionQueue so it cannot race a rebuild, clear or teardown.
// MUST NOT be called from _sessionQueue (dispatch_sync would deadlock).

- (nullable NSDictionary<NSString *, id> *)greenScreenDiagnosticsSnapshot {
    __block NSDictionary<NSString *, id> *snapshot = nil;
    dispatch_sync(_sessionQueue, ^{
        if (atomic_load(&self->_invalidated)) {
            return;
        }
        for (id node in self->_currentFilterChain) {
            if ([node isKindOfClass:[VGGreenScreenFilterNode class]]) {
                snapshot = [(VGGreenScreenFilterNode *)node diagnosticsSnapshot];
                return;
            }
        }
    });
    return snapshot;
}

// ─── UFM camera graph: read-only cumulative filter-chain timing ──────────────
// Two sequential, never-nested reads: _sessionQueue for the committed spec
// types, then _graphExecutionQueue for the _fc* aggregates (nesting would
// risk the _sessionQueue-must-never-block-on-graph-queue deadlock documented
// on -invalidate). A clear landing between the two reads is harmless — the
// graph read then sees _fcTimingActive == NO and returns nil.
// MUST NOT be called from _sessionQueue or _graphExecutionQueue (deadlock).

- (nullable NSDictionary<NSString *, id> *)filterChainDiagnosticsSnapshot {
    __block NSArray<NSString *> *activeTypes = nil;
    dispatch_sync(_sessionQueue, ^{
        if (atomic_load(&self->_invalidated)) {
            return;
        }
        NSArray<NSDictionary *> *specs = self->_activeFilterSpecs;
        if (specs.count == 0) {
            return;
        }
        NSMutableArray<NSString *> *types = [NSMutableArray arrayWithCapacity:specs.count];
        for (NSDictionary *spec in specs) {
            id type = spec[@"type"];
            [types addObject:[type isKindOfClass:[NSString class]] ? (NSString *)type : @"(unknown)"];
        }
        activeTypes = [types copy];
    });
    if (activeTypes.count == 0) {
        return nil;
    }

    __block BOOL     active     = NO;
    __block uint64_t frameCount = 0;
    __block uint64_t dropped    = 0;
    __block double   lastMs     = 0.0;
    __block double   sumMs      = 0.0;
    __block double   maxMs      = 0.0;
    dispatch_sync(_graphExecutionQueue, ^{
        active     = self->_fcTimingActive;
        frameCount = self->_fcGraphFrameCount;
        lastMs     = self->_fcLastGraphTotalMs;
        sumMs      = self->_fcSumGraphTotalMs;
        maxMs      = self->_fcMaxGraphTotalMs;
        const uint64_t droppedNow = atomic_load(&self->_graphDroppedBusyCounter);
        dropped = (droppedNow >= self->_fcDroppedBusyBase)
                      ? (droppedNow - self->_fcDroppedBusyBase) : 0;
    });
    if (!active) {
        return nil;
    }

    const double meanMs = frameCount > 0 ? sumMs / (double)frameCount : 0.0;
    return @{
        @"proofLevel":        @"filterChainTimingV1",
        @"activeFilterCount": @(activeTypes.count),
        @"activeFilterTypes": activeTypes,
        @"graphFrameCount":   @(frameCount),
        @"droppedBusyCount":  @(dropped),
        @"lastGraphTotalMs":  @(lastMs),
        @"meanGraphTotalMs":  @(meanMs),
        @"maxGraphTotalMs":   @(maxMs),
        @"timingBoundary":    @"VGCameraGraphSession graphExecutionQueue around scheduler.didReceiveRawFrame "
                               "(scheduler traversal + active filter nodes + synchronous sink presentEnvelope; "
                               "accepted frames only)",
        @"nonClaims":         @[
            @"does not provide per-node Beauty V2 cost",
            @"does not include frames dropped by the in-flight backpressure guard",
            @"does not include capture, rotation, or post-return display latency",
        ],
    };
}

- (void)invalidate {
    dispatch_sync(_sessionQueue, ^{
        if (atomic_exchange(&self->_invalidated, YES)) {
            return;
        }

        // 3G-C: Clear renderer.frameDelegate while still on the session queue.
        // The session is the frameDelegate; clearing it prevents _onVideoFrame:
        // from calling our didReceiveRawFrame: after teardown begins.
        VanguardMetalRenderer *renderer = self->_renderer;
        if (renderer) {
            if (renderer.frameDelegate == self) {
                renderer.frameDelegate = nil;
            }
        }

        [self->_scheduler invalidate];

        if (self->_sessionPool) {
            CVPixelBufferPoolRelease(self->_sessionPool);
            self->_sessionPool = NULL;
        }
        if (self->_sessionPoolBytes > 0) {
            [[VGResourceAllocator sharedInstance] reportPoolReleased:self->_sessionPoolBytes];
            self->_sessionPoolBytes = 0;
        }

        self->_scheduler = nil;
        self->_context = nil;

        // Phase 6E.1D.1 (Opus §Issue3): Defensively clear the graph recording
        // flag and disable the sink before nil-ing _source and _nodes. Prevents
        // any in-flight processed frames from appending after teardown starts.
        // Must be done before _nodes = nil (sink lookup) and _source = nil.
        if (self->_source) {
            self->_source.graphRecordingEnabled = NO;
        }
        VGRecordingSinkNode *recordingSink =
            (VGRecordingSinkNode *)self->_nodes[@"camera_recording_sink"];
        if (recordingSink) {
            recordingSink.enabled = NO;
        }

        // [Beauty-Still]: Clear spec snapshot on teardown.
        self->_activeFilterSpecs = nil;

        self->_nodes = nil;
        self->_source = nil;
    });

    // 3G-C: After the session queue has cleared frameDelegate (preventing new
    // enqueues), drain the graph execution queue synchronously. This ensures any
    // in-flight async block that captured a scheduler reference has finished and
    // released its retained buffer before invalidate returns.
    //
    // We must NOT hold _sessionQueue while doing this (deadlock risk if the
    // async block tries to dispatch_sync back). The dispatch_sync here is on a
    // *different* queue (_graphExecutionQueue), which is safe.
    dispatch_sync(_graphExecutionQueue, ^{
        // Intentionally empty — just draining any queued or in-flight block.
    });
}

- (void)dealloc {
    if (_sessionPool) {
        CVPixelBufferPoolRelease(_sessionPool);
        _sessionPool = NULL;
    }
    if (_sessionPoolBytes > 0) {
        [[VGResourceAllocator sharedInstance] reportPoolReleased:_sessionPoolBytes];
        _sessionPoolBytes = 0;
    }
}

- (BOOL)_queryDimensionsWidth:(size_t *)outWidth height:(size_t *)outHeight {
    if (![_source respondsToSelector:@selector(captureSession)]) {
        return NO;
    }
    AVCaptureSession *session = _source.captureSession;
    if (!session) {
        return NO;
    }
    
    AVCaptureDevice *device = nil;
    for (AVCaptureInput *input in session.inputs) {
        if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
            AVCaptureDeviceInput *deviceInput = (AVCaptureDeviceInput *)input;
            if ([deviceInput.device hasMediaType:AVMediaTypeVideo]) {
                device = deviceInput.device;
                break;
            }
        }
    }
    if (!device) {
        return NO;
    }
    
    AVCaptureVideoDataOutput *videoOutput = nil;
    for (AVCaptureOutput *output in session.outputs) {
        if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
            videoOutput = (AVCaptureVideoDataOutput *)output;
            break;
        }
    }
    if (!videoOutput) {
        return NO;
    }
    
    CMVideoFormatDescriptionRef formatDesc = device.activeFormat.formatDescription;
    if (!formatDesc) {
        return NO;
    }
    
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(formatDesc);
    size_t width = dims.width;
    size_t height = dims.height;
    
    AVCaptureConnection *connection = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (connection) {
        if (connection.videoOrientation == AVCaptureVideoOrientationPortrait ||
            connection.videoOrientation == AVCaptureVideoOrientationPortraitUpsideDown) {
            size_t temp = width;
            width = height;
            height = temp;
        }
    }
    
    if (width == 0 || height == 0) {
        return NO;
    }
    
    if (outWidth) *outWidth = width;
    if (outHeight) *outHeight = height;
    return YES;
}

- (id)_sessionPool {
    return (__bridge id)_sessionPool;
}

- (NSUInteger)_sessionPoolBytes {
    return _sessionPoolBytes;
}

+ (BOOL)isGraphModeEnabled {
#if defined(VG_USE_CAMERA_GRAPH) && (VG_USE_CAMERA_GRAPH != 0)
    return YES;
#else
    return NO;
#endif
}

// ─── VGFrameDelegate (Phase 6A-3G-C) ─────────────────────────────────────────
//
// This is the async boundary between the AVCapture delegate queue
// (com.vanguard.capture) and the graph execution queue
// (com.vanguard.cameraGraphExecution).
//
// Called by VanguardMetalRenderer._onVideoFrame: on com.vanguard.capture
// (a serial queue). Must return quickly — no GPU work, no filter execution.
//
// Ownership:
//   envelope.payload.videoBuffer: source-owned (+1). We add our own +1 via
//   CVPixelBufferRetain before the async dispatch so the buffer stays alive
//   after _onVideoFrame: releases its references. The async block releases
//   our +1 after [scheduler didReceiveRawFrame:] returns.
//
// Backpressure:
//   If _graphInFlight is already YES (previous frame still processing),
//   we drop the incoming frame and return immediately. This prevents frame
//   backlog on the execution queue and matches the AVFoundation drop-latest
//   model (alwaysDiscardsLateVideoFrames companion on the CPU side).
- (void)didReceiveRawFrame:(VGFrameEnvelope)envelope {
    // ── Guard: invalidated ────────────────────────────────────────────────────
    if (atomic_load(&_invalidated)) return;

    // ── Guard: no buffer ──────────────────────────────────────────────────────
    CVPixelBufferRef rawBuffer = envelope.payload.videoBuffer;
    if (!rawBuffer) return;

    // ── Backpressure: drop-latest ─────────────────────────────────────────────
    // Atomically set in-flight from NO→YES. If it was already YES, a block is
    // already executing — drop this frame.
    BOOL expected = NO;
    if (!atomic_compare_exchange_strong(&_graphInFlight, &expected, YES)) {
        // Frame dropped — graph execution is busy.
        // Counts toward filterChainDiagnosticsSnapshot's droppedBusyCount delta.
        atomic_fetch_add(&_graphDroppedBusyCounter, 1);
        return;
    }

    // ── Retain buffer for async lifetime ─────────────────────────────────────
    // _onVideoFrame: will release its references to rawFrame / frameToDeliver
    // after we return. We must hold our own +1 until the async block finishes.
    CVPixelBufferRetain(rawBuffer);

    // ── Capture scheduler at enqueue time ────────────────────────────────────
    // Read _scheduler under no explicit lock — assignment is done on
    // _sessionQueue which is separate from the capture queue. On ARM64, object
    // pointer reads are atomic. The strong local reference prevents dealloc
    // before the block executes.
    VGGraphSchedulerV2 *scheduler = _scheduler;

    // Build a retained envelope for the async block. The buffer pointer is the
    // same rawBuffer we just retained; everything else copies by value.
    VGFrameEnvelope asyncEnvelope = envelope;
    asyncEnvelope.payload.videoBuffer = rawBuffer; // already +1 from our retain

    __weak __typeof(self) weakSelf = self;
    dispatch_async(_graphExecutionQueue, ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;

        // ── Execute graph if session is still live ─────────────────────────
        // scheduler may be nil if invalidate was called between enqueue and here.
        if (strongSelf && !atomic_load(&strongSelf->_invalidated) && scheduler) {
            // Brackets the synchronous scheduler call: covers scheduler +
            // every active filter + the synchronous sink present for this
            // frame. Tracked only while a chain is committed. Plain stores are
            // safe — _fc* state is owned by this serial queue.
            const BOOL timeFrame = strongSelf->_fcTimingActive;
            const uint64_t t0 = timeFrame ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0;
            [scheduler didReceiveRawFrame:asyncEnvelope];
            if (timeFrame) {
                const uint64_t t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                const double graphTotalMs = (double)(t1 - t0) / 1.0e6;
                strongSelf->_fcGraphFrameCount  += 1;
                strongSelf->_fcLastGraphTotalMs  = graphTotalMs;
                strongSelf->_fcSumGraphTotalMs  += graphTotalMs;
                if (graphTotalMs > strongSelf->_fcMaxGraphTotalMs) {
                    strongSelf->_fcMaxGraphTotalMs = graphTotalMs;
                }
            }
        }

        // ── Release our +1 retain ─────────────────────────────────────────
        // The scheduler has already called presentEnvelope: (synchronously),
        // which retained the buffer for the renderer. We now release our +1.
        CVPixelBufferRelease(rawBuffer);

        // ── Clear in-flight flag ──────────────────────────────────────────
        if (strongSelf) {
            atomic_store(&strongSelf->_graphInFlight, NO);
        }
    });
}

@end
