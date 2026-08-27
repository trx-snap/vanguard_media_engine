// Phase 1 Unit Z: Android GLES identity renderFrame textured-quad presentation smoke JNI bridge.
//
// Android-only translation unit added via CMake target_sources block.
//
// JNI entry point:
//   runAndroidDagPhase1ZGlesRenderFrameSmoke -> jstring

#include <jni.h>
#include <android/hardware_buffer.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <unistd.h>

#include <sstream>
#include <string>

#include "vanguard/render/gles_backend.h"
#include "vanguard/render/render_transform.h"

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
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1ZGlesRenderFrameSmoke(
    JNIEnv* env,
    jobject /* this */,
    jobject jsurface,
    jobject jbufferA,
    jobject jbufferB,
    jint width,
    jint height) {

    if (!jsurface || !jbufferA || !jbufferB || width <= 0 || height <= 0) {
        std::ostringstream oss;
        oss << "status=FAIL;"
            << "clientVersion=0;"
            << "vendor=;"
            << "renderer=;"
            << "version=;"
            << "preInitRender=not_run;"
            << "preInitLastError=;"
            << "initialize=not_run;"
            << "importA=not_run;"
            << "handleA=0;"
            << "descriptorWidth=0;"
            << "descriptorHeight=0;"
            << "descriptorLayers=0;"
            << "descriptorFormat=0;"
            << "descriptorUsageSampled=false;"
            << "hasAAfterImport=false;"
            << "preAttachRender=not_run;"
            << "preAttachLastError=;"
            << "attach=not_run;"
            << "hasSurfaceAfterAttach=false;"
            << "surfaceKindAfterAttach=none;"
            << "widthAfterAttach=0;"
            << "heightAfterAttach=0;"
            << "invalidHandleRender=not_run;"
            << "invalidHandleLastError=;"
            << "firstRenderA=not_run;"
            << "firstRenderALastError=;"
            << "secondRenderA=not_run;"
            << "hasSurfaceAfterSecond=false;"
            << "surfaceKindAfterSecond=none;"
            << "widthAfterSecond=0;"
            << "heightAfterSecond=0;"
            << "importB=not_run;"
            << "handleB=0;"
            << "distinctHandles=false;"
            << "hasBAfterImport=false;"
            << "renderB=not_run;"
            << "renderBLastError=;"
            << "identityTransformRender=not_run;"
            << "nonIdentityTransformRender=not_run;"
            << "nonIdentityTransformLastError=;"
            << "hasSurfaceAfterTransform=false;"
            << "rot180TransformRender=not_run;"
            << "rot180TransformLastError=;"
            << "rot270TransformRender=not_run;"
            << "rot270TransformLastError=;"
            << "mirrorTransformRender=not_run;"
            << "mirrorTransformLastError=;"
            << "hasSurfaceAfterAllTransforms=false;"
            << "releaseA=not_run;"
            << "releaseAFence=-1;"
            << "hasAAfterRelease=false;"
            << "hasBAfterReleaseA=false;"
            << "releasedHandleRender=not_run;"
            << "releasedHandleLastError=;"
            << "detach=not_run;"
            << "surfaceKindAfterDetach=none;"
            << "postDetachRenderB=not_run;"
            << "postDetachLastError=;"
            << "shutdown=not_run;"
            << "hasBAfterShutdown=false;"
            << "idempotentShutdown=not_run;"
            << "proofBoundary=gles_renderFrame_rgba_texture_quad_transform_uv_no_yuv_no_fence_sync;"
            << "lastError=invalid_arguments";
        return env->NewStringUTF(oss.str().c_str());
    }

    ANativeWindow* window = ANativeWindow_fromSurface(env, jsurface);
    if (!window) {
        std::ostringstream oss;
        oss << "status=FAIL;"
            << "clientVersion=0;"
            << "vendor=;"
            << "renderer=;"
            << "version=;"
            << "preInitRender=not_run;"
            << "preInitLastError=;"
            << "initialize=not_run;"
            << "importA=not_run;"
            << "handleA=0;"
            << "descriptorWidth=0;"
            << "descriptorHeight=0;"
            << "descriptorLayers=0;"
            << "descriptorFormat=0;"
            << "descriptorUsageSampled=false;"
            << "hasAAfterImport=false;"
            << "preAttachRender=not_run;"
            << "preAttachLastError=;"
            << "attach=not_run;"
            << "hasSurfaceAfterAttach=false;"
            << "surfaceKindAfterAttach=none;"
            << "widthAfterAttach=0;"
            << "heightAfterAttach=0;"
            << "invalidHandleRender=not_run;"
            << "invalidHandleLastError=;"
            << "firstRenderA=not_run;"
            << "firstRenderALastError=;"
            << "secondRenderA=not_run;"
            << "hasSurfaceAfterSecond=false;"
            << "surfaceKindAfterSecond=none;"
            << "widthAfterSecond=0;"
            << "heightAfterSecond=0;"
            << "importB=not_run;"
            << "handleB=0;"
            << "distinctHandles=false;"
            << "hasBAfterImport=false;"
            << "renderB=not_run;"
            << "renderBLastError=;"
            << "identityTransformRender=not_run;"
            << "nonIdentityTransformRender=not_run;"
            << "nonIdentityTransformLastError=;"
            << "hasSurfaceAfterTransform=false;"
            << "rot180TransformRender=not_run;"
            << "rot180TransformLastError=;"
            << "rot270TransformRender=not_run;"
            << "rot270TransformLastError=;"
            << "mirrorTransformRender=not_run;"
            << "mirrorTransformLastError=;"
            << "hasSurfaceAfterAllTransforms=false;"
            << "releaseA=not_run;"
            << "releaseAFence=-1;"
            << "hasAAfterRelease=false;"
            << "hasBAfterReleaseA=false;"
            << "releasedHandleRender=not_run;"
            << "releasedHandleLastError=;"
            << "detach=not_run;"
            << "surfaceKindAfterDetach=none;"
            << "postDetachRenderB=not_run;"
            << "postDetachLastError=;"
            << "shutdown=not_run;"
            << "hasBAfterShutdown=false;"
            << "idempotentShutdown=not_run;"
            << "proofBoundary=gles_renderFrame_rgba_texture_quad_transform_uv_no_yuv_no_fence_sync;"
            << "lastError=native_window_from_surface_failed";
        return env->NewStringUTF(oss.str().c_str());
    }

    AHardwareBuffer* ahbA = ResolveAHardwareBufferFromJObject(env, jbufferA);
    AHardwareBuffer* ahbB = ResolveAHardwareBufferFromJObject(env, jbufferB);

    if (!ahbA || !ahbB) {
        ANativeWindow_release(window);
        std::ostringstream oss;
        oss << "status=FAIL;"
            << "clientVersion=0;"
            << "vendor=;"
            << "renderer=;"
            << "version=;"
            << "preInitRender=not_run;"
            << "preInitLastError=;"
            << "initialize=not_run;"
            << "importA=not_run;"
            << "handleA=0;"
            << "descriptorWidth=0;"
            << "descriptorHeight=0;"
            << "descriptorLayers=0;"
            << "descriptorFormat=0;"
            << "descriptorUsageSampled=false;"
            << "hasAAfterImport=false;"
            << "preAttachRender=not_run;"
            << "preAttachLastError=;"
            << "attach=not_run;"
            << "hasSurfaceAfterAttach=false;"
            << "surfaceKindAfterAttach=none;"
            << "widthAfterAttach=0;"
            << "heightAfterAttach=0;"
            << "invalidHandleRender=not_run;"
            << "invalidHandleLastError=;"
            << "firstRenderA=not_run;"
            << "firstRenderALastError=;"
            << "secondRenderA=not_run;"
            << "hasSurfaceAfterSecond=false;"
            << "surfaceKindAfterSecond=none;"
            << "widthAfterSecond=0;"
            << "heightAfterSecond=0;"
            << "importB=not_run;"
            << "handleB=0;"
            << "distinctHandles=false;"
            << "hasBAfterImport=false;"
            << "renderB=not_run;"
            << "renderBLastError=;"
            << "identityTransformRender=not_run;"
            << "nonIdentityTransformRender=not_run;"
            << "nonIdentityTransformLastError=;"
            << "hasSurfaceAfterTransform=false;"
            << "rot180TransformRender=not_run;"
            << "rot180TransformLastError=;"
            << "rot270TransformRender=not_run;"
            << "rot270TransformLastError=;"
            << "mirrorTransformRender=not_run;"
            << "mirrorTransformLastError=;"
            << "hasSurfaceAfterAllTransforms=false;"
            << "releaseA=not_run;"
            << "releaseAFence=-1;"
            << "hasAAfterRelease=false;"
            << "hasBAfterReleaseA=false;"
            << "releasedHandleRender=not_run;"
            << "releasedHandleLastError=;"
            << "detach=not_run;"
            << "surfaceKindAfterDetach=none;"
            << "postDetachRenderB=not_run;"
            << "postDetachLastError=;"
            << "shutdown=not_run;"
            << "hasBAfterShutdown=false;"
            << "idempotentShutdown=not_run;"
            << "proofBoundary=gles_renderFrame_rgba_texture_quad_transform_uv_no_yuv_no_fence_sync;"
            << "lastError=hardware_buffer_from_jobject_failed";
        return env->NewStringUTF(oss.str().c_str());
    }

    vanguard::render::GlesBackend backend;

    // 1. Pre-init renderFrame(kInvalidHardwareBufferHandle) returns kBackendNotInitialized and lastError "backend_not_initialized"
    const auto preInitRenderRes = backend.renderFrame(vanguard::render::kInvalidHardwareBufferHandle);
    const std::string preInitLastError = SanitizeString(backend.lastError());
    const bool preInitRenderOk = (preInitRenderRes == vanguard::render::RenderFrameResult::kBackendNotInitialized) &&
                                 (preInitLastError == "backend_not_initialized");

    // 2. Initialize succeeds and reports clientVersion >= 2, non-empty vendor/renderer/version
    const bool initOk = backend.initialize();
    const bool isInitAfterInit = backend.isInitialized();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const bool initCheckOk = initOk && isInitAfterInit && (clientVersion >= 2) &&
                             !vendor.empty() && !renderer.empty() && !version.empty();

    // 3. Import buffer A succeeds; handleA > 0; descriptor matches width/height/layers/usage sampled; has true
    vanguard::render::HardwareBufferHandle handleA = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descA{};
    const auto importARes = backend.importHardwareBuffer(ahbA, -1, &handleA, &descA);
    const bool hasAAfterImport = backend.hasHardwareBuffer(handleA);
    const bool importAOk = (importARes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                           (handleA != vanguard::render::kInvalidHardwareBufferHandle) &&
                           (descA.width == static_cast<uint32_t>(width)) &&
                           (descA.height == static_cast<uint32_t>(height)) &&
                           (descA.layers == 1) &&
                           ((descA.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) &&
                           (descA.format != 0) &&
                           hasAAfterImport;

    // 4. renderFrame(handleA) before attach returns kNoSurface with lastError "no_surface_attached"
    const auto preAttachRenderRes = backend.renderFrame(handleA);
    const std::string preAttachLastError = SanitizeString(backend.lastError());
    const bool preAttachRenderOk = (preAttachRenderRes == vanguard::render::RenderFrameResult::kNoSurface) &&
                                   (preAttachLastError == "no_surface_attached");

    // 5. Attach surface succeeds; active surface kind "window"; dimensions match
    const bool attachOk = backend.attachSurface(window, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    const bool hasSurfaceAfterAttach = backend.hasSurface();
    const std::string surfaceKindAfterAttach = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterAttach = backend.surfaceWidth();
    const uint32_t heightAfterAttach = backend.surfaceHeight();
    const bool attachCheckOk = attachOk && hasSurfaceAfterAttach &&
                               (surfaceKindAfterAttach == "window") &&
                               (widthAfterAttach == static_cast<uint32_t>(width)) &&
                               (heightAfterAttach == static_cast<uint32_t>(height));

    // 6. renderFrame(kInvalidHardwareBufferHandle) after attach returns kInvalidBufferHandle with lastError "invalid_buffer_handle"
    const auto invalidHandleRenderRes = backend.renderFrame(vanguard::render::kInvalidHardwareBufferHandle);
    const std::string invalidHandleLastError = SanitizeString(backend.lastError());
    const bool invalidHandleRenderOk = (invalidHandleRenderRes == vanguard::render::RenderFrameResult::kInvalidBufferHandle) &&
                                       (invalidHandleLastError == "invalid_buffer_handle");

    // 7. First renderFrame(handleA) returns kSuccess and clears lastError
    const auto firstRenderARes = backend.renderFrame(handleA);
    const std::string firstRenderALastError = SanitizeString(backend.lastError());
    const bool firstRenderAOk = (firstRenderARes == vanguard::render::RenderFrameResult::kSuccess) &&
                                (firstRenderALastError.empty() || firstRenderALastError == "none");

    // 8. Second renderFrame(handleA) returns kSuccess and surface remains attached/kind window/dimensions unchanged
    const auto secondRenderARes = backend.renderFrame(handleA);
    const std::string secondRenderALastError = SanitizeString(backend.lastError());
    const bool hasSurfaceAfterSecond = backend.hasSurface();
    const std::string surfaceKindAfterSecond = SanitizeString(backend.activeSurfaceKind());
    const uint32_t widthAfterSecond = backend.surfaceWidth();
    const uint32_t heightAfterSecond = backend.surfaceHeight();
    const bool secondRenderAOk = (secondRenderARes == vanguard::render::RenderFrameResult::kSuccess) &&
                                 (secondRenderALastError.empty() || secondRenderALastError == "none") &&
                                 hasSurfaceAfterSecond &&
                                 (surfaceKindAfterSecond == "window") &&
                                 (widthAfterSecond == static_cast<uint32_t>(width)) &&
                                 (heightAfterSecond == static_cast<uint32_t>(height));

    // 9. Import buffer B succeeds; handleB > 0 and distinct from handleA; both handles active
    vanguard::render::HardwareBufferHandle handleB = vanguard::render::kInvalidHardwareBufferHandle;
    vanguard::render::HardwareBufferDescriptor descB{};
    const auto importBRes = backend.importHardwareBuffer(ahbB, -1, &handleB, &descB);
    const bool distinctHandles = (handleB != handleA) && (handleB != vanguard::render::kInvalidHardwareBufferHandle);
    const bool hasBAfterImport = backend.hasHardwareBuffer(handleB);
    const bool hasAStillActive = backend.hasHardwareBuffer(handleA);
    const bool importBOk = (importBRes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                           distinctHandles &&
                           hasBAfterImport &&
                           hasAStillActive;

    // 10. renderFrame(handleB) returns kSuccess
    const auto renderBRes = backend.renderFrame(handleB);
    const std::string renderBLastError = SanitizeString(backend.lastError());
    const bool renderBOk = (renderBRes == vanguard::render::RenderFrameResult::kSuccess) &&
                           (renderBLastError.empty() || renderBLastError == "none");

    // 11. Identity transform overload (VideoFrameTransform{rotationDegrees=0, mirrorHorizontal=false}) on handleA returns kSuccess
    const vanguard::render::VideoFrameTransform identityTransform{0, false};
    const auto identityTransformRes = backend.renderFrame(handleA, identityTransform);
    const std::string identityTransformLastError = SanitizeString(backend.lastError());
    const bool identityTransformOk = (identityTransformRes == vanguard::render::RenderFrameResult::kSuccess) &&
                                     (identityTransformLastError.empty() || identityTransformLastError == "none");

    // 12. Non-identity transform overload (rotationDegrees=90) returns kSuccess; surface remains attached
    const vanguard::render::VideoFrameTransform rot90Transform{90, false};
    const auto nonIdentityTransformRes = backend.renderFrame(handleA, rot90Transform);
    const std::string nonIdentityTransformLastError = SanitizeString(backend.lastError());
    const bool hasSurfaceAfterTransform = backend.hasSurface();
    const bool nonIdentityTransformOk = (nonIdentityTransformRes == vanguard::render::RenderFrameResult::kSuccess) &&
                                        (nonIdentityTransformLastError.empty() || nonIdentityTransformLastError == "none") &&
                                        hasSurfaceAfterTransform;

    // 12b. rot180 transform overload (VideoFrameTransform{180, false}) returns kSuccess; surface remains attached
    const vanguard::render::VideoFrameTransform rot180Transform{180, false};
    const auto rot180TransformRes = backend.renderFrame(handleA, rot180Transform);
    const std::string rot180TransformLastError = SanitizeString(backend.lastError());
    const bool hasSurfaceAfterRot180 = backend.hasSurface();
    const bool rot180TransformOk = (rot180TransformRes == vanguard::render::RenderFrameResult::kSuccess) &&
                                   (rot180TransformLastError.empty() || rot180TransformLastError == "none") &&
                                   hasSurfaceAfterRot180;

    // 12c. rot270 transform overload (VideoFrameTransform{270, false}) returns kSuccess; surface remains attached
    const vanguard::render::VideoFrameTransform rot270Transform{270, false};
    const auto rot270TransformRes = backend.renderFrame(handleA, rot270Transform);
    const std::string rot270TransformLastError = SanitizeString(backend.lastError());
    const bool hasSurfaceAfterRot270 = backend.hasSurface();
    const bool rot270TransformOk = (rot270TransformRes == vanguard::render::RenderFrameResult::kSuccess) &&
                                   (rot270TransformLastError.empty() || rot270TransformLastError == "none") &&
                                   hasSurfaceAfterRot270;

    // 12d. mirror transform overload (VideoFrameTransform{0, true}) returns kSuccess; surface remains attached
    const vanguard::render::VideoFrameTransform mirrorTransform{0, true};
    const auto mirrorTransformRes = backend.renderFrame(handleA, mirrorTransform);
    const std::string mirrorTransformLastError = SanitizeString(backend.lastError());
    const bool hasSurfaceAfterMirror = backend.hasSurface();
    const bool mirrorTransformOk = (mirrorTransformRes == vanguard::render::RenderFrameResult::kSuccess) &&
                                   (mirrorTransformLastError.empty() || mirrorTransformLastError == "none") &&
                                   hasSurfaceAfterMirror;

    const bool hasSurfaceAfterAllTransforms = backend.hasSurface();

    // 13. Release handleA succeeds; releaseFenceFd >= -1; has handleA false, handleB true
    int releaseFenceA = -999;
    const auto releaseARes = backend.releaseHardwareBuffer(handleA, &releaseFenceA);
    const bool hasAAfterRelease = backend.hasHardwareBuffer(handleA);
    const bool hasBAfterReleaseA = backend.hasHardwareBuffer(handleB);
    const bool releaseAOk = (releaseARes == vanguard::render::HardwareBufferImportResult::kSuccess) &&
                            (releaseFenceA >= -1) &&
                            !hasAAfterRelease &&
                            hasBAfterReleaseA;

    // 14. Render released handleA after attach returns kInvalidBufferHandle with lastError "invalid_buffer_handle"
    const auto releasedHandleRenderRes = backend.renderFrame(handleA);
    const std::string releasedHandleLastError = SanitizeString(backend.lastError());
    const bool releasedHandleRenderOk = (releasedHandleRenderRes == vanguard::render::RenderFrameResult::kInvalidBufferHandle) &&
                                        (releasedHandleLastError == "invalid_buffer_handle");

    // 15. Detach surface succeeds; active surface kind "offscreen"; render handleB after detach returns kNoSurface with lastError "no_surface_attached"
    backend.detachSurface();
    const bool hasSurfaceAfterDetach = backend.hasSurface();
    const std::string surfaceKindAfterDetach = SanitizeString(backend.activeSurfaceKind());
    const auto postDetachRenderBRes = backend.renderFrame(handleB);
    const std::string postDetachLastError = SanitizeString(backend.lastError());
    const bool detachCheckOk = !hasSurfaceAfterDetach &&
                               (surfaceKindAfterDetach == "offscreen") &&
                               (postDetachRenderBRes == vanguard::render::RenderFrameResult::kNoSurface) &&
                               (postDetachLastError == "no_surface_attached");

    // 16. Shutdown with handleB still active cleans it; has handleB false; second shutdown is safe
    backend.shutdown();
    const bool hasBAfterShutdown = backend.hasHardwareBuffer(handleB);
    const bool isInitAfterShutdown = backend.isInitialized();
    backend.shutdown();
    const bool idempotentShutdownOk = !backend.hasHardwareBuffer(handleB) && !backend.isInitialized();
    const bool shutdownCheckOk = !hasBAfterShutdown && !isInitAfterShutdown && idempotentShutdownOk;

    // Release ANativeWindow reference owned by JNI harness
    ANativeWindow_release(window);

    // Close any non-negative fds returned by releaseHardwareBuffer exactly once after capturing
    if (releaseFenceA >= 0) {
        ::close(releaseFenceA);
    }

    const bool allChecksPass = preInitRenderOk &&
                               initCheckOk &&
                               importAOk &&
                               preAttachRenderOk &&
                               attachCheckOk &&
                               invalidHandleRenderOk &&
                               firstRenderAOk &&
                               secondRenderAOk &&
                               importBOk &&
                               renderBOk &&
                               identityTransformOk &&
                               nonIdentityTransformOk &&
                               rot180TransformOk &&
                               rot270TransformOk &&
                               mirrorTransformOk &&
                               hasSurfaceAfterAllTransforms &&
                               releaseAOk &&
                               releasedHandleRenderOk &&
                               detachCheckOk &&
                               shutdownCheckOk;

    const std::string backendLastError = SanitizeString(backend.lastError());

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "preInitRender=" << (preInitRenderOk ? "rejected_as_expected" : "failed") << ";"
        << "preInitLastError=" << preInitLastError << ";"
        << "initialize=" << (initCheckOk ? "success" : "failed") << ";"
        << "importA=" << (importAOk ? "success" : "failed") << ";"
        << "handleA=" << handleA << ";"
        << "descriptorWidth=" << descA.width << ";"
        << "descriptorHeight=" << descA.height << ";"
        << "descriptorLayers=" << descA.layers << ";"
        << "descriptorFormat=" << descA.format << ";"
        << "descriptorUsageSampled=" << (((descA.usage & AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE) != 0) ? "true" : "false") << ";"
        << "hasAAfterImport=" << (hasAAfterImport ? "true" : "false") << ";"
        << "preAttachRender=" << (preAttachRenderOk ? "rejected_as_expected" : "failed") << ";"
        << "preAttachLastError=" << preAttachLastError << ";"
        << "attach=" << (attachCheckOk ? "success" : "failed") << ";"
        << "hasSurfaceAfterAttach=" << (hasSurfaceAfterAttach ? "true" : "false") << ";"
        << "surfaceKindAfterAttach=" << surfaceKindAfterAttach << ";"
        << "widthAfterAttach=" << widthAfterAttach << ";"
        << "heightAfterAttach=" << heightAfterAttach << ";"
        << "invalidHandleRender=" << (invalidHandleRenderOk ? "rejected_as_expected" : "failed") << ";"
        << "invalidHandleLastError=" << invalidHandleLastError << ";"
        << "firstRenderA=" << (firstRenderAOk ? "success" : "failed") << ";"
        << "firstRenderALastError=" << firstRenderALastError << ";"
        << "secondRenderA=" << (secondRenderAOk ? "success" : "failed") << ";"
        << "hasSurfaceAfterSecond=" << (hasSurfaceAfterSecond ? "true" : "false") << ";"
        << "surfaceKindAfterSecond=" << surfaceKindAfterSecond << ";"
        << "widthAfterSecond=" << widthAfterSecond << ";"
        << "heightAfterSecond=" << heightAfterSecond << ";"
        << "importB=" << (importBOk ? "success" : "failed") << ";"
        << "handleB=" << handleB << ";"
        << "distinctHandles=" << (distinctHandles ? "true" : "false") << ";"
        << "hasBAfterImport=" << (hasBAfterImport ? "true" : "false") << ";"
        << "renderB=" << (renderBOk ? "success" : "failed") << ";"
        << "renderBLastError=" << renderBLastError << ";"
        << "identityTransformRender=" << (identityTransformOk ? "success" : "failed") << ";"
        << "nonIdentityTransformRender=" << (nonIdentityTransformOk ? "success" : "failed") << ";"
        << "nonIdentityTransformLastError=" << nonIdentityTransformLastError << ";"
        << "hasSurfaceAfterTransform=" << (hasSurfaceAfterTransform ? "true" : "false") << ";"
        << "rot180TransformRender=" << (rot180TransformOk ? "success" : "failed") << ";"
        << "rot180TransformLastError=" << rot180TransformLastError << ";"
        << "rot270TransformRender=" << (rot270TransformOk ? "success" : "failed") << ";"
        << "rot270TransformLastError=" << rot270TransformLastError << ";"
        << "mirrorTransformRender=" << (mirrorTransformOk ? "success" : "failed") << ";"
        << "mirrorTransformLastError=" << mirrorTransformLastError << ";"
        << "hasSurfaceAfterAllTransforms=" << (hasSurfaceAfterAllTransforms ? "true" : "false") << ";"
        << "releaseA=" << (releaseAOk ? "success" : "failed") << ";"
        << "releaseAFence=" << releaseFenceA << ";"
        << "hasAAfterRelease=" << (hasAAfterRelease ? "true" : "false") << ";"
        << "hasBAfterReleaseA=" << (hasBAfterReleaseA ? "true" : "false") << ";"
        << "releasedHandleRender=" << (releasedHandleRenderOk ? "rejected_as_expected" : "failed") << ";"
        << "releasedHandleLastError=" << releasedHandleLastError << ";"
        << "detach=" << (detachCheckOk ? "success" : "failed") << ";"
        << "surfaceKindAfterDetach=" << surfaceKindAfterDetach << ";"
        << "postDetachRenderB=" << (detachCheckOk ? "rejected_as_expected" : "failed") << ";"
        << "postDetachLastError=" << postDetachLastError << ";"
        << "shutdown=" << (shutdownCheckOk ? "success" : "failed") << ";"
        << "hasBAfterShutdown=" << (hasBAfterShutdown ? "true" : "false") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=gles_renderFrame_rgba_texture_quad_transform_uv_no_yuv_no_fence_sync;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
