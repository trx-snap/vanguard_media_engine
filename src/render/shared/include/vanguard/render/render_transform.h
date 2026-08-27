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
// VideoFrameTransform
// ---------------------------------------------------------------------------

struct VideoFrameTransform {
    // Cardinal clockwise rotation of the recorded video content.
    // Valid values: 0, 90, 180, 270. All other values are treated as 0.
    uint32_t rotationDegrees = 0;
    bool mirrorHorizontal = false;
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
    return pc;
}

} // namespace render
} // namespace vanguard
