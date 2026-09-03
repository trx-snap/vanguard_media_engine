package com.connects.vanguard_media_engine.audio_playback_graph

// ── VanguardRealtimeAudioPlaybackSinkClockWriter (Y10a modularity prep) ────
//
// Behavior-identical extraction of the presentation-clock-only logic and
// clock telemetry bookkeeping previously inline in
// [VanguardRealtimeAudioPlaybackSinkBridge]: the owned
// [VanguardRealtimePlaybackPresentationClock] instance, epoch open/close,
// instance-frame unwrap/rebase, and the timestamp-poll accounting/counting.
// Every method here executes synchronously on whichever thread calls it
// (the sink thread, for every call site the bridge has); this class owns no
// thread and makes no AudioTrack call itself — the bridge still owns
// AudioTrack lifecycle/reads and hands this class only the resulting raw
// values, so sink-thread-only clock writes and the no-feedback rule are
// unchanged.
class VanguardRealtimeAudioPlaybackSinkClockWriter(sampleRate: Int) {

    companion object {
        const val EPOCH_NONE = VanguardRealtimePlaybackPresentationClock.EPOCH_NONE
        private const val FRAME_WRAP_MODULUS = VanguardRealtimePlaybackPresentationClock.FRAME_WRAP_MODULUS
        private const val FRAME_WRAP_FORWARD_MAX = VanguardRealtimePlaybackPresentationClock.FRAME_WRAP_FORWARD_MAX
    }

    private val presentationClock = VanguardRealtimePlaybackPresentationClock(sampleRate)

    // ── Published telemetry (sink thread writes) ───────────────────────────

    @Volatile var currentEpoch = EPOCH_NONE
        private set
    @Volatile var clockEpochOpenCalls = 0
        private set
    @Volatile var clockEpochCloseCalls = 0
        private set
    @Volatile var clockRejectedCount = 0L
        private set
    @Volatile var clockSnapshotsAtPark = 0L
        private set
    @Volatile var clockSnapshotsAtDeadObjectRecovery = 0L
        private set
    @Volatile var rebasedClampCount = 0L
        private set
    @Volatile var timestampPollAttempts = 0L
        private set
    @Volatile var timestampPollSuccesses = 0L
        private set
    @Volatile var timestampPollUnavailable = 0L
        private set
    @Volatile var timestampPollsWhileParked = 0L
        private set
    @Volatile var timestampMaxPollsInOnePass = 0L
        private set

    // ── Y8b dead-object recovery telemetry (Y10a extraction) ───────────────
    //
    // Storage only: the sink thread's AudioTrack release/rebuild/play calls
    // and the recovery step order stay in
    // [VanguardRealtimeAudioPlaybackSinkBridge.recoverFromSyntheticDeadObject];
    // this class never calls AudioTrack and owns no thread. Fields are set
    // directly by the bridge (unlike the clock fields above, which only ever
    // change through this class's own epoch/poll methods) because the
    // recovery sequence interleaves them with AudioTrack calls this class
    // must not make.

    @Volatile var deadObjectInjectedCount = 0L
    @Volatile var deadObjectObservedCount = 0L
    @Volatile var deadObjectRecoveryCount = 0
    @Volatile var deadObjectOldTrackReleaseCount = 0
    @Volatile var deadObjectRecoveryExecutedOnSinkThread = false
    @Volatile var deadObjectNewTrackInitOk = false
    @Volatile var deadObjectNewTrackVolumeOk = false
    @Volatile var deadObjectNewTrackPlayOk = false
    // Mirrors AudioTrack.PLAYSTATE_UNKNOWN (VanguardRealtimeAudioPlaybackSinkBridge.PLAY_STATE_UNKNOWN).
    @Volatile var deadObjectNewTrackPlayState = -1
    @Volatile var deadObjectNewTrackSameBuffer = false
    @Volatile var deadObjectNewTrackBufferFrames = 0
    @Volatile var deadObjectRecoveryWallMs = -1L
    @Volatile var deadObjectEpochBeforeRecovery = EPOCH_NONE
    @Volatile var deadObjectEpochOpenedAfterRecovery = EPOCH_NONE
    @Volatile var deadObjectEpochCloseAccepted = false
    @Volatile var deadObjectEpochOpenAccepted = false
    @Volatile var deadObjectPositionBeforeRecovery = -1L
    @Volatile var deadObjectBaseFrameAfterRecovery = -1L
    @Volatile var deadObjectBaseStepFrames = -1L
    @Volatile var deadObjectBaseStepBounded = false
    @Volatile var deadObjectContentHeadAtDeadObject = -1L
    @Volatile var deadObjectWrittenAheadOfHeadFrames = -1L
    @Volatile var deadObjectPublicationLagFrames = -1L
    @Volatile var deadObjectBaseStepDecompositionOk = false
    @Volatile var deadObjectClockProvenanceAtRecovery = ""
    @Volatile var deadObjectClockLastAgeNsAtRecovery = -1L
    @Volatile var deadObjectSliceBytesAtRecovery = -1L
    @Volatile var deadObjectUnwrittenBytesAtRecovery = -1L
    @Volatile var deadObjectBufferPositionAtRecovery = -1L
    @Volatile var deadObjectFramesReadAtRecovery = -1L
    @Volatile var deadObjectFramesWrittenBeforeRecovery = -1L
    @Volatile var deadObjectRemainderFramesExpected = -1L
    @Volatile var deadObjectRemainderFramesWrittenOnNewTrack = -1L
    @Volatile var deadObjectRemainderAccountingOk = false
    @Volatile var deadObjectTimestampPollsDuringRecovery = -1L
    @Volatile var playbackHeadAtDeadObject = -1L

    // Pure arithmetic (Y8b proof decomposition): step = baseFrame -
    // positionBeforeRecovery must be >= 0 (sign-only fail-closed claim; the
    // caller throws when this returns false, before any decomposition is
    // attempted, matching the original inline order). When a dead-instance
    // head estimate (contentHead >= 0) exists it further decomposes into
    // writtenAhead (bounded by one track buffer + one mix window, the
    // caller-supplied `lossBound`) and publicationLag against the last
    // published position.
    fun recordDeadObjectBaseStepDecomposition(
        baseFrame: Long,
        positionBeforeRecovery: Long,
        contentHead: Long,
        framesWrittenAtDeadObject: Long,
        lossBound: Long,
    ): Boolean {
        val step = baseFrame - positionBeforeRecovery
        deadObjectBaseStepFrames = step
        val bounded = step >= 0L
        deadObjectBaseStepBounded = bounded
        if (!bounded) return false
        if (contentHead >= 0L) {
            val writtenAhead = framesWrittenAtDeadObject - contentHead
            deadObjectWrittenAheadOfHeadFrames = writtenAhead
            deadObjectPublicationLagFrames = contentHead - positionBeforeRecovery
            deadObjectBaseStepDecompositionOk = writtenAhead in 0L..lossBound
        } else {
            deadObjectWrittenAheadOfHeadFrames = -1L
            deadObjectPublicationLagFrames = -1L
            deadObjectBaseStepDecompositionOk = false
        }
        return true
    }

    // ── Sink-thread-confined state ─────────────────────────────────────────

    private var pollsThisPass = 0L
    private var lastRaw32 = -1L
    private var wrapOffset = 0L
    private var epochRawOrigin = 0L

    fun bindWriterThread(): Boolean = presentationClock.bindWriterThread()
    val boundWriterThreadId: Long get() = presentationClock.boundWriterThreadId

    fun snapshot(): VanguardRealtimePlaybackPresentationClock.Snapshot = presentationClock.snapshot()

    fun snapshotAtPark(): VanguardRealtimePlaybackPresentationClock.Snapshot {
        clockSnapshotsAtPark++
        return presentationClock.snapshot()
    }

    fun snapshotAtDeadObjectRecovery(): VanguardRealtimePlaybackPresentationClock.Snapshot {
        clockSnapshotsAtDeadObjectRecovery++
        return presentationClock.snapshot()
    }

    private fun countClockOutcome(outcome: VanguardRealtimePlaybackPresentationClock.Outcome) {
        if (!outcome.accepted) clockRejectedCount++
    }

    fun openEpoch(epoch: Int, baseFrame: Long): VanguardRealtimePlaybackPresentationClock.Outcome {
        currentEpoch = epoch
        clockEpochOpenCalls++
        val outcome = presentationClock.epochOpened(epoch, baseFrame, System.nanoTime())
        countClockOutcome(outcome)
        return outcome
    }

    private fun closeEpochInternal(epoch: Int): VanguardRealtimePlaybackPresentationClock.Outcome {
        currentEpoch = EPOCH_NONE
        clockEpochCloseCalls++
        val outcome = presentationClock.epochClosed(epoch, System.nanoTime())
        countClockOutcome(outcome)
        return outcome
    }

    // Explicit close of a known (possibly stale) epoch; caller reads .accepted.
    fun closeEpoch(epoch: Int): VanguardRealtimePlaybackPresentationClock.Outcome = closeEpochInternal(epoch)

    // Fire-and-forget close of whatever is currently open; no-op if none.
    fun closeIfOpen() {
        val epoch = currentEpoch
        if (epoch == EPOCH_NONE) return
        closeEpochInternal(epoch)
    }

    // Rebases future timestamp polls to `origin` without touching wrap state
    // (same AudioTrack instance continuing without a discontinuity).
    fun setOrigin(origin: Long) {
        epochRawOrigin = origin
    }

    // Full reset after a discontinuity (flush restart or a new AudioTrack
    // instance): wrap state and rebase origin both restart from scratch.
    fun resetUnwrap(origin: Long) {
        lastRaw32 = -1L
        wrapOffset = 0L
        epochRawOrigin = origin
    }

    private fun unwrapInstanceFrame(raw32: Long): Long {
        val last = lastRaw32
        if (last >= 0L && raw32 < last) {
            val forward = raw32 + FRAME_WRAP_MODULUS - last
            if (forward > 0L && forward < FRAME_WRAP_FORWARD_MAX) wrapOffset += FRAME_WRAP_MODULUS
        }
        lastRaw32 = raw32
        return raw32 + wrapOffset
    }

    // Non-mutating unwrap of a raw instance frame (e.g. the dead instance's
    // last head) into the current epoch's content-frame numbering.
    fun peekContentFrame(raw32: Long, fallbackLastRaw32: Long): Long {
        val last = if (lastRaw32 >= 0L) lastRaw32 else fallbackLastRaw32
        var offset = wrapOffset
        if (last >= 0L && raw32 < last) {
            val forward = raw32 + FRAME_WRAP_MODULUS - last
            if (forward > 0L && forward < FRAME_WRAP_FORWARD_MAX) offset += FRAME_WRAP_MODULUS
        }
        return raw32 + offset - epochRawOrigin
    }

    fun resetPassCounter() {
        pollsThisPass = 0L
    }

    // Parked-check + attempt counters; false means the caller must not touch
    // AudioTrack for this pass (clock closed, matches the original inline order).
    fun beginPoll(parked: Boolean): Boolean {
        if (parked) timestampPollsWhileParked++
        if (currentEpoch == EPOCH_NONE) return false
        pollsThisPass++
        if (pollsThisPass > timestampMaxPollsInOnePass) timestampMaxPollsInOnePass = pollsThisPass
        timestampPollAttempts++
        return true
    }

    // The accounting half of one timestamp poll, given the raw AudioTrack
    // read the bridge already performed. Telemetry and clock writes only;
    // nothing downstream depends on the result.
    fun recordTimestampPoll(available: Boolean, framePositionRaw: Long, frameNanoTime: Long, head: Long) {
        val epoch = currentEpoch
        if (available) {
            timestampPollSuccesses++
            val instance = unwrapInstanceFrame(framePositionRaw)
            var rebased = instance - epochRawOrigin
            if (rebased < 0L) {
                rebasedClampCount++
                rebased = 0L
            }
            if (rebased >= FRAME_WRAP_MODULUS) {
                clockRejectedCount++
                return
            }
            countClockOutcome(presentationClock.observeTimestamp(epoch, rebased, frameNanoTime))
        } else {
            timestampPollUnavailable++
            countClockOutcome(presentationClock.observeTimestampUnavailable(epoch, head, System.nanoTime()))
        }
    }
}
