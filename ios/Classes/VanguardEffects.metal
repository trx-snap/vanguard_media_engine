// VanguardEffects.metal
// Vanguard Media Engine — Phase 4 GPU Effects Kernels
//
// Three compute kernels, each contracted by P4-ME-1/2/3 tests:
//   vanguard_lut_apply              — texture(0)in, texture(1)out, texture(2)lut3D
//   vanguard_bilateral_filter       — texture(0)in, texture(1)out, buffer(0)BilateralParams
//   vanguard_segmentation_composite — texture(0)fg, texture(1)bg, texture(2)mask, texture(3)out
//
// All kernels:
//   • Early-exit on out-of-bounds gid.
//   • half precision for throughput on A-series GPU.
//   • No global memory write hazards (inputs are read-only, output is write-only).

#include <metal_stdlib>
using namespace metal;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: LUT Apply
// Trilinear-samples a 3D LUT texture using the input pixel's RGB as UVW coordinates.
// Identity LUT: output equals input (P4-ME-4 verified to ≤10/255 precision on 4³ LUT).
// Production: use 32³ or 64³ CLUT for broadcast-quality color grading.
// ─────────────────────────────────────────────────────────────────────────────

kernel void vanguard_lut_apply(
    texture2d<half, access::read>    inTex  [[texture(0)]],
    texture2d<half, access::write>   outTex [[texture(1)]],
    texture3d<half, access::sample>  lut    [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    constexpr sampler s(coord::normalized,
                        filter::linear,
                        address::clamp_to_edge);

    half4 pixel  = inTex.read(gid);
    // Metal auto-swizzles MTLPixelFormatBGRA8Unorm: .r=Red, .g=Green, .b=Blue.
    // Sample the LUT using logical (R,G,B) — no manual channel swap needed.
    half4 mapped = lut.sample(s, float3(pixel.r, pixel.g, pixel.b));
    outTex.write(half4(mapped.rgb, pixel.a), gid);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Beauty Filter (GPUPixel-inspired adaptive skin-smooth, single pass)
//
// Algorithm:
//   1. Sample centre + 8 neighbours at ±8px stride (covers coarse smoothing
//      range without a loop; works on any resolution).
//   2. Compute weighted mean (Gaussian-style weights, sum = 1.0).
//   3. Extract high-pass detail: detail = centre − mean.
//   4. Estimate local variance from abs(detail).
//   5. Derive adaptive strength k: high in flat regions, low at edges.
//   6. Smooth: smoothed = mix(centre, mean, k).
//   7. Add detail back: final = smoothed + sharpen × detail × 2.0.
//
// BilateralParams struct is kept for ABI compatibility with the ObjC caller;
// sigmaColor / sigmaSpace / radius are unused by this kernel.
// Tuning constants are inlined: theta=0.03, baseStrength=1.5, sharpen=0.4.
// ─────────────────────────────────────────────────────────────────────────────

struct BilateralParams {
    float sigmaSpace;   ///< Kept for ABI compatibility — unused by this kernel
    float sigmaColor;   ///< Kept for ABI compatibility — unused by this kernel
    int   radius;       ///< Kept for ABI compatibility — unused by this kernel
};

kernel void vanguard_bilateral_filter(
    texture2d<half, access::read>  inTex  [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    constant BilateralParams&      params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    // ── 1. Texel stride — 8-pixel steps for wider coverage on high-res images ────
    const int texelSpacingMultiplier = 8;

    // Pixel boundary limits for clamping
    int W = int(inTex.get_width())  - 1;
    int H = int(inTex.get_height()) - 1;

    // Pixel-space stride (8 pixels in each direction)
    int sx = int(texelSpacingMultiplier);
    int sy = int(texelSpacingMultiplier);
    int px = int(gid.x);
    int py = int(gid.y);

    // ── 2. Sample 9 points: centre + 4 cardinal + 4 diagonal ──────────────────
    half3 c  = inTex.read(gid).rgb;
    half4 centre4 = inTex.read(gid);

    half3 l  = inTex.read(uint2(clamp(px - sx, 0, W), py             )).rgb;
    half3 r  = inTex.read(uint2(clamp(px + sx, 0, W), py             )).rgb;
    half3 u  = inTex.read(uint2(px,              clamp(py - sy, 0, H))).rgb;
    half3 d  = inTex.read(uint2(px,              clamp(py + sy, 0, H))).rgb;
    half3 ul = inTex.read(uint2(clamp(px - sx, 0, W), clamp(py - sy, 0, H))).rgb;
    half3 ur = inTex.read(uint2(clamp(px + sx, 0, W), clamp(py - sy, 0, H))).rgb;
    half3 dl = inTex.read(uint2(clamp(px - sx, 0, W), clamp(py + sy, 0, H))).rgb;
    half3 dr = inTex.read(uint2(clamp(px + sx, 0, W), clamp(py + sy, 0, H))).rgb;

    // ── 3. Weighted mean ────────────────────────────────────────────────────────
    // Centre: 0.25 | Cardinals: 0.125 each | Diagonals: 0.0625 each
    // Sum of weights = 0.25 + 4×0.125 + 4×0.0625 = 0.25 + 0.5 + 0.25 = 1.0
    half3 meanColor = c    * half(0.25f)
                    + l    * half(0.125f)
                    + r    * half(0.125f)
                    + u    * half(0.125f)
                    + d    * half(0.125f)
                    + ul   * half(0.0625f)
                    + ur   * half(0.0625f)
                    + dl   * half(0.0625f)
                    + dr   * half(0.0625f);

    // ── 4. High-pass detail ─────────────────────────────────────────────────────
    half3 highPass = c - meanColor;

    // ── 5. Local variance estimate ──────────────────────────────────────────────
    float meanVar = (abs(float(highPass.r)) +
                     abs(float(highPass.g)) +
                     abs(float(highPass.b))) / 3.0f;

    // ── 6. Adaptive smoothing strength ─────────────────────────────────────────
    // theta=0.03: pixels with variance > ~3% of full range are treated as edges.
    // baseStrength=1.5: allows k to reach 1.0 well within the flat-region range
    // (k is clamped to [0,1], so the excess only widens the smoothing band).
    const float theta = 0.03f;
    const float baseStrength = 1.5f;
    float k = (1.0f - meanVar / (meanVar + theta)) * baseStrength;
    k = clamp(k, 0.0f, 1.0f);

    // ── 7. Smooth ───────────────────────────────────────────────────────────────
    half3 smoothed = mix(c, meanColor, half(k));

    // ── 8. Add detail back (micro-texture / sharpness preservation) ─────────────
    const half sharpen = half(0.4f);
    half3 finalRGB = clamp(smoothed + sharpen * highPass * half(2.0f),
                           half(0.0f), half(1.0f));

    outTex.write(half4(finalRGB, centre4.a), gid);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Segmentation Composite
// Alpha-blends foreground over background using a single-channel mask.
// mask.r = 1.0 → full foreground (person visible).
// mask.r = 0.0 → full background (person removed / background effect visible).
// Uses metal mix() which is: mix(bg, fg, mask) = bg*(1-mask) + fg*mask.
// P4-ME-5 GPU test validates white-mask preserves foreground to ≤3/255.
// ─────────────────────────────────────────────────────────────────────────────

kernel void vanguard_segmentation_composite(
    texture2d<half, access::read>  fgTex   [[texture(0)]],
    texture2d<half, access::read>  bgTex   [[texture(1)]],
    texture2d<half, access::read>  maskTex [[texture(2)]],   // r8Unorm single channel
    texture2d<half, access::write> outTex  [[texture(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    half4 fg   = fgTex.read(gid);
    half4 bg   = bgTex.read(gid);
    // Clamp mask read coordinate to mask texture dimensions.
    // This makes a 1×1 default-white mask read 1.0 for every pixel in the
    // frame instead of 0.0 for all pixels where gid > (0,0).
    uint2 maskCoord = min(gid, uint2(maskTex.get_width()  - 1,
                                     maskTex.get_height() - 1));
    half  mask = maskTex.read(maskCoord).r;  // r8Unorm → [0,1] normalised

    outTex.write(mix(bg, fg, mask), gid);
}

// =============================================================================
// MARK: Beauty V2 — 3-Pass GPUPixel-Style Kernels (Phase 4B / Phase 9B+ OP-1)
//
// Pass graph (OP-1: highpass fused into composite — eliminates intermediateC):
//   Pass 1  vanguard_beauty_blur_h    — horizontal 1D Gaussian → intermediateA
//   Pass 2  vanguard_beauty_blur_v    — vertical   1D Gaussian → intermediateB (meanColor)
//   Pass 3  vanguard_beauty_composite — fused highpass + adaptive smooth + detail restore → outputBuffer
//
// OP-1 change (Phase 9B+): vanguard_beauty_highpass kernel removed.
//   highPass is now computed inline in composite:
//   highPass = clamp(orig - mean + 0.5, 0, 1) - 0.5  (Option A — preserves old clamped range)
//   This eliminates the _beautyPoolC intermediate texture and one full-frame dispatch.
//
// Design rules (DEC-56 / RR-40):
//   - Separated Gaussian blur (not box blur). DEC-56: deliberate adaptation from GPUPixel.
//   - All reads use read(uint2) — no sampler objects.
//   - Clamp-to-edge via integer clamp() — no platform sampler dependency (RR-40).
//   - No addCompletedHandler: references (RR-44 / DEC-58 — CPU-side concern).
//   - Each kernel = one pass; no inter-pass Metal synchronisation.
//   - half precision throughout for A-series throughput.
//   - radius capped at 16 to bound loop trip-count (max 33 taps per axis).
// =============================================================================

// ---------------------------------------------------------------------------
// Uniform struct shared by blur passes 1 and 2.
// Must match BeautyBlurParams in BeautyV2FilterGroup.m (CPU ABI — exact layout).
// Layout: int(4) + float(4) + float(4) = 12 bytes, no padding.
// Phase 4B.5 (DEC-59): rangeSigma added for bilateral range weighting.
// ---------------------------------------------------------------------------
struct BeautyBlurParams {
    int   radius;      // Half-width of the 1D Gaussian kernel. Range [1, 16].
    float sigma;       // Spatial std-dev. Range [1.0, 20.0].
    float rangeSigma;  // Colour-similarity std-dev. Range [0.01, 1.0]. (Phase 4B.5)
};

// ---------------------------------------------------------------------------
// MARK: Pass 1 — vanguard_beauty_blur_h  (Phase 4B.5: bilateral range weighting)
//
// Horizontal 1D range-aware blur of the original frame (DEC-59).
// texture(0) in:  original frame  BGRA8Unorm read
// texture(1) out: intermediateA   BGRA8Unorm write
// buffer(0):      BeautyBlurParams {radius, sigma, rangeSigma}
//
// Boundary: X clamped to [0, width-1].  Y is the pixel row — unchanged.
// Weight:   w[i] = spatial(i) × range(i)
//   spatial(i) = exp(-i² / 2σ_s²)               [unchanged from Phase 4B]
//   range(i)   = exp(-‖tap.rgb - centre.rgb‖² / 2σ_r²)  [Phase 4B.5 addition]
// Centre pixel read once before loop — no extra texture fetch per tap.
// Range weight uses full RGB distance (3-channel) for colour accuracy.
// ---------------------------------------------------------------------------
kernel void vanguard_beauty_blur_h(
    texture2d<half, access::read>  inTex  [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    constant BeautyBlurParams&     params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    const int   W           = int(inTex.get_width()) - 1;
    const int   px          = int(gid.x);
    const int   radius      = clamp(params.radius, 1, 16);
    const float twoSig2     = 2.0f * params.sigma      * params.sigma;      // spatial
    const float twoRangeSig2 = 2.0f * params.rangeSigma * params.rangeSigma; // range (RR-46)

    // Read centre pixel once — used as reference for range weighting.
    float3 centre = float3(inTex.read(gid).rgb);

    float3 acc  = float3(0.0f);
    float  wSum = 0.0f;

    for (int i = -radius; i <= radius; ++i) {
        int    sx     = clamp(px + i, 0, W);
        float3 tap    = float3(inTex.read(uint2(uint(sx), gid.y)).rgb);

        float  spatial = exp(-float(i * i) / twoSig2);
        float3 delta   = tap - centre;
        float  range   = exp(-dot(delta, delta) / twoRangeSig2);
        float  w       = spatial * range;

        acc  += tap * w;
        wSum += w;
    }

    // Guard against degenerate zero-sum (all-edge pixel surrounded by identical
    // weight=0 taps). Extremely rare; fall back to centre pixel when wSum ≈ 0.
    float3 result = (wSum > 1e-6f) ? (acc / wSum) : centre;

    half alpha = inTex.read(gid).a;
    outTex.write(half4(half3(result), alpha), gid);
}

// ---------------------------------------------------------------------------
// MARK: Pass 2 — vanguard_beauty_blur_v  (Phase 4B.5: bilateral range weighting)
//
// Vertical 1D range-aware blur of intermediateA → meanColor (DEC-59).
// texture(0) in:  intermediateA (blur_h output)  BGRA8Unorm read
// texture(1) out: intermediateB (meanColor)       BGRA8Unorm write
// buffer(0):      BeautyBlurParams — same {radius, sigma, rangeSigma} as Pass 1
//
// Boundary: Y clamped to [0, height-1].  X unchanged.
// Weight:   w[i] = spatial(i) × range(i)  — see blur_h for algorithm notes.
// Note: pass 2 reads from intermediateA (blur_h output), not the original frame.
// The centre reference is therefore the horizontally-smoothed value at this pixel,
// which slightly widens the effective range tolerance — this is acceptable and
// consistent with standard cross-bilateral filter implementations.
// ---------------------------------------------------------------------------
kernel void vanguard_beauty_blur_v(
    texture2d<half, access::read>  inTex  [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    constant BeautyBlurParams&     params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    const int   H            = int(inTex.get_height()) - 1;
    const int   py           = int(gid.y);
    const int   radius       = clamp(params.radius, 1, 16);
    const float twoSig2      = 2.0f * params.sigma      * params.sigma;
    const float twoRangeSig2 = 2.0f * params.rangeSigma * params.rangeSigma;

    // Read centre pixel (horizontally-smoothed intermediateA value).
    float3 centre = float3(inTex.read(gid).rgb);

    float3 acc  = float3(0.0f);
    float  wSum = 0.0f;

    for (int i = -radius; i <= radius; ++i) {
        int    sy     = clamp(py + i, 0, H);
        float3 tap    = float3(inTex.read(uint2(gid.x, uint(sy))).rgb);

        float  spatial = exp(-float(i * i) / twoSig2);
        float3 delta   = tap - centre;
        float  range   = exp(-dot(delta, delta) / twoRangeSig2);
        float  w       = spatial * range;

        acc  += tap * w;
        wSum += w;
    }

    float3 result = (wSum > 1e-6f) ? (acc / wSum) : centre;

    half alpha = inTex.read(gid).a;
    outTex.write(half4(half3(result), alpha), gid);
}

// ---------------------------------------------------------------------------
// MARK: Pass 3 — vanguard_beauty_composite  (Phase 9B+ OP-1: was Pass 4)
//
// Adaptive skin-smoothing composite. Blends original toward meanColor in flat
// regions, preserves edges via theta variance-gate, then applies Phase 4B.6
// perceptual enhancements (detail damping, tone compression, midtone lift)
// before adding detail back.
//
// Phase 4C (DEC-63): When a skin mask is provided, the final beauty result is
// blended with the original pixel based on mask coverage. Non-skin areas
// receive the original pixel unchanged. When hasMask=0, output is identical
// to Phase 4B.6 (zero regression).
//
// Phase 9B+ OP-1: highpass is now computed inline (no intermediateC texture).
//   Option A math: clamp(orig - mean + 0.5, 0, 1) - 0.5  → range [-0.5, +0.5]
//   × 2.0 multiplier on detail add-back is preserved (range unchanged).
//
// texture(0) in:  original frame                  BGRA8Unorm read
// texture(1) in:  intermediateB (meanColor)        BGRA8Unorm read
// texture(2) out: outputBuffer (final composite)   BGRA8Unorm write  [was texture(3)]
// texture(3) in:  skinMask (R8Unorm, quarter-res) — optional (Phase 4C, DEC-62) [was texture(4)]
// buffer(0):      BeautyCompositeParams {smoothStrength, sharpenStrength, theta,
//                                        detailDamping, toneStrength, midtoneLift,
//                                        hasMask, maskStrength}
//
// Algorithm (Phase 4B.6 — DEC-60 + Phase 4C mask — DEC-63):
//   highPass  = clamp(orig - mean + 0.5, 0, 1) - 0.5    (Option A inline, range [-0.5, +0.5])
//   varLuma   = mean(|highPass.rgb|)              (per-pixel variance proxy)
//   k         = (1 - varLuma/(varLuma+theta)) * smoothStrength
//   smoothed  = mix(original, meanColor, clamp(k,0,1))
//   dampedDetail = highPass * detailDamping       (Phase 4B.6: texture attenuation)
//   toned     = smoothed * toneScale              (Phase 4B.6: contrast compression)
//   lifted    = toned + midtone lift              (Phase 4B.6: luminance boost)
//   beautyRGB = clamp(lifted + sharpenStrength * dampedDetail * 2, 0, 1)
//   if hasMask > 0:
//     mask = sample(skinMask, normalized_coords) * maskStrength
//     finalRGB = mix(original.rgb, beautyRGB, clamp(mask, 0, 1))
//   else:
//     finalRGB = beautyRGB
// ---------------------------------------------------------------------------
struct BeautyCompositeParams {
    float smoothStrength;   // [0,2]    smooth blend factor
    float sharpenStrength;  // [0,0.5]  detail add-back amount
    float theta;            // variance gate (≥ 0.001)
    float detailDamping;    // [0,1]    Phase 4B.6: texture attenuation (1.0 = full detail)
    float toneStrength;     // [0,1]    Phase 4B.6: tone compression intensity
    float midtoneLift;      // [0,0.15] Phase 4B.6: midtone luminance boost
    float hasMask;          // Phase 4C: 0 = no mask (exact 4B.6), >0 = mask active
    float maskStrength;     // Phase 4C: [0,1] mask influence (1.0 = full mask)
    // ── Phase 4C.1: face-weighted boost offsets (DEC-66/67) ──
    float faceSmoothBoost;  // [0,1]   additive smooth offset for face region
    float faceToneBoost;    // [0,0.7] additive tone offset for face region
    float faceLiftBoost;    // [0,0.1] additive lift offset for face region
    float faceDampingReduce;// [0,0.5] subtractive damping for face region
    // ── Phase 4C.2: color aesthetic layer (DEC-70/71) ──
    float faceWhitenStrength;    // [0,1] luminance brightening
    float faceRosyStrength;      // [0,1] warm pink chroma shift
    float faceToneUnifyStrength;  // [0,1] chroma variance compression
    float faceGlowStrength;      // [0,1] luminance glow shaping
    // ── Phase 4C.3: feature protection & enhancement (DEC-76/78) ──
    float featureRestoreStrength;  // [0,1] master feature detection sensitivity
    float featureDetailRestore;    // [0,1] original detail blend-back on features
    float featureContrastBoost;    // [0,1] highpass amplification on features
    float featureSatBoost;         // [0,1] chroma preservation on features
    // ── Phase 4D: perceptual feature enhancement (DEC-82/84) ──
    float eyeEnhanceStrength;      // [0,1] eye brightness + micro-contrast
    float lipEnhanceStrength;      // [0,1] lip chroma + edge clarity
    float browEnhanceStrength;     // [0,1] brow micro-contrast
    // ── Phase 4E: tone polish layer (DEC-90/92) ──
    float polishGlowStrength;      // [0,1] midtone glow curve intensity
    float polishSmoothStrength;    // [0,1] highpass attenuation for micro-smoothing
    float polishWarmthStrength;    // [0,1] warm compensation vs cool whitening
    float polishBloomStrength;     // [0,1] pseudo-bloom luminance lift
    float _pad1;                   // padding for 16-byte alignment
};
// Layout: 28 × float = 112 bytes. Must match CPU struct EXACTLY.

// ── Phase 4C.2: inline color aesthetic transform (DEC-70/71/73) ─────────────
// Applied after Step 8 (detail add-back), before mask blend.
// When all color params are 0: returns input unchanged (exact 4C.1).
// Order: whiten → rosy → unify → glow (DEC-73).
inline half3 _applyColorLayer(half3 rgb, float m,
                              constant BeautyCompositeParams& p) {
    float3 c = float3(rgb);
    float luma = dot(c, float3(0.299f, 0.587f, 0.114f));

    // C1: Whitening — parabolic luminance shift, peaks at mid-luma.
    //     Highlights/shadows barely affected; prevents clipping.
    float whitenAmount = m * p.faceWhitenStrength;
    float whitenCurve  = 4.0f * luma * (1.0f - luma);  // parabolic, peaks at 0.5
    c += whitenAmount * whitenCurve * 0.15f;

    // C2: Rosy warmth — R+/G- chroma shift for warm pink undertone.
    //     Blue unchanged to avoid cool/grey artifacts.
    float rosyAmount = m * p.faceRosyStrength;
    c.r += rosyAmount * 0.04f;
    c.g -= rosyAmount * 0.015f;

    // C3: Tone unification — compress chroma toward achromatic reference.
    //     Max 50% compression at full strength (0.5 multiplier).
    float unifyAmount = m * p.faceToneUnifyStrength;
    float3 neutral    = float3(dot(c, float3(0.299f, 0.587f, 0.114f)));  // recompute luma after C1/C2
    float3 chromaDiff = c - neutral;
    c = neutral + chromaDiff * (1.0f - unifyAmount * 0.5f);

    // C4: Glow shaping — parabolic luminance boost on final color.
    float newLuma   = dot(c, float3(0.299f, 0.587f, 0.114f));
    float glowCurve = 4.0f * newLuma * (1.0f - newLuma);
    c += m * p.faceGlowStrength * glowCurve * 0.08f;

    return half3(clamp(c, 0.0f, 1.0f));
}

// ── Phase 4C.3: inline feature protection & enhancement (DEC-76/77/78) ───────
// Applied after 4C.2 color layer, before mask blend.
// When featureRestoreStrength=0: returns input unchanged (exact 4C.2).
// Feature detection: smoothstep on varLuma using theta as reference (DEC-77).
// No m-gating — Step 9 mask blend handles edge transitions (DEC-79).
inline half3 _applyFeatureLayer(half3 colorRGB, half3 origRGB, half3 highPass,
                                float varLuma,
                                constant BeautyCompositeParams& p) {
    // F0: Feature detection — smoothstep on varLuma.
    //     Low varLuma (smooth skin) → 0. High varLuma (feature) → 1.
    //     Uses theta as reference point (DEC-77).
    float featureFactor = smoothstep(p.theta, p.theta * 4.0f, varLuma);
    float fStr = featureFactor * clamp(p.featureRestoreStrength, 0.0f, 1.0f);

    // Early exit: no feature detected or master strength is 0 → exact 4C.2.
    if (fStr < 0.001f) return colorRGB;

    float3 color = float3(colorRGB);
    float3 orig  = float3(origRGB);

    // F1: Detail restoration — blend back original texture on features.
    //     At full strength: features get original pixel (bypassing smoothing).
    //     At zero: features stay fully processed (exact 4C.2).
    float restoreAmount = fStr * clamp(p.featureDetailRestore, 0.0f, 1.0f);
    color = mix(color, orig, restoreAmount);

    // F2: Contrast micro-boost — amplify highpass on features.
    //     Makes eyes/brows/lips pop with local contrast.
    //     Multiplied by 2.0 because highPass is in half-range [-0.5, +0.5].
    float contrastAmount = fStr * clamp(p.featureContrastBoost, 0.0f, 1.0f);
    color += float3(highPass) * contrastAmount * 2.0f;

    // F3: Saturation preservation — maintain/boost chroma on features.
    //     Counteracts tone unification (4C.2) and smoothing desaturation.
    //     Max saturation boost: 50% (0.5 multiplier).
    float satAmount = clamp(p.featureSatBoost, 0.0f, 1.0f);
    float newLuma   = dot(color, float3(0.299f, 0.587f, 0.114f));
    float3 chroma   = color - float3(newLuma);
    float satScale  = 1.0f + fStr * satAmount * 0.5f;
    color = float3(newLuma) + chroma * satScale;

    return half3(clamp(color, 0.0f, 1.0f));
}

// ── Phase 4D: inline perceptual feature enhancement (DEC-82/83/86) ───────────
// Applied after 4C.3 feature layer, before mask blend.
// Enhances eyes (brightness + contrast), lips (chroma + clarity),
// brows (micro-contrast) using soft heuristic gates on existing signals.
// PROTOTYPE: uses hardcoded constants — params will be added in Step 2.
// When featureFactor=0 (smooth skin): returns input unchanged (exact 4C.3).
// No m-gating — Step 9 mask blend handles edge transitions (DEC-79).
inline half3 _applyEnhanceLayer(half3 colorRGB, half3 origRGB, half3 highPass,
                                float varLuma, float luma,
                                constant BeautyCompositeParams& p) {
    // Phase 4D (DEC-84): read from params — wired via CPU struct.
    float eyeStrength  = p.eyeEnhanceStrength;
    float lipStrength  = p.lipEnhanceStrength;
    float browStrength = p.browEnhanceStrength;

    // E0: Feature detection — recompute from theta + varLuma (DEC-86).
    //     Same formula as 4C.3 but decoupled — allows independent tuning later.
    float featureFactor = smoothstep(p.theta, p.theta * 4.0f, varLuma);

    // Early exit: smooth skin → no enhancement → exact 4C.3.
    if (featureFactor < 0.001f) return colorRGB;

    float3 color = float3(colorRGB);
    float3 origF = float3(origRGB);

    // Compute chroma magnitude from original pixel (not processed).
    // Using dot(chroma, chroma) instead of length() to avoid sqrt (DEC-82).
    float origLuma   = dot(origF, float3(0.299f, 0.587f, 0.114f));
    float3 chromaVec = origF - float3(origLuma);
    float chromaMag2 = dot(chromaVec, chromaVec);  // squared chroma magnitude

    // ── Classification gates (DEC-82) ──────────────────────────────────────
    // Three soft [0,1] gates using smoothstep — no hard boundaries.
    // All include featureFactor, so smooth skin → all gates ≈ 0.

    // Eye-like: high luma (sclera / iris highlights).
    float eyeGate = featureFactor * smoothstep(0.55f, 0.80f, luma);

    // Lip-like: high chroma (red/pink saturation) + low luma (darker than skin).
    // chromaMag2 thresholds: 0.06² = 0.0036, 0.15² = 0.0225.
    float lipGate = featureFactor
                    * smoothstep(0.0036f, 0.0225f, chromaMag2)
                    * (1.0f - smoothstep(0.3f, 0.6f, luma));

    // Brow-like: low chroma (achromatic hair) + medium-low luma.
    // chromaMag2 thresholds: 0.04² = 0.0016, 0.10² = 0.01.
    float browGate = featureFactor
                     * (1.0f - smoothstep(0.0016f, 0.01f, chromaMag2))
                     * (1.0f - smoothstep(0.5f, 0.7f, luma));

    // ── Enhancement operations ─────────────────────────────────────────────

    // E1: Eye brightness + micro-contrast.
    color += float3(eyeGate * eyeStrength * 0.10f);
    color += float3(highPass) * (eyeGate * eyeStrength * 0.5f);

    // E2: Lip chroma boost + edge clarity.
    float lipSat   = lipGate * lipStrength;
    float newLuma   = dot(color, float3(0.299f, 0.587f, 0.114f));
    float3 lipChroma = color - float3(newLuma);
    color = float3(newLuma) + lipChroma * (1.0f + lipSat * 0.3f);
    color += float3(highPass) * (lipGate * lipStrength * 0.2f);

    // E3: Brow micro-contrast.
    color += float3(highPass) * (browGate * browStrength * 0.4f);

    return half3(clamp(color, 0.0f, 1.0f));
}

// ── Phase 4E: tone polish layer (DEC-90/91/95/96/97) ────────────────────────
// Final perceptual polish: midtone glow + feature-safe micro-smoothing
// + warmth compensation + highlight-protected pseudo-bloom.
// When all polish params < 0.001: returns input unchanged (exact 4D).
inline half3 _applyTonePolish(half3 colorRGB, half3 origRGB, half3 highPass,
                               float luma, float varLuma, float m,
                               constant BeautyCompositeParams& p) {
    // TP-0: Early exit — all polish params zero → exact 4D output.
    if (p.polishGlowStrength   < 0.001f &&
        p.polishSmoothStrength < 0.001f &&
        p.polishWarmthStrength < 0.001f &&
        p.polishBloomStrength  < 0.001f) return colorRGB;

    float3 color = float3(colorRGB);

    // ── TP-1: Soft midtone glow curve with highlight protection ─────────
    // Lifts midtones using a parabolic curve: 4*x*(1-x), peak at luma=0.5.
    // Highlights (luma > 0.80) are protected with a smooth rolloff.
    float midGate   = 4.0f * luma * (1.0f - luma);           // peak=1.0 at 0.5
    float hiProtect = 1.0f - smoothstep(0.80f, 0.95f, luma); // 1→0 in highlights
    float glowLift  = midGate * hiProtect * p.polishGlowStrength * 0.16f;
    color += float3(glowLift);

    // ── TP-2: Feature-safe micro-smoothing via highpass attenuation ─────
    // Subtracts residual highpass on SKIN only. Feature pixels excluded
    // via varLuma masking (DEC-95) to preserve 4C.3 restoration.
    float featureFactor = smoothstep(p.theta, p.theta * 4.0f, varLuma);
    float skinOnly = 1.0f - featureFactor;
    float smoothFactor = p.polishSmoothStrength * m * skinOnly * 0.8f;
    color -= float3(highPass) * smoothFactor;

    // ── TP-3: Warmth compensation ───────────────────────────────────────
    // Adds subtle warm shift to midtones to counter whitening pallor.
    // R:G:B ratio 1.0:0.6:0.0 (DEC-94).
    float warmFactor = midGate * p.polishWarmthStrength * 0.05f;
    color.x += warmFactor * 1.0f;   // red channel
    color.y += warmFactor * 0.6f;   // green channel
    // blue unchanged → net warm shift

    // ── TP-4: Highlight-protected pseudo-bloom (ALU-only) ───────────────
    // Brightens bright pixels with hiProtect rolloff (DEC-96).
    float bloomGate = smoothstep(0.45f, 0.70f, luma);
    float bloomLift = bloomGate * hiProtect * p.polishBloomStrength * m * 0.12f;
    color += float3(bloomLift);

    return half3(clamp(color, 0.0f, 1.0f));
}

kernel void vanguard_beauty_composite(
    texture2d<half, access::read>   origTex [[texture(0)]],
    texture2d<half, access::read>   meanTex [[texture(1)]],
    texture2d<half, access::write>  outTex  [[texture(2)]],   // Phase 9B+ OP-1: was texture(3)
    texture2d<half, access::sample> maskTex [[texture(3)]],   // Phase 9B+ OP-1: was texture(4)
    constant BeautyCompositeParams& params  [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    half4 orig = origTex.read(gid);
    half3 mean = meanTex.read(gid).rgb;

    // 1. Fused highpass — Option A: preserve old clamped [-0.5, +0.5] range.
    // Formerly computed by vanguard_beauty_highpass into intermediateC.
    // Clamp ensures range identical to former BGRA8Unorm storage round-trip.
    // × 2.0 multiplier on detail add-back is preserved unchanged (line ~688).
    half3 highPass = clamp(orig.rgb - mean + half3(0.5h),
                           half3(0.0h), half3(1.0h)) - half3(0.5h);  // [-0.5, +0.5]

    // 2. Per-pixel variance proxy.
    float varLuma = (abs(float(highPass.r)) +
                     abs(float(highPass.g)) +
                     abs(float(highPass.b))) / 3.0f;

    // ── Phase 4C.1: mask-modulated parameter boost (DEC-66/67) ────────────
    // Sample mask BEFORE composite math so it can modulate parameters.
    // When hasMask=0, m=0 and all params remain at base values (exact 4B.6).
    // When hasMask>0 but boosts=0, m>0 but params remain at base values (exact 4C).
    float m = 0.0f;  // mask influence for this pixel
    if (params.hasMask > 0.0f) {
        constexpr sampler maskSampler(filter::linear, address::clamp_to_edge);
        float2 uv = float2(float(gid.x) + 0.5f, float(gid.y) + 0.5f) /
                     float2(float(outTex.get_width()), float(outTex.get_height()));
        half maskVal = maskTex.sample(maskSampler, uv).r;
        m = clamp(float(maskVal) * params.maskStrength, 0.0f, 1.0f);
    }

    // Compute effective parameters: base + mask × boost (DEC-67: additive model).
    // When m=0 (outside face or hasMask=0): effective = base — zero regression.
    float eff_smooth  = clamp(params.smoothStrength + m * params.faceSmoothBoost,  0.0f, 2.0f);
    float eff_tone    = clamp(params.toneStrength   + m * params.faceToneBoost,    0.0f, 1.0f);
    float eff_lift    = clamp(params.midtoneLift    + m * params.faceLiftBoost,    0.0f, 0.25f);
    float eff_damping = clamp(params.detailDamping  - m * params.faceDampingReduce, 0.0f, 1.0f);

    // 3. Adaptive smoothing gate (unchanged from Phase 4B.5).
    //    k → eff_smooth in flat regions (varLuma ≈ 0).
    //    k → 0 at edges (varLuma >> theta).
    float k = (1.0f - varLuma / (varLuma + params.theta)) * eff_smooth;
    k = clamp(k, 0.0f, 1.0f);

    // 4. Blend toward meanColor in flat regions (unchanged).
    half3 smoothed = mix(orig.rgb, mean, half(k));

    // ── Phase 4B.6 perceptual enhancements (DEC-60) ──────────────────────────

    // 5. Detail damping — attenuate texture before add-back.
    //    eff_damping=1.0 → full detail (Phase 4B.5 behavior).
    //    eff_damping<1.0 → softer skin texture.
    half3 dampedDetail = highPass * half(eff_damping);

    // 6. Tone compression — soft S-curve that compresses midtone contrast.
    //    eff_tone=0 → no effect (identity).
    float3 smoothedF = float3(smoothed);
    float luma = dot(smoothedF, float3(0.299f, 0.587f, 0.114f));
    float compressed = luma - eff_tone * 0.08f * sin(luma * 3.14159265f);
    float toneScale = (luma > 0.001f) ? (compressed / luma) : 1.0f;
    half3 toned = half3(clamp(smoothedF * toneScale, 0.0f, 1.0f));

    // 7. Midtone lift — parabolic curve 4×luma×(1-luma), peaks at luma=0.5.
    //    eff_lift=0 → no effect.
    float lift = eff_lift * 4.0f * luma * (1.0f - luma);
    half3 lifted = clamp(toned + half3(half(lift)), half(0.0h), half(1.0h));

    // 8. Add damped detail back. Multiply by 2.0 because highPass is in half-range.
    half3 beautyRGB = clamp(
        lifted + half(params.sharpenStrength) * dampedDetail * half(2.0h),
        half(0.0h), half(1.0h));

    // ── Phase 4C.2: color aesthetic layer (DEC-70/71/73) ───────────────────
    // Applied after Step 8, before mask blend. Reuses existing mask value `m`.
    // When all color params are 0: colorRGB = beautyRGB (exact 4C.1).
    // When hasMask == 0: this block is skipped entirely (exact 4B.6).
    half3 colorRGB = beautyRGB;
    if (params.hasMask > 0.0f && m > 0.001f) {
        colorRGB = _applyColorLayer(beautyRGB, m, params);
    }

    // ── Phase 4C.3: feature protection & enhancement (DEC-76/78) ───────────
    // Applied after 4C.2 color layer, before mask blend.
    // When featureRestoreStrength=0: featureRGB = colorRGB (exact 4C.2).
    // When hasMask == 0: this block is skipped entirely (exact 4B.6).
    // No m-gating inside — Step 9 handles edge transitions (DEC-79).
    half3 featureRGB = colorRGB;
    if (params.hasMask > 0.0f && m > 0.001f) {
        featureRGB = _applyFeatureLayer(colorRGB, orig.rgb, highPass, varLuma, params);
    }

    // ── Phase 4D: perceptual feature enhancement (DEC-82/83) ───────────────
    // Applied after 4C.3, before mask blend.
    // PROTOTYPE: hardcoded strengths inside function — no struct change.
    // When featureFactor=0 (smooth skin): enhancedRGB = featureRGB (exact 4C.3).
    // When hasMask == 0: this block is skipped entirely (exact 4B.6).
    half3 enhancedRGB = featureRGB;
    if (params.hasMask > 0.0f && m > 0.001f) {
        enhancedRGB = _applyEnhanceLayer(featureRGB, orig.rgb, highPass,
                                          varLuma, luma, params);
    }

    // ── Phase 4E: tone polish layer (DEC-90/91) ────────────────────────────
    // Applied after 4D, before mask blend.
    // STEP 1: skeleton only — early exit returns enhancedRGB unchanged.
    // When all polish params are 0: polishedRGB = enhancedRGB (exact 4D).
    // When hasMask == 0: this block is skipped entirely (exact 4B.6).
    half3 polishedRGB = enhancedRGB;
    if (params.hasMask > 0.0f && m > 0.001f) {
        polishedRGB = _applyTonePolish(enhancedRGB, orig.rgb, highPass,
                                        luma, varLuma, m, params);
    }

    // ── Phase 4C/4C.1/4C.2/4C.3/4D/4E: skin mask gating (DEC-63/66/70/76/82/90)
    // When hasMask > 0: blend between original and processed beauty result.
    // When hasMask == 0: output is exact Phase 4B.6 (zero regression).
    half3 finalRGB = polishedRGB;
    if (params.hasMask > 0.0f) {
        finalRGB = mix(orig.rgb, polishedRGB, half(m));
    }


    // 9. Alpha preserved from original (unchanged).
    outTex.write(half4(finalRGB, orig.a), gid);
}

// =============================================================================
// MARK: Color Matrix Apply — Phase 10-C-3L.1C
//
// Applies a 4×5 row-major color matrix to each pixel, matching the layout
// used by Flutter's ColorFilter.matrix:
//   Columns : [R_in, G_in, B_in, A_in, constant]
//   Rows    : [R_out, G_out, B_out, A_out]
//
// The constant term (column 4) follows Flutter convention: a value in [0, 255]
// that is divided by 255.0 before being added to the normalised [0,1] output.
//
// Metal pixel format: MTLPixelFormatBGRA8Unorm.
// Metal auto-swizzles to logical RGBA channels: .r=R, .g=G, .b=B, .a=A.
//
// buffer(0): 20 contiguous floats (4 rows × 5 columns, row-major order).
// texture(0): BGRA8 read.
// texture(1): BGRA8 write.
// =============================================================================

struct ColorMatrixParams {
    float m[20]; // 4 rows × 5 cols, row-major. Matches Flutter ColorFilter.matrix.
};

kernel void vanguard_color_matrix_apply(
    texture2d<half, access::read>  inTex  [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    constant ColorMatrixParams&    cm     [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    half4 p = inTex.read(gid);  // Metal BGRA8 auto-swizzled: .r=R, .g=G, .b=B, .a=A

    // Row 0: R_out = m[0]*R + m[1]*G + m[2]*B + m[3]*A + m[4]/255
    float r = cm.m[0]  * float(p.r)
            + cm.m[1]  * float(p.g)
            + cm.m[2]  * float(p.b)
            + cm.m[3]  * float(p.a)
            + cm.m[4]  / 255.0f;

    // Row 1: G_out = m[5]*R + m[6]*G + m[7]*B + m[8]*A + m[9]/255
    float g = cm.m[5]  * float(p.r)
            + cm.m[6]  * float(p.g)
            + cm.m[7]  * float(p.b)
            + cm.m[8]  * float(p.a)
            + cm.m[9]  / 255.0f;

    // Row 2: B_out = m[10]*R + m[11]*G + m[12]*B + m[13]*A + m[14]/255
    float b = cm.m[10] * float(p.r)
            + cm.m[11] * float(p.g)
            + cm.m[12] * float(p.b)
            + cm.m[13] * float(p.a)
            + cm.m[14] / 255.0f;

    // Row 3: A_out = m[15]*R + m[16]*G + m[17]*B + m[18]*A + m[19]/255
    float a = cm.m[15] * float(p.r)
            + cm.m[16] * float(p.g)
            + cm.m[17] * float(p.b)
            + cm.m[18] * float(p.a)
            + cm.m[19] / 255.0f;

    outTex.write(half4(half(clamp(r, 0.0f, 1.0f)),
                       half(clamp(g, 0.0f, 1.0f)),
                       half(clamp(b, 0.0f, 1.0f)),
                       half(clamp(a, 0.0f, 1.0f))), gid);
}
