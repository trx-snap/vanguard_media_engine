// Phase 1 Unit AH: Android GLES YCBCR_420_888 AHardwareBuffer import guard fail-closed physical smoke JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// Non-claim: fail-closed import guard proof for YCBCR_420_888 format only;
// no YUV or external/OES import, no release fence production, no product API/UI wiring.
//
// JNI entry point:
//   runAndroidDagPhase1AHGlesYcbcrImportGuardSmoke -> jstring

#include <jni.h>
#include <android/hardware_buffer.h>
#include <dlfcn.h>

#include <cstdint>
#include <sstream>
#include <string>

#include "vanguard/render/gles_backend.h"

namespace {

using FnAHardwareBuffer_fromHardwareBuffer =
    AHardwareBuffer* (*)(JNIEnv*, jobject);
using FnAHardwareBuffer_describe =
    void (*)(const AHardwareBuffer*, AHardwareBuffer_Desc*);

struct NativeHardwareBufferFunctions {
    FnAHardwareBuffer_fromHardwareBuffer fromHardwareBuffer = nullptr;
    FnAHardwareBuffer_describe describe = nullptr;
    bool isValid() const {
        return fromHardwareBuffer && describe;
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

std::string BuildFailureString(const char* lastErrorReason) {
    std::ostringstream oss;
    oss << "status=FAIL;"
        << "clientVersion=0;"
        << "vendor=;"
        << "renderer=;"
        << "version=;"
        << "validBufferDescribe=not_run;"
        << "validBufferFormat=0;"
        << "validBufferUsage=0;"
        << "ycbcrBufferDescribe=not_run;"
        << "ycbcrBufferFormat=0;"
        << "ycbcrBufferUsage=0;"
        << "ycbcrFormatIs420888=false;"
        << "initialize=not_run;"
        << "validPreImport=not_run;"
        << "validPreHandle=0;"
        << "validPreDescWidth=0;"
        << "validPreDescHeight=0;"
        << "validPreDescLayers=0;"
        << "validPreDescFormat=0;"
        << "validPreDescUsageSampled=false;"
        << "hasValidPreAfterImport=false;"
        << "validPreRelease=not_run;"
        << "validPreReleaseFence=-1;"
        << "hasValidPreAfterRelease=false;"
        << "ycbcrImport=not_run;"
        << "ycbcrHandle=0;"
        << "ycbcrDescZero=false;"
        << "ycbcrLastError=none;"
        << "hasYcbcrAfterImport=false;"
        << "validPostImport=not_run;"
        << "validPostHandle=0;"
        << "validPostDescWidth=0;"
        << "validPostDescHeight=0;"
        << "validPostDescLayers=0;"
        << "validPostDescFormat=0;"
        << "validPostDescUsageSampled=false;"
        << "hasValidPostAfterImport=false;"
        << "validPostRelease=not_run;"
        << "validPostReleaseFence=-1;"
        << "hasValidPostAfterRelease=false;"
        << "shutdown=not_run;"
        << "idempotentShutdown=not_run;"
        << "proofBoundary=gles_ycbcr_ahb_import_guard_fail_closed_no_oes_no_release_fence_no_product;"
        << "lastError=" << lastErrorReason;
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1AHGlesYcbcrImportGuardSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jValidBuffer,
    jobject jYcbcrBuffer,
    jint width,
    jint height) {

    if (!jValidBuffer || !jYcbcrBuffer || width <= 0 || height <= 0) {
        return env->NewStringUTF(BuildFailureString("invalid_arguments").c_str());
    }

    NativeHardwareBufferFunctions ahbFns = ResolveNativeHardwareBufferFunctions();
    if (!ahbFns.isValid()) {
        return env->NewStringUTF(BuildFailureString("hardware_buffer_symbols_unavailable").c_str());
    }

    AHardwareBuffer* ahbValid = ahbFns.fromHardwareBuffer(env, jValidBuffer);
    AHardwareBuffer* ahbYcbcr = ahbFns.fromHardwareBuffer(env, jYcbcrBuffer);

    if (!ahbValid || !ahbYcbcr) {
        return env->NewStringUTF(BuildFailureString("hardware_buffer_from_jobject_failed").c_str());
    }

    // Buffer description queries
    AHardwareBuffer_Desc descValidBuf{};
    ahbFns.describe(ahbValid, &descValidBuf);
    const bool validBufferDescribeOk = (descValidBuf.width == static_cast<uint32_t>(width)) &&
                                       (descValidBuf.height == static_cast<uint32_t>(height)) &&
                                       (descValidBuf.layers == 1) &&
                                       (descValidBuf.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                                       ((descValidBuf.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);

    AHardwareBuffer_Desc descYcbcrBuf{};
    ahbFns.describe(ahbYcbcr, &descYcbcrBuf);
    const bool ycbcrFormatIs420888 = (descYcbcrBuf.format == AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420);
    const bool ycbcrBufferDescribeOk = (descYcbcrBuf.width == static_cast<uint32_t>(width)) &&
                                       (descYcbcrBuf.height == static_cast<uint32_t>(height)) &&
                                       (descYcbcrBuf.layers == 1) &&
                                       ycbcrFormatIs420888 &&
                                       ((descYcbcrBuf.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);

    vanguard::render::GlesBackend backend;

    // 1. Initialize backend exactly once
    const bool initOk = backend.initialize();
    const bool isInitialized = backend.isInitialized();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool initCheckOk = initOk && isInitialized && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    // 2. Lane 1: valid import before YCBCR succeeds, descriptor matches, releases cleanly
    vanguard::render::HardwareBufferHandle hValidPre = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descValidPre{};
    const auto resValidPre = backend.importHardwareBuffer(ahbValid, -1, &hValidPre, &descValidPre);
    const bool validPreImportOk = (resValidPre == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                                  (hValidPre != vanguard::render::kInvalidHardwareBufferHandle);
    const bool validPreDescOk = (descValidPre.width == static_cast<uint32_t>(width)) &&
                                (descValidPre.height == static_cast<uint32_t>(height)) &&
                                (descValidPre.layers == 1) &&
                                (descValidPre.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                                ((descValidPre.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);
    const bool hasValidPreAfterImport = backend.hasHardwareBuffer(hValidPre);

    int releaseFenceValidPre = -999;
    const auto resReleaseValidPre = backend.releaseHardwareBuffer(hValidPre, &releaseFenceValidPre);
    const bool validPreReleaseOk = (resReleaseValidPre == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                                   (releaseFenceValidPre == -1);
    const bool hasValidPreAfterRelease = backend.hasHardwareBuffer(hValidPre);
    const bool lane1Ok = validPreImportOk && validPreDescOk && hasValidPreAfterImport &&
                         validPreReleaseOk && !hasValidPreAfterRelease;

    // 3. Lane 2: YCBCR import returns kIncompatibleBuffer, handle=0, zeroed descriptor, lastError
    vanguard::render::HardwareBufferHandle hYcbcr = 999;
    vanguard::render::HardwareBufferDescriptor descYcbcr{1, 1, 1, 1, 1, 1};
    const auto resYcbcr = backend.importHardwareBuffer(ahbYcbcr, -1, &hYcbcr, &descYcbcr);
    const bool ycbcrDescZero = (descYcbcr.width == 0 && descYcbcr.height == 0 &&
                                descYcbcr.layers == 0 && descYcbcr.format == 0 &&
                                descYcbcr.stride == 0 && descYcbcr.usage == 0);
    const std::string ycbcrLastError = SanitizeString(backend.lastError());
    const bool ycbcrImportOk = (resYcbcr == vanguard::render::HardwareBufferImportResult::kIncompatibleBuffer) &&
                               (hYcbcr == vanguard::render::kInvalidHardwareBufferHandle) &&
                               ycbcrDescZero &&
                               (ycbcrLastError == "ahb_import_unsupported_format");
    const bool hasYcbcrAfterImport = backend.hasHardwareBuffer(hYcbcr);
    const bool lane2Ok = ycbcrImportOk && !hasYcbcrAfterImport;

    // 4. Lane 3: valid import after YCBCR rejection succeeds and releases cleanly (unpoisoned state)
    vanguard::render::HardwareBufferHandle hValidPost = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descValidPost{};
    const auto resValidPost = backend.importHardwareBuffer(ahbValid, -1, &hValidPost, &descValidPost);
    const bool validPostImportOk = (resValidPost == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                                   (hValidPost != vanguard::render::kInvalidHardwareBufferHandle);
    const bool validPostDescOk = (descValidPost.width == static_cast<uint32_t>(width)) &&
                                 (descValidPost.height == static_cast<uint32_t>(height)) &&
                                 (descValidPost.layers == 1) &&
                                 (descValidPost.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                                 ((descValidPost.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);
    const bool hasValidPostAfterImport = backend.hasHardwareBuffer(hValidPost);

    int releaseFenceValidPost = -999;
    const auto resReleaseValidPost = backend.releaseHardwareBuffer(hValidPost, &releaseFenceValidPost);
    const bool validPostReleaseOk = (resReleaseValidPost == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                                    (releaseFenceValidPost == -1);
    const bool hasValidPostAfterRelease = backend.hasHardwareBuffer(hValidPost);
    const bool lane3Ok = validPostImportOk && validPostDescOk && hasValidPostAfterImport &&
                         validPostReleaseOk && !hasValidPostAfterRelease;

    // 5. Lane 4: shutdown succeeds and second shutdown is safe/idempotent
    backend.shutdown();
    const bool isInitAfterShutdown = backend.isInitialized();

    backend.shutdown();
    const bool idempotentShutdownOk = !backend.isInitialized();
    const bool lane4Ok = !isInitAfterShutdown && idempotentShutdownOk;

    // Overall check evaluation
    const bool allChecksPass = validBufferDescribeOk &&
                               ycbcrBufferDescribeOk &&
                               initCheckOk &&
                               lane1Ok &&
                               lane2Ok &&
                               lane3Ok &&
                               lane4Ok;

    const std::string backendLastError = SanitizeString(backend.lastError());

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "validBufferDescribe=" << (validBufferDescribeOk ? "success" : "failed") << ";"
        << "validBufferFormat=" << descValidBuf.format << ";"
        << "validBufferUsage=" << descValidBuf.usage << ";"
        << "ycbcrBufferDescribe=" << (ycbcrBufferDescribeOk ? "success" : "failed") << ";"
        << "ycbcrBufferFormat=" << descYcbcrBuf.format << ";"
        << "ycbcrBufferUsage=" << descYcbcrBuf.usage << ";"
        << "ycbcrFormatIs420888=" << (ycbcrFormatIs420888 ? "true" : "false") << ";"
        << "initialize=" << (initCheckOk ? "success" : "failed") << ";"
        << "validPreImport=" << (validPreImportOk ? "success" : "failed") << ";"
        << "validPreHandle=" << hValidPre << ";"
        << "validPreDescWidth=" << descValidPre.width << ";"
        << "validPreDescHeight=" << descValidPre.height << ";"
        << "validPreDescLayers=" << descValidPre.layers << ";"
        << "validPreDescFormat=" << descValidPre.format << ";"
        << "validPreDescUsageSampled=" << (((descValidPre.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) ? "true" : "false") << ";"
        << "hasValidPreAfterImport=" << (hasValidPreAfterImport ? "true" : "false") << ";"
        << "validPreRelease=" << (validPreReleaseOk ? "success" : "failed") << ";"
        << "validPreReleaseFence=" << releaseFenceValidPre << ";"
        << "hasValidPreAfterRelease=" << (hasValidPreAfterRelease ? "true" : "false") << ";"
        << "ycbcrImport=" << (ycbcrImportOk ? "rejected_as_expected" : "failed") << ";"
        << "ycbcrHandle=" << hYcbcr << ";"
        << "ycbcrDescZero=" << (ycbcrDescZero ? "true" : "false") << ";"
        << "ycbcrLastError=" << (ycbcrLastError.empty() ? "none" : ycbcrLastError) << ";"
        << "hasYcbcrAfterImport=" << (hasYcbcrAfterImport ? "true" : "false") << ";"
        << "validPostImport=" << (validPostImportOk ? "success" : "failed") << ";"
        << "validPostHandle=" << hValidPost << ";"
        << "validPostDescWidth=" << descValidPost.width << ";"
        << "validPostDescHeight=" << descValidPost.height << ";"
        << "validPostDescLayers=" << descValidPost.layers << ";"
        << "validPostDescFormat=" << descValidPost.format << ";"
        << "validPostDescUsageSampled=" << (((descValidPost.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) ? "true" : "false") << ";"
        << "hasValidPostAfterImport=" << (hasValidPostAfterImport ? "true" : "false") << ";"
        << "validPostRelease=" << (validPostReleaseOk ? "success" : "failed") << ";"
        << "validPostReleaseFence=" << releaseFenceValidPost << ";"
        << "hasValidPostAfterRelease=" << (hasValidPostAfterRelease ? "true" : "false") << ";"
        << "shutdown=" << (!isInitAfterShutdown ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=gles_ycbcr_ahb_import_guard_fail_closed_no_oes_no_release_fence_no_product;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
