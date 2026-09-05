package com.connects.vanguard_media_engine.audio_playback_graph

import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import java.nio.ByteBuffer

// ── VanguardRealtimeAudioPlaybackFrameSource (P4-AUDIO-REALTIME-PLAYBACK-FRAME-SOURCE-SEAM, Y18a) ─
//
// The ONE seam through which [VanguardRealtimeAudioPlaybackSinkBridge] pulls
// mixed PCM16 and hands back its drift samples. It exposes exactly the four
// touches the sink already made on the caller-owned
// [VanguardRealtimePlaybackTransportStateMachine] (owner-thread identity,
// generation, state label for a stall reason, drain, drift-sample post) and
// nothing else: no transport command, no clock, no timebase, no pacing.
// Y18a adds the seam only; [VanguardRealtimePlaybackStateMachineFrameSource]
// is the production route and maps the state machine's results 1:1. A ring
// transport implementation is a later slice (Y18b).
//
// Threading contract (inherited from the sink): [drain] and
// [postDriftSample] are called on the sink thread only; [isOwnerThread] is
// read once on the sink thread at sink start; [currentGeneration] /
// [currentStateLabel] are cheap any-thread reads. A [postDriftSample]
// callback runs wherever the implementation completes the sample (owner
// thread, or inline on a post-dispose rejection) and must never block the
// sink thread.
interface VanguardRealtimeAudioPlaybackFrameSource {

    // Outcome of one [drain]: `reply` carries framesRead / bytesRead /
    // eosDrained when `accepted`; `reason` is the rejection reason otherwise.
    data class DrainResult(
        val accepted: Boolean,
        val reason: String,
        val reply: Reply?,
    )

    // Outcome of one [postDriftSample]: a rejection whose `reason` equals
    // [VanguardRealtimePlaybackTransportStateMachine.REASON_STALE_GENERATION]
    // is counted by the sink as stale; any other rejection as "other".
    data class DriftResult(
        val accepted: Boolean,
        val reason: String,
        val reply: Reply?,
    )

    // True when the calling thread is the source's own transport/owner
    // thread; the sink fails closed if its sink thread is that thread.
    val isOwnerThread: Boolean

    // Current transport generation; pinned by the sink onto each drift sample.
    val currentGeneration: Long

    // Lower-case state label used only inside the sink's stall exit reason.
    val currentStateLabel: String

    // Pops up to `maxFrames` of interleaved PCM16 into the direct buffer
    // `dst` at byte offset 0 (sink thread only).
    fun drain(dst: ByteBuffer, maxFrames: Int): DrainResult

    // Fire-and-forget, generation-pinned drift-sample hand-off (sink thread
    // only). Returns whether the sample was enqueued; the sink never reads
    // this value for any decision.
    fun postDriftSample(
        request: VanguardRealtimePlaybackTransportStateMachine.DriftSampleRequest,
        expectedGeneration: Long?,
        callback: ((DriftResult) -> Unit)? = null,
    ): Boolean
}

// Production route: forwards every call to the caller-owned
// [VanguardRealtimePlaybackTransportStateMachine] and maps its [Result] to
// the seam types field-for-field (accepted, reason, reply). Adds no state,
// no thread, no buffering and no retry; the callback keeps the machine's own
// thread and inline-on-dispose semantics.
class VanguardRealtimePlaybackStateMachineFrameSource(
    private val machine: VanguardRealtimePlaybackTransportStateMachine,
) : VanguardRealtimeAudioPlaybackFrameSource {

    override val isOwnerThread: Boolean get() = machine.isOwnerThread

    override val currentGeneration: Long get() = machine.currentGeneration

    override val currentStateLabel: String get() = machine.currentState.name.lowercase()

    override fun drain(dst: ByteBuffer, maxFrames: Int): VanguardRealtimeAudioPlaybackFrameSource.DrainResult {
        val result = machine.drain(dst, maxFrames)
        return VanguardRealtimeAudioPlaybackFrameSource.DrainResult(result.accepted, result.reason, result.reply)
    }

    override fun postDriftSample(
        request: VanguardRealtimePlaybackTransportStateMachine.DriftSampleRequest,
        expectedGeneration: Long?,
        callback: ((VanguardRealtimeAudioPlaybackFrameSource.DriftResult) -> Unit)?,
    ): Boolean {
        if (callback == null) return machine.postDriftSample(request, expectedGeneration, null)
        val mapped: (VanguardRealtimePlaybackTransportStateMachine.Result) -> Unit = { result ->
            callback(VanguardRealtimeAudioPlaybackFrameSource.DriftResult(result.accepted, result.reason, result.reply))
        }
        return machine.postDriftSample(request, expectedGeneration, mapped)
    }
}
