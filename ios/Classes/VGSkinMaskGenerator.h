// VGSkinMaskGenerator.h
// Phase 4C — Step 2: CPU skin mask generation from face landmarks (DEC-62/64).
// Phase A  — Step 2 spatial cleanup (DEC-113/114/115).
// Phase C  — Step 4 semantic accuracy (DEC-119): YCbCr skin verification.
//
// Phase A additions (Step 2 only — no algorithm changes outside mask pipeline):
//   A.1 Edge-aware mask feathering  — luma-guided bilateral feather replaces
//       uniform Gaussian. Preserves hard face/background edges while still
//       feathering skin-to-skin transitions (DEC-113).
//   A.2 Soft feature exclusion      — smooth smoothstep falloff replaces hard
//       zero cutouts for eyes/lips/brows (DEC-114).
//   A.3 Neck extension              — conservative soft ellipse below the face
//       bounding box; fades naturally; conservative default (DEC-115).
//
// Produces a quarter-resolution R8 (uint8) soft mask from face detection
// results. The mask is rasterized on CPU — no GPU compute pass needed.
//
// Mask values:
//   255 = full skin (beauty effect applies at full strength)
//   0   = non-skin (beauty effect disabled — original pixel preserved)
//   1–254 = feathered transition zone
//
// Threading contract:
//   - submitResult:sourceWidth:sourceHeight: is the primary entry point.
//     It dispatches mask generation to a private serial queue and returns
//     immediately — it NEVER blocks the caller (render thread safe).
//   - If generation is already in-flight, the request is coalesced (skipped).
//   - latestMask is atomic — safe to read from the render thread.
//   - All vImage / rasterization work runs on the private mask queue.
//
// Architecture alignment:
//   DEC-62 — quarter-res R8Unorm soft mask
//   DEC-63 — final-blend mask (Step 3 will consume this mask)
//   DEC-64 — CPU-side mask rasterization (no GPU mask pass)
//   DEC-65 — 4-pass pipeline preserved (no new pass)
//   RR-55  — mask edge leakage (mitigated by Gaussian feathering)
//   RR-57  — temporal mask flicker (mitigated by reuse of cached mask)
//   RR-59  — R8 precision banding (mitigated by bilinear sampling in Step 3)

#pragma once
#import <Foundation/Foundation.h>
#import <CoreMedia/CMTime.h>

@class VGFaceDetectionResult;

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// VGSkinMask — immutable snapshot of a generated mask
// ---------------------------------------------------------------------------

@interface VGSkinMask : NSObject

/// Mask pixel data (R8 uint8). Length = width × height.
/// The data is owned by this object — safe to read after the generator
/// has moved on to the next frame.
@property (nonatomic, readonly) const uint8_t *data;

/// Mask dimensions (quarter of source frame).
@property (nonatomic, readonly) size_t width;
@property (nonatomic, readonly) size_t height;

/// Bytes per row (== width for R8 format, no padding).
@property (nonatomic, readonly) size_t bytesPerRow;

/// Presentation timestamp of the source frame that produced this mask.
@property (nonatomic, readonly) CMTime sourcePTS;

/// Number of faces that contributed to this mask.
@property (nonatomic, readonly) NSInteger faceCount;

- (instancetype)init NS_UNAVAILABLE;

@end

// ---------------------------------------------------------------------------
// VGSkinMaskGenerator — CPU mask rasterizer
// ---------------------------------------------------------------------------

@interface VGSkinMaskGenerator : NSObject

/// Latest generated mask. Atomic — safe to read from any thread.
/// nil until the first generation completes.
@property (atomic, readonly, nullable) VGSkinMask *latestMask;

/// Feather sigma in quarter-res pixels. Default: 8.
/// Controls the softness of mask edges. Higher = softer.
@property (nonatomic, assign) float featherSigma;

/// Face oval inset factor [0, 1]. Default: 0.05 (5% inset).
/// Shrinks the face oval slightly to avoid mask leakage at edges.
@property (nonatomic, assign) float faceOvalInset;

/// Feature exclusion padding factor [0, 1]. Default: 0.15 (15% expansion).
/// Expands exclusion zones around eyes/lips/brows.
@property (nonatomic, assign) float featureExclusionPadding;

/// EMA smoothing alpha [0, 1]. Default: 0.3.
/// Phase B.1 (DEC-117): this value is superseded by the motion-adaptive alpha
/// computed in _generateMaskForResult:. It is retained for reference and may
/// be read by diagnostic code, but is NOT applied directly to the EMA blend.
/// The adaptive range is alphaMin=0.15 (still face) to alphaMax=0.70 (fast motion).
@property (nonatomic, assign) float smoothingAlpha;

// ─── Phase A (Step 2) configuration ─────────────────────────────────────────

/// Master gate for all Phase A spatial improvements.
/// When NO, behaviour is identical to Step 1 (Gaussian only, hard exclusion).
/// Default: YES. Set to NO to revert to Step 1 behaviour during QA.
@property (nonatomic, assign) BOOL phaseAEnabled;

/// Neck extension ellipse strength [0, 1]. Default: 0.20 (conservative first pass).
/// Controls the height of the neck extension as a fraction of faceHeight.
/// 0 = no extension. Values > 0.4 risk touching clothing.
@property (nonatomic, assign) float neckExtensionStrength;

/// Range sigma for edge-aware feathering [0.01, 1.0]. Default: 0.12.
/// Controls how aggressively luma edges suppress feathering.
/// Lower = sharper edge preservation. Higher = softer / more Gaussian-like.
@property (nonatomic, assign) float featherRangeSigma;

/// Feature exclusion inner radius as fraction of feature extent [0, 1]. Default: 0.6.
/// At distanceFromFeature < innerRadius, exclusion is 0 (full exclusion).
/// At distanceFromFeature > 1.0, exclusion is 1 (full skin).
@property (nonatomic, assign) float featureExclusionInnerRadius;

// ─── Phase C (Step 4) configuration ─────────────────────────────────────────────────

/// Phase C.1 skin colour verification gate (DEC-119).
///
/// When YES: non-skin pixels inside the face mask receive a monotonic
/// partial reduction (value × 0.3). Uses YCbCr range checking on a
/// quarter-res CbCr snapshot passed via submitResult:chromaBuffer:.
///
/// When NO: exact Step 3 behaviour — no pixel-space modification.
/// Default: YES.
@property (nonatomic, assign) BOOL skinVerificationEnabled;

/// Submit a face detection result for async mask generation.
///
/// This method dispatches mask rasterization to a private serial queue
/// and returns immediately — it NEVER blocks the render thread.
/// If a previous generation is still in-flight, the request is coalesced
/// (skipped). The latest mask is published atomically when complete.
///
/// @param result       Face detection result (faces + landmarks). Retained
///                     for the duration of async generation.
/// @param sourceWidth  Full-resolution source frame width.
/// @param sourceHeight Full-resolution source frame height.
- (void)submitResult:(VGFaceDetectionResult *)result
         sourceWidth:(size_t)sourceWidth
        sourceHeight:(size_t)sourceHeight;

/// Extended entry point that provides a quarter-res luma guidance buffer for
/// Phase A edge-aware feathering (DEC-113).
///
/// lumaBuffer is a read-only R8 buffer of dimensions lumaWidth × lumaHeight,
/// typically sourceWidth/4 × sourceHeight/4. The buffer is accessed
/// synchronously (copied before the method returns) so the caller does not
/// need to keep it alive after the call.
///
/// When phaseAEnabled=NO, this falls through to the standard Gaussian path
/// and the luma buffer is ignored.
///
/// @param lumaBuffer   Quarter-res Y-plane (R8, one byte per pixel). May be
///                     NULL — if so, falls back to plain Gaussian feathering.
/// @param lumaWidth    Width of lumaBuffer in pixels.
/// @param lumaHeight   Height of lumaBuffer in pixels.
- (void)submitResult:(VGFaceDetectionResult *)result
         lumaBuffer:(const uint8_t * _Nullable)lumaBuffer
          lumaWidth:(size_t)lumaWidth
         lumaHeight:(size_t)lumaHeight
        sourceWidth:(size_t)sourceWidth
       sourceHeight:(size_t)sourceHeight;

/// Phase C.1 skin verification entry point (DEC-119).
///
/// Provides a quarter-res interleaved CbCr buffer for per-pixel skin tone
/// range checking. Non-skin pixels inside the face mask receive a partial
/// reduction (× 0.3), not a hard cutoff — monotonic by design.
///
/// The chroma buffer is captured synchronously (copied before return) from
/// the current frame's CVPixelBuffer. A 1-frame lag between chroma and
/// detection geometry is safe — skin colour is stable between frames.
///
/// When skinVerificationEnabled=NO, this falls through to the standard path
/// and the chroma buffer is ignored.
///
/// @param chromaBuffer  Quarter-res interleaved CbCr, 2 bytes per pixel
///                      (Cb at even index, Cr at odd index).
///                      Length = chromaWidth × chromaHeight × 2.
///                      May be NULL — if so, verification is skipped.
/// @param chromaWidth   Width of the chroma buffer (== sourceWidth / 4).
/// @param chromaHeight  Height of the chroma buffer (== sourceHeight / 4).
- (void)submitResult:(VGFaceDetectionResult *)result
       chromaBuffer:(const uint8_t * _Nullable)chromaBuffer
        chromaWidth:(size_t)chromaWidth
       chromaHeight:(size_t)chromaHeight
        sourceWidth:(size_t)sourceWidth
       sourceHeight:(size_t)sourceHeight;

/// Release internal buffers. Safe to call multiple times.
- (void)invalidate;

/// Phase B.1 (DEC-117) — Reset EMA smoothing history and motion tracking.
///
/// Call when envelope.generation changes (seek / session restart) to prevent
/// the first post-seek mask from blending with stale pre-seek state.
/// Dispatched async to the internal mask queue — no caller synchronisation needed.
- (void)resetTemporalState;

- (instancetype)init NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
