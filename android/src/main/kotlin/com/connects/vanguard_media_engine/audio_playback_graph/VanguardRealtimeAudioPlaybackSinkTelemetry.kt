package com.connects.vanguard_media_engine.audio_playback_graph

import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply

// Immutable any-thread view of [VanguardRealtimeAudioPlaybackSinkBridge]'s
// sink-thread-published telemetry. Top-level so it can be referenced from
// diagnostic evaluators without depending on the sink bridge's own class body.
//
// Verifier note: the Android bytecode verifier rejects a single invocation
// whose method signature widens past its argument-register budget (observed
// on-device as a VerifyError on the previous flat ~165-parameter
// constructor: "expected 18 argument registers, method signature has 19 or
// more"). Every field below is grouped into a small section data class
// (<= 8 primitive/String/enum fields each), sections are grouped into a
// handful of bundles (<= 6 section references each), and this class holds
// only the bundles -- so no single constructor call in the whole telemetry
// snapshot ever approaches that limit. [VanguardRealtimeAudioPlaybackSinkBridge
// .telemetry()] builds the sections and bundles, then this class exposes
// every original public property name/type unchanged via delegation, so
// every caller, diagnostic and test is unaffected.

// ── Section data classes (each a small, verifier-safe constructor) ─────────

data class VanguardRealtimeAudioPlaybackSinkTelemetryCore(
    val phase: VanguardRealtimeAudioPlaybackSinkBridge.Phase,
    val exitReason: String,
    val threadId: Long,
    val threadIsTransportOwner: Boolean,
    val clockWriterBoundOnSinkThread: Boolean,
    val audioTrackInitOk: Boolean,
    val gainSetOk: Boolean,
    val gainValue: Float,
)

// Y11a-prep volume request queue (any thread request / sink thread apply).
data class VanguardRealtimeAudioPlaybackSinkTelemetryGainQueue(
    val gainRequestCount: Long,
    val gainAppliedCount: Long,
    val gainRejectedCount: Long,
    val gainQueueFullCount: Long,
    val lastGainRequestSeq: Long,
    val lastGainAppliedSeq: Long,
    val gainAppliedOnSinkThread: Boolean,
    // Current sink-thread-applied linear gain; gainValue mirrored under its new name.
    val effectiveGain: Float,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryTrackLifecycle(
    val audioTrackBufferBytes: Int,
    val audioTracksCreated: Int,
    val releaseCount: Int,
    val releaseExecutedOnSinkThread: Boolean,
    val audioTrackCallsOffSinkThread: Long,
    val played: Boolean,
    val initialPlayState: Int,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryWritePath(
    val framesReadFromTransport: Long,
    val framesWrittenToSink: Long,
    val partialWriteCount: Long,
    val zeroWriteCount: Long,
    val drainCalls: Long,
    val drainCallsBeforeAllow: Long,
    val drainRequestSizeChanges: Long,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryDrainSummary(
    val emptyDrainCount: Long,
    val productiveDrainPasses: Long,
    val eosDrainedObserved: Boolean,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryClockPollA(
    val timestampPollAttempts: Long,
    val timestampPollSuccesses: Long,
    val timestampPollUnavailable: Long,
    val timestampPollsWhileParked: Long,
    val timestampMaxPollsInOnePass: Long,
    val clockEpochOpenCalls: Int,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryClockPollB(
    val clockEpochCloseCalls: Int,
    val clockRejectedCount: Long,
    val clockSnapshotsAtPark: Long,
    val rebasedClampCount: Long,
    val currentEpoch: Int,
    // Y17: epoch opens declared backward (a backward seek's unpark); 0 on every non-backward run.
    val clockDeclaredBackwardOpenCalls: Int = 0,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryParkA(
    val parkCount: Int,
    val unparkCount: Int,
    val playStateAtPark: Int,
    val playStateAfterUnpark: Int,
    val parkedPlayStateViolations: Long,
    val parkExecutedOnSinkThread: Boolean,
    val unparkExecutedOnSinkThread: Boolean,
    val positionAtPark: Long,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryParkB(
    val epochClosedAtPark: Int,
    val epochOpenedAtUnpark: Int,
    val parkAckLatencyMs: Long,
    val parkedHoldMs: Long,
    val playbackHeadAtPark: Long,
    val playbackHeadAtUnpark: Long,
    val playbackHeadFinal: Long,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryParkC(
    val readyAtMs: Long,
    val drainAllowedAtMs: Long,
    val firstDrainAtMs: Long,
    val firstWriteAtMs: Long,
    val sinkThreadWallMs: Long,
    val checksumHex: String,
    val lastReply: Reply?,
)

// Y8b synthetic dead-object recovery telemetry (split A-E; 39 fields total).
data class VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectA(
    val syntheticDeadObjectInjectAfterFrames: Long,
    val deadObjectInjectedCount: Long,
    val deadObjectObservedCount: Long,
    val deadObjectRecoveryCount: Int,
    val deadObjectOldTrackReleaseCount: Int,
    val deadObjectRecoveryExecutedOnSinkThread: Boolean,
    val deadObjectNewTrackInitOk: Boolean,
    val deadObjectNewTrackVolumeOk: Boolean,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectB(
    val deadObjectNewTrackPlayOk: Boolean,
    val deadObjectNewTrackPlayState: Int,
    val deadObjectNewTrackSameBuffer: Boolean,
    val audioTrackBufferFrames: Int,
    val deadObjectNewTrackBufferFrames: Int,
    val deadObjectRecoveryWallMs: Long,
    val deadObjectEpochBeforeRecovery: Int,
    val deadObjectEpochOpenedAfterRecovery: Int,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectC(
    val deadObjectEpochCloseAccepted: Boolean,
    val deadObjectEpochOpenAccepted: Boolean,
    val deadObjectPositionBeforeRecovery: Long,
    val deadObjectBaseFrameAfterRecovery: Long,
    val deadObjectBaseStepFrames: Long,
    // Sign-only claim: true iff deadObjectBaseStepFrames >= 0.
    val deadObjectBaseStepBounded: Boolean,
    // Content frame (current-epoch continuous frame) the dead instance
    // had consumed at the dead object; -1 when its head was unreadable.
    val deadObjectContentHeadAtDeadObject: Long,
    // written - contentHead: frames lost with the dead instance (-1 if H < 0).
    val deadObjectWrittenAheadOfHeadFrames: Long,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectD(
    // contentHead - last published position (-1 if H < 0).
    val deadObjectPublicationLagFrames: Long,
    // H >= 0 && 0 <= written - H <= track buffer + one mix window.
    val deadObjectBaseStepDecompositionOk: Boolean,
    val deadObjectClockProvenanceAtRecovery: String,
    val deadObjectClockLastAgeNsAtRecovery: Long,
    val deadObjectSliceBytesAtRecovery: Long,
    val deadObjectUnwrittenBytesAtRecovery: Long,
    val deadObjectBufferPositionAtRecovery: Long,
    val deadObjectFramesReadAtRecovery: Long,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectE(
    val deadObjectFramesWrittenBeforeRecovery: Long,
    val deadObjectRemainderFramesExpected: Long,
    val deadObjectRemainderFramesWrittenOnNewTrack: Long,
    val deadObjectRemainderAccountingOk: Boolean,
    val deadObjectTimestampPollsDuringRecovery: Long,
    val clockSnapshotsAtDeadObjectRecovery: Long,
    val playbackHeadAtDeadObject: Long,
)

// Y9 seek park / flush / seek epoch (split A-D; 26 fields total).
data class VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushA(
    val maxSeekHoldMs: Long,
    // Count of seek parks the sink thread executed via requestSeekPark() (0..MAX_SEEK_PARKS, Y10b-1a).
    val seekParkCount: Int,
    // Hold cap applied to the last park: maxPauseHoldMs or maxSeekHoldMs.
    val parkHoldCapMs: Long,
    val flushRequestCount: Int,
    val flushCount: Int,
    val flushExecutedOnSinkThread: Boolean,
    val flushAckLatencyMs: Long,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushB(
    val playStateBeforeFlush: Int,
    val playStateAfterFlush: Int,
    val playbackHeadBeforeFlush: Long,
    val playbackHeadAfterFlush: Long,
    val framesWrittenAtFlush: Long,
    val framesReadAtFlush: Long,
    val drainCallsAtFlush: Long,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushC(
    val timestampPollsDuringFlush: Long,
    val postSeekExpectedFrames: Long,
    // declaredFrameCount before a flush; framesReadAtFlush + postSeekExpectedFrames after it.
    val readBudgetFrames: Long,
    // Pending seek target handed over by requestFlush; the seek epoch base.
    val seekTargetFrame: Long,
    val seekEpochOpenedAtUnpark: Int,
    val seekEpochBaseFrame: Long,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushD(
    // Deliberate discontinuity: seekEpochBaseFrame - positionAtPark (>= 0 for
    // a forward seek; Y17: may be negative for a declared backward seek).
    val seekDiscontinuityFrames: Long,
    val seekEpochOpenAccepted: Boolean,
    // True once the flush reset lastRaw32 / wrapOffset / epochRawOrigin.
    val seekUnwrapResetAtFlush: Boolean,
    // Instance-frame origin used by the epoch opened at the last unpark:
    // positionAtPark for a bounded pause, 0 for a seek (flushed instance).
    val epochRawOriginAtUnpark: Long,
    val playbackHeadAtSeekUnpark: Long,
    // framesWrittenToSink - framesWrittenAtFlush once flushed, else 0.
    val postSeekFramesWritten: Long,
    // Y17: the last requestFlush declared its seek backward (T < written at
    // flush); the unpark then opened the seek epoch through the clock's
    // declared-backward entry point. False on every forward run.
    val seekDeclaredBackward: Boolean = false,
)

// Y13 diagnostic production-clock query / epoch-relative lag (split A-C; 17
// fields total). Bounded diagnostic only (see bridge class header): never
// influences drain size, sleeps, gating, checksum, park/unpark, epoch
// decisions or transport commands, and does not by itself claim
// P4-AUDIO-MIXBUS or P4-AUDIO-GRAPH-TRANSPORT-CLOCK are complete.
data class VanguardRealtimeAudioPlaybackSinkTelemetryPresentationLagA(
    val epochBaseFrame: Long,
    val framesWrittenAtEpochOpen: Long,
    val framesReadAtEpochOpen: Long,
    val presentationLagSampleCount: Long,
    val presentationLagBoundedSampleCount: Long,
    val presentationLagExcludedSampleCount: Long,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryPresentationLagB(
    val lastPresentationLagFrames: Long,
    val minPresentationLagFrames: Long,
    val maxPresentationLagFrames: Long,
    val presentationLagLowerBoundFrames: Long,
    val presentationLagUpperBoundFrames: Long,
    val lastPositionFramesAtPoll: Long,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryPresentationLagC(
    val lastPositionUsAtPoll: Long,
    val positionAtEosFrames: Long,
    val positionAtEosUs: Long,
    // Y13: isolated currentPosition() read counters (own counters, distinct from the snapshot-call counters).
    val currentPositionReadsFromWriterThread: Long,
    val currentPositionReadsFromOtherThreads: Long,
)

// Y16 drift-sample ingestion (P4-AUDIO-REALTIME-PLAYBACK-CLOCK-DRIFT-SAMPLE-
// OWNERSHIP; split A-C; 17 fields total). Bounded diagnostic only: counters
// of presentation-clock positions the sink thread posted to the transport
// owner thread (generation-pinned) for the native worker-owned AudioClock to
// record. Never influences drain size, sleeps, gating, checksum, park/
// unpark, epoch, transport commands or currentPosition authority. No
// control loop exists.
data class VanguardRealtimeAudioPlaybackSinkTelemetryDriftA(
    // Sink-thread side: polls that produced an honest position and were posted /
    // skipped (ineligible poll) / dropped (in-flight cap reached).
    val driftSamplesPosted: Long,
    val driftSamplesSkipped: Long,
    val driftSamplesDropped: Long,
    // Owner-thread callback side.
    val driftCallbackCount: Long,
    val driftSamplesRecorded: Long,
    val driftSamplesStaleRejected: Long,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryDriftB(
    val driftSamplesOtherRejected: Long,
    val driftLastRejectReason: String,
    // Kotlin-only diagnostic queue latency (post -> owner-thread callback), never sent to native.
    val driftMaxQueueLatencyNs: Long,
    // Last generation pinned on a posted sample.
    val driftLastPostedGeneration: Long,
    // Mirror of the last accepted native reply's drift fields (-1/0 until one was accepted).
    val driftLastExpectedPtsUs: Long,
    val driftLastReportedPtsUs: Long,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryDriftC(
    val driftLastDeltaUs: Long,
    val driftLastReportedFrame: Long,
    val driftNativeSampleCount: Long,
    val driftNativeSamplesRecorded: Long,
    val driftNativeSamplesRejected: Long,
)

// ── Bundles (small groups of section references; still verifier-safe) ──────

data class VanguardRealtimeAudioPlaybackSinkTelemetryCoreBundle(
    val core: VanguardRealtimeAudioPlaybackSinkTelemetryCore,
    val gainQueue: VanguardRealtimeAudioPlaybackSinkTelemetryGainQueue,
    val trackLifecycle: VanguardRealtimeAudioPlaybackSinkTelemetryTrackLifecycle,
    val writePath: VanguardRealtimeAudioPlaybackSinkTelemetryWritePath,
    val drainSummary: VanguardRealtimeAudioPlaybackSinkTelemetryDrainSummary,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryClockParkBundle(
    val clockPollA: VanguardRealtimeAudioPlaybackSinkTelemetryClockPollA,
    val clockPollB: VanguardRealtimeAudioPlaybackSinkTelemetryClockPollB,
    val parkA: VanguardRealtimeAudioPlaybackSinkTelemetryParkA,
    val parkB: VanguardRealtimeAudioPlaybackSinkTelemetryParkB,
    val parkC: VanguardRealtimeAudioPlaybackSinkTelemetryParkC,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectBundle(
    val deadObjectA: VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectA,
    val deadObjectB: VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectB,
    val deadObjectC: VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectC,
    val deadObjectD: VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectD,
    val deadObjectE: VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectE,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushBundle(
    val seekFlushA: VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushA,
    val seekFlushB: VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushB,
    val seekFlushC: VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushC,
    val seekFlushD: VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushD,
)

data class VanguardRealtimeAudioPlaybackSinkTelemetryLagDriftBundle(
    val presentationLagA: VanguardRealtimeAudioPlaybackSinkTelemetryPresentationLagA,
    val presentationLagB: VanguardRealtimeAudioPlaybackSinkTelemetryPresentationLagB,
    val presentationLagC: VanguardRealtimeAudioPlaybackSinkTelemetryPresentationLagC,
    val driftA: VanguardRealtimeAudioPlaybackSinkTelemetryDriftA,
    val driftB: VanguardRealtimeAudioPlaybackSinkTelemetryDriftB,
    val driftC: VanguardRealtimeAudioPlaybackSinkTelemetryDriftC,
)

// ── Top-level snapshot: every original public property, unchanged ──────────

class VanguardRealtimeAudioPlaybackSinkTelemetry(
    private val coreBundle: VanguardRealtimeAudioPlaybackSinkTelemetryCoreBundle,
    private val clockParkBundle: VanguardRealtimeAudioPlaybackSinkTelemetryClockParkBundle,
    private val deadObjectBundle: VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectBundle,
    private val seekFlushBundle: VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushBundle,
    private val lagDriftBundle: VanguardRealtimeAudioPlaybackSinkTelemetryLagDriftBundle,
) {
    val phase: VanguardRealtimeAudioPlaybackSinkBridge.Phase get() = coreBundle.core.phase
    val exitReason: String get() = coreBundle.core.exitReason
    val threadId: Long get() = coreBundle.core.threadId
    val threadIsTransportOwner: Boolean get() = coreBundle.core.threadIsTransportOwner
    val clockWriterBoundOnSinkThread: Boolean get() = coreBundle.core.clockWriterBoundOnSinkThread
    val audioTrackInitOk: Boolean get() = coreBundle.core.audioTrackInitOk
    val gainSetOk: Boolean get() = coreBundle.core.gainSetOk
    val gainValue: Float get() = coreBundle.core.gainValue

    val gainRequestCount: Long get() = coreBundle.gainQueue.gainRequestCount
    val gainAppliedCount: Long get() = coreBundle.gainQueue.gainAppliedCount
    val gainRejectedCount: Long get() = coreBundle.gainQueue.gainRejectedCount
    val gainQueueFullCount: Long get() = coreBundle.gainQueue.gainQueueFullCount
    val lastGainRequestSeq: Long get() = coreBundle.gainQueue.lastGainRequestSeq
    val lastGainAppliedSeq: Long get() = coreBundle.gainQueue.lastGainAppliedSeq
    val gainAppliedOnSinkThread: Boolean get() = coreBundle.gainQueue.gainAppliedOnSinkThread
    val effectiveGain: Float get() = coreBundle.gainQueue.effectiveGain

    val audioTrackBufferBytes: Int get() = coreBundle.trackLifecycle.audioTrackBufferBytes
    val audioTracksCreated: Int get() = coreBundle.trackLifecycle.audioTracksCreated
    val releaseCount: Int get() = coreBundle.trackLifecycle.releaseCount
    val releaseExecutedOnSinkThread: Boolean get() = coreBundle.trackLifecycle.releaseExecutedOnSinkThread
    val audioTrackCallsOffSinkThread: Long get() = coreBundle.trackLifecycle.audioTrackCallsOffSinkThread
    val played: Boolean get() = coreBundle.trackLifecycle.played
    val initialPlayState: Int get() = coreBundle.trackLifecycle.initialPlayState

    val framesReadFromTransport: Long get() = coreBundle.writePath.framesReadFromTransport
    val framesWrittenToSink: Long get() = coreBundle.writePath.framesWrittenToSink
    val partialWriteCount: Long get() = coreBundle.writePath.partialWriteCount
    val zeroWriteCount: Long get() = coreBundle.writePath.zeroWriteCount
    val drainCalls: Long get() = coreBundle.writePath.drainCalls
    val drainCallsBeforeAllow: Long get() = coreBundle.writePath.drainCallsBeforeAllow
    val drainRequestSizeChanges: Long get() = coreBundle.writePath.drainRequestSizeChanges

    val emptyDrainCount: Long get() = coreBundle.drainSummary.emptyDrainCount
    val productiveDrainPasses: Long get() = coreBundle.drainSummary.productiveDrainPasses
    val eosDrainedObserved: Boolean get() = coreBundle.drainSummary.eosDrainedObserved

    val timestampPollAttempts: Long get() = clockParkBundle.clockPollA.timestampPollAttempts
    val timestampPollSuccesses: Long get() = clockParkBundle.clockPollA.timestampPollSuccesses
    val timestampPollUnavailable: Long get() = clockParkBundle.clockPollA.timestampPollUnavailable
    val timestampPollsWhileParked: Long get() = clockParkBundle.clockPollA.timestampPollsWhileParked
    val timestampMaxPollsInOnePass: Long get() = clockParkBundle.clockPollA.timestampMaxPollsInOnePass
    val clockEpochOpenCalls: Int get() = clockParkBundle.clockPollA.clockEpochOpenCalls

    val clockEpochCloseCalls: Int get() = clockParkBundle.clockPollB.clockEpochCloseCalls
    val clockRejectedCount: Long get() = clockParkBundle.clockPollB.clockRejectedCount
    val clockSnapshotsAtPark: Long get() = clockParkBundle.clockPollB.clockSnapshotsAtPark
    val rebasedClampCount: Long get() = clockParkBundle.clockPollB.rebasedClampCount
    val currentEpoch: Int get() = clockParkBundle.clockPollB.currentEpoch
    val clockDeclaredBackwardOpenCalls: Int get() = clockParkBundle.clockPollB.clockDeclaredBackwardOpenCalls

    val parkCount: Int get() = clockParkBundle.parkA.parkCount
    val unparkCount: Int get() = clockParkBundle.parkA.unparkCount
    val playStateAtPark: Int get() = clockParkBundle.parkA.playStateAtPark
    val playStateAfterUnpark: Int get() = clockParkBundle.parkA.playStateAfterUnpark
    val parkedPlayStateViolations: Long get() = clockParkBundle.parkA.parkedPlayStateViolations
    val parkExecutedOnSinkThread: Boolean get() = clockParkBundle.parkA.parkExecutedOnSinkThread
    val unparkExecutedOnSinkThread: Boolean get() = clockParkBundle.parkA.unparkExecutedOnSinkThread
    val positionAtPark: Long get() = clockParkBundle.parkA.positionAtPark

    val epochClosedAtPark: Int get() = clockParkBundle.parkB.epochClosedAtPark
    val epochOpenedAtUnpark: Int get() = clockParkBundle.parkB.epochOpenedAtUnpark
    val parkAckLatencyMs: Long get() = clockParkBundle.parkB.parkAckLatencyMs
    val parkedHoldMs: Long get() = clockParkBundle.parkB.parkedHoldMs
    val playbackHeadAtPark: Long get() = clockParkBundle.parkB.playbackHeadAtPark
    val playbackHeadAtUnpark: Long get() = clockParkBundle.parkB.playbackHeadAtUnpark
    val playbackHeadFinal: Long get() = clockParkBundle.parkB.playbackHeadFinal

    val readyAtMs: Long get() = clockParkBundle.parkC.readyAtMs
    val drainAllowedAtMs: Long get() = clockParkBundle.parkC.drainAllowedAtMs
    val firstDrainAtMs: Long get() = clockParkBundle.parkC.firstDrainAtMs
    val firstWriteAtMs: Long get() = clockParkBundle.parkC.firstWriteAtMs
    val sinkThreadWallMs: Long get() = clockParkBundle.parkC.sinkThreadWallMs
    val checksumHex: String get() = clockParkBundle.parkC.checksumHex
    val lastReply: Reply? get() = clockParkBundle.parkC.lastReply

    val syntheticDeadObjectInjectAfterFrames: Long get() = deadObjectBundle.deadObjectA.syntheticDeadObjectInjectAfterFrames
    val deadObjectInjectedCount: Long get() = deadObjectBundle.deadObjectA.deadObjectInjectedCount
    val deadObjectObservedCount: Long get() = deadObjectBundle.deadObjectA.deadObjectObservedCount
    val deadObjectRecoveryCount: Int get() = deadObjectBundle.deadObjectA.deadObjectRecoveryCount
    val deadObjectOldTrackReleaseCount: Int get() = deadObjectBundle.deadObjectA.deadObjectOldTrackReleaseCount
    val deadObjectRecoveryExecutedOnSinkThread: Boolean get() = deadObjectBundle.deadObjectA.deadObjectRecoveryExecutedOnSinkThread
    val deadObjectNewTrackInitOk: Boolean get() = deadObjectBundle.deadObjectA.deadObjectNewTrackInitOk
    val deadObjectNewTrackVolumeOk: Boolean get() = deadObjectBundle.deadObjectA.deadObjectNewTrackVolumeOk

    val deadObjectNewTrackPlayOk: Boolean get() = deadObjectBundle.deadObjectB.deadObjectNewTrackPlayOk
    val deadObjectNewTrackPlayState: Int get() = deadObjectBundle.deadObjectB.deadObjectNewTrackPlayState
    val deadObjectNewTrackSameBuffer: Boolean get() = deadObjectBundle.deadObjectB.deadObjectNewTrackSameBuffer
    val audioTrackBufferFrames: Int get() = deadObjectBundle.deadObjectB.audioTrackBufferFrames
    val deadObjectNewTrackBufferFrames: Int get() = deadObjectBundle.deadObjectB.deadObjectNewTrackBufferFrames
    val deadObjectRecoveryWallMs: Long get() = deadObjectBundle.deadObjectB.deadObjectRecoveryWallMs
    val deadObjectEpochBeforeRecovery: Int get() = deadObjectBundle.deadObjectB.deadObjectEpochBeforeRecovery
    val deadObjectEpochOpenedAfterRecovery: Int get() = deadObjectBundle.deadObjectB.deadObjectEpochOpenedAfterRecovery

    val deadObjectEpochCloseAccepted: Boolean get() = deadObjectBundle.deadObjectC.deadObjectEpochCloseAccepted
    val deadObjectEpochOpenAccepted: Boolean get() = deadObjectBundle.deadObjectC.deadObjectEpochOpenAccepted
    val deadObjectPositionBeforeRecovery: Long get() = deadObjectBundle.deadObjectC.deadObjectPositionBeforeRecovery
    val deadObjectBaseFrameAfterRecovery: Long get() = deadObjectBundle.deadObjectC.deadObjectBaseFrameAfterRecovery
    val deadObjectBaseStepFrames: Long get() = deadObjectBundle.deadObjectC.deadObjectBaseStepFrames
    val deadObjectBaseStepBounded: Boolean get() = deadObjectBundle.deadObjectC.deadObjectBaseStepBounded
    val deadObjectContentHeadAtDeadObject: Long get() = deadObjectBundle.deadObjectC.deadObjectContentHeadAtDeadObject
    val deadObjectWrittenAheadOfHeadFrames: Long get() = deadObjectBundle.deadObjectC.deadObjectWrittenAheadOfHeadFrames

    val deadObjectPublicationLagFrames: Long get() = deadObjectBundle.deadObjectD.deadObjectPublicationLagFrames
    val deadObjectBaseStepDecompositionOk: Boolean get() = deadObjectBundle.deadObjectD.deadObjectBaseStepDecompositionOk
    val deadObjectClockProvenanceAtRecovery: String get() = deadObjectBundle.deadObjectD.deadObjectClockProvenanceAtRecovery
    val deadObjectClockLastAgeNsAtRecovery: Long get() = deadObjectBundle.deadObjectD.deadObjectClockLastAgeNsAtRecovery
    val deadObjectSliceBytesAtRecovery: Long get() = deadObjectBundle.deadObjectD.deadObjectSliceBytesAtRecovery
    val deadObjectUnwrittenBytesAtRecovery: Long get() = deadObjectBundle.deadObjectD.deadObjectUnwrittenBytesAtRecovery
    val deadObjectBufferPositionAtRecovery: Long get() = deadObjectBundle.deadObjectD.deadObjectBufferPositionAtRecovery
    val deadObjectFramesReadAtRecovery: Long get() = deadObjectBundle.deadObjectD.deadObjectFramesReadAtRecovery

    val deadObjectFramesWrittenBeforeRecovery: Long get() = deadObjectBundle.deadObjectE.deadObjectFramesWrittenBeforeRecovery
    val deadObjectRemainderFramesExpected: Long get() = deadObjectBundle.deadObjectE.deadObjectRemainderFramesExpected
    val deadObjectRemainderFramesWrittenOnNewTrack: Long get() = deadObjectBundle.deadObjectE.deadObjectRemainderFramesWrittenOnNewTrack
    val deadObjectRemainderAccountingOk: Boolean get() = deadObjectBundle.deadObjectE.deadObjectRemainderAccountingOk
    val deadObjectTimestampPollsDuringRecovery: Long get() = deadObjectBundle.deadObjectE.deadObjectTimestampPollsDuringRecovery
    val clockSnapshotsAtDeadObjectRecovery: Long get() = deadObjectBundle.deadObjectE.clockSnapshotsAtDeadObjectRecovery
    val playbackHeadAtDeadObject: Long get() = deadObjectBundle.deadObjectE.playbackHeadAtDeadObject

    val maxSeekHoldMs: Long get() = seekFlushBundle.seekFlushA.maxSeekHoldMs
    val seekParkCount: Int get() = seekFlushBundle.seekFlushA.seekParkCount
    val parkHoldCapMs: Long get() = seekFlushBundle.seekFlushA.parkHoldCapMs
    val flushRequestCount: Int get() = seekFlushBundle.seekFlushA.flushRequestCount
    val flushCount: Int get() = seekFlushBundle.seekFlushA.flushCount
    val flushExecutedOnSinkThread: Boolean get() = seekFlushBundle.seekFlushA.flushExecutedOnSinkThread
    val flushAckLatencyMs: Long get() = seekFlushBundle.seekFlushA.flushAckLatencyMs

    val playStateBeforeFlush: Int get() = seekFlushBundle.seekFlushB.playStateBeforeFlush
    val playStateAfterFlush: Int get() = seekFlushBundle.seekFlushB.playStateAfterFlush
    val playbackHeadBeforeFlush: Long get() = seekFlushBundle.seekFlushB.playbackHeadBeforeFlush
    val playbackHeadAfterFlush: Long get() = seekFlushBundle.seekFlushB.playbackHeadAfterFlush
    val framesWrittenAtFlush: Long get() = seekFlushBundle.seekFlushB.framesWrittenAtFlush
    val framesReadAtFlush: Long get() = seekFlushBundle.seekFlushB.framesReadAtFlush
    val drainCallsAtFlush: Long get() = seekFlushBundle.seekFlushB.drainCallsAtFlush

    val timestampPollsDuringFlush: Long get() = seekFlushBundle.seekFlushC.timestampPollsDuringFlush
    val postSeekExpectedFrames: Long get() = seekFlushBundle.seekFlushC.postSeekExpectedFrames
    val readBudgetFrames: Long get() = seekFlushBundle.seekFlushC.readBudgetFrames
    val seekTargetFrame: Long get() = seekFlushBundle.seekFlushC.seekTargetFrame
    val seekEpochOpenedAtUnpark: Int get() = seekFlushBundle.seekFlushC.seekEpochOpenedAtUnpark
    val seekEpochBaseFrame: Long get() = seekFlushBundle.seekFlushC.seekEpochBaseFrame

    val seekDiscontinuityFrames: Long get() = seekFlushBundle.seekFlushD.seekDiscontinuityFrames
    val seekEpochOpenAccepted: Boolean get() = seekFlushBundle.seekFlushD.seekEpochOpenAccepted
    val seekUnwrapResetAtFlush: Boolean get() = seekFlushBundle.seekFlushD.seekUnwrapResetAtFlush
    val epochRawOriginAtUnpark: Long get() = seekFlushBundle.seekFlushD.epochRawOriginAtUnpark
    val playbackHeadAtSeekUnpark: Long get() = seekFlushBundle.seekFlushD.playbackHeadAtSeekUnpark
    val postSeekFramesWritten: Long get() = seekFlushBundle.seekFlushD.postSeekFramesWritten
    val seekDeclaredBackward: Boolean get() = seekFlushBundle.seekFlushD.seekDeclaredBackward

    val epochBaseFrame: Long get() = lagDriftBundle.presentationLagA.epochBaseFrame
    val framesWrittenAtEpochOpen: Long get() = lagDriftBundle.presentationLagA.framesWrittenAtEpochOpen
    val framesReadAtEpochOpen: Long get() = lagDriftBundle.presentationLagA.framesReadAtEpochOpen
    val presentationLagSampleCount: Long get() = lagDriftBundle.presentationLagA.presentationLagSampleCount
    val presentationLagBoundedSampleCount: Long get() = lagDriftBundle.presentationLagA.presentationLagBoundedSampleCount
    val presentationLagExcludedSampleCount: Long get() = lagDriftBundle.presentationLagA.presentationLagExcludedSampleCount

    val lastPresentationLagFrames: Long get() = lagDriftBundle.presentationLagB.lastPresentationLagFrames
    val minPresentationLagFrames: Long get() = lagDriftBundle.presentationLagB.minPresentationLagFrames
    val maxPresentationLagFrames: Long get() = lagDriftBundle.presentationLagB.maxPresentationLagFrames
    val presentationLagLowerBoundFrames: Long get() = lagDriftBundle.presentationLagB.presentationLagLowerBoundFrames
    val presentationLagUpperBoundFrames: Long get() = lagDriftBundle.presentationLagB.presentationLagUpperBoundFrames
    val lastPositionFramesAtPoll: Long get() = lagDriftBundle.presentationLagB.lastPositionFramesAtPoll

    val lastPositionUsAtPoll: Long get() = lagDriftBundle.presentationLagC.lastPositionUsAtPoll
    val positionAtEosFrames: Long get() = lagDriftBundle.presentationLagC.positionAtEosFrames
    val positionAtEosUs: Long get() = lagDriftBundle.presentationLagC.positionAtEosUs
    val currentPositionReadsFromWriterThread: Long get() = lagDriftBundle.presentationLagC.currentPositionReadsFromWriterThread
    val currentPositionReadsFromOtherThreads: Long get() = lagDriftBundle.presentationLagC.currentPositionReadsFromOtherThreads

    val driftSamplesPosted: Long get() = lagDriftBundle.driftA.driftSamplesPosted
    val driftSamplesSkipped: Long get() = lagDriftBundle.driftA.driftSamplesSkipped
    val driftSamplesDropped: Long get() = lagDriftBundle.driftA.driftSamplesDropped
    val driftCallbackCount: Long get() = lagDriftBundle.driftA.driftCallbackCount
    val driftSamplesRecorded: Long get() = lagDriftBundle.driftA.driftSamplesRecorded
    val driftSamplesStaleRejected: Long get() = lagDriftBundle.driftA.driftSamplesStaleRejected

    val driftSamplesOtherRejected: Long get() = lagDriftBundle.driftB.driftSamplesOtherRejected
    val driftLastRejectReason: String get() = lagDriftBundle.driftB.driftLastRejectReason
    val driftMaxQueueLatencyNs: Long get() = lagDriftBundle.driftB.driftMaxQueueLatencyNs
    val driftLastPostedGeneration: Long get() = lagDriftBundle.driftB.driftLastPostedGeneration
    val driftLastExpectedPtsUs: Long get() = lagDriftBundle.driftB.driftLastExpectedPtsUs
    val driftLastReportedPtsUs: Long get() = lagDriftBundle.driftB.driftLastReportedPtsUs

    val driftLastDeltaUs: Long get() = lagDriftBundle.driftC.driftLastDeltaUs
    val driftLastReportedFrame: Long get() = lagDriftBundle.driftC.driftLastReportedFrame
    val driftNativeSampleCount: Long get() = lagDriftBundle.driftC.driftNativeSampleCount
    val driftNativeSamplesRecorded: Long get() = lagDriftBundle.driftC.driftNativeSamplesRecorded
    val driftNativeSamplesRejected: Long get() = lagDriftBundle.driftC.driftNativeSamplesRejected
}
