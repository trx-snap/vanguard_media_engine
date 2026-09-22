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

// ═════════════════════════════════════════════════════════════════════════════
// MARK: - GPU Zero Green Screen Metal Compute Pipelines (< 12.5ms & Sub-Pixel Parity)
// ═════════════════════════════════════════════════════════════════════════════

struct GreenScreenDownscaleUniforms {
    uint mirror;
    float cropScale;
};

struct GreenScreenGuidedUniforms {
    float2 resolution;      // canvas resolution (e.g. 720, 1280)
    float eps;             // 1e-4
    uint filterEnabled;    // 1
    float4 cropUniforms;   // (offsetU, offsetV, scaleU, scaleV)
    uint rotationIndex;    // 0=identity, 1=+90 CW, 2=-90 CCW, 3=180
    uint mirrorCorrection; // 0=off, 1=flip
    uint isBiPlanar;       // 0=BGRA, 1=YCbCr biplanar
    uint _pad;
};

struct GreenScreenTemporalUniforms {
    float2 resolution;
    uint stabilizerEnabled;
    uint _pad;
};

struct GreenScreenCompositeUniforms {
    float2 resolution;
    float4 solidColor;
    uint outputMode;       // 0: straight-alpha, 1: solid color, 2: texture, 5: raw cam, 6: mask inspect
    uint despillEnabled;
    float4 cropUniforms;   // (offsetU, offsetV, scaleU, scaleV)
    uint rotationIndex;    // 0=identity, 1=+90 CW, 2=-90 CCW, 3=180
    uint mirrorCorrection; // 0=off, 1=flip
    uint isBiPlanar;       // 0=BGRA, 1=YCbCr biplanar
    uint _pad;
};

inline float getGreenScreenLuma(float3 rgb) {
    return dot(rgb, float3(0.299, 0.587, 0.114));
}

// Maps canvas UV [0, 1]^2 to camera UV [0, 1]^2 with aspect-fill crop, rotation, and mirror correction.
inline float2 getGreenScreenCameraUv(float2 uv, float4 cropUniforms, uint rotationIndex, uint mirrorCorrection) {
    float2 cropOffset = float2(cropUniforms.x, cropUniforms.y);
    float2 cropScale  = float2(cropUniforms.z, cropUniforms.w);
    float2 normUv = cropOffset + uv * cropScale;

    if (rotationIndex == 0) {
        // Landscape / pass-through
        float effX = (mirrorCorrection != 0) ? (1.0 - normUv.x) : normUv.x;
        return float2(effX, normUv.y);
    } else {
        // Portrait front camera (sensor 1920x1440):
        // Upright vertical: canvas top (v=0) maps to sensor top (camX=cropOffset.y).
        // Canvas bottom (v=1) maps to sensor bottom (camX=cropOffset.y + cropScale.y).
        float camX = normUv.y;
        // Horizontal:
        // By default (mirrorCorrection == 0), selfie-mirrored matching Vanguard front camera:
        // Canvas left (u=0) maps to sensor right, canvas right (u=1) maps to sensor left.
        // Raising user's right hand raises right hand on screen.
        // When mirrorCorrection != 0, spectator unmirrored (raising user's right hand shows on screen left).
        float camY = (mirrorCorrection != 0) ? normUv.x : (1.0 - normUv.x);
        return float2(camX, camY);
    }
}

// ── 1. Downscale Compute Kernel (Camera 1080p -> 256x256 RGB input) ─────────
kernel void kernel_greenscreen_downscale(
    texture2d<float, access::sample> uCameraTexture  [[texture(0)]],
    texture2d<float, access::write>  uDownscaledImage [[texture(1)]],
    constant GreenScreenDownscaleUniforms& u          [[buffer(0)]],
    uint2 coord                                      [[thread_position_in_grid]]
) {
    if (coord.x >= 256 || coord.y >= 256) return;
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = (float2(coord) + 0.5) / 256.0;
    float effX = (u.mirror != 0) ? (1.0 - uv.x) : uv.x;
    float2 camUv = float2(0.5 + (effX - 0.5) * u.cropScale, uv.y);
    float4 color = uCameraTexture.sample(s, camUv);
    uDownscaledImage.write(float4(color.rgb, 1.0), coord);
}

// ── 2. 25-Point Isotropic Guided Filter (Sub-Pixel Edge Snapping) ───────────
constant float2 kGreenScreenGuidedOffsets[25] = {
    float2( 0.0,  0.0),
    // Ring 1 (radius 1.5)
    float2( 1.5,  0.0), float2(-1.5,  0.0), float2( 0.0,  1.5), float2( 0.0, -1.5),
    float2( 1.1,  1.1), float2(-1.1,  1.1), float2( 1.1, -1.1), float2(-1.1, -1.1),
    // Ring 2 (radius 3.0)
    float2( 3.0,  0.0), float2(-3.0,  0.0), float2( 0.0,  3.0), float2( 0.0, -3.0),
    float2( 2.1,  2.1), float2(-2.1,  2.1), float2( 2.1, -2.1), float2(-2.1, -2.1),
    // Ring 3 (radius 5.0)
    float2( 5.0,  0.0), float2(-5.0,  0.0), float2( 0.0,  5.0), float2( 0.0, -5.0),
    float2( 3.5,  3.5), float2(-3.5,  3.5), float2( 3.5, -3.5), float2(-3.5, -3.5)
};

kernel void kernel_greenscreen_guided_filter(
    texture2d<float, access::sample> uCameraTexture      [[texture(0)]], // Camera Y (or BGRA)
    texture2d<float, access::sample> uCoarseAlphaTexture [[texture(1)]], // ARKit raw matte (.r8Unorm)
    texture2d<float, access::write>  uRefinedAlphaImage  [[texture(2)]], // Refined alpha at canvas resolution
    constant GreenScreenGuidedUniforms& u                [[buffer(0)]],
    uint2 coord                                          [[thread_position_in_grid]]
) {
    if (coord.x >= uint(u.resolution.x) || coord.y >= uint(u.resolution.y)) return;

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = (float2(coord) + 0.5) / u.resolution;
    float2 centerCamUv = getGreenScreenCameraUv(uv, u.cropUniforms, u.rotationIndex, u.mirrorCorrection);

    // Sample coarse alpha from ARKit matte at camera UV
    float rawAlpha = uCoarseAlphaTexture.sample(s, centerCamUv).r;

    // High-resolution input bypass: Apple ARMatteGenerator (1920x1440) already performs
    // high-resolution guided refinement. Re-filtering over high-res matte adds ISO noise and motion grain.
    if (u.filterEnabled == 0 || uCoarseAlphaTexture.get_width() > 512) {
        uRefinedAlphaImage.write(float4(rawAlpha, 0.0, 0.0, 1.0), coord);
        return;
    }

    // Fast path: solid foreground interior (>0.96) or deep background (<0.03)
    if (rawAlpha < 0.03) {
        uRefinedAlphaImage.write(float4(0.0, 0.0, 0.0, 1.0), coord);
        return;
    }
    if (rawAlpha > 0.96) {
        uRefinedAlphaImage.write(float4(1.0, 0.0, 0.0, 1.0), coord);
        return;
    }

    float centerI = (u.isBiPlanar != 0) ? uCameraTexture.sample(s, centerCamUv).r
                                        : getGreenScreenLuma(uCameraTexture.sample(s, centerCamUv).rgb);

    // 25-point isotropic circular guided filter
    float2 step = 2.0 / u.resolution;
    float sumI  = 0.0;
    float sumP  = 0.0;
    float sumII = 0.0;
    float sumIp = 0.0;

    for (int i = 0; i < 25; i++) {
        float2 offsetUv = uv + kGreenScreenGuidedOffsets[i] * step;
        float2 offsetCamUv = getGreenScreenCameraUv(offsetUv, u.cropUniforms, u.rotationIndex, u.mirrorCorrection);

        float I = (u.isBiPlanar != 0) ? uCameraTexture.sample(s, offsetCamUv).r
                                      : getGreenScreenLuma(uCameraTexture.sample(s, offsetCamUv).rgb);
        float p = uCoarseAlphaTexture.sample(s, offsetCamUv).r;

        sumI  += I;
        sumP  += p;
        sumII += I * I;
        sumIp += I * p;
    }

    float meanI = sumI * 0.04;
    float meanP = sumP * 0.04;
    float varI  = max(0.0, (sumII * 0.04) - (meanI * meanI));
    float covIp = (sumIp * 0.04) - (meanI * meanP);

    float a = covIp / (varI + u.eps);
    float b = meanP - a * meanI;

    float refinedAlpha = clamp(a * centerI + b, 0.0, 1.0);

    float edgeFactor = smoothstep(0.03, 0.14, rawAlpha) * smoothstep(0.96, 0.85, rawAlpha);
    float finalAlpha = mix(rawAlpha, refinedAlpha, edgeFactor);

    uRefinedAlphaImage.write(float4(finalAlpha, 0.0, 0.0, 1.0), coord);
}

// ── 3. Temporal Stability Compute Kernel (Strict Zero-Lag Motion Snap) ────────
kernel void kernel_greenscreen_temporal_stabilize(
    texture2d<float, access::sample> uCurrAlpha       [[texture(0)]],
    texture2d<float, access::sample> uPrevAlpha       [[texture(1)]],
    texture2d<float, access::write>  uStabilizedAlpha [[texture(2)]],
    constant GreenScreenTemporalUniforms& u           [[buffer(0)]],
    uint2 coord                                       [[thread_position_in_grid]]
) {
    if (coord.x >= uint(u.resolution.x) || coord.y >= uint(u.resolution.y)) return;
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = (float2(coord) + 0.5) / u.resolution;

    float currA = uCurrAlpha.sample(s, uv).r;
    float prevA = uPrevAlpha.sample(s, uv).r;

    if (u.stabilizerEnabled == 0) {
        uStabilizedAlpha.write(float4(currA, 0.0, 0.0, 1.0), coord);
        return;
    }

    float diffAlpha = abs(currA - prevA);
    // Strict zero-lag motion snap: snap 100% to current frame on movement (glued to face).
    // Blend only when completely static to eliminate camera sensor grain.
    float blendRate = (diffAlpha > 0.012) ? 1.0 : mix(0.35, 1.0, diffAlpha / 0.012);
    float finalAlpha = mix(prevA, currA, blendRate);

    uStabilizedAlpha.write(float4(finalAlpha, 0.0, 0.0, 1.0), coord);
}

// ── 4. Hermite Antialiased Composite & Despill Kernel ─────────────────────────
inline float sampleGreenScreenHermiteAlpha(texture2d<float, access::sample> tex, sampler s, float2 uv, float2 res) {
    float2 pos = uv * res - 0.5;
    float2 f = fract(pos);
    float2 p = (floor(pos) + 0.5) / res;
    float2 d = 1.0 / res;
    float2 st = f * f * (3.0 - 2.0 * f);
    float a00 = tex.sample(s, p).r;
    float a10 = tex.sample(s, p + float2(d.x, 0.0)).r;
    float a01 = tex.sample(s, p + float2(0.0, d.y)).r;
    float a11 = tex.sample(s, p + d).r;
    return mix(mix(a00, a10, st.x), mix(a01, a11, st.x), st.y);
}

inline float3 sampleCameraColor(
    texture2d<float, access::sample> uCameraY,
    texture2d<float, access::sample> uCameraCbCr,
    sampler s,
    float2 camUv,
    uint isBiPlanar
) {
    if (isBiPlanar != 0) {
        float y = uCameraY.sample(s, camUv).r;
        float2 cbcr = uCameraCbCr.sample(s, camUv).rg;
        return ycbcrToRgb(y, cbcr.r, cbcr.g);
    } else {
        return uCameraY.sample(s, camUv).rgb;
    }
}

kernel void kernel_greenscreen_composite_despill(
    texture2d<float, access::sample> uCameraY         [[texture(0)]], // Camera Y (or BGRA)
    texture2d<float, access::sample> uCameraCbCr      [[texture(1)]], // Camera CbCr (or dummy)
    texture2d<float, access::sample> uAlphaTexture    [[texture(2)]], // Stabilized alpha (canvas res)
    texture2d<float, access::sample> uBgTexture       [[texture(3)]], // Background (canvas res)
    texture2d<float, access::write>  uOutputImage     [[texture(4)]], // Output image (canvas res)
    constant GreenScreenCompositeUniforms& u          [[buffer(0)]],
    uint2 coord                                       [[thread_position_in_grid]]
) {
    if (coord.x >= uint(u.resolution.x) || coord.y >= uint(u.resolution.y)) return;
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = (float2(coord) + 0.5) / u.resolution;
    float2 camUv = getGreenScreenCameraUv(uv, u.cropUniforms, u.rotationIndex, u.mirrorCorrection);

    float3 cameraColor = sampleCameraColor(uCameraY, uCameraCbCr, s, camUv, u.isBiPlanar);

    // Studio "Virtual Key Light" & Face Warmth Recovery:
    // In flat/cloudy indoor daylight, recover natural facial warmth, midtone exposure, and healthy skin tones:
    float rawCamLuma = getGreenScreenLuma(cameraColor);
    float3 litColor = pow(max(cameraColor, float3(0.0)), float3(0.94));
    litColor.r = min(1.0, litColor.r * 1.025);
    litColor.b = min(1.0, litColor.b * 0.985);
    litColor = mix(float3(rawCamLuma), litColor, 1.06);
    cameraColor = clamp(litColor, 0.0, 1.0);

    float alpha = sampleGreenScreenHermiteAlpha(uAlphaTexture, s, uv, u.resolution);

    // Isotropic Cardinal Analysis for Despill Normal Gradient
    float2 px = float2(1.5 / u.resolution.x, 1.5 / u.resolution.y);
    float aN = sampleGreenScreenHermiteAlpha(uAlphaTexture, s, uv + float2(0.0, px.y), u.resolution);
    float aS = sampleGreenScreenHermiteAlpha(uAlphaTexture, s, uv - float2(0.0, px.y), u.resolution);
    float aE = sampleGreenScreenHermiteAlpha(uAlphaTexture, s, uv + float2(px.x, 0.0), u.resolution);
    float aW = sampleGreenScreenHermiteAlpha(uAlphaTexture, s, uv - float2(px.x, 0.0), u.resolution);

    // 1. High-Frequency Hair Edge Detail Transfer:
    // Boost fine hair strand contrast in the transition zone using the local Laplacian.
    // Gated to alpha in [0.20, 0.80] with a noise deadzone to eliminate floating specks in the background.
    float refinedA = alpha;
    if (alpha > 0.20 && alpha < 0.80) {
        float laplacianA = alpha - 0.25 * (aN + aS + aE + aW);
        if (abs(laplacianA) > 0.02) {
            float hairBoost = clamp(laplacianA * 0.25, -0.08, 0.08) * smoothstep(0.20, 0.45, alpha) * smoothstep(0.80, 0.55, alpha);
            refinedA = clamp(alpha + hairBoost, 0.0, 1.0);
        }
    }

    // Continuous sub-pixel Hermite edge transition with subtle interior choke:
    // Choking the outer edge from 0.12 removes residual room-light fringe while keeping sub-pixel hair strands smooth.
    float compAlpha = smoothstep(0.12, 0.92, refinedA);

    // 2. Low-Light Boundary Cross-Bilateral De-Noiser:
    // In dim/cloudy light, sensor ISO gain causes high-frequency buzzing along the boundary.
    // Cross-bilateral smoothing along the edge eliminates sensor grain while preserving sharp hair edges:
    if (compAlpha > 0.05 && compAlpha < 0.92) {
        float2 camUvN = getGreenScreenCameraUv(uv + float2(0.0, px.y), u.cropUniforms, u.rotationIndex, u.mirrorCorrection);
        float2 camUvS = getGreenScreenCameraUv(uv - float2(0.0, px.y), u.cropUniforms, u.rotationIndex, u.mirrorCorrection);
        float2 camUvE = getGreenScreenCameraUv(uv + float2(px.x, 0.0), u.cropUniforms, u.rotationIndex, u.mirrorCorrection);
        float2 camUvW = getGreenScreenCameraUv(uv - float2(px.x, 0.0), u.cropUniforms, u.rotationIndex, u.mirrorCorrection);

        float3 colN = sampleCameraColor(uCameraY, uCameraCbCr, s, camUvN, u.isBiPlanar);
        float3 colS = sampleCameraColor(uCameraY, uCameraCbCr, s, camUvS, u.isBiPlanar);
        float3 colE = sampleCameraColor(uCameraY, uCameraCbCr, s, camUvE, u.isBiPlanar);
        float3 colW = sampleCameraColor(uCameraY, uCameraCbCr, s, camUvW, u.isBiPlanar);

        float wN = exp(-distance(cameraColor, colN) * 10.0);
        float wS = exp(-distance(cameraColor, colS) * 10.0);
        float wE = exp(-distance(cameraColor, colE) * 10.0);
        float wW = exp(-distance(cameraColor, colW) * 10.0);
        float totalW = 1.0 + wN + wS + wE + wW;
        cameraColor = (cameraColor + colN * wN + colS * wS + colE * wE + colW * wW) / totalW;
    }

    // 3. Optical Chromatic Green Spill Neutralization:
    // Neutralize ugly green bounce on skin, ears, and hair edges
    if (u.despillEnabled != 0 && compAlpha > 0.02) {
        float maxRB = max(cameraColor.r, cameraColor.b);
        if (cameraColor.g > maxRB) {
            float excessG = cameraColor.g - maxRB;
            float despillFactor = smoothstep(0.98, 0.35, compAlpha);
            cameraColor.g -= excessG * despillFactor;
            // Restore lost luminance into warm natural skin tones
            cameraColor.rb += float2(excessG * 0.25 * despillFactor);
        }
    }

    // 4. Ambient Wall Light Decontamination (Despill) using Inward Normal
    if (u.despillEnabled != 0 && compAlpha > 0.02 && compAlpha < 0.90) {
        float2 grad = float2(aE - aW, aN - aS);
        float gradLen = length(grad);
        if (gradLen > 0.001) {
            float2 inDir = (grad / gradLen) * 3.5 * px;
            float inAlpha = sampleGreenScreenHermiteAlpha(uAlphaTexture, s, uv + inDir, u.resolution);
            if (inAlpha > 0.65) {
                float2 inCamUv = getGreenScreenCameraUv(uv + inDir, u.cropUniforms, u.rotationIndex, u.mirrorCorrection);
                float3 inCol = sampleCameraColor(uCameraY, uCameraCbCr, s, inCamUv, u.isBiPlanar);
                float inLuma = getGreenScreenLuma(inCol);
                float curLuma = getGreenScreenLuma(cameraColor);
                if (curLuma > inLuma * 1.05) {
                    cameraColor = mix(cameraColor, inCol, (1.0 - compAlpha) * 0.75);
                }
            }
        }
    }

    // 5. Background color, Exposure Harmonization & Subtle Light Wrap:
    float3 bgCol = (u.outputMode == 1) ? u.solidColor.rgb : uBgTexture.sample(s, uv).rgb;
    if (u.outputMode != 0) {
        // Exposure Harmonization: bridge contrast gap when subject is in cloudy/dim light over bright background
        float bgLuma = getGreenScreenLuma(bgCol);
        float curLuma = getGreenScreenLuma(cameraColor);
        if (bgLuma > 0.55 && curLuma < 0.50) {
            float exposureGap = (bgLuma - curLuma) * 0.16;
            cameraColor = min(float3(1.0), cameraColor * (1.0 + exposureGap));
        }

        // Naturally soften outer silhouette edge into background without washing out dark hair
        if (compAlpha > 0.15 && compAlpha < 0.85) {
            float lumaWeight = clamp(curLuma * 0.8 + 0.2, 0.2, 1.0);
            float wrapWeight = smoothstep(0.85, 0.45, compAlpha) * smoothstep(0.15, 0.45, compAlpha) * 0.08 * lumaWeight;
            cameraColor = mix(cameraColor, bgCol, wrapWeight);
        }
    }

    float4 finalPixel;
    if (u.outputMode == 0) {
        // Straight-alpha output (for Duet / graph compositor)
        finalPixel = (compAlpha > 0.0) ? float4(cameraColor, compAlpha) : float4(0.0);
    } else if (u.outputMode == 5) {
        // Raw camera feed pass
        finalPixel = float4(cameraColor, 1.0);
    } else if (u.outputMode == 6) {
        // Mask inspection pass
        finalPixel = float4(float3(compAlpha), 1.0);
    } else {
        // Background composite (solid color or texture)
        finalPixel = float4(mix(bgCol, cameraColor, compAlpha), 1.0);
    }

    uOutputImage.write(finalPixel, coord);
}

