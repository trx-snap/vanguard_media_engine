// VanguardMultiCamRenderDiagnostic.m
// vanguard_media_engine — MC-9: Offscreen MultiCam render diagnostic.
//
// ═══════════════════════════════════════════════════════════════════════════════
// MC-9 — MULTICAM RENDER DIAGNOSTIC (OFFSCREEN COMPOSITION, DIAGNOSTIC-ONLY)
// ═══════════════════════════════════════════════════════════════════════════════
//
// See VanguardMultiCamRenderDiagnostic.h for full documentation.
//
// ── IMPLEMENTATION NOTES ─────────────────────────────────────────────────────
//
// CIContext (singleton, dedicated):
//   A dedicated static CIContext is created once for this class, separate from
//   the playback/export compositor (_VGDCCNSharedCIContext). This avoids any
//   contention and makes the diagnostic self-contained.
//   Config: kCIContextWorkingColorSpace: [NSNull null] — matches the existing
//   compositor pattern (disables color-space conversion for performance).
//
// CVPixelBufferPool (lazy creation):
//   Created on first render when output dimensions are known.
//   Pool attributes:
//     kCVPixelBufferPoolMinimumBufferCountKey: @2
//   Buffer attributes:
//     kCVPixelFormatType_32BGRA
//     kCVPixelBufferIOSurfacePropertiesKey: @{} (IOSurface-backed)
//     kCVPixelBufferMetalCompatibilityKey: @YES (MC-10 texture bridge readiness)
//   Pool is released in dealloc.
//
// CIFilter isolation:
//   All CIFilter instances (CIRoundedRectangleGenerator, CIBlendWithAlphaMask)
//   are created per-frame inside _renderPairedFrame: on renderQ.
//   CIFilter is NOT thread-safe per Apple documentation. No filter caching.
//
// Frame dropping:
//   _renderingInFlight is a BOOL set on captureQ (read/check/set).
//   Written NO from renderQ (single aligned store — safe on ARM64).
//   When YES on arrival, the frame is dropped and droppedRenderFrames incremented.
//
// _lastCompositedBuffer:
//   Retained after each successful render (node-owned +1 from pool allocation).
//   Released on displacement, stop, and dealloc.
//   Exposed for MC-10 readiness but not surfaced in current diagnostic metrics.
//
// Composition layout (PiP only — MC-9 scope):
//   Primary: back camera (full canvas, back buffer dimensions used as output).
//   Secondary: front camera (PiP inset, bottom-right corner, widthFraction=0.35).
//   Layout math: VGDualCameraLayoutMath (MC-1A).
//
// ── REFERENCE IMPLEMENTATION ─────────────────────────────────────────────────
//
//   CIContext usage and CIFilter composition patterns match those in:
//   VGDualCameraCompositorNode._compositeWithPrimary:secondary: (Phase 7.x-J)
//   BeautyV2FilterGroup._VGBeautyCreatePool() (Phase 4B)
//
// ── DO NOT MODIFY ─────────────────────────────────────────────────────────────
//
//   VanguardMultiCamMediaSource.*    VanguardMultiCamPairedFrame.*
//   VanguardMultiCamFramePairer.*    VGCameraGraphSession.*
//   VanguardCameraMediaSource.*      VGDualCameraCompositorNode.*
//   VanguardMediaEnginePlugin.swift  connectsapp_*/**

#import "VanguardMultiCamRenderDiagnostic.h"
#import "VanguardMultiCamPairedFrame.h"
#import "VGDualCameraLayoutMath.h"
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>  // CACurrentMediaTime

// ─── Dedicated CIContext ──────────────────────────────────────────────────────
//
// Separate from _VGDCCNSharedCIContext used by the playback/export compositor.
// Created once (dispatch_once) — CIContext is thread-safe per Apple docs.
// Options match VGDualCameraCompositorNode: disable color-space conversion.

static CIContext *_VGMCRDSharedCIContext(void) {
    static CIContext *ctx = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ctx = [CIContext contextWithOptions:@{
            kCIContextWorkingColorSpace : [NSNull null],
        }];
    });
    return ctx;
}

// ─── Pool creation helper ─────────────────────────────────────────────────────
//
// Creates an IOSurface-backed, Metal-compatible CVPixelBufferPool.
// Returns NULL on failure. Caller owns the returned pool (+1 from Create).
// Matches the BeautyV2FilterGroup._VGBeautyCreatePool pattern (Phase 4B).

static CVPixelBufferPoolRef _Nullable
_VGMCRDCreatePool(size_t width, size_t height) {
    NSDictionary *poolAttrs = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @2,
    };
    NSDictionary *bufAttrs = @{
        (id)kCVPixelBufferWidthKey              : @(width),
        (id)kCVPixelBufferHeightKey             : @(height),
        (id)kCVPixelBufferPixelFormatTypeKey    : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},     // IOSurface-backed
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,   // MC-10 texture bridge readiness
    };
    CVPixelBufferPoolRef pool = NULL;
    CVReturn status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        (__bridge CFDictionaryRef)poolAttrs,
        (__bridge CFDictionaryRef)bufAttrs,
        &pool);
    if (status != kCVReturnSuccess || !pool) {
        NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] _VGMCRDCreatePool: "
              "CVPixelBufferPoolCreate failed (ret=%d) for %zux%zu.",
              status, width, height);
        return NULL;
    }
    return pool; // +1 from Create — caller owns
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation VanguardMultiCamRenderDiagnostic {

    // ── Render queue ──────────────────────────────────────────────────────────
    //
    // Serial queue for CoreImage composition work.
    // captureQ → (dispatch_async) → renderQ for each render job.
    dispatch_queue_t _renderQ;

    // ── Frame-drop flag ───────────────────────────────────────────────────────
    //
    // Written on captureQ (check + set atomically for serial callers).
    // Written NO from renderQ at completion (single aligned store, ARM64-safe).
    BOOL _renderingInFlight;

    // ── Output buffer pool ────────────────────────────────────────────────────
    //
    // Lazy: created on first render when output dimensions are known.
    // Node-owned (+1 from CVPixelBufferPoolCreate). Released in dealloc.
    CVPixelBufferPoolRef _pool;

    // ── Pool dimensions ───────────────────────────────────────────────────────
    //
    // Cached to detect dimension changes (unlikely in diagnostic, defensive).
    size_t _poolWidth;
    size_t _poolHeight;

    // ── Last composited buffer ────────────────────────────────────────────────
    //
    // Retained for MC-10 readiness. Allocated from _pool (+1).
    // Released on displacement (next successful render), stop, and dealloc.
    CVPixelBufferRef _lastCompositedBuffer;

    // ── Metrics (written on renderQ, read after stop) ─────────────────────────
    int32_t _renderedFrames;
    int32_t _droppedRenderFrames;
    double  _totalRenderMs;     // sum of per-frame render durations
    double  _peakRenderMs;
    int32_t _outputWidth;
    int32_t _outputHeight;

    // ── Stop flag ─────────────────────────────────────────────────────────────
    //
    // Set to YES by stop. Checked in renderQ block to prevent rendering
    // after the diagnostic window has closed.
    BOOL _stopped;
}

@synthesize renderedFrames      = _renderedFrames;
@synthesize droppedRenderFrames = _droppedRenderFrames;
@synthesize averageRenderMs     = _averageRenderMs;
@synthesize peakRenderMs        = _peakRenderMs;
@synthesize outputWidth         = _outputWidth;
@synthesize outputHeight        = _outputHeight;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Init / Dealloc
// ─────────────────────────────────────────────────────────────────────────────

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    // Create dedicated serial render queue.
    // Quality: userInitiated — we need timely completion but must not block UI.
    _renderQ = dispatch_queue_create(
        "com.vanguard.multicam.renderDiagnosticQ",
        DISPATCH_QUEUE_SERIAL);

    _renderingInFlight   = NO;
    _stopped             = NO;
    _pool                = NULL;
    _poolWidth           = 0;
    _poolHeight          = 0;
    _lastCompositedBuffer = NULL;

    _renderedFrames      = 0;
    _droppedRenderFrames = 0;
    _totalRenderMs       = 0.0;
    _peakRenderMs        = 0.0;
    _outputWidth         = 0;
    _outputHeight        = 0;

    // Pre-warm the shared CIContext (dispatch_once is lazy).
    // Doing this here avoids a first-frame spike.
    (void)_VGMCRDSharedCIContext();

    NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] init: render diagnostic created.");
    return self;
}

- (void)dealloc {
    // Release last composited buffer if any.
    if (_lastCompositedBuffer) {
        CVPixelBufferRelease(_lastCompositedBuffer);
        _lastCompositedBuffer = NULL;
    }
    // Release pool (CF type — not ARC).
    if (_pool) {
        CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
    }
    NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] dealloc: resources released.");
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Stop
// ─────────────────────────────────────────────────────────────────────────────

- (void)stop {
    // Set stopped flag immediately so any in-flight renderQ work can check it.
    _stopped = YES;

    // Synchronously drain the renderQ so we can safely read metrics afterward.
    // dispatch_sync on the serial renderQ guarantees all enqueued blocks complete.
    dispatch_sync(_renderQ, ^{
        // Release last composited buffer — no longer needed after stop.
        if (self->_lastCompositedBuffer) {
            CVPixelBufferRelease(self->_lastCompositedBuffer);
            self->_lastCompositedBuffer = NULL;
        }
    });
    NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] stop: renderQ drained. "
          "rendered=%d dropped=%d avgMs=%.2f peakMs=%.2f",
          _renderedFrames, _droppedRenderFrames,
          [self averageRenderMs], _peakRenderMs);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Metrics
// ─────────────────────────────────────────────────────────────────────────────

- (double)averageRenderMs {
    if (_renderedFrames <= 0) return 0.0;
    return _totalRenderMs / (double)_renderedFrames;
}

- (NSDictionary<NSString *, NSNumber *> *)metrics {
    return @{
        @"renderedFrames"      : @(_renderedFrames),
        @"droppedRenderFrames" : @(_droppedRenderFrames),
        @"averageRenderMs"     : @([self averageRenderMs]),
        @"peakRenderMs"        : @(_peakRenderMs),
        @"outputWidth"         : @(_outputWidth),
        @"outputHeight"        : @(_outputHeight),
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - VanguardMultiCamMediaSourceDelegate
// ─────────────────────────────────────────────────────────────────────────────

/// Called synchronously on the source's captureQ.
/// Must return quickly — no GPU work here.
///
/// Implements queue-depth-1 frame dropping:
///   If _renderingInFlight == YES → drop frame, increment counter, return.
///   Else: set _renderingInFlight = YES, retain frame, dispatch to renderQ.
///
/// _renderingInFlight read/check/set: all on captureQ (serial) → no race.
/// The NO write from renderQ is a single aligned store → safe on ARM64.
- (void)multiCamMediaSource:(VanguardMultiCamMediaSource *)source
       didOutputPairedFrame:(VanguardMultiCamPairedFrame *)pairedFrame {
    // Check: is a render already in flight?
    if (_renderingInFlight) {
        // renderQ is still processing the previous frame — drop this one.
        _droppedRenderFrames++;
        return;
    }

    // Mark renderQ as busy before dispatching.
    // Read/check/set is safe: we are on a serial captureQ.
    _renderingInFlight = YES;

    // ARC retains pairedFrame until the block completes.
    // This extends both CVPixelBuffer lifetimes past the delegate callback.
    dispatch_async(_renderQ, ^{
        [self _renderPairedFrame:pairedFrame];
        // Clear busy flag AFTER render completes.
        // Single aligned BOOL write — ARM64-safe.
        self->_renderingInFlight = NO;
    });

    // Return immediately. GPU work happens on renderQ.
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Private: render
// ─────────────────────────────────────────────────────────────────────────────

/// Composites a paired frame offscreen using CoreImage.
/// Called exclusively on the serial renderQ.
///
/// Composition layout (PiP only — MC-9 scope):
///   Primary (canvas): back camera buffer
///   Secondary (inset): front camera buffer (bottom-right PiP)
///   Output: same dimensions as primary (back camera)
///
/// CIFilter instances are created fresh per-frame. CIFilter is NOT thread-safe.
/// VGDualCameraLayoutMath is pure C — safe to call from any thread.
- (void)_renderPairedFrame:(VanguardMultiCamPairedFrame *)frame {
    if (_stopped) return;

    CVPixelBufferRef primaryBuf   = frame.backBuffer;   // back = full canvas
    CVPixelBufferRef secondaryBuf = frame.frontBuffer;  // front = PiP inset

    if (!primaryBuf || !secondaryBuf) {
        NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] _renderPairedFrame: "
              "nil buffer — skipping.");
        return;
    }

    // ── 1. Dimensions ─────────────────────────────────────────────────────────
    size_t primW = CVPixelBufferGetWidth(primaryBuf);
    size_t primH = CVPixelBufferGetHeight(primaryBuf);
    size_t secW  = CVPixelBufferGetWidth(secondaryBuf);
    size_t secH  = CVPixelBufferGetHeight(secondaryBuf);

    if (primW == 0 || primH == 0 || secW == 0 || secH == 0) {
        NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] _renderPairedFrame: "
              "degenerate dimensions prim=%zux%zu sec=%zux%zu — skipping.",
              primW, primH, secW, secH);
        return;
    }

    // ── 2. Lazy pool creation / dimension check ───────────────────────────────
    //
    // Pool is created once for the first frame's dimensions.
    // Defensive re-creation if dimensions change (unlikely in diagnostic).
    if (!_pool || _poolWidth != primW || _poolHeight != primH) {
        if (_pool) {
            // Release previous pool (dimension change — defensive path).
            if (_lastCompositedBuffer) {
                CVPixelBufferRelease(_lastCompositedBuffer);
                _lastCompositedBuffer = NULL;
            }
            CVPixelBufferPoolRelease(_pool);
            _pool = NULL;
        }
        _pool = _VGMCRDCreatePool(primW, primH);
        if (!_pool) {
            NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] _renderPairedFrame: "
                  "pool creation failed for %zux%zu — skipping.", primW, primH);
            return;
        }
        _poolWidth  = primW;
        _poolHeight = primH;
        NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] pool created: %zux%zu BGRA.",
              primW, primH);
    }

    // ── 3. Allocate output buffer from pool ───────────────────────────────────
    CVPixelBufferRef outputBuf = NULL;
    CVReturn poolRet = CVPixelBufferPoolCreatePixelBuffer(nil, _pool, &outputBuf);
    if (poolRet != kCVReturnSuccess || !outputBuf) {
        NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] _renderPairedFrame: "
              "CVPixelBufferPoolCreatePixelBuffer failed (ret=%d).", poolRet);
        return;
    }
    // outputBuf is +1 from pool allocation — we own it.

    // ── 4. Build CIImages ─────────────────────────────────────────────────────
    //
    // CIImage is immutable and thread-safe.
    CIImage *primaryCI   = [CIImage imageWithCVPixelBuffer:primaryBuf];
    CIImage *secondaryCI = [CIImage imageWithCVPixelBuffer:secondaryBuf];
    if (!primaryCI || !secondaryCI) {
        NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] _renderPairedFrame: "
              "CIImage creation failed.");
        CVPixelBufferRelease(outputBuf);
        return;
    }

    // ── 5. PiP geometry (VGDualCameraLayoutMath — MC-1A) ─────────────────────
    //
    // Use default PiP layout (bottom-right, 35% width, 1.8% margin, 24pt corner).
    // These match VGPiPLayoutDescriptor() defaults in Dart.
    VGPiPLayoutConfig pipLayout = {
        .anchor         = VGPiPAnchorBottomRight,
        .widthFraction  = 0.35,
        .marginFraction = 0.018,
        .cornerRadius   = 24.0,
        .opacity        = 1.0,
    };
    VGDCPiPGeometry pipGeo = VGDCLayoutComputePiPGeometry(primW, primH,
                                                           secW,  secH,
                                                           pipLayout);
    double pipOriginX = pipGeo.pipOriginX;
    double pipOriginY = pipGeo.pipOriginY;
    double pipW       = pipGeo.pipW;
    double pipH       = pipGeo.pipH;
    double cr         = pipGeo.clampedCornerRadius;

    // ── 6. Scale secondary to PiP size ────────────────────────────────────────
    //
    // Normalize secondary origin first (CoreImage Y-up, may be non-zero).
    // Matches VGDualCameraCompositorNode._compositeWithPrimary:secondary: §5.
    CIImage *secNorm = secondaryCI;
    CGPoint secOrigin = secNorm.extent.origin;
    if (secOrigin.x != 0.0 || secOrigin.y != 0.0) {
        CGAffineTransform normT = CGAffineTransformMakeTranslation(-secOrigin.x,
                                                                   -secOrigin.y);
        secNorm = [secNorm imageByApplyingTransform:normT];
    }

    double scaleX = (secW > 0) ? pipW / (double)secW : 1.0;
    double scaleY = (secH > 0) ? pipH / (double)secH : 1.0;
    CGAffineTransform scaleT = CGAffineTransformMakeScale(scaleX, scaleY);
    CIImage *secScaled = [secNorm imageByApplyingTransform:scaleT];

    // ── 7. Translate secondary to PiP position ────────────────────────────────
    CGAffineTransform translateT = CGAffineTransformMakeTranslation(pipOriginX,
                                                                    pipOriginY);
    CIImage *secPositioned = [secScaled imageByApplyingTransform:translateT];

    // ── 8. Apply corner radius mask ───────────────────────────────────────────
    //
    // CIFilter instances are created per-frame — CIFilter is NOT thread-safe.
    // Matches VGDualCameraCompositorNode._compositeWithPrimary:secondary: §7.
    CIImage *secStyled = secPositioned;
    if (cr > 0.0) {
        CGRect pipLocalRect = CGRectMake(pipOriginX, pipOriginY, pipW, pipH);
        CIFilter *maskFilter = [CIFilter filterWithName:@"CIRoundedRectangleGenerator"
                                          keysAndValues:
            @"inputExtent", [CIVector vectorWithCGRect:pipLocalRect],
            @"inputRadius", @(cr),
            @"inputColor",  [CIColor whiteColor],
            nil];
        CIImage *mask = maskFilter.outputImage;
        if (mask) {
            mask = [mask imageByCroppingToRect:pipLocalRect];
            CIFilter *blendFilter = [CIFilter filterWithName:@"CIBlendWithAlphaMask"
                                                keysAndValues:
                kCIInputImageKey,           secPositioned,
                kCIInputMaskImageKey,        mask,
                kCIInputBackgroundImageKey,  [CIImage emptyImage],
                nil];
            CIImage *masked = blendFilter.outputImage;
            if (masked) {
                secStyled = masked;
            }
        }
    }

    // ── 9. Composite: secondary PiP over primary (Porter-Duff SourceOver) ─────
    CIImage *composited = [secStyled imageByCompositingOverImage:primaryCI];
    if (!composited) {
        NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] _renderPairedFrame: "
              "imageByCompositingOverImage: returned nil.");
        CVPixelBufferRelease(outputBuf);
        return;
    }

    // ── 10. Render into output buffer (synchronous) ───────────────────────────
    //
    // CIContext render:toCVPixelBuffer:bounds:colorSpace: is synchronous.
    // It blocks renderQ until the GPU operation completes.
    // Timing wraps this call to measure actual render duration.
    double t0 = CACurrentMediaTime() * 1000.0; // milliseconds

    CGRect renderBounds = CGRectMake(0, 0, (CGFloat)primW, (CGFloat)primH);
    [_VGMCRDSharedCIContext() render:composited
                     toCVPixelBuffer:outputBuf
                               bounds:renderBounds
                           colorSpace:nil];

    double renderMs = CACurrentMediaTime() * 1000.0 - t0;

    // ── 11. Update metrics ────────────────────────────────────────────────────
    _renderedFrames++;
    _totalRenderMs += renderMs;
    if (renderMs > _peakRenderMs) {
        _peakRenderMs = renderMs;
    }
    if (_outputWidth == 0) {
        _outputWidth  = (int32_t)primW;
        _outputHeight = (int32_t)primH;
    }

    // ── 12. Retain last composited buffer (MC-10 readiness) ───────────────────
    //
    // Release previous buffer before storing new one.
    // Manual release required — this is a CVPixelBufferRef (CF type, not ARC).
    if (_lastCompositedBuffer) {
        CVPixelBufferRelease(_lastCompositedBuffer);
    }
    _lastCompositedBuffer = outputBuf; // takes +1 from pool allocation

    // ── 13. One-time first-frame log ──────────────────────────────────────────
    if (_renderedFrames == 1) {
        NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] first frame rendered | "
              "canvas=%zux%zu pip=(%.0f,%.0f,%.0f,%.0f) cr=%.1f renderMs=%.2f",
              primW, primH,
              pipOriginX, pipOriginY, pipW, pipH,
              cr, renderMs);
    }
}

@end
