// BeautyV2FilterGroup.h
// Phase 4B — Beauty V2: VGFilterGroupNode skeleton (Step 1: lifecycle only).
//
// BeautyV2FilterGroup is externally a single VGMetalFilterNode that the
// scheduler and image-path loop treat identically to any other filter node.
// Internally it owns a fixed 4-pass acyclic subgraph and three node-local
// CVPixelBufferPools for the intermediate buffers.
//
// Step 1 scope (this file):
//   - Lifecycle: init, prepareWithWidth:height:device:error:, invalidate
//   - Passthrough processEnvelope: (no GPU work — Metal kernels come in Step 2)
//   - Node-local pool ownership (CFRetain/CFRelease — NOT ARC)
//
// Architecture alignment:
//   DEC-57 — VGFilterGroupNode backend-neutral pass graph mandate
//   DEC-58 — synchronous waitUntilCompleted (no addCompletedHandler: in MVP)
//   RR-43  — lazy prepare: prepareWithWidth:height:device:error: is called
//             on first processEnvelope:device: until runtime call site exists
//   RR-44  — async GPU completion prohibited in Phase 4B MVP
//
// Conformance:
//   VGMetalFilterNode  (primary — used by scheduler and image processor)
//   VanguardFilterNode (legacy — required by setFilterChainFromSpecs: wiring)
//
// NOT yet wired into VanguardGraphRuntime or the filter chain.
// Beauty V1 (VanguardBeautyFilterNode) remains in production until Step 4
// (validation gate) is passed.

#pragma once
#import "VanguardFilterNode.h"        // legacy protocol (filter chain wiring)
#import <UMF/VGMetalFilterNode.h>     // primary protocol (scheduler)
#import <UMF/VGFrameEnvelope.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// BeautyV2FilterGroup
// ---------------------------------------------------------------------------
// External shape (scheduler sees one node):
//
//   VGFrameEnvelope in → BeautyV2FilterGroup → VGFrameEnvelope out
//
// Internal pass graph (Phase 9B+ OP-1: 3-pass, highpass fused into composite):
//
//   original (read-only)
//     ├──► [Pass 1: blur_h]  → intermediateA  (_beautyPoolA)
//     │         └──► [Pass 2: blur_v] → intermediateB  (_beautyPoolB)  = meanColor
//     └──► [Pass 3: composite(original, B, fused-highpass)] → outputBuffer  (runtime session pool)
//
// OP-1 change: _beautyPoolC and Pass 3 highpass kernel removed.
//   highPass is fused inline in composite: clamp(orig - mean + 0.5, 0, 1) - 0.5
//
// Pool ownership:
//   _beautyPoolA/B  — node-local; MUST use CFRetain/CFRelease explicitly.
//   _pool (init param) — borrowed from runtime; DO NOT CFRetain.
//
@interface BeautyV2FilterGroup : NSObject <VanguardFilterNode, VGMetalFilterNode>

// ─── VGMediaNode (required by VGMetalFilterNode → VGMediaNode chain) ─────────

/// Stable node identifier. Assigned at init time via NSUUID.
@property (nonatomic, readonly, copy) NSString *nodeId;
/// Node type tag for logging. Value: @"BeautyV2FilterGroup".
@property (nonatomic, readonly, copy) NSString *nodeType;

// ─── VGMetalFilterNode ────────────────────────────────────────────────────────

/// Human-readable name for logging. Value: @"BeautyV2".
@property (nonatomic, readonly, copy) NSString *filterName;

/// When NO, processEnvelope:device: returns input envelope unchanged (passthrough).
@property (nonatomic, assign) BOOL enabled;

// ─── VGFilterGroupNode (Phase 4.1 — documented, not yet a compiled protocol) ──

/// Group name for diagnostics.  Value: @"BeautyV2".
@property (nonatomic, readonly, copy) NSString *groupName;

/// Number of internal passes. Value: 4.
@property (nonatomic, readonly) NSInteger passCount;

/// Debug routing: when 0–3, processEnvelope returns the output of that pass
/// instead of the final composite. Default: -1 (normal composite output).
/// Only active in DEBUG builds. Has no effect in release.
@property (nonatomic, assign) NSInteger debugOutputPassIndex;

// ─── Beauty V2 tunable parameters ────────────────────────────────────────────
// These properties are applied every frame in processEnvelope:device:.
// CPU-side sanitization is applied before GPU dispatch — callers do not need
// to clamp values, but out-of-range values are silently clamped:
//   radius  → clamp(radius,  1, 12)   (prevents degenerate blur kernel)
//   sigma   → max(sigma,     1.0)     (prevents NaN in Gaussian weight)
//   theta   → max(theta,     0.001)   (prevents NaN in composite divide)

/// Master intensity control [0.0, 1.0].
///
/// When `useIntensityRamp` is YES (the default), this value drives all 5
/// internal parameters via a single linear ramp every frame.
/// Default: 0.75.
///
/// Setting `useIntensityRamp = NO` disables the ramp entirely; the 5
/// individual properties (radius/sigma/etc.) are used as-is.
@property (nonatomic, assign) float intensity;

/// Controls whether `intensity` drives the parameter ramp each frame.
///
/// - YES (default): intensity → {radius, sigma, smoothStrength, sharpenStrength,
///   theta} ramp runs every processEnvelope: call. Individual property values
///   are overwritten by the ramp.
/// - NO: ramp is skipped. The 5 individual properties are used exactly as set
///   (still subject to CPU sanitization / clamping).
///
/// The runtime sets this to YES when only `intensity` is supplied, and NO
/// when any granular param (radius/sigma/etc.) is explicitly provided.
@property (nonatomic, assign) BOOL useIntensityRamp;

/// Gaussian kernel half-radius in pixels. Clamped to [1, 12] before dispatch.
/// Default: 10 (medium-strong smoothing at 1080p).
@property (nonatomic, assign) int   radius;

/// Gaussian sigma (std-dev). Clamped to ≥ 1.0 before dispatch (ISSUE-1).
/// Default: 5.5.
@property (nonatomic, assign) float sigma;

/// Skin-smoothing blend factor [0.0, 1.0]. Higher = more blur mixed in.
/// Default: 0.90.
@property (nonatomic, assign) float smoothStrength;

/// High-frequency sharpening blend factor [0.0, 1.0].
/// Default: 0.25 (subtle detail restoration).
@property (nonatomic, assign) float sharpenStrength;

/// Luminance-weighting denominator in composite pass. Clamped to ≥ 0.001 (ISSUE-3).
/// Default: 0.06.
@property (nonatomic, assign) float theta;

/// Range (colour-similarity) sigma for Phase 4B.5 bilateral-like blur (DEC-59).
///
/// Controls how aggressively neighbours with different colour/luminance are
/// excluded from the blur mean. Lower values = tighter edge preservation.
///
/// - Default: `0.10f`
/// - Valid minimum: `0.01f` (clamped before dispatch — prevents NaN in exp).
/// - Ramp: when `useIntensityRamp = YES`, the intensity slider drives this from
///   `0.20` (low intensity, wide — behaves like spatial Gaussian) down to `0.08`
///   (high intensity, tight — protects edges during heavy smoothing).
/// - Advanced override: set `useIntensityRamp = NO` and assign directly.
///   Product UI always uses the intensity slider; this is for dev/QA only.
///
/// Phase 4B.5: Controls bilateral range weighting (edge preservation).
/// Fully wired to Metal blur kernels (DEC-59).
@property (nonatomic, assign) float rangeSigma;

// ─── Phase 4B.6 Perceptual Composite Parameters (DEC-60) ────────────────
// These properties control the perceptual enhancements added in Phase 4B.6.
// Values are computed by the intensity ramp (or set directly in DEV mode),
//   sanitized on CPU, and consumed by the GPU composite kernel every frame.
// CPU sanitization: detailDamping → [0, 1], toneStrength → [0, 1],
//   midtoneLift → [0, 0.15].

/// Detail damping factor [0.0, 1.0]. Controls how much high-frequency
/// texture is preserved in the composite add-back stage.
///   1.0 = full detail (identical to Phase 4B.5 behavior).
///   0.0 = all detail suppressed (maximum skin softening).
/// Default: 0.55. Ramp: [1.0, 0.5] (more damping at high intensity).
/// Phase 4B.6 (DEC-60) — wired to GPU composite kernel.
@property (nonatomic, assign) float detailDamping;

/// Tone compression strength [0.0, 1.0]. Applies a soft S-curve that
/// compresses midtone local contrast in the smoothed result.
///   0.0 = off (no compression — identical to Phase 4B.5).
///   1.0 = full compression.
/// Default: 0.25. Ramp: [0, 0.3] (more compression at high intensity).
/// Phase 4B.6 (DEC-60) — wired to GPU composite kernel.
@property (nonatomic, assign) float toneStrength;

/// Midtone luminance lift [0.0, 0.15]. Gently raises midtone brightness
/// using a parabolic curve 4×luma×(1-luma) for a subtle "glow" effect.
///   0.0 = off (no lift — identical to Phase 4B.5).
///   0.15 = maximum lift.
/// Default: 0.045. Ramp: [0, 0.06] (mild lift at high intensity).
/// Phase 4B.6 (DEC-60) — wired to GPU composite kernel.
@property (nonatomic, assign) float midtoneLift;

// ─── Phase 4C: Face-Aware Beauty Toggle (DEC-61 / DEC-63) ────────────────
// DEV-only. When NO (default), face detection + mask generation are disabled
// and the composite kernel produces exact Phase 4B.6 global beauty output.
// When YES, Vision face detection runs asynchronously, skin masks are
// generated, and the composite uses the mask to selectively apply beauty.
// This does NOT affect blur/highpass passes — only the composite blend.

/// Enables face-aware beauty mode.
///
/// - `NO` (default): face detection disabled, no mask, global beauty (Phase 4B.6).
/// - `YES`: Vision detection enabled, skin mask consumed by composite.
///
/// **DEV/test only.** Not for production use until Phase 4C is signed off.
@property (nonatomic, assign) BOOL faceAwareEnabled;

// ─── Phase 4C.1: Face-Weighted Boost Parameters (DEC-66 / DEC-67) ────────
// Per-pixel beauty parameter offsets applied inside the face mask region.
// Only active when faceAwareEnabled=YES AND hasMask>0. When faceAwareEnabled=NO
// or no face is detected, these are ignored and output is exact Phase 4B.6.
// When all boost values are zero, output is exact Phase 4C.
//
// Additive model (DEC-67): effectiveParam = baseParam + maskVal × boost.
// Exception: faceDampingReduce is subtractive (lower damping = softer skin).
//
// CPU sanitization: faceSmoothBoost → [0, 1], faceToneBoost → [0, 0.7],
//   faceLiftBoost → [0, 0.10], faceDampingReduce → [0, 0.5].

/// Additive smooth strength offset for face region [0.0, 1.0].
/// Raises the smoothing ceiling inside the mask.
/// Default: 0.40. Danger zone: > 0.8 (RR-60: plastic/wax face).
/// Phase 4C.1 (DEC-66) — wired to GPU composite kernel.
@property (nonatomic, assign) float faceSmoothBoost;

/// Additive tone compression offset for face region [0.0, 0.7].
/// Increases midtone contrast compression inside the mask.
/// Default: 0.12. Danger zone: > 0.5 (flat/grey complexion).
/// Phase 4C.1 (DEC-66) — wired to GPU composite kernel.
@property (nonatomic, assign) float faceToneBoost;

/// Additive midtone lift offset for face region [0.0, 0.10].
/// Concentrates luminance glow on face skin.
/// Default: 0.025. Danger zone: > 0.08 (white-hot highlights, RR-62).
/// Phase 4C.1 (DEC-66) — wired to GPU composite kernel.
@property (nonatomic, assign) float faceLiftBoost;

/// Subtractive detail damping reduction for face region [0.0, 0.5].
/// Lowers damping inside the mask (lower = softer skin texture).
/// Default: 0.15. Danger zone: > 0.4 (all texture lost).
/// Phase 4C.1 (DEC-67) — wired to GPU composite kernel.
@property (nonatomic, assign) float faceDampingReduce;

// ─── Phase 4C.2: Color Aesthetic Layer Parameters (DEC-70 / DEC-71) ──────
// Color-domain transforms applied inside the face mask region after beauty
// boost (4C.1). Only active when faceAwareEnabled=YES AND hasMask>0.
// When faceAwareEnabled=NO or no face detected, these are ignored.
// When all color values are zero, output is exact Phase 4C.1.
//
// All params are mask-modulated: effectiveColor = m × param × transform.
// CPU sanitization: all → [0, 1.0].

/// Face luminance brightening [0.0, 1.0].
/// Parabolic curve concentrates effect on midtones; highlights self-limit.
/// Default: 0.30. Danger zone: > 0.7 (RR-65: washed-out/chalky face).
/// Phase 4C.2 (DEC-71) — wired to GPU composite kernel.
@property (nonatomic, assign) float faceWhitenStrength;

/// Warm pink chroma shift [0.0, 1.0].
/// R+0.04/G-0.015 per unit; blue unchanged to avoid cool/grey artifacts.
/// Default: 0.25. Danger zone: > 0.6 (RR-67: sunburn/over-pink).
/// Phase 4C.2 (DEC-71) — wired to GPU composite kernel.
@property (nonatomic, assign) float faceRosyStrength;

/// Chroma variance compression toward neutral [0.0, 1.0].
/// Compresses redness, dark circles, uneven tan toward uniform skin tone.
/// Default: 0.35. Danger zone: > 0.8 (RR-69: grey/lifeless complexion).
/// Phase 4C.2 (DEC-71) — wired to GPU composite kernel.
@property (nonatomic, assign) float faceToneUnifyStrength;

/// Luminance glow shaping [0.0, 1.0].
/// Parabolic midtone boost applied after color transforms for radiance.
/// Default: 0.20. Danger zone: > 0.6 (over-bright/washed).
/// Phase 4C.2 (DEC-71) — wired to GPU composite kernel.
@property (nonatomic, assign) float faceGlowStrength;

// ─── Phase 4C.3: Feature Protection & Enhancement Parameters (DEC-76 / DEC-78) ──
// Feature-aware detail restoration and enhancement applied inside the face mask
// region after color transforms (4C.2). Only active when faceAwareEnabled=YES
// AND hasMask>0. When faceAwareEnabled=NO or no face detected, these are ignored.
// When all feature values are zero, output is exact Phase 4C.2.
//
// Feature detection uses varLuma smoothstep — no m-gating (DEC-79).
// CPU sanitization: all → [0, 1.0].

/// Master feature detection sensitivity [0.0, 1.0].
/// Controls smoothstep threshold and overall feature restoration strength.
/// Default: 0.40. Danger zone: > 0.8 (RR-75: patchy skin/feature boundary).
/// Phase 4C.3 (DEC-76) — wired to GPU composite kernel.
@property (nonatomic, assign) float featureRestoreStrength;

/// Original detail blend-back on features [0.0, 1.0].
/// Restores original texture on detected features (eyes, lips, brows).
/// Default: 0.35. Danger zone: > 0.7 (unfiltered features vs filtered skin).
/// Phase 4C.3 (DEC-78) — wired to GPU composite kernel.
@property (nonatomic, assign) float featureDetailRestore;

/// Highpass amplification on features [0.0, 1.0].
/// Boosts local contrast on detected features for sharper definition.
/// Default: 0.25. Danger zone: > 0.6 (RR-71: sharpening halos).
/// Phase 4C.3 (DEC-78) — wired to GPU composite kernel.
@property (nonatomic, assign) float featureContrastBoost;

/// Chroma preservation/boost on features [0.0, 1.0].
/// Maintains saturation on features (especially lips). Max boost: 50%.
/// Default: 0.20. Danger zone: > 0.6 (RR-73: lip over-saturation).
/// Phase 4C.3 (DEC-78) — wired to GPU composite kernel.
@property (nonatomic, assign) float featureSatBoost;

// ─── Phase 4D: Perceptual Feature Enhancement Parameters (DEC-82 / DEC-84) ──
// Targeted enhancement for eyes, lips, and brows using soft heuristic gates.
// Only active when faceAwareEnabled=YES AND hasMask>0.
// When all enhance values are zero, output is exact Phase 4C.3.
//
// Classification: luma + chroma + varLuma smoothstep gates (no ML, DEC-82).
// CPU sanitization: all → [0, 1.0].

/// Eye brightness + micro-contrast enhancement [0.0, 1.0].
/// Lifts luminance and amplifies highpass on bright, high-variance pixels.
/// Default: 0.0 (disabled — opt-in only, DEC-83).
/// Phase 4D (DEC-82) — wired to GPU composite kernel.
@property (nonatomic, assign) float eyeEnhanceStrength;

/// Lip chroma boost + edge clarity enhancement [0.0, 1.0].
/// Increases saturation and highpass on high-chroma, low-luma pixels.
/// Default: 0.0 (disabled — opt-in only, DEC-83).
/// Phase 4D (DEC-82) — wired to GPU composite kernel.
@property (nonatomic, assign) float lipEnhanceStrength;

/// Brow micro-contrast enhancement [0.0, 1.0].
/// Amplifies highpass on low-chroma, medium-luma, high-variance pixels.
/// Default: 0.0 (disabled — opt-in only, DEC-83).
/// Phase 4D (DEC-82) — wired to GPU composite kernel.
@property (nonatomic, assign) float browEnhanceStrength;

// ─── Phase 4E: Tone Polish Layer Parameters (DEC-90 / DEC-92) ────────────────
// Final perceptual polish: midtone glow, micro-smoothing, warmth, pseudo-bloom.
// Only active when faceAwareEnabled=YES AND hasMask>0.
// When all polish values are zero, output is exact Phase 4D.
//
// All ALU-only — no new pass, texture, sampler, or buffer (DEC-90).
// CPU sanitization: all → [0, 1.0].

/// Midtone glow curve intensity [0.0, 1.0].
/// Lifts midtones via parabolic curve with highlight protection.
/// Default: 0.0 (disabled — opt-in only, DEC-91).
/// Phase 4E (DEC-90) — wired to GPU composite kernel.
@property (nonatomic, assign) float polishGlowStrength;

/// Highpass attenuation for micro-smoothing [0.0, 1.0].
/// Subtracts residual highpass for silkier skin texture (feature-safe, DEC-95).
/// Default: 0.0 (disabled — opt-in only, DEC-91).
/// Phase 4E (DEC-90) — wired to GPU composite kernel.
@property (nonatomic, assign) float polishSmoothStrength;

/// Warm compensation vs cool whitening [0.0, 1.0].
/// Adds subtle R+G warm shift to midtones (ratio 1.0:0.6:0.0, DEC-94).
/// Default: 0.0 (disabled — opt-in only, DEC-91).
/// Phase 4E (DEC-90) — wired to GPU composite kernel.
@property (nonatomic, assign) float polishWarmthStrength;

/// Pseudo-bloom luminance lift [0.0, 1.0].
/// Brightens bright pixels with highlight protection (DEC-96).
/// Default: 0.0 (disabled — opt-in only, DEC-91).
/// Phase 4E (DEC-90) — wired to GPU composite kernel.
@property (nonatomic, assign) float polishBloomStrength;

// ─── Initializer ─────────────────────────────────────────────────────────────

/// Designated initializer.
/// @param pool   Runtime session pool — output buffers drawn from here (borrowed,
///               DO NOT CFRetain). Must remain valid for the lifetime of this node.
/// @param device Shared MTLDevice.
- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// ─── Prepare lifecycle ────────────────────────────────────────────────────────

/// Creates (or recreates) the three node-local intermediate CVPixelBufferPools.
///
/// Called by the runtime at filter-chain installation time (future call site).
/// For Phase 4B MVP: also called lazily on the first processEnvelope:device:
/// invocation, and whenever frame dimensions change (RR-43).
///
/// Idempotent: if width/height/device match the last successful prepare, returns
/// YES immediately without reallocating.
///
/// Thread-safety: serialised internally; safe to call from any background queue.
///
/// @return YES on success, NO on pool creation failure (sets *error).
- (BOOL)prepareWithWidth:(size_t)width
                  height:(size_t)height
                  device:(id<MTLDevice>)device
                   error:(NSError *__autoreleasing _Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
