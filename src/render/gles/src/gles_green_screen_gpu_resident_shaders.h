// gles_green_screen_gpu_resident_shaders.h
// ANDROID-GREENSCREEN-GPU-RESIDENT: GLSL sources for GlesGreenScreenGpuResidentRenderer.
//
// Adapted from the RND gpuzero `shaders/shaders.h` (downscale / guided filter /
// temporal stabilizer / composite). Every hardcoded RND geometry constant
// (256 model size, 720x1280 alpha resolution, 1080x2340 screen, the 16:9 ->
// 19.5:9 crop scale, the axis swap + `uMirror` orientation hack) has been
// replaced by uniforms driven from the renderer's state:
//
//   - Camera UV policy (identical in all three camera-sampling passes):
//       camUv = (uCameraStMatrix * vec4(quadUv, 0, 1)).xy
//     where quadUv is "quad space": the [0,1]^2 coordinate of the displayed
//     camera layer with v=0 at the BOTTOM (GL convention, exactly the space
//     the proven AndroidGreenScreenPreviewCompositor feeds through its
//     `uSTMatrix * aTextureCoord` vertex path). uCameraStMatrix is the
//     SurfaceTexture transform matrix latched with the frame.
//   - Model input rows run top-down, so the downscale pass flips v once.
//   - The coarse mask texture (model output, row 0 = top) is therefore sampled
//     at (q.x, 1 - q.y) wherever quad space is used.
//   - Alpha ping/pong/history textures live in quad space at
//     uAlphaResolution (derived from the output size and camera aspect).
//   - The composite pass maps every output pixel to quad space through the
//     aspect-fill camera viewport and the camera scissor rect supplied as
//     uniforms; the background is drawn over the source rect.
//
// Private header: included only by gles_green_screen_gpu_resident_renderer.cpp.

#pragma once

namespace vanguard {
namespace render {
namespace green_screen_gpu_resident_shaders {

// Compute: downscale the latched camera OES frame into the model input
// texture (RGBA8, model width x height). Model row 0 is the top of the
// upright camera image.
inline const char* kDownscaleComputeShader = R"GLSL(#version 310 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
precision highp int;

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(binding = 0) uniform samplerExternalOES uCameraTexture;
layout(binding = 1, rgba8) uniform writeonly highp image2D uModelInputImage;

uniform ivec2 uModelSize;
uniform mat4 uCameraStMatrix;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    if (coord.x >= uModelSize.x || coord.y >= uModelSize.y) return;

    vec2 modelUv = (vec2(coord) + 0.5) / vec2(uModelSize);
    // Model rows run top-down; quad space runs bottom-up.
    vec2 quadUv = vec2(modelUv.x, 1.0 - modelUv.y);
    vec2 camUv = (uCameraStMatrix * vec4(quadUv, 0.0, 1.0)).xy;

    vec4 color = texture(uCameraTexture, camUv);
    imageStore(uModelInputImage, coord, vec4(color.rgb, 1.0));
}
)GLSL";

// Compute: guided filter. Snaps the coarse neural alpha to camera luminance
// edges (hair strands / fingers). Output: refined alpha in quad space at
// uAlphaResolution.
inline const char* kGuidedFilterComputeShader = R"GLSL(#version 310 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
precision highp int;

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(binding = 0) uniform samplerExternalOES uCameraTexture;
layout(binding = 1) uniform sampler2D uCoarseAlphaTexture;
layout(binding = 2, r32f) uniform writeonly highp image2D uRefinedAlphaImage;

uniform vec2 uAlphaResolution;
uniform mat4 uCameraStMatrix;
uniform bool uFilterEnabled;

float getLuma(vec3 rgb) {
    return dot(rgb, vec3(0.299, 0.587, 0.114));
}

vec2 camUvFor(vec2 quadUv) {
    return (uCameraStMatrix * vec4(quadUv, 0.0, 1.0)).xy;
}

float coarseAlphaAt(vec2 quadUv) {
    // Coarse mask row 0 is the top of the image; quad space v=0 is the bottom.
    return texture(uCoarseAlphaTexture, vec2(quadUv.x, 1.0 - quadUv.y)).r;
}

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    if (coord.x >= int(uAlphaResolution.x) || coord.y >= int(uAlphaResolution.y)) return;

    vec2 uv = (vec2(coord) + 0.5) / uAlphaResolution;

    float rawAlpha = coarseAlphaAt(uv);

    if (!uFilterEnabled) {
        imageStore(uRefinedAlphaImage, coord, vec4(rawAlpha, 0.0, 0.0, 1.0));
        return;
    }

    // Fast path: solid foreground interior (>0.96) or deep background (<0.03).
    if (rawAlpha < 0.03) {
        imageStore(uRefinedAlphaImage, coord, vec4(0.0, 0.0, 0.0, 1.0));
        return;
    }
    if (rawAlpha > 0.96) {
        imageStore(uRefinedAlphaImage, coord, vec4(1.0, 0.0, 0.0, 1.0));
        return;
    }

    float centerI = getLuma(texture(uCameraTexture, camUvFor(uv)).rgb);

    // 25-point isotropic circular kernel (stride = 2 alpha pixels).
    const vec2 offsets[25] = vec2[25](
        vec2( 0.0,  0.0),
        vec2( 1.5,  0.0), vec2(-1.5,  0.0), vec2( 0.0,  1.5), vec2( 0.0, -1.5),
        vec2( 1.1,  1.1), vec2(-1.1,  1.1), vec2( 1.1, -1.1), vec2(-1.1, -1.1),
        vec2( 3.0,  0.0), vec2(-3.0,  0.0), vec2( 0.0,  3.0), vec2( 0.0, -3.0),
        vec2( 2.1,  2.1), vec2(-2.1,  2.1), vec2( 2.1, -2.1), vec2(-2.1, -2.1),
        vec2( 5.0,  0.0), vec2(-5.0,  0.0), vec2( 0.0,  5.0), vec2( 0.0, -5.0),
        vec2( 3.5,  3.5), vec2(-3.5,  3.5), vec2( 3.5, -3.5), vec2(-3.5, -3.5)
    );

    vec2 step = 2.0 / uAlphaResolution;
    float sumI = 0.0;
    float sumP = 0.0;
    float sumII = 0.0;
    float sumIp = 0.0;

    for (int i = 0; i < 25; i++) {
        vec2 offsetUv = clamp(uv + offsets[i] * step, 0.0, 1.0);
        float I = getLuma(texture(uCameraTexture, camUvFor(offsetUv)).rgb);
        float p = coarseAlphaAt(offsetUv);
        sumI  += I;
        sumP  += p;
        sumII += I * I;
        sumIp += I * p;
    }

    float meanI = sumI * 0.04;
    float meanP = sumP * 0.04;
    float varI  = max(0.0, (sumII * 0.04) - (meanI * meanI));
    float covIp = (sumIp * 0.04) - (meanI * meanP);

    // Regularization eps: 1e-4 lets high-frequency hair strands transfer from camera luminance.
    float a = covIp / (varI + 1e-4);
    float b = meanP - a * meanI;

    float refinedAlpha = clamp(a * centerI + b, 0.0, 1.0);

    // Boundary zone: optical alpha from the guided filter; interior/background keep the raw alpha.
    float edgeFactor = smoothstep(0.03, 0.14, rawAlpha) * smoothstep(0.96, 0.85, rawAlpha);
    float finalAlpha = mix(rawAlpha, refinedAlpha, edgeFactor);

    imageStore(uRefinedAlphaImage, coord, vec4(finalAlpha, 0.0, 0.0, 1.0));
}
)GLSL";

// Compute: temporal stabilizer (optional). Reads the current refined alpha
// and the previous stabilized alpha (separate history texture, no in-place
// read/write hazard) and writes the stabilized alpha.
inline const char* kTemporalStabilizerComputeShader = R"GLSL(#version 310 es
precision highp float;
precision highp int;

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(binding = 0) uniform sampler2D uCurrAlpha;
layout(binding = 1) uniform sampler2D uPrevAlpha;
layout(binding = 2, r32f) uniform writeonly highp image2D uStabilizedAlpha;

uniform vec2 uAlphaResolution;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    if (coord.x >= int(uAlphaResolution.x) || coord.y >= int(uAlphaResolution.y)) return;

    vec2 uv = (vec2(coord) + 0.5) / uAlphaResolution;

    float currA = texture(uCurrAlpha, uv).r;
    float prevA = texture(uPrevAlpha, uv).r;

    float diffAlpha = abs(currA - prevA);

    // Zero-lag motion response: snap to the current frame on movement, blend only when static.
    float blendRate = (diffAlpha > 0.015) ? 1.0 : mix(0.35, 1.0, diffAlpha / 0.015);
    float finalAlpha = mix(prevA, currA, blendRate);

    imageStore(uStabilizedAlpha, coord, vec4(finalAlpha, 0.0, 0.0, 1.0));
}
)GLSL";

// Vertex: full-screen quad (position only; the fragment shader derives
// everything from gl_FragCoord).
inline const char* kCompositeVertexShader = R"GLSL(#version 300 es
layout(location = 0) in vec2 aPosition;

void main() {
    gl_Position = vec4(aPosition, 0.0, 1.0);
}
)GLSL";

// Fragment: final composite. Background over the source rect, then the
// camera layer (placeholder / passthrough / masked) inside the camera
// scissor rect through the aspect-fill camera viewport.
//
// All rect uniforms are GL window pixels (origin bottom-left): x, y, w, h.
inline const char* kCompositeFragmentShader = R"GLSL(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
precision highp int;

out vec4 fragColor;

uniform samplerExternalOES uCameraTexture;
uniform sampler2D uAlphaTexture;
uniform sampler2D uBackgroundImage;

uniform vec2 uAlphaResolution;
uniform mat4 uCameraStMatrix;
uniform vec4 uSourceRect;
uniform vec4 uCameraScissor;
uniform vec4 uCameraViewport;
uniform vec4 uBackgroundImageRect;
uniform vec4 uBackgroundColor;
uniform vec4 uPlaceholderColor;
uniform int uBackgroundMode;  // 0 black, 1 solid color, 2 image
uniform int uCameraMode;      // 0 none, 1 placeholder, 2 passthrough, 3 masked
uniform bool uDespillEnabled;

bool inRect(vec2 p, vec4 r) {
    return p.x >= r.x && p.y >= r.y && p.x < (r.x + r.z) && p.y < (r.y + r.w);
}

float getLuma(vec3 rgb) {
    return dot(rgb, vec3(0.299, 0.587, 0.114));
}

vec2 camUvFor(vec2 quadUv) {
    return (uCameraStMatrix * vec4(quadUv, 0.0, 1.0)).xy;
}

float sampleHermiteAlpha(vec2 uv) {
    vec2 res = uAlphaResolution;
    vec2 pos = uv * res - 0.5;
    vec2 f = fract(pos);
    vec2 p = (floor(pos) + 0.5) / res;
    vec2 d = 1.0 / res;
    // Cubic Hermite smoothstep for C1-continuous derivatives across texels.
    vec2 s = f * f * (3.0 - 2.0 * f);
    float a00 = texture(uAlphaTexture, p).r;
    float a10 = texture(uAlphaTexture, p + vec2(d.x, 0.0)).r;
    float a01 = texture(uAlphaTexture, p + vec2(0.0, d.y)).r;
    float a11 = texture(uAlphaTexture, p + d).r;
    return mix(mix(a00, a10, s.x), mix(a01, a11, s.x), s.y);
}

vec3 maskedCamera(vec2 uv, vec3 background) {
    vec3 cameraColor = texture(uCameraTexture, camUvFor(uv)).rgb;
    float alpha = sampleHermiteAlpha(uv);

    // Isotropic 8-point anti-aliased boundary refinement (radius 1.5 alpha pixels).
    vec2 px = 1.5 / uAlphaResolution;
    float aN = sampleHermiteAlpha(uv + vec2(0.0, px.y));
    float aS = sampleHermiteAlpha(uv - vec2(0.0, px.y));
    float aE = sampleHermiteAlpha(uv + vec2(px.x, 0.0));
    float aW = sampleHermiteAlpha(uv - vec2(px.x, 0.0));

    vec2 dPx = px * 0.7071068;
    float aNE = sampleHermiteAlpha(uv + vec2( dPx.x,  dPx.y));
    float aNW = sampleHermiteAlpha(uv + vec2(-dPx.x,  dPx.y));
    float aSE = sampleHermiteAlpha(uv + vec2( dPx.x, -dPx.y));
    float aSW = sampleHermiteAlpha(uv + vec2(-dPx.x, -dPx.y));

    float minCardinal = min(min(aN, aS), min(aE, aW));
    float minDiagonal = min(min(aNE, aNW), min(aSE, aSW));
    float isotropicMin = min(minCardinal, minDiagonal);

    // Soft boundary contraction: pulls the boundary inward to remove light wall fringe.
    float boundaryT = smoothstep(0.10, 0.85, alpha);
    float softAlpha = mix(isotropicMin, alpha, boundaryT);

    // Continuous sigmoidal threshold with C1 sub-pixel antialiasing.
    float compAlpha = smoothstep(0.05, 0.95, softAlpha);

    // Ambient wall light decontamination (despill) along the inward normal.
    if (uDespillEnabled && compAlpha > 0.02 && compAlpha < 0.90) {
        vec2 grad = vec2(aE - aW, aN - aS);
        float gradLen = length(grad);
        if (gradLen > 0.001) {
            vec2 inDir = (grad / gradLen) * 3.0 * px;
            float inAlpha = sampleHermiteAlpha(uv + inDir);
            if (inAlpha > 0.70) {
                vec3 inCol = texture(uCameraTexture, camUvFor(clamp(uv + inDir, 0.0, 1.0))).rgb;
                float inLuma = getLuma(inCol);
                float camLuma = getLuma(cameraColor);
                if (camLuma > inLuma * 1.05) {
                    cameraColor = mix(cameraColor, inCol, (1.0 - compAlpha) * 0.70);
                }
            }
        }
    }

    return mix(background, cameraColor, compAlpha);
}

void main() {
    vec2 p = gl_FragCoord.xy;
    vec3 col = vec3(0.0);

    // Background layer over the source rect.
    if (inRect(p, uSourceRect)) {
        if (uBackgroundMode == 1) {
            col = uBackgroundColor.rgb;
        } else if (uBackgroundMode == 2 && inRect(p, uBackgroundImageRect)) {
            vec2 iuv = (p - uBackgroundImageRect.xy) / uBackgroundImageRect.zw;
            // Image row 0 is the top row; GL v=0 is the bottom.
            col = texture(uBackgroundImage, vec2(iuv.x, 1.0 - iuv.y)).rgb;
        }
    }

    // Camera layer inside the camera scissor rect.
    if (uCameraMode != 0 && inRect(p, uCameraScissor)) {
        if (uCameraMode == 1) {
            col = uPlaceholderColor.rgb;
        } else {
            vec2 quadUv = (p - uCameraViewport.xy) / uCameraViewport.zw;
            if (all(greaterThanEqual(quadUv, vec2(0.0))) && all(lessThanEqual(quadUv, vec2(1.0)))) {
                if (uCameraMode == 2) {
                    col = texture(uCameraTexture, camUvFor(quadUv)).rgb;
                } else {
                    col = maskedCamera(quadUv, col);
                }
            }
        }
    }

    fragColor = vec4(col, 1.0);
}
)GLSL";

}  // namespace green_screen_gpu_resident_shaders
}  // namespace render
}  // namespace vanguard
