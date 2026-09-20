// greenscreen_blend.frag
// Two fragment programs selected at glslc time from one source file:
//
//   * default (no define): DUET-VULKAN-GREENSCREEN-PIXEL-PROOF three-texture
//     mask blend for VulkanGreenScreenCompositor (diagnostic-only; not wired
//     into production Duet preview/export). Compiled into
//     shaders/greenscreen_blend_frag_spv.h as kGreenScreenBlendFragSpv.
//
//   * -DVANGUARD_DUET_CAMERA_MASK=1: ANDROID-DUET-VULKAN-GREENSCREEN-VISUAL /
//     ANDROID-DUET-VULKAN-GREENSCREEN-MATTE camera-over-source alpha-mask
//     layer for VulkanGreenScreenFrameRenderer's recordCameraDraw
//     (diagnostic Vulkan Duet preview session only). Compiled into the same
//     header as kGreenScreenCameraMaskFragSpv.
//
// The default variant pairs with the reused fullscreen-triangle vertex shader
// in passthrough_vert_spv.h (passthrough_transform.vert). The camera-mask
// variant pairs with the green-screen helper's private
// greenscreen_camera_mask.vert (greenscreen_camera_mask_vert_spv.h), which
// additionally exposes the raw camera-rect UV the mask debug modes sample.

#version 450

#ifdef VANGUARD_DUET_CAMERA_MASK

// ---------------------------------------------------------------------------
// Camera-mask variant.
//
// Drawn as the SECOND layer of a Duet green-screen frame, after the opaque
// source/decoder layer has already been drawn through the core passthrough
// shaders. The pipeline's viewport is exactly the camera rect (scissor = rect
// clipped to the canvas), so the vertex stage's base (x, y) spans the camera
// rect and `inUv` is the aspect-fill-cropped camera UV produced by
// ResolveVulkanDuetLayoutLayerPlacement's push constants -- the same UV
// mapping the layout (PiP / split) path uses for the camera layer. `inRawUv`
// is the untransformed camera-rect UV in the GLES quad convention
// (bottom-left origin; see greenscreen_camera_mask.vert); it is consumed
// only by the debug modes, whose formulas stay textually identical to the
// GLES green-screen fragment shader in AndroidDuetPreviewCompositor.kt.
//
//   set 0, binding 0: the camera import's own descriptor set (immutable
//                     external-format YCbCr sampler baked into the set
//                     layout), so an AHardwareBuffer camera frame samples
//                     with the same colour contract as the layout path.
//   set 1, binding 0: the green-screen mask (R8 CPU upload or RGBA8 GPU
//                     import), .r in [0,1] (0 -> background, 1 -> camera),
//                     sampled with the renderer's own LINEAR / CLAMP_TO_EDGE
//                     sampler.
//
// Push constants: the 112-byte VideoTransformFullPushConstants block pushed
// verbatim by the caller, plus one trailing vec4 `maskDebug` private to the
// green-screen helper (VulkanGreenScreenCameraMaskPushConstants, 128 bytes):
//   maskDebug.x  = debug mode (0 = normal, 1 = mask_direct, 2 = mask_mapped,
//                  3 = mask_direct_mirror_x, 4 = mask_direct_flip_y),
//   maskDebug.yz = (1/maskWidth, 1/maskHeight) in mask UV space, driving the
//                  one-mask-pixel erosion taps in normal mode only,
//   maskDebug.w  = reserved (0).
//
// Mask UV / matte policy (ANDROID-DUET-VULKAN-GREENSCREEN-MATTE): the mask
// is produced from the same native camera frame `uCamera` samples, so normal
// mode samples it with the TRANSFORMED camera UV (maskUv = clamp(inUv, 0.0,
// 1.0)). The matte thus follows the same aspect-fill crop, 270-degree
// rotation and front-camera mirror as the camera texel, then is eroded by
// one mask texel (min of centre + 4 direct neighbours) and shaped with
// smoothstep(0.52, 0.78). The former GLES parity policy (raw camera-rect UV
// with Y flipped) is no longer valid for the corrected Vulkan-native camera
// stream: physical RND on SM-A566B (cameraRot=270, cameraMirror=1) showed
// the raw-UV matte rotated against the correctly placed camera. Raw-UV
// sampling survives only in the mask_direct* diagnostics.
//
// Debug modes 1..4 (RND diagnostic, selected by maskDebug.x) write the mask
// as opaque grayscale instead of the camera: the pipeline's viewport /
// scissor already confine the draw to the camera rect, so the grayscale
// never leaks outside it. camera_passthrough (GLES mode 5) is not a shader
// mode here: the Kotlin compositor routes it to the opaque layout path, and
// mask_full_white is a forced 1x1 white CPU mask upload rendered in normal
// mode.
//
// Colour: the camera sample goes through the same push-constant colour
// matrix as passthrough_transform.frag (identity by default), then its alpha
// is scaled by the matte. The pipeline blends with straight alpha
// (SRC_ALPHA / ONE_MINUS_SRC_ALPHA) over the already-drawn source layer.

layout(push_constant) uniform Transform {
    vec4 uvTransform0;
    vec4 uvTransform1;
    vec4 colorMatrixRow0;
    vec4 colorMatrixRow1;
    vec4 colorMatrixRow2;
    vec4 colorMatrixRow3;
    vec4 colorMatrixOffset;
    vec4 maskDebug;
} xf;

layout(set = 0, binding = 0) uniform sampler2D uCamera;
layout(set = 1, binding = 0) uniform sampler2D uMask;

layout(location = 0) in vec2 inUv;
layout(location = 1) in vec2 inRawUv;
layout(location = 0) out vec4 outColor;

void main() {
    // Debug mode arrives as a small non-negative integer stored in a float
    // (exact for 0..4); anything outside 1..4 is normal compositing.
    int debugMode = int(xf.maskDebug.x + 0.5);
    if (debugMode == 1) {
        // mask_direct: raw mask at the raw camera-rect UV.
        float rawMaskAlpha = texture(uMask, inRawUv).r;
        outColor = vec4(rawMaskAlpha, rawMaskAlpha, rawMaskAlpha, 1.0);
        return;
    }
    if (debugMode == 2) {
        // mask_mapped: raw mask at the transformed (aspect-fill-cropped,
        // rotated / mirrored) camera UV, clamped like the GLES vMaskCoord.
        float rawMaskAlpha = texture(uMask, clamp(inUv, 0.0, 1.0)).r;
        outColor = vec4(rawMaskAlpha, rawMaskAlpha, rawMaskAlpha, 1.0);
        return;
    }
    if (debugMode == 3) {
        // mask_direct_mirror_x: raw mask sampled with X inverted, to help
        // RND spot a front-camera horizontal mirror mismatch.
        float rawMaskAlpha = texture(uMask, vec2(1.0 - inRawUv.x, inRawUv.y)).r;
        outColor = vec4(rawMaskAlpha, rawMaskAlpha, rawMaskAlpha, 1.0);
        return;
    }
    if (debugMode == 4) {
        // mask_direct_flip_y: raw mask sampled with Y inverted, to help RND
        // spot a front-camera vertical flip mismatch.
        float rawMaskAlpha = texture(uMask, vec2(inRawUv.x, 1.0 - inRawUv.y)).r;
        outColor = vec4(rawMaskAlpha, rawMaskAlpha, rawMaskAlpha, 1.0);
        return;
    }

    vec4 rgba = texture(uCamera, inUv);
    vec4 camera = clamp(
        vec4(
            dot(xf.colorMatrixRow0, rgba) + xf.colorMatrixOffset.r,
            dot(xf.colorMatrixRow1, rgba) + xf.colorMatrixOffset.g,
            dot(xf.colorMatrixRow2, rgba) + xf.colorMatrixOffset.b,
            dot(xf.colorMatrixRow3, rgba) + xf.colorMatrixOffset.a
        ),
        0.0,
        1.0
    );

    // Normal mode: transformed camera UV, so the matte follows the same
    // aspect-fill crop / rotation / mirror as the camera texel (the UV
    // mask_mapped visualises above).
    vec2 maskUv = clamp(inUv, 0.0, 1.0);
    float centerAlpha = texture(uMask, maskUv).r;
    // Conservative GPU-side matte refinement: take the minimum of the centre
    // tap and its four direct neighbours (one mask pixel away, clamped inside
    // [0,1]). This erodes the matte by one mask pixel so false-positive room
    // background clinging to the head/shoulder silhouette shrinks, while the
    // true person core (uniformly high confidence) is unaffected.
    vec2 maskTexelSize = xf.maskDebug.yz;
    float leftAlpha  = texture(uMask, clamp(maskUv - vec2(maskTexelSize.x, 0.0), 0.0, 1.0)).r;
    float rightAlpha = texture(uMask, clamp(maskUv + vec2(maskTexelSize.x, 0.0), 0.0, 1.0)).r;
    float upAlpha    = texture(uMask, clamp(maskUv - vec2(0.0, maskTexelSize.y), 0.0, 1.0)).r;
    float downAlpha  = texture(uMask, clamp(maskUv + vec2(0.0, maskTexelSize.y), 0.0, 1.0)).r;
    float erodedAlpha = min(centerAlpha, min(min(leftAlpha, rightAlpha), min(upAlpha, downAlpha)));
    // Shape the eroded MediaPipe selfie-segmentation confidence with the
    // same feather as the GLES compositor, so low-confidence background is
    // rejected while true edge pixels still feather smoothly.
    float maskAlpha = smoothstep(0.52, 0.78, erodedAlpha);
    outColor = vec4(camera.rgb, camera.a * maskAlpha);
}

#else // pixel-proof three-texture blend (default variant)

// ---------------------------------------------------------------------------
// DUET-VULKAN-GREENSCREEN-PIXEL-PROOF: three-texture mask blend for
// VulkanGreenScreenCompositor (diagnostic-only in this slice; not wired
// into production Duet preview/export).
//
// The vertex stage is driven with an identity UV transform, so `inUv` is the
// normalized framebuffer coordinate of the fragment centre:
// inUv = ((x + 0.5) / outputWidth, (y + 0.5) / outputHeight) with a top-left
// origin and Y down. All three textures are sampled with that one normalized
// coordinate, so a mask whose texel grid differs from the output grid (e.g.
// 17x19 mask over a 64x48 output) is scaled by the sampler (NEAREST +
// CLAMP_TO_EDGE in the diagnostic composition root):
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

#endif
