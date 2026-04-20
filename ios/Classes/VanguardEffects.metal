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
    // UVW = normalized RGB of input pixel.
    // For bgra8Unorm input, Metal exposes logical RGBA so pixel.r = red channel.
    half4 mapped = lut.sample(s, float3(pixel.r, pixel.g, pixel.b));
    outTex.write(half4(mapped.rgb, pixel.a), gid);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Bilateral Filter (Beauty)
// Edge-preserving Gaussian: spatial Gaussian × range Gaussian.
// At intensity=0: sigmaColor → 0 → weight only exact-match neighbors → identity.
// P4-FN-5 analytically validates this property.
// ─────────────────────────────────────────────────────────────────────────────

struct BilateralParams {
    float sigmaSpace;   ///< Spatial Gaussian σ (pixel neighbourhood spread)
    float sigmaColor;   ///< Range Gaussian σ (colour similarity gate)
    int   radius;       ///< Filter half-radius in pixels (e.g. 2 for 5×5 kernel)
};

kernel void vanguard_bilateral_filter(
    texture2d<half, access::read>  inTex  [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    constant BilateralParams&      params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    half4 centre = inTex.read(gid);
    float sumW = 0.0, sumR = 0.0, sumG = 0.0, sumB = 0.0;

    const float ss2  = 2.0f * params.sigmaSpace * params.sigmaSpace;
    const float sc2  = 2.0f * params.sigmaColor * params.sigmaColor + 1e-9f;

    for (int dy = -params.radius; dy <= params.radius; ++dy) {
        for (int dx = -params.radius; dx <= params.radius; ++dx) {
            uint2 coord = uint2(
                clamp(int(gid.x) + dx, 0, int(inTex.get_width())  - 1),
                clamp(int(gid.y) + dy, 0, int(inTex.get_height()) - 1));
            half4 nb = inTex.read(coord);
            float spatialD = float(dx*dx + dy*dy);
            float colorD   = dot(float3(nb.rgb - centre.rgb),
                                 float3(nb.rgb - centre.rgb));
            float w = exp(-spatialD / ss2) * exp(-colorD / sc2);
            sumW += w;
            sumR += w * float(nb.r);
            sumG += w * float(nb.g);
            sumB += w * float(nb.b);
        }
    }

    outTex.write(half4(half(sumR/sumW), half(sumG/sumW), half(sumB/sumW), centre.a), gid);
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
    half  mask = maskTex.read(gid).r;       // r8Unorm → [0,1] normalised

    outTex.write(mix(bg, fg, mask), gid);
}
