// gles_multicam_spatial_compositor.h
// P3-MULTICAM-NODE: Private helper - GlesMultiCamSpatialCompositor.
//
// Draws two already-imported textures into two independent viewport-sized
// rectangles of the currently-current EGL surface: an opaque single-texture
// draw of textureA scoped to rectA via glViewport, followed by an opaque
// single-texture draw of textureB scoped to rectB via glViewport. Unlike
// GlesTwoTextureCompositor, this performs no mix()/weight/opacity blending --
// each draw is a full-opacity textured quad clipped to its own rectangle by
// glViewport alone. Owns only the temporary shader/program/VBO objects it
// creates for each draw call; never creates, binds outside the draw, or
// deletes either source texture. Does not call eglSwapBuffers or
// eglMakeCurrent, and does not clear the framebuffer -- the caller
// (GlesBackend) is responsible for surface/context currency, the opaque
// green sentinel clear, and presentation.
//
// Private source: instantiated only by GlesBackend::Impl (gles_backend.cpp)
// and not exposed through the public gles_backend.h. EGL/GLES/Android
// headers must never appear in this header; the .cpp translation unit
// confines all such includes behind #if defined(__ANDROID__).
//
// Scope: GL_TEXTURE_2D and GL_TEXTURE_EXTERNAL_OES are each independently
// accepted structurally for textureTargetA/textureTargetB (any other value,
// including 0, fails closed with no GL draw); this slice's physical proof
// exercises GL_TEXTURE_2D only. No color-correct YUV conversion policy, no
// camera ingest, no Vulkan, no recording/export, no product UI, no corner
// radius, no secondary opacity -- every caller passes opacity 1.0/identity
// crops by construction.
//
// glViewport(0, 0, surfaceWidth, surfaceHeight) is restored on every return
// path of drawSpatialComposite(), including every failure path, so a caller
// that reuses the same EGL surface afterward (e.g. GlesTextureFrameRenderer,
// or a subsequent diagnosticPresentWindowClear()) is never left with a
// stale sub-rect viewport.

#pragma once
#include "vanguard/render/render_transform.h"

#include <cstdint>
#include <string>

namespace vanguard {
namespace render {

// Bottom-left-origin pixel viewport rectangle, mirroring the public
// GlesViewportRectPx (vanguard/render/gles_backend.h) field-for-field
// without including that public header, matching the dependency style of
// this helper's siblings (GlesTextureFrameRenderer, GlesTwoTextureCompositor)
// which also take raw primitives rather than backend types.
struct GlesSpatialViewportRectPx {
    int32_t x;
    int32_t yBottom;
    uint32_t width;
    uint32_t height;
};

class GlesMultiCamSpatialCompositor {
public:
    GlesMultiCamSpatialCompositor();
    ~GlesMultiCamSpatialCompositor();

    GlesMultiCamSpatialCompositor(const GlesMultiCamSpatialCompositor&) = delete;
    GlesMultiCamSpatialCompositor& operator=(const GlesMultiCamSpatialCompositor&) = delete;

    // Draws textureA as a full-opacity textured quad scoped to rectA via
    // glViewport(rectA.x, rectA.yBottom, rectA.width, rectA.height), then
    // draws textureB the same way scoped to rectB. Each texture's UVs are
    // independently mapped through its own transform (see
    // makeVideoTransformPushConstants). Deletes every temporary
    // program/shader/VBO object it created before returning, on every path.
    // Never deletes textureA or textureB. Always restores
    // glViewport(0, 0, surfaceWidth, surfaceHeight) before returning, on
    // every path (success or failure).
    //
    // textureA, textureB - non-zero GL texture names already bound to valid
    //                       image data under their respective
    //                       textureTargetA/textureTargetB, not owned by
    //                       this helper.
    // textureTargetA,
    // textureTargetB      - raw GLenum values; GL_TEXTURE_2D and
    //                       GL_TEXTURE_EXTERNAL_OES are each independently
    //                       accepted. Any other value, including
    //                       0/unknown, fails with
    //                       outError="gles_multicam_spatial_compositor_unsupported_texture_target"
    //                       and performs no GL draw calls.
    // surfaceWidth,
    // surfaceHeight       - dimensions of the currently-current EGL surface,
    //                       used only to restore the full-surface viewport
    //                       on return; both must be > 0.
    // rectA, rectB        - bottom-left-origin pixel viewport rectangles;
    //                       both width and height must be > 0, x/yBottom
    //                       must be >= 0, and x+width/yBottom+height must
    //                       not exceed surfaceWidth/surfaceHeight. Any
    //                       violation fails closed with
    //                       outError="gles_multicam_spatial_compositor_invalid_rect"
    //                       and performs no GL draw calls.
    // transformA, transformB - rotation/mirror/crop applied independently to
    //                       each texture's sampled UVs; non-cardinal
    //                       rotationDegrees normalize to identity via
    //                       normalizeRotation(). Callers construct these as
    //                       identity for this slice's opacity/crop
    //                       non-claims.
    // outError             - non-null; set to "" on success or an ASCII
    //                       failure reason.
    //
    // Returns true only if both draws report GL_NO_ERROR. Returns false
    // with outError="gles_multicam_spatial_compositor_unavailable_on_host"
    // and no GL calls on non-Android builds.
    bool drawSpatialComposite(uint32_t textureA,
                              uint32_t textureTargetA,
                              uint32_t textureB,
                              uint32_t textureTargetB,
                              uint32_t surfaceWidth,
                              uint32_t surfaceHeight,
                              const GlesSpatialViewportRectPx& rectA,
                              const GlesSpatialViewportRectPx& rectB,
                              const VideoFrameTransform& transformA,
                              const VideoFrameTransform& transformB,
                              std::string* outError);
};

} // namespace render
} // namespace vanguard
