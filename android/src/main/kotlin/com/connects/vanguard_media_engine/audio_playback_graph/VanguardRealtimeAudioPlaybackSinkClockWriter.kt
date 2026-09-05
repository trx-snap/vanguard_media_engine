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
    // Y17: of [clockEpochOpenCalls], how many went through
    // [openEpochDeclaredBackward] (a backward seek's unpark). Zero on every
    // non-backward run.
    @Volatile var clockDeclaredBackwardOpenCalls = 0
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

    // ── Y13 diagnostic production-clock query / epoch-relative lag telemetry ─
    //
    // P4-AUDIO-REALTIME-PLAYBACK-PRESENTATION-CLOCK-QUERY-SURFACE: a bounded
    // diagnostic surface only. It never influences drain size, sleeps,
    // gating, checksum, park/unpark, epoch decisions or transport commands
    // (record telemetry only); it does not by itself claim P4-AUDIO-MIXBUS
    // or P4-AUDIO-GRAPH-TRANSPORT-CLOCK are complete. Lag is computed only
    // at the existing post-write timestamp poll path in [recordTimestampPoll]
    // (no new/second poll point, no extra AudioTrack call), epoch-relative
    // via the anchors captured once per [openEpoch] call so a seek's base
    // discontinuity never leaks into the metric as cumulative drift.
    @Volatile var epochBaseFrame = -1L
        private set
    @Volatile var framesWrittenAtEpochOpen = -1L
        private set
    @Volatile var framesReadAtEpochOpen = -1L
        private set
    @Volatile var presentationLagSampleCount = 0L
        private set
    // Of [presentationLagSampleCount], how many fell within the honest bounds below.
    @Volatile var presentationLagBoundedSampleCount = 0L
        private set
    // RESET / STALE / no-anchor (or off-epoch) samples: never fed into the lag formula.
    @Volatile var presentationLagExcludedSampleCount = 0L
        private set
    @Volatile var lastPresentationLagFrames = 0L
        private set
    @Volatile var minPresentationLagFrames = 0L
        private set
    @Volatile var maxPresentationLagFrames = 0L
        private set
    // -(extrapolation horizon in frames + one mix window); no nonnegative-lag claim.
    @Volatile var presentationLagLowerBoundFrames = 0L
        private set
    // AudioTrack client buffer + one mix window + the same extrapolation horizon
    // used on the negative side (timestamp freshness / output-path uncertainty).
    @Volatile var presentationLagUpperBoundFrames = 0L
        private set
    @Volatile var lastPositionFramesAtPoll = -1L
        private set
    @Volatile var lastPositionUsAtPoll = -1L
        private set
    @Volatile var positionAtEosFrames = -1L
        private set
    @Volatile var positionAtEosUs = -1L
        private set

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

    // Y13: any-thread, non-allocating forwarders onto the owned clock (class
    // comment); isolated from the snapshot-call counters above (own counters).
    fun currentPositionFrames(): Long = presentationClock.currentPositionFrames()
    fun currentPositionUs(): Long = presentationClock.currentPositionUs()
    val currentPositionReadsFromWriterThread: Long get() = presentationClock.currentPositionReadsFromWriterThreadCount
    val currentPositionReadsFromOtherThreads: Long get() = presentationClock.currentPositionReadsFromOtherThreadsCount

    // Sink thread only, once at EOS: no new timestamp poll (class comment).
    fun recordPositionAtEos() {
        val frames = presentationClock.currentPositionFrames()
        positionAtEosFrames = frames
        positionAtEosUs = VanguardRealtimePlaybackPresentationClock.framesToUs(frames, presentationClock.sampleRate)
    }

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

    // Y13: also anchors the epoch-relative lag inputs (class comment) --
    // baseFrame doubles as [epochBaseFrame], and the caller-supplied stream
    // counters at this same open become [framesWrittenAtEpochOpen] /
    // [framesReadAtEpochOpen]. Set unconditionally (matching [currentEpoch]
    // above): every existing call site throws on a rejected outcome, so a
    // stale anchor never survives to a later poll.
    fun openEpoch(
        epoch: Int,
        baseFrame: Long,
        framesWrittenAtEpochOpen: Long,
        framesReadAtEpochOpen: Long,
    ): VanguardRealtimePlaybackPresentationClock.Outcome =
        openEpochInternal(epoch, baseFrame, framesWrittenAtEpochOpen, framesReadAtEpochOpen, declaredBackward = false)

    // Y17: same anchoring as [openEpoch], but the base is a writer-declared
    // backward discontinuity (a backward seek target on a flushed instance),
    // forwarded to [VanguardRealtimePlaybackPresentationClock.
    // epochOpenedDeclaredBackward]. The Y13 lag anchors are captured per
    // epoch exactly as for a forward seek, so the backward base never leaks
    // into the lag metric as cumulative drift.
    fun openEpochDeclaredBackward(
        epoch: Int,
        baseFrame: Long,
        framesWrittenAtEpochOpen: Long,
        framesReadAtEpochOpen: Long,
    ): VanguardRealtimePlaybackPresentationClock.Outcome =
        openEpochInternal(epoch, baseFrame, framesWrittenAtEpochOpen, framesReadAtEpochOpen, declaredBackward = true)

    private fun openEpochInternal(
        epoch: Int,
        baseFrame: Long,
        framesWrittenAtEpochOpen: Long,
        framesReadAtEpochOpen: Long,
        declaredBackward: Boolean,
    ): VanguardRealtimePlaybackPresentationClock.Outcome {
        currentEpoch = epoch
        clockEpochOpenCalls++
        val outcome = if (declaredBackward) {
            clockDeclaredBackwardOpenCalls++
            presentationClock.epochOpenedDeclaredBackward(epoch, baseFrame, System.nanoTime())
        } else {
            presentationClock.epochOpened(epoch, baseFrame, System.nanoTime())
        }
        countClockOutcome(outcome)
        epochBaseFrame = baseFrame
        this.framesWrittenAtEpochOpen = framesWrittenAtEpochOpen
        this.framesReadAtEpochOpen = framesReadAtEpochOpen
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
    // nothing downstream depends on the result. Y13: the SAME observation
    // also feeds the epoch-relative lag bound below (no second poll point,
    // no extra AudioTrack call); framesReadFromTransport is accepted for
    // anchor-input symmetry with [openEpoch] but the lag formula itself
    // (class comment) does not use it.
    //
    // Y16: returns true iff this poll produced an honest presentation
    // position (the same accepted ANCHORED/EXTRAPOLATED + epoch-anchored
    // eligibility the lag sample uses), so the bridge may hand
    // [lastPositionUsAtPoll]/[lastPositionFramesAtPoll] to the native clock
    // as a drift sample. The return value gates ONLY that diagnostic
    // emission; no drain/gating/epoch decision reads it.
    fun recordTimestampPoll(
        available: Boolean,
        framePositionRaw: Long,
        frameNanoTime: Long,
        head: Long,
        framesWrittenToSink: Long,
        framesReadFromTransport: Long,
        audioTrackBufferFrames: Int,
        maxFramesPerMix: Int,
    ): Boolean {
        val epoch = currentEpoch
        val outcome: VanguardRealtimePlaybackPresentationClock.Outcome
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
                return false
            }
            outcome = presentationClock.observeTimestamp(epoch, rebased, frameNanoTime)
            countClockOutcome(outcome)
        } else {
            timestampPollUnavailable++
            outcome = presentationClock.observeTimestampUnavailable(epoch, head, System.nanoTime())
            countClockOutcome(outcome)
        }
        return recordPresentationLag(outcome, framesWrittenToSink, audioTrackBufferFrames, maxFramesPerMix)
    }

    // Y13 bounded diagnostic only (class comment): never fails closed, never
    // read by any drain/gating/epoch/transport decision. Lag is computed
    // only for an accepted ANCHORED/EXTRAPOLATED outcome with an epoch-open
    // anchor on record; every other outcome (RESET/STALE/no-anchor/rejected)
    // is excluded and counted separately, honestly, with no nonnegative-lag
    // claim. Returns that same eligibility (Y16 drift-sample gate).
    private fun recordPresentationLag(
        outcome: VanguardRealtimePlaybackPresentationClock.Outcome,
        framesWrittenToSink: Long,
        audioTrackBufferFrames: Int,
        maxFramesPerMix: Int,
    ): Boolean {
        val positionFrames = presentationClock.currentPositionFrames()
        lastPositionFramesAtPoll = positionFrames
        lastPositionUsAtPoll = VanguardRealtimePlaybackPresentationClock.framesToUs(positionFrames, presentationClock.sampleRate)
        val eligible = outcome == VanguardRealtimePlaybackPresentationClock.Outcome.ACCEPTED_ANCHORED ||
            outcome == VanguardRealtimePlaybackPresentationClock.Outcome.ACCEPTED_EXTRAPOLATED
        if (!eligible || epochBaseFrame < 0L) {
            presentationLagExcludedSampleCount++
            return false
        }
        val lag = (framesWrittenToSink - framesWrittenAtEpochOpen) - (positionFrames - epochBaseFrame)
        presentationLagSampleCount++
        lastPresentationLagFrames = lag
        if (presentationLagSampleCount == 1L) {
            minPresentationLagFrames = lag
            maxPresentationLagFrames = lag
        } else {
            if (lag < minPresentationLagFrames) minPresentationLagFrames = lag
            if (lag > maxPresentationLagFrames) maxPresentationLagFrames = lag
        }
        val horizonFrames = presentationClock.extrapolationHorizonNs * presentationClock.sampleRate / 1_000_000_000L
        val lower = -(horizonFrames + maxFramesPerMix)
        // Upper side: client buffer + one mix window + the same timestamp
        // freshness horizon / output-path uncertainty as the negative side.
        // Diagnostic envelope only, not a latency SLA or device latency measurement.
        val upper = audioTrackBufferFrames.toLong() + maxFramesPerMix + horizonFrames
        presentationLagLowerBoundFrames = lower
        presentationLagUpperBoundFrames = upper
        if (lag in lower..upper) presentationLagBoundedSampleCount++
        return true
    }
}
