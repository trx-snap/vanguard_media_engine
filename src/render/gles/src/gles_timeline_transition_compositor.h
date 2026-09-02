// gles_timeline_transition_compositor.h
// P5-COMPOSITOR-TRANS (sub-slice GLES-RENDER): Private helper -
// GlesTimelineTransitionCompositor.
//
// Draws two already-created textures ("from" clip layer and "to" clip layer)
// into the currently-current EGL surface according to a resolved timeline
// transition geometry: the blend weights, per-layer normalized viewports and
// per-layer normalized crops produced by the compositor-owned pure math in
// vanguard::compositors::ComputeTransitionGeometry() /
// EvaluateTimelineComposition() (see
// compositors/include/vanguard/compositors/vg_timeline_compositor_node.h).
//
// This helper is the GLES raster stage for compositor-owned clip overlap
// transitions. It is NOT a graph node and owns no timeline state: the
// composition root (a diagnostic JNI in this slice; VGTimelineCompositorNode
// integration later) evaluates the transition math and hands the resolved
// geometry across the GlesTimelineTransitionGeometry descriptor below. That
// descriptor mirrors vanguard::compositors::TimelineTransitionProgress
// field-for-field (minus the family enum) so vanguard_render_gles keeps its
// existing dependency direction: it never includes a compositors/graph
// header, exactly like GlesMultiCamSpatialCompositor.
//
// Draw model (derived purely from the descriptor, never from a family enum):
//   * blendWeightTo <= 0            -> "from" layer only, opaque, at its
//                                      geometry (kNone / hard cut, crossfade
//                                      progress 0).
//   * blendWeightFrom <= 0          -> "to" layer only, opaque, at its
//                                      geometry (crossfade progress 1).
//   * both weights >= 1             -> layered opaque paint-over: "from" at
//                                      its geometry, then "to" at its
//                                      geometry (slide / wipe families).
//   * otherwise                     -> single full-canvas mix(from, to,
//                                      blendWeightTo) draw (crossfade); both
//                                      viewports must be identity.
// Each opaque layer draw places crop-rect(layer) x viewport-rect(layer) onto
// the canvas, clips the result to the canvas, advances the sampled UV range
// by the clipped fraction, and draws a textured quad scoped by glViewport to
// the resulting bottom-left pixel rectangle. A layer whose visible region
// rounds to zero pixels is skipped (not an error). GL_BLEND is never enabled.
//
// Coordinate conventions: viewport/crop rects are top-left-origin, Y-down
// normalized canvas rects (the compositor convention). They are mapped to GL
// texture coordinates with V flipped, so crop.y == 0 selects the visually top
// row of a GL-convention texture (texel row 0 at the bottom). No
// SurfaceTexture transform matrix is applied; OES stream orientation policy
// remains out of scope for this slice.
//
// Ownership / lifecycle non-claims (mirroring GlesTwoTextureCompositor and
// GlesMultiCamSpatialCompositor): owns only the temporary shader/program/VBO
// objects it creates per draw call and deletes them on every path; never
// creates, binds outside the draw, or deletes either source texture; never
// calls eglMakeCurrent / eglSwapBuffers; never clears the framebuffer; owns
// no Surface/SurfaceTexture/MediaCodec/decoder. Always restores
// glViewport(0, 0, surfaceWidth, surfaceHeight) and unbinds the program,
// GL_ARRAY_BUFFER, and texture units 0/1 before returning after any GL call.
//
// Texture targets: GL_TEXTURE_2D and GL_TEXTURE_EXTERNAL_OES are each
// independently accepted structurally for textureTargetFrom/textureTargetTo
// with sampler variants selected per permutation; any other target (including
// 0) fails closed before any GL call. This slice's physical proof exercises
// GL_TEXTURE_2D content and the OES sampler compile route only; no
// SurfaceTexture/decoder OES frame proof, no Vulkan, no decode, no export.
//
// Private source: EGL/GLES/Android headers must never appear in this header;
// the .cpp translation unit confines all such includes behind
// #if defined(__ANDROID__) and compiles to a safe unavailable stub elsewhere.

#pragma once

#include <cstdint>
#include <string>

namespace vanguard {
namespace render {

// Top-left-origin, Y-down normalized canvas rectangle. Viewport rects may lie
// outside [0,1] on x/y (off-canvas slide motion); crop rects must lie inside
// [0,1]. Mirrors vanguard::compositors::TimelineNormalizedRect without
// including that header.
struct GlesTimelineNormalizedRect {
    double x      = 0.0;
    double y      = 0.0;
    double width  = 1.0;
    double height = 1.0;
};

// Resolved transition geometry at one timeline instant. Mirrors
// vanguard::compositors::TimelineTransitionProgress minus the family enum.
// Defaults describe an inactive transition (from-only, identity geometry).
struct GlesTimelineTransitionGeometry {
    double progress        = 0.0;
    double blendWeightFrom = 1.0;
    double blendWeightTo   = 0.0;
    GlesTimelineNormalizedRect fromViewport;
    GlesTimelineNormalizedRect toViewport;
    GlesTimelineNormalizedRect fromCrop;
    GlesTimelineNormalizedRect toCrop;
};

// Bottom-left-origin pixel placement plus GL-convention UV range resolved for
// one layer. `visible == false` means the layer has no on-canvas pixels.
struct GlesTimelineLayerPlacement {
    bool     visible      = false;
    int32_t  xPx          = 0;
    int32_t  yBottomPx    = 0;
    uint32_t widthPx      = 0;
    uint32_t heightPx     = 0;
    // GL texture coordinates (V already flipped: vTop >= vBottom).
    float    u0           = 0.0f;
    float    u1           = 1.0f;
    float    vBottom      = 0.0f;
    float    vTop         = 1.0f;
};

// Pure, platform-independent placement math (no GL calls): maps
// crop x viewport onto a surfaceWidth x surfaceHeight canvas, clips to the
// canvas, and advances the UV range by the clipped fraction. Callers must
// have validated finiteness; non-finite inputs yield visible == false.
GlesTimelineLayerPlacement ResolveTimelineLayerPlacement(
    const GlesTimelineNormalizedRect& viewport,
    const GlesTimelineNormalizedRect& crop,
    uint32_t surfaceWidth,
    uint32_t surfaceHeight);

class GlesTimelineTransitionCompositor {
public:
    GlesTimelineTransitionCompositor();
    ~GlesTimelineTransitionCompositor();

    GlesTimelineTransitionCompositor(const GlesTimelineTransitionCompositor&) = delete;
    GlesTimelineTransitionCompositor& operator=(const GlesTimelineTransitionCompositor&) = delete;

    // Draws the resolved transition into the currently-current EGL surface
    // (see the draw model in the file header).
    //
    // textureFrom, textureTo   - non-zero GL texture names already holding
    //                            valid image data under their respective
    //                            targets; not owned by this helper. Both must
    //                            be non-zero even when a weight makes one
    //                            layer invisible.
    // textureTargetFrom,
    // textureTargetTo          - raw GLenum values; GL_TEXTURE_2D and
    //                            GL_TEXTURE_EXTERNAL_OES are independently
    //                            accepted. Any other value (including 0)
    //                            fails with
    //                            outError="gles_timeline_transition_compositor_unsupported_texture_target"
    //                            and performs no GL calls.
    // surfaceWidth,
    // surfaceHeight            - dimensions of the current EGL surface; both
    //                            must be > 0 (else
    //                            "gles_timeline_transition_compositor_invalid_argument").
    // geometry                 - resolved transition geometry. progress must
    //                            be finite ("..._invalid_progress"), both
    //                            weights finite ("..._invalid_blend_weight";
    //                            finite values are clamped into [0,1]), every
    //                            rect field finite with non-negative extents,
    //                            and both crops inside [0,1]
    //                            ("..._invalid_geometry"). A mix draw with a
    //                            non-identity viewport fails with
    //                            "..._unsupported_geometry". All validation
    //                            runs before any GL call.
    // outError                 - non-null; set to "" on success or an ASCII
    //                            failure reason.
    //
    // Returns true only if every issued shader compile/link, buffer upload,
    // and draw reports GL_NO_ERROR. Returns false with
    // outError="gles_timeline_transition_compositor_unavailable_on_host" and
    // no GL calls on non-Android builds.
    bool drawTransition(uint32_t textureFrom,
                        uint32_t textureTargetFrom,
                        uint32_t textureTo,
                        uint32_t textureTargetTo,
                        uint32_t surfaceWidth,
                        uint32_t surfaceHeight,
                        const GlesTimelineTransitionGeometry& geometry,
                        std::string* outError);
};

} // namespace render
} // namespace vanguard
