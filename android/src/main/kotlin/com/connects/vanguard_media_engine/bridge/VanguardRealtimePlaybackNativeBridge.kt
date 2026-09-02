package com.connects.vanguard_media_engine.bridge

import java.nio.ByteBuffer

// ── VanguardRealtimePlaybackNativeBridge (P4-AUDIO-REALTIME-PLAYBACK-TRANSPORT-CORE, Y1) ─
//
// Externs-only JNI bridge for the production realtime playback graph
// transport session
// (src/platform/android/src/android_phase4_realtime_playback_graph_session_jni.cpp).
// Deliberately separate from [VanguardNativeBridge] so the production
// transport surface does not grow the diagnostic companion object.
//
// Threading contract (enforced natively, fail closed):
// - The thread that calls [createRealtimePlaybackGraphSession] becomes the
//   session's owner thread. Every other entry point except
//   [destroyRealtimePlaybackGraphSession] must run on that thread; any other
//   caller receives `status=wrong_owner_thread` with no mutation.
// - [destroyRealtimePlaybackGraphSession] is any-thread, idempotent, joins
//   the native worker before returning, and answers `status=not_found` on
//   a second call.
//
// Every string reply is a `;`-separated `key=value` list parsed by
// com.connects.vanguard_media_engine.audio_playback_graph.
// VanguardRealtimePlaybackNativeSession; no policy lives here.
object VanguardRealtimePlaybackNativeBridge {
    init {
        // Idempotent: the JVM loads a shared library at most once per class
        // loader, so this coexists with VanguardNativeBridge's own load.
        System.loadLibrary("vanguard_media_engine")
    }

    // Returns an opaque handle > 0, or 0 on invalid arguments (sampleRate
    // outside the primitive range, channelCount not 1/2, maxFramesPerMix
    // not in 1..8192, trackCount not in 1..8, declaredFrameCount <= 0 or
    // above 600 s), rig validation failure, worker start failure, or when
    // four sessions are already live.
    external fun createRealtimePlaybackGraphSession(
        sampleRate: Int,
        channelCount: Int,
        maxFramesPerMix: Int,
        trackCount: Int,
        declaredFrameCount: Long,
    ): Long

    external fun prepareRealtimePlaybackGraphSession(handle: Long): String

    external fun startRealtimePlaybackGraphSession(handle: Long): String

    external fun pauseRealtimePlaybackGraphSession(handle: Long): String

    external fun resumeRealtimePlaybackGraphSession(handle: Long): String

    // targetFrame must be in [0, declaredFrameCount); forward and backward
    // targets are accepted while prepared, playing, paused, or stopped.
    external fun seekRealtimePlaybackGraphSession(handle: Long, targetFrame: Long): String

    external fun stopRealtimePlaybackGraphSession(handle: Long): String

    // Pops up to maxFrames of mixed interleaved little-endian PCM16 into the
    // direct buffer `dst` at byte offset 0. maxFrames == 0 is a legal
    // epoch-only call.
    external fun drainRealtimePlaybackGraphSessionOutputPcm16(
        handle: Long,
        dst: ByteBuffer,
        maxFrames: Int,
    ): String

    external fun snapshotRealtimePlaybackGraphSession(handle: Long): String

    external fun destroyRealtimePlaybackGraphSession(handle: Long): String
}
