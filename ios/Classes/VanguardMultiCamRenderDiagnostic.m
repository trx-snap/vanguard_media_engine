// VanguardMultiCamRenderDiagnostic.m
// vanguard_media_engine — MC-9/MC-10: MultiCam render diagnostic.
//
// ═══════════════════════════════════════════════════════════════════════════════
// MC-9/MC-10 — MULTICAM RENDER DIAGNOSTIC (OFFSCREEN COMPOSITION + TEXTURE)
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
// _lastCompositedBuffer (MC-10):
//   Protected by os_unfair_lock (_bufferLock).
//   Written on renderQ (after render completes), released under lock.
//   Read by Flutter raster thread via copyPixelBuffer (under lock, retained).
//   Lock scope covers ONLY pointer swap/retain/release — not CIContext rendering.
//   Released on displacement, stop, and dealloc.
//
// textureFrameAvailable (MC-10):
//   Dispatched to main queue after each successful composition and buffer swap.
//   Guarded by _textureRegistered flag — no-op during MC-9 blocking run path.
//
// registerTexture / unregisterTexture (MC-10):
//   Both called on main thread. initWithTextureRegistry: asserts main thread.
//   doUnregisterTexture must be called after stop (renderQ drained).
//
// Composition layout (PiP only — MC-9 scope, preserved in MC-10):
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
//   FlutterTexture pattern matches VanguardMetalRenderer (os_unfair_lock,
//   CVPixelBufferRetain in copyPixelBuffer, textureFrameAvailable on main).
//
// ── DO NOT MODIFY ─────────────────────────────────────────────────────────────
//
//   VanguardMultiCamMediaSource.*    VanguardMultiCamPairedFrame.*
//   VanguardMultiCamFramePairer.*    VGCameraGraphSession.*
//   VanguardCameraMediaSource.*      VGDualCameraCompositorNode.*
//   Phase 8 overlay files

#import "VanguardMultiCamRenderDiagnostic.h"
#import "VanguardMultiCamPairedFrame.h"
#import "VGDualCameraLayoutMath.h"
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>  // CACurrentMediaTime
#import <os/lock.h>

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
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,   // MC-10 texture bridge
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

    // ── Last composited buffer (MC-9/MC-10) ──────────────────────────────────
    //
    // Protected by os_unfair_lock (_bufferLock).
    // Written on renderQ after each successful composite.
    // Read on Flutter raster thread via copyPixelBuffer.
    // Lock scope: pointer swap/retain/release only — NOT CIContext rendering.
    CVPixelBufferRef _lastCompositedBuffer;

    // ── Buffer lock (MC-10) ───────────────────────────────────────────────────
    //
    // os_unfair_lock is priority-aware (raster thread is high-priority).
    // Non-recursive. Must not be held across CIContext rendering.
    os_unfair_lock _bufferLock;

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

    // ── Flutter Texture (MC-10) ───────────────────────────────────────────────
    //
    // Weak reference to avoid retain cycle: Flutter registry retains textures
    // by ID, not by object reference. We must not extend registry lifetime.
    __weak id<FlutterTextureRegistry> _textureRegistry;

    // The registered texture ID. 0 until initWithTextureRegistry: is called.
    int64_t _textureId;

    // Guards textureFrameAvailable dispatch. YES only when initWithTextureRegistry:
    // was used. The MC-9 blocking run path never sets this to YES.
    BOOL _textureRegistered;

    // ── Layout config (MC-12) ────────────────────────────────────────────────
    //
    // Drives PiP or split-screen composition in _renderPairedFrame:
    // Set once before source starts; read exclusively on renderQ.
    VGMCRDLayoutConfig _layoutConfig;
}

@synthesize renderedFrames      = _renderedFrames;
@synthesize droppedRenderFrames = _droppedRenderFrames;
// averageRenderMs is a computed property — custom getter defined below.
// @dynamic suppresses the auto-synthesis warning; no backing ivar is generated.
@dynamic    averageRenderMs;
@synthesize peakRenderMs        = _peakRenderMs;
@synthesize outputWidth         = _outputWidth;
@synthesize outputHeight        = _outputHeight;
@synthesize textureId           = _textureId;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Init / Dealloc
// ─────────────────────────────────────────────────────────────────────────────

/// Shared initialization logic. Called from both designated initializers.
- (void)_commonInit {
    // Create dedicated serial render queue.
    // Quality: userInitiated — timely completion without blocking UI.
    _renderQ = dispatch_queue_create(
        "com.vanguard.multicam.renderDiagnosticQ",
        DISPATCH_QUEUE_SERIAL);

    _bufferLock          = OS_UNFAIR_LOCK_INIT;
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

    _textureRegistry     = nil;
    _textureId           = 0;
    _textureRegistered   = NO;
    _layoutConfig        = VGMCRDDefaultLayoutConfig();

    // Pre-warm the shared CIContext (dispatch_once is lazy).
    // Doing this here avoids a first-frame spike.
    (void)_VGMCRDSharedCIContext();
}

/// MC-9 designated initializer — no Flutter texture.
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    [self _commonInit];
    NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] init: render diagnostic created (no texture).");
    return self;
}

/// MC-10 designated initializer — registers Flutter texture.
///
/// Must be called on the main thread.
- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry {
    NSAssert([NSThread isMainThread],
             @"[VanguardMultiCamRenderDiagnostic] initWithTextureRegistry: must be called on main thread.");
    self = [super init];
    if (!self) return nil;
    [self _commonInit];

    // Register with Flutter texture registry on the main thread.
    // Matches VanguardMetalRenderer.m L218-226 pattern.
    _textureRegistry   = registry;
    _textureId         = [registry registerTexture:self];
    _textureRegistered = YES;

    NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-10] initWithTextureRegistry: "
          "registered textureId=%lld.", (long long)_textureId);
    return self;
}

- (void)dealloc {
    // Release last composited buffer if any (under lock).
    os_unfair_lock_lock(&_bufferLock);
    CVPixelBufferRef buf = _lastCompositedBuffer;
    _lastCompositedBuffer = NULL;
    os_unfair_lock_unlock(&_bufferLock);
    if (buf) CVPixelBufferRelease(buf);

    // Release pool (CF type — not ARC).
    if (_pool) {
        CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
    }
    NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] dealloc: resources released.");
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - FlutterTexture Protocol (MC-10)
// ─────────────────────────────────────────────────────────────────────────────

/// Called on Flutter raster thread. Must be thread-safe and fast.
///
/// Returns a +1 retained CVPixelBufferRef — Flutter engine releases it after
/// rendering. Returns NULL if no frame has been composited yet.
///
/// Lock scope: acquire lock, retain, unlock, return. No CIContext work here.
- (CVPixelBufferRef _Nullable)copyPixelBuffer {
    os_unfair_lock_lock(&_bufferLock);
    CVPixelBufferRef result =
        _lastCompositedBuffer ? CVPixelBufferRetain(_lastCompositedBuffer) : NULL;
    os_unfair_lock_unlock(&_bufferLock);
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Texture Unregister (MC-10)
// ─────────────────────────────────────────────────────────────────────────────

/// Unregisters the Flutter texture from the registry.
///
/// Must be called on main thread AFTER stop (renderQ drained).
/// After this returns, Flutter will never call copyPixelBuffer again.
/// Safe to call multiple times (idempotent via _textureRegistered guard).
- (void)doUnregisterTexture {
    NSAssert([NSThread isMainThread],
             @"[VanguardMultiCamRenderDiagnostic] doUnregisterTexture must be called on main thread.");
    if (!_textureRegistered) return;
    id<FlutterTextureRegistry> registry = _textureRegistry;
    if (registry && _textureId != 0) {
        [registry unregisterTexture:_textureId];
    }
    _textureRegistered = NO;
    NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-10] doUnregisterTexture: "
          "unregistered textureId=%lld.", (long long)_textureId);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Layout config (MC-12)
// ─────────────────────────────────────────────────────────────────────────────

- (void)setLayoutConfig:(VGMCRDLayoutConfig)config {
    _layoutConfig = config;
}

+ (VGMCRDLayoutConfig)layoutConfigFromMap:(NSDictionary<NSString *, id> *)map {
    VGMCRDLayoutConfig cfg = VGMCRDDefaultLayoutConfig();
    if (!map) return cfg;

    // layoutMode
    NSString *modeStr = [map objectForKey:@"layoutMode"];
    if ([modeStr isEqualToString:@"splitScreen"]) {
        cfg.layoutMode = VGDualCameraLayoutModeSplitScreen;
    } else {
        cfg.layoutMode = VGDualCameraLayoutModePiP;
    }

    // pipLayout
    NSDictionary *pip = [map objectForKey:@"pipLayout"];
    if ([pip isKindOfClass:[NSDictionary class]]) {
        NSString *anchorStr = [pip objectForKey:@"anchor"];
        if      ([anchorStr isEqualToString:@"topLeft"])    cfg.pipConfig.anchor = VGPiPAnchorTopLeft;
        else if ([anchorStr isEqualToString:@"topRight"])   cfg.pipConfig.anchor = VGPiPAnchorTopRight;
        else if ([anchorStr isEqualToString:@"bottomLeft"]) cfg.pipConfig.anchor = VGPiPAnchorBottomLeft;
        else                                                 cfg.pipConfig.anchor = VGPiPAnchorBottomRight;

        NSNumber *wf = [pip objectForKey:@"widthFraction"];
        if (wf && [wf doubleValue] > 0) cfg.pipConfig.widthFraction = [wf doubleValue];
        NSNumber *mf = [pip objectForKey:@"marginFraction"];
        if (mf && [mf doubleValue] >= 0) cfg.pipConfig.marginFraction = [mf doubleValue];
        NSNumber *cr = [pip objectForKey:@"cornerRadius"];
        if (cr && [cr doubleValue] >= 0) cfg.pipConfig.cornerRadius = [cr doubleValue];
        NSNumber *op = [pip objectForKey:@"opacity"];
        if (op) cfg.pipConfig.opacity = MAX(0.0, MIN(1.0, [op doubleValue]));
    }

    // splitLayout
    NSDictionary *split = [map objectForKey:@"splitLayout"];
    if ([split isKindOfClass:[NSDictionary class]]) {
        NSNumber *sr = [split objectForKey:@"splitRatio"];
        if (sr && [sr doubleValue] > 0.0 && [sr doubleValue] < 1.0) {
            cfg.splitConfig.splitRatio = [sr doubleValue];
        }
    }

    return cfg;
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
        // Release last composited buffer under lock — no more raster-thread reads
        // are possible after doUnregisterTexture (called by plugin after stop).
        // Locking here is defensive: ensures correct pairing with copyPixelBuffer.
        os_unfair_lock_lock(&self->_bufferLock);
        CVPixelBufferRef buf = self->_lastCompositedBuffer;
        self->_lastCompositedBuffer = NULL;
        os_unfair_lock_unlock(&self->_bufferLock);
        if (buf) CVPixelBufferRelease(buf);
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
/// MC-12: branches on _layoutConfig.layoutMode — PiP or split-screen.
/// Both paths use VGDualCameraLayoutMath for geometry. Falls back to
/// default bottom-right PiP on any degenerate input.
///
/// After successful render and buffer swap (MC-10):
///   If _textureRegistered, dispatches textureFrameAvailable: to main queue.
- (void)_renderPairedFrame:(VanguardMultiCamPairedFrame *)frame {
    if (_stopped) return;

    CVPixelBufferRef primaryBuf   = frame.backBuffer;   // back = full canvas
    CVPixelBufferRef secondaryBuf = frame.frontBuffer;  // front = PiP/secondary

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
    if (!_pool || _poolWidth != primW || _poolHeight != primH) {
        if (_pool) {
            os_unfair_lock_lock(&_bufferLock);
            CVPixelBufferRef old = _lastCompositedBuffer;
            _lastCompositedBuffer = NULL;
            os_unfair_lock_unlock(&_bufferLock);
            if (old) CVPixelBufferRelease(old);
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

    // ── 4. Build CIImages ─────────────────────────────────────────────────────
    CIImage *primaryCI   = [CIImage imageWithCVPixelBuffer:primaryBuf];
    CIImage *secondaryCI = [CIImage imageWithCVPixelBuffer:secondaryBuf];
    if (!primaryCI || !secondaryCI) {
        NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] _renderPairedFrame: "
              "CIImage creation failed.");
        CVPixelBufferRelease(outputBuf);
        return;
    }

    // ── 5. Compose based on layout mode (MC-12) ───────────────────────────────
    CIImage *composited = nil;

    if (_layoutConfig.layoutMode == VGDualCameraLayoutModeSplitScreen) {
        // ── Split-screen path ─────────────────────────────────────────────────
        VGDCSplitRects rects = VGDCLayoutComputeSplitRects(primW, primH,
                                                            _layoutConfig.splitConfig);
        if (rects.isValid) {
            // Scale and crop primary into top band.
            VGDCAspectFillResult primFill = VGDCLayoutComputeAspectFill(primW, primH, rects.topRect);
            CGPoint primOrigin = primaryCI.extent.origin;
            CIImage *primNorm = (primOrigin.x != 0.0 || primOrigin.y != 0.0)
                ? [primaryCI imageByApplyingTransform:
                    CGAffineTransformMakeTranslation(-primOrigin.x, -primOrigin.y)]
                : primaryCI;
            CIImage *primFilled = [[primNorm
                imageByApplyingTransform:CGAffineTransformMakeScale(primFill.scale, primFill.scale)]
                imageByApplyingTransform:CGAffineTransformMakeTranslation(primFill.offsetX, primFill.offsetY)];
            CIImage *primCropped = [primFilled imageByCroppingToRect:rects.topRect];

            // Scale and crop secondary into bottom band.
            VGDCAspectFillResult secFill = VGDCLayoutComputeAspectFill(secW, secH, rects.bottomRect);
            CGPoint secOrigin = secondaryCI.extent.origin;
            CIImage *secNorm = (secOrigin.x != 0.0 || secOrigin.y != 0.0)
                ? [secondaryCI imageByApplyingTransform:
                    CGAffineTransformMakeTranslation(-secOrigin.x, -secOrigin.y)]
                : secondaryCI;
            CIImage *secFilled = [[secNorm
                imageByApplyingTransform:CGAffineTransformMakeScale(secFill.scale, secFill.scale)]
                imageByApplyingTransform:CGAffineTransformMakeTranslation(secFill.offsetX, secFill.offsetY)];
            CIImage *secCropped = [secFilled imageByCroppingToRect:rects.bottomRect];

            // Composite onto a black canvas.
            CIImage *black = [[CIImage imageWithColor:[CIColor blackColor]]
                imageByCroppingToRect:CGRectMake(0, 0, (CGFloat)primW, (CGFloat)primH)];
            composited = [primCropped imageByCompositingOverImage:
                            [secCropped imageByCompositingOverImage:black]];
        } else {
            NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-12] split rects invalid — "
                  "falling back to default PiP.");
        }
    }

    if (!composited) {
        // ── PiP path (default and split-screen fallback) ──────────────────────
        VGDCPiPGeometry pipGeo = VGDCLayoutComputePiPGeometry(primW, primH,
                                                               secW, secH,
                                                               _layoutConfig.pipConfig);
        double pipOriginX = pipGeo.pipOriginX;
        double pipOriginY = pipGeo.pipOriginY;
        double pipW       = pipGeo.pipW;
        double pipH       = pipGeo.pipH;
        double cr         = pipGeo.clampedCornerRadius;

        CIImage *secNorm = secondaryCI;
        CGPoint secOrigin = secNorm.extent.origin;
        if (secOrigin.x != 0.0 || secOrigin.y != 0.0) {
            secNorm = [secNorm imageByApplyingTransform:
                CGAffineTransformMakeTranslation(-secOrigin.x, -secOrigin.y)];
        }
        double scaleX = (secW > 0) ? pipW / (double)secW : 1.0;
        double scaleY = (secH > 0) ? pipH / (double)secH : 1.0;
        CIImage *secScaled = [secNorm imageByApplyingTransform:
            CGAffineTransformMakeScale(scaleX, scaleY)];
        CIImage *secPositioned = [secScaled imageByApplyingTransform:
            CGAffineTransformMakeTranslation(pipOriginX, pipOriginY)];

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
                if (masked) { secStyled = masked; }
            }
        }
        composited = [secStyled imageByCompositingOverImage:primaryCI];
    }

    if (!composited) {
        NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-9] _renderPairedFrame: "
              "compositing returned nil.");
        CVPixelBufferRelease(outputBuf);
        return;
    }

    // ── 6. Render into output buffer (synchronous) ────────────────────────────
    double t0 = CACurrentMediaTime() * 1000.0;
    CGRect renderBounds = CGRectMake(0, 0, (CGFloat)primW, (CGFloat)primH);
    [_VGMCRDSharedCIContext() render:composited
                     toCVPixelBuffer:outputBuf
                               bounds:renderBounds
                           colorSpace:nil];
    double renderMs = CACurrentMediaTime() * 1000.0 - t0;

    // ── 7. Update metrics ─────────────────────────────────────────────────────
    _renderedFrames++;
    _totalRenderMs += renderMs;
    if (renderMs > _peakRenderMs) { _peakRenderMs = renderMs; }
    if (_outputWidth == 0) {
        _outputWidth  = (int32_t)primW;
        _outputHeight = (int32_t)primH;
    }

    // ── 8. Swap _lastCompositedBuffer under lock (MC-10) ──────────────────────
    os_unfair_lock_lock(&_bufferLock);
    CVPixelBufferRef old = _lastCompositedBuffer;
    _lastCompositedBuffer = outputBuf;
    os_unfair_lock_unlock(&_bufferLock);
    if (old) CVPixelBufferRelease(old);

    // ── 9. Signal Flutter raster thread (MC-10) ───────────────────────────────
    if (_textureRegistered) {
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strong = weakSelf;
            if (!strong || !strong->_textureRegistered) return;
            [strong->_textureRegistry textureFrameAvailable:strong->_textureId];
        });
    }

    // ── 10. One-time first-frame log ──────────────────────────────────────────
    if (_renderedFrames == 1) {
        NSLog(@"[VanguardMultiCamRenderDiagnostic][MC-12] first frame | "
              "mode=%s canvas=%zux%zu renderMs=%.2f texture=%s",
              _layoutConfig.layoutMode == VGDualCameraLayoutModeSplitScreen
                  ? "splitScreen" : "pip",
              primW, primH, renderMs,
              _textureRegistered ? "YES" : "NO");
    }
}

@end

