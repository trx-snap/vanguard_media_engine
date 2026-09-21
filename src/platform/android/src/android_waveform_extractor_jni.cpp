#include <jni.h>
#include <string>
#include <vector>
#include <android/log.h>
#include "vg_native_waveform_extractor.h"

#define LOG_TAG "VGNativeWaveformJni"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_nativeExtractWaveform(
    JNIEnv* env,
    jobject /* thiz */,
    jstring jpath,
    jint samplesPerSecond,
    jdouble maxDurationSeconds,
    jdoubleArray joutDuration
) {
    if (!jpath || samplesPerSecond < 1 || maxDurationSeconds <= 0.0) {
        return nullptr;
    }

    const char* pathChars = env->GetStringUTFChars(jpath, nullptr);
    if (!pathChars) {
        return nullptr;
    }

    std::string path(pathChars);
    env->ReleaseStringUTFChars(jpath, pathChars);

    vanguard::VgNativeWaveformResult result = vanguard::VgNativeWaveformExtractor::extract(
        path,
        samplesPerSecond,
        maxDurationSeconds
    );

    if (!result.success || result.samples.empty()) {
        LOGD("Native waveform extraction bypassed for '%s': %s",
             path.c_str(), result.errorMessage.c_str());
        return nullptr;
    }

    if (joutDuration && env->GetArrayLength(joutDuration) >= 1) {
        jdouble dur = (jdouble)result.durationSeconds;
        env->SetDoubleArrayRegion(joutDuration, 0, 1, &dur);
    }

    jfloatArray jSamples = env->NewFloatArray((jsize)result.samples.size());
    if (!jSamples) {
        LOGW("Failed to allocate jfloatArray of size %zu", result.samples.size());
        return nullptr;
    }

    env->SetFloatArrayRegion(jSamples, 0, (jsize)result.samples.size(), result.samples.data());
    return jSamples;
}

// Also provide non-companion signature in case method is called on instance or companion
extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_nativeExtractWaveform(
    JNIEnv* env,
    jclass /* clazz */,
    jstring jpath,
    jint samplesPerSecond,
    jdouble maxDurationSeconds,
    jdoubleArray joutDuration
) {
    return Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_nativeExtractWaveform(
        env,
        nullptr,
        jpath,
        samplesPerSecond,
        maxDurationSeconds,
        joutDuration
    );
}
