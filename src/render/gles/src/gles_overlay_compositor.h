// gles_overlay_compositor.h
// P5-OVERLAYS-TRANS (sub-slice GLES-RENDER): Private helper -
// GlesOverlayCompositor.
//
// Draws an ordered list of already-created overlay textures (text / emoji /
// sticker rasters owned by the caller) on top of whatever is already in the
// currently-current EGL surface, one Porter-Duff source-over pass per layer.
// Each layer is placed by an evaluated spatial transform (top-left canvas
// pixel position, size, uniform scale, rotation about the layer centre,
// opacity) that mirrors the raster fields of the pure-Dart
// VGOverlayEvaluatedTransform produced by the verified
// P5-OVERLAYS-KEYFRAME-INTERP sub-slice (lib/src/overlay/vg_overlay_keyframe.dart).
//
// This helper is the GLES raster stage for compositor-owned overlay layers.
// It is NOT a graph node and owns no timeline or keyframe state: the
// composition root (a diagnostic JNI in this slice; VGTimelineCompositorNode /
// export integration later) evaluates the keyframe math elsewhere and hands
// already-resolved transforms across the GlesOverlayLayerDescriptor below.
// That descriptor is a plain C++ mirror of VGOverlayEvaluatedTransform's
// raster fields (translationX/Y, width, height, rotation, scale, opacity,
// zIndex) plus the GL texture identity, so vanguard_render_gles keeps its
// existing dependency direction: it never includes a compositors, graph, or
// Dart-facing header, exactly like GlesTimelineTransitionCompositor.
//
// Draw model:
//   * Layers are drawn in the caller-provided order, first to last, i.e.
//     back-to-front. The caller (Dart VGOverlayTransformEvaluator today) is
//     responsible for sorting by zIndex; `zIndex` is carried for parity and
//     telemetry only and is never used to reorder here.
//   * Every layer is one textured unit quad whose position is produced in the
//     vertex shader by a `mat3 uTransform` (column-major, applied to
//     (localX, localY, 1) with local coordinates in [-1, 1]²). The matrix
//     encodes: centre = (x + width/2, y + height/2), half extents =
//     (width * scale / 2, height * scale / 2), clockwise-positive rotation
//     about that centre in the Y-down canvas, then the canvas -> NDC mapping.
//     Arbitrary rotation angles are supported; the quad is not clipped to the
//     canvas except by GL's own clip volume.
//   * The fragment shader multiplies the sampled alpha by `float uOpacity`
//     and leaves RGB straight (non-premultiplied). Blending is enabled with
//     glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA,
//                         GL_ONE,       GL_ONE_MINUS_SRC_ALPHA)
//     and GL_FUNC_ADD, which is standard source-over for straight-alpha
//     sources (destination alpha accumulates as srcA + dstA * (1 - srcA)).
//   * The framebuffer is never cleared; overlays composite over the existing
//     surface contents (the base clip layer in a real pipeline, the clear
//     colour in the diagnostic).
//
// Coordinate conventions: x/y are the overlay's top-left corner in canvas
// pixels with a top-left origin and Y down (the Dart convention); rotation
// is radians, clockwise-positive on screen. Texture row 0 (GL convention:
// bottom texel row) is mapped to the visually bottom edge of the overlay, so
// a texture uploaded bottom-up in the usual GL manner appears upright.
//
// GL state lifecycle (Opus correction 1): before the first draw the helper
// records viewport, active texture unit, texture-unit-0 bindings
// (GL_TEXTURE_2D and, when queryable, GL_TEXTURE_EXTERNAL_OES),
// GL_ARRAY_BUFFER binding, current program, GL_BLEND enable, blend equations
// and blend functions, and restores every one of them before returning on
// every path (success, draw failure, compile failure). It creates only
// temporary shader/program/VBO objects and deletes them on every path; it
// never creates, images, or deletes a layer texture; never calls
// eglMakeCurrent / eglSwapBuffers; never clears the framebuffer; owns no
// Surface/SurfaceTexture/MediaCodec/decoder.
//
// Texture targets: GL_TEXTURE_2D and GL_TEXTURE_EXTERNAL_OES are each
// accepted structurally per layer with the sampler type selected per layer;
// any other target (including 0) fails closed before any GL call. This
// slice's physical proof exercises GL_TEXTURE_2D content and the OES sampler
// compile/link route only; no SurfaceTexture/decoder OES frame proof, no
// Vulkan, no decode, no export, no product wiring.
//
// Private source: EGL/GLES/Android headers must never appear in this header;
// the .cpp translation unit confines all such includes behind
// #if defined(__ANDROID__) and compiles to a safe unavailable stub elsewhere.

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace vanguard {
namespace render {

// One resolved overlay layer at one timeline instant. Raster-field mirror of
// the Dart VGOverlayEvaluatedTransform (Opus correction 4): identity /
// type / timing / text / asset fields are intentionally absent because the
// raster stage never needs them. Field order and meaning:
//   texture        - non-zero GL texture name already holding the overlay
//                    raster under `textureTarget`; not owned by the helper.
//   textureTarget  - raw GLenum: GL_TEXTURE_2D (0x0DE1) or
//                    GL_TEXTURE_EXTERNAL_OES (0x8D65).
//   x, y           - top-left corner in canvas pixels (Dart translationX/Y).
//   width, height  - unscaled size in canvas pixels; both must be > 0.
//   rotation       - radians, clockwise-positive, about the layer centre.
//   scale          - uniform scale factor about the layer centre; must be > 0.
//   opacity        - [0, 1]; multiplied into the sampled alpha.
//   zIndex         - draw-order hint carried for parity/telemetry; the helper
//                    draws layers in the caller-provided order.
struct GlesOverlayLayerDescriptor {
    uint32_t texture       = 0;
    uint32_t textureTarget = 0x0DE1; // GL_TEXTURE_2D
    double   x             = 0.0;
    double   y             = 0.0;
    double   width         = 0.0;
    double   height        = 0.0;
    double   rotation      = 0.0;
    double   scale         = 1.0;
    double   opacity       = 1.0;
    int32_t  zIndex        = 0;
};

// Pure, platform-independent validation of one descriptor against a
// surfaceWidth x surfaceHeight canvas (no GL calls). Returns true when the
// layer is drawable; otherwise returns false and sets *outError to one of:
//   "gles_overlay_compositor_invalid_argument"          - surface dim == 0
//   "gles_overlay_compositor_invalid_texture"           - texture == 0
//   "gles_overlay_compositor_unsupported_texture_target"
//   "gles_overlay_compositor_invalid_transform"         - non-finite
//        x/y/width/height/rotation/scale, width/height <= 0, or scale <= 0
//   "gles_overlay_compositor_invalid_opacity"           - non-finite or
//        outside [0, 1]
// Checks run in exactly that order so callers can rely on the first failure.
bool ValidateOverlayLayerDescriptor(const GlesOverlayLayerDescriptor& layer,
                                    uint32_t surfaceWidth,
                                    uint32_t surfaceHeight,
                                    std::string* outError);

// Pure, platform-independent transform math (no GL calls): fills
// outColumnMajor[9] with the column-major mat3 that the vertex shader applies
// to (localX, localY, 1), localX/localY in [-1, 1] (local -1,-1 is the
// overlay's visual top-left corner), producing NDC (x, y, 1). Callers must
// have validated the descriptor; non-finite inputs produce an identity
// matrix and return false.
bool ComputeOverlayTransform(const GlesOverlayLayerDescriptor& layer,
                             uint32_t surfaceWidth,
                             uint32_t surfaceHeight,
                             float outColumnMajor[9]);

class GlesOverlayCompositor {
public:
    GlesOverlayCompositor();
    ~GlesOverlayCompositor();

    GlesOverlayCompositor(const GlesOverlayCompositor&) = delete;
    GlesOverlayCompositor& operator=(const GlesOverlayCompositor&) = delete;

    // Draws `layerCount` layers from `layers` in order (back-to-front) over
    // the current contents of the currently-current EGL surface (see the
    // draw model and state lifecycle in the file header).
    //
    // layers, layerCount       - `layers` may be null only when layerCount
    //                            is 0 (a no-op that still validates the
    //                            surface dimensions and issues no GL call).
    // surfaceWidth,
    // surfaceHeight            - dimensions of the current EGL surface; both
    //                            must be > 0.
    // outError                 - non-null; set to "" on success, to a
    //                            ValidateOverlayLayerDescriptor reason when a
    //                            layer fails validation (all layers are
    //                            validated before any GL call), or to
    //                            "gles_overlay_compositor_shader_compile_failed"
    //                            "gles_overlay_compositor_program_link_failed"
    //                            "gles_overlay_compositor_draw_failed"
    //                            for GL-stage failures.
    //
    // Returns true only if every issued shader compile/link, buffer upload,
    // and draw reports GL_NO_ERROR. Returns false with
    // outError="gles_overlay_compositor_unavailable_on_host" and no GL calls
    // on non-Android builds.
    bool drawOverlays(const GlesOverlayLayerDescriptor* layers,
                      size_t layerCount,
                      uint32_t surfaceWidth,
                      uint32_t surfaceHeight,
                      std::string* outError);
};

} // namespace render
} // namespace vanguard
