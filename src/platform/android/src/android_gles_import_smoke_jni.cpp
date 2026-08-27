// Phase 1 Unit Y: Android GLES AHardwareBuffer RGBA_8888/RGBX_8888 import foundation smoke JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// JNI entry point:
//   runAndroidDagPhase1YGlesImportSmoke -> jstring

#include <jni.h>
#include <android/hardware_buffer.h>
#include <dlfcn.h>
#include <unistd.h>

#include <sstream>
#include <string>

#include "vanguard/render/gles_backend.h"

namespace {

using FnAHardwareBuffer_fromHardwareBuffer =
    AHardwareBuffer* (*)(JNIEnv*, jobject);

AHardwareBuffer* ResolveAHardwareBufferFromJObject(JNIEnv* env, jobject jHwBuf) {
    if (!jHwBuf) return nullptr;
    void* lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) return nullptr;
    auto fn = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
        dlsym(lib, "AHardwareBuffer_fromHardwareBuffer"));
    AHardwareBuffer* buf = nullptr;
    if (fn) {
        buf = fn(env, jHwBuf);
    }
    dlclose(lib);
    return buf;
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

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1YGlesImportSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jbufferA,
    jobject jbufferB,
    jint width,
    jint height) {

    if (!jbufferA || !jbufferB || width <= 0 || height <= 0) {
        std::ostringstream oss;
        oss << "status=FAIL;"
            << "preInitImport=not_run;"
            << "preInitHandle=0;"
            << "preInitDescriptorZero=false;"
            << "initialize=not_run;"
            << "nullBufferImport=not_run;"
            << "nullHandleImport=not_run;"
            << "nullDescriptorImport=not_run;"
            << "validImportA=not_run;"
            << "handleA=0;"
            << "descriptorWidth=0;"
            << "descriptorHeight=0;"
            << "descriptorLayers=0;"
            << "descriptorFormat=0;"
            << "descriptorUsageSampled=false;"
            << "hasAAfterImport=false;"
            << "duplicateImport=not_run;"
            << "duplicateHandle=0;"
            << "hasAAfterDuplicate=false;"
            << "renderFrame=not_run;"
            << "validImportB=not_run;"
            << "handleB=0;"
            << "distinctHandles=false;"
            << "hasBAfterImport=false;"
            << "releaseA=not_run;"
            << "releaseAFence=-1;"
            << "hasAAfterRelease=false;"
            << "doubleReleaseA=not_run;"
            << "shutdown=not_run;"
            << "hasBAfterShutdown=false;"
            << "idempotentShutdown=not_run;"
            << "proofBoundary=gles_ahb_rgba_import_no_renderFrame;"
            << "lastError=invalid_arguments";
        return env->NewStringUTF(oss.str().c_str());
    }

    AHardwareBuffer* ahbA = ResolveAHardwareBufferFromJObject(env, jbufferA);
    AHardwareBuffer* ahbB = ResolveAHardwareBufferFromJObject(env, jbufferB);

    if (!ahbA || !ahbB) {
        std::ostringstream oss;
        oss << "status=FAIL;"
            << "preInitImport=not_run;"
            << "preInitHandle=0;"
            << "preInitDescriptorZero=false;"
            << "initialize=not_run;"
            << "nullBufferImport=not_run;"
            << "nullHandleImport=not_run;"
            << "nullDescriptorImport=not_run;"
            << "validImportA=not_run;"
            << "handleA=0;"
            << "descriptorWidth=0;"
            << "descriptorHeight=0;"
            << "descriptorLayers=0;"
            << "descriptorFormat=0;"
            << "descriptorUsageSampled=false;"
            << "hasAAfterImport=false;"
            << "duplicateImport=not_run;"
            << "duplicateHandle=0;"
            << "hasAAfterDuplicate=false;"
            << "renderFrame=not_run;"
            << "validImportB=not_run;"
            << "handleB=0;"
            << "distinctHandles=false;"
            << "hasBAfterImport=false;"
            << "releaseA=not_run;"
            << "releaseAFence=-1;"
            << "hasAAfterRelease=false;"
            << "doubleReleaseA=not_run;"
            << "shutdown=not_run;"
            << "hasBAfterShutdown=false;"
            << "idempotentShutdown=not_run;"
            << "proofBoundary=gles_ahb_rgba_import_no_renderFrame;"
            << "lastError=hardware_buffer_from_jobject_failed";
        return env->NewStringUTF(oss.str().c_str());
    }

    vanguard::render::GlesBackend backend;

    // 1. Pre-init import of bufferA returns kBackendNotInitialized, handle=0, descriptor zeroed
    vanguard::render::HardwareBufferHandle hPre = 999;
    vanguard::render::HardwareBufferDescriptor descPre{1, 1, 1, 1, 1, 1};
    const auto preRes = backend.importHardwareBuffer(ahbA, -1, &hPre, &descPre);
    const bool preDescZero = (descPre.width == 0 && descPre.height == 0 && descPre.layers == 0 &&
                              descPre.format == 0 && descPre.stride == 0 && descPre.usage == 0);
    const bool preInitCheckOk = (preRes == vanguard::render::HardwareBufferImportResult::kBackendNotInitialized) &&
                                (hPre == vanguard::render::kInvalidHardwareBufferHandle) &&
                                preDescZero;

    // 2. Initialize succeeds
    const bool initOk = backend.initialize();

    // 3. Null argument validation cases return kInvalidArgument without crash
    vanguard::render::HardwareBufferHandle hNullBuf = 999;
    vanguard::render::HardwareBufferDescriptor descNullBuf{1, 1, 1, 1, 1, 1};
    const auto nullBufRes = backend.importHardwareBuffer(nullptr, -1, &hNullBuf, &descNullBuf);
    const bool nullBufOk = (nullBufRes == vanguard::render::HardwareBufferImportResult::kInvalidArgument) &&
                           (hNullBuf == vanguard::render::kInvalidHardwareBufferHandle);

    vanguard::render::HardwareBufferDescriptor descNullH{1, 1, 1, 1, 1, 1};
    const auto nullHRes = backend.importHardwareBuffer(ahbA, -1, nullptr, &descNullH);
    const bool nullHOk = (nullHRes == vanguard::render::HardwareBufferImportResult::kInvalidArgument);

    vanguard::render::HardwareBufferHandle hNullDesc = 999;
    const auto nullDescRes = backend.importHardwareBuffer(ahbA, -1, &hNullDesc, nullptr);
    const bool nullDescOk = (nullDescRes == vanguard::render::HardwareBufferImportResult::kInvalidArgument);

    // 4. Valid import of bufferA succeeds; handle nonzero; descriptor width/height/layers/format/usage ok; has true
    vanguard::render::HardwareBufferHandle hA = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descA{};
    const auto importARes = backend.importHardwareBuffer(ahbA, -1, &hA, &descA);
    const bool validImportA = (importARes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                              (hA != vanguard::render::kInvalidHardwareBufferHandle);
    const bool descAOk = (descA.width == static_cast<uint32_t>(width)) &&
                         (descA.height == static_cast<uint32_t>(height)) &&
                         (descA.layers == 1) &&
                         ((descA.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) &&
                         (descA.format != 0);
    const bool hasAAfterImport = backend.hasHardwareBuffer(hA);
    const bool importACheckOk = validImportA && descAOk && hasAAfterImport;

    // 5. Duplicate import of bufferA returns kDuplicateImport; duplicate handle remains zero; original handle still active
    vanguard::render::HardwareBufferHandle hDup = 999;
    vanguard::render::HardwareBufferDescriptor descDup{1, 1, 1, 1, 1, 1};
    const auto dupRes = backend.importHardwareBuffer(ahbA, -1, &hDup, &descDup);
    const bool duplicateOk = (dupRes == vanguard::render::HardwareBufferImportResult::kDuplicateImport) &&
                             (hDup == vanguard::render::kInvalidHardwareBufferHandle);
    const bool hasAAfterDuplicate = backend.hasHardwareBuffer(hA);
    const bool duplicateCheckOk = duplicateOk && hasAAfterDuplicate;

    // 6. renderFrame(handleA) before attach returns kNoSurface (Unit Z foundation)
    const auto renderRes = backend.renderFrame(hA);
    const bool renderNoSurface = (renderRes == vanguard::render::RenderFrameResult::kNoSurface);

    // 7. Import bufferB succeeds with distinct handle; both handles active
    vanguard::render::HardwareBufferHandle hB = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descB{};
    const auto importBRes = backend.importHardwareBuffer(ahbB, -1, &hB, &descB);
    const bool validImportB = (importBRes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                              (hB != vanguard::render::kInvalidHardwareBufferHandle);
    const bool distinctHandles = (hB != hA);
    const bool hasBAfterImport = backend.hasHardwareBuffer(hB);
    const bool hasAStillActive = backend.hasHardwareBuffer(hA);
    const bool importBCheckOk = validImportB && distinctHandles && hasBAfterImport && hasAStillActive;

    // 8. Release handleA returns kSuccess, outReleaseFenceFd >= -1, has false; double release handleA returns kUnknownHandle
    int releaseFenceA = -999;
    const auto releaseARes = backend.releaseHardwareBuffer(hA, &releaseFenceA);
    const bool releaseAOk = (releaseARes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                            (releaseFenceA >= -1);
    const bool hasAAfterRelease = backend.hasHardwareBuffer(hA);

    int doubleReleaseFenceA = -999;
    const auto doubleReleaseARes = backend.releaseHardwareBuffer(hA, &doubleReleaseFenceA);
    const bool doubleReleaseAOk = (doubleReleaseARes == vanguard::render::HardwareBufferImportResult::kUnknownHandle);
    const bool hasBStillActiveAfterReleaseA = backend.hasHardwareBuffer(hB);
    const bool releaseCheckOk = releaseAOk && !hasAAfterRelease && doubleReleaseAOk && hasBStillActiveAfterReleaseA;

    // 9. Shutdown with handleB still active cleans it; after shutdown hasHardwareBuffer(handleB)==false; second shutdown safe
    backend.shutdown();
    const bool hasBAfterShutdown = backend.hasHardwareBuffer(hB);
    const bool isInitAfterShutdown = backend.isInitialized();

    backend.shutdown();
    const bool idempotentShutdownOk = !backend.hasHardwareBuffer(hB) && !backend.isInitialized();
    const bool shutdownCheckOk = !hasBAfterShutdown && !isInitAfterShutdown && idempotentShutdownOk;

    // Close any non-negative fds returned by releaseHardwareBuffer exactly once after capturing
    if (releaseFenceA >= 0) {
        ::close(releaseFenceA);
    }
    if (doubleReleaseFenceA >= 0) {
        ::close(doubleReleaseFenceA);
    }

    // Overall check pass evaluation
    const bool allChecksPass = preInitCheckOk &&
                               initOk &&
                               nullBufOk &&
                               nullHOk &&
                               nullDescOk &&
                               importACheckOk &&
                               duplicateCheckOk &&
                               renderNoSurface &&
                               importBCheckOk &&
                               releaseCheckOk &&
                               shutdownCheckOk;

    const std::string backendLastError = SanitizeString(backend.lastError());

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "preInitImport=" << (preRes == vanguard::render::HardwareBufferImportResult::kBackendNotInitialized ? "rejected_as_expected" : "unexpected_result") << ";"
        << "preInitHandle=" << hPre << ";"
        << "preInitDescriptorZero=" << (preDescZero ? "true" : "false") << ";"
        << "initialize=" << (initOk ? "success" : "failed") << ";"
        << "nullBufferImport=" << (nullBufOk ? "rejected_as_expected" : "failed") << ";"
        << "nullHandleImport=" << (nullHOk ? "rejected_as_expected" : "failed") << ";"
        << "nullDescriptorImport=" << (nullDescOk ? "rejected_as_expected" : "failed") << ";"
        << "validImportA=" << (validImportA ? "success" : "failed") << ";"
        << "handleA=" << hA << ";"
        << "descriptorWidth=" << descA.width << ";"
        << "descriptorHeight=" << descA.height << ";"
        << "descriptorLayers=" << descA.layers << ";"
        << "descriptorFormat=" << descA.format << ";"
        << "descriptorUsageSampled=" << (((descA.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) ? "true" : "false") << ";"
        << "hasAAfterImport=" << (hasAAfterImport ? "true" : "false") << ";"
        << "duplicateImport=" << (duplicateOk ? "rejected_as_expected" : "failed") << ";"
        << "duplicateHandle=" << hDup << ";"
        << "hasAAfterDuplicate=" << (hasAAfterDuplicate ? "true" : "false") << ";"
        << "renderFrame=" << (renderNoSurface ? "no_surface" : "unexpected_result") << ";"
        << "validImportB=" << (validImportB ? "success" : "failed") << ";"
        << "handleB=" << hB << ";"
        << "distinctHandles=" << (distinctHandles ? "true" : "false") << ";"
        << "hasBAfterImport=" << (hasBAfterImport ? "true" : "false") << ";"
        << "releaseA=" << (releaseAOk ? "success" : "failed") << ";"
        << "releaseAFence=" << releaseFenceA << ";"
        << "hasAAfterRelease=" << (hasAAfterRelease ? "true" : "false") << ";"
        << "doubleReleaseA=" << (doubleReleaseAOk ? "rejected_as_expected" : "failed") << ";"
        << "shutdown=" << (!hasBAfterShutdown ? "success" : "failed") << ";"
        << "hasBAfterShutdown=" << (hasBAfterShutdown ? "true" : "false") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=gles_ahb_rgba_import_no_renderFrame;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
