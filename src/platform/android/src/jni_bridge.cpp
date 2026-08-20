#include <jni.h>
#include "vanguard/platform/android_backend_probe.h"
#include "vanguard/core/logging.h"

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    vanguard::core::Logger::log("Vanguard JNI_OnLoad");
    return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_probeCapabilities(JNIEnv* env, jobject /* this */) {
    auto caps = vanguard::platform::AndroidProbeBackendCapability();
    
    // Convert to Kotlin BackendCapabilityReport
    jclass reportClass = env->FindClass("com/connects/vanguard_media_engine/diagnostics/BackendCapabilityReport");
    if (!reportClass) return nullptr;
    
    jmethodID ctor = env->GetMethodID(reportClass, "<init>", "(ZILjava/lang/String;)V");
    if (!ctor) return nullptr;
    
    int selectedInt = (caps.selected == vanguard::render::RenderBackendType::kVulkan) ? 0 : 
                      (caps.selected == vanguard::render::RenderBackendType::kGles) ? 1 : 2;
                      
    jstring reasonStr = env->NewStringUTF(caps.fallbackReason.c_str());
    jobject report = env->NewObject(reportClass, ctor, caps.vulkanSupported, selectedInt, reasonStr);
    
    return report;
}
