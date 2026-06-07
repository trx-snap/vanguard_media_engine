// VanguardMultiCamRenderDiagnostic.h
// vanguard_media_engine — MC-9: Offscreen MultiCam render diagnostic.
//
// ═══════════════════════════════════════════════════════════════════════════════
// MC-9 — MULTICAM RENDER DIAGNOSTIC (OFFSCREEN COMPOSITION, DIAGNOSTIC-ONLY)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Diagnostic-only offscreen compositor that receives VanguardMultiCamPairedFrame
// objects from VanguardMultiCamMediaSource and composites them using CoreImage
// into a CVPixelBuffer pool. No Flutter texture. No visible preview.
//
// ── PURPOSE ──────────────────────────────────────────────────────────────────
//
//   MC-9 proves that real-time offscreen CoreImage composition of two 1080p
//   BGRA streams at ~26–30 fps is feasible within the device's thermal and
//   memory budget, before any Flutter texture integration (MC-10+).
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
//   Flutter texture delivery, or camera graph integration.
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
//   _lastCompositedBuffer: Retained for MC-10 readiness. Released on next
//   successful render, on stop, and in dealloc.
//
// ── THREAD SAFETY ─────────────────────────────────────────────────────────────
//
//   Delegate callback fires on VanguardMultiCamMediaSource's captureQ (serial).
//   _renderingInFlight is written on captureQ (read/check/set — all on captureQ).
//   The NO write from renderQ is a single aligned store (safe on ARM64).
//
//   All other ivars are accessed on renderQ only.
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
//   VanguardMediaEnginePlugin.swift  connectsapp_*/**
//   Phase 8 overlay files

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "VanguardMultiCamMediaSource.h"

NS_ASSUME_NONNULL_BEGIN

// ─── VanguardMultiCamRenderDiagnostic ─────────────────────────────────────────

/// Diagnostic-only offscreen compositor for MultiCam paired frames.
///
/// Conforms to `VanguardMultiCamMediaSourceDelegate` and composites received
/// front/back paired frames offscreen using CoreImage and CVPixelBufferPool.
///
/// ## Usage
/// ```objc
/// VanguardMultiCamRenderDiagnostic *renderer = [[VanguardMultiCamRenderDiagnostic alloc] init];
/// source.delegate = renderer;
/// // ... run source for 3 seconds ...
/// NSDictionary *metrics = renderer.metrics;
/// ```
///
/// ## Diagnostic-Only
/// Not for production use. No Flutter texture. No visible preview.
/// Do NOT integrate with VGCameraGraphSession or VanguardCameraMediaSource.
@interface VanguardMultiCamRenderDiagnostic : NSObject <VanguardMultiCamMediaSourceDelegate>

// ─── Designated initializer ───────────────────────────────────────────────────

/// Initializes the renderer. Call before assigning as a delegate.
///
/// Creates the serial renderQ and dedicated CIContext.
/// Does NOT allocate the CVPixelBufferPool (created lazily on first render).
- (instancetype)init NS_DESIGNATED_INITIALIZER;

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
/// Safe to call from any thread after source.stop().
- (NSDictionary<NSString *, NSNumber *> *)metrics;

// ─── Cleanup ──────────────────────────────────────────────────────────────────

/// Releases the last composited buffer and tears down pool resources.
///
/// Call after source.stop() to ensure all retained buffers are freed before
/// reading metrics. Safe to call multiple times (idempotent).
///
/// After stop, the delegate will not process any further frames (the source
/// has already stopped delivering them). This method completes the cleanup.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
