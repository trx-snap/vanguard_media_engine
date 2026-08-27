// gles_texture_frame_renderer.h
// Phase 1 Unit Z/AA: Private helper - GlesTextureFrameRenderer.
//
// Draws an already-imported GL_TEXTURE_2D or GL_TEXTURE_EXTERNAL_OES texture
// as a full-window textured quad on whichever EGL surface is current when
// drawTexturedQuad() is called. Owns
// only the temporary shader/program/VBO objects it creates for the draw
// call; never creates, binds outside the draw, or deletes the source
// texture. Does not call eglSwapBuffers or eglMakeCurrent -- the caller
// (GlesBackend::renderFrame) is responsible for surface/context currency and
// presentation.
//
// Private source: instantiated only by GlesBackend::Impl (gles_backend.cpp)
// and not exposed through the public gles_backend.h. EGL/GLES/Android
// headers must never appear in this header; the .cpp translation unit
// confines all such includes behind #if defined(__ANDROID__).
//
// Unit AA scope: supports rotationDegrees 0/90/180/270 plus mirrorHorizontal
// via the shared UV-mapping helper (VideoFrameTransform /
// makeVideoTransformPushConstants). No pixel readback/content proof, no
// fence sync, no product wiring.
//
// Unit AR adds a texture-target-aware drawTexturedQuad() overload: passing
// GL_TEXTURE_EXTERNAL_OES selects a fragment shader sampling with
// samplerExternalOES (GL_OES_EGL_image_external), for the
// GlesHardwareBufferImports YUV/implementation-defined import foundation.
// This does not claim color-correct YUV->RGB conversion, Camera2 product
// wiring, or multi-node DAG composition.

#pragma once
#include "vanguard/render/render_transform.h"

#include <cstdint>
#include <string>

namespace vanguard {
namespace render {

class GlesTextureFrameRenderer {
public:
    GlesTextureFrameRenderer();
    ~GlesTextureFrameRenderer();

    GlesTextureFrameRenderer(const GlesTextureFrameRenderer&) = delete;
    GlesTextureFrameRenderer& operator=(const GlesTextureFrameRenderer&) = delete;

    // Compiles/links a temporary minimal ES2 textured-quad shader program,
    // binds `texture` on texture unit 0 against `textureTarget`, and draws a
    // full-window triangle-strip quad via glViewport(0, 0, width, height),
    // sampling with UVs mapped through `transform` (see
    // makeVideoTransformPushConstants). Deletes every temporary
    // program/shader/VBO object it created before returning, on every path.
    // Never deletes `texture`.
    //
    // texture       - non-zero GL texture name already bound to valid image
    //                 data under `textureTarget`, not owned by this helper.
    // textureTarget - raw GLenum value; only GL_TEXTURE_2D (samples via
    //                 sampler2D) and GL_TEXTURE_EXTERNAL_OES (samples via
    //                 samplerExternalOES, requiring
    //                 "#extension GL_OES_EGL_image_external : require") are
    //                 accepted. Any other value, including 0/unknown, fails
    //                 with outError="gles_texture_frame_renderer_invalid_texture_target"
    //                 and performs no GL calls.
    // width, height - target viewport dimensions; both must be > 0.
    // transform - rotation/mirror applied to the sampled UVs; non-cardinal
    //             rotationDegrees normalize to identity via normalizeRotation().
    // outError - non-null; set to "" on success or an ASCII failure reason.
    //
    // Returns true only if shader compile/link, buffer upload, and the draw
    // itself all report GL_NO_ERROR. Returns false with
    // outError="gles_texture_frame_renderer_unavailable_on_host" and no GL
    // calls on non-Android builds.
    bool drawTexturedQuad(uint32_t texture,
                          uint32_t textureTarget,
                          uint32_t width,
                          uint32_t height,
                          const VideoFrameTransform& transform,
                          std::string* outError);

    // Convenience overload preserved for existing callers: delegates to the
    // texture-target overload above with textureTarget=GL_TEXTURE_2D.
    bool drawTexturedQuad(uint32_t texture,
                          uint32_t width,
                          uint32_t height,
                          const VideoFrameTransform& transform,
                          std::string* outError);

    // Convenience wrapper delegating to the transform overload with the
    // default identity VideoFrameTransform{} and GL_TEXTURE_2D.
    bool drawTexturedQuad(uint32_t texture,
                          uint32_t width,
                          uint32_t height,
                          std::string* outError);
};

} // namespace render
} // namespace vanguard
