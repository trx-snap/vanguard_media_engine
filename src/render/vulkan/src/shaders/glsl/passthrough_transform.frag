// passthrough_transform.frag
// Vanguard Android True-DAG Phase 10: fullscreen-triangle fragment shader
// sampling the imported source image and applying an optional Vulkan-native
// colorMatrix, matching GLES/Flutter ColorFilter.matrix semantics exactly
// (see AndroidTimelineVideoEncoder's uColorMatrixRow0..3/uColorMatrixOffset
// GLSL fragment shader).
//
// Shares the same 7-vec4 push-constant block/offsets as
// passthrough_transform.vert (VideoTransformFullPushConstants, 112 bytes):
//   layout(push_constant) uniform Transform {
//     vec4 uvTransform0;      // offset  0: vertex-only
//     vec4 uvTransform1;      // offset 16: vertex-only
//     vec4 colorMatrixRow0;   // offset 32
//     vec4 colorMatrixRow1;   // offset 48
//     vec4 colorMatrixRow2;   // offset 64
//     vec4 colorMatrixRow3;   // offset 80
//     vec4 colorMatrixOffset; // offset 96
//   } xf;
//
// Identity defaults (colorMatrixRow0=[1,0,0,0], row1=[0,1,0,0],
// row2=[0,0,1,0], row3=[0,0,0,1], offset=[0,0,0,0]) leave the sampled color
// unchanged, so this shader is safe to use for every render, not only frames
// carrying a clip colorMatrix.

#version 450

layout(push_constant) uniform Transform {
    vec4 uvTransform0;
    vec4 uvTransform1;
    vec4 colorMatrixRow0;
    vec4 colorMatrixRow1;
    vec4 colorMatrixRow2;
    vec4 colorMatrixRow3;
    vec4 colorMatrixOffset;
} xf;

layout(binding = 0) uniform sampler2D uTexture;

layout(location = 0) in vec2 inUv;
layout(location = 1) in vec2 inViewportNdc;
layout(location = 0) out vec4 outColor;

void main() {
    float r = xf.uvTransform0.z;
    if (r > 0.0) {
        float aspect = xf.uvTransform1.z;
        vec2 p = abs(vec2(inViewportNdc.x, inViewportNdc.y * aspect));
        vec2 b = vec2(1.0, aspect);
        vec2 q = p - b + vec2(r);
        float dist = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
        if (dist > 0.0) {
            discard;
        }
    }

    vec4 rgba = texture(uTexture, inUv);
    outColor = clamp(
        vec4(
            dot(xf.colorMatrixRow0, rgba) + xf.colorMatrixOffset.r,
            dot(xf.colorMatrixRow1, rgba) + xf.colorMatrixOffset.g,
            dot(xf.colorMatrixRow2, rgba) + xf.colorMatrixOffset.b,
            dot(xf.colorMatrixRow3, rgba) + xf.colorMatrixOffset.a
        ),
        0.0,
        1.0
    );
}
