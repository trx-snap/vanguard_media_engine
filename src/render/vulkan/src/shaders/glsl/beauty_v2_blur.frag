// beauty_v2_blur.frag
// P5-BEAUTY-V2-VULKAN-RENDER: shared horizontal/vertical bilateral blur pass
// for VulkanBeautyV2Compositor (Pass 1 blur_h, Pass 2 blur_v). Mirrors
// kBlurFragmentShaderSrc in gles_beauty_v2_compositor.cpp exactly (same
// clamped texel-fetch addressing, same weighting math); `axis` selects the
// tap-offset dimension so one pipeline serves both passes.
//
// Paired with the reused fullscreen-triangle vertex shader in
// passthrough_vert_spv.h (VideoTransformFullPushConstants, vertex-only bytes
// 0-31: uvTransform0/uvTransform1). This shader does not consume that
// varying (it addresses texels purely through gl_FragCoord, exactly like the
// GLES shader), so it declares no matching input and reads only its own
// fragment-only push constants starting at byte offset 32.
//
// Push constants (fragment-only range, offset 32, size 32 bytes):
//   layout(offset = 32) ivec4 dims;  // x=width y=height z=radius w=axis(0=h,1=v)
//   vec4 sigmas;                     // x=sigma y=rangeSigma z=pad w=pad

#version 450

layout(push_constant) uniform BeautyBlurPC {
    layout(offset = 32) ivec4 dims;
    vec4 sigmas;
} pc;

layout(binding = 0) uniform sampler2D uInputTex;

layout(location = 0) out vec4 fragColor;

const int kMaxLoopRadius = 16;

void main() {
    ivec2 coord = clamp(ivec2(gl_FragCoord.xy), ivec2(0), ivec2(pc.dims.x - 1, pc.dims.y - 1));
    vec4 centreTexel = texelFetch(uInputTex, coord, 0);
    vec3 centre = centreTexel.rgb;

    float sigma = pc.sigmas.x;
    float rangeSigma = pc.sigmas.y;
    float twoSig2 = 2.0 * sigma * sigma;
    float twoRangeSig2 = 2.0 * rangeSigma * rangeSigma;

    int radius = pc.dims.z;
    int axis = pc.dims.w;

    vec3 acc = vec3(0.0);
    float wSum = 0.0;
    for (int i = -kMaxLoopRadius; i <= kMaxLoopRadius; i++) {
        if (i < -radius || i > radius) continue;
        ivec2 tapCoord = coord;
        if (axis == 0) {
            tapCoord.x = clamp(coord.x + i, 0, pc.dims.x - 1);
        } else {
            tapCoord.y = clamp(coord.y + i, 0, pc.dims.y - 1);
        }
        vec3 tap = texelFetch(uInputTex, tapCoord, 0).rgb;
        float spatial = exp(-float(i * i) / twoSig2);
        vec3 delta = tap - centre;
        float range = exp(-dot(delta, delta) / twoRangeSig2);
        float w = spatial * range;
        acc += tap * w;
        wSum += w;
    }

    vec3 result = (wSum > 1e-6) ? (acc / wSum) : centre;
    fragColor = vec4(result, centreTexel.a);
}
