// gles_texture_frame_renderer.h
// Phase 1 Unit Z: Private helper - GlesTextureFrameRenderer.
//
// Draws an already-imported GL_TEXTURE_2D as a full-window textured quad on
// whichever EGL surface is current when drawTexturedQuad() is called. Owns
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
// Unit Z scope: identity textured-quad draw only. No orientation/rotation
// correction, no mirroring, no YUV/external-texture sampling.

#pragma once
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
    // binds `texture` (an existing GL_TEXTURE_2D name, not owned by this
    // helper) on texture unit 0, and draws a full-window triangle-strip quad
    // via glViewport(0, 0, width, height). Deletes every temporary
    // program/shader/VBO object it created before returning, on every path.
    // Never deletes `texture`.
    //
    // texture  - non-zero GL_TEXTURE_2D name already bound to valid image data.
    // width, height - target viewport dimensions; both must be > 0.
    // outError - non-null; set to "" on success or an ASCII failure reason.
    //
    // Returns true only if shader compile/link, buffer upload, and the draw
    // itself all report GL_NO_ERROR. Returns false with
    // outError="gles_texture_frame_renderer_unavailable_on_host" and no GL
    // calls on non-Android builds.
    bool drawTexturedQuad(uint32_t texture,
                          uint32_t width,
                          uint32_t height,
                          std::string* outError);
};

} // namespace render
} // namespace vanguard
