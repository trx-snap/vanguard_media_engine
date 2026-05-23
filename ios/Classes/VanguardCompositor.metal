//
// VanguardCompositor.metal
// Vanguard Media Engine — Phase 3 GPU Render Pass
//
// Two-layer alpha composite shader:
//   - Plane 0 (background): Y+CbCr planes from bottom video track
//   - Plane 1 (foreground): Y+CbCr planes from top video track OR bitmap PNG
//   - Output: BGRA8Unorm composited frame for hardware encoder + Flutter Texture
//
// The YCbCr → RGB conversion uses BT.709 (HD) coefficients which match
// AVAssetReader's kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange output.

#include <metal_stdlib>
using namespace metal;

// --- Structures ---

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// --- Uniforms ---

struct CompositorUniforms {
    float alpha;          // Foreground layer alpha (0.0 = invisible, 1.0 = opaque)
    float contrast;       // Contrast adjustment (1.0 = no change)
    float brightness;     // Brightness offset (0.0 = no change)
    float saturation;     // Saturation multiplier (1.0 = no change)
};

// --- Utility Functions ---

// BT.709 YCbCr → RGB conversion.
// y:  luminance plane sampled as .r
// cb: chrominance plane blue-difference sampled as .r
// cr: chrominance plane red-difference sampled as .g
float3 ycbcrToRgb(float y, float cb, float cr) {
    float Y  = y  - 16.0  / 255.0;
    float Cb = cb - 128.0 / 255.0;
    float Cr = cr - 128.0 / 255.0;
    float R = clamp(1.164 * Y + 1.793 * Cr, 0.0, 1.0);
    float G = clamp(1.164 * Y - 0.213 * Cb - 0.533 * Cr, 0.0, 1.0);
    float B = clamp(1.164 * Y + 2.112 * Cb, 0.0, 1.0);
    return float3(R, G, B);
}

// Applies contrast, brightness, and saturation to an RGB color.
float3 applyEffects(float3 color, float contrast, float brightness, float saturation) {
    // Brightness
    color += brightness;
    // Contrast (pivot at 0.5)
    color = (color - 0.5) * contrast + 0.5;
    // Saturation (mix with luminance)
    float luminance = dot(color, float3(0.299, 0.587, 0.114));
    color = mix(float3(luminance), color, saturation);
    return clamp(color, 0.0, 1.0);
}

// --- Vertex Shader ---

vertex VertexOut vanguard_vertex(
    VertexIn in [[stage_in]]
) {
    VertexOut out;
    // Normalize clip space: NDC x = [-1, 1], y = [-1, 1]
    out.position = float4(in.position.x * 2.0 - 1.0, -(in.position.y * 2.0 - 1.0), 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

// --- Fragment Shader: Composite ---

fragment float4 vanguard_composite(
    VertexOut in                          [[stage_in]],
    texture2d<float> bgY                  [[texture(0)]],
    texture2d<float> bgCbCr               [[texture(1)]],
    texture2d<float> fgY                  [[texture(2)]],
    texture2d<float> fgCbCr               [[texture(3)]],
    constant CompositorUniforms& uniforms  [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);

    // Background layer (BT.709 YCbCr → RGB)
    float bgLuma     = bgY.sample(s, in.texCoord).r;
    float2 bgChroma  = bgCbCr.sample(s, in.texCoord).rg;
    float3 bgRgb     = ycbcrToRgb(bgLuma, bgChroma.r, bgChroma.g);

    // Foreground layer (BT.709 YCbCr → RGB)
    float fgLuma     = fgY.sample(s, in.texCoord).r;
    float2 fgChroma  = fgCbCr.sample(s, in.texCoord).rg;
    float3 fgRgb     = ycbcrToRgb(fgLuma, fgChroma.r, fgChroma.g);

    // Apply effects to foreground
    fgRgb = applyEffects(fgRgb, uniforms.contrast, uniforms.brightness, uniforms.saturation);

    // Alpha blend foreground over background
    float3 blended = mix(bgRgb, fgRgb, uniforms.alpha);

    return float4(blended, 1.0);
}

// --- HLG Preview Colour Helpers ---

// Inverse HLG OETF (ITU-R BT.2100): encoded signal -> scene-linear light.
float3 hlgInverseOETF(float3 E) {
    const float a = 0.17883277;
    const float b = 0.28466892;
    const float c = 0.55991073;
    return float3(
        (E.r <= 0.5) ? (E.r * E.r / 3.0) : ((exp((E.r - c) / a) + b) / 12.0),
        (E.g <= 0.5) ? (E.g * E.g / 3.0) : ((exp((E.g - c) / a) + b) / 12.0),
        (E.b <= 0.5) ? (E.b * E.b / 3.0) : ((exp((E.b - c) / a) + b) / 12.0)
    );
}

// sRGB OETF: scene-linear -> display-encoded.
float3 sRGBEncode(float3 L) {
    return select(12.92 * L,
                  1.055 * pow(L, float3(1.0 / 2.4)) - 0.055,
                  L > 0.0031308);
}

// --- Fragment Shader: Rotated Blit ---
// Samples srcTexture with UV remapped according to rotationIndex:
//   0 = identity (pass-through)
//   1 = +90°  (back-camera portrait:  b≈+1)
//   2 = -90°  (front-camera portrait: b≈-1)
//   3 = 180°  (upside-down:           a≈-1)
// Reuses vanguard_vertex — no new vertex shader needed.

fragment float4 vanguard_blit_rotated(
    VertexOut in                   [[stage_in]],
    texture2d<float> srcTexture    [[texture(0)]],
    constant uint& rotationIndex   [[buffer(0)]],
    constant uint& isHLG           [[buffer(1)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);
    float2 uv = in.texCoord;
    if      (rotationIndex == 1) uv = float2(uv.y, 1.0 - uv.x);        // +90
    else if (rotationIndex == 2) uv = float2(1.0 - uv.y, uv.x);        // -90
    else if (rotationIndex == 3) uv = float2(1.0 - uv.x, 1.0 - uv.y); // 180
    float4 sampled = srcTexture.sample(s, uv);
    float3 color = sampled.rgb;

    if (isHLG != 0) {
        // HLG live-preview colour correction — preview path only.
        // Step 1: inverse HLG OETF -> BT.2020 scene-linear
        float3 bt2020Linear = hlgInverseOETF(max(color, float3(0.0)));
        // Step 2: BT.2020 -> BT.709 colour matrix (ITU-R BT.2087 Table 2)
        float3x3 M = float3x3(
            float3( 1.6605, -0.1246, -0.0182),
            float3(-0.5876,  1.1329, -0.1006),
            float3(-0.0728, -0.0083,  1.1187)
        );
        float3 bt709Linear = clamp(M * bt2020Linear, 0.0, 1.0);
        // Step 3: sRGB OETF encode -> display-correct signal
        color = sRGBEncode(bt709Linear);
    }

    return float4(color, sampled.a);
}

// --- Fragment Shader: Rotated Blit with Crop + Mirror Correction (Phase 6C) ---
//
// Extends vanguard_blit_rotated with aspect-fill crop and front-camera mirror
// correction. Existing callers of vanguard_blit_rotated are UNAFFECTED.
//
// Buffer layout:
//   buffer(0) -> rotationIndex:     uint   (0=identity, 1=+90, 2=-90, 3=180)
//   buffer(1) -> isHLG:             uint   (0=SDR, 1=HLG colour correction)
//   buffer(2) -> cropUniforms:      float4 (offsetU, offsetV, scaleU, scaleV)
//                 offsetU/V: UV origin of the visible crop window (centre crop)
//                 scaleU/V:  UV scale of the visible crop window (<= 1.0)
//   buffer(3) -> mirrorCorrection:  uint   (0=off, 1=flip tex.y after rotation)
//
// UV pipeline (all in [0,1] space):
//   1. Apply crop: uv = offset + uv * scale   (select central window)
//   2. Apply rotation: remap uv per rotationIndex
//   3. Apply mirror: flip uv.y if mirrorCorrection == 1
//
// Preserves existing vanguard_vertex + vertex descriptor -- no vertex changes.

fragment float4 vanguard_blit_rotated_ex(
    VertexOut in                    [[stage_in]],
    texture2d<float> srcTexture     [[texture(0)]],
    constant uint&   rotationIndex  [[buffer(0)]],
    constant uint&   isHLG          [[buffer(1)]],
    constant float4& cropUniforms   [[buffer(2)]],  // (offsetU, offsetV, scaleU, scaleV)
    constant uint&   mirrorCorrection [[buffer(3)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);

    float2 uv = in.texCoord;

    // Step 1: apply aspect-fill crop (select central visible window).
    float2 cropOffset = float2(cropUniforms.x, cropUniforms.y);
    float2 cropScale  = float2(cropUniforms.z, cropUniforms.w);
    uv = cropOffset + uv * cropScale;

    // Step 2: apply rotation (same mapping as vanguard_blit_rotated).
    if      (rotationIndex == 1) uv = float2(uv.y, 1.0 - uv.x);        // +90 CW
    else if (rotationIndex == 2) uv = float2(1.0 - uv.y, uv.x);        // -90 CCW
    else if (rotationIndex == 3) uv = float2(1.0 - uv.x, 1.0 - uv.y); // 180

    // Step 3: mirror correction -- flip tex.y to correct front-camera
    // portrait-space horizontal mirror becoming a display vertical flip
    // after 90° rotation into landscape.
    if (mirrorCorrection != 0) {
        uv.y = 1.0 - uv.y;
    }

    float4 sampled = srcTexture.sample(s, uv);
    float3 color   = sampled.rgb;

    if (isHLG != 0) {
        float3 bt2020Linear = hlgInverseOETF(max(color, float3(0.0)));
        float3x3 M = float3x3(
            float3( 1.6605, -0.1246, -0.0182),
            float3(-0.5876,  1.1329, -0.1006),
            float3(-0.0728, -0.0083,  1.1187)
        );
        float3 bt709Linear = clamp(M * bt2020Linear, 0.0, 1.0);
        color = sRGBEncode(bt709Linear);
    }

    return float4(color, sampled.a);
}
