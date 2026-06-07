// VanguardMultiCamPairedFrame.h
// vanguard_media_engine — MC-8: MultiCam paired-frame pixel buffer lifecycle.
//
// ═══════════════════════════════════════════════════════════════════════════════
// MC-8 — MULTICAM PAIRED FRAME (BUFFER OWNERSHIP WRAPPER)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Immutable NSObject wrapper holding a software-paired front/back CVPixelBuffer
// pair delivered by VanguardMultiCamMediaSource.
//
// ── OWNERSHIP CONTRACT ────────────────────────────────────────────────────────
//
//   The designated initializer receives ALREADY-RETAINED (+1) pixel buffers.
//   It does NOT call CVPixelBufferRetain internally.
//   dealloc calls CVPixelBufferRelease on both buffers.
//
//   Callers MUST NOT release the buffers after passing them to init.
//   This object becomes the exclusive owner after construction.
//
//   Example correct usage (inside captureOutput:didOutputSampleBuffer:):
//
//     CVPixelBufferRef front = CMSampleBufferGetImageBuffer(frontSampleBuffer);
//     CVPixelBufferRetain(front);   // +1 — ownership to paired frame
//     CVPixelBufferRef back = _pendingBackBuffer;  // already +1
//     _pendingBackBuffer = NULL;    // clear pending slot without releasing
//
//     VanguardMultiCamPairedFrame *frame =
//         [[VanguardMultiCamPairedFrame alloc]
//             initWithFrontBuffer:front frontPTS:frontPTS
//                      backBuffer:back  backPTS:backPTS];
//     // frame dealloc → CVPixelBufferRelease(front) + CVPixelBufferRelease(back)
//
// ── THREAD SAFETY ─────────────────────────────────────────────────────────────
//
//   Immutable after construction. Safe to read from any thread as long as
//   the object is alive. In MC-8, the object is created and consumed
//   synchronously on the captureQ serial queue inside the delegate callback.
//
// ── WHAT IT DOES NOT DO ──────────────────────────────────────────────────────
//
//   Does NOT depend on Metal, CoreImage, Flutter, or AVFoundation.
//   Does NOT touch VGCameraGraphSession or VanguardCameraMediaSource.
//   Does NOT create or register any Flutter texture.
//   Does NOT render frames.
//
// ── AVAILABILITY ─────────────────────────────────────────────────────────────
//
//   No OS version restriction — only Foundation/CoreVideo/CoreMedia.
//
// ── DO NOT MODIFY ─────────────────────────────────────────────────────────────
//
//   VanguardMultiCamFramePairer.*    VanguardMultiCamSyncDiagnostic.*
//   VanguardCameraMediaSource.*      VGCameraGraphSession.*
//   VanguardMediaSource.h            VanguardMediaEnginePlugin.swift
//   connectsapp_*/**                 Android code
//   Phase 8 overlay files

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VanguardMultiCamPairedFrame ──────────────────────────────────────────────

/// Immutable container holding a software-paired front/back CVPixelBuffer pair.
///
/// ## Ownership
/// The initializer takes ownership of two already-retained (+1) pixel buffers.
/// `dealloc` releases both via `CVPixelBufferRelease`.
/// Callers MUST NOT release the buffers after passing them to the initializer.
///
/// ## Thread safety
/// Immutable after construction. Safe to pass between threads as long as the
/// object remains alive. In production use (MC-8), delivery is synchronous
/// on the captureQ serial queue.
///
/// ## What this is NOT
/// Not a renderer, compositor, or texture. Contains only pixel buffer references
/// and presentation timestamps.
@interface VanguardMultiCamPairedFrame : NSObject

// ─── Buffer access ────────────────────────────────────────────────────────────

/// The front-camera pixel buffer. Retained by this object.
/// Valid until this object is deallocated.
@property (nonatomic, readonly) CVPixelBufferRef frontBuffer;

/// The front-camera presentation timestamp (PTS).
@property (nonatomic, readonly) CMTime frontPTS;

/// The back-camera pixel buffer. Retained by this object.
/// Valid until this object is deallocated.
@property (nonatomic, readonly) CVPixelBufferRef backBuffer;

/// The back-camera presentation timestamp (PTS).
@property (nonatomic, readonly) CMTime backPTS;

// ─── Designated initializer ───────────────────────────────────────────────────

/// Initializes the paired frame by taking ownership of two already-retained buffers.
///
/// @param frontBuffer  A +1 retained front-camera CVPixelBufferRef.
///                     This object takes ownership — do NOT release after init.
/// @param frontPTS     The front-camera presentation timestamp.
/// @param backBuffer   A +1 retained back-camera CVPixelBufferRef.
///                     This object takes ownership — do NOT release after init.
/// @param backPTS      The back-camera presentation timestamp.
- (instancetype)initWithFrontBuffer:(CVPixelBufferRef)frontBuffer
                           frontPTS:(CMTime)frontPTS
                         backBuffer:(CVPixelBufferRef)backBuffer
                            backPTS:(CMTime)backPTS NS_DESIGNATED_INITIALIZER;

/// Unavailable. Use initWithFrontBuffer:frontPTS:backBuffer:backPTS:.
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
