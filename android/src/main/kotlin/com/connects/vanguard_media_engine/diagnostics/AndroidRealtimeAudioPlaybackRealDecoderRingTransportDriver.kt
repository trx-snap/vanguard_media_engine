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
// ring-specific name leaving this class. Y23
// (P4-AUDIO-REALTIME-PLAYBACK-RING-TRANSPORT-SESSION-SEEK): the driver's two
// bounded seek primitives map 1:1 onto the ring's verified Y20 forward seek
// -- [prepareForSeek] -> [quiesceFeedForSeek], [seek] -> [seekTransport] --
// [framesConsumedBySinkObserved] onto the ring's own
// [AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.framesReadBySinkObserved],
// and [earliestSeekHoldFrame] onto a conservative frame computed here from
// the frozen geometry, the ring's default ring capacities AND the native
// worker's one-second timing gate (the ring exposes no explicit earliest
// hold; see [earliestSeekHoldFrame] and [conservativeEarliestSeekHoldFrame]).
// A forwarded control the ring refuses (Boolean false) does not fail the
// ring, so [exitReason] stays empty per its contract; the ring's typed
// [AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.PauseResumeTelemetry.lastControlRejectReason]
// is instead appended to [currentStageLabel] (the session's failure-label
// fallback) so a rejected control names its cause, not only the stage.
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

    companion object {
        private val EOS_STAGES = setOf(
            AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.EOS_SET,
            AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.CLOSING,
            AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.CLOSED,
        )
        private val TERMINAL_STAGES = setOf(
            AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.CLOSED,
            AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.FAILED,
        )
        // Y23: feed lead over the sink the hold frame must clear (comment on
        // [earliestSeekHoldFrame]): one default source ring + one default
        // output ring.
        val SEEK_HOLD_LEAD_FRAMES: Long =
            AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.DEFAULT_SOURCE_RING_CAPACITY_FRAMES.toLong() +
                AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.DEFAULT_OUTPUT_RING_CAPACITY_FRAMES.toLong()

        private fun alignUp(v: Long, window: Long): Long = (v + window - 1L) / window * window

        // Native worker one-second timing gate in frames (the same F1 the
        // standalone Y20 scenario derives): the worker closes its timing
        // gate only once the dispatch cursor passed
        // ceil(NATIVE_TIMING_WARMUP_FRAMES / window) * window + sampleRate,
        // and the native session rejects a seek whose hold sits at or below
        // it (seek_hold_below_native_timing_gate). Pure geometry math.
        fun nativeTimingGateFrames(sampleRate: Int, window: Long): Long =
            alignUp(AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.NATIVE_TIMING_WARMUP_FRAMES, window) +
                sampleRate.toLong()

        // Lowest window-aligned hold frame STRICTLY past the native timing
        // gate (mirrors the standalone Y20 alignUp(F1 + 1)).
        fun nativeTimingGateHoldFloorFrames(sampleRate: Int, window: Long): Long =
            alignUp(nativeTimingGateFrames(sampleRate, window) + 1L, window)

        // The driver's earliest seek hold: the larger of the window-aligned
        // feed-lead bound (sink consumption + one source ring + one output
        // ring) and the native timing gate floor above. Both bounds are
        // window-aligned, so the maximum is too; the session then places
        // H = alignUp(E + preSeekHoldWindows * window) > E > F1, which can
        // never fall below the native gate for any preSeekHoldWindows >= 1.
        fun conservativeEarliestSeekHoldFrame(framesConsumedBySink: Long, sampleRate: Int, window: Long): Long {
            if (window <= 0L || sampleRate <= 0) return -1L
            val consumed = maxOf(0L, framesConsumedBySink)
            val leadBound = alignUp(consumed + SEEK_HOLD_LEAD_FRAMES, window)
            return maxOf(leadBound, nativeTimingGateHoldFloorFrames(sampleRate, window))
        }
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

    // Typed reason of the most recent forwarded control the ring refused
    // (class comment); empty until a control returns false. Read-only view
    // of the ring's own telemetry field, captured at the refusal.
    @Volatile private var lastControlRejectReason: String = ""

    private fun forwardControl(accepted: Boolean): Boolean {
        if (!accepted) {
            val reason = ring.telemetry().pauseResume.lastControlRejectReason
            lastControlRejectReason = reason.ifEmpty { "control_rejected_without_reason" }
        }
        return accepted
    }

    override val currentStageLabel: String
        get() {
            val stage = ring.currentStage.name.lowercase()
            val reject = lastControlRejectReason
            return if (reject.isEmpty()) stage else "$stage:$reject"
        }

    override val isEosTerminal: Boolean get() = ring.currentStage in EOS_STAGES

    override fun open(timeoutMs: Long): Boolean = ring.open(timeoutMs)

    override fun start(timeoutMs: Long): Boolean = ring.startTransport(timeoutMs)

    override fun cancel() = ring.cancel()

    override fun close(timeoutMs: Long): Boolean = ring.close(timeoutMs)

    // Y22: the ring's verified pause/resume cycle, forwarded 1:1 (class comment).
    override val supportsPauseResume: Boolean get() = true

    override fun prepareForPause(timeoutMs: Long): Boolean = forwardControl(ring.quiesceFeedForPause(timeoutMs))

    override fun pause(timeoutMs: Long): Boolean = forwardControl(ring.pauseTransport(timeoutMs))

    override fun confirmHold(timeoutMs: Long): Boolean = forwardControl(ring.assertPausedHoldFrozen(timeoutMs))

    override fun resume(timeoutMs: Long): Boolean = forwardControl(ring.resumeTransport(timeoutMs))

    // Y23: the ring's verified forward seek, forwarded 1:1 (class comment).
    override val supportsSeek: Boolean get() = true

    override val framesConsumedBySinkObserved: Long get() = ring.framesReadBySinkObserved

    // Conservative exclusive lower bound for the hold frame (adapter-private
    // computation; the ring has no explicit earliest), the maximum of two
    // window-aligned bounds (see [conservativeEarliestSeekHoldFrame]):
    //  1. Feed lead: the ring commits up to one output ring before Start
    //     (pre-start fill quota) and its feed may then run ahead of the
    //     sink by up to one source ring plus one output ring, so a hold
    //     frame at or below (sink read + source ring + output ring) could
    //     already be committed when the feed cap is armed. Sized from the
    //     ring's DEFAULT ring capacities (its constructed capacities are
    //     private to it); the ring's own arm-time check
    //     (real_ring_seek_hold_already_passed) remains the authoritative
    //     fail-closed guard for a non-default construction.
    //  2. Native timing gate: the native session refuses a seek whose hold
    //     sits at or below the worker's one-second timing gate F1 =
    //     alignUp(NATIVE_TIMING_WARMUP_FRAMES) + sampleRate
    //     (seek_hold_below_native_timing_gate), so the earliest hold is
    //     never below the first window boundary strictly past F1. The
    //     native check itself is untouched and remains authoritative.
    // Window-aligned; -1 until the geometry is frozen.
    override val earliestSeekHoldFrame: Long
        get() {
            val g = ring.frozenGeometry ?: return -1L
            return conservativeEarliestSeekHoldFrame(
                framesConsumedBySink = ring.framesReadBySinkObserved,
                sampleRate = g.sampleRate,
                window = g.maxFramesPerMix.toLong(),
            )
        }

    override fun prepareForSeek(holdFrame: Long, timeoutMs: Long): Boolean = forwardControl(ring.quiesceFeedForSeek(holdFrame, timeoutMs))

    override fun seek(targetFrame: Long, timeoutMs: Long): Boolean = forwardControl(ring.seekTransport(targetFrame, timeoutMs))
}
