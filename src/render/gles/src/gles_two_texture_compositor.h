// gles_two_texture_compositor.h
// Phase 1 Unit AS: Private helper - GlesTwoTextureCompositor.
//
// Draws two already-imported GL_TEXTURE_2D textures composited into a
// single full-window quad via mix(colorA, colorB, weightB) on whichever EGL
// surface is current when drawCompositedQuad() is called. Owns only the
// temporary shader/program/VBO objects it creates for the draw call; never
// creates, binds outside the draw, or deletes either source texture. Does
// not call eglSwapBuffers or eglMakeCurrent -- the caller (GlesBackend) is
// responsible for surface/context currency and presentation.
//
// Private source: instantiated only by GlesBackend::Impl (gles_backend.cpp)
// and not exposed through the public gles_backend.h. EGL/GLES/Android
// headers must never appear in this header; the .cpp translation unit
// confines all such includes behind #if defined(__ANDROID__).
//
// Unit AS scope: two-texture GL_TEXTURE_2D composition foundation only.
// Both textureTargetA and textureTargetB must be GL_TEXTURE_2D; any other
// target (including GL_TEXTURE_EXTERNAL_OES or 0) fails closed with no GL
// draw. No external/OES mixed composition, no timeline DAG integration, no
// transitions/PiP, no product UI.

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
    // texture unit 0 (sampler2D uTextureA) and `textureB` on texture unit 1
    // (sampler2D uTextureB), and draws a full-window triangle-strip quad via
    // glViewport(0, 0, width, height) with
    // gl_FragColor = mix(colorA, colorB, weightB), where each texture's UVs
    // are independently mapped through its own transform (see
    // makeVideoTransformPushConstants). Deletes every temporary
    // program/shader/VBO object it created before returning, on every path.
    // Never deletes textureA or textureB. Unbinds GL_ARRAY_BUFFER, the
    // program, and GL_TEXTURE_2D on texture units 0 and 1 before returning
    // on every path.
    //
    // textureA, textureB - non-zero GL texture names already bound to valid
    //                       image data under GL_TEXTURE_2D, not owned by
    //                       this helper.
    // textureTargetA,
    // textureTargetB      - raw GLenum values; only GL_TEXTURE_2D is
    //                       accepted for Unit AS. Any other value, including
    //                       0/GL_TEXTURE_EXTERNAL_OES/unknown, fails with
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
