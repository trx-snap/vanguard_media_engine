package com.connects.vanguard_media_engine.diagnostics

import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver

// ── AndroidAudioMixBusTimelineNativeSession (P4-AUDIO-MIXBUS-TIMELINE-OWNERSHIP) ─
//
// Thin wrapper around the one-shot
// `runAudioMixBusTimelineNativeSmoke` JNI route
// (android_phase4_audio_mixbus_timeline_jni.cpp), used by
// [AndroidAudioMixBusTimelineDriver]. The native route is fully
// stack-scoped and synchronous: every node/envelope/buffer it creates is
// destroyed before the reply string returns, so there is no handle, no
// registry, no OS resource, and nothing to release on the Kotlin side —
// lifecycle here is a single call that parses the semicolon-delimited
// key/value status reply.
//
// Honest non-claims: diagnostic foundation only — no GraphAudioScheduler
// wiring, no production mixdown change, no export/pass-2 reroute, no
// runtime queue, no backpressure, no realtime sink, no threads, no
// AudioTrack/AAudio, no MediaCodec/MediaExtractor, no file IO, no
// streaming/cache, no iOS, no product/editor UI.
class AndroidAudioMixBusTimelineNativeSession {

    class Failure(val reason: String) : Exception(reason)

    data class NativeReply(
        val raw: String,
        val kv: Map<String, String>,
        val pass: Boolean,
        val reason: String,
    )

    /// Runs the one-shot native diagnostic and parses its status reply.
    /// Throws [Failure] only when the reply itself is malformed (missing
    /// status field); a native FAIL is returned as a parsed reply so the
    /// driver can surface every lane the native side still reported.
    fun runOnce(): NativeReply {
        val diagnostics = VanguardDiagnostics()
        val bridge = VanguardNativeBridge(
            lifecycleObserver = VanguardLifecycleObserver(diagnostics),
            diagnostics = diagnostics,
            codecAdapter = null,
        )
        val raw = bridge.runAudioMixBusTimelineNativeSmoke()
        val kv = parseStatus(raw)
        val status = kv["status"] ?: throw Failure("native_status_field_missing")
        return NativeReply(
            raw = raw,
            kv = kv,
            pass = status == "PASS",
            reason = kv["reason"] ?: "",
        )
    }

    fun booleanField(kv: Map<String, String>, key: String): Boolean =
        when (kv[key]) {
            "true" -> true
            "false" -> false
            else -> throw Failure("missing_or_non_boolean_native_field_$key")
        }

    fun longField(kv: Map<String, String>, key: String): Long =
        kv[key]?.toLongOrNull() ?: throw Failure("missing_native_field_$key")

    fun doubleField(kv: Map<String, String>, key: String): Double =
        kv[key]?.toDoubleOrNull() ?: throw Failure("missing_native_field_$key")

    fun stringField(kv: Map<String, String>, key: String): String =
        kv[key] ?: throw Failure("missing_native_field_$key")

    private fun parseStatus(raw: String): Map<String, String> =
        raw.split(';').mapNotNull { part ->
            val idx = part.indexOf('=')
            if (idx <= 0) null else part.substring(0, idx) to part.substring(idx + 1)
        }.toMap()
}
