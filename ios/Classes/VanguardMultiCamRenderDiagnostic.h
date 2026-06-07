// VanguardMultiCamRenderDiagnostic.h
// vanguard_media_engine — MC-9/MC-10: MultiCam render diagnostic.
//
// ═══════════════════════════════════════════════════════════════════════════════
// MC-9/MC-10 — MULTICAM RENDER DIAGNOSTIC (OFFSCREEN COMPOSITION + TEXTURE)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Diagnostic-only offscreen compositor that receives VanguardMultiCamPairedFrame
// objects from VanguardMultiCamMediaSource and composites them using CoreImage
// into a CVPixelBuffer pool.
//
// MC-9: offscreen-only. No Flutter texture. No visible preview.
// MC-10: adds FlutterTexture protocol conformance for live visible preview
//        via the start/stop API (startMultiCamRenderDiagnostic /
//        stopMultiCamRenderDiagnostic). The blocking run API is preserved.
//
// ── PURPOSE ──────────────────────────────────────────────────────────────────
//
//   MC-9 proves that real-time offscreen CoreImage composition of two 1080p
//   BGRA streams at ~26–30 fps is feasible within the device's thermal and
//   memory budget.
//
//   MC-10 proves that the composited buffer can be delivered to Flutter's
//   rendering pipeline through <FlutterTexture>, producing a live visible
//   dual-camera PiP preview.
//
//   The class composites:
//     - Back camera = full canvas (primary)
//     - Front camera = PiP inset (secondary, bottom-right corner)
//     - Layout math via VGDualCameraLayoutMath (MC-1A)
//     - Render via CIContext into CVPixelBufferPool
//
// ── DESIGN CONSTRAINTS ───────────────────────────────────────────────────────
//
//   DIAGNOSTIC-ONLY: This class must NOT be used for production rendering,
//   camera graph integration, or any Flutter texture delivery outside the
//   MC-10 start/stop diagnostic route.
//
//   Frame dropping: If the renderQ is busy when a new paired frame arrives,
//   the new frame is silently dropped (_renderingInFlight flag). This preserves
//   system stability at the cost of occasional frame loss.
//
//   CIFilter isolation: All CIFilter instances are created per-render call on
//   renderQ. CIFilter is NOT thread-safe per Apple documentation.
//
//   Buffer lifetime: VanguardMultiCamPairedFrame is ARC-retained through the
//   async dispatch, releasing both pixel buffers when the frame is done.
//
//   _lastCompositedBuffer: Protected by os_unfair_lock (_bufferLock).
//   Written on renderQ; read on Flutter raster thread via copyPixelBuffer.
//   Released on next successful render, on stop, and in dealloc.
//
// ── THREAD SAFETY ─────────────────────────────────────────────────────────────
//
//   Delegate callback fires on VanguardMultiCamMediaSource's captureQ (serial).
//   _renderingInFlight is written on captureQ (read/check/set — all on captureQ).
//   The NO write from renderQ is a single aligned store (safe on ARM64).
//
//   _lastCompositedBuffer is protected by os_unfair_lock (_bufferLock).
//   Lock scope covers only pointer swap/retain/release — not CIContext rendering.
//
//   textureFrameAvailable: dispatched to main queue from renderQ after each
//   successful composition, but only when a texture is registered.
//
//   registerTexture / unregisterTexture: called on main thread only.
//
// ── AVAILABILITY ─────────────────────────────────────────────────────────────
//
//   No OS version restriction beyond the 13.0 requirement of the parent source.
//   This class itself has no iOS 13 API dependency.
//
// ── DO NOT MODIFY ─────────────────────────────────────────────────────────────
//
//   VanguardMultiCamMediaSource.*    VanguardMultiCamPairedFrame.*
//   VanguardMultiCamFramePairer.*    VGCameraGraphSession.*
//   VanguardCameraMediaSource.*      VanguardMediaSource.h
//   Phase 8 overlay files

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Flutter/Flutter.h>
#import "VanguardMultiCamMediaSource.h"
#import "VGDualCameraLayoutMath.h"

NS_ASSUME_NONNULL_BEGIN

// ─── VGMCRDLayoutConfig ───────────────────────────────────────────────────────
/// Parsed layout configuration passed from Dart via the method channel.
/// MC-12: Drives PiP anchor/size or split-screen ratio in _renderPairedFrame:
///
/// Parsed defensively from a raw [String:Any] map.
/// All fields have safe defaults matching the existing MC-9/MC-10 behaviour.
typedef struct {
    VGDualCameraLayoutMode layoutMode;     ///< .pip (0) or .splitScreen (1). Default: .pip.
    VGPiPLayoutConfig      pipConfig;     ///< PiP geometry. Default: bottomRight, 0.35, 0.018, 24pt.
    VGSplitScreenLayoutConfig splitConfig; ///< Split-screen geometry. Default: ratio 0.5.
} VGMCRDLayoutConfig;

/// Returns the default layout config (bottom-right PiP, 35% width).
/// Used when no config is provided and as a fallback for malformed input.
static inline VGMCRDLayoutConfig VGMCRDDefaultLayoutConfig(void) {
    VGMCRDLayoutConfig c;
    c.layoutMode              = VGDualCameraLayoutModePiP;
    c.pipConfig.anchor        = VGPiPAnchorBottomRight;
    c.pipConfig.widthFraction  = 0.35;
    c.pipConfig.marginFraction = 0.018;
    c.pipConfig.cornerRadius   = 24.0;
    c.pipConfig.opacity        = 1.0;
    c.splitConfig.splitRatio   = 0.5;
    return c;
}

/// Diagnostic-only offscreen compositor for MultiCam paired frames.
///
/// ## MC-9: Blocking run API
/// Conforms to `VanguardMultiCamMediaSourceDelegate`. Composites received
/// front/back paired frames offscreen using CoreImage and CVPixelBufferPool.
///
/// ## MC-10: Start/stop texture API
/// Implements `<FlutterTexture>` to deliver composited buffers to Flutter.
/// When instantiated with a `FlutterTextureRegistry`, registers a texture on
/// init and signals `textureFrameAvailable` after each successful composition.
///
/// ## Usage (MC-9 blocking)
/// ```objc
/// VanguardMultiCamRenderDiagnostic *renderer = [[VanguardMultiCamRenderDiagnostic alloc] init];
/// source.delegate = renderer;
/// // ... run source for 3 seconds ...
/// NSDictionary *metrics = renderer.metrics;
/// ```
///
/// ## Usage (MC-10 start/stop)
/// ```objc
/// VanguardMultiCamRenderDiagnostic *renderer =
///     [[VanguardMultiCamRenderDiagnostic alloc] initWithTextureRegistry:registry];
/// int64_t textureId = renderer.textureId;
/// source.delegate = renderer;
/// // ... run source until stopped ...
/// [renderer doUnregisterTexture];
/// NSDictionary *metrics = renderer.metrics;
/// ```
///
/// ## Diagnostic-Only
/// Not for production use. Do NOT integrate with VGCameraGraphSession or
/// VanguardCameraMediaSource.
@interface VanguardMultiCamRenderDiagnostic : NSObject <VanguardMultiCamMediaSourceDelegate, FlutterTexture>

// ─── Designated initializers ──────────────────────────────────────────────────

/// MC-9 initializer. No texture registry. No Flutter texture.
///
/// Creates the serial renderQ and dedicated CIContext.
/// Does NOT allocate the CVPixelBufferPool (created lazily on first render).
/// Does NOT call textureFrameAvailable after renders.
- (instancetype)init NS_DESIGNATED_INITIALIZER;

/// MC-10 initializer. Registers a Flutter texture on the main thread.
///
/// Creates the serial renderQ, dedicated CIContext, and registers this object
/// as a FlutterTexture with the provided registry. The texture ID is stored in
/// `textureId` and is valid until `doUnregisterTexture` is called.
///
/// MUST be called on the main thread (Flutter requirement for registerTexture:).
///
/// @param registry  The Flutter texture registry from the plugin registrar.
- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry
    NS_DESIGNATED_INITIALIZER;

// ─── Flutter Texture (MC-10) ──────────────────────────────────────────────────

/// The registered Flutter texture ID. Valid only after initWithTextureRegistry:.
/// 0 when no texture is registered (init-only path).
@property (nonatomic, readonly) int64_t textureId;

/// Unregisters the Flutter texture from the registry.
///
/// Must be called on the main thread AFTER draining the renderQ (stop).
/// After this call, Flutter will never call copyPixelBuffer again.
/// Safe to call multiple times (idempotent).
- (void)doUnregisterTexture;

// ─── Metrics ──────────────────────────────────────────────────────────────────

/// Number of frames successfully rendered into the output pool.
@property (nonatomic, readonly) int32_t renderedFrames;

/// Number of paired frames dropped because the renderQ was busy.
@property (nonatomic, readonly) int32_t droppedRenderFrames;

/// Mean render duration in milliseconds. 0.0 if no frames were rendered.
@property (nonatomic, readonly) double averageRenderMs;

/// Peak render duration in milliseconds. 0.0 if no frames were rendered.
@property (nonatomic, readonly) double peakRenderMs;

/// Width of the output composite buffer in pixels. 0 until first render.
@property (nonatomic, readonly) int32_t outputWidth;

/// Height of the output composite buffer in pixels. 0 until first render.
@property (nonatomic, readonly) int32_t outputHeight;

/// Returns a snapshot of all render metrics as a dictionary.
///
/// Keys (all NSNumber):
///   @"renderedFrames"      — int32_t: successfully composited frames
///   @"droppedRenderFrames" — int32_t: frames dropped (renderQ busy)
///   @"averageRenderMs"     — double:  mean render time in milliseconds
///   @"peakRenderMs"        — double:  peak render time in milliseconds
///   @"outputWidth"         — int32_t: output buffer width in pixels
///   @"outputHeight"        — int32_t: output buffer height in pixels
///
/// Safe to call from any thread after source.stop() and self.stop().
- (NSDictionary<NSString *, NSNumber *> *)metrics;

// ─── Cleanup ──────────────────────────────────────────────────────────────────

/// Drains the renderQ and releases the last composited buffer.
///
/// Call after source.stop() to ensure all retained buffers are freed before
/// reading metrics. Safe to call multiple times (idempotent).
///
/// For the MC-10 start/stop path, call BEFORE doUnregisterTexture so that
/// renderQ is drained before the raster thread is unblocked from unregister.
- (void)stop;

/// MC-12: Set layout configuration before calling source.start().
///
/// Not thread-safe — must be called before the source delegate fires.
/// After start, the config is read on renderQ only.
- (void)setLayoutConfig:(VGMCRDLayoutConfig)config;

/// MC-12: Parse a VGLivePreviewConfig.toMap() dictionary into a VGMCRDLayoutConfig.
///
/// Fully defensive: any missing/malformed field falls back to the default.
/// Called from Swift, which cannot directly reference C-struct enum constants.
+ (VGMCRDLayoutConfig)layoutConfigFromMap:(NSDictionary<NSString *, id> * _Nullable)map;

@end

NS_ASSUME_NONNULL_END
