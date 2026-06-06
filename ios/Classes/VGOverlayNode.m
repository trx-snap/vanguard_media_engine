// VGOverlayNode.m
// vanguard_media_engine — Phase 8.5 / Phase 8.7
//
// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 8.5 — NATIVE OVERLAY NODE PASS-THROUGH STUB
// PHASE 8.7 — EXPORT-ONLY DEBUG RECTANGLE RENDERING
// ═══════════════════════════════════════════════════════════════════════════════
//
// Implementation of VGOverlayNode.
//
// Phase 8.5: Established VGTransformNode conformance and defensive parameter
// parsing. Pass-through processEnvelope:device:.
//
// Phase 8.7: Adds export-only debug rectangle rendering inside
// processEnvelope:device:. Uses CoreImage to composite solid semi-transparent
// red rectangles for each active overlay over the input frame. This is a visual
// proof slice only — no text, no emoji, no sticker/image loading.
//
// Key architectural invariants (Phase 8.7):
//   - When no overlays are active for the current PTS, the original envelope is
//     returned EXACTLY unchanged (zero buffer allocation, zero CoreImage work).
//   - When active overlays exist, a NEW CVPixelBuffer is allocated via
//     CVPixelBufferCreate (+1). The scheduler detects (newBuffer != frame) and
//     owns / releases the returned buffer after sink delivery (RR-36).
//   - The input CVPixelBuffer is NEVER mutated in place.
//   - envelope.metadata is NEVER touched — the C struct copy preserves the
//     pointer; the scheduler manages its lifecycle (DEC-102).
//   - CIContext is a shared static singleton (dispatch_once), matching the
//     VGTimelineCompositorNode pattern.
//   - CGColorSpaceCreateDeviceRGB() is used for all renders and released after
//     each frame (matching _VGTCNBlendBuffers / _VGTCNCompositePiP patterns).
//   - On any internal failure (buffer alloc, nil image), falls back to
//     returning the original envelope — export is never failed by rendering.
//
// This file does NOT import:
//   VanguardMediaEnginePlugin, VGEditorGraphFactory,
//   VGTimelinePlaybackGraphFactory, VanguardGraphRuntime,
//   VGGraphSchedulerV2, VGTimelineCompositorNode,
//   VGTimelineExportHelper, VGExportScheduler,
//   any Metal shader, any Flutter type, any AVFoundation type, CoreText.
//
// All VGNode protocol requirements follow the VGLegacyFilterAdapter pattern.

#import "VGOverlayNode.h"

// ─── Phase 8.1 canvas descriptor ─────────────────────────────────────────────
#import <UMF/VGCanvasDescriptor.h>

// ─── Phase 8.3 overlay descriptor ────────────────────────────────────────────
#import <UMF/VGOverlayDescriptor.h>

// ─── UMF graph context (required by VGNode lifecycle) ────────────────────────
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGMediaFormat.h>
#import <UMF/VGNode.h>

// ─── Phase 8.7: CoreImage / CoreVideo / CoreMedia for rendering ───────────────
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

// ─── System ──────────────────────────────────────────────────────────────────
#import <os/log.h>
#include <math.h>

// ─── Module-private log ───────────────────────────────────────────────────────
static os_log_t sOverlayNodeLog;

// ─── Phase 8.7: Shared CIContext singleton ────────────────────────────────────
//
// Lazily initialized on first use via dispatch_once. Uses nil options which
// selects Metal/GPU on device and falls back to CPU in simulator.
// Same pattern as _VGTCNSharedCIContext in VGTimelineCompositorNode.
//
// RR-143: CIContext with nil options — Metal/GPU on device; CPU fallback in sim.
static CIContext *_VGOverlaySharedCIContext(void) {
    static CIContext *context = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        context = [CIContext contextWithOptions:nil];
    });
    return context;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - @implementation VGOverlayNode
// ─────────────────────────────────────────────────────────────────────────────

@implementation VGOverlayNode {
    NSString                       *_nodeId;
    BOOL                            _enabled;
    VGCanvasDescriptor             *_canvas;
    NSArray<VGOverlayDescriptor *> *_overlays;
}

// ─── Module initialization ────────────────────────────────────────────────────

+ (void)initialize {
    if (self == [VGOverlayNode class]) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            sOverlayNodeLog = os_log_create("com.vanguard.engine", "VGOverlayNode");
        });
    }
}

// ─── Designated initializer ───────────────────────────────────────────────────

- (instancetype)initWithNodeId:(NSString *)nodeId
                    parameters:(nullable NSDictionary<NSString *, id> *)parameters
                         ports:(nullable NSArray<VGMediaPort *> *)ports
                         error:(NSError * _Nullable * _Nullable)outError {
    NSParameterAssert(nodeId != nil);

    self = [super init];
    if (!self) return nil;

    _nodeId = [nodeId copy];

    // ── enabled ──────────────────────────────────────────────────────────────
    // Default YES. If parameters supplies an NSNumber for "enabled", honour it.
    id enabledRaw = parameters[@"enabled"];
    if ([enabledRaw isKindOfClass:[NSNumber class]]) {
        _enabled = [(NSNumber *)enabledRaw boolValue];
    } else {
        _enabled = YES;
    }

    // ── canvas ───────────────────────────────────────────────────────────────
    // Defensive parse: NSDictionary → VGCanvasDescriptor.
    // Any missing or non-dictionary value falls back to the UMF default canvas.
    id canvasRaw = parameters[@"canvas"];
    if ([canvasRaw isKindOfClass:[NSDictionary class]]) {
        VGCanvasDescriptor *parsed =
            [VGCanvasDescriptor fromDictionary:(NSDictionary *)canvasRaw];
        _canvas = parsed ?: [VGCanvasDescriptor defaultCanvas];
    } else {
        _canvas = [VGCanvasDescriptor defaultCanvas];
    }

    // ── overlays ─────────────────────────────────────────────────────────────
    // Defensive parse: NSArray<NSDictionary *> → NSArray<VGOverlayDescriptor *>.
    // Non-array values → empty array.
    // Non-dictionary elements within the array → skipped (defensive).
    id overlaysRaw = parameters[@"overlays"];
    if ([overlaysRaw isKindOfClass:[NSArray class]]) {
        NSArray *rawArray = (NSArray *)overlaysRaw;
        NSMutableArray<VGOverlayDescriptor *> *parsed =
            [NSMutableArray arrayWithCapacity:rawArray.count];
        for (id element in rawArray) {
            if (![element isKindOfClass:[NSDictionary class]]) {
                os_log_debug(sOverlayNodeLog,
                             "[VGOverlayNode] overlays: skipping non-dictionary element "
                             "(class=%{public}@)",
                             NSStringFromClass([element class]));
                continue;
            }
            VGOverlayDescriptor *descriptor =
                [VGOverlayDescriptor fromDictionary:(NSDictionary *)element];
            if (descriptor) {
                [parsed addObject:descriptor];
            }
        }
        _overlays = [parsed copy];
    } else {
        _overlays = @[];
    }

    // ── outError ─────────────────────────────────────────────────────────────
    // No parse failure is fatal. Always clear the error output.
    if (outError) {
        *outError = nil;
    }

    os_log_debug(sOverlayNodeLog,
                 "[VGOverlayNode] init: nodeId=%{public}@ enabled=%d "
                 "canvas=%ldx%ld overlays=%lu",
                 _nodeId, (int)_enabled,
                 (long)_canvas.width, (long)_canvas.height,
                 (unsigned long)_overlays.count);

    return self;
}

// ─── VGNode — Identity ────────────────────────────────────────────────────────

- (NSString *)nodeId {
    return _nodeId;
}

- (NSString *)nodeClass {
    return NSStringFromClass([self class]);
}

- (VGNodeRole)nodeRole {
    return VGNodeRoleFilter;
}

// ─── VGNode — Port declaration ────────────────────────────────────────────────

- (NSArray<VGMediaPort *> *)declaredPorts {
    // Standard single-input / single-output video transform port pair.
    // Matches the port names used by VGLegacyFilterAdapter.
    return @[
        [VGMediaPort inputPort:@"video_in"
                     mediaType:VGMediaTypeVideo
                      required:YES],
        [VGMediaPort outputPort:@"video_out"
                      mediaType:VGMediaTypeVideo],
    ];
}

// ─── VGNode — Lifecycle ───────────────────────────────────────────────────────

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    // Phase 8.7: no persistent async resources to warm up.
    // The CIContext is a shared static singleton; no per-instance setup needed.
    // Context is accepted for API symmetry and future use.
    (void)context;
    os_log_debug(sOverlayNodeLog,
                 "[VGOverlayNode] prepareWithContext: nodeId=%{public}@", _nodeId);
    completion(nil);
}

- (void)invalidate {
    // Phase 8.7: no persistent resources held by this instance.
    // The CIContext is shared and must not be released here.
    // CVPixelBufferCreate allocations are owned by the scheduler after return.
    os_log_debug(sOverlayNodeLog,
                 "[VGOverlayNode] invalidate: nodeId=%{public}@", _nodeId);
}

// ─── VGNode — Format negotiation (stub) ──────────────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Stub. Format negotiation deferred per VGLegacyFilterAdapter Phase 3 precedent.
    (void)portId;
    (void)inputFormats;
    return nil;
}

// ─── VGTransformNode — Control ────────────────────────────────────────────────

- (BOOL)enabled {
    return _enabled;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
}

- (float)estimatedGPUCostMs {
    // Phase 8.7: CoreImage compositing per frame. Conservative upper bound.
    // Measured at 1080p; one CISourceOverCompositing pass per active overlay.
    // DEC-58: declared upper bound for GPU budget enforcement.
    return 2.0f;
}

// ─── VGTransformNode — Frame processing ──────────────────────────────────────
//
// Phase 8.7: Export-only debug rectangle rendering.
//
// Fast path (no active overlays):
//   Returns the original envelope EXACTLY unchanged. No buffer allocation.
//   No CoreImage invocation. Sub-microsecond.
//
// Render path (active overlays exist):
//   1. Wraps the input CVPixelBuffer in a CIImage.
//   2. For each active overlay (sorted by zIndex ascending), composites a
//      solid semi-transparent red CIImage rectangle using CISourceOverCompositing.
//   3. Allocates a new CVPixelBuffer via CVPixelBufferCreate (+1).
//   4. Renders the composited CIImage into the new buffer via CIContext.
//   5. Returns a copy of the input envelope with only payload.videoBuffer
//      replaced by the new buffer pointer.
//
// Buffer ownership (RR-36):
//   The new buffer is returned at +1 from CVPixelBufferCreate.
//   VGExportScheduler detects (newBuffer != frame) and takes ownership.
//   VGOverlayNode does NOT retain or release the output buffer.
//
// Metadata lifecycle (DEC-102):
//   The envelope is a C struct — copying it by value preserves the metadata
//   pointer. VGOverlayNode does NOT call any metadata helper functions.
//   The scheduler manages metadata release via VGFrameEnvelopeReleaseMetadata.
//
// Failure fallback:
//   On any failure (nil input buffer, non-finite PTS, buffer alloc failure,
//   nil CIImage), the original envelope is returned unchanged. Export never
//   fails due to overlay rendering errors.

- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                             device:(id<MTLDevice>)device {
    // ── Gate: disabled ────────────────────────────────────────────────────────
    if (!_enabled) {
        return envelope;
    }

    // ── Gate: nil input buffer ────────────────────────────────────────────────
    CVPixelBufferRef inputBuffer = (CVPixelBufferRef)envelope.payload.videoBuffer;
    if (!inputBuffer) {
        return envelope;
    }

    // ── Gate: non-finite PTS ──────────────────────────────────────────────────
    // envelope.pts is set to request.requestedPTS by VGTimelineCompositorNode,
    // which equals CMTimeMake(_frameIndex, _fps) from VGExportScheduler.
    // This is always valid in export, but guard defensively.
    double ptsSeconds = CMTimeGetSeconds(envelope.pts);
    if (!isfinite(ptsSeconds)) {
        os_log_debug(sOverlayNodeLog,
                     "[VGOverlayNode][8.7] non-finite PTS — pass-through");
        return envelope;
    }

    // ── Filter active overlays ────────────────────────────────────────────────
    // An overlay is active when:
    //   ptsSeconds >= startTimeSeconds
    //   ptsSeconds <  startTimeSeconds + durationSeconds
    //   durationSeconds > 0
    //   width > 0, height > 0, scale > 0, opacity > 0
    NSMutableArray<VGOverlayDescriptor *> *activeOverlays =
        [NSMutableArray arrayWithCapacity:_overlays.count];

    for (VGOverlayDescriptor *overlay in _overlays) {
        if (overlay.durationSeconds <= 0.0) continue;
        if (overlay.width <= 0.0)           continue;
        if (overlay.height <= 0.0)          continue;
        if (overlay.scale <= 0.0)           continue;
        if (overlay.opacity <= 0.0)         continue;

        double start = overlay.startTimeSeconds;
        double end   = start + overlay.durationSeconds;

        if (ptsSeconds >= start && ptsSeconds < end) {
            [activeOverlays addObject:overlay];
        }
    }

    // ── Fast path: no active overlays ─────────────────────────────────────────
    // Return the original envelope EXACTLY unchanged. No allocation. No CoreImage.
    if (activeOverlays.count == 0) {
        return envelope;
    }

    // ── Sort by zIndex ascending (lower zIndex = further back = rendered first)
    [activeOverlays sortWithOptions:NSSortStable
                    usingComparator:^NSComparisonResult(VGOverlayDescriptor *a,
                                                        VGOverlayDescriptor *b) {
        if (a.zIndex < b.zIndex) return NSOrderedAscending;
        if (a.zIndex > b.zIndex) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    // ── Output buffer dimensions from the actual input buffer ─────────────────
    size_t outputWidth  = CVPixelBufferGetWidth(inputBuffer);
    size_t outputHeight = CVPixelBufferGetHeight(inputBuffer);
    if (outputWidth == 0 || outputHeight == 0) {
        return envelope;
    }

    // ── Canvas → output coordinate scale factors ──────────────────────────────
    // Phase 8.7: simple scale factors if canvas dimensions differ from output.
    // If canvas dimensions are 0 (pathological default), treat as 1:1.
    double canvasW = (double)MAX(1, _canvas.width);
    double canvasH = (double)MAX(1, _canvas.height);
    double scaleX  = (double)outputWidth  / canvasW;
    double scaleY  = (double)outputHeight / canvasH;

    // ── Build CoreImage accumulator starting from input buffer ────────────────
    CIImage *accumulator = [CIImage imageWithCVPixelBuffer:inputBuffer];
    if (!accumulator) {
        os_log_error(sOverlayNodeLog,
                     "[VGOverlayNode][8.7] CIImage from input buffer returned nil — pass-through");
        return envelope;
    }

    // ── Composite each active overlay ─────────────────────────────────────────
    for (VGOverlayDescriptor *overlay in activeOverlays) {
        // ── Geometry ─────────────────────────────────────────────────────────
        // Descriptor coordinates: top-left canvas pixels.
        // CoreImage coordinates: bottom-left origin.
        double rectW = overlay.width  * overlay.scale * scaleX;
        double rectH = overlay.height * overlay.scale * scaleY;

        // Skip degenerate rectangles (after scaling).
        if (rectW < 1.0 || rectH < 1.0) continue;

        double rectXLeft = overlay.translationX * scaleX;
        double rectYTop  = overlay.translationY * scaleY;

        // Y-flip: CoreImage origin is bottom-left.
        // ciY is the Y coordinate of the bottom edge of the rectangle in CI space.
        double ciY = (double)outputHeight - rectYTop - rectH;

        CGRect overlayRect = CGRectMake((CGFloat)rectXLeft, (CGFloat)ciY,
                                        (CGFloat)rectW,     (CGFloat)rectH);

        // ── Debug solid color: semi-transparent red using overlay opacity ─────
        // Phase 8.7: visual proof color only. Real overlay content deferred.
        CIColor *debugColor = [CIColor colorWithRed:1.0
                                              green:0.0
                                               blue:0.0
                                              alpha:(CGFloat)overlay.opacity];
        CIImage *solidRect = [CIImage imageWithColor:debugColor];

        // Crop to the overlay rectangle bounds.
        CIImage *croppedRect = [solidRect imageByCroppingToRect:overlayRect];

        // ── Rotation (Phase 8.7 — simple implementation) ──────────────────────
        // Rotate around the rectangle's center point.
        // CGAffineTransformRotate uses radians; descriptor rotation is radians.
        // Note: VGOverlayDescriptor.rotation is clockwise-positive, while
        // CoreImage uses counter-clockwise-positive. Negate to correct.
        // If rotation is effectively zero, skip the transform for efficiency.
        if (fabs(overlay.rotation) > 1e-6) {
            CGFloat cx = (CGFloat)(rectXLeft + rectW * 0.5);
            CGFloat cy = (CGFloat)(ciY + rectH * 0.5);
            // Translate center to origin, rotate, translate back.
            CGAffineTransform t =
                CGAffineTransformMakeTranslation(cx, cy);
            t = CGAffineTransformRotate(t, -(CGFloat)overlay.rotation);
            t = CGAffineTransformTranslate(t, -cx, -cy);
            croppedRect = [croppedRect imageByApplyingTransform:t];
        }

        // ── Composite over accumulator (Porter-Duff source-over) ──────────────
        // CIImage.imageByCompositingOverImage: renders croppedRect on top.
        accumulator = [croppedRect imageByCompositingOverImage:accumulator];
        if (!accumulator) {
            os_log_error(sOverlayNodeLog,
                         "[VGOverlayNode][8.7] compositing returned nil — pass-through");
            return envelope;
        }
    }

    // ── Allocate output CVPixelBuffer ─────────────────────────────────────────
    // Use CVPixelBufferCreate (not pool) — matches VGTimelineCompositorNode style.
    // BGRA + Metal + IOSurface attributes for downstream renderer compatibility.
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey:         @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferMetalCompatibilityKey:      @YES,
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey:     @{},
    };

    CVPixelBufferRef outputBuffer = NULL;
    CVReturn cvStatus = CVPixelBufferCreate(kCFAllocatorDefault,
                                            outputWidth,
                                            outputHeight,
                                            kCVPixelFormatType_32BGRA,
                                            (__bridge CFDictionaryRef)attrs,
                                            &outputBuffer);
    if (cvStatus != kCVReturnSuccess || !outputBuffer) {
        os_log_error(sOverlayNodeLog,
                     "[VGOverlayNode][8.7] CVPixelBufferCreate failed (status=%d) — pass-through",
                     cvStatus);
        return envelope;
    }

    // ── Render the composited CIImage into the output buffer ──────────────────
    // colorSpace: CGColorSpaceCreateDeviceRGB() — avoids dark/underexposed output.
    // Same pattern as _VGTCNBlendBuffers and _VGTCNCompositePiP (Phase 7.x-Q3B).
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_VGOverlaySharedCIContext() render:accumulator
                        toCVPixelBuffer:outputBuffer
                                  bounds:CGRectMake(0, 0,
                                                    (CGFloat)outputWidth,
                                                    (CGFloat)outputHeight)
                              colorSpace:colorSpace];
    if (colorSpace) {
        CGColorSpaceRelease(colorSpace);
    }

    os_log(sOverlayNodeLog,
           "[VGOverlayNode][8.7] rendered: pts=%.3fs activeOverlays=%lu "
           "outputSize=%zux%zu",
           ptsSeconds, (unsigned long)activeOverlays.count,
           outputWidth, outputHeight);

    // ── Return new envelope with replaced video buffer ─────────────────────────
    // C struct copy by value — metadata pointer is preserved unchanged.
    // Do NOT call any metadata helper functions (DEC-102).
    // Do NOT CVPixelBufferRetain(outputBuffer) — the +1 from CVPixelBufferCreate
    // IS the scheduler's ownership. VGExportScheduler detects (newBuffer != frame)
    // and releases after sink delivery (RR-36).
    VGFrameEnvelope outputEnvelope = envelope;
    outputEnvelope.payload.videoBuffer = outputBuffer;
    return outputEnvelope;
}

// ─── Canvas and overlay accessors ─────────────────────────────────────────────

- (VGCanvasDescriptor *)canvas {
    return _canvas;
}

- (NSArray<VGOverlayDescriptor *> *)overlays {
    return _overlays;
}

@end
