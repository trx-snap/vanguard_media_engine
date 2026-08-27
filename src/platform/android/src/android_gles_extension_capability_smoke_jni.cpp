// Unit AI: Android GLES/EGL extension and native-fence capability inventory physical proof JNI bridge.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase1AIGlesExtensionCapabilitySmoke -> jstring

#include <jni.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <GLES3/gl3.h>

#include <cstring>
#include <sstream>
#include <string>

#include "vanguard/render/gles_backend.h"

namespace {

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

bool HasExtension(const std::string& extList, const std::string& extName) {
    if (extList.empty() || extName.empty()) {
        return false;
    }
    size_t pos = 0;
    while ((pos = extList.find(extName, pos)) != std::string::npos) {
        const bool matchStart = (pos == 0 || extList[pos - 1] == ' ');
        const size_t endPos = pos + extName.length();
        const bool matchEnd = (endPos == extList.length() || extList[endPos] == ' ');
        if (matchStart && matchEnd) {
            return true;
        }
        pos += extName.length();
    }
    return false;
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1AIGlesExtensionCapabilitySmoke(
    JNIEnv* env,
    jobject /* this */) {

    vanguard::render::GlesBackend backend;

    // 1. Initial initialize()
    const bool initOk = backend.initialize();

    // 2. Query basic GL properties from initialized backend
    const bool isInitialized = backend.isInitialized();
    const int clientVersion = backend.clientVersion();
    const std::string vendor = SanitizeString(backend.diagnosticVendor());
    const std::string renderer = SanitizeString(backend.diagnosticRenderer());
    const std::string version = SanitizeString(backend.diagnosticVersion());
    const std::string backendLastError = SanitizeString(backend.lastError());

    // 3. Query current EGL display while backend context is current
    const EGLDisplay currentDisplay = eglGetCurrentDisplay();
    const bool eglCurrentDisplayOk = (currentDisplay != EGL_NO_DISPLAY);

    // 4. Query EGL extension string
    std::string eglExtStr;
    if (eglCurrentDisplayOk) {
        const char* s = eglQueryString(currentDisplay, EGL_EXTENSIONS);
        if (s) {
            eglExtStr = s;
        }
    }
    const bool eglExtensionsAvailable = !eglExtStr.empty();

    // 5. Query GL extension string
    std::string glExtStr;
    const GLubyte* s = glGetString(GL_EXTENSIONS);
    if (s) {
        glExtStr = reinterpret_cast<const char*>(s);
    }
    if (glExtStr.empty() && clientVersion >= 3) {
        GLint numExt = 0;
        glGetIntegerv(GL_NUM_EXTENSIONS, &numExt);
        for (GLint i = 0; i < numExt; ++i) {
            const GLubyte* ext = glGetStringi(GL_EXTENSIONS, static_cast<GLuint>(i));
            if (ext) {
                if (!glExtStr.empty()) {
                    glExtStr += " ";
                }
                glExtStr += reinterpret_cast<const char*>(ext);
            }
        }
    }
    const bool glExtensionsAvailable = !glExtStr.empty();

    // 6. Inventory EGL and GL extension strings
    const bool hasEglAndroidImageNativeBuffer = HasExtension(eglExtStr, "EGL_ANDROID_image_native_buffer");
    const bool hasEglAndroidGetNativeClientBuffer = HasExtension(eglExtStr, "EGL_ANDROID_get_native_client_buffer");
    const bool hasEglKhrImageBase = HasExtension(eglExtStr, "EGL_KHR_image_base");
    const bool hasEglAndroidNativeFenceSync = HasExtension(eglExtStr, "EGL_ANDROID_native_fence_sync");
    const bool hasEglKhrFenceSync = HasExtension(eglExtStr, "EGL_KHR_fence_sync");
    const bool hasGlOesEglImage = HasExtension(glExtStr, "GL_OES_EGL_image");
    const bool hasGlOesEglImageExternal = HasExtension(glExtStr, "GL_OES_EGL_image_external");
    const bool hasGlExtYuvTarget = HasExtension(glExtStr, "GL_EXT_YUV_target");

    // 7. Inventory extension symbol availability via eglGetProcAddress
    const bool symbolEglGetNativeClientBufferAndroid = (eglGetProcAddress("eglGetNativeClientBufferANDROID") != nullptr);
    const bool symbolEglCreateImageKhr = (eglGetProcAddress("eglCreateImageKHR") != nullptr);
    const bool symbolEglDestroyImageKhr = (eglGetProcAddress("eglDestroyImageKHR") != nullptr);
    const bool symbolGlEglImageTargetTexture2DOes = (eglGetProcAddress("glEGLImageTargetTexture2DOES") != nullptr);
    const bool symbolEglCreateSyncKhr = (eglGetProcAddress("eglCreateSyncKHR") != nullptr);
    const bool symbolEglDestroySyncKhr = (eglGetProcAddress("eglDestroySyncKHR") != nullptr);
    const bool symbolEglDupNativeFenceFdAndroid = (eglGetProcAddress("eglDupNativeFenceFDANDROID") != nullptr);

    // 8. Shutdown backend
    backend.shutdown();
    const bool shutdown1Ok = (!backend.isInitialized() && backend.clientVersion() == 0);

    // 9. Idempotent shutdown
    backend.shutdown();
    const bool idempotentShutdownOk = (!backend.isInitialized() && backend.clientVersion() == 0);

    // 10. Evaluate overall pass criteria:
    // Core Unit Y/AE symbols and basic backend/display/extensions must pass.
    // Native-fence and OES/YUV booleans are inventory values only.
    const bool allChecksPass = initOk &&
                               isInitialized &&
                               (clientVersion >= 2) &&
                               !vendor.empty() &&
                               !renderer.empty() &&
                               !version.empty() &&
                               eglCurrentDisplayOk &&
                               eglExtensionsAvailable &&
                               glExtensionsAvailable &&
                               symbolEglGetNativeClientBufferAndroid &&
                               symbolEglCreateImageKhr &&
                               symbolEglDestroyImageKhr &&
                               symbolGlEglImageTargetTexture2DOes &&
                               shutdown1Ok &&
                               idempotentShutdownOk;

    std::ostringstream oss;
    oss << "status=" << (allChecksPass ? "PASS" : "FAIL") << ";"
        << "clientVersion=" << clientVersion << ";"
        << "vendor=" << vendor << ";"
        << "renderer=" << renderer << ";"
        << "version=" << version << ";"
        << "initialize=" << (initOk ? "success" : "failed") << ";"
        << "eglCurrentDisplayOk=" << (eglCurrentDisplayOk ? "true" : "false") << ";"
        << "eglExtensionsAvailable=" << (eglExtensionsAvailable ? "true" : "false") << ";"
        << "glExtensionsAvailable=" << (glExtensionsAvailable ? "true" : "false") << ";"
        << "hasEglAndroidImageNativeBuffer=" << (hasEglAndroidImageNativeBuffer ? "true" : "false") << ";"
        << "hasEglAndroidGetNativeClientBuffer=" << (hasEglAndroidGetNativeClientBuffer ? "true" : "false") << ";"
        << "hasEglKhrImageBase=" << (hasEglKhrImageBase ? "true" : "false") << ";"
        << "hasEglAndroidNativeFenceSync=" << (hasEglAndroidNativeFenceSync ? "true" : "false") << ";"
        << "hasEglKhrFenceSync=" << (hasEglKhrFenceSync ? "true" : "false") << ";"
        << "hasGlOesEglImage=" << (hasGlOesEglImage ? "true" : "false") << ";"
        << "hasGlOesEglImageExternal=" << (hasGlOesEglImageExternal ? "true" : "false") << ";"
        << "hasGlExtYuvTarget=" << (hasGlExtYuvTarget ? "true" : "false") << ";"
        << "symbolEglGetNativeClientBufferAndroid=" << (symbolEglGetNativeClientBufferAndroid ? "true" : "false") << ";"
        << "symbolEglCreateImageKhr=" << (symbolEglCreateImageKhr ? "true" : "false") << ";"
        << "symbolEglDestroyImageKhr=" << (symbolEglDestroyImageKhr ? "true" : "false") << ";"
        << "symbolGlEglImageTargetTexture2DOes=" << (symbolGlEglImageTargetTexture2DOes ? "true" : "false") << ";"
        << "symbolEglCreateSyncKhr=" << (symbolEglCreateSyncKhr ? "true" : "false") << ";"
        << "symbolEglDestroySyncKhr=" << (symbolEglDestroySyncKhr ? "true" : "false") << ";"
        << "symbolEglDupNativeFenceFdAndroid=" << (symbolEglDupNativeFenceFdAndroid ? "true" : "false") << ";"
        << "shutdown=" << (shutdown1Ok ? "success" : "failed") << ";"
        << "idempotentShutdown=" << (idempotentShutdownOk ? "success" : "failed") << ";"
        << "proofBoundary=gles_egl_extension_capability_inventory_no_import_no_render_no_product;"
        << "lastError=" << (backendLastError.empty() ? "none" : backendLastError);

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
