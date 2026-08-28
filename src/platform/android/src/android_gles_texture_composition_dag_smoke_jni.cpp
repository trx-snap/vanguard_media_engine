// Phase 1 Unit BB: Android GLES SurfaceProducer Texture DAG Two-Source
// Composition & Playhead Evaluation Physical Proof JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// Proves a multi-frame two-source synthetic HardwareBuffer DAG/playhead
// evaluation loop (source A -> compositor <- source B -> sink) that renders
// changing blend weights into a real Flutter TextureRegistry.SurfaceProducer
// surface via GlesBackend::diagnosticPresentCompositeFrames(). Per frame, the
// diagnostic Graph is evaluated with Graph::evaluatePlayhead() to gate active
// node state and extract the compositor node's blendWeightAt() weight; that
// weight is then manually supplied, alongside the two AHardwareBuffer
// handles already imported directly into the backend, to
// diagnosticPresentCompositeFrames(). The Graph itself never transports
// pixel/handle data end-to-end; this translation unit performs that wiring
// manually after each evaluation.
//
// Non-claim: diagnostic-only foundation; no MediaCodec decoded input, no
// ImageReader.PRIVATE, no product UI, no ConnectsApp wiring, no Phase 1
// closure.
//
// Phase 1-Unit BC extends this entry point with a diagnostic-only
// frameDelayMs argument (default 0, BB-compatible), matching the Unit AY
// pattern: after each successful diagnosticPresentCompositeFrames() call the
// loop sleeps for frameDelayMs milliseconds, holding the worker active long
// enough for an active-dispose/cancellation physical proof. The native loop
// always finishes its delayed iterations; it is never preemptively
// interrupted.
//
// Phase 1-Unit BD extends this entry point with independent per-source
// rotationDegrees/mirrorHorizontal render-transform arguments (default 0 /
// false, BB/BC-compatible), matching the Unit AZ pattern. Each source's raw
// transform is passed to diagnosticPresentCompositeFrames() exactly as
// received; vanguard::render::normalizeRotation is used only to populate the
// diagnostic normalizedRotationDegreesA/B status fields.
//
// Phase 1-Unit BE extends this entry point with independent per-source
// sourceKindA/sourceKindB string arguments ("2d" or "oes", default "2d",
// BB/BC/BD-compatible), proving all four source target permutations (2D+2D,
// OES+2D, 2D+OES, OES+OES). A "2d" source is validated as an RGBA_8888
// descriptor with GPU_SAMPLED_IMAGE|CPU_WRITE_OFTEN usage, is CPU-filled,
// and is required to import as GL_TEXTURE_2D (0x0DE1/3553). An "oes" source
// is validated as a YCBCR_420_888 descriptor with GPU_SAMPLED_IMAGE-only
// usage, is never CPU-filled, and is required to import as
// GL_TEXTURE_EXTERNAL_OES (0x8D65/36197). Import/release handle usage is
// otherwise identical regardless of source kind.
//
// JNI entry point:
//   runAndroidDagPhase1BBGlesTextureCompositionDagSmoke -> jstring

#include <jni.h>

#include <android/hardware_buffer.h>
#include <android/native_window_jni.h>
#include <android/rect.h>
#include <dlfcn.h>
#include <poll.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/render/gles_backend.h"
#include "vanguard/render/render_transform.h"

namespace {

using FnAHardwareBuffer_fromHardwareBuffer =
    AHardwareBuffer* (*)(JNIEnv*, jobject);
using FnAHardwareBuffer_describe =
    void (*)(const AHardwareBuffer*, AHardwareBuffer_Desc*);
using FnAHardwareBuffer_lock =
    int32_t (*)(AHardwareBuffer*, uint64_t, int32_t, const ARect*, void**);
using FnAHardwareBuffer_unlock =
    int32_t (*)(AHardwareBuffer*, int32_t*);

struct NativeHardwareBufferFunctions {
    FnAHardwareBuffer_fromHardwareBuffer fromHardwareBuffer = nullptr;
    FnAHardwareBuffer_describe describe = nullptr;
    FnAHardwareBuffer_lock lock = nullptr;
    FnAHardwareBuffer_unlock unlock = nullptr;
    bool isValid() const {
        return fromHardwareBuffer && describe && lock && unlock;
    }
};

NativeHardwareBufferFunctions ResolveNativeHardwareBufferFunctions() {
    NativeHardwareBufferFunctions fns;
    void* lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) return fns;

    fns.fromHardwareBuffer = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
        dlsym(lib, "AHardwareBuffer_fromHardwareBuffer"));
    fns.describe = reinterpret_cast<FnAHardwareBuffer_describe>(
        dlsym(lib, "AHardwareBuffer_describe"));
    fns.lock = reinterpret_cast<FnAHardwareBuffer_lock>(
        dlsym(lib, "AHardwareBuffer_lock"));
    fns.unlock = reinterpret_cast<FnAHardwareBuffer_unlock>(
        dlsym(lib, "AHardwareBuffer_unlock"));

    dlclose(lib);
    return fns;
}

std::string SanitizeString(const char* input) {
    if (!input) {
        return "";
    }
    std::string s(input);
    for (char& c : s) {
        if (c == ';' || c == '\n' || c == '\r') {
            c = '_';
        }
    }
    return s;
}

const char* HardwareBufferResultName(
    vanguard::render::HardwareBufferImportResult result) {
    using Result = vanguard::render::HardwareBufferImportResult;
    switch (result) {
        case Result::kSuccess: return "success";
        case Result::kUnavailable: return "unavailable";
        case Result::kBackendNotInitialized: return "backend_not_initialized";
        case Result::kInvalidArgument: return "invalid_argument";
        case Result::kDuplicateImport: return "duplicate_import";
        case Result::kIncompatibleBuffer: return "incompatible_buffer";
        case Result::kVulkanFunctionUnavailable: return "vulkan_function_unavailable";
        case Result::kVulkanFailure: return "vulkan_failure";
        case Result::kUnknownHandle: return "unknown_handle";
    }
    return "unknown";
}

// Fills `buf` with a solid RGBA color via AHardwareBuffer_lock/unlock,
// waiting on and closing any unlock fence, mirroring Unit AS's CPU-fill
// pattern so the rendered blend is deterministic.
bool FillHardwareBufferSolidColor(
    const NativeHardwareBufferFunctions& ahbFns,
    AHardwareBuffer* buf,
    uint32_t width,
    uint32_t height,
    uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    AHardwareBuffer_Desc desc{};
    ahbFns.describe(buf, &desc);
    if (desc.width != width || desc.height != height || desc.stride < desc.width) {
        return false;
    }

    void* writeAddr = nullptr;
    int32_t lockRes = ahbFns.lock(buf, AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN, -1, nullptr, &writeAddr);
    if (lockRes != 0 || !writeAddr) {
        return false;
    }
    uint8_t* base = static_cast<uint8_t*>(writeAddr);
    for (uint32_t y = 0; y < desc.height; ++y) {
        uint8_t* row = base + y * desc.stride * 4;
        for (uint32_t x = 0; x < desc.width; ++x) {
            uint8_t* pixel = row + x * 4;
            pixel[0] = r;
            pixel[1] = g;
            pixel[2] = b;
            pixel[3] = a;
        }
    }
    int32_t fence = -1;
    int32_t unlockRes = ahbFns.unlock(buf, &fence);
    if (unlockRes != 0) {
        return false;
    }
    if (fence >= 0) {
        struct pollfd pfd{};
        pfd.fd = fence;
        pfd.events = POLLIN;
        int pollRes = poll(&pfd, 1, 1000);
        close(fence);
        if (pollRes <= 0 || (pfd.revents & (POLLERR | POLLNVAL))) {
            return false;
        }
    }
    return true;
}

// ── Phase 1 Unit BB: private diagnostic DAG nodes ──────────────────────────
// Local to this translation unit; not part of any product graph session.

class DiagBBHardwareBufferSourceNode final : public vanguard::graph::Node {
public:
    explicit DiagBBHardwareBufferSourceNode(std::string id)
        : id_(std::move(id)) {
        outputPorts_ = {{ "kVideoFrame", vanguard::graph::PortDataType::kVideoFrame }};
    }

    const std::string&                  id()          const override { return id_; }
    vanguard::graph::NodeKind           kind()        const override { return vanguard::graph::NodeKind::kSource; }
    vanguard::graph::NodeType           type()        const override { return vanguard::graph::NodeType::kHardwareBufferSource; }
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override { return inputPorts_; }
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override { return outputPorts_; }

    bool     isActiveAt(uint64_t /*timelinePtsUs*/) const override { return true; }
    uint64_t mapTimelineToLocalPts(uint64_t pts)    const override { return pts; }
    float    blendWeightAt(uint64_t /*pts*/)        const override { return 1.0f; }

private:
    std::string id_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

// Diagnostic compositor node whose blendWeightAt() mirrors the per-frame
// weightB schedule (f / (frameCount - 1), clamped [0, 1]) used to drive
// GlesBackend::diagnosticPresentCompositeFrames() for the same frame.
class DiagBBTimelineCompositorNode final : public vanguard::graph::Node {
public:
    DiagBBTimelineCompositorNode(std::string id, uint64_t frameDurationUs, int frameCount)
        : id_(std::move(id)), frameDurationUs_(frameDurationUs), frameCount_(frameCount) {
        inputPorts_ = {
            { "kVideoFrameA", vanguard::graph::PortDataType::kVideoFrame },
            { "kVideoFrameB", vanguard::graph::PortDataType::kVideoFrame },
        };
        outputPorts_ = {{ "kVideoFrame", vanguard::graph::PortDataType::kVideoFrame }};
    }

    const std::string&                  id()          const override { return id_; }
    vanguard::graph::NodeKind           kind()        const override { return vanguard::graph::NodeKind::kProcessing; }
    vanguard::graph::NodeType           type()        const override { return vanguard::graph::NodeType::kVGTimelineCompositor; }
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override { return inputPorts_; }
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override { return outputPorts_; }

    bool     isActiveAt(uint64_t /*timelinePtsUs*/) const override { return true; }
    uint64_t mapTimelineToLocalPts(uint64_t pts)    const override { return pts; }

    float blendWeightAt(uint64_t timelinePtsUs) const override {
        if (frameCount_ <= 1 || frameDurationUs_ == 0) {
            return 1.0f;
        }
        const uint64_t denom = static_cast<uint64_t>(frameCount_ - 1);
        const uint64_t f = timelinePtsUs / frameDurationUs_;
        if (f >= denom) {
            return 1.0f;
        }
        const float weight = static_cast<float>(f) / static_cast<float>(denom);
        return std::clamp(weight, 0.0f, 1.0f);
    }

private:
    std::string id_;
    uint64_t frameDurationUs_;
    int frameCount_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

class DiagBBTextureSurfaceSinkNode final : public vanguard::graph::Node {
public:
    explicit DiagBBTextureSurfaceSinkNode(std::string id)
        : id_(std::move(id)) {
        inputPorts_ = {{ "kVideoFrame", vanguard::graph::PortDataType::kVideoFrame }};
    }

    const std::string&                  id()          const override { return id_; }
    vanguard::graph::NodeKind           kind()        const override { return vanguard::graph::NodeKind::kSink; }
    vanguard::graph::NodeType           type()        const override { return vanguard::graph::NodeType::kPreviewSurfaceSink; }
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override { return inputPorts_; }
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override { return outputPorts_; }

    bool     isActiveAt(uint64_t /*timelinePtsUs*/) const override { return true; }
    uint64_t mapTimelineToLocalPts(uint64_t pts)    const override { return pts; }
    float    blendWeightAt(uint64_t /*pts*/)        const override { return 1.0f; }

private:
    std::string id_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

constexpr const char* kProofBoundary =
    "gles_surfaceproducer_texture_dag_two_source_composition_no_decoded_input_no_product_ui";

// Phase 1-Unit BE: GL texture target constants required for each source
// kind's import (mirrors GlesBackend::diagnosticTextureTargetForHardwareBuffer).
constexpr uint32_t kGlTextureTarget2D = 0x0DE1;    // GL_TEXTURE_2D
constexpr uint32_t kGlTextureTargetOes = 0x8D65;   // GL_TEXTURE_EXTERNAL_OES

// Normalizes a caller-provided source kind string to the two accepted
// values ("2d"/"oes"); anything else falls back to the BB/BC/BD-compatible
// "2d" default, mirroring the Kotlin-side normalizeSourceKind.
std::string NormalizeSourceKind(const std::string& raw) {
    return (raw == "oes") ? "oes" : "2d";
}

std::string JStringToStdString(JNIEnv* env, jstring str) {
    if (str == nullptr) {
        return "2d";
    }
    const char* chars = env->GetStringUTFChars(str, nullptr);
    if (chars == nullptr) {
        return "2d";
    }
    std::string result(chars);
    env->ReleaseStringUTFChars(str, chars);
    return result;
}

// Validates an AHardwareBuffer_Desc against the expected format/usage for
// the given (already-normalized) source kind.
bool ValidateSourceDescriptor(
    const AHardwareBuffer_Desc& desc,
    const std::string& sourceKind,
    uint32_t width,
    uint32_t height) {
    if (desc.width != width || desc.height != height || desc.layers != 1) {
        return false;
    }
    if (sourceKind == "oes") {
        return (desc.format == AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420) &&
               ((desc.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);
    }
    return (desc.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
           ((desc.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) &&
           ((desc.usage & AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN) != 0) &&
           (desc.stride >= desc.width);
}

const char* BufferFormatLabel(const std::string& sourceKind) {
    return (sourceKind == "oes") ? "ycbcr_420_888" : "rgba_8888";
}

struct BBStatusFields {
    bool pass = false;
    std::string initialize = "not_run";
    std::string attach = "not_run";
    std::string graphBuild = "not_run";
    std::string importA = "not_run";
    std::string importB = "not_run";
    std::string evaluation = "not_run";
    int renderedFrames = 0;
    int frameCount = 0;
    int frameDelayMs = 0;
    int64_t lastEvaluatedPtsUs = 0;
    uint64_t graphGeneration = 0;
    int activeNodeCount = 0;
    bool compositorActive = false;
    float startWeightB = 0.0f;
    float endWeightB = 0.0f;
    bool monotonicWeights = false;
    std::string renderFrame = "not_run";
    int failingFrame = -1;
    std::string releaseA = "not_run";
    std::string releaseB = "not_run";
    int width = 0;
    int height = 0;
    bool textureSurface = false;
    int releaseFenceAFd = -1;
    int releaseFenceBFd = -1;
    bool releaseFenceExported = false;
    // Phase 1-Unit BD: independent per-source diagnostic render-transform
    // status fields. rotationDegrees*/mirrorHorizontal* echo the raw caller
    // input (what the renderer actually receives); normalizedRotationDegrees*
    // is diagnostic-only, via vanguard::render::normalizeRotation.
    int rotationDegreesA = 0;
    bool mirrorHorizontalA = false;
    int normalizedRotationDegreesA = 0;
    int rotationDegreesB = 0;
    bool mirrorHorizontalB = false;
    int normalizedRotationDegreesB = 0;
    // Phase 1-Unit BE: independent per-source kind ("2d"/"oes") status
    // fields proving the two-source DAG smoke over all four source target
    // permutations.
    std::string sourceKindA = "2d";
    std::string sourceKindB = "2d";
    std::string bufferAFormat = "not_run";
    std::string bufferBFormat = "not_run";
    int32_t targetA = -1;
    int32_t targetB = -1;
    std::string bufferFillA = "not_run";
    std::string bufferFillB = "not_run";
    std::string lastError = "none";
};

std::string BuildStatusString(const BBStatusFields& f) {
    std::ostringstream oss;
    oss << std::fixed << std::setprecision(6);
    oss << "status=" << (f.pass ? "PASS" : "FAIL") << ";"
        << "initialize=" << f.initialize << ";"
        << "attach=" << f.attach << ";"
        << "graphBuild=" << f.graphBuild << ";"
        << "importA=" << f.importA << ";"
        << "importB=" << f.importB << ";"
        << "evaluation=" << f.evaluation << ";"
        << "renderedFrames=" << f.renderedFrames << ";"
        << "frameCount=" << f.frameCount << ";"
        << "frameDelayMs=" << f.frameDelayMs << ";"
        << "lastEvaluatedPtsUs=" << f.lastEvaluatedPtsUs << ";"
        << "graphGeneration=" << f.graphGeneration << ";"
        << "activeNodeCount=" << f.activeNodeCount << ";"
        << "compositorActive=" << (f.compositorActive ? "true" : "false") << ";"
        << "startWeightB=" << f.startWeightB << ";"
        << "endWeightB=" << f.endWeightB << ";"
        << "monotonicWeights=" << (f.monotonicWeights ? "true" : "false") << ";"
        << "renderFrame=" << f.renderFrame << ";"
        << "failingFrame=" << f.failingFrame << ";"
        << "releaseA=" << f.releaseA << ";"
        << "releaseB=" << f.releaseB << ";"
        << "width=" << f.width << ";"
        << "height=" << f.height << ";"
        << "textureSurface=" << (f.textureSurface ? "true" : "false") << ";"
        << "releaseFenceAFd=" << f.releaseFenceAFd << ";"
        << "releaseFenceBFd=" << f.releaseFenceBFd << ";"
        << "releaseFenceExported=" << (f.releaseFenceExported ? "true" : "false") << ";"
        << "rotationDegreesA=" << f.rotationDegreesA << ";"
        << "mirrorHorizontalA=" << (f.mirrorHorizontalA ? "true" : "false") << ";"
        << "normalizedRotationDegreesA=" << f.normalizedRotationDegreesA << ";"
        << "rotationDegreesB=" << f.rotationDegreesB << ";"
        << "mirrorHorizontalB=" << (f.mirrorHorizontalB ? "true" : "false") << ";"
        << "normalizedRotationDegreesB=" << f.normalizedRotationDegreesB << ";"
        << "sourceKindA=" << f.sourceKindA << ";"
        << "sourceKindB=" << f.sourceKindB << ";"
        << "bufferAFormat=" << f.bufferAFormat << ";"
        << "bufferBFormat=" << f.bufferBFormat << ";"
        << "targetA=" << f.targetA << ";"
        << "targetB=" << f.targetB << ";"
        << "bufferFillA=" << f.bufferFillA << ";"
        << "bufferFillB=" << f.bufferFillB << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lastError=" << (f.lastError.empty() ? "none" : f.lastError);
    return oss.str();
}

} // namespace

// ── Phase 1 Unit BB: GLES SurfaceProducer texture composition DAG smoke ───
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1BBGlesTextureCompositionDagSmoke(
    JNIEnv*  env,
    jobject  /* this */,
    jobject  surface,
    jobject  bufferA,
    jobject  bufferB,
    jint     width,
    jint     height,
    jint     frameCount,
    jlong    frameDurationUs,
    jint     frameDelayMs,
    jint     rotationDegreesA,
    jboolean mirrorHorizontalA,
    jint     rotationDegreesB,
    jboolean mirrorHorizontalB,
    jstring  sourceKindA,
    jstring  sourceKindB) {

    // Phase 1-Unit BC: diagnostic-only per-frame delay; clamp negative input
    // to no delay rather than rejecting the call (BB omits this arg / sends
    // 0, which must keep behaving identically).
    const jint effectiveFrameDelayMs = (frameDelayMs > 0) ? frameDelayMs : 0;

    // Phase 1-Unit BD: independent per-source render-transform arguments;
    // both BB/BC-compatible (rotationDegrees=0, mirrorHorizontal=false) when
    // omitted by the caller. The renderer receives the raw rotation value
    // (matching the AZ/single-source route); normalizeRotation is used only
    // for the diagnostic status fields below.
    const bool mirrorHorizontalABool = (mirrorHorizontalA == JNI_TRUE);
    const bool mirrorHorizontalBBool = (mirrorHorizontalB == JNI_TRUE);
    const jint normalizedRotationDegreesA = static_cast<jint>(
        vanguard::render::normalizeRotation(static_cast<uint32_t>(rotationDegreesA)));
    const jint normalizedRotationDegreesB = static_cast<jint>(
        vanguard::render::normalizeRotation(static_cast<uint32_t>(rotationDegreesB)));

    // Phase 1-Unit BE: independent per-source kind arguments; both
    // BB/BC/BD-compatible ("2d") when omitted/unrecognized by the caller.
    const std::string sourceKindAValue = NormalizeSourceKind(JStringToStdString(env, sourceKindA));
    const std::string sourceKindBValue = NormalizeSourceKind(JStringToStdString(env, sourceKindB));
    const uint32_t expectedTargetA =
        (sourceKindAValue == "oes") ? kGlTextureTargetOes : kGlTextureTarget2D;
    const uint32_t expectedTargetB =
        (sourceKindBValue == "oes") ? kGlTextureTargetOes : kGlTextureTarget2D;

    BBStatusFields status;
    status.width = width;
    status.height = height;
    status.frameCount = frameCount;
    status.frameDelayMs = effectiveFrameDelayMs;
    status.rotationDegreesA = rotationDegreesA;
    status.mirrorHorizontalA = mirrorHorizontalABool;
    status.normalizedRotationDegreesA = normalizedRotationDegreesA;
    status.rotationDegreesB = rotationDegreesB;
    status.mirrorHorizontalB = mirrorHorizontalBBool;
    status.normalizedRotationDegreesB = normalizedRotationDegreesB;
    status.sourceKindA = sourceKindAValue;
    status.sourceKindB = sourceKindBValue;

    if (surface == nullptr || bufferA == nullptr || bufferB == nullptr ||
        width <= 0 || height <= 0 || frameCount <= 0 || frameDurationUs <= 0) {
        status.lastError = "invalid_arguments";
        return env->NewStringUTF(BuildStatusString(status).c_str());
    }

    NativeHardwareBufferFunctions ahbFns = ResolveNativeHardwareBufferFunctions();
    if (!ahbFns.isValid()) {
        status.lastError = "hardware_buffer_symbols_unavailable";
        return env->NewStringUTF(BuildStatusString(status).c_str());
    }

    ANativeWindow* nativeWindow = ANativeWindow_fromSurface(env, surface);
    if (nativeWindow == nullptr) {
        status.attach = "native_window_failed";
        status.lastError = "native_window_from_surface_failed";
        return env->NewStringUTF(BuildStatusString(status).c_str());
    }

    AHardwareBuffer* ahbA = ahbFns.fromHardwareBuffer(env, bufferA);
    AHardwareBuffer* ahbB = ahbFns.fromHardwareBuffer(env, bufferB);
    if (ahbA == nullptr || ahbB == nullptr) {
        ANativeWindow_release(nativeWindow);
        status.importA = (ahbA == nullptr) ? "hardware_buffer_from_jobject_failed" : status.importA;
        status.importB = (ahbB == nullptr) ? "hardware_buffer_from_jobject_failed" : status.importB;
        status.lastError = "hardware_buffer_from_jobject_failed";
        return env->NewStringUTF(BuildStatusString(status).c_str());
    }

    // Phase 1-Unit BE: validate each source descriptor according to its
    // source kind ("2d" -> RGBA_8888 + GPU_SAMPLED_IMAGE|CPU_WRITE_OFTEN,
    // "oes" -> YCBCR_420_888 + GPU_SAMPLED_IMAGE only).
    AHardwareBuffer_Desc nativeDescA{};
    ahbFns.describe(ahbA, &nativeDescA);
    AHardwareBuffer_Desc nativeDescB{};
    ahbFns.describe(ahbB, &nativeDescB);
    const bool descAOk = ValidateSourceDescriptor(
        nativeDescA, sourceKindAValue, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    const bool descBOk = ValidateSourceDescriptor(
        nativeDescB, sourceKindBValue, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    if (!descAOk || !descBOk) {
        ANativeWindow_release(nativeWindow);
        status.lastError = "hardware_buffer_descriptor_mismatch";
        return env->NewStringUTF(BuildStatusString(status).c_str());
    }
    status.bufferAFormat = BufferFormatLabel(sourceKindAValue);
    status.bufferBFormat = BufferFormatLabel(sourceKindBValue);

    // CPU-fill only "2d"/RGBA sources solid red [255,0,0,255] / solid blue
    // [0,0,255,255] so the composited blend is deterministic; "oes"/YCBCR
    // sources are never CPU-filled.
    bool fillAOk = true;
    if (sourceKindAValue == "oes") {
        status.bufferFillA = "skipped_oes";
    } else {
        fillAOk = FillHardwareBufferSolidColor(
            ahbFns, ahbA, static_cast<uint32_t>(width), static_cast<uint32_t>(height), 255, 0, 0, 255);
        status.bufferFillA = fillAOk ? "success" : "failed";
    }
    bool fillBOk = true;
    if (sourceKindBValue == "oes") {
        status.bufferFillB = "skipped_oes";
    } else {
        fillBOk = FillHardwareBufferSolidColor(
            ahbFns, ahbB, static_cast<uint32_t>(width), static_cast<uint32_t>(height), 0, 0, 255, 255);
        status.bufferFillB = fillBOk ? "success" : "failed";
    }
    if (!fillAOk || !fillBOk) {
        ANativeWindow_release(nativeWindow);
        status.lastError = "hardware_buffer_fill_failed";
        return env->NewStringUTF(BuildStatusString(status).c_str());
    }

    int releaseFenceAFd = -1;
    int releaseFenceBFd = -1;

    try {
        // ── 1. Initialize GlesBackend ────────────────────────────────────────
        vanguard::render::GlesBackend backend;
        const bool initialized = backend.initialize();
        status.initialize = initialized ? "success" : "failed";

        // ── 2. Attach the SurfaceProducer-backed window surface ─────────────
        bool attached = false;
        if (initialized) {
            attached = backend.attachSurface(
                nativeWindow, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
            status.attach = attached ? "success" : "failed";
        }
        status.textureSurface = attached;

        // ── 3. Build the diagnostic two-source -> compositor -> sink DAG ────
        bool graphOk = false;
        uint64_t graphGenId = 0u;
        vanguard::graph::Graph graph;

        if (attached) {
            auto sourceA = std::make_shared<DiagBBHardwareBufferSourceNode>("diag_bb_source_a");
            auto sourceB = std::make_shared<DiagBBHardwareBufferSourceNode>("diag_bb_source_b");
            auto compositor = std::make_shared<DiagBBTimelineCompositorNode>(
                "diag_bb_compositor", static_cast<uint64_t>(frameDurationUs), frameCount);
            auto sink = std::make_shared<DiagBBTextureSurfaceSinkNode>("diag_bb_texture_sink");

            const auto addSourceAStatus = graph.addNode(sourceA);
            const auto addSourceBStatus = graph.addNode(sourceB);
            const auto addCompositorStatus = graph.addNode(compositor);
            const auto addSinkStatus = graph.addNode(sink);
            const auto connectAStatus = graph.connect(
                "diag_bb_source_a", "kVideoFrame", "diag_bb_compositor", "kVideoFrameA");
            const auto connectBStatus = graph.connect(
                "diag_bb_source_b", "kVideoFrame", "diag_bb_compositor", "kVideoFrameB");
            const auto connectSinkStatus = graph.connect(
                "diag_bb_compositor", "kVideoFrame", "diag_bb_texture_sink", "kVideoFrame");

            if (addSourceAStatus.ok() && addSourceBStatus.ok() && addCompositorStatus.ok() &&
                addSinkStatus.ok() && connectAStatus.ok() && connectBStatus.ok() &&
                connectSinkStatus.ok()) {
                graphGenId = graph.generationId();
                status.graphBuild = "success";
                graphOk = true;
            } else {
                status.graphBuild = "graph_build_failed";
            }
        }
        status.graphGeneration = graphGenId;

        // ── 4. Import the two HardwareBuffers directly into the backend ─────
        //         (target 0x0DE1/3553 for "2d", 0x8D65/36197 for "oes")
        vanguard::render::HardwareBufferHandle handleA =
            vanguard::render::kInvalidHardwareBufferHandle;
        vanguard::render::HardwareBufferHandle handleB =
            vanguard::render::kInvalidHardwareBufferHandle;
        bool importedA = false;
        bool importedB = false;
        bool targetAOk = false;
        bool targetBOk = false;

        if (graphOk) {
            vanguard::render::HardwareBufferDescriptor importDescA{};
            const auto importResultA = backend.importHardwareBuffer(ahbA, -1, &handleA, &importDescA);
            status.importA = HardwareBufferResultName(importResultA);
            importedA = (importResultA == vanguard::render::HardwareBufferImportResult::kSuccess);
            if (importedA) {
                status.targetA = static_cast<int32_t>(
                    backend.diagnosticTextureTargetForHardwareBuffer(handleA));
                targetAOk = (static_cast<uint32_t>(status.targetA) == expectedTargetA);
            }

            vanguard::render::HardwareBufferDescriptor importDescB{};
            const auto importResultB = backend.importHardwareBuffer(ahbB, -1, &handleB, &importDescB);
            status.importB = HardwareBufferResultName(importResultB);
            importedB = (importResultB == vanguard::render::HardwareBufferImportResult::kSuccess);
            if (importedB) {
                status.targetB = static_cast<int32_t>(
                    backend.diagnosticTextureTargetForHardwareBuffer(handleB));
                targetBOk = (static_cast<uint32_t>(status.targetB) == expectedTargetB);
            }
        }

        // ── 5. Per-frame: evaluatePlayhead -> extract compositor weight ->
        //         diagnosticPresentCompositeFrames ─────────────────────────
        if (importedA && importedB && !targetAOk) {
            status.evaluation = "target_mismatch_a";
        } else if (importedA && importedB && !targetBOk) {
            status.evaluation = "target_mismatch_b";
        }

        if (importedA && importedB && targetAOk && targetBOk) {
            status.evaluation = "success";
            status.renderFrame = "success";

            vanguard::render::VideoFrameTransform transformA{};
            transformA.rotationDegrees = static_cast<uint32_t>(rotationDegreesA);
            transformA.mirrorHorizontal = mirrorHorizontalABool;

            vanguard::render::VideoFrameTransform transformB{};
            transformB.rotationDegrees = static_cast<uint32_t>(rotationDegreesB);
            transformB.mirrorHorizontal = mirrorHorizontalBBool;

            bool evalLoopOk = true;
            bool compositorFoundEveryFrame = true;
            bool monotonicWeights = true;
            bool haveFirstWeight = false;
            float previousWeightB = 0.0f;

            for (int frameIdx = 0; frameIdx < frameCount; ++frameIdx) {
                vanguard::graph::FrameRequest request;
                request.timelinePtsUs =
                    static_cast<uint64_t>(frameIdx) * static_cast<uint64_t>(frameDurationUs);
                request.generationId = graphGenId;
                request.canvasWidth = static_cast<uint32_t>(width);
                request.canvasHeight = static_cast<uint32_t>(height);

                vanguard::graph::FrameEvaluationResult evalResult;
                const auto evalStatus = graph.evaluatePlayhead(request, evalResult);
                status.lastEvaluatedPtsUs = static_cast<int64_t>(evalResult.evaluatedPtsUs);
                status.activeNodeCount = static_cast<int>(evalResult.activeNodes.size());

                if (!evalStatus.ok() || !evalResult.ok() || !evalResult.hasVideo ||
                    evalResult.activeNodes.empty()) {
                    status.evaluation = "evaluation_failed";
                    evalLoopOk = false;
                    status.failingFrame = frameIdx;
                    break;
                }

                bool compositorFoundThisFrame = false;
                float weightB = 0.0f;
                for (const auto& info : evalResult.activeNodeDetails) {
                    if (info.nodeId == "diag_bb_compositor") {
                        compositorFoundThisFrame = true;
                        weightB = info.weight;
                        break;
                    }
                }
                if (!compositorFoundThisFrame) {
                    compositorFoundEveryFrame = false;
                    status.evaluation = "compositor_not_active";
                    evalLoopOk = false;
                    status.failingFrame = frameIdx;
                    break;
                }

                if (!haveFirstWeight) {
                    status.startWeightB = weightB;
                    haveFirstWeight = true;
                } else if (weightB < previousWeightB) {
                    monotonicWeights = false;
                }
                previousWeightB = weightB;
                status.endWeightB = weightB;

                const bool presentOk = backend.diagnosticPresentCompositeFrames(
                    handleA, handleB, weightB, transformA, transformB);
                if (!presentOk) {
                    status.renderFrame = "failed";
                    status.failingFrame = frameIdx;
                    break;
                }
                status.renderedFrames++;
                if (effectiveFrameDelayMs > 0) {
                    usleep(static_cast<useconds_t>(effectiveFrameDelayMs) * 1000);
                }
            }

            status.compositorActive = compositorFoundEveryFrame;
            status.monotonicWeights = monotonicWeights;
        }

        // ── 6. Release both HardwareBuffer imports ───────────────────────────
        if (importedA) {
            const auto releaseResultA = backend.releaseHardwareBuffer(handleA, &releaseFenceAFd);
            status.releaseA = HardwareBufferResultName(releaseResultA);
        }
        if (importedB) {
            const auto releaseResultB = backend.releaseHardwareBuffer(handleB, &releaseFenceBFd);
            status.releaseB = HardwareBufferResultName(releaseResultB);
        }
        status.releaseFenceAFd = releaseFenceAFd;
        status.releaseFenceBFd = releaseFenceBFd;
        status.releaseFenceExported = (releaseFenceAFd >= 0) && (releaseFenceBFd >= 0);

        status.lastError = SanitizeString(backend.lastError());

        // ── 7. Close any exported release fence fds, detach, shutdown ───────
        if (releaseFenceAFd >= 0) {
            ::close(releaseFenceAFd);
            releaseFenceAFd = -1;
        }
        if (releaseFenceBFd >= 0) {
            ::close(releaseFenceBFd);
            releaseFenceBFd = -1;
        }
        backend.detachSurface();
        backend.shutdown();

        const bool releasePassed =
            (status.releaseA == "success") && (status.releaseB == "success");
        const bool startWeightCorrect = (frameCount <= 1)
            ? (std::fabs(status.startWeightB - 1.0f) < 0.0001f)
            : (std::fabs(status.startWeightB - 0.0f) < 0.0001f);
        const bool endWeightCorrect = std::fabs(status.endWeightB - 1.0f) < 0.0001f;

        status.pass = (status.initialize == "success") &&
                      (status.attach == "success") &&
                      (status.graphBuild == "success") &&
                      importedA && importedB &&
                      targetAOk && targetBOk &&
                      (status.evaluation == "success") &&
                      status.compositorActive &&
                      status.monotonicWeights &&
                      (status.renderedFrames == frameCount) &&
                      (status.renderFrame == "success") &&
                      startWeightCorrect &&
                      endWeightCorrect &&
                      releasePassed;
    } catch (...) {
        status.initialize = "exception";
        status.pass = false;
        status.lastError = "native_exception";
    }

    if (releaseFenceAFd >= 0) {
        ::close(releaseFenceAFd);
    }
    if (releaseFenceBFd >= 0) {
        ::close(releaseFenceBFd);
    }
    ANativeWindow_release(nativeWindow);

    return env->NewStringUTF(BuildStatusString(status).c_str());
}
