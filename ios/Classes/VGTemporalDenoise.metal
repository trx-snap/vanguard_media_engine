// VGTemporalDenoise.metal
// vanguard_media_engine — Phase 10 Temporal Video Denoise (Proof Slice)
//
// One-frame-history temporal denoise compute kernel.
//
// Algorithm per pixel:
//   1. Compute BT.709 luma for current and history pixel.
//   2. diff = abs(currentLuma - historyLuma).
//   3. motionWeight = 1.0 - smoothstep(motionThreshold * 0.5, motionThreshold, diff).
//      → High motion (diff ≥ motionThreshold): motionWeight ≈ 0 → strongly favor current.
//      → Low motion  (diff < threshold * 0.5): motionWeight ≈ 1 → blend with history.
//   4. blendAmount = motionWeight * blendStrength.
//   5. output = mix(current, history, blendAmount).
//   6. Alpha preserved from current frame.
//
// Kernel conventions match VanguardEffects.metal:
//   • half precision for throughput on A-series GPU.
//   • texture2d read/write (not sample) — matches color matrix kernel pattern.
//   • BGRA8Unorm pixel format: Metal auto-swizzles .r=R .g=G .b=B .a=A.
//   • Early-exit on out-of-bounds gid.
//   • No global memory write hazards (inputs read-only, output write-only).
//
// Tunable constants live in the ObjC caller (TemporalDenoiseParams), not here.
// This kernel intentionally has no hard-coded thresholds.

#include <metal_stdlib>
using namespace metal;

// CPU-side mirror struct in VGTimelineCompositorNode.m must match this layout.
struct TemporalDenoiseParams {
    float blendStrength;    ///< Conservative blend cap [0.0–1.0]. ObjC default: 0.20.
    float motionThreshold;  ///< Luma-diff threshold above which pixels favor current frame.
                            ///< ObjC default: 0.06. Units: linear [0.0–1.0] luma.
};

kernel void vanguard_temporal_denoise(
    texture2d<half, access::read>  currentFrame  [[texture(0)]],
    texture2d<half, access::read>  historyFrame  [[texture(1)]],
    texture2d<half, access::write> outputFrame   [[texture(2)]],
    constant TemporalDenoiseParams& params        [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    // Bounds guard — same pattern as all VanguardEffects.metal kernels.
    if (gid.x >= outputFrame.get_width() || gid.y >= outputFrame.get_height()) return;

    // Read current and history pixels.
    // Metal BGRA8Unorm auto-swizzle: .r = Red, .g = Green, .b = Blue, .a = Alpha.
    half4 cur = currentFrame.read(gid);
    half4 his = historyFrame.read(gid);

    // BT.709 luma coefficients (Rec. 709 standard).
    const half3 lumaCoeff = half3(0.2126h, 0.7152h, 0.0722h);

    half curLuma = dot(cur.rgb, lumaCoeff);
    half hisLuma = dot(his.rgb, lumaCoeff);

    // Luma difference drives the motion gate.
    half diff = abs(curLuma - hisLuma);

    // smoothstep(lo, hi, x): 0 when x <= lo; 1 when x >= hi; smooth in between.
    // lo = motionThreshold * 0.5, hi = motionThreshold.
    // motionWeight = 1 - smoothstep → near 1 for static areas, near 0 for motion.
    half lo = half(params.motionThreshold) * 0.5h;
    half hi = half(params.motionThreshold);
    half t  = clamp((diff - lo) / max(hi - lo, 1e-5h), 0.0h, 1.0h);
    half motionWeight = 1.0h - (t * t * (3.0h - 2.0h * t)); // cubic smoothstep

    // blend fraction: 0 on motion (output = current), blendStrength on static.
    half blendAmount = motionWeight * half(params.blendStrength);

    // mix(a, b, t) = a + (b - a) * t; t=0 → cur, t=1 → his.
    // blendAmount near 0 → strongly favor current (motion guard).
    half3 blended = mix(cur.rgb, his.rgb, blendAmount);

    // Preserve alpha from current frame.
    outputFrame.write(half4(blended, cur.a), gid);
}
