// gles_two_texture_compositor.h
// Phase 1 Unit AS: Private helper - GlesTwoTextureCompositor.
//
// Draws two already-imported textures composited into a single full-window
// quad via mix(colorA, colorB, weightB) on whichever EGL surface is current
// when drawCompositedQuad() is called. Owns only the temporary
// shader/program/VBO objects it creates for the draw call; never creates,
// binds outside the draw, or deletes either source texture. Does not call
// eglSwapBuffers or eglMakeCurrent -- the caller (GlesBackend) is
// responsible for surface/context currency and presentation.
//
// Private source: instantiated only by GlesBackend::Impl (gles_backend.cpp)
// and not exposed through the public gles_backend.h. EGL/GLES/Android
// headers must never appear in this header; the .cpp translation unit
// confines all such includes behind #if defined(__ANDROID__).
//
// Unit AS originally scoped this to two-texture GL_TEXTURE_2D composition
// only: both textureTargetA and textureTargetB had to be GL_TEXTURE_2D, with
// any other target (including GL_TEXTURE_EXTERNAL_OES or 0) failing closed
// with no GL draw. No timeline DAG integration, no transitions/PiP, no
// product UI.
//
// Unit AT: textureTargetA and textureTargetB may now independently be
// GL_TEXTURE_2D or GL_TEXTURE_EXTERNAL_OES, supporting all four target
// permutations (2D+2D, OES+2D, 2D+OES, OES+OES). Any other target value
// (including 0) still fails closed with no GL draw. No color-correct YUV
// conversion policy, timeline DAG integration, transitions/PiP, or product
// UI is claimed.

#pragma once
#include "vanguard/render/render_transform.h"

#include <cstdint>
#include <string>

namespace vanguard {
namespace render {

class GlesTwoTextureCompositor {
public:
    GlesTwoTextureCompositor();
    ~GlesTwoTextureCompositor();

    GlesTwoTextureCompositor(const GlesTwoTextureCompositor&) = delete;
    GlesTwoTextureCompositor& operator=(const GlesTwoTextureCompositor&) = delete;

    // Compiles/links a temporary minimal ES2 program sampling `textureA` on
    // texture unit 0 (uTextureA) and `textureB` on texture unit 1
    // (uTextureB), and draws a full-window triangle-strip quad via
    // glViewport(0, 0, width, height) with
    // gl_FragColor = mix(colorA, colorB, weightB), where each texture's UVs
    // are independently mapped through its own transform (see
    // makeVideoTransformPushConstants). The fragment shader's sampler types
    // are selected per texture's actual target (sampler2D for
    // GL_TEXTURE_2D, samplerExternalOES for GL_TEXTURE_EXTERNAL_OES, with
    // "#extension GL_OES_EGL_image_external : require" included whenever
    // either source is OES), so all four target permutations (2D+2D,
    // OES+2D, 2D+OES, OES+OES) are supported. Deletes every temporary
    // program/shader/VBO object it created before returning, on every path.
    // Never deletes textureA or textureB. Unbinds GL_ARRAY_BUFFER, the
    // program, and each texture's own actual target on texture units 0 and
    // 1 before returning on every path.
    //
    // textureA, textureB - non-zero GL texture names already bound to valid
    //                       image data under their respective
    //                       textureTargetA/textureTargetB, not owned by
    //                       this helper.
    // textureTargetA,
    // textureTargetB      - raw GLenum values; GL_TEXTURE_2D and
    //                       GL_TEXTURE_EXTERNAL_OES are each independently
    //                       accepted as of Unit AT. Any other value,
    //                       including 0/unknown, fails with
    //                       outError="gles_two_texture_compositor_unsupported_texture_target"
    //                       and performs no GL calls.
    // width, height       - target viewport dimensions; both must be > 0.
    // weightB             - mix() weight for textureB (0.0 = textureA only,
    //                       1.0 = textureB only). Must be finite; non-finite
    //                       values fail with
    //                       outError="gles_two_texture_compositor_invalid_weight"
    //                       and perform no GL calls. Finite values are
    //                       clamped into [0.0, 1.0] before use.
    // transformA, transformB - rotation/mirror applied independently to each
    //                       texture's sampled UVs; non-cardinal
    //                       rotationDegrees normalize to identity via
    //                       normalizeRotation().
    // outError             - non-null; set to "" on success or an ASCII
    //                       failure reason.
    //
    // Returns true only if shader compile/link, buffer upload, and the draw
    // itself all report GL_NO_ERROR. Returns false with
    // outError="gles_two_texture_compositor_unavailable_on_host" and no GL
    // calls on non-Android builds.
    bool drawCompositedQuad(uint32_t textureA,
                            uint32_t textureTargetA,
                            uint32_t textureB,
                            uint32_t textureTargetB,
                            uint32_t width,
                            uint32_t height,
                            float weightB,
                            const VideoFrameTransform& transformA,
                            const VideoFrameTransform& transformB,
                            std::string* outError);
};

} // namespace render
} // namespace vanguard
