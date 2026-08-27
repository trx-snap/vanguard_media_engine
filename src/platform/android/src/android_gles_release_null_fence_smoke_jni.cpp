// Phase 1 Unit AL: Android GLES releaseHardwareBuffer nullptr release-fence output physical smoke JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// Non-claim: optional nullptr release-fence output contract physical proof only;
// no production release fence implementation, no changes to releaseHardwareBuffer,
// no renderFrame, no readPixels, no YUV/OES, no product API/UI wiring.
//
// JNI entry point:
//   runAndroidDagPhase1ALGlesReleaseNullFenceSmoke -> jstring

#include <jni.h>
#include <android/hardware_buffer.h>
#include <dlfcn.h>
#include <unistd.h>

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
        << "bufferDescribe=not_run;"
        << "bufferWidth=0;"
        << "bufferHeight=0;"
        << "bufferLayers=0;"
        << "bufferFormat=0;"
        << "bufferUsageSampled=false;"
        << "initialize=not_run;"
        << "import1=not_run;"
        << "handle1=0;"
        << "desc1Width=0;"
        << "desc1Height=0;"
        << "desc1Layers=0;"
        << "desc1Format=0;"
        << "desc1UsageSampled=false;"
        << "hasAfterImport1=false;"
        << "nullFenceRelease1=not_run;"
        << "hasAfterNullFenceRelease1=false;"
        << "nullFenceDoubleRelease1=not_run;"
        << "import2=not_run;"
        << "handle2=0;"
        << "desc2Width=0;"
        << "desc2Height=0;"
        << "desc2Layers=0;"
        << "desc2Format=0;"
        << "desc2UsageSampled=false;"
        << "hasAfterImport2=false;"
        << "release2=not_run;"
        << "release2Fence=-1;"
        << "hasAfterRelease2=false;"
        << "shutdown=not_run;"
        << "idempotentShutdown=not_run;"
        << "proofBoundary=gles_release_null_fence_output_contract_release_fence_optional_no_render_no_product;"
        << "lastError=" << lastErrorReason;
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1ALGlesReleaseNullFenceSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jHardwareBuffer,
    jint width,
    jint height) {

    if (!jHardwareBuffer || width <= 0 || height <= 0) {
        return env->NewStringUTF(BuildFailureString("invalid_arguments").c_str());
    }

    NativeHardwareBufferFunctions ahbFns = ResolveNativeHardwareBufferFunctions();
    if (!ahbFns.isValid()) {
        return env->NewStringUTF(BuildFailureString("hardware_buffer_symbols_unavailable").c_str());
    }

    AHardwareBuffer* ahb = ahbFns.fromHardwareBuffer(env, jHardwareBuffer);
    if (!ahb) {
        return env->NewStringUTF(BuildFailureString("hardware_buffer_from_jobject_failed").c_str());
    }

    // Lane 1: Buffer describe check
    AHardwareBuffer_Desc descBuf{};
    ahbFns.describe(ahb, &descBuf);
    const bool bufferUsageSampled = ((descBuf.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);
    const bool bufferDescribeOk = (descBuf.width == static_cast<uint32_t>(width)) &&
                                  (descBuf.height == static_cast<uint32_t>(height)) &&
                                  (descBuf.layers == 1) &&
                                  (descBuf.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                                  bufferUsageSampled;

    vanguard::render::GlesBackend backend;

    // Initialize backend once
    const bool initOk = backend.initialize();
    const bool isInitialized = backend.isInitialized();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool initCheckOk = initOk && isInitialized && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    // Lane 2: importBuffer succeeds, handle nonzero, descriptor matches, hasAfterImport=true
    vanguard::render::HardwareBufferHandle handle1 = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor desc1{};
    const auto resImport1 = backend.importHardwareBuffer(ahb, -1, &handle1, &desc1);
    const bool import1Ok = (resImport1 == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                           (handle1 != vanguard::render::kInvalidHardwareBufferHandle);
    const bool desc1UsageSampled = ((desc1.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);
    const bool desc1Ok = (desc1.width == static_cast<uint32_t>(width)) &&
                         (desc1.height == static_cast<uint32_t>(height)) &&
                         (desc1.layers == 1) &&
                         (desc1.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                         desc1UsageSampled;
    const bool hasAfterImport1 = backend.hasHardwareBuffer(handle1);
    const bool lane2Ok = import1Ok && desc1Ok && hasAfterImport1;

    // Lane 3: releaseHardwareBuffer(handle1, nullptr) returns kSuccess, hasAfterNullFenceRelease1=false
    const auto resNullFenceRelease1 = backend.releaseHardwareBuffer(handle1, nullptr);
    const bool nullFenceRelease1Ok = (resNullFenceRelease1 == vanguard::render::HardwareBufferImportResult::kSuccess);
    const bool hasAfterNullFenceRelease1 = backend.hasHardwareBuffer(handle1);
    const bool lane3Ok = nullFenceRelease1Ok && !hasAfterNullFenceRelease1;

    // Lane 4: double release of the same handle with nullptr returns kUnknownHandle and does not crash
    const auto resDoubleRelease1 = backend.releaseHardwareBuffer(handle1, nullptr);
    const bool doubleRelease1Ok = (resDoubleRelease1 == vanguard::render::HardwareBufferImportResult::kUnknownHandle);
    const bool lane4Ok = doubleRelease1Ok;

    // Lane 5: a second valid import after nullptr release succeeds and then releases with non-null outReleaseFenceFd, returning releaseFence=-1, proving state/table remains healthy
    vanguard::render::HardwareBufferHandle handle2 = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor desc2{};
    const auto resImport2 = backend.importHardwareBuffer(ahb, -1, &handle2, &desc2);
    const bool import2Ok = (resImport2 == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                           (handle2 != vanguard::render::kInvalidHardwareBufferHandle);
    const bool desc2UsageSampled = ((desc2.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0);
    const bool desc2Ok = (desc2.width == static_cast<uint32_t>(width)) &&
                         (desc2.height == static_cast<uint32_t>(height)) &&
                         (desc2.layers == 1) &&
                         (desc2.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) &&
                         desc2UsageSampled;
    const bool hasAfterImport2 = backend.hasHardwareBuffer(handle2);

    int release2Fence = -999;
    const auto resRelease2 = backend.releaseHardwareBuffer(handle2, &release2Fence);
    const bool release2Ok = (resRelease2 == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                            (release2Fence >= -1);
    const bool hasAfterRelease2 = backend.hasHardwareBuffer(handle2);
    const bool lane5Ok = import2Ok && desc2Ok && hasAfterImport2 && release2Ok && !hasAfterRelease2;

    // Lane 6: shutdown succeeds and second shutdown is safe/idempotent
    backend.shutdown();
    const bool isInitAfterShutdown = backend.isInitialized();

    backend.shutdown();
    const bool idempotentShutdownOk = !backend.isInitialized();
    const bool lane6Ok = !isInitAfterShutdown && idempotentShutdownOk;

    // Close any non-negative fds returned by releaseHardwareBuffer exactly once after capturing
    if (release2Fence >= 0) {
        ::close(release2Fence);
    }

    const bool allChecksPass = bufferDescribeOk &&
                               initCheckOk &&
                               lane2Ok &&
                               lane3Ok &&
                               lane4Ok &&
                               lane5Ok &&
                               lane6Ok;

    const std::string backendLastError = SanitizeString(backend.lastError());

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "bufferDescribe=" << (bufferDescribeOk ? "success" : "failed") << ";"
        << "bufferWidth=" << descBuf.width << ";"
        << "bufferHeight=" << descBuf.height << ";"
        << "bufferLayers=" << descBuf.layers << ";"
        << "bufferFormat=" << descBuf.format << ";"
        << "bufferUsageSampled=" << (bufferUsageSampled ? "true" : "false") << ";"
        << "initialize=" << (initCheckOk ? "success" : "failed") << ";"
        << "import1=" << (import1Ok ? "success" : "failed") << ";"
        << "handle1=" << handle1 << ";"
        << "desc1Width=" << desc1.width << ";"
        << "desc1Height=" << desc1.height << ";"
        << "desc1Layers=" << desc1.layers << ";"
        << "desc1Format=" << desc1.format << ";"
        << "desc1UsageSampled=" << (desc1UsageSampled ? "true" : "false") << ";"
        << "hasAfterImport1=" << (hasAfterImport1 ? "true" : "false") << ";"
        << "nullFenceRelease1=" << (nullFenceRelease1Ok ? "success" : "failed") << ";"
        << "hasAfterNullFenceRelease1=" << (hasAfterNullFenceRelease1 ? "true" : "false") << ";"
        << "nullFenceDoubleRelease1=" << (doubleRelease1Ok ? "rejected_as_expected" : "failed") << ";"
        << "import2=" << (import2Ok ? "success" : "failed") << ";"
        << "handle2=" << handle2 << ";"
        << "desc2Width=" << desc2.width << ";"
        << "desc2Height=" << desc2.height << ";"
        << "desc2Layers=" << desc2.layers << ";"
        << "desc2Format=" << desc2.format << ";"
        << "desc2UsageSampled=" << (desc2UsageSampled ? "true" : "false") << ";"
        << "hasAfterImport2=" << (hasAfterImport2 ? "true" : "false") << ";"
        << "release2=" << (release2Ok ? "success" : "failed") << ";"
        << "release2Fence=" << release2Fence << ";"
        << "hasAfterRelease2=" << (hasAfterRelease2 ? "true" : "false") << ";"
        << "shutdown=" << (!isInitAfterShutdown ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=gles_release_null_fence_output_contract_release_fence_optional_no_render_no_product;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
