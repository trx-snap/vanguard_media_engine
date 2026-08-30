// render_transform.h
// Vanguard Android True-DAG Phase 4B2C: playback rotation spatial transform.
//
// Shared, platform-neutral header. Must not include Android, Vulkan, JNI, or
// any other platform-specific headers. C++17 only.
//
// UV mapping convention (fragment shader: uv = row * vec4(x, y, 0, 1)):
//   0   deg: u = x,       v = y
//   90  deg CW: u = y,    v = 1 - x
//   180 deg: u = 1 - x,   v = 1 - y
//   270 deg CW: u = 1 - y, v = x

#pragma once
#include <cstdint>

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// RenderDestinationRect
// ---------------------------------------------------------------------------
// Aspect-preserving-fit destination sub-rect within a backend's fixed output
// surface extent, in output pixel coordinates. All-zero (x=0, y=0, width=0,
// height=0 -- the default) means "no destination rect": the backend renders
// to its full output extent, matching pre-existing behavior. A non-default
// rect must have width > 0 and height > 0 and lie fully within the output
// extent; validating that is the caller/backend's responsibility, not this
// header's.
struct RenderDestinationRect {
    int32_t x = 0;
    int32_t y = 0;
    int32_t width = 0;
    int32_t height = 0;

    bool isDefault() const {
        return x == 0 && y == 0 && width == 0 && height == 0;
    }
};

// ---------------------------------------------------------------------------
// VideoFrameTransform
// ---------------------------------------------------------------------------

struct VideoFrameTransform {
    // Cardinal clockwise rotation of the recorded video content.
    // Valid values: 0, 90, 180, 270. All other values are treated as 0.
    uint32_t rotationDegrees = 0;
    bool mirrorHorizontal = false;

    // Normalized decoder-buffer crop, applied after the rotation/mirror
    // mapping below. Identity defaults (1,1,0,0) leave rotation/mirror-only
    // callers unaffected. Caller is responsible for clamping these to a
    // valid [0,1] crop rect; this header performs no validation.
    float cropScaleU = 1.0f;
    float cropScaleV = 1.0f;
    float cropBiasU = 0.0f;
    float cropBiasV = 0.0f;

    // Aspect-preserving-fit destination sub-rect within the backend's fixed
    // output extent. Default (RenderDestinationRect{}) means the full output
    // extent, matching pre-existing behavior.
    RenderDestinationRect destinationRect{};

    // Phase 10: optional per-frame color matrix (Vulkan-native colorMatrix
    // parity with GLES/Flutter ColorFilter.matrix). When false (the
    // default), rendering uses the identity color matrix. Row-major 4x4 plus
    // an additive per-channel offset, matching the same 4x5 layout as
    // AndroidTimelineVideoEncoder's GLES uColorMatrixRow0..3/uColorMatrixOffset
    // uniforms: rows are already the [R,G,B,A] weights for the corresponding
    // output channel; [colorMatrixOffset] entries are already normalized into
    // [0,1] (i.e. raw/255.0), matching that same GLES upload convention --
    // this header performs no further normalization.
    bool colorMatrixEnabled = false;
    float colorMatrixRow0[4] = {1.0f, 0.0f, 0.0f, 0.0f};
    float colorMatrixRow1[4] = {0.0f, 1.0f, 0.0f, 0.0f};
    float colorMatrixRow2[4] = {0.0f, 0.0f, 1.0f, 0.0f};
    float colorMatrixRow3[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    float colorMatrixOffset[4] = {0.0f, 0.0f, 0.0f, 0.0f};
};

// ---------------------------------------------------------------------------
// VideoTransformPushConstants
// ---------------------------------------------------------------------------
// Packed as two float[4] rows of a 2x4 matrix that maps NDC vertex coords
// (x, y) plus constants to UV. Fragment shader evaluates:
//   uv.u = dot(uvTransform0, vec4(x, y, 0.0, 1.0))
//   uv.v = dot(uvTransform1, vec4(x, y, 0.0, 1.0))
//
// Must be 32 bytes total, 16-byte aligned (satisfies
// VkPushConstantRange offset+size alignment requirements).

struct alignas(16) VideoTransformPushConstants {
    float uvTransform0[4];  // coefficients for u: [cx, cy, 0, bias]
    float uvTransform1[4];  // coefficients for v: [cx, cy, 0, bias]
};

static_assert(sizeof(VideoTransformPushConstants) == 32,
              "VideoTransformPushConstants must be exactly 32 bytes");
static_assert(alignof(VideoTransformPushConstants) == 16,
              "VideoTransformPushConstants must be 16-byte aligned");

// ---------------------------------------------------------------------------
// VideoColorMatrixPushConstants / VideoTransformFullPushConstants
// ---------------------------------------------------------------------------
// Phase 10: Vulkan-native colorMatrix parity push constants, appended after
// VideoTransformPushConstants in a single combined push-constant block shared
// by the vertex (UV only) and fragment (color matrix) stages. GLSL push
// constant offsets (both stages must declare an identical 7-vec4 block):
//   uv.uvTransform0    @  0
//   uv.uvTransform1    @ 16
//   color.row0         @ 32
//   color.row1         @ 48
//   color.row2         @ 64
//   color.row3         @ 80
//   color.offset       @ 96
//
// rgba' = clamp(vec4(dot(row0, rgba) + offset.r,
//                     dot(row1, rgba) + offset.g,
//                     dot(row2, rgba) + offset.b,
//                     dot(row3, rgba) + offset.a), 0.0, 1.0)
// -- matching GLES/Flutter ColorFilter.matrix semantics exactly.

struct alignas(16) VideoColorMatrixPushConstants {
    float row0[4];
    float row1[4];
    float row2[4];
    float row3[4];
    float offset[4];
};

static_assert(sizeof(VideoColorMatrixPushConstants) == 80,
              "VideoColorMatrixPushConstants must be exactly 80 bytes");
static_assert(alignof(VideoColorMatrixPushConstants) == 16,
              "VideoColorMatrixPushConstants must be 16-byte aligned");

struct alignas(16) VideoTransformFullPushConstants {
    VideoTransformPushConstants uv;
    VideoColorMatrixPushConstants color;
};

static_assert(sizeof(VideoTransformFullPushConstants) == 112,
              "VideoTransformFullPushConstants must be exactly 112 bytes");
static_assert(alignof(VideoTransformFullPushConstants) == 16,
              "VideoTransformFullPushConstants must be 16-byte aligned");
static_assert(sizeof(VideoTransformFullPushConstants) <= 128,
              "VideoTransformFullPushConstants must fit the guaranteed minimum "
              "Vulkan push constant budget (128 bytes)");

// ---------------------------------------------------------------------------
// normalizeRotation
// Maps any integer degrees to a cardinal 0/90/180/270 value.
// Non-cardinal input returns 0 (identity).
// ---------------------------------------------------------------------------

inline uint32_t normalizeRotation(uint32_t degrees) {
    degrees = degrees % 360u;
    switch (degrees) {
        case 0:   return 0u;
        case 90:  return 90u;
        case 180: return 180u;
        case 270: return 270u;
        default:  return 0u;
    }
}

// ---------------------------------------------------------------------------
// makeVideoTransformPushConstants
// Builds the push constants for the given cardinal rotation and horizontal mirror.
// ---------------------------------------------------------------------------

inline VideoTransformPushConstants makeVideoTransformPushConstants(
    const VideoFrameTransform& transform)
{
    VideoTransformPushConstants pc{};
    const uint32_t rot = normalizeRotation(transform.rotationDegrees);

    if (transform.mirrorHorizontal) {
        // Mirrored cases use display-space horizontal mirror before rotation:
        // rot0:   u = 1 - x, v = y   => [-1, 0, 0, 1], [ 0,  1, 0, 0]
        // rot90:  u = y,     v = x   => [ 0, 1, 0, 0], [ 1,  0, 0, 0]
        // rot180: u = x,     v = 1-y => [ 1, 0, 0, 0], [ 0, -1, 0, 1]
        // rot270: u = 1 - y, v = 1-x => [ 0, -1, 0, 1], [-1,  0, 0, 1]
        switch (rot) {
            case 90:
                // u = y    -> [0, 1, 0, 0]
                // v = x    -> [1, 0, 0, 0]
                pc.uvTransform0[0] =  0.0f; pc.uvTransform0[1] =  1.0f;
                pc.uvTransform0[2] =  0.0f; pc.uvTransform0[3] =  0.0f;
                pc.uvTransform1[0] =  1.0f; pc.uvTransform1[1] =  0.0f;
                pc.uvTransform1[2] =  0.0f; pc.uvTransform1[3] =  0.0f;
                break;
            case 180:
                // u = x    -> [1,  0, 0, 0]
                // v = 1-y  -> [0, -1, 0, 1]
                pc.uvTransform0[0] =  1.0f; pc.uvTransform0[1] =  0.0f;
                pc.uvTransform0[2] =  0.0f; pc.uvTransform0[3] =  0.0f;
                pc.uvTransform1[0] =  0.0f; pc.uvTransform1[1] = -1.0f;
                pc.uvTransform1[2] =  0.0f; pc.uvTransform1[3] =  1.0f;
                break;
            case 270:
                // u = 1-y  -> [ 0, -1, 0, 1]
                // v = 1-x  -> [-1,  0, 0, 1]
                pc.uvTransform0[0] =  0.0f; pc.uvTransform0[1] = -1.0f;
                pc.uvTransform0[2] =  0.0f; pc.uvTransform0[3] =  1.0f;
                pc.uvTransform1[0] = -1.0f; pc.uvTransform1[1] =  0.0f;
                pc.uvTransform1[2] =  0.0f; pc.uvTransform1[3] =  1.0f;
                break;
            default: // 0 deg mirrored
                // u = 1-x  -> [-1, 0, 0, 1]
                // v = y    -> [ 0, 1, 0, 0]
                pc.uvTransform0[0] = -1.0f; pc.uvTransform0[1] =  0.0f;
                pc.uvTransform0[2] =  0.0f; pc.uvTransform0[3] =  1.0f;
                pc.uvTransform1[0] =  0.0f; pc.uvTransform1[1] =  1.0f;
                pc.uvTransform1[2] =  0.0f; pc.uvTransform1[3] =  0.0f;
                break;
        }
    } else {
        // Rotation      u formula         v formula
        // 0 deg      u = x            v = y
        // 90 CW      u = y            v = 1 - x
        // 180        u = 1 - x        v = 1 - y
        // 270 CW     u = 1 - y        v = x

        switch (rot) {
            case 90:
                // u = y    -> [0, 1, 0, 0]
                // v = 1-x  -> [-1, 0, 0, 1]
                pc.uvTransform0[0] =  0.0f; pc.uvTransform0[1] =  1.0f;
                pc.uvTransform0[2] =  0.0f; pc.uvTransform0[3] =  0.0f;
                pc.uvTransform1[0] = -1.0f; pc.uvTransform1[1] =  0.0f;
                pc.uvTransform1[2] =  0.0f; pc.uvTransform1[3] =  1.0f;
                break;
            case 180:
                // u = 1-x  -> [-1, 0, 0, 1]
                // v = 1-y  -> [0, -1, 0, 1]
                pc.uvTransform0[0] = -1.0f; pc.uvTransform0[1] =  0.0f;
                pc.uvTransform0[2] =  0.0f; pc.uvTransform0[3] =  1.0f;
                pc.uvTransform1[0] =  0.0f; pc.uvTransform1[1] = -1.0f;
                pc.uvTransform1[2] =  0.0f; pc.uvTransform1[3] =  1.0f;
                break;
            case 270:
                // u = 1-y  -> [0, -1, 0, 1]
                // v = x    -> [1,  0, 0, 0]
                pc.uvTransform0[0] =  0.0f; pc.uvTransform0[1] = -1.0f;
                pc.uvTransform0[2] =  0.0f; pc.uvTransform0[3] =  1.0f;
                pc.uvTransform1[0] =  1.0f; pc.uvTransform1[1] =  0.0f;
                pc.uvTransform1[2] =  0.0f; pc.uvTransform1[3] =  0.0f;
                break;
            default: // 0 deg identity
                // u = x    -> [1, 0, 0, 0]
                // v = y    -> [0, 1, 0, 0]
                pc.uvTransform0[0] =  1.0f; pc.uvTransform0[1] =  0.0f;
                pc.uvTransform0[2] =  0.0f; pc.uvTransform0[3] =  0.0f;
                pc.uvTransform1[0] =  0.0f; pc.uvTransform1[1] =  1.0f;
                pc.uvTransform1[2] =  0.0f; pc.uvTransform1[3] =  0.0f;
                break;
        }
    }

    // Compose crop after the rotation/mirror mapping above: final row
    // coefficients are the crop scale multiplied into the existing row
    // coefficients, final bias is cropBias + cropScale * existingBias.
    pc.uvTransform0[0] *= transform.cropScaleU;
    pc.uvTransform0[1] *= transform.cropScaleU;
    pc.uvTransform0[3] = transform.cropBiasU + transform.cropScaleU * pc.uvTransform0[3];

    pc.uvTransform1[0] *= transform.cropScaleV;
    pc.uvTransform1[1] *= transform.cropScaleV;
    pc.uvTransform1[3] = transform.cropBiasV + transform.cropScaleV * pc.uvTransform1[3];

    return pc;
}

// ---------------------------------------------------------------------------
// makeVideoTransformFullPushConstants
// Builds the combined UV-transform + color-matrix push constants. The color
// matrix is the identity (matching [VideoFrameTransform]'s own defaults) when
// [VideoFrameTransform::colorMatrixEnabled] is false.
// ---------------------------------------------------------------------------

inline VideoTransformFullPushConstants makeVideoTransformFullPushConstants(
    const VideoFrameTransform& transform)
{
    VideoTransformFullPushConstants full{};
    full.uv = makeVideoTransformPushConstants(transform);

    if (transform.colorMatrixEnabled) {
        for (int i = 0; i < 4; ++i) {
            full.color.row0[i] = transform.colorMatrixRow0[i];
            full.color.row1[i] = transform.colorMatrixRow1[i];
            full.color.row2[i] = transform.colorMatrixRow2[i];
            full.color.row3[i] = transform.colorMatrixRow3[i];
            full.color.offset[i] = transform.colorMatrixOffset[i];
        }
    } else {
        full.color.row0[0] = 1.0f; full.color.row0[1] = 0.0f; full.color.row0[2] = 0.0f; full.color.row0[3] = 0.0f;
        full.color.row1[0] = 0.0f; full.color.row1[1] = 1.0f; full.color.row1[2] = 0.0f; full.color.row1[3] = 0.0f;
        full.color.row2[0] = 0.0f; full.color.row2[1] = 0.0f; full.color.row2[2] = 1.0f; full.color.row2[3] = 0.0f;
        full.color.row3[0] = 0.0f; full.color.row3[1] = 0.0f; full.color.row3[2] = 0.0f; full.color.row3[3] = 1.0f;
        full.color.offset[0] = 0.0f; full.color.offset[1] = 0.0f; full.color.offset[2] = 0.0f; full.color.offset[3] = 0.0f;
    }

    return full;
}

} // namespace render
} // namespace vanguard
