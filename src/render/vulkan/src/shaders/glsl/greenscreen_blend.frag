// greenscreen_blend.frag
// DUET-VULKAN-GREENSCREEN-PIXEL-PROOF: three-texture mask blend for
// VulkanGreenScreenCompositor (diagnostic-only in this slice; not wired
// into production Duet preview/export).
//
// Paired with the reused fullscreen-triangle vertex shader in
// passthrough_vert_spv.h. The vertex stage is driven with an identity UV
// transform, so `inUv` is the normalized framebuffer coordinate of the
// fragment centre: inUv = ((x + 0.5) / outputWidth, (y + 0.5) / outputHeight)
// with a top-left origin and Y down. All three textures are sampled with
// that one normalized coordinate, so a mask whose texel grid differs from
// the output grid (e.g. 17x19 mask over a 64x48 output) is scaled by the
// sampler (NEAREST + CLAMP_TO_EDGE in the diagnostic composition root):
// mask texel = floor(inUv * maskSize).
//
// Pinned color / alpha contract (mirrored by the CPU reference in
// vulkan_greenscreen_compositor.cpp and by the JSON `colorContract` /
// `blendFormula` fields of the diagnostic):
//   * background / foreground: VK_FORMAT_R8G8B8A8_UNORM, straight
//     (non-premultiplied) color, sampled as normalized [0,1] floats.
//   * mask: VK_FORMAT_R8_UNORM, .r sampled as normalized maskAlpha in [0,1]
//     (0 -> background, 1 -> foreground).
//   * No sRGB <-> linear conversion anywhere: every operand is a UNORM
//     sample and the arithmetic is in normalized UNORM sample space.
//   * out.rgb = mix(background.rgb, foreground.rgb, maskAlpha)
//     out.a   = mix(background.a,   foreground.a,   maskAlpha)
//   * The fixed-function blend stage is disabled; the value written here is
//     the final RGBA8_UNORM attachment value (round-to-nearest UNORM
//     conversion by the hardware).
//
// No push constants are read by this stage (the reused vertex module owns
// the 112-byte VideoTransformFullPushConstants block on its own).

#version 450

layout(binding = 0) uniform sampler2D uBackground;
layout(binding = 1) uniform sampler2D uForeground;
layout(binding = 2) uniform sampler2D uMask;

layout(location = 0) in vec2 inUv;
layout(location = 0) out vec4 outColor;

void main() {
    vec4 background = texture(uBackground, inUv);
    vec4 foreground = texture(uForeground, inUv);
    float maskAlpha = texture(uMask, inUv).r;
    outColor = vec4(mix(background.rgb, foreground.rgb, maskAlpha),
                    mix(background.a, foreground.a, maskAlpha));
}
