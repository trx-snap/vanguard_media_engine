// VGOverlayNode.m
// vanguard_media_engine — Phase 8.5 / Phase 8.7 / Phase 8.8
//
// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 8.5 — NATIVE OVERLAY NODE PASS-THROUGH STUB
// PHASE 8.7 — EXPORT-ONLY DEBUG RECTANGLE RENDERING
// PHASE 8.8 — EXPORT-ONLY SIMPLE TEXT / EMOJI RENDERING
// ═══════════════════════════════════════════════════════════════════════════════
//
// Implementation of VGOverlayNode.
//
// Phase 8.5: Established VGTransformNode conformance and defensive parameter
// parsing. Pass-through processEnvelope:device:.
//
// Phase 8.7: Adds export-only debug rectangle rendering inside
// processEnvelope:device:. Uses CoreImage to composite solid semi-transparent
// red rectangles for each active overlay over the input frame.
//
// Phase 8.8: Replaces the debug rectangle with real text/emoji rendering for
// VGOverlayTypeText and VGOverlayTypeEmoji overlays whose textContent is
// non-empty. Text is rasterized via CGBitmapContextCreate + UIGraphicsPushContext
// + [NSString drawInRect:withAttributes:], converted to CIImage via
// imageWithCGImage:, and composited through the existing Phase 8.7 geometry,
// opacity, rotation, zIndex, and buffer path. The Phase 8.7 red debug rectangle
// is retained as fallback for:
//   - empty or nil textContent (any type)
//   - VGOverlayTypeSticker (asset resolver is Phase 8.9+)
//   - rasterization failure (nil CGContext / CGImage / CIImage)
// Each overlay body is wrapped in @autoreleasepool to drain CoreGraphics
// temporaries (UIFont, UIColor, NSDictionary attributes) before the runloop turns.
//
// Key architectural invariants (unchanged from Phase 8.7):
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

// ─── Phase 8.8: UIKit for text rasterization ─────────────────────────────────
// Used for UIFont, UIColor, UIGraphicsPushContext/Pop, and
// NSString drawInRect:withAttributes:. UIGraphicsImageRenderer and
// UIGraphicsBeginImageContext are NOT used — CGBitmapContextCreate gives
// explicit ownership and is safe on the background export serial queue.
#import <UIKit/UIKit.h>

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

// ─── Phase 8.8: Text rasterization helper ────────────────────────────────────
//
// _VGOverlayCreateTextImage:
//   Rasterizes overlay.textContent into a CIImage at the specified pixel size.
//
//   Technology choice (per Opus Phase 8.8 validation):
//     CGBitmapContextCreate gives explicit pixel format, byte stride,
//     and lifecycle control — safe from any background thread / GCD queue.
//     UIGraphicsPushContext makes the CGBitmapContext available to UIKit string
//     drawing methods (NSString UIKitAdditions) on the calling thread.
//     This avoids UIGraphicsImageRenderer / UIGraphicsBeginImageContext, which
//     carry UIKit graphics-context-stack semantics that are not appropriate here.
//
//   Text parameters (Phase 8.8 defaults — no descriptor fields for font/color):
//     Font:  UIFontWeightSemibold system font.
//     Size:  MAX(12.0, MIN(height * 0.6, 96.0)) — readable fraction of overlay height.
//     Color: white at the overlay's opacity level.
//     Background: fully transparent (CGContextClearRect).
//
//   Emoji: works opportunistically — system font stack falls back to Apple Color
//     Emoji for emoji characters. No special handling needed.
//
//   Returns nil on any failure; caller falls back to red debug rectangle.
//   Caller is responsible for no further release of the returned CIImage
//   (it is autoreleased per CoreImage conventions).
//
//   All CoreFoundation objects (colorSpace, ctx, cgImage) are released
//   before return in every code path.

static CIImage * _Nullable _VGOverlayCreateTextImage(VGOverlayDescriptor *overlay,
                                                     CGFloat width,
                                                     CGFloat height,
                                                     CGFloat opacity) {
    // Guard: caller should have checked this, but be defensive.
    if (overlay.textContent.length == 0) { return nil; }

    // Pixel dimensions must be at least 1×1.
    NSInteger pixelWidth  = (NSInteger)MAX(1.0, round((double)width));
    NSInteger pixelHeight = (NSInteger)MAX(1.0, round((double)height));

    // ── Create CGBitmapContext ────────────────────────────────────────────────
    // BGRA / premultiplied-first matches the CVPixelBuffer format used throughout
    // VGOverlayNode (kCVPixelFormatType_32BGRA). Using NULL data pointer lets
    // CoreGraphics manage the backing store.
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) { return nil; }

    CGContextRef ctx = CGBitmapContextCreate(
        NULL,
        (size_t)pixelWidth,
        (size_t)pixelHeight,
        8,                   // bits per component
        (size_t)pixelWidth * 4, // bytes per row (4 bytes/pixel, no padding)
        colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(colorSpace); // released regardless of ctx success

    if (!ctx) { return nil; }

    // ── Clear to fully transparent ────────────────────────────────────────────
    CGContextClearRect(ctx, CGRectMake(0, 0, (CGFloat)pixelWidth, (CGFloat)pixelHeight));

    // ── Draw text ─────────────────────────────────────────────────────────────
    // UIGraphicsPushContext pushes onto the per-thread UIKit context stack,
    // making CGBitmapContext available to NSString UIKit drawing methods.
    // UIGraphicsPopContext restores the previous stack state.
    UIGraphicsPushContext(ctx);

    CGFloat fontSize = MAX(12.0, MIN(height * 0.6, 96.0));
    UIFont  *font    = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
    UIColor *color   = [[UIColor whiteColor] colorWithAlphaComponent:
                            MAX(0.0, MIN(1.0, (double)opacity))];
    NSDictionary<NSAttributedStringKey, id> *attrs = @{
        NSFontAttributeName:            font,
        NSForegroundColorAttributeName: color,
    };
    // drawInRect: clips to the provided rect; wraps text naturally within bounds.
    // CGBitmapContext origin is bottom-left; UIKit drawing into a pushed CGContext
    // uses the same coordinate system as the context (Y increases upward here).
    // For this overlay use-case the exact vertical origin is acceptable —
    // the text renders within the raster and the raster is placed by the
    // existing geometry path.
    [overlay.textContent drawInRect:CGRectMake(0, 0, (CGFloat)pixelWidth, (CGFloat)pixelHeight)
                     withAttributes:attrs];

    UIGraphicsPopContext();

    // ── Extract CGImage and convert to CIImage ────────────────────────────────
    CGImageRef cgImage = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx); // released regardless of cgImage success

    if (!cgImage) { return nil; }

    CIImage *ciImage = [CIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage); // CIImage has retained what it needs

    return ciImage; // autoreleased
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
// Phase 8.7 / Phase 8.8: Export-only overlay rendering.
//
// Fast path (no active overlays):
//   Returns the original envelope EXACTLY unchanged. No buffer allocation.
//   No CoreImage invocation. Sub-microsecond.
//
// Render path (active overlays exist):
//   1. Wraps the input CVPixelBuffer in a CIImage.
//   2. For each active overlay (sorted by zIndex ascending, wrapped in
//      @autoreleasepool):
//        Phase 8.8: if type is text/emoji and textContent is non-empty,
//          rasterize text via _VGOverlayCreateTextImage and use the result.
//        Fallback: composite a solid semi-transparent red rectangle (Phase 8.7)
//          for sticker type, empty/nil textContent, or rasterization failure.
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
    //
    // Phase 8.8: Each overlay body is wrapped in @autoreleasepool to drain
    // UIFont, UIColor, NSDictionary, and CIImage autoreleased objects created
    // during text rasterization before the next overlay iteration. This prevents
    // memory pressure from accumulating across multiple overlays per frame.
    for (VGOverlayDescriptor *overlay in activeOverlays) {
        @autoreleasepool {

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

        // ── Phase 8.8: Determine overlay image (text or debug fallback) ────────
        //
        // Text/emoji with non-empty textContent → rasterize via
        // _VGOverlayCreateTextImage. The returned CIImage has bottom-left origin
        // (matching CoreImage convention) with dimensions (rectW × rectH) pixels.
        // It must be translated into position before compositing.
        //
        // Fallback (sticker / empty text / rasterization failure) → Phase 8.7
        // solid red debug rectangle.
        CIImage *overlayCI = nil;
        BOOL usedTextRaster = NO;

        VGOverlayType overlayType = overlay.type;
        BOOL isTextOrEmoji = (overlayType == VGOverlayTypeText ||
                              overlayType == VGOverlayTypeEmoji);

        if (isTextOrEmoji && overlay.textContent.length > 0) {
            // Attempt text rasterization.
            CIImage *textImage = _VGOverlayCreateTextImage(
                overlay,
                (CGFloat)rectW,
                (CGFloat)rectH,
                (CGFloat)overlay.opacity);

            if (textImage) {
                // _VGOverlayCreateTextImage returns a raster with origin at (0,0).
                // Translate to the correct CoreImage canvas position.
                CGAffineTransform positionT =
                    CGAffineTransformMakeTranslation((CGFloat)rectXLeft, (CGFloat)ciY);
                overlayCI = [textImage imageByApplyingTransform:positionT];
                usedTextRaster = (overlayCI != nil);
            }

            if (!usedTextRaster) {
                os_log_debug(sOverlayNodeLog,
                             "[VGOverlayNode][8.8] text rasterization failed for "
                             "overlay id=%{public}@ — falling back to debug rectangle",
                             overlay.overlayId);
            }
        }

        if (!usedTextRaster) {
            // ── Debug solid color fallback: semi-transparent red ───────────────
            // Retained from Phase 8.7 for:
            //   - VGOverlayTypeSticker (no asset resolver in Phase 8.8)
            //   - empty / nil textContent
            //   - text rasterization failure
            CIColor *debugColor = [CIColor colorWithRed:1.0
                                                  green:0.0
                                                   blue:0.0
                                                  alpha:(CGFloat)overlay.opacity];
            CIImage *solidRect = [CIImage imageWithColor:debugColor];
            overlayCI = [solidRect imageByCroppingToRect:overlayRect];
        }

        if (!overlayCI) {
            os_log_error(sOverlayNodeLog,
                         "[VGOverlayNode][8.8] overlay CIImage is nil — skipping overlay");
            continue;
        }

        // ── Rotation ──────────────────────────────────────────────────────────
        // Rotate around the overlay's center point in CoreImage space.
        // VGOverlayDescriptor.rotation is clockwise-positive; CoreImage uses
        // counter-clockwise-positive — negate to correct.
        // Skip rotation when effectively zero.
        if (fabs(overlay.rotation) > 1e-6) {
            CGFloat cx = (CGFloat)(rectXLeft + rectW * 0.5);
            CGFloat cy = (CGFloat)(ciY + rectH * 0.5);
            // Translate center to origin, rotate, translate back.
            CGAffineTransform t = CGAffineTransformMakeTranslation(cx, cy);
            t = CGAffineTransformRotate(t, -(CGFloat)overlay.rotation);
            t = CGAffineTransformTranslate(t, -cx, -cy);
            overlayCI = [overlayCI imageByApplyingTransform:t];
            if (!overlayCI) {
                os_log_error(sOverlayNodeLog,
                             "[VGOverlayNode][8.8] rotation transform returned nil — skipping overlay");
                continue;
            }
        }

        // ── Composite over accumulator (Porter-Duff source-over) ──────────────
        accumulator = [overlayCI imageByCompositingOverImage:accumulator];
        if (!accumulator) {
            os_log_error(sOverlayNodeLog,
                         "[VGOverlayNode][8.8] compositing returned nil — pass-through");
            return envelope;
        }

        } // @autoreleasepool
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
           "[VGOverlayNode][8.8] rendered: pts=%.3fs activeOverlays=%lu "
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
