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
// ANDROID-DUET-VULKAN-GREENSCREEN-FREE-TRANSFORM: PLUS a second, alternate
// draw path -- a real 2-triangle (6-vertex) quad built from 4 CPU-rotated NDC
// corners -- used only for a Duet green-screen foreground layer that has a
// non-identity user free-transform rotation (see
// VulkanGreenScreenFrameRenderer::recordCameraDraw). Selected per-draw by
// maskDebug.w (0.0 = original fullscreen-triangle path unchanged in every
// respect, non-zero = rotated-quad path), independent of camera sensor/
// content rotation (which stays entirely in uvTransform0/1 as before). Both
// paths feed the exact same outUv / outRawUv formulas from their own base UV,
// so the fragment stage and every mask-UV / colour-matrix formula there is
// untouched and produces identical output for identical logical UV.
//
// Push constants (VulkanGreenScreenCameraMaskPushConstants, 160 bytes,
// offset 0; the first 128 bytes are byte-for-byte unchanged from the
// pre-rotation layout -- VideoTransformFullPushConstants (112 bytes) plus the
// fragment-only maskDebug vec4 -- so the original fullscreen-triangle path's
// push data is identical to before; the trailing 32 bytes are vertex-only and
// meaningful only on the rotated-quad path):
//   vec4 uvTransform0;      // offset   0: row0 coefficients [cx, cy, 0, bias] for u
//   vec4 uvTransform1;      // offset  16: row1 coefficients [cx, cy, 0, bias] for v
//   vec4 colorMatrixRow0;   // offset  32: fragment-only
//   vec4 colorMatrixRow1;   // offset  48: fragment-only
//   vec4 colorMatrixRow2;   // offset  64: fragment-only
//   vec4 colorMatrixRow3;   // offset  80: fragment-only
//   vec4 colorMatrixOffset; // offset  96: fragment-only
//   vec4 maskDebug;         // offset 112: fragment-only x/y/z (debugMode, texelW, texelH);
//                           //             vertex-read w = useRotatedQuad (0.0 or 1.0)
//   vec4 rotatedQuad0;      // offset 128: vertex-only NDC corners 0,1 (x0,y0,x1,y1)
//   vec4 rotatedQuad1;      // offset 144: vertex-only NDC corners 2,3 (x2,y2,x3,y3)
// This vertex shader reads uvTransform0/uvTransform1 (both paths) and
// maskDebug.w / rotatedQuad0 / rotatedQuad1 (rotated-quad path only).
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
// The rotated-quad path's base UV corners are chosen so this same formula
// yields the identical raw-UV value at each of the 4 logical rect corners as
// the fullscreen-triangle path already does (see kQuadUvBase below).

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
    vec4 rotatedQuad0;
    vec4 rotatedQuad1;
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

// ANDROID-DUET-VULKAN-GREENSCREEN-FREE-TRANSFORM: rotated-quad path, active
// only when xf.maskDebug.w != 0.0 (a 6-vertex draw). rotatedQuad0/1 carry the
// 4 already-rotated NDC corners the CPU computed for the camera rect's
// corners in canvas-pixel space, in the SAME logical order the
// fullscreen-triangle path implies via barycentric interpolation of
// kPositions/kUvBase: corner 0 <-> NDC(-1,-1) <-> UV(0,0), corner 1 <->
// NDC(1,-1) <-> UV(1,0), corner 2 <-> NDC(-1,1) <-> UV(0,1), corner 3 <->
// NDC(1,1) <-> UV(1,1). kQuadCornerIndex maps 6 vertices (2 triangles,
// diagonal TR-BL split) onto those 4 corners; VK_CULL_MODE_NONE makes
// triangle winding irrelevant here.
const vec2 kQuadUvBase[4] = vec2[](
    vec2(0.0, 0.0),
    vec2(1.0, 0.0),
    vec2(0.0, 1.0),
    vec2(1.0, 1.0)
);
const int kQuadCornerIndex[6] = int[](0, 1, 2, 1, 3, 2);

void main() {
    vec2 pos;
    vec2 uv;
    if (xf.maskDebug.w != 0.0) {
        vec2 corners[4] = vec2[](
            xf.rotatedQuad0.xy,
            xf.rotatedQuad0.zw,
            xf.rotatedQuad1.xy,
            xf.rotatedQuad1.zw
        );
        int c = kQuadCornerIndex[gl_VertexIndex];
        pos = corners[c];
        uv  = kQuadUvBase[c];
    } else {
        pos = kPositions[gl_VertexIndex];
        uv  = kUvBase[gl_VertexIndex];
    }

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
