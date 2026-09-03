// P5-OVERLAYS-TRANS (sub-slice GLES-RENDER): GlesOverlayCompositor
// shader/raster proof diagnostic JNI bridge.
//
// Android-only translation unit added via the CMake target_sources block.
// This is the composition root for the private
// vanguard::render::GlesOverlayCompositor raster helper: it plays the role
// the Dart VGOverlayTransformEvaluator plays in the product (already-resolved
// per-layer transforms, sorted back-to-front) by hand-building
// GlesOverlayLayerDescriptor values with known expected pixel outcomes. No
// keyframe math is re-implemented natively.
//
// The diagnostic owns a temporary 64x64 EGL pbuffer context and synthetic
// GL_TEXTURE_2D textures created solely for proof on the calling thread,
// draws every lane through the helper, reads pixels back with glReadPixels,
// gates the result against hard-coded expected pixel tables, and tears down
// every EGL/GL object it created before returning.
//
// Non-claim: shader/raster proof only. No Vulkan pipeline or SPIR-V, no
// MediaCodec decode, no SurfaceTexture/decoder OES frame proof (the OES
// sampler route is proven structurally: target validation plus shader
// compile/link against a never-imaged external texture name), no production
// export route, no AndroidTimelineExportSession change, no VGTimelineCompositorNode
// change, no app/editor UI.
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   runAndroidDagPhase5TimelineOverlayGlesRenderSmoke -> jstring (JSON)

#include <jni.h>

#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <sstream>
#include <string>
#include <type_traits>
#include <vector>

#include "gles_overlay_compositor.h"

namespace {

using vanguard::render::ComputeOverlayTransform;
using vanguard::render::GlesOverlayCompositor;
using vanguard::render::GlesOverlayLayerDescriptor;
using vanguard::render::ValidateOverlayLayerDescriptor;

constexpr const char* kProofBoundary =
    "native_gles_timeline_overlay_compositor_shader_raster_only_no_vulkan_no_decode_no_export_no_product";
constexpr const char* kPassMarker =
    "ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_GLES_RENDER_PHYSICAL_SMOKE_PASS";
constexpr const char* kFailMarker =
    "ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_GLES_RENDER_PHYSICAL_SMOKE_FAIL";

constexpr uint32_t kSurfaceWidth   = 64;
constexpr uint32_t kSurfaceHeight  = 64;
constexpr int      kColorTolerance = 8;

constexpr uint32_t kTarget2D      = 0x0DE1; // GL_TEXTURE_2D
constexpr uint32_t kTargetOes     = 0x8D65; // GL_TEXTURE_EXTERNAL_OES
constexpr uint32_t kTargetCubeMap = 0x8513; // GL_TEXTURE_CUBE_MAP (unsupported)

constexpr const char* kErrInvalidArgument   = "gles_overlay_compositor_invalid_argument";
constexpr const char* kErrInvalidTexture    = "gles_overlay_compositor_invalid_texture";
constexpr const char* kErrUnsupportedTarget = "gles_overlay_compositor_unsupported_texture_target";
constexpr const char* kErrInvalidTransform  = "gles_overlay_compositor_invalid_transform";
constexpr const char* kErrInvalidOpacity    = "gles_overlay_compositor_invalid_opacity";
constexpr const char* kErrCompileFailed     = "gles_overlay_compositor_shader_compile_failed";
constexpr const char* kErrLinkFailed        = "gles_overlay_compositor_program_link_failed";

constexpr double kPi = 3.14159265358979323846;

// Lane 7 (struct parity): the native descriptor must mirror the raster
// fields of the Dart VGOverlayEvaluatedTransform (translationX/Y -> x/y,
// width, height, rotation, scale, opacity, zIndex) with the same value
// types. Checked at compile time; the runtime lane re-reports the result.
static_assert(std::is_same<decltype(GlesOverlayLayerDescriptor::texture), uint32_t>::value, "texture");
static_assert(std::is_same<decltype(GlesOverlayLayerDescriptor::textureTarget), uint32_t>::value, "target");
static_assert(std::is_same<decltype(GlesOverlayLayerDescriptor::x), double>::value, "x");
static_assert(std::is_same<decltype(GlesOverlayLayerDescriptor::y), double>::value, "y");
static_assert(std::is_same<decltype(GlesOverlayLayerDescriptor::width), double>::value, "width");
static_assert(std::is_same<decltype(GlesOverlayLayerDescriptor::height), double>::value, "height");
static_assert(std::is_same<decltype(GlesOverlayLayerDescriptor::rotation), double>::value, "rotation");
static_assert(std::is_same<decltype(GlesOverlayLayerDescriptor::scale), double>::value, "scale");
static_assert(std::is_same<decltype(GlesOverlayLayerDescriptor::opacity), double>::value, "opacity");
static_assert(std::is_same<decltype(GlesOverlayLayerDescriptor::zIndex), int32_t>::value, "zIndex");
static_assert(std::is_standard_layout<GlesOverlayLayerDescriptor>::value, "standard layout");
constexpr bool kStructParityCompileTimeOk = true;

struct Rgba {
    uint8_t r;
    uint8_t g;
    uint8_t b;
    uint8_t a;
};

constexpr Rgba kRed      = {255, 0, 0, 255};
constexpr Rgba kYellow   = {255, 255, 0, 255};
constexpr Rgba kMagenta  = {255, 0, 255, 255};
constexpr Rgba kWhite    = {255, 255, 255, 255};
constexpr Rgba kBlue     = {0, 0, 255, 255};
constexpr Rgba kGreen    = {0, 255, 0, 255};
constexpr Rgba kHalfGreen = {0, 255, 0, 128}; // straight alpha ~0.502
constexpr Rgba kSentinel = {40, 40, 40, 255};  // clear colour

// Expected blends over the sentinel (src * a + sentinel * (1 - a)).
constexpr Rgba kRedHalfOverSentinel   = {148, 20, 20, 255};   // a = 0.5
constexpr Rgba kGreenHalfOverSentinel = {20, 148, 20, 255};   // a = 128/255
constexpr Rgba kGreenQuarterOverSentinel = {30, 94, 30, 255}; // a = 0.5 * 128/255
constexpr Rgba kGreenHalfOverBlue     = {0, 128, 128, 255};   // opaque green @0.5 over blue

// Quadrant texture: TL red, TR yellow, BL magenta, BR white.
struct QuadColors {
    Rgba tl;
    Rgba tr;
    Rgba bl;
    Rgba br;
};
constexpr QuadColors kQuadA = {kRed, kYellow, kMagenta, kWhite};

// ── EGL scratch context (owned entirely by this diagnostic) ─────────────────

struct EglScratch {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLConfig  config  = nullptr;
    int        clientVersion = 0;

    bool Setup(std::string* outError) {
        display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (display == EGL_NO_DISPLAY) {
            *outError = "egl_get_display_failed";
            return false;
        }
        EGLint major = 0, minor = 0;
        if (eglInitialize(display, &major, &minor) != EGL_TRUE) {
            *outError = "egl_initialize_failed";
            display = EGL_NO_DISPLAY;
            return false;
        }
        if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) {
            *outError = "egl_bind_api_failed";
            Teardown();
            return false;
        }
        const EGLint configAttribs[] = {
            EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
            EGL_RED_SIZE,   8,
            EGL_GREEN_SIZE, 8,
            EGL_BLUE_SIZE,  8,
            EGL_ALPHA_SIZE, 8,
            EGL_NONE
        };
        EGLint numConfigs = 0;
        if (eglChooseConfig(display, configAttribs, &config, 1, &numConfigs) != EGL_TRUE ||
            numConfigs < 1) {
            *outError = "egl_choose_config_failed";
            config = nullptr;
            Teardown();
            return false;
        }
        const EGLint contextAttribsEs3[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribsEs3);
        clientVersion = 3;
        if (context == EGL_NO_CONTEXT) {
            const EGLint contextAttribsEs2[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
            context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribsEs2);
            clientVersion = 2;
        }
        if (context == EGL_NO_CONTEXT) {
            *outError = "egl_create_context_failed";
            clientVersion = 0;
            Teardown();
            return false;
        }
        const EGLint pbufferAttribs[] = {
            EGL_WIDTH,  static_cast<EGLint>(kSurfaceWidth),
            EGL_HEIGHT, static_cast<EGLint>(kSurfaceHeight),
            EGL_NONE
        };
        surface = eglCreatePbufferSurface(display, config, pbufferAttribs);
        if (surface == EGL_NO_SURFACE) {
            *outError = "egl_create_pbuffer_surface_failed";
            Teardown();
            return false;
        }
        if (eglMakeCurrent(display, surface, surface, context) != EGL_TRUE) {
            *outError = "egl_make_current_failed";
            Teardown();
            return false;
        }
        return true;
    }

    void Teardown() {
        if (display == EGL_NO_DISPLAY) {
            return;
        }
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (surface != EGL_NO_SURFACE) {
            eglDestroySurface(display, surface);
            surface = EGL_NO_SURFACE;
        }
        if (context != EGL_NO_CONTEXT) {
            eglDestroyContext(display, context);
            context = EGL_NO_CONTEXT;
        }
        eglTerminate(display);
        display = EGL_NO_DISPLAY;
        config = nullptr;
        clientVersion = 0;
    }
};

// ── Synthetic textures ──────────────────────────────────────────────────────

void PutTexel(uint8_t* texel, Rgba c) {
    texel[0] = c.r;
    texel[1] = c.g;
    texel[2] = c.b;
    texel[3] = c.a;
}

// 2x2 RGBA GL_TEXTURE_2D, NEAREST/CLAMP. Data rows are uploaded bottom-up
// (GL convention: texel row 0 is the bottom), matching the helper's UV
// mapping so that `tl`/`tr` appear at the visual top of the overlay.
GLuint CreateQuadrantTexture(const QuadColors& q) {
    uint8_t data[2][2][4];
    PutTexel(data[0][0], q.bl);
    PutTexel(data[0][1], q.br);
    PutTexel(data[1][0], q.tl);
    PutTexel(data[1][1], q.tr);

    GLuint texture = 0;
    glGenTextures(1, &texture);
    if (texture == 0) {
        return 0;
    }
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, data);
    glBindTexture(GL_TEXTURE_2D, 0);
    if (glGetError() != GL_NO_ERROR) {
        glDeleteTextures(1, &texture);
        return 0;
    }
    return texture;
}

GLuint CreateSolidTexture(Rgba c) {
    return CreateQuadrantTexture(QuadColors{c, c, c, c});
}

// ── Descriptor construction ─────────────────────────────────────────────────

GlesOverlayLayerDescriptor MakeLayer(GLuint texture,
                                     double x, double y, double width, double height,
                                     double rotation = 0.0,
                                     double scale = 1.0,
                                     double opacity = 1.0,
                                     int32_t zIndex = 0,
                                     uint32_t target = kTarget2D) {
    GlesOverlayLayerDescriptor d;
    d.texture       = texture;
    d.textureTarget = target;
    d.x             = x;
    d.y             = y;
    d.width         = width;
    d.height        = height;
    d.rotation      = rotation;
    d.scale         = scale;
    d.opacity       = opacity;
    d.zIndex        = zIndex;
    return d;
}

// ── Pixel readback + probes ─────────────────────────────────────────────────

void DrainGlErrors() {
    for (int i = 0; i < 16 && glGetError() != GL_NO_ERROR; ++i) {
    }
}

void ClearSentinel() {
    glViewport(0, 0, static_cast<GLsizei>(kSurfaceWidth), static_cast<GLsizei>(kSurfaceHeight));
    glClearColor(kSentinel.r / 255.0f, kSentinel.g / 255.0f, kSentinel.b / 255.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
}

bool ReadSurface(std::vector<uint8_t>& outPixels) {
    outPixels.assign(static_cast<size_t>(kSurfaceWidth) * kSurfaceHeight * 4, 0);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, static_cast<GLsizei>(kSurfaceWidth), static_cast<GLsizei>(kSurfaceHeight),
                 GL_RGBA, GL_UNSIGNED_BYTE, outPixels.data());
    return glGetError() == GL_NO_ERROR;
}

// Pixel at top-left image coordinates (glReadPixels row 0 is the bottom).
const uint8_t* PixelAt(const std::vector<uint8_t>& px, uint32_t x, uint32_t yTopLeft) {
    const uint32_t glRow = kSurfaceHeight - 1 - yTopLeft;
    return &px[(static_cast<size_t>(glRow) * kSurfaceWidth + x) * 4];
}

bool ColorNear(const uint8_t* p, Rgba expected) {
    return std::abs(static_cast<int>(p[0]) - expected.r) <= kColorTolerance &&
           std::abs(static_cast<int>(p[1]) - expected.g) <= kColorTolerance &&
           std::abs(static_cast<int>(p[2]) - expected.b) <= kColorTolerance &&
           std::abs(static_cast<int>(p[3]) - expected.a) <= kColorTolerance;
}

uint64_t Checksum(const std::vector<uint8_t>& px) {
    uint64_t sum = 0;
    for (const uint8_t b : px) sum += b;
    return sum;
}

// One expected-ownership region in top-left pixel coordinates [x0,x1)x[y0,y1).
// Regions are evaluated in order; the first region containing a pixel wins,
// so list the topmost (last drawn) layer's regions first.
struct Region {
    uint32_t x0, y0, x1, y1;
    Rgba color;
};

// Counts pixels whose colour does not match the first region containing
// them, or the sentinel when no region contains them.
uint32_t CountTableMismatches(const std::vector<uint8_t>& px,
                              const Region* regions, size_t regionCount,
                              uint32_t* outFirstBadX, uint32_t* outFirstBadY,
                              std::string* outFirstBadRgba) {
    uint32_t mismatches = 0;
    for (uint32_t y = 0; y < kSurfaceHeight; ++y) {
        for (uint32_t x = 0; x < kSurfaceWidth; ++x) {
            Rgba expected = kSentinel;
            for (size_t i = 0; i < regionCount; ++i) {
                const Region& r = regions[i];
                if (x >= r.x0 && x < r.x1 && y >= r.y0 && y < r.y1) {
                    expected = r.color;
                    break;
                }
            }
            const uint8_t* p = PixelAt(px, x, y);
            if (!ColorNear(p, expected)) {
                if (mismatches == 0) {
                    *outFirstBadX = x;
                    *outFirstBadY = y;
                    char buf[48];
                    std::snprintf(buf, sizeof(buf), "%u,%u,%u,%u", p[0], p[1], p[2], p[3]);
                    *outFirstBadRgba = buf;
                }
                ++mismatches;
            }
        }
    }
    return mismatches;
}

std::string RgbaString(const uint8_t* p) {
    char buf[48];
    std::snprintf(buf, sizeof(buf), "%u,%u,%u,%u", p[0], p[1], p[2], p[3]);
    return buf;
}

// ── JSON helpers ────────────────────────────────────────────────────────────

std::string JsonEscape(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (const char c : in) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned>(c));
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

const char* BoolStr(bool v) { return v ? "true" : "false"; }

class DetailsBuilder {
public:
    void Str(const char* key, const std::string& value) {
        Raw(key, "\"" + JsonEscape(value) + "\"");
    }
    void Bool(const char* key, bool value) { Raw(key, BoolStr(value)); }
    void U64(const char* key, uint64_t value) { Raw(key, std::to_string(value)); }
    void Int(const char* key, int64_t value) { Raw(key, std::to_string(value)); }
    std::string Json() const {
        std::string out = "{";
        for (size_t i = 0; i < entries_.size(); ++i) {
            if (i != 0) out += ",";
            out += entries_[i];
        }
        out += "}";
        return out;
    }

private:
    void Raw(const char* key, const std::string& rawValue) {
        entries_.push_back("\"" + JsonEscape(key) + "\":" + rawValue);
    }
    std::vector<std::string> entries_;
};

// Clear -> draw the layer list -> read -> gate against the region table.
bool RunTableCase(GlesOverlayCompositor& compositor,
                  const GlesOverlayLayerDescriptor* layers, size_t layerCount,
                  const Region* regions, size_t regionCount,
                  const char* name,
                  DetailsBuilder& details,
                  std::string* outFailure) {
    const std::string keyBase = name;
    std::string err;
    DrainGlErrors();
    ClearSentinel();
    if (!compositor.drawOverlays(layers, layerCount, kSurfaceWidth, kSurfaceHeight, &err)) {
        details.Str((keyBase + "Error").c_str(), err);
        *outFailure = keyBase + "_draw_failed:" + err;
        return false;
    }
    std::vector<uint8_t> px;
    if (!ReadSurface(px)) {
        details.Str((keyBase + "Error").c_str(), "read_pixels_failed");
        *outFailure = keyBase + "_read_pixels_failed";
        return false;
    }
    uint32_t badX = 0, badY = 0;
    std::string badRgba;
    const uint32_t mismatches =
        CountTableMismatches(px, regions, regionCount, &badX, &badY, &badRgba);
    details.U64((keyBase + "Mismatches").c_str(), mismatches);
    details.Str((keyBase + "Checksum").c_str(), std::to_string(Checksum(px)));
    details.Str((keyBase + "CenterRgba").c_str(),
                RgbaString(PixelAt(px, kSurfaceWidth / 2, kSurfaceHeight / 2)));
    if (mismatches != 0) {
        details.Str((keyBase + "FirstMismatch").c_str(),
                    std::to_string(badX) + "," + std::to_string(badY) + ":" + badRgba);
        *outFailure = keyBase + "_pixel_mismatch";
        return false;
    }
    return true;
}

// Expects drawOverlays to reject `layer` with exactly `expectedError`.
bool ExpectRejected(GlesOverlayCompositor& compositor,
                    const GlesOverlayLayerDescriptor& layer,
                    uint32_t surfaceWidth, uint32_t surfaceHeight,
                    const char* expectedError,
                    std::string* outActual) {
    std::string err;
    const bool drew = compositor.drawOverlays(&layer, 1, surfaceWidth, surfaceHeight, &err);
    *outActual = err;
    return !drew && err == expectedError;
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase5TimelineOverlayGlesRenderSmoke(
    JNIEnv* env,
    jobject /* this */) {

    std::string failureReason;
    auto fail = [&failureReason](const std::string& reason) {
        if (failureReason.empty()) {
            failureReason = reason;
        }
    };
    DetailsBuilder details;
    details.Str("proofBoundary", kProofBoundary);
    details.U64("surfaceWidth", kSurfaceWidth);
    details.U64("surfaceHeight", kSurfaceHeight);
    details.Int("colorTolerance", kColorTolerance);

    // Gate flags (all default false; every lane must set its own true).
    bool eglSetupOk = false;
    bool invalidTextureRejectedOk = false;
    bool invalidDimensionsRejectedOk = false;
    bool nonFiniteTransformRejectedOk = false;
    bool invalidOpacityRejectedOk = false;
    bool unsupportedTargetRejectedOk = false;
    bool singleLayerTransformOk = false;
    bool opacityBlendOk = false;
    bool multiLayerZOrderOk = false;
    bool texture2dTargetAcceptedOk = false;
    bool oesTargetStructuralOk = false;
    bool unsupportedTargetStillRejectedOk = false;
    bool blendStateRestoredOk = false;
    bool viewportRestoredOk = false;
    bool glStateRestoredOk = false;
    bool structParityOk = false;
    bool canonical = false;

    EglScratch egl;
    GLuint solidRed = 0, solidBlue = 0, solidGreen = 0, halfGreen = 0, quadA = 0;
    GLuint oesName = 0;

    {
        std::string eglError;
        eglSetupOk = egl.Setup(&eglError);
        details.Bool("eglSetupOk", eglSetupOk);
        details.Int("eglClientVersion", egl.clientVersion);
        if (!eglSetupOk) {
            fail("egl_setup_failed:" + eglError);
            details.Str("eglError", eglError);
        }
    }

    bool oesExtensionAvailable = false;
    if (eglSetupOk) {
        const GLubyte* version  = glGetString(GL_VERSION);
        const GLubyte* renderer = glGetString(GL_RENDERER);
        const GLubyte* exts     = glGetString(GL_EXTENSIONS);
        details.Str("glVersion", version ? reinterpret_cast<const char*>(version) : "");
        details.Str("glRenderer", renderer ? reinterpret_cast<const char*>(renderer) : "");
        oesExtensionAvailable = exts != nullptr &&
            std::strstr(reinterpret_cast<const char*>(exts), "GL_OES_EGL_image_external") != nullptr;
        details.Bool("oesExtensionAvailable", oesExtensionAvailable);
        glDisable(GL_DITHER);
        glDisable(GL_BLEND);
        glDisable(GL_SCISSOR_TEST);
        DrainGlErrors();

        solidRed   = CreateSolidTexture(kRed);
        solidBlue  = CreateSolidTexture(kBlue);
        solidGreen = CreateSolidTexture(kGreen);
        halfGreen  = CreateSolidTexture(kHalfGreen);
        quadA      = CreateQuadrantTexture(kQuadA);
        // Fresh, never-bound name for the structural OES lane; the helper's
        // first glBindTexture(GL_TEXTURE_EXTERNAL_OES, name) defines it as an
        // external texture with no image.
        glGenTextures(1, &oesName);
        if (solidRed == 0 || solidBlue == 0 || solidGreen == 0 || halfGreen == 0 ||
            quadA == 0 || oesName == 0) {
            eglSetupOk = false;
            fail("synthetic_texture_creation_failed");
        }
    }

    GlesOverlayCompositor compositor;

    if (eglSetupOk) {
        // ── Lane 1: parameter validation (fail closed, no GL calls) ────────
        const GlesOverlayLayerDescriptor valid = MakeLayer(solidRed, 8, 8, 16, 16);
        std::string err;
        DrainGlErrors();

        invalidTextureRejectedOk =
            ExpectRejected(compositor, MakeLayer(0, 8, 8, 16, 16),
                           kSurfaceWidth, kSurfaceHeight, kErrInvalidTexture, &err);
        details.Str("invalidTextureError", err);

        bool ok = ExpectRejected(compositor, valid, 0, kSurfaceHeight, kErrInvalidArgument, &err);
        ok = ok && ExpectRejected(compositor, valid, kSurfaceWidth, 0, kErrInvalidArgument, &err);
        ok = ok && ExpectRejected(compositor, MakeLayer(solidRed, 8, 8, 0, 16),
                                  kSurfaceWidth, kSurfaceHeight, kErrInvalidTransform, &err);
        ok = ok && ExpectRejected(compositor, MakeLayer(solidRed, 8, 8, 16, -4),
                                  kSurfaceWidth, kSurfaceHeight, kErrInvalidTransform, &err);
        ok = ok && ExpectRejected(compositor, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, 0.0),
                                  kSurfaceWidth, kSurfaceHeight, kErrInvalidTransform, &err);
        {
            // Null layer array with a non-zero count is an argument error.
            std::string nullErr;
            const bool nullRejected =
                !compositor.drawOverlays(nullptr, 1, kSurfaceWidth, kSurfaceHeight, &nullErr) &&
                nullErr == kErrInvalidArgument;
            ok = ok && nullRejected;
        }
        invalidDimensionsRejectedOk = ok;
        details.Str("invalidDimensionsError", err);

        const double kNan = std::numeric_limits<double>::quiet_NaN();
        const double kInf = std::numeric_limits<double>::infinity();
        ok = ExpectRejected(compositor, MakeLayer(solidRed, kNan, 8, 16, 16),
                            kSurfaceWidth, kSurfaceHeight, kErrInvalidTransform, &err);
        ok = ok && ExpectRejected(compositor, MakeLayer(solidRed, 8, kInf, 16, 16),
                                  kSurfaceWidth, kSurfaceHeight, kErrInvalidTransform, &err);
        ok = ok && ExpectRejected(compositor, MakeLayer(solidRed, 8, 8, kNan, 16),
                                  kSurfaceWidth, kSurfaceHeight, kErrInvalidTransform, &err);
        ok = ok && ExpectRejected(compositor, MakeLayer(solidRed, 8, 8, 16, kInf),
                                  kSurfaceWidth, kSurfaceHeight, kErrInvalidTransform, &err);
        ok = ok && ExpectRejected(compositor, MakeLayer(solidRed, 8, 8, 16, 16, kNan),
                                  kSurfaceWidth, kSurfaceHeight, kErrInvalidTransform, &err);
        ok = ok && ExpectRejected(compositor, MakeLayer(solidRed, 8, 8, 16, 16, -kInf),
                                  kSurfaceWidth, kSurfaceHeight, kErrInvalidTransform, &err);
        ok = ok && ExpectRejected(compositor, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, kNan),
                                  kSurfaceWidth, kSurfaceHeight, kErrInvalidTransform, &err);
        ok = ok && ExpectRejected(compositor, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, kInf),
                                  kSurfaceWidth, kSurfaceHeight, kErrInvalidTransform, &err);
        nonFiniteTransformRejectedOk = ok;
        details.Str("nonFiniteTransformError", err);

        ok = ExpectRejected(compositor, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, 1.0, kNan),
                            kSurfaceWidth, kSurfaceHeight, kErrInvalidOpacity, &err);
        ok = ok && ExpectRejected(compositor, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, 1.0, kInf),
                                  kSurfaceWidth, kSurfaceHeight, kErrInvalidOpacity, &err);
        ok = ok && ExpectRejected(compositor, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, 1.0, -0.01),
                                  kSurfaceWidth, kSurfaceHeight, kErrInvalidOpacity, &err);
        ok = ok && ExpectRejected(compositor, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, 1.0, 1.01),
                                  kSurfaceWidth, kSurfaceHeight, kErrInvalidOpacity, &err);
        invalidOpacityRejectedOk = ok;
        details.Str("invalidOpacityError", err);

        ok = ExpectRejected(compositor, MakeLayer(solidRed, 8, 8, 16, 16, 0.0, 1.0, 1.0, 0, 0),
                            kSurfaceWidth, kSurfaceHeight, kErrUnsupportedTarget, &err);
        ok = ok && ExpectRejected(compositor,
                                  MakeLayer(solidRed, 8, 8, 16, 16, 0.0, 1.0, 1.0, 0, kTargetCubeMap),
                                  kSurfaceWidth, kSurfaceHeight, kErrUnsupportedTarget, &err);
        {
            // A bad layer anywhere in the list rejects the whole list before
            // any GL call: the valid first layer must not be drawn.
            const GlesOverlayLayerDescriptor list[2] = {
                valid, MakeLayer(solidBlue, 0, 0, 16, 16, 0.0, 1.0, 1.0, 1, kTargetCubeMap)};
            std::string listErr;
            ClearSentinel();
            const bool listRejected =
                !compositor.drawOverlays(list, 2, kSurfaceWidth, kSurfaceHeight, &listErr) &&
                listErr == kErrUnsupportedTarget;
            std::vector<uint8_t> px;
            uint32_t bx = 0, by = 0;
            std::string brgba;
            const bool untouched = ReadSurface(px) &&
                CountTableMismatches(px, nullptr, 0, &bx, &by, &brgba) == 0;
            details.Bool("mixedListRejectedBeforeDraw", listRejected && untouched);
            ok = ok && listRejected && untouched;
        }
        unsupportedTargetRejectedOk = ok;
        details.Str("unsupportedTargetError", err);

        const bool noGlErrorAfterValidation = glGetError() == GL_NO_ERROR;
        details.Bool("noGlErrorAfterValidation", noGlErrorAfterValidation);
        if (!noGlErrorAfterValidation) {
            invalidTextureRejectedOk = false;
            invalidDimensionsRejectedOk = false;
            nonFiniteTransformRejectedOk = false;
            invalidOpacityRejectedOk = false;
            unsupportedTargetRejectedOk = false;
        }
        if (!invalidTextureRejectedOk)     fail("invalid_texture_not_rejected");
        if (!invalidDimensionsRejectedOk)  fail("invalid_dimensions_not_rejected");
        if (!nonFiniteTransformRejectedOk) fail("non_finite_transform_not_rejected");
        if (!invalidOpacityRejectedOk)     fail("invalid_opacity_not_rejected");
        if (!unsupportedTargetRejectedOk)  fail("unsupported_target_not_rejected");

        // ── Lane 2: single-layer transform (translation + scale, rotation) ─
        std::string laneFailure;
        {
            // Quadrant texture at (16,16) 16x16, scale 2 -> centre (24,24),
            // half extents 16 -> covers [8,40)² with quadrants at 24.
            const GlesOverlayLayerDescriptor scaled = MakeLayer(quadA, 16, 16, 16, 16, 0.0, 2.0);
            const Region scaledTable[] = {
                {8, 8, 24, 24, kRed}, {24, 8, 40, 24, kYellow},
                {8, 24, 24, 40, kMagenta}, {24, 24, 40, 40, kWhite},
            };
            const bool scaledOk = RunTableCase(compositor, &scaled, 1, scaledTable, 4,
                                               "translateScale", details, &laneFailure);
            if (!scaledOk) fail(laneFailure);

            // Non-square 32x16 at (16,24), rotated +90 deg (clockwise) about
            // centre (32,32) -> covers [24,40)x[16,48); quadrants rotate
            // TL->TR, TR->BR, BR->BL, BL->TL.
            const GlesOverlayLayerDescriptor rotated = MakeLayer(quadA, 16, 24, 32, 16, kPi / 2.0);
            const Region rotatedTable[] = {
                {24, 16, 32, 32, kMagenta}, {32, 16, 40, 32, kRed},
                {24, 32, 32, 48, kWhite},   {32, 32, 40, 48, kYellow},
            };
            const bool rotatedOk = RunTableCase(compositor, &rotated, 1, rotatedTable, 4,
                                                "rotate90", details, &laneFailure);
            if (!rotatedOk) fail(laneFailure);

            // 180 deg: quadrants swap diagonally, footprint unchanged.
            const GlesOverlayLayerDescriptor flipped = MakeLayer(quadA, 16, 16, 32, 32, kPi);
            const Region flippedTable[] = {
                {16, 16, 32, 32, kWhite}, {32, 16, 48, 32, kMagenta},
                {16, 32, 32, 48, kYellow}, {32, 32, 48, 48, kRed},
            };
            const bool flippedOk = RunTableCase(compositor, &flipped, 1, flippedTable, 4,
                                                "rotate180", details, &laneFailure);
            if (!flippedOk) fail(laneFailure);

            // Partially off-canvas translation: red 32x32 at (48,-16) shows
            // only [48,64)x[0,16).
            const GlesOverlayLayerDescriptor offCanvas = MakeLayer(solidRed, 48, -16, 32, 32);
            const Region offCanvasTable[] = {{48, 0, 64, 16, kRed}};
            const bool offCanvasOk = RunTableCase(compositor, &offCanvas, 1, offCanvasTable, 1,
                                                  "offCanvasClip", details, &laneFailure);
            if (!offCanvasOk) fail(laneFailure);

            singleLayerTransformOk = scaledOk && rotatedOk && flippedOk && offCanvasOk;
        }

        // ── Lane 3: per-layer opacity + Porter-Duff source-over ────────────
        {
            const GlesOverlayLayerDescriptor redHalf = MakeLayer(solidRed, 0, 0, 64, 64, 0.0, 1.0, 0.5);
            const Region redHalfTable[] = {{0, 0, 64, 64, kRedHalfOverSentinel}};
            const bool a = RunTableCase(compositor, &redHalf, 1, redHalfTable, 1,
                                        "opacityHalfUniform", details, &laneFailure);
            if (!a) fail(laneFailure);

            // Texture alpha alone (uOpacity = 1) blends.
            const GlesOverlayLayerDescriptor texAlpha = MakeLayer(halfGreen, 0, 0, 64, 64);
            const Region texAlphaTable[] = {{0, 0, 64, 64, kGreenHalfOverSentinel}};
            const bool b = RunTableCase(compositor, &texAlpha, 1, texAlphaTable, 1,
                                        "textureAlphaBlend", details, &laneFailure);
            if (!b) fail(laneFailure);

            // Texture alpha x uOpacity multiply.
            const GlesOverlayLayerDescriptor both = MakeLayer(halfGreen, 0, 0, 64, 64, 0.0, 1.0, 0.5);
            const Region bothTable[] = {{0, 0, 64, 64, kGreenQuarterOverSentinel}};
            const bool c = RunTableCase(compositor, &both, 1, bothTable, 1,
                                        "textureAlphaTimesOpacity", details, &laneFailure);
            if (!c) fail(laneFailure);

            // Opacity 0 leaves the destination untouched; opacity 1 is opaque.
            const GlesOverlayLayerDescriptor zero = MakeLayer(solidRed, 0, 0, 64, 64, 0.0, 1.0, 0.0);
            const bool d = RunTableCase(compositor, &zero, 1, nullptr, 0,
                                        "opacityZero", details, &laneFailure);
            if (!d) fail(laneFailure);
            const GlesOverlayLayerDescriptor one = MakeLayer(solidRed, 16, 16, 32, 32);
            const Region oneTable[] = {{16, 16, 48, 48, kRed}};
            const bool e = RunTableCase(compositor, &one, 1, oneTable, 1,
                                        "opacityOneOpaque", details, &laneFailure);
            if (!e) fail(laneFailure);

            opacityBlendOk = a && b && c && d && e;
        }

        // ── Lane 4: multi-layer stacking / order ───────────────────────────
        {
            const GlesOverlayLayerDescriptor stack[3] = {
                MakeLayer(solidRed,   0,  0, 32, 64, 0.0, 1.0, 1.0, 0),
                MakeLayer(solidBlue,  16, 0, 32, 64, 0.0, 1.0, 1.0, 1),
                MakeLayer(solidGreen, 24, 24, 16, 16, 0.0, 1.0, 0.5, 2),
            };
            const Region stackTable[] = {
                {24, 24, 40, 40, kGreenHalfOverBlue}, // top: half green over blue
                {16, 0, 48, 64, kBlue},               // middle covers red overlap
                {0, 0, 32, 64, kRed},
            };
            const bool forwardOk = RunTableCase(compositor, stack, 3, stackTable, 3,
                                                "stackForward", details, &laneFailure);
            if (!forwardOk) fail(laneFailure);

            // Reverse order of the two opaque layers: overlap must be red,
            // proving the helper honours caller order rather than zIndex.
            const GlesOverlayLayerDescriptor reversed[2] = {stack[1], stack[0]};
            const Region reversedTable[] = {
                {0, 0, 32, 64, kRed},
                {16, 0, 48, 64, kBlue},
            };
            const bool reverseOk = RunTableCase(compositor, reversed, 2, reversedTable, 2,
                                                "stackReversed", details, &laneFailure);
            if (!reverseOk) fail(laneFailure);

            // Empty list is a successful no-op.
            std::string emptyErr;
            ClearSentinel();
            const bool emptyOk =
                compositor.drawOverlays(nullptr, 0, kSurfaceWidth, kSurfaceHeight, &emptyErr) &&
                emptyErr.empty() && glGetError() == GL_NO_ERROR;
            details.Bool("emptyListNoOpOk", emptyOk);
            if (!emptyOk) fail("empty_layer_list_not_no_op");

            multiLayerZOrderOk = forwardOk && reverseOk && emptyOk;
        }

        // ── Lane 6a: GL state restoration (non-default prior state) ────────
        {
            DrainGlErrors();
            // Prior state: blending enabled with unusual func/equation, odd
            // viewport, texture bound on unit 0, active unit 1.
            glEnable(GL_BLEND);
            glBlendEquationSeparate(GL_FUNC_REVERSE_SUBTRACT, GL_FUNC_ADD);
            glBlendFuncSeparate(GL_ONE, GL_ONE, GL_ZERO, GL_ONE);
            glViewport(4, 6, 20, 24);
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, quadA);
            glActiveTexture(GL_TEXTURE1);
            DrainGlErrors();

            const GlesOverlayLayerDescriptor probe = MakeLayer(solidBlue, 16, 16, 32, 32);
            std::string probeErr;
            const bool probeDrawn =
                compositor.drawOverlays(&probe, 1, kSurfaceWidth, kSurfaceHeight, &probeErr);
            details.Bool("priorStateProbeDrawOk", probeDrawn);
            details.Str("priorStateProbeError", probeErr);

            GLint blendEnabled = glIsEnabled(GL_BLEND);
            GLint eqRgb = 0, eqA = 0, srcRgb = 0, dstRgb = 0, srcA = 0, dstA = 0;
            glGetIntegerv(GL_BLEND_EQUATION_RGB, &eqRgb);
            glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &eqA);
            glGetIntegerv(GL_BLEND_SRC_RGB, &srcRgb);
            glGetIntegerv(GL_BLEND_DST_RGB, &dstRgb);
            glGetIntegerv(GL_BLEND_SRC_ALPHA, &srcA);
            glGetIntegerv(GL_BLEND_DST_ALPHA, &dstA);
            const bool priorBlendRestored =
                blendEnabled == GL_TRUE && eqRgb == GL_FUNC_REVERSE_SUBTRACT && eqA == GL_FUNC_ADD &&
                srcRgb == GL_ONE && dstRgb == GL_ONE && srcA == GL_ZERO && dstA == GL_ONE;
            details.Bool("priorBlendStateRestored", priorBlendRestored);

            GLint vp[4] = {-1, -1, -1, -1};
            glGetIntegerv(GL_VIEWPORT, vp);
            const bool priorViewportRestored = vp[0] == 4 && vp[1] == 6 && vp[2] == 20 && vp[3] == 24;
            details.Str("viewportAfterPriorStateDraw",
                        std::to_string(vp[0]) + "," + std::to_string(vp[1]) + "," +
                        std::to_string(vp[2]) + "," + std::to_string(vp[3]));

            GLint activeTexture = 0, binding0 = 0, program = -1, arrayBuffer = -1;
            glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
            glActiveTexture(GL_TEXTURE0);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &binding0);
            glGetIntegerv(GL_CURRENT_PROGRAM, &program);
            glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &arrayBuffer);
            const bool priorGlRestored =
                activeTexture == GL_TEXTURE1 && binding0 == static_cast<GLint>(quadA) &&
                program == 0 && arrayBuffer == 0;
            details.Bool("priorActiveTextureUnit1Restored", activeTexture == GL_TEXTURE1);
            details.Bool("priorTexture2dBindingRestored", binding0 == static_cast<GLint>(quadA));
            details.Int("currentProgramAfterPriorStateDraw", program);
            details.Int("arrayBufferBindingAfterPriorStateDraw", arrayBuffer);

            // Reset to the diagnostic's baseline state.
            glBindTexture(GL_TEXTURE_2D, 0);
            glActiveTexture(GL_TEXTURE0);
            glDisable(GL_BLEND);
            glBlendEquationSeparate(GL_FUNC_ADD, GL_FUNC_ADD);
            glBlendFuncSeparate(GL_ONE, GL_ZERO, GL_ONE, GL_ZERO);
            glViewport(0, 0, static_cast<GLsizei>(kSurfaceWidth), static_cast<GLsizei>(kSurfaceHeight));
            const bool noGlError = glGetError() == GL_NO_ERROR;

            // ── Lane 6b: default prior state (blend disabled, full viewport).
            const GlesOverlayLayerDescriptor probe2 = MakeLayer(solidRed, 0, 0, 16, 16);
            std::string probe2Err;
            const bool probe2Drawn =
                compositor.drawOverlays(&probe2, 1, kSurfaceWidth, kSurfaceHeight, &probe2Err);
            GLint blendAfter = glIsEnabled(GL_BLEND);
            glGetIntegerv(GL_BLEND_SRC_RGB, &srcRgb);
            glGetIntegerv(GL_BLEND_DST_RGB, &dstRgb);
            glGetIntegerv(GL_BLEND_SRC_ALPHA, &srcA);
            glGetIntegerv(GL_BLEND_DST_ALPHA, &dstA);
            glGetIntegerv(GL_BLEND_EQUATION_RGB, &eqRgb);
            glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &eqA);
            const bool defaultBlendRestored =
                blendAfter == GL_FALSE && srcRgb == GL_ONE && dstRgb == GL_ZERO &&
                srcA == GL_ONE && dstA == GL_ZERO && eqRgb == GL_FUNC_ADD && eqA == GL_FUNC_ADD;
            details.Bool("defaultBlendStateRestored", defaultBlendRestored);
            details.Bool("blendDisabledAfterDraw", blendAfter == GL_FALSE);

            glGetIntegerv(GL_VIEWPORT, vp);
            const bool defaultViewportRestored =
                vp[0] == 0 && vp[1] == 0 &&
                vp[2] == static_cast<GLint>(kSurfaceWidth) && vp[3] == static_cast<GLint>(kSurfaceHeight);
            details.Str("viewportAfterDefaultStateDraw",
                        std::to_string(vp[0]) + "," + std::to_string(vp[1]) + "," +
                        std::to_string(vp[2]) + "," + std::to_string(vp[3]));

            glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &binding0);
            glGetIntegerv(GL_CURRENT_PROGRAM, &program);
            glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &arrayBuffer);
            const bool defaultGlRestored =
                activeTexture == GL_TEXTURE0 && binding0 == 0 && program == 0 && arrayBuffer == 0;
            details.Int("currentProgramAfterDraw", program);
            details.Int("arrayBufferBindingAfterDraw", arrayBuffer);
            details.Bool("activeTextureUnit0AfterDraw", activeTexture == GL_TEXTURE0);
            details.Int("texture2dBindingUnit0AfterDraw", binding0);
            const bool noGlError2 = glGetError() == GL_NO_ERROR;

            blendStateRestoredOk = probeDrawn && probe2Drawn && priorBlendRestored &&
                                   defaultBlendRestored && noGlError && noGlError2;
            viewportRestoredOk = probeDrawn && probe2Drawn && priorViewportRestored &&
                                 defaultViewportRestored && noGlError && noGlError2;
            glStateRestoredOk = probeDrawn && probe2Drawn && priorGlRestored &&
                                defaultGlRestored && noGlError && noGlError2;
            if (!blendStateRestoredOk) fail("blend_state_not_restored");
            if (!viewportRestoredOk)   fail("viewport_not_restored");
            if (!glStateRestoredOk)    fail("gl_state_not_restored");
        }

        // ── Lane 5: texture targets ────────────────────────────────────────
        // GL_TEXTURE_2D fully accepted: every content lane above went through
        // the 2D route.
        texture2dTargetAcceptedOk = singleLayerTransformOk && opacityBlendOk && multiLayerZOrderOk;
        if (!texture2dTargetAcceptedOk) fail("texture_2d_target_route_not_fully_accepted");

        // GL_TEXTURE_EXTERNAL_OES structural route: an OES layer alone and an
        // OES layer mixed with a 2D layer must pass target validation and,
        // where the extension exists, compile/link. A never-imaged external
        // texture name is used; no SurfaceTexture or decoder OES frame is
        // claimed.
        {
            bool structuralOk = true;
            {
                DrainGlErrors();
                ClearSentinel();
                std::string oesErr;
                const GlesOverlayLayerDescriptor oesLayer =
                    MakeLayer(oesName, 8, 8, 16, 16, 0.3, 1.5, 0.75, 0, kTargetOes);
                const bool drawOk =
                    compositor.drawOverlays(&oesLayer, 1, kSurfaceWidth, kSurfaceHeight, &oesErr);
                const bool rejectedAsUnsupported = oesErr == kErrUnsupportedTarget;
                const bool compileOrLinkFailed = oesErr == kErrCompileFailed || oesErr == kErrLinkFailed;
                details.Bool("oesSingleDrawOk", drawOk);
                details.Str("oesSingleError", oesErr);
                if (rejectedAsUnsupported) structuralOk = false;
                if (oesExtensionAvailable && compileOrLinkFailed) structuralOk = false;
                DrainGlErrors();
            }
            {
                DrainGlErrors();
                ClearSentinel();
                std::string oesErr;
                const GlesOverlayLayerDescriptor mixed[2] = {
                    MakeLayer(solidRed, 0, 0, 32, 32, 0.0, 1.0, 1.0, 0),
                    MakeLayer(oesName, 16, 16, 16, 16, 0.0, 1.0, 1.0, 1, kTargetOes),
                };
                const bool drawOk =
                    compositor.drawOverlays(mixed, 2, kSurfaceWidth, kSurfaceHeight, &oesErr);
                const bool rejectedAsUnsupported = oesErr == kErrUnsupportedTarget;
                const bool compileOrLinkFailed = oesErr == kErrCompileFailed || oesErr == kErrLinkFailed;
                details.Bool("oesMixedWith2dDrawOk", drawOk);
                details.Str("oesMixedWith2dError", oesErr);
                if (rejectedAsUnsupported) structuralOk = false;
                if (oesExtensionAvailable && compileOrLinkFailed) structuralOk = false;
                DrainGlErrors();
            }
            oesTargetStructuralOk = structuralOk;
            if (!oesTargetStructuralOk) fail("oes_target_structural_route_failed");
            details.Str("oesProofScope",
                        "structural_target_validation_and_sampler_compile_only_no_surfacetexture_no_decoder_frame");
        }

        // Unsupported targets are still rejected after the OES route ran.
        {
            std::string stillErr;
            bool still = ExpectRejected(compositor,
                                        MakeLayer(solidRed, 8, 8, 16, 16, 0.0, 1.0, 1.0, 0, kTargetCubeMap),
                                        kSurfaceWidth, kSurfaceHeight, kErrUnsupportedTarget, &stillErr);
            still = still && ExpectRejected(compositor,
                                            MakeLayer(solidRed, 8, 8, 16, 16, 0.0, 1.0, 1.0, 0, 0),
                                            kSurfaceWidth, kSurfaceHeight, kErrUnsupportedTarget, &stillErr);
            still = still && glGetError() == GL_NO_ERROR;
            unsupportedTargetStillRejectedOk = still;
            details.Str("unsupportedTargetStillError", stillErr);
            if (!unsupportedTargetStillRejectedOk) fail("unsupported_target_not_still_rejected");
        }

        // ── Lane 7: descriptor / transform parity ──────────────────────────
        {
            // Full-canvas identity placement must map local (-1,-1) (visual
            // top-left) to NDC (-1, +1) and local (+1,+1) to NDC (+1, -1).
            float m[9];
            const GlesOverlayLayerDescriptor full = MakeLayer(solidRed, 0, 0, 64, 64);
            bool parity = ComputeOverlayTransform(full, kSurfaceWidth, kSurfaceHeight, m);
            auto apply = [&m](double lx, double ly, double* ox, double* oy) {
                *ox = m[0] * lx + m[3] * ly + m[6];
                *oy = m[1] * lx + m[4] * ly + m[7];
            };
            auto near = [](double a, double b) { return std::fabs(a - b) <= 1e-5; };
            double ox = 0, oy = 0;
            apply(-1, -1, &ox, &oy);
            parity = parity && near(ox, -1.0) && near(oy, 1.0);
            apply(1, 1, &ox, &oy);
            parity = parity && near(ox, 1.0) && near(oy, -1.0);
            parity = parity && near(m[2], 0.0) && near(m[5], 0.0) && near(m[8], 1.0);

            // Rotated lane-2 descriptor: source top-left corner lands on
            // canvas pixel (40, 16) -> NDC (0.25, 0.5).
            const GlesOverlayLayerDescriptor rotated = MakeLayer(quadA, 16, 24, 32, 16, kPi / 2.0);
            parity = parity && ComputeOverlayTransform(rotated, kSurfaceWidth, kSurfaceHeight, m);
            apply(-1, -1, &ox, &oy);
            parity = parity && near(ox, 0.25) && near(oy, 0.5);

            // Pure validation parity with the fail-closed draw path.
            std::string vErr;
            parity = parity && ValidateOverlayLayerDescriptor(full, kSurfaceWidth, kSurfaceHeight, &vErr) &&
                     vErr.empty();
            parity = parity &&
                     !ValidateOverlayLayerDescriptor(MakeLayer(0, 0, 0, 64, 64), kSurfaceWidth, kSurfaceHeight, &vErr) &&
                     vErr == kErrInvalidTexture;
            parity = parity &&
                     !ValidateOverlayLayerDescriptor(MakeLayer(solidRed, 0, 0, 64, 64, 0.0, 1.0, 2.0),
                                                     kSurfaceWidth, kSurfaceHeight, &vErr) &&
                     vErr == kErrInvalidOpacity;

            // Non-finite descriptor yields identity + false from the pure math.
            const double nanRot = std::numeric_limits<double>::quiet_NaN();
            const bool nonFiniteIdentity =
                !ComputeOverlayTransform(MakeLayer(solidRed, 0, 0, 64, 64, nanRot),
                                         kSurfaceWidth, kSurfaceHeight, m) &&
                near(m[0], 1.0) && near(m[4], 1.0) && near(m[8], 1.0) &&
                near(m[1], 0.0) && near(m[3], 0.0) && near(m[6], 0.0) && near(m[7], 0.0);
            parity = parity && nonFiniteIdentity;

            structParityOk = kStructParityCompileTimeOk && parity;
            details.Str("descriptorFields",
                        "texture,textureTarget,x,y,width,height,rotation,scale,opacity,zIndex");
            details.Str("mirroredDartFields",
                        "translationX,translationY,width,height,rotation,scale,opacity,zIndex");
            details.Bool("descriptorStandardLayout", std::is_standard_layout<GlesOverlayLayerDescriptor>::value);
            details.U64("descriptorSizeBytes", sizeof(GlesOverlayLayerDescriptor));
            if (!structParityOk) fail("struct_parity_failed");
        }
    }

    // ── Teardown: every object this diagnostic created ─────────────────────
    if (egl.display != EGL_NO_DISPLAY && egl.context != EGL_NO_CONTEXT) {
        GLuint owned[6] = {solidRed, solidBlue, solidGreen, halfGreen, quadA, oesName};
        for (GLuint t : owned) {
            if (t != 0) glDeleteTextures(1, &t);
        }
        DrainGlErrors();
    }
    egl.Teardown();

    const bool lanesPass =
        eglSetupOk &&
        invalidTextureRejectedOk && invalidDimensionsRejectedOk &&
        nonFiniteTransformRejectedOk && invalidOpacityRejectedOk && unsupportedTargetRejectedOk &&
        singleLayerTransformOk && opacityBlendOk && multiLayerZOrderOk &&
        texture2dTargetAcceptedOk && oesTargetStructuralOk && unsupportedTargetStillRejectedOk &&
        blendStateRestoredOk && viewportRestoredOk && glStateRestoredOk &&
        structParityOk;
    // Canonical route: every lane ran through the private helper against the
    // diagnostic-owned pbuffer with no lane skipped or substituted.
    canonical = lanesPass && failureReason.empty();
    const bool allNativeLanesPass = lanesPass && canonical;

    std::ostringstream oss;
    oss << "{"
        << "\"pass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"status\":\"" << (allNativeLanesPass ? "PASS" : "FAIL") << "\","
        << "\"marker\":\"" << (allNativeLanesPass ? kPassMarker : kFailMarker) << "\","
        << "\"proofBoundary\":\"" << kProofBoundary << "\","
        << "\"failureReason\":\"" << JsonEscape(failureReason) << "\","
        << "\"eglSetupOk\":" << BoolStr(eglSetupOk) << ","
        << "\"invalidTextureRejectedOk\":" << BoolStr(invalidTextureRejectedOk) << ","
        << "\"invalidDimensionsRejectedOk\":" << BoolStr(invalidDimensionsRejectedOk) << ","
        << "\"nonFiniteTransformRejectedOk\":" << BoolStr(nonFiniteTransformRejectedOk) << ","
        << "\"invalidOpacityRejectedOk\":" << BoolStr(invalidOpacityRejectedOk) << ","
        << "\"unsupportedTargetRejectedOk\":" << BoolStr(unsupportedTargetRejectedOk) << ","
        << "\"singleLayerTransformOk\":" << BoolStr(singleLayerTransformOk) << ","
        << "\"opacityBlendOk\":" << BoolStr(opacityBlendOk) << ","
        << "\"multiLayerZOrderOk\":" << BoolStr(multiLayerZOrderOk) << ","
        << "\"texture2dTargetAcceptedOk\":" << BoolStr(texture2dTargetAcceptedOk) << ","
        << "\"oesTargetStructuralOk\":" << BoolStr(oesTargetStructuralOk) << ","
        << "\"unsupportedTargetStillRejectedOk\":" << BoolStr(unsupportedTargetStillRejectedOk) << ","
        << "\"blendStateRestoredOk\":" << BoolStr(blendStateRestoredOk) << ","
        << "\"viewportRestoredOk\":" << BoolStr(viewportRestoredOk) << ","
        << "\"glStateRestoredOk\":" << BoolStr(glStateRestoredOk) << ","
        << "\"structParityOk\":" << BoolStr(structParityOk) << ","
        << "\"canonical\":" << BoolStr(canonical) << ","
        << "\"allNativeLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"nativeAllLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"details\":" << details.Json()
        << "}";

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
