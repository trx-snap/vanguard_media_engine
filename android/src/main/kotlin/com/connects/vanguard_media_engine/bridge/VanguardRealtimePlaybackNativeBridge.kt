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
// - Y5a (P4-AUDIO-REALTIME-PLAYBACK-EXTERNAL-INGEST-SEAM):
//   [ingestRealtimePlaybackGraphSessionExternalPcm16] is the owner-thread
//   PRODUCER entry point for tracks opted into external ingest by
//   `externalIngestTrackMask` at create. Kotlin owns every Android
//   codec/media API; native only copies already-decoded PCM16 from a
//   direct buffer into that track's source ring. Decoder/background
//   threads must never call it directly: route through
//   VanguardRealtimePlaybackTransportStateMachine.ingest/postIngest.
// - Y16 (P4-AUDIO-REALTIME-PLAYBACK-CLOCK-DRIFT-SAMPLE-OWNERSHIP):
//   [recordDriftSampleRealtimePlaybackGraphSession] is the owner-thread
//   entry point that hands ONE Kotlin presentation-clock position to the
//   native worker, which alone stamps its steady clock and records the
//   drift sample on its AudioClock. No Kotlin timebase crosses this seam.
//   Sink/background threads must never call it directly: route through
//   VanguardRealtimePlaybackTransportStateMachine.postDriftSample.
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
    // above 600 s, externalIngestTrackMask negative or with bits at or above
    // trackCount), rig validation failure, worker start failure, or when
    // four sessions are already live. externalIngestTrackMask bit t marks
    // track t as external-ingest (owner-thread producer); 0 = all synthetic.
    external fun createRealtimePlaybackGraphSession(
        sampleRate: Int,
        channelCount: Int,
        maxFramesPerMix: Int,
        trackCount: Int,
        declaredFrameCount: Long,
        externalIngestTrackMask: Int,
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

    // Y5a: copies frameCount interleaved PCM16 frames from byte offset 0 of
    // the direct buffer `src` into external track `trackIndex`'s source
    // ring. expectedStartFrame must equal the track writer's nextWriteFrame
    // (the reply's nextWriteFrame re-anchors the producer after
    // prepare/seek/stop). Statuses: ok, partial_write, ring_full,
    // eos_reached (nonterminal); expected_start_mismatch, awaiting_seek_ack,
    // command_in_flight, format_mismatch, invalid_track, track_not_external,
    // invalid_args, buffer statuses (rejected, no mutation);
    // wrong_owner_thread / not_found / worker_exited / invalid_state.
    external fun ingestRealtimePlaybackGraphSessionExternalPcm16(
        handle: Long,
        trackIndex: Int,
        src: ByteBuffer,
        frameCount: Int,
        sampleRate: Int,
        channelCount: Int,
        expectedStartFrame: Long,
    ): String

    // Y16: records one presentation-clock drift sample on the worker-owned
    // native AudioClock. reportedPtsUs / reportedFrame are the Kotlin
    // presentation clock's position (both must be >= 0); the worker computes
    // `now` and the expected position itself. Statuses: ok; invalid_state
    // (native not playing), invalid_args, no_clock, drift_sample_rejected
    // (nonterminal, no mutation); wrong_owner_thread / not_found /
    // worker_exited / command_busy / command_timeout. Never changes state.
    external fun recordDriftSampleRealtimePlaybackGraphSession(
        handle: Long,
        reportedPtsUs: Long,
        reportedFrame: Long,
    ): String

    external fun snapshotRealtimePlaybackGraphSession(handle: Long): String

    external fun destroyRealtimePlaybackGraphSession(handle: Long): String
}
