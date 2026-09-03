// beauty_v2_composite.frag
// P5-BEAUTY-V2-VULKAN-RENDER: composite pass (Pass 3) for
// VulkanBeautyV2Compositor. Mirrors kCompositeFragmentShaderSrc in
// gles_beauty_v2_compositor.cpp exactly: fused highpass, adaptive smoothing
// gate, soft-S tone compression, midtone lift, detail add-back, alpha
// preservation from the original (orig) image.
//
// Paired with the reused fullscreen-triangle vertex shader in
// passthrough_vert_spv.h; this shader addresses texels purely through
// gl_FragCoord (matching the GLES shader) and does not consume the vertex
// shader's UV varying. Reads only its own fragment-only push constants
// starting at byte offset 32.
//
// Push constants (fragment-only range, offset 32, size 48 bytes):
//   layout(offset = 32) ivec4 dims;       // x=width y=height z=pad w=pad
//   vec4 strengths0;                      // x=smoothStrength y=sharpenStrength
//                                          // z=theta w=detailDamping
//   vec4 strengths1;                      // x=toneStrength y=midtoneLift
//                                          // z=pad w=pad

#version 450

layout(push_constant) uniform BeautyCompositePC {
    layout(offset = 32) ivec4 dims;
    vec4 strengths0;
    vec4 strengths1;
} pc;

layout(binding = 0) uniform sampler2D uOrigTex;
layout(binding = 1) uniform sampler2D uMeanTex;

layout(location = 0) out vec4 fragColor;

void main() {
    ivec2 coord = clamp(ivec2(gl_FragCoord.xy), ivec2(0), ivec2(pc.dims.x - 1, pc.dims.y - 1));
    vec4 orig = texelFetch(uOrigTex, coord, 0);
    vec3 mean = texelFetch(uMeanTex, coord, 0).rgb;

    vec3 highPass = clamp(orig.rgb - mean + vec3(0.5), 0.0, 1.0) - vec3(0.5);
    float varLuma = (abs(highPass.r) + abs(highPass.g) + abs(highPass.b)) / 3.0;

    float smoothStrength = pc.strengths0.x;
    float sharpenStrength = pc.strengths0.y;
    float theta = pc.strengths0.z;
    float detailDamping = pc.strengths0.w;
    float toneStrength = pc.strengths1.x;
    float midtoneLift = pc.strengths1.y;

    float k = clamp((1.0 - varLuma / (varLuma + theta)) * smoothStrength, 0.0, 1.0);
    vec3 smoothed = mix(orig.rgb, mean, k);
    vec3 dampedDetail = highPass * detailDamping;

    float luma = dot(smoothed, vec3(0.299, 0.587, 0.114));
    float compressed = luma - toneStrength * 0.08 * sin(luma * 3.14159265);
    float toneScale = (luma > 0.001) ? (compressed / luma) : 1.0;
    vec3 toned = clamp(smoothed * toneScale, 0.0, 1.0);

    float lift = midtoneLift * 4.0 * luma * (1.0 - luma);
    vec3 lifted = clamp(toned + vec3(lift), 0.0, 1.0);

    vec3 beauty = clamp(lifted + sharpenStrength * dampedDetail * 2.0, 0.0, 1.0);
    fragColor = vec4(beauty, orig.a);
}
