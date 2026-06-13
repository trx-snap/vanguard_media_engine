// VGFaceNeckBeautyMaskPolicy.h
// Phase 9B-1 — Deterministic post-processing policy.
//
// Converts a raw MediaPipe Selfie Multiclass float output tensor
// ([1, 256, 256, 6] NHWC) into a VGSkinMask using:
//
//   1. Confidence competition (face+body vs hair, clothes, others).
//   2. Face bounding-box derivation from class-3 face-skin pixels.
//   3. Neck-ROI projection below the face box.
//   4. Forehead trim (per-column, fraction of faceHeight).
//   5. Gated forehead expansion (blocked by high hair/clothes confidence).
//   6. Morphological open/close cleanup (simple CPU loops, kernel = 3×3).
//   7. Motion-adaptive temporal EMA on a 256×256 float history buffer.
//
// Threading:
//   processTensor:… is synchronous and NOT thread-safe. Wrap in a serial
//   dispatch queue when calling from concurrent producers (VGLiteRTMaskProvider
//   will do this in Phase 9B-2). resetTemporalState is also not thread-safe
//   by itself — call from the same queue as processTensor.
//
// Non-goals (Phase 9B-1):
//   No TFLite API calls — policy operates on a pre-computed float* pointer.
//   No Metal shaders — pure CPU.
//   No production graph wiring — that is Phase 9B-2.

#pragma once
#import <Foundation/Foundation.h>
#import <CoreMedia/CMTime.h>

@class VGSkinMask;

NS_ASSUME_NONNULL_BEGIN

// ─── VGFaceNeckBeautyMaskPolicy ──────────────────────────────────────────────

/// Stateful post-processing policy for MediaPipe Selfie Multiclass output.
///
/// Tuning parameters match the Phase 9B prototype (FaceNeckBeautyMaskPolicy.py).
/// All float parameters are in [0, 1] unless noted otherwise.
@interface VGFaceNeckBeautyMaskPolicy : NSObject

// ── Confidence thresholds ──────────────────────────────────────────────────

/// Minimum skin confidence to include a pixel. Default: 0.6.
@property (nonatomic) float skinThreshold;

/// Extra margin skin must exceed hair confidence by. Default: 0.10.
@property (nonatomic) float hairMargin;

/// Extra margin skin must exceed clothes/others confidence by. Default: 0.05.
@property (nonatomic) float clothMargin;

// ── Neck ROI ───────────────────────────────────────────────────────────────

/// Fraction of faceHeight projected downward as neck height. Default: 0.40.
@property (nonatomic) float neckDepth;

/// Fraction of faceWidth used as neck rectangle width. Default: 0.65.
@property (nonatomic) float neckWidth;

// ── Forehead ──────────────────────────────────────────────────────────────

/// Per-column trim from top face pixel, as fraction of faceHeight. Default: 0.10.
@property (nonatomic) float foreheadTrim;

/// Number of pixels to expand upward past the trim line (gated by hair). Default: 4.
@property (nonatomic) NSInteger foreheadExpand;

// ── Morphological cleanup ──────────────────────────────────────────────────

/// Square kernel side length for open/close morphological cleanup.
/// Must be odd and ≥ 1. Default: 3.
@property (nonatomic) NSInteger morphKernelSize;

// ── Temporal EMA ──────────────────────────────────────────────────────────

/// Base EMA blending alpha (0 = freeze, 1 = no smoothing). Default: 0.6.
/// Effective alpha is motion-adaptive:
///   alphaEff = temporalAlpha * max(0, 1 - motion / 0.08)
///   where motion = changed-pixel fraction between current and previous mask.
@property (nonatomic) float temporalAlpha;

// ── Processing ────────────────────────────────────────────────────────────

/// Convert a raw TFLite output tensor to a VGSkinMask.
///
/// @param outputTensor   Pointer to float buffer of size 256 * 256 * 6.
///                        Layout: NHWC, N=1, H=256, W=256, C=6.
///                        Class order: 0=background, 1=hair, 2=body-skin,
///                        3=face-skin, 4=clothes, 5=others/accessories.
///                        Caller retains ownership; pointer must be valid
///                        for the duration of this call.
/// @param sourceWidth    Full-resolution source frame width (used to scale
///                        the quarter-res output dimensions).
/// @param sourceHeight   Full-resolution source frame height.
/// @param pts            Presentation timestamp for the output mask.
/// @param generationReset YES to discard temporal history before processing.
///
/// @return A non-nil VGSkinMask. Returns an empty (all-zero) mask if no
///         face pixels are detected above threshold.
- (VGSkinMask *)processTensor:(const float *)outputTensor
                  sourceWidth:(size_t)sourceWidth
                 sourceHeight:(size_t)sourceHeight
                          pts:(CMTime)pts
              generationReset:(BOOL)generationReset;

/// Discard temporal EMA history. Equivalent to passing generationReset=YES
/// to the next processTensor call.
- (void)resetTemporalState;

/// Designated initializer — all parameters set to defaults.
- (instancetype)init NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
