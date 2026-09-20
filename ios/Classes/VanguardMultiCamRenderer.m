// VanguardMultiCamRenderer.m
// vanguard_media_engine — MC-9/MC-10/MC-19/MC-20: MultiCam compositor (production renderer).
//
// ═══════════════════════════════════════════════════════════════════════════════
// MC-9/MC-10 — MULTICAM OFFSCREEN COMPOSITION + FLUTTER TEXTURE
// ═══════════════════════════════════════════════════════════════════════════════
//
// See VanguardMultiCamRenderer.h for full documentation.
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

#import "VanguardMultiCamRenderer.h"
#import "VanguardMultiCamPairedFrame.h"
#import "VGDualCameraLayoutMath.h"
#import <AVFoundation/AVFoundation.h>  // MC-17: AVAssetWriter
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>        // MC-17: CMTime, CMSampleBuffer
#import <ImageIO/ImageIO.h>
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
        NSLog(@"[VanguardMultiCamRenderer][MC-9] _VGMCRDCreatePool: "
              "CVPixelBufferPoolCreate failed (ret=%d) for %zux%zu.",
              status, width, height);
        return NULL;
    }
    return pool; // +1 from Create — caller owns
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - MC-17: Recording state enum
// ─────────────────────────────────────────────────────────────────────────────
//
// Declared at file scope so the enum type is visible in both the ivar block
// and method bodies. (NS_ENUM inside @implementation {} ivar block is not
// legal in Objective-C.)

typedef NS_ENUM(NSInteger, VGMCRecordingState) {
    VGMCRecordingStateIdle      = 0,
    VGMCRecordingStateStarting  = 1,
    VGMCRecordingStateRecording = 2,
    VGMCRecordingStateStopping  = 3,
};

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation VanguardMultiCamRenderer {

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

    // ── MC-17: Video-only recording ──────────────────────────────────────────
    //
    // All writer state is accessed exclusively on the serial _renderQ.
    // No lock needed — _renderQ serializes all access.
    //
    // State machine:
    //   VGMCRecordingStateIdle      — not recording
    //   VGMCRecordingStateStarting  — writer created; waiting for first renderable frame
    //   VGMCRecordingStateRecording — actively appending frames
    //   VGMCRecordingStateStopping  — markAsFinished called, awaiting finishWriting
    AVAssetWriter          *_assetWriter;
    AVAssetWriterInput     *_videoWriterInput;
    AVAssetWriterInputPixelBufferAdaptor *_pixelBufferAdaptor;
    NSString               *_recordingOutputPath;
    BOOL                    _mcRecordingSessionStarted;  // startSessionAtSourceTime: called
    int32_t                 _framesOfferedToWriter;
    int32_t                 _framesAppended;
    int32_t                 _framesDroppedWriterNotReady;
    CFAbsoluteTime          _recordingStartTime;         // CFAbsoluteTimeGetCurrent() at first append

    // MC-20: Best-effort AAC audio writer input.
    // Nil when the source did not configure microphone capture (permission denied,
    // hardware unavailable, or any canAdd* check failed).
    // All access is on _renderQ (same as video writer state above).
    AVAssetWriterInput     *_audioWriterInput;

    // Recording state — written/read exclusively on _renderQ.
    VGMCRecordingState _mcRecordingState;
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

    // MC-17: recording state
    _mcRecordingState             = VGMCRecordingStateIdle;
    _assetWriter                  = nil;
    _videoWriterInput             = nil;
    _audioWriterInput             = nil;  // MC-20
    _pixelBufferAdaptor           = nil;
    _recordingOutputPath          = nil;
    _mcRecordingSessionStarted    = NO;
    _framesOfferedToWriter        = 0;
    _framesAppended               = 0;
    _framesDroppedWriterNotReady  = 0;
    _recordingStartTime           = 0;

    // Pre-warm the shared CIContext (dispatch_once is lazy).
    // Doing this here avoids a first-frame spike.
    (void)_VGMCRDSharedCIContext();
}

/// MC-9 designated initializer — no Flutter texture.
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    [self _commonInit];
    NSLog(@"[VanguardMultiCamRenderer][MC-9] init: render diagnostic created (no texture).");
    return self;
}

/// MC-10 designated initializer — registers Flutter texture.
///
/// Must be called on the main thread.
- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry {
    NSAssert([NSThread isMainThread],
             @"[VanguardMultiCamRenderer] initWithTextureRegistry: must be called on main thread.");
    self = [super init];
    if (!self) return nil;
    [self _commonInit];

    // Register with Flutter texture registry on the main thread.
    // Matches VanguardMetalRenderer.m L218-226 pattern.
    _textureRegistry   = registry;
    _textureId         = [registry registerTexture:self];
    _textureRegistered = YES;

    NSLog(@"[VanguardMultiCamRenderer][MC-10] initWithTextureRegistry: "
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
    NSLog(@"[VanguardMultiCamRenderer][MC-9] dealloc: resources released.");
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
             @"[VanguardMultiCamRenderer] doUnregisterTexture must be called on main thread.");
    if (!_textureRegistered) return;
    id<FlutterTextureRegistry> registry = _textureRegistry;
    if (registry && _textureId != 0) {
        [registry unregisterTexture:_textureId];
    }
    _textureRegistered = NO;
    NSLog(@"[VanguardMultiCamRenderer][MC-10] doUnregisterTexture: "
          "unregistered textureId=%lld.", (long long)_textureId);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Layout config (MC-12)
// ─────────────────────────────────────────────────────────────────────────────

- (void)setLayoutConfig:(VGMCRDLayoutConfig)config {
    _layoutConfig = config;
}

// MC-23: Live layout update — safe to call from any thread while running.
// Dispatches a struct copy onto the serial _renderQ; the next composited
// frame will use the new config. No lock needed (_renderQ serialises all
// _layoutConfig reads). No-op after stop (_stopped will be YES but the
// assignment is harmless).
- (void)updateLayoutConfig:(VGMCRDLayoutConfig)config {
    dispatch_async(_renderQ, ^{
        self->_layoutConfig = config;
    });
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
        if      ([anchorStr isEqualToString:@"topLeft"])       cfg.pipConfig.anchor = VGPiPAnchorTopLeft;
        else if ([anchorStr isEqualToString:@"topRight"])      cfg.pipConfig.anchor = VGPiPAnchorTopRight;
        else if ([anchorStr isEqualToString:@"bottomLeft"])    cfg.pipConfig.anchor = VGPiPAnchorBottomLeft;
        else if ([anchorStr isEqualToString:@"freeFloating"])  cfg.pipConfig.anchor = VGPiPAnchorFreeFloating;
        else                                                    cfg.pipConfig.anchor = VGPiPAnchorBottomRight;

        NSNumber *wf = [pip objectForKey:@"widthFraction"];
        if (wf && [wf doubleValue] > 0) cfg.pipConfig.widthFraction = [wf doubleValue];
        NSNumber *mf = [pip objectForKey:@"marginFraction"];
        if (mf && [mf doubleValue] >= 0) cfg.pipConfig.marginFraction = [mf doubleValue];
        NSNumber *cr = [pip objectForKey:@"cornerRadius"];
        if (cr && [cr doubleValue] >= 0) cfg.pipConfig.cornerRadius = [cr doubleValue];
        NSNumber *op = [pip objectForKey:@"opacity"];
        if (op) cfg.pipConfig.opacity = MAX(0.0, MIN(1.0, [op doubleValue]));
        NSNumber *cx = [pip objectForKey:@"centerX"];
        if (cx) cfg.pipConfig.centerX = [cx doubleValue];
        NSNumber *cy = [pip objectForKey:@"centerY"];
        if (cy) cfg.pipConfig.centerY = [cy doubleValue];
    }

    // splitLayout
    NSDictionary *split = [map objectForKey:@"splitLayout"];
    if ([split isKindOfClass:[NSDictionary class]]) {
        NSNumber *sr = [split objectForKey:@"splitRatio"];
        if (sr && [sr doubleValue] > 0.0 && [sr doubleValue] < 1.0) {
            cfg.splitConfig.splitRatio = [sr doubleValue];
        }
        NSString *dirStr = [split objectForKey:@"direction"];
        if ([dirStr isEqualToString:@"leftRight"]) {
            cfg.splitConfig.direction = VGSplitScreenDirectionLeftRight;
        } else {
            cfg.splitConfig.direction = VGSplitScreenDirectionTopBottom;
        }
    }

    return cfg;
}

// ───────────────────────────────────────────────────────────────────────────────
// MARK: - MC-15: Still-photo capture
// ───────────────────────────────────────────────────────────────────────────────

/// Captures the current composited preview frame as a JPEG.
///
/// Threading model (mirrors VanguardCameraMediaSource.takePhotoToURL:):
///   1. Retain _lastCompositedBuffer under _bufferLock (nanosecond hold).
///   2. All encoding and I/O run on the serial _renderQ (no UIKit, no main).
///   3. completion is always dispatched to the main thread.
///
/// The buffer is IOSurface-backed (kCVPixelBufferIOSurfacePropertiesKey).
/// CIImage reads the IOSurface without a CPU pixel copy.
/// The _renderQ may concurrently write a new frame to _lastCompositedBuffer
/// but that only replaces the pointer under the lock — it never mutates the
/// pixel data of the already-retained snapshot buffer.
- (void)capturePhotoToPath:(NSString *)path
                completion:(void (^)(NSDictionary * _Nullable result,
                                     FlutterError * _Nullable error))completion {

    // ── Step 1: Retain snapshot under lock ────────────────────────────────────
    //
    // Lock is held for nanoseconds: retain + NULL-check only.
    // No encoding or allocation happens inside the lock.
    os_unfair_lock_lock(&_bufferLock);
    CVPixelBufferRef snapshot =
        _lastCompositedBuffer ? CVPixelBufferRetain(_lastCompositedBuffer) : NULL;
    os_unfair_lock_unlock(&_bufferLock);

    // ── Step 2: Guard — no frame delivered yet ────────────────────────────────
    if (!snapshot) {
        NSLog(@"[VanguardMultiCamRenderer][MC-15] capturePhotoToPath: "
              "no composited frame available yet.");
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil,
                [FlutterError errorWithCode:@"NO_FRAME"
                                    message:@"No composited frame available yet"
                                    details:nil]);
        });
        return;
    }

    // ── Step 3: Encode and write on _renderQ ──────────────────────────────────
    //
    // Dispatch to the existing serial _renderQ so encoding is serialized
    // against ongoing renders. This prevents concurrent CIContext work and
    // keeps CPU pressure predictable.
    dispatch_async(_renderQ, ^{

        // Read dimensions from snapshot BEFORE releasing.
        size_t width  = CVPixelBufferGetWidth(snapshot);
        size_t height = CVPixelBufferGetHeight(snapshot);

        // Build CIImage. On A-series SoCs reads the IOSurface directly.
        // No UIImage, no CGImage, no VTCreateCGImageFromCVPixelBuffer.
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:snapshot];

        // Release the retained snapshot — ownership fully transferred to CIImage.
        // CIImage retains the IOSurface internally; releasing snapshot is safe.
        CVPixelBufferRelease(snapshot);

        // ── Determine color space ─────────────────────────────────────────────
        // ciImage.colorSpace is a non-owning reference — do NOT release it.
        // CGColorSpaceCreateDeviceRGB() returns +1 — MUST be released.
        CGColorSpaceRef cs = ciImage.colorSpace;
        BOOL ownedCS = NO;
        if (!cs) {
            cs = CGColorSpaceCreateDeviceRGB();
            ownedCS = YES;
        }

        // ── Encode to JPEG ────────────────────────────────────────────────────
        //
        // CIContext.JPEGRepresentationOfImage:colorSpace:options: is fully
        // thread-safe (CIContext is documented thread-safe by Apple).
        // Uses kCGImageDestinationLossyCompressionQuality @0.9 — identical to
        // VanguardCameraMediaSource and VGPhotoSinkNode.
        NSDictionary *encodeOptions = @{
            (id)kCGImageDestinationLossyCompressionQuality : @0.9,
        };
        NSData *jpegData = [_VGMCRDSharedCIContext()
            JPEGRepresentationOfImage:ciImage
                           colorSpace:cs
                              options:encodeOptions];

        if (ownedCS) {
            CGColorSpaceRelease(cs); // release only the space we created
        }

        if (!jpegData) {
            NSLog(@"[VanguardMultiCamRenderer][MC-15] capturePhotoToPath: "
                  "JPEG encoding failed.");
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil,
                    [FlutterError errorWithCode:@"ENCODE_FAIL"
                                        message:@"JPEG encoding failed"
                                        details:nil]);
            });
            return;
        }

        // ── Write to disk ─────────────────────────────────────────────────────
        NSError *writeErr = nil;
        [jpegData writeToFile:path
                      options:NSDataWritingAtomic
                        error:&writeErr];

        if (writeErr) {
            NSLog(@"[VanguardMultiCamRenderer][MC-15] capturePhotoToPath: "
                  "write failed: %@", writeErr.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil,
                    [FlutterError errorWithCode:@"WRITE_FAIL"
                                        message:writeErr.localizedDescription
                                        details:nil]);
            });
            return;
        }

        // ── Success ───────────────────────────────────────────────────────────
        NSLog(@"[VanguardMultiCamRenderer][MC-15] capturePhotoToPath: "
              "wrote %zu bytes to %@", (size_t)jpegData.length, path);
        NSDictionary *resultMap = @{
            @"filePath"  : path,
            @"width"     : @(width),
            @"height"    : @(height),
            @"sizeBytes" : @(jpegData.length),
            @"format"    : @"jpeg",
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(resultMap, nil);
        });
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Stop
// ─────────────────────────────────────────────────────────────────────────────

- (void)stop {
    // Set stopped flag immediately so any in-flight renderQ work can check it.
    _stopped = YES;

    // MC-17: Finalize any active recording before draining the renderQ.
    // Must run on _renderQ to serialize with any in-flight append.
    dispatch_sync(_renderQ, ^{
        if (self->_mcRecordingState == VGMCRecordingStateRecording ||
            self->_mcRecordingState == VGMCRecordingStateStarting) {

            NSLog(@"[VanguardMultiCamRenderer][MC-17] stop: force-finalizing active recording.");
            self->_mcRecordingState = VGMCRecordingStateStopping;

            AVAssetWriter      *writer = self->_assetWriter;
            AVAssetWriterInput *input  = self->_videoWriterInput;

            if (writer && writer.status == AVAssetWriterStatusWriting) {
                // MC-20: mark audio before video (AAC encoder flush order).
                if (self->_audioWriterInput) {
                    [self->_audioWriterInput markAsFinished];
                }
                [input markAsFinished];
                // Bounded wait — prevents hanging teardown if mediaserverd stalls.
                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                [writer finishWritingWithCompletionHandler:^{
                    dispatch_semaphore_signal(sem);
                }];
                long rc = dispatch_semaphore_wait(
                    sem, dispatch_time(DISPATCH_TIME_NOW, 3LL * NSEC_PER_SEC));
                if (rc != 0) {
                    NSLog(@"[VanguardMultiCamRenderer][MC-17] stop: "
                          "finishWriting did not complete within 3s — file may be truncated.");
                }
            }

            self->_assetWriter        = nil;
            self->_videoWriterInput   = nil;
            self->_audioWriterInput   = nil;  // MC-20
            self->_pixelBufferAdaptor = nil;
            self->_mcRecordingState   = VGMCRecordingStateIdle;
        }

        // Release last composited buffer under lock — no more raster-thread reads
        // are possible after doUnregisterTexture (called by plugin after stop).
        // Locking here is defensive: ensures correct pairing with copyPixelBuffer.
        os_unfair_lock_lock(&self->_bufferLock);
        CVPixelBufferRef buf = self->_lastCompositedBuffer;
        self->_lastCompositedBuffer = NULL;
        os_unfair_lock_unlock(&self->_bufferLock);
        if (buf) CVPixelBufferRelease(buf);
    });

    NSLog(@"[VanguardMultiCamRenderer][MC-9] stop: renderQ drained. "
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
// MARK: - MC-17: Video Recording
// ─────────────────────────────────────────────────────────────────────────────

/// Starts video-only recording of the composited preview buffer.
///
/// All writer setup runs on _renderQ to serialize with the render/append path.
/// completion: is dispatched to main thread.
- (void)startVideoRecordingToPath:(NSString *)path
                       completion:(void (^)(FlutterError * _Nullable error))completion {

    dispatch_async(_renderQ, ^{

        // Guard: at least one frame must have been rendered.
        if (self->_renderedFrames <= 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([FlutterError errorWithCode:@"NOT_RENDERING"
                                               message:@"No frames rendered yet — start preview first"
                                               details:nil]);
            });
            return;
        }

        // Guard: no recording already active.
        if (self->_mcRecordingState != VGMCRecordingStateIdle) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([FlutterError errorWithCode:@"ALREADY_RECORDING"
                                               message:@"A recording is already active"
                                               details:nil]);
            });
            return;
        }

        // ── Disk space pre-flight (200 MB minimum, matching single-camera policy) ──
        NSError *fsErr = nil;
        NSDictionary *attrs = [[NSFileManager defaultManager]
            attributesOfFileSystemForPath:[path stringByDeletingLastPathComponent]
                                    error:&fsErr];
        int64_t freeBytes = [attrs[NSFileSystemFreeSize] longLongValue];
        if (fsErr || freeBytes < 200 * 1024 * 1024) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([FlutterError errorWithCode:@"DISK_SPACE"
                                               message:@"Insufficient disk space (< 200 MB)"
                                               details:nil]);
            });
            return;
        }

        // ── AVAssetWriter setup ──────────────────────────────────────────────────
        NSError *writerErr = nil;
        NSURL *outputURL = [NSURL fileURLWithPath:path];
        AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:outputURL
                                                         fileType:AVFileTypeMPEG4
                                                            error:&writerErr];
        if (writerErr || !writer) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([FlutterError errorWithCode:@"WRITER_INIT_FAIL"
                                               message:writerErr.localizedDescription ?: @"AVAssetWriter creation failed"
                                               details:nil]);
            });
            return;
        }

        // Use current output dimensions if known; fall back to 1080×1920.
        int32_t w = (self->_outputWidth  > 0) ? self->_outputWidth  : 1080;
        int32_t h = (self->_outputHeight > 0) ? self->_outputHeight : 1920;

        // ── Video input — H.264, real-time ───────────────────────────────────────
        NSDictionary *videoSettings = @{
            AVVideoCodecKey  : AVVideoCodecTypeH264,
            AVVideoWidthKey  : @(w),
            AVVideoHeightKey : @(h),
            AVVideoCompressionPropertiesKey : @{
                AVVideoAverageBitRateKey         : @(10000000),   // 10 Mbps
                AVVideoMaxKeyFrameIntervalKey    : @30,           // 1 keyframe/sec at 30 fps
                AVVideoExpectedSourceFrameRateKey: @30,
                AVVideoAllowFrameReorderingKey   : @NO,
            },
        };
        AVAssetWriterInput *videoInput =
            [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                              outputSettings:videoSettings];
        videoInput.expectsMediaDataInRealTime = YES;

        // ── Pixel buffer adaptor — BGRA, matches pool format ─────────────────────
        NSDictionary *pbAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey     : @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey               : @(w),
            (id)kCVPixelBufferHeightKey              : @(h),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
            (id)kCVPixelBufferMetalCompatibilityKey  : @YES,
        };
        AVAssetWriterInputPixelBufferAdaptor *adaptor =
            [AVAssetWriterInputPixelBufferAdaptor
                assetWriterInputPixelBufferAdaptorWithAssetWriterInput:videoInput
                                           sourcePixelBufferAttributes:pbAttrs];

        if (![writer canAddInput:videoInput]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([FlutterError errorWithCode:@"WRITER_INIT_FAIL"
                                               message:@"Cannot add video input to AVAssetWriter"
                                               details:nil]);
            });
            return;
        }
        [writer addInput:videoInput];

        // ── MC-20: Best-effort AAC audio writer input ────────────────────────────
        // Mirrors single-camera AAC settings (VanguardCameraMediaSource L694-698).
        // Only added if canAddInput: passes. Failure is logged and silently skipped
        // so recording proceeds as video-only (unchanged from pre-MC-20 behavior).
        AVAssetWriterInput *audioInput = nil;
        NSDictionary *audioSettings = @{
            AVFormatIDKey           : @(kAudioFormatMPEG4AAC),
            AVSampleRateKey         : @44100,
            AVNumberOfChannelsKey   : @1,
            AVEncoderBitRateKey     : @(128000),
        };
        AVAssetWriterInput *candidateAudioInput =
            [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                              outputSettings:audioSettings];
        candidateAudioInput.expectsMediaDataInRealTime = YES;
        if ([writer canAddInput:candidateAudioInput]) {
            [writer addInput:candidateAudioInput];
            audioInput = candidateAudioInput;
            NSLog(@"[VanguardMultiCamRenderer][MC-20] AAC audio input added to writer.");
        } else {
            NSLog(@"[VanguardMultiCamRenderer][MC-20] Cannot add audio input — video-only recording.");
        }

        if (![writer startWriting]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([FlutterError errorWithCode:@"WRITER_INIT_FAIL"
                                               message:writer.error.localizedDescription ?: @"startWriting failed"
                                               details:nil]);
            });
            return;
        }

        // ── Activate recording state ─────────────────────────────────────────────
        // State is set to Starting; transitions to Recording on first appended frame.
        self->_assetWriter                 = writer;
        self->_videoWriterInput            = videoInput;
        self->_audioWriterInput            = audioInput;  // MC-20: nil if unavailable
        self->_pixelBufferAdaptor          = adaptor;
        self->_recordingOutputPath         = [path copy];
        self->_mcRecordingSessionStarted   = NO;
        self->_framesOfferedToWriter       = 0;
        self->_framesAppended              = 0;
        self->_framesDroppedWriterNotReady = 0;
        self->_recordingStartTime          = 0;
        self->_mcRecordingState            = VGMCRecordingStateStarting;

        NSLog(@"[VanguardMultiCamRenderer][MC-17] startVideoRecordingToPath: "
              "ready. outputDims=%dx%d audio=%@ path=%@",
              w, h, audioInput ? @"YES" : @"NO", path);

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil);  // success
        });
    });
}

/// Stops video-only recording and returns diagnostic metrics.
///
/// Dispatches finalization onto _renderQ. completion: is dispatched to main thread.
- (void)stopVideoRecordingWithCompletion:(void (^)(NSDictionary * _Nullable result,
                                                    FlutterError * _Nullable error))completion {

    dispatch_async(_renderQ, ^{

        // Guard: must be actively recording (or in starting state).
        if (self->_mcRecordingState != VGMCRecordingStateRecording &&
            self->_mcRecordingState != VGMCRecordingStateStarting) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [FlutterError errorWithCode:@"NOT_RECORDING"
                                                    message:@"No recording is currently active"
                                                    details:nil]);
            });
            return;
        }

        // Transition to stopping — prevents further appends in _renderPairedFrame:.
        self->_mcRecordingState = VGMCRecordingStateStopping;

        // Capture state before finalization.
        AVAssetWriter      *writer     = self->_assetWriter;
        AVAssetWriterInput *input      = self->_videoWriterInput;
        NSString           *outputPath = self->_recordingOutputPath;
        int32_t framesOffered  = self->_framesOfferedToWriter;
        int32_t framesAppended = self->_framesAppended;
        int32_t framesDropped  = self->_framesDroppedWriterNotReady;
        int32_t outWidth       = self->_outputWidth;
        int32_t outHeight      = self->_outputHeight;
        CFAbsoluteTime startTime = self->_recordingStartTime;

        // Handle the case where recording was started but no frame was ever appended.
        if (!writer || writer.status != AVAssetWriterStatusWriting) {
            self->_assetWriter        = nil;
            self->_videoWriterInput   = nil;
            self->_audioWriterInput   = nil;  // MC-20
            self->_pixelBufferAdaptor = nil;
            self->_mcRecordingState   = VGMCRecordingStateIdle;
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [FlutterError errorWithCode:@"NOT_RECORDING"
                                                    message:@"Writer is not in writing state"
                                                    details:nil]);
            });
            return;
        }

        // Finalize the writer.
        // MC-20: markAsFinished on audio input before video input (order matters
        // for AAC encoder flush). Both must be marked before finishWriting.
        if (self->_audioWriterInput) {
            [self->_audioWriterInput markAsFinished];
        }
        [input markAsFinished];
        [writer finishWritingWithCompletionHandler:^{
            // finishWriting fires on an arbitrary thread — re-dispatch to _renderQ
            // to safely access and clear ivars (matches single-camera FIX-B pattern).
            dispatch_async(self->_renderQ, ^{
                NSError *writerError = writer.error;
                AVAssetWriterStatus finalStatus = writer.status;

                // Compute duration.
                double durationSeconds = (startTime > 0)
                    ? (CFAbsoluteTimeGetCurrent() - startTime)
                    : 0.0;

                // Compute file size.
                NSError *sizeErr = nil;
                NSDictionary *fileAttrs = [[NSFileManager defaultManager]
                    attributesOfItemAtPath:outputPath error:&sizeErr];
                int64_t fileSizeBytes = [fileAttrs[NSFileSize] longLongValue];

                // Clear ivars.
                self->_assetWriter        = nil;
                self->_videoWriterInput   = nil;
                self->_audioWriterInput   = nil;  // MC-20
                self->_pixelBufferAdaptor = nil;
                self->_mcRecordingState   = VGMCRecordingStateIdle;

                NSLog(@"[VanguardMultiCamRenderer][MC-17] stopVideoRecording: "
                      "done. status=%ld duration=%.2fs offered=%d appended=%d dropped=%d "
                      "fileSize=%lld error=%@",
                      (long)finalStatus, durationSeconds,
                      framesOffered, framesAppended, framesDropped,
                      (long long)fileSizeBytes,
                      writerError.localizedDescription);

                if (writerError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(nil, [FlutterError errorWithCode:@"WRITER_FINISH_FAIL"
                                                            message:writerError.localizedDescription
                                                            details:nil]);
                    });
                    return;
                }

                NSDictionary *resultMap = @{
                    @"filePath"                    : outputPath ?: @"",
                    @"durationSeconds"             : @(durationSeconds),
                    @"width"                       : @(outWidth),
                    @"height"                      : @(outHeight),
                    @"framesOffered"               : @(framesOffered),
                    @"framesAppended"              : @(framesAppended),
                    @"framesDroppedWriterNotReady" : @(framesDropped),
                    @"writerStatus"                : @((NSInteger)finalStatus),
                    @"fileSizeBytes"               : @(fileSizeBytes),
                };
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(resultMap, nil);
                });
            });
        }];
    });
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
// MARK: - MC-20: Audio delegate
// ─────────────────────────────────────────────────────────────────────────────

/// Called on the source's captureQ. The sample buffer is borrowed (+0).
///
/// MC-20 threading contract (Opus-validated):
///   1. CFRetain the sample buffer here on captureQ — extends its lifetime.
///   2. dispatch_async to _renderQ — serializes with all video appends.
///   3. On renderQ: check guards, append if safe, CFRelease unconditionally.
///
/// Guards on _renderQ (all must pass):
///   - _mcRecordingState == VGMCRecordingStateRecording
///   - _mcRecordingSessionStarted == YES (startSessionAtSourceTime: was called)
///   - _assetWriter.status == AVAssetWriterStatusWriting
///   - _audioWriterInput != nil
///   - _audioWriterInput.isReadyForMoreMediaData == YES
///
/// Early audio (before first video frame establishes session time) is dropped
/// by the _mcRecordingSessionStarted guard. No buffering, no timestamp rebasing.
- (void)multiCamMediaSource:(VanguardMultiCamMediaSource *)source
  didOutputAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {

    // Retain on captureQ — makes the buffer safe to use asynchronously.
    CFRetain(sampleBuffer);

    dispatch_async(_renderQ, ^{
        // ── Guard 1: must be actively recording (not starting, stopping, or idle) ──
        // Starting state intentionally excluded: session hasn't begun yet.
        // Audio appended before startSessionAtSourceTime: would crash the writer.
        if (self->_mcRecordingState != VGMCRecordingStateRecording ||
            !self->_mcRecordingSessionStarted) {
            CFRelease(sampleBuffer);
            return;
        }

        // ── Guard 2: writer must be in writing state ───────────────────────────
        if (!self->_assetWriter ||
            self->_assetWriter.status != AVAssetWriterStatusWriting) {
            CFRelease(sampleBuffer);
            return;
        }

        // ── Guard 3: audio writer input must be present and ready ──────────────
        if (!self->_audioWriterInput ||
            !self->_audioWriterInput.isReadyForMoreMediaData) {
            CFRelease(sampleBuffer);
            return;
        }

        // ── Append ────────────────────────────────────────────────────────────
        BOOL ok = [self->_audioWriterInput appendSampleBuffer:sampleBuffer];
        if (!ok) {
            NSLog(@"[VanguardMultiCamRenderer][MC-20] audio appendSampleBuffer failed. "
                  "writerStatus=%ld error=%@",
                  (long)self->_assetWriter.status,
                  self->_assetWriter.error.localizedDescription);
        }

        CFRelease(sampleBuffer);
    });
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
        NSLog(@"[VanguardMultiCamRenderer][MC-9] _renderPairedFrame: "
              "nil buffer — skipping.");
        return;
    }

    // ── 1. Dimensions ─────────────────────────────────────────────────────────
    size_t primW = CVPixelBufferGetWidth(primaryBuf);
    size_t primH = CVPixelBufferGetHeight(primaryBuf);
    size_t secW  = CVPixelBufferGetWidth(secondaryBuf);
    size_t secH  = CVPixelBufferGetHeight(secondaryBuf);

    if (primW == 0 || primH == 0 || secW == 0 || secH == 0) {
        NSLog(@"[VanguardMultiCamRenderer][MC-9] _renderPairedFrame: "
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
            NSLog(@"[VanguardMultiCamRenderer][MC-9] _renderPairedFrame: "
                  "pool creation failed for %zux%zu — skipping.", primW, primH);
            return;
        }
        _poolWidth  = primW;
        _poolHeight = primH;
        NSLog(@"[VanguardMultiCamRenderer][MC-9] pool created: %zux%zu BGRA.",
              primW, primH);
    }

    // ── 3. Allocate output buffer from pool ───────────────────────────────────
    CVPixelBufferRef outputBuf = NULL;
    CVReturn poolRet = CVPixelBufferPoolCreatePixelBuffer(nil, _pool, &outputBuf);
    if (poolRet != kCVReturnSuccess || !outputBuf) {
        NSLog(@"[VanguardMultiCamRenderer][MC-9] _renderPairedFrame: "
              "CVPixelBufferPoolCreatePixelBuffer failed (ret=%d).", poolRet);
        return;
    }

    // ── 4. Build CIImages ─────────────────────────────────────────────────────
    CIImage *primaryCI   = [CIImage imageWithCVPixelBuffer:primaryBuf];
    CIImage *secondaryCI = [CIImage imageWithCVPixelBuffer:secondaryBuf];
    if (!primaryCI || !secondaryCI) {
        NSLog(@"[VanguardMultiCamRenderer][MC-9] _renderPairedFrame: "
              "CIImage creation failed.");
        CVPixelBufferRelease(outputBuf);
        return;
    }

    // ── 5. Compose based on layout mode (MC-12) ───────────────────────────────
    CIImage *composited = nil;

    if (_layoutConfig.layoutMode == VGDualCameraLayoutModeSplitScreen) {

        if (_layoutConfig.splitConfig.direction == VGSplitScreenDirectionLeftRight) {
            // ── Left/Right V-split path (always 50/50 locked) ─────────────────
            VGDCSplitRectsLR lrRects = VGDCLayoutComputeSplitRectsLeftRight(
                primW, primH, _layoutConfig.splitConfig);
            if (lrRects.isValid) {
                // Scale and crop primary into left band.
                VGDCAspectFillResult primFill = VGDCLayoutComputeAspectFill(
                    primW, primH, lrRects.leftRect);
                CGPoint primOrigin = primaryCI.extent.origin;
                CIImage *primNorm = (primOrigin.x != 0.0 || primOrigin.y != 0.0)
                    ? [primaryCI imageByApplyingTransform:
                        CGAffineTransformMakeTranslation(-primOrigin.x, -primOrigin.y)]
                    : primaryCI;
                CIImage *primFilled = [[primNorm
                    imageByApplyingTransform:CGAffineTransformMakeScale(primFill.scale, primFill.scale)]
                    imageByApplyingTransform:CGAffineTransformMakeTranslation(primFill.offsetX, primFill.offsetY)];
                CIImage *primCropped = [primFilled imageByCroppingToRect:lrRects.leftRect];

                // Scale and crop secondary into right band.
                VGDCAspectFillResult secFill = VGDCLayoutComputeAspectFill(
                    secW, secH, lrRects.rightRect);
                CGPoint secOrigin = secondaryCI.extent.origin;
                CIImage *secNorm = (secOrigin.x != 0.0 || secOrigin.y != 0.0)
                    ? [secondaryCI imageByApplyingTransform:
                        CGAffineTransformMakeTranslation(-secOrigin.x, -secOrigin.y)]
                    : secondaryCI;
                CIImage *secFilled = [[secNorm
                    imageByApplyingTransform:CGAffineTransformMakeScale(secFill.scale, secFill.scale)]
                    imageByApplyingTransform:CGAffineTransformMakeTranslation(secFill.offsetX, secFill.offsetY)];
                CIImage *secCropped = [secFilled imageByCroppingToRect:lrRects.rightRect];

                // Composite onto a black canvas.
                CIImage *black = [[CIImage imageWithColor:[CIColor blackColor]]
                    imageByCroppingToRect:CGRectMake(0, 0, (CGFloat)primW, (CGFloat)primH)];
                composited = [primCropped imageByCompositingOverImage:
                                [secCropped imageByCompositingOverImage:black]];
            } else {
                NSLog(@"[VanguardMultiCamRenderer] leftRight split rects invalid — "
                      "falling back to default PiP.");
            }
        } else {
            // ── Top/Bottom H-split path ───────────────────────────────────────
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
                NSLog(@"[VanguardMultiCamRenderer][MC-12] split rects invalid — "
                      "falling back to default PiP.");
            }
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
        NSLog(@"[VanguardMultiCamRenderer][MC-9] _renderPairedFrame: "
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

    // ── 7a. MC-17: Append to video writer (before buffer swap) ────────────────
    //
    // outputBuf is still exclusively owned by this scope (+1 from pool).
    // appendPixelBuffer:withPresentationTime: is synchronous — it copies pixel
    // data into the encoder pipeline and returns before the next line executes.
    // We therefore do NOT need an extra CVPixelBufferRetain here.
    //
    // Insertion point: after CIContext render is complete; before _lastCompositedBuffer
    // swap so the buffer is still solely in our scope.
    if (_mcRecordingState == VGMCRecordingStateStarting ||
        _mcRecordingState == VGMCRecordingStateRecording) {

        _framesOfferedToWriter++;
        CMTime pts = frame.frontPTS;  // consistent single PTS source

        if (!_videoWriterInput.isReadyForMoreMediaData) {
            // Writer backpressure — skip this frame, preserve preview.
            _framesDroppedWriterNotReady++;
            NSLog(@"[VanguardMultiCamRenderer][MC-17] writer not ready — drop frame "
                  "(offered=%d dropped=%d)",
                  _framesOfferedToWriter, _framesDroppedWriterNotReady);
        } else {
            // First frame: start the writer session at this hardware PTS.
            // Matches VanguardCameraMediaSource pattern (deferred start).
            if (!_mcRecordingSessionStarted) {
                [_assetWriter startSessionAtSourceTime:pts];
                _mcRecordingSessionStarted = YES;
                _recordingStartTime        = CFAbsoluteTimeGetCurrent();
                _mcRecordingState          = VGMCRecordingStateRecording;
                NSLog(@"[VanguardMultiCamRenderer][MC-17] session started at hardware PTS.");
            }

            BOOL ok = [_pixelBufferAdaptor appendPixelBuffer:outputBuf
                                        withPresentationTime:pts];
            if (ok) {
                _framesAppended++;
            } else {
                NSLog(@"[VanguardMultiCamRenderer][MC-17] appendPixelBuffer failed. "
                      "writerStatus=%ld error=%@",
                      (long)_assetWriter.status,
                      _assetWriter.error.localizedDescription);
            }
        }

        // Detect writer failure (e.g. disk full mid-recording).
        if (_assetWriter.status == AVAssetWriterStatusFailed) {
            NSLog(@"[VanguardMultiCamRenderer][MC-17] writer FAILED: %@",
                  _assetWriter.error.localizedDescription);
            _assetWriter        = nil;
            _videoWriterInput   = nil;
            _pixelBufferAdaptor = nil;
            _mcRecordingState   = VGMCRecordingStateIdle;
        }
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
        NSLog(@"[VanguardMultiCamRenderer][MC-12] first frame | "
              "mode=%s canvas=%zux%zu renderMs=%.2f texture=%s",
              _layoutConfig.layoutMode == VGDualCameraLayoutModeSplitScreen
                  ? "splitScreen" : "pip",
              primW, primH, renderMs,
              _textureRegistered ? "YES" : "NO");
    }
}

@end

