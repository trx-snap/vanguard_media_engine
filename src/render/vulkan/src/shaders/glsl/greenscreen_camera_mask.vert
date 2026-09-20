// greenscreen_camera_mask.vert
// ANDROID-DUET-VULKAN-GREENSCREEN-MATTE: private fullscreen-triangle vertex
// shader for VulkanGreenScreenFrameRenderer's camera-over-source alpha-mask
// layer (glsl/greenscreen_blend.frag compiled with
// -DVANGUARD_DUET_CAMERA_MASK=1). Compiled into
// shaders/greenscreen_camera_mask_vert_spv.h as kGreenScreenCameraMaskVertSpv.
//
// Identical to passthrough_transform.vert (same fullscreen triangle, same
// push-constant UV transform producing the aspect-fill-cropped camera UV at
// location 0) PLUS a second, untransformed "raw" UV at location 1 that the
// fragment stage samples the green-screen MASK with. It is private to the
// green-screen helper; the shared passthrough vertex module is untouched.
//
// Push constants (VulkanGreenScreenCameraMaskPushConstants, 128 bytes,
// offset 0; the first 112 bytes are VideoTransformFullPushConstants pushed
// verbatim, the trailing vec4 is fragment-only):
//   vec4 uvTransform0;      // offset   0: row0 coefficients [cx, cy, 0, bias] for u
//   vec4 uvTransform1;      // offset  16: row1 coefficients [cx, cy, 0, bias] for v
//   vec4 colorMatrixRow0;   // offset  32: fragment-only
//   vec4 colorMatrixRow1;   // offset  48: fragment-only
//   vec4 colorMatrixRow2;   // offset  64: fragment-only
//   vec4 colorMatrixRow3;   // offset  80: fragment-only
//   vec4 colorMatrixOffset; // offset  96: fragment-only
//   vec4 maskDebug;         // offset 112: fragment-only (debugMode, texelW, texelH, 0)
// This vertex shader reads only uvTransform0/uvTransform1.
//
// Raw UV orientation contract: the pipeline's viewport is exactly the camera
// rect, so the fullscreen triangle's base UV spans that rect with (0,0) at
// its TOP-left (Vulkan clip space is Y-down). The GLES compositor's raw quad
// coordinate (aTextureCoord in AndroidDuetPreviewCompositor's green-screen
// program) instead has (0,0) at the rect's BOTTOM-left (GL clip space is
// Y-up). outRawUv is therefore emitted as (base.x, 1.0 - base.y) -- the GLES
// convention -- so every mask-UV formula in the fragment stage (mask_direct,
// mask_direct_mirror_x, mask_direct_flip_y and the normal-mode
// (raw.x, 1.0 - raw.y) matte policy) is textually identical to the GLES
// shader AND produces the same picture for the same mask on both backends.

#version 450

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

layout(location = 0) out vec2 outUv;
layout(location = 1) out vec2 outRawUv;

// Fullscreen triangle positions in clip space (NDC).
// gl_VertexIndex: 0=(-1,-1), 1=(3,-1), 2=(-1,3)
const vec2 kPositions[3] = vec2[](
    vec2(-1.0, -1.0),
    vec2( 3.0, -1.0),
    vec2(-1.0,  3.0)
);

// Identity UV coordinates for each vertex (in [0,1] space):
// 0=(0,0), 1=(2,0), 2=(0,2)
const vec2 kUvBase[3] = vec2[](
    vec2(0.0, 0.0),
    vec2(2.0, 0.0),
    vec2(0.0, 2.0)
);

void main() {
    vec2 pos = kPositions[gl_VertexIndex];
    vec2 uv  = kUvBase[gl_VertexIndex];

    // Transformed camera UV (aspect-fill crop + rotation / mirror), exactly
    // as passthrough_transform.vert computes it.
    vec4 uvExt = vec4(uv.x, uv.y, 0.0, 1.0);
    outUv = vec2(dot(xf.uvTransform0, uvExt),
                 dot(xf.uvTransform1, uvExt));

    // Raw camera-rect UV in the GLES quad convention (bottom-left origin);
    // see the orientation contract above.
    outRawUv = vec2(uv.x, 1.0 - uv.y);

    gl_Position = vec4(pos, 0.0, 1.0);
}
