// P5-COMPOSITOR-TRANS (sub-slice GLES-RENDER): GlesTimelineTransitionCompositor
// shader/raster proof diagnostic JNI bridge.
//
// Android-only translation unit added via the CMake target_sources block.
// This is the composition root that bridges vanguard::compositors'
// ComputeTransitionGeometry() (compositor-owned pure transition math from the
// verified P5-COMPOSITOR-TRANS-NODE-TOPOLOGY-MATH sub-slice) to the private
// vanguard::render::GlesTimelineTransitionCompositor raster helper. Neither
// vanguard_render_gles nor the compositors library include each other; only
// this JNI translation unit links them together.
//
// The diagnostic owns a temporary EGL pbuffer context and synthetic
// GL_TEXTURE_2D textures created solely for proof on the calling thread,
// draws every transition family through the helper, reads pixels back with
// glReadPixels, gates the result against hard-coded expected pixel ownership
// tables, and tears down every EGL/GL object it created before returning.
//
// Non-claim: shader/raster proof only. No Vulkan pipeline or SPIR-V, no
// MediaCodec decode or dual decoder sync, no SurfaceTexture/decoder OES frame
// proof (the OES sampler route is proven structurally: target validation plus
// shader compile/link against a never-imaged external texture name), no
// production export route, no AndroidTimelineExportSession change, no
// app/editor UI.
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   runAndroidDagPhase5TimelineTransitionGlesRenderSmoke -> jstring (JSON)

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
#include <vector>

#include "gles_timeline_transition_compositor.h"
#include "vanguard/compositors/vg_timeline_compositor_node.h"

namespace {

using vanguard::compositors::ComputeTransitionGeometry;
using vanguard::compositors::TimelineNormalizedRect;
using vanguard::compositors::TimelineTransitionProgress;
using vanguard::compositors::TransitionType;
using vanguard::render::GlesTimelineNormalizedRect;
using vanguard::render::GlesTimelineTransitionCompositor;
using vanguard::render::GlesTimelineTransitionGeometry;

constexpr const char* kProofBoundary =
    "native_gles_timeline_transition_compositor_shader_raster_only_no_vulkan_no_decode_no_export";
constexpr const char* kPassMarker =
    "ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_GLES_RENDER_PHYSICAL_SMOKE_PASS";
constexpr const char* kFailMarker =
    "ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_GLES_RENDER_PHYSICAL_SMOKE_FAIL";

constexpr uint32_t kSurfaceWidth  = 64;
constexpr uint32_t kSurfaceHeight = 64;
constexpr int      kColorTolerance = 8;

constexpr uint32_t kTarget2D        = 0x0DE1; // GL_TEXTURE_2D
constexpr uint32_t kTargetOes       = 0x8D65; // GL_TEXTURE_EXTERNAL_OES
constexpr uint32_t kTargetCubeMap   = 0x8513; // GL_TEXTURE_CUBE_MAP (unsupported)

constexpr const char* kErrInvalidArgument   = "gles_timeline_transition_compositor_invalid_argument";
constexpr const char* kErrInvalidProgress   = "gles_timeline_transition_compositor_invalid_progress";
constexpr const char* kErrInvalidWeight     = "gles_timeline_transition_compositor_invalid_blend_weight";
constexpr const char* kErrUnsupportedTarget = "gles_timeline_transition_compositor_unsupported_texture_target";
constexpr const char* kErrCompileFailed     = "gles_timeline_transition_compositor_shader_compile_failed";
constexpr const char* kErrLinkFailed        = "gles_timeline_transition_compositor_program_link_failed";

struct Rgb {
    uint8_t r;
    uint8_t g;
    uint8_t b;
};

constexpr Rgb kRed      = {255, 0, 0};
constexpr Rgb kYellow   = {255, 255, 0};
constexpr Rgb kMagenta  = {255, 0, 255};
constexpr Rgb kWhite    = {255, 255, 255};
constexpr Rgb kBlue     = {0, 0, 255};
constexpr Rgb kCyan     = {0, 255, 255};
constexpr Rgb kGreen    = {0, 255, 0};
constexpr Rgb kBlack    = {0, 0, 0};
constexpr Rgb kPurple   = {128, 0, 128}; // crossfade midpoint of red/blue
// Fade (two-phase dip to black) expectations over the same solid red -> blue
// pair: quarter = red at half weight, midpoint = black, three-quarter = blue
// at half weight.
constexpr Rgb kFadeHalfRed  = {128, 0, 0};
constexpr Rgb kFadeBlack    = {0, 0, 0};
constexpr Rgb kFadeHalfBlue = {0, 0, 128};
constexpr Rgb kSentinel = {40, 40, 40};  // clear color; must never survive a tiling draw

// Quadrant texture A (from): TL red, TR yellow, BL magenta, BR white.
// Quadrant texture B (to):   TL blue, TR cyan, BL green, BR black.
// Every A texel has R == 255 and every B texel has R == 0, so layer
// ownership is readable from the red channel alone.
struct QuadColors {
    Rgb tl;
    Rgb tr;
    Rgb bl;
    Rgb br;
};
constexpr QuadColors kQuadA = {kRed, kYellow, kMagenta, kWhite};
constexpr QuadColors kQuadB = {kBlue, kCyan, kGreen, kBlack};

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

void PutTexel(uint8_t* texel, Rgb c) {
    texel[0] = c.r;
    texel[1] = c.g;
    texel[2] = c.b;
    texel[3] = 255;
}

// 2x2 RGBA GL_TEXTURE_2D, NEAREST/CLAMP. Data rows are uploaded bottom-up
// (GL convention: texel row 0 is the bottom), matching the helper's V flip so
// that crop.y == 0 selects `tl`/`tr`.
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

GLuint CreateSolidTexture(Rgb c) {
    return CreateQuadrantTexture(QuadColors{c, c, c, c});
}

// ── Geometry conversion (compositor math -> render helper descriptor) ───────

GlesTimelineNormalizedRect ToGlesRect(const TimelineNormalizedRect& r) {
    GlesTimelineNormalizedRect out;
    out.x      = r.x;
    out.y      = r.y;
    out.width  = r.width;
    out.height = r.height;
    return out;
}

GlesTimelineTransitionGeometry ToGlesGeometry(const TimelineTransitionProgress& p) {
    GlesTimelineTransitionGeometry g;
    g.progress        = p.progress;
    g.blendWeightFrom = p.blendWeightFrom;
    g.blendWeightTo   = p.blendWeightTo;
    g.fromViewport    = ToGlesRect(p.fromViewport);
    g.toViewport      = ToGlesRect(p.toViewport);
    g.fromCrop        = ToGlesRect(p.fromCrop);
    g.toCrop          = ToGlesRect(p.toCrop);
    return g;
}

GlesTimelineTransitionGeometry GeometryFor(TransitionType type, double progress) {
    return ToGlesGeometry(ComputeTransitionGeometry(type, progress));
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

bool ColorNear(const uint8_t* p, Rgb expected) {
    return std::abs(static_cast<int>(p[0]) - expected.r) <= kColorTolerance &&
           std::abs(static_cast<int>(p[1]) - expected.g) <= kColorTolerance &&
           std::abs(static_cast<int>(p[2]) - expected.b) <= kColorTolerance;
}

uint64_t Checksum(const std::vector<uint8_t>& px) {
    uint64_t sum = 0;
    for (const uint8_t b : px) sum += b;
    return sum;
}

// Counts pixels NOT within tolerance of `expected` inside the given
// top-left-coordinate rect.
uint32_t CountMismatches(const std::vector<uint8_t>& px,
                         uint32_t x0, uint32_t y0, uint32_t x1, uint32_t y1,
                         Rgb expected) {
    uint32_t mismatches = 0;
    for (uint32_t y = y0; y < y1; ++y) {
        for (uint32_t x = x0; x < x1; ++x) {
            if (!ColorNear(PixelAt(px, x, y), expected)) ++mismatches;
        }
    }
    return mismatches;
}

uint32_t CountUniformMismatches(const std::vector<uint8_t>& px, Rgb expected) {
    return CountMismatches(px, 0, 0, kSurfaceWidth, kSurfaceHeight, expected);
}

// Canvas quadrant mismatch count against an expected ownership table.
struct QuadrantMismatches {
    uint32_t tl = 0;
    uint32_t tr = 0;
    uint32_t bl = 0;
    uint32_t br = 0;
    uint32_t total() const { return tl + tr + bl + br; }
};

QuadrantMismatches CountQuadrantMismatches(const std::vector<uint8_t>& px, const QuadColors& expected) {
    const uint32_t hw = kSurfaceWidth / 2;
    const uint32_t hh = kSurfaceHeight / 2;
    QuadrantMismatches m;
    m.tl = CountMismatches(px, 0,  0,  hw,            hh,             expected.tl);
    m.tr = CountMismatches(px, hw, 0,  kSurfaceWidth, hh,             expected.tr);
    m.bl = CountMismatches(px, 0,  hh, hw,            kSurfaceHeight, expected.bl);
    m.br = CountMismatches(px, hw, hh, kSurfaceWidth, kSurfaceHeight, expected.br);
    return m;
}

std::string RgbString(const uint8_t* p) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%u,%u,%u", p[0], p[1], p[2]);
    return buf;
}

// Clear -> draw -> read. Returns false (with `outError`) when the draw or
// readback fails.
bool RenderAndRead(GlesTimelineTransitionCompositor& compositor,
                   GLuint textureFrom,
                   GLuint textureTo,
                   const GlesTimelineTransitionGeometry& geometry,
                   std::vector<uint8_t>& outPixels,
                   std::string* outError) {
    DrainGlErrors();
    ClearSentinel();
    if (!compositor.drawTransition(textureFrom, kTarget2D, textureTo, kTarget2D,
                                   kSurfaceWidth, kSurfaceHeight, geometry, outError)) {
        return false;
    }
    if (!ReadSurface(outPixels)) {
        *outError = "read_pixels_failed";
        return false;
    }
    return true;
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

// Runs one slide/wipe family at p=0.5 and gates the canvas quadrant ownership
// table. Records mismatch counts and checksum under `<name>*` detail keys.
bool RunQuadrantCase(GlesTimelineTransitionCompositor& compositor,
                     GLuint quadA,
                     GLuint quadB,
                     TransitionType type,
                     const QuadColors& expected,
                     const char* name,
                     DetailsBuilder& details,
                     std::string* outFailure) {
    std::vector<uint8_t> px;
    std::string err;
    const std::string keyBase = name;
    if (!RenderAndRead(compositor, quadA, quadB, GeometryFor(type, 0.5), px, &err)) {
        details.Str((keyBase + "Error").c_str(), err);
        *outFailure = keyBase + "_draw_failed:" + err;
        return false;
    }
    const QuadrantMismatches m = CountQuadrantMismatches(px, expected);
    const uint32_t sentinelLeft = static_cast<uint32_t>(kSurfaceWidth * kSurfaceHeight) -
        CountUniformMismatches(px, kSentinel);
    details.U64((keyBase + "MismatchTl").c_str(), m.tl);
    details.U64((keyBase + "MismatchTr").c_str(), m.tr);
    details.U64((keyBase + "MismatchBl").c_str(), m.bl);
    details.U64((keyBase + "MismatchBr").c_str(), m.br);
    details.U64((keyBase + "SentinelPixels").c_str(), sentinelLeft);
    details.Str((keyBase + "Checksum").c_str(), std::to_string(Checksum(px)));
    details.Str((keyBase + "ProbeTl").c_str(), RgbString(PixelAt(px, kSurfaceWidth / 4, kSurfaceHeight / 4)));
    details.Str((keyBase + "ProbeTr").c_str(), RgbString(PixelAt(px, 3 * kSurfaceWidth / 4, kSurfaceHeight / 4)));
    details.Str((keyBase + "ProbeBl").c_str(), RgbString(PixelAt(px, kSurfaceWidth / 4, 3 * kSurfaceHeight / 4)));
    details.Str((keyBase + "ProbeBr").c_str(), RgbString(PixelAt(px, 3 * kSurfaceWidth / 4, 3 * kSurfaceHeight / 4)));
    const bool ok = m.total() == 0 && sentinelLeft == 0;
    if (!ok) {
        *outFailure = keyBase + "_pixel_ownership_mismatch";
    }
    return ok;
}

// Runs one uniform-result case (crossfade instant or hard cut) and gates
// every canvas pixel against `expected`.
bool RunUniformCase(GlesTimelineTransitionCompositor& compositor,
                    GLuint solidFrom,
                    GLuint solidTo,
                    TransitionType type,
                    double progress,
                    Rgb expected,
                    const char* name,
                    DetailsBuilder& details,
                    std::string* outFailure) {
    std::vector<uint8_t> px;
    std::string err;
    const std::string keyBase = name;
    if (!RenderAndRead(compositor, solidFrom, solidTo, GeometryFor(type, progress), px, &err)) {
        details.Str((keyBase + "Error").c_str(), err);
        *outFailure = keyBase + "_draw_failed:" + err;
        return false;
    }
    const uint32_t mismatches = CountUniformMismatches(px, expected);
    details.U64((keyBase + "Mismatches").c_str(), mismatches);
    details.Str((keyBase + "Checksum").c_str(), std::to_string(Checksum(px)));
    details.Str((keyBase + "CenterRgb").c_str(), RgbString(PixelAt(px, kSurfaceWidth / 2, kSurfaceHeight / 2)));
    const bool ok = mismatches == 0;
    if (!ok) {
        *outFailure = keyBase + "_color_mismatch";
    }
    return ok;
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase5TimelineTransitionGlesRenderSmoke(
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
    bool nonFiniteProgressRejectedOk = false;
    bool nonFiniteWeightRejectedOk = false;
    bool unsupportedTargetRejectedOk = false;
    bool hardCutNoneOk = false;
    bool crossfadeStartOk = false;
    bool crossfadeMidOk = false;
    bool crossfadeEndOk = false;
    bool fadeStartOk = false, fadeQuarterOk = false, fadeMidOk = false;
    bool fadeThreeQuarterOk = false, fadeEndOk = false;
    bool slideLeftOk = false, slideRightOk = false, slideUpOk = false, slideDownOk = false;
    bool wipeLeftOk = false, wipeRightOk = false, wipeUpOk = false, wipeDownOk = false;
    bool texture2dTargetAcceptedOk = false;
    bool oesTargetStructuralOk = false;
    bool unsupportedTargetStillRejectedOk = false;
    bool viewportRestoredOk = false;
    bool glStateRestoredOk = false;

    EglScratch egl;
    GLuint solidRed = 0, solidBlue = 0, quadA = 0, quadB = 0;
    GLuint oesNameFrom = 0, oesNameTo = 0;

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

        solidRed  = CreateSolidTexture(kRed);
        solidBlue = CreateSolidTexture(kBlue);
        quadA     = CreateQuadrantTexture(kQuadA);
        quadB     = CreateQuadrantTexture(kQuadB);
        // Fresh, never-bound names for the structural OES lane; the helper's
        // first glBindTexture(GL_TEXTURE_EXTERNAL_OES, name) defines them as
        // external textures with no image (samples as opaque black).
        GLuint oesNames[2] = {0, 0};
        glGenTextures(2, oesNames);
        oesNameFrom = oesNames[0];
        oesNameTo   = oesNames[1];
        if (solidRed == 0 || solidBlue == 0 || quadA == 0 || quadB == 0 ||
            oesNameFrom == 0 || oesNameTo == 0) {
            eglSetupOk = false;
            fail("synthetic_texture_creation_failed");
        }
    }

    GlesTimelineTransitionCompositor compositor;

    if (eglSetupOk) {
        // ── Lane 1: parameter validation (fail closed, no GL calls) ────────
        const GlesTimelineTransitionGeometry xfadeMid = GeometryFor(TransitionType::kCrossfade, 0.5);
        std::string err;
        DrainGlErrors();

        bool ok = !compositor.drawTransition(0, kTarget2D, solidBlue, kTarget2D,
                                             kSurfaceWidth, kSurfaceHeight, xfadeMid, &err) &&
                  err == kErrInvalidArgument;
        ok = ok && !compositor.drawTransition(solidRed, kTarget2D, 0, kTarget2D,
                                              kSurfaceWidth, kSurfaceHeight, xfadeMid, &err) &&
             err == kErrInvalidArgument;
        invalidTextureRejectedOk = ok;
        details.Str("invalidTextureError", err);

        ok = !compositor.drawTransition(solidRed, kTarget2D, solidBlue, kTarget2D,
                                        0, kSurfaceHeight, xfadeMid, &err) &&
             err == kErrInvalidArgument;
        ok = ok && !compositor.drawTransition(solidRed, kTarget2D, solidBlue, kTarget2D,
                                              kSurfaceWidth, 0, xfadeMid, &err) &&
             err == kErrInvalidArgument;
        invalidDimensionsRejectedOk = ok;
        details.Str("invalidDimensionsError", err);

        GlesTimelineTransitionGeometry nanProgress = xfadeMid;
        nanProgress.progress = std::numeric_limits<double>::quiet_NaN();
        ok = !compositor.drawTransition(solidRed, kTarget2D, solidBlue, kTarget2D,
                                        kSurfaceWidth, kSurfaceHeight, nanProgress, &err) &&
             err == kErrInvalidProgress;
        GlesTimelineTransitionGeometry infProgress = xfadeMid;
        infProgress.progress = std::numeric_limits<double>::infinity();
        ok = ok && !compositor.drawTransition(solidRed, kTarget2D, solidBlue, kTarget2D,
                                              kSurfaceWidth, kSurfaceHeight, infProgress, &err) &&
             err == kErrInvalidProgress;
        nonFiniteProgressRejectedOk = ok;
        details.Str("nonFiniteProgressError", err);

        GlesTimelineTransitionGeometry nanWeight = xfadeMid;
        nanWeight.blendWeightTo = std::numeric_limits<double>::quiet_NaN();
        ok = !compositor.drawTransition(solidRed, kTarget2D, solidBlue, kTarget2D,
                                        kSurfaceWidth, kSurfaceHeight, nanWeight, &err) &&
             err == kErrInvalidWeight;
        GlesTimelineTransitionGeometry infWeight = xfadeMid;
        infWeight.blendWeightFrom = -std::numeric_limits<double>::infinity();
        ok = ok && !compositor.drawTransition(solidRed, kTarget2D, solidBlue, kTarget2D,
                                              kSurfaceWidth, kSurfaceHeight, infWeight, &err) &&
             err == kErrInvalidWeight;
        nonFiniteWeightRejectedOk = ok;
        details.Str("nonFiniteWeightError", err);

        ok = !compositor.drawTransition(solidRed, 0, solidBlue, kTarget2D,
                                        kSurfaceWidth, kSurfaceHeight, xfadeMid, &err) &&
             err == kErrUnsupportedTarget;
        ok = ok && !compositor.drawTransition(solidRed, kTarget2D, solidBlue, kTargetCubeMap,
                                              kSurfaceWidth, kSurfaceHeight, xfadeMid, &err) &&
             err == kErrUnsupportedTarget;
        unsupportedTargetRejectedOk = ok;
        unsupportedTargetStillRejectedOk = ok;
        details.Str("unsupportedTargetError", err);

        const bool noGlErrorAfterValidation = glGetError() == GL_NO_ERROR;
        details.Bool("noGlErrorAfterValidation", noGlErrorAfterValidation);
        if (!noGlErrorAfterValidation) {
            invalidTextureRejectedOk = false;
            invalidDimensionsRejectedOk = false;
            nonFiniteProgressRejectedOk = false;
            nonFiniteWeightRejectedOk = false;
            unsupportedTargetRejectedOk = false;
            unsupportedTargetStillRejectedOk = false;
        }
        if (!invalidTextureRejectedOk)     fail("invalid_texture_not_rejected");
        if (!invalidDimensionsRejectedOk)  fail("invalid_dimensions_not_rejected");
        if (!nonFiniteProgressRejectedOk)  fail("non_finite_progress_not_rejected");
        if (!nonFiniteWeightRejectedOk)    fail("non_finite_weight_not_rejected");
        if (!unsupportedTargetRejectedOk)  fail("unsupported_target_not_rejected");

        // ── Lane 2: hard cut + crossfade start / mid / end ─────────────────
        std::string laneFailure;
        hardCutNoneOk = RunUniformCase(compositor, solidRed, solidBlue, TransitionType::kNone, 0.7,
                                       kRed, "hardCutNone", details, &laneFailure);
        if (!hardCutNoneOk) fail(laneFailure);
        crossfadeStartOk = RunUniformCase(compositor, solidRed, solidBlue, TransitionType::kCrossfade, 0.0,
                                          kRed, "crossfadeStart", details, &laneFailure);
        if (!crossfadeStartOk) fail(laneFailure);
        crossfadeMidOk = RunUniformCase(compositor, solidRed, solidBlue, TransitionType::kCrossfade, 0.5,
                                        kPurple, "crossfadeMid", details, &laneFailure);
        if (!crossfadeMidOk) fail(laneFailure);
        crossfadeEndOk = RunUniformCase(compositor, solidRed, solidBlue, TransitionType::kCrossfade, 1.0,
                                        kBlue, "crossfadeEnd", details, &laneFailure);
        if (!crossfadeEndOk) fail(laneFailure);

        // ── Lane 2b: fade (dip to black) start / quarter / mid / three-quarter / end ──
        // Single-sided partial weights must render the layer scaled over black,
        // never as an opaque from-only / to-only frame; the midpoint is black.
        fadeStartOk = RunUniformCase(compositor, solidRed, solidBlue, TransitionType::kFade, 0.0,
                                     kRed, "fadeStart", details, &laneFailure);
        if (!fadeStartOk) fail(laneFailure);
        fadeQuarterOk = RunUniformCase(compositor, solidRed, solidBlue, TransitionType::kFade, 0.25,
                                       kFadeHalfRed, "fadeQuarter", details, &laneFailure);
        if (!fadeQuarterOk) fail(laneFailure);
        fadeMidOk = RunUniformCase(compositor, solidRed, solidBlue, TransitionType::kFade, 0.5,
                                   kFadeBlack, "fadeMid", details, &laneFailure);
        if (!fadeMidOk) fail(laneFailure);
        fadeThreeQuarterOk = RunUniformCase(compositor, solidRed, solidBlue, TransitionType::kFade, 0.75,
                                            kFadeHalfBlue, "fadeThreeQuarter", details, &laneFailure);
        if (!fadeThreeQuarterOk) fail(laneFailure);
        fadeEndOk = RunUniformCase(compositor, solidRed, solidBlue, TransitionType::kFade, 1.0,
                                   kBlue, "fadeEnd", details, &laneFailure);
        if (!fadeEndOk) fail(laneFailure);

        // ── Lane 3: slides at p=0.5 (viewport translation, clipped UVs) ────
        // Expected canvas quadrant ownership derived by hand from
        // ComputeTransitionGeometry: slide-left shows A's right half on the
        // canvas left and B's left half on the canvas right, etc.
        slideLeftOk = RunQuadrantCase(compositor, quadA, quadB, TransitionType::kSlideLeft,
                                      QuadColors{kQuadA.tr, kQuadB.tl, kQuadA.br, kQuadB.bl},
                                      "slideLeft", details, &laneFailure);
        if (!slideLeftOk) fail(laneFailure);
        slideRightOk = RunQuadrantCase(compositor, quadA, quadB, TransitionType::kSlideRight,
                                       QuadColors{kQuadB.tr, kQuadA.tl, kQuadB.br, kQuadA.bl},
                                       "slideRight", details, &laneFailure);
        if (!slideRightOk) fail(laneFailure);
        slideUpOk = RunQuadrantCase(compositor, quadA, quadB, TransitionType::kSlideUp,
                                    QuadColors{kQuadA.bl, kQuadA.br, kQuadB.tl, kQuadB.tr},
                                    "slideUp", details, &laneFailure);
        if (!slideUpOk) fail(laneFailure);
        slideDownOk = RunQuadrantCase(compositor, quadA, quadB, TransitionType::kSlideDown,
                                      QuadColors{kQuadB.bl, kQuadB.br, kQuadA.tl, kQuadA.tr},
                                      "slideDown", details, &laneFailure);
        if (!slideDownOk) fail(laneFailure);

        // Viewport + GL state restoration after sub-rect layer draws.
        {
            GLint vp[4] = {-1, -1, -1, -1};
            glGetIntegerv(GL_VIEWPORT, vp);
            viewportRestoredOk = vp[0] == 0 && vp[1] == 0 &&
                                 vp[2] == static_cast<GLint>(kSurfaceWidth) &&
                                 vp[3] == static_cast<GLint>(kSurfaceHeight);
            details.Str("viewportAfterSlide",
                        std::to_string(vp[0]) + "," + std::to_string(vp[1]) + "," +
                        std::to_string(vp[2]) + "," + std::to_string(vp[3]));
            if (!viewportRestoredOk) fail("viewport_not_restored");

            GLint program = -1, arrayBuffer = -1, activeTexture = -1;
            GLint binding0 = -1, binding1 = -1;
            glGetIntegerv(GL_CURRENT_PROGRAM, &program);
            glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &arrayBuffer);
            glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
            glActiveTexture(GL_TEXTURE0);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &binding0);
            glActiveTexture(GL_TEXTURE1);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &binding1);
            glActiveTexture(GL_TEXTURE0);
            glStateRestoredOk = program == 0 && arrayBuffer == 0 &&
                                activeTexture == GL_TEXTURE0 &&
                                binding0 == 0 && binding1 == 0 &&
                                glGetError() == GL_NO_ERROR;
            details.Int("currentProgramAfterDraw", program);
            details.Int("arrayBufferBindingAfterDraw", arrayBuffer);
            details.Bool("activeTextureUnit0AfterDraw", activeTexture == GL_TEXTURE0);
            details.Int("texture2dBindingUnit0AfterDraw", binding0);
            details.Int("texture2dBindingUnit1AfterDraw", binding1);
            if (!glStateRestoredOk) fail("gl_state_not_restored");
        }

        // ── Lane 4: wipes at p=0.5 (identity viewport, complementary crops) ─
        wipeLeftOk = RunQuadrantCase(compositor, quadA, quadB, TransitionType::kWipeLeft,
                                     QuadColors{kQuadA.tl, kQuadB.tr, kQuadA.bl, kQuadB.br},
                                     "wipeLeft", details, &laneFailure);
        if (!wipeLeftOk) fail(laneFailure);
        wipeRightOk = RunQuadrantCase(compositor, quadA, quadB, TransitionType::kWipeRight,
                                      QuadColors{kQuadB.tl, kQuadA.tr, kQuadB.bl, kQuadA.br},
                                      "wipeRight", details, &laneFailure);
        if (!wipeRightOk) fail(laneFailure);
        wipeUpOk = RunQuadrantCase(compositor, quadA, quadB, TransitionType::kWipeUp,
                                   QuadColors{kQuadA.tl, kQuadA.tr, kQuadB.bl, kQuadB.br},
                                   "wipeUp", details, &laneFailure);
        if (!wipeUpOk) fail(laneFailure);
        wipeDownOk = RunQuadrantCase(compositor, quadA, quadB, TransitionType::kWipeDown,
                                     QuadColors{kQuadB.tl, kQuadB.tr, kQuadA.bl, kQuadA.br},
                                     "wipeDown", details, &laneFailure);
        if (!wipeDownOk) fail(laneFailure);

        // ── Lane 5: texture targets ────────────────────────────────────────
        // GL_TEXTURE_2D fully accepted: every lane 2-4 draw above went
        // through the 2D+2D route.
        texture2dTargetAcceptedOk = hardCutNoneOk && crossfadeStartOk && crossfadeMidOk &&
                                    crossfadeEndOk && fadeStartOk && fadeQuarterOk && fadeMidOk && fadeThreeQuarterOk && fadeEndOk &&
                                    slideLeftOk && slideRightOk &&
                                    slideUpOk && slideDownOk && wipeLeftOk && wipeRightOk &&
                                    wipeUpOk && wipeDownOk;
        if (!texture2dTargetAcceptedOk) fail("texture_2d_target_route_not_fully_accepted");

        // GL_TEXTURE_EXTERNAL_OES structural route: every sampler permutation
        // (OES from / OES to / both; mix, opaque-layer and weighted fade-layer
        // shaders) must pass target validation and, where the extension
        // exists, compile/link.
        // Never-imaged external texture names are used; no SurfaceTexture or
        // decoder OES frame is claimed.
        {
            struct OesCase {
                const char* name;
                uint32_t targetFrom;
                uint32_t targetTo;
                TransitionType type;
                double progress;
            };
            const OesCase cases[] = {
                {"oesFromMix",     kTargetOes, kTarget2D,  TransitionType::kCrossfade, 0.5},
                {"oesToMix",       kTarget2D,  kTargetOes, TransitionType::kCrossfade, 0.5},
                {"oesBothMix",     kTargetOes, kTargetOes, TransitionType::kCrossfade, 0.5},
                {"oesFromOpaque",  kTargetOes, kTarget2D,  TransitionType::kSlideLeft, 0.5},
                {"oesToOpaque",    kTarget2D,  kTargetOes, TransitionType::kWipeLeft,  0.5},
                // Weighted single-sampler (fade half-phase) shader, OES on the
                // faded side: first half fades "from", second half fades "to".
                {"oesFromFade",    kTargetOes, kTarget2D,  TransitionType::kFade,      0.25},
                {"oesToFade",      kTarget2D,  kTargetOes, TransitionType::kFade,      0.75},
            };
            bool structuralOk = true;
            for (const OesCase& c : cases) {
                DrainGlErrors();
                ClearSentinel();
                std::string oesErr;
                const GLuint texFrom = c.targetFrom == kTargetOes ? oesNameFrom : solidRed;
                const GLuint texTo   = c.targetTo == kTargetOes ? oesNameTo : solidBlue;
                const bool drawOk = compositor.drawTransition(
                    texFrom, c.targetFrom, texTo, c.targetTo,
                    kSurfaceWidth, kSurfaceHeight, GeometryFor(c.type, c.progress), &oesErr);
                const bool rejectedAsUnsupported = oesErr == kErrUnsupportedTarget;
                const bool compileOrLinkFailed = oesErr == kErrCompileFailed || oesErr == kErrLinkFailed;
                details.Bool((std::string(c.name) + "DrawOk").c_str(), drawOk);
                details.Str((std::string(c.name) + "Error").c_str(), oesErr);
                if (rejectedAsUnsupported) structuralOk = false;
                if (oesExtensionAvailable && compileOrLinkFailed) structuralOk = false;
                DrainGlErrors();
            }
            oesTargetStructuralOk = structuralOk;
            if (!oesTargetStructuralOk) fail("oes_target_structural_route_failed");
            details.Str("oesProofScope",
                        "structural_target_validation_and_sampler_compile_only_no_surfacetexture_no_decoder_frame");
        }
    }

    // ── Teardown: every object this diagnostic created ─────────────────────
    if (egl.display != EGL_NO_DISPLAY && egl.context != EGL_NO_CONTEXT) {
        GLuint owned[6] = {solidRed, solidBlue, quadA, quadB, oesNameFrom, oesNameTo};
        for (GLuint t : owned) {
            if (t != 0) glDeleteTextures(1, &t);
        }
        DrainGlErrors();
    }
    egl.Teardown();

    const bool allNativeLanesPass =
        eglSetupOk &&
        invalidTextureRejectedOk && invalidDimensionsRejectedOk &&
        nonFiniteProgressRejectedOk && nonFiniteWeightRejectedOk && unsupportedTargetRejectedOk &&
        hardCutNoneOk && crossfadeStartOk && crossfadeMidOk && crossfadeEndOk &&
        fadeStartOk && fadeQuarterOk && fadeMidOk && fadeThreeQuarterOk && fadeEndOk &&
        slideLeftOk && slideRightOk && slideUpOk && slideDownOk &&
        wipeLeftOk && wipeRightOk && wipeUpOk && wipeDownOk &&
        texture2dTargetAcceptedOk && oesTargetStructuralOk && unsupportedTargetStillRejectedOk &&
        viewportRestoredOk && glStateRestoredOk;

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
        << "\"nonFiniteProgressRejectedOk\":" << BoolStr(nonFiniteProgressRejectedOk) << ","
        << "\"nonFiniteWeightRejectedOk\":" << BoolStr(nonFiniteWeightRejectedOk) << ","
        << "\"unsupportedTargetRejectedOk\":" << BoolStr(unsupportedTargetRejectedOk) << ","
        << "\"hardCutNoneOk\":" << BoolStr(hardCutNoneOk) << ","
        << "\"crossfadeStartOk\":" << BoolStr(crossfadeStartOk) << ","
        << "\"crossfadeMidOk\":" << BoolStr(crossfadeMidOk) << ","
        << "\"crossfadeEndOk\":" << BoolStr(crossfadeEndOk) << ","
        << "\"fadeStartOk\":" << BoolStr(fadeStartOk) << ","
        << "\"fadeQuarterOk\":" << BoolStr(fadeQuarterOk) << ","
        << "\"fadeMidOk\":" << BoolStr(fadeMidOk) << ","
        << "\"fadeThreeQuarterOk\":" << BoolStr(fadeThreeQuarterOk) << ","
        << "\"fadeEndOk\":" << BoolStr(fadeEndOk) << ","
        << "\"slideLeftOk\":" << BoolStr(slideLeftOk) << ","
        << "\"slideRightOk\":" << BoolStr(slideRightOk) << ","
        << "\"slideUpOk\":" << BoolStr(slideUpOk) << ","
        << "\"slideDownOk\":" << BoolStr(slideDownOk) << ","
        << "\"wipeLeftOk\":" << BoolStr(wipeLeftOk) << ","
        << "\"wipeRightOk\":" << BoolStr(wipeRightOk) << ","
        << "\"wipeUpOk\":" << BoolStr(wipeUpOk) << ","
        << "\"wipeDownOk\":" << BoolStr(wipeDownOk) << ","
        << "\"texture2dTargetAcceptedOk\":" << BoolStr(texture2dTargetAcceptedOk) << ","
        << "\"oesTargetStructuralOk\":" << BoolStr(oesTargetStructuralOk) << ","
        << "\"unsupportedTargetStillRejectedOk\":" << BoolStr(unsupportedTargetStillRejectedOk) << ","
        << "\"viewportRestoredOk\":" << BoolStr(viewportRestoredOk) << ","
        << "\"glStateRestoredOk\":" << BoolStr(glStateRestoredOk) << ","
        << "\"allNativeLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"nativeAllLanesPass\":" << BoolStr(allNativeLanesPass) << ","
        << "\"details\":" << details.Json()
        << "}";

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
