// VGFaceTrackingDiagnosticOverlay.h
// Phase 9B-Reset — Face Tracking Diagnostic Overlay (coordinate ground-truth tool)
//
// PURPOSE (read before editing):
//   This file exists solely to prove that Vision face detection coordinates
//   are correctly aligned with the live camera preview in the Flutter Texture
//   pipeline. It was written during Phase 9B-Reset to diagnose the Y-axis
//   inversion issue before resuming BeautyV2 / segmentation / mask work.
//
//   CONFIRMED: C = flip Y transform (Vision bottom-left → CG top-left).
//
//   This overlay does NOT:
//     - Feed or replace BeautyV2 mask logic.
//     - Modify the production mask buffer.
//     - Alter segmentation output.
//     - Affect production frame delivery in non-DEBUG builds.
//
// GATE — two conditions BOTH required to draw:
//   1. DEBUG build  (compile-time #if DEBUG in VanguardMetalRenderer.m)
//   2. Launch environment variable:  VG_FACE_TRACKING_DIAGNOSTIC = 1
//      Set in Xcode: Product → Scheme → Run → Arguments → Environment Variables.
//
//   In non-DEBUG builds: the call site in VanguardMetalRenderer.m is wrapped
//     in #if DEBUG and the overlay is never called. Zero overhead.
//   In DEBUG without the flag: +enabled returns NO immediately. Zero drawing.
//   In DEBUG with the flag: full diagnostic draws onto the Flutter Texture buffer.
//
// RECORDING NOTE:
//   While enabled, overlay marks appear in any concurrent recording because
//   both the display and recording read the same _latestPixelBuffer.
//   Disable before recording production content.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface VGFaceTrackingDiagnosticOverlay : NSObject

/// Returns YES only in DEBUG builds when VG_FACE_TRACKING_DIAGNOSTIC=1 is set.
/// Always returns NO in non-DEBUG builds (the call site is also wrapped in #if DEBUG).
@property (class, nonatomic, readonly) BOOL enabled;

/// Shared singleton used by VanguardMetalRenderer.
/// Safe to call; no-op if +enabled returns NO.
@property (class, nonatomic, readonly) VGFaceTrackingDiagnosticOverlay *shared;

/// Draw the full diagnostic suite onto pixelBuffer (must be 32BGRA, IOSurface-backed).
///
/// Called from VanguardMetalRenderer.presentEnvelope: immediately before
/// _latestPixelBuffer swap. Drawing lands on the exact buffer Flutter displays.
///
/// @param pixelBuffer  The incoming frame buffer. Must be 32BGRA.
/// @param pts          Presentation timestamp from the envelope.
/// @param metadata     VGFrameEnvelope.metadata bridged as NSDictionary (may be nil).
///                     Used read-only to extract VGSegmentationMetadataKeySkinMaskBuffer
///                     for visual comparison. Never retained, never modified.
///
/// Draws (when enabled):
///   • Static red canary (border + cross) — confirms overlay path is live.
///   • Confirmed C/flipY face bbox (cyan) + centre dot.
///   • Raw Vision face-contour polygon (orange fill, yellow outline).
///   • Landmark dots: contour(green), eyes(yellow), brows(orange), lips(magenta), nose(white).
///   • Production mask visual comparison (purple tint from metadata) — display-only.
- (void)drawOverlayOn:(CVPixelBufferRef)pixelBuffer
                  pts:(CMTime)pts
             metadata:(nullable NSDictionary *)metadata;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
