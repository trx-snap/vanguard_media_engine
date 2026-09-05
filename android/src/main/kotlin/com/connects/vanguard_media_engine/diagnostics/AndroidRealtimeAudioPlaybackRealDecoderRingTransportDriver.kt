package com.connects.vanguard_media_engine.diagnostics

import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackFrameSource
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackTransportDriver

// ── AndroidRealtimeAudioPlaybackRealDecoderRingTransportDriver (P4-AUDIO-REALTIME-PLAYBACK-RING-TRANSPORT-SESSION-INTEGRATION, Y21) ─
//
// Diagnostics-owned [VanguardRealtimeAudioPlaybackTransportDriver] adapter
// wrapping the existing Y18c real-decoder ring frame source
// [AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource]: maps its
// frozen [AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Geometry]
// to the driver's primitive geometry fields and its
// [AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.currentStage]
// / [AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.currentFailureReason]
// to [isAlive] / [exitReason] / [currentStageLabel] / [isEosTerminal]. The
// ring already implements the production
// [VanguardRealtimeAudioPlaybackFrameSource] seam directly (Y18c class
// comment), so [frameSource] returns the wrapped ring instance itself,
// unwrapped, adding no second indirection onto the sink's hot drain /
// postDriftSample path. Only that one production seam and this driver
// interface's primitives are exposed here; the ring's own diagnostics-only
// seek control surface and its [Geometry] / [Stage] types never cross into
// [com.connects.vanguard_media_engine.audio_playback_graph]. Y22
// (P4-AUDIO-REALTIME-PLAYBACK-RING-TRANSPORT-SESSION-PAUSE-RESUME): the
// driver's four bounded pause/resume primitives map 1:1 onto the ring's
// verified Y19 cycle -- [prepareForPause] -> [quiesceFeedForPause], [pause]
// -> [pauseTransport], [confirmHold] -> [assertPausedHoldFrozen], [resume]
// -> [resumeTransport] -- each a Boolean-only forward with no ring type or
// ring-specific name leaving this class.
//
// Ownership: this adapter owns no thread and does not construct the ring
// itself -- the caller builds an
// [AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource] from the
// driver [VanguardRealtimeAudioPlaybackTransportDriver.Context] the session
// hands to the factory, then wraps it here. [open] / [start] / [cancel] /
// [close] forward 1:1 onto the ring's own
// [AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.open] /
// [startTransport] / [cancel] / [close]; the verified ring class itself is
// untouched.
class AndroidRealtimeAudioPlaybackRealDecoderRingTransportDriver(
    private val ring: AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource,
) : VanguardRealtimeAudioPlaybackTransportDriver {

    private companion object {
        val EOS_STAGES = setOf(
            AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.EOS_SET,
            AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.CLOSING,
            AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.CLOSED,
        )
        val TERMINAL_STAGES = setOf(
            AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.CLOSED,
            AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.FAILED,
        )
    }

    override val sampleRate: Int get() = ring.frozenGeometry?.sampleRate ?: -1
    override val channelCount: Int get() = ring.frozenGeometry?.channelCount ?: -1
    override val maxFramesPerMix: Int get() = ring.frozenGeometry?.maxFramesPerMix ?: -1
    override val declaredFrameCount: Long get() = ring.frozenGeometry?.expectedFrames ?: -1L

    // The ring implements the production frame-source seam directly (class
    // comment): returned unwrapped, never re-wrapped.
    override val frameSource: VanguardRealtimeAudioPlaybackFrameSource get() = ring

    override val isAlive: Boolean get() = ring.currentStage !in TERMINAL_STAGES

    override val exitReason: String get() = ring.currentFailureReason

    override val currentStageLabel: String get() = ring.currentStage.name.lowercase()

    override val isEosTerminal: Boolean get() = ring.currentStage in EOS_STAGES

    override fun open(timeoutMs: Long): Boolean = ring.open(timeoutMs)

    override fun start(timeoutMs: Long): Boolean = ring.startTransport(timeoutMs)

    override fun cancel() = ring.cancel()

    override fun close(timeoutMs: Long): Boolean = ring.close(timeoutMs)

    // Y22: the ring's verified pause/resume cycle, forwarded 1:1 (class comment).
    override val supportsPauseResume: Boolean get() = true

    override fun prepareForPause(timeoutMs: Long): Boolean = ring.quiesceFeedForPause(timeoutMs)

    override fun pause(timeoutMs: Long): Boolean = ring.pauseTransport(timeoutMs)

    override fun confirmHold(timeoutMs: Long): Boolean = ring.assertPausedHoldFrozen(timeoutMs)

    override fun resume(timeoutMs: Long): Boolean = ring.resumeTransport(timeoutMs)
}
