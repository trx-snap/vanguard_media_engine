package com.connects.vanguard_media_engine.streaming

/**
 * Diagnostic smoke harness validating [AdaptiveStreamTimelineController] metadata-only timeline evaluation,
 * sequential on-time frame acceptance, duplicate frame dropping, out-of-order frame dropping,
 * late frame threshold dropping, too-far-future frame rejection, retryable future frame re-evaluation and acceptance,
 * seek and rendition-step rebasing with generation bump, live-offset speed policy adjustments,
 * invalid negative parameter rejection, and reset behavior.
 *
 * ## Verification Invariants
 * - **Metadata Only / Zero Buffer Retention**: Operates strictly on numeric timestamps and frame indices.
 *   Never imports, allocates, retains, or touches HardwareBuffer, Image, Surface, Media3, or ExoPlayer instances.
 * - **Zero Network I/O**: Pure algorithmic and control-plane verification without network transport dependencies.
 * - **Deterministic Verification**: Tests synthetic sequences against precise counter and state assertions.
 * - **Mechanical Safety**: Catches unexpected errors and returns structured result map with `pass=false`.
 */
object AdaptiveStreamTimelineSmokeHarness {

    /**
     * Executes the [AdaptiveStreamTimelineController] smoke verification suite.
     *
     * @param frameCount Number of sequential on-time frames to evaluate in the initial pass (default 5).
     * @return Map containing test verdict `pass` (Boolean), diagnostic `raw` status string, and test telemetry.
     */
    fun run(frameCount: Int = 5): Map<String, Any?> {
        try {
            val effectiveFrameCount = if (frameCount > 0) frameCount else 5
            val controller = AdaptiveStreamTimelineController(
                lateThresholdUs = 250_000L,
                maxFutureLeadUs = 1_000_000L,
                liveOffsetPolicy = AdaptiveStreamLiveOffsetPolicy(
                    targetLiveOffsetMs = 3_000L,
                    minLiveOffsetMs = 1_500L,
                    maxLiveOffsetMs = 6_000L,
                    minPlaybackSpeed = 0.97,
                    maxPlaybackSpeed = 1.03,
                ),
            )

            val initialSnap = controller.snapshot()

            // 1. Initialize controller start
            val startResult = controller.start(
                frameTimeNanos = 1_000_000_000L,
                initialMediaPtsUs = 0L,
            )
            val startPass = startResult["pass"] == true

            // 2. Evaluate sequential on-time frames
            var allSequentialAccepted = true
            for (i in 0 until effectiveFrameCount) {
                val frameIndex = i.toLong()
                val samplePtsUs = i * 33_333L
                val arrivalFrameTimeNanos = 1_000_000_000L + (i * 33_333_000L)
                val decision = controller.evaluate(frameIndex, samplePtsUs, arrivalFrameTimeNanos)
                if (!decision.accepted || decision.status != AdaptiveStreamTimelineDecisionStatus.ACCEPTED) {
                    allSequentialAccepted = false
                }
            }

            val sequentialSnap = controller.snapshot()
            val expectedLastIndex = (effectiveFrameCount - 1).toLong()
            val expectedLastPts = (effectiveFrameCount - 1) * 33_333L

            val sequentialPass = startPass &&
                allSequentialAccepted &&
                (sequentialSnap["acceptedFrames"] == effectiveFrameCount.toLong()) &&
                (sequentialSnap["droppedLateFrames"] == 0L) &&
                (sequentialSnap["droppedOutOfOrderFrames"] == 0L) &&
                (sequentialSnap["droppedDuplicateFrames"] == 0L) &&
                (sequentialSnap["failedFrames"] == 0L) &&
                (sequentialSnap["lastAcceptedFrameIndex"] == expectedLastIndex) &&
                (sequentialSnap["lastAcceptedPtsUs"] == expectedLastPts)

            // 3. Evaluate duplicate frame (same index / pts as last accepted)
            val dupDecision = controller.evaluate(
                frameIndex = expectedLastIndex,
                samplePtsUs = expectedLastPts,
                arrivalFrameTimeNanos = 1_000_000_000L + (effectiveFrameCount * 33_333_000L),
            )
            val dupSnap = controller.snapshot()
            val duplicatePass = !dupDecision.accepted &&
                dupDecision.status == AdaptiveStreamTimelineDecisionStatus.DROPPED_DUPLICATE &&
                dupDecision.raw.contains("DROPPED_DUPLICATE") &&
                (dupSnap["droppedDuplicateFrames"] == 1L)

            // 4. Evaluate out-of-order older frame (frame 0 arriving after frame N)
            val oooDecision = controller.evaluate(
                frameIndex = 0L,
                samplePtsUs = 0L,
                arrivalFrameTimeNanos = 1_000_000_000L + ((effectiveFrameCount + 1) * 33_333_000L),
            )
            val oooSnap = controller.snapshot()
            val outOfOrderPass = !oooDecision.accepted &&
                oooDecision.status == AdaptiveStreamTimelineDecisionStatus.DROPPED_OUT_OF_ORDER &&
                oooDecision.raw.contains("DROPPED_OUT_OF_ORDER") &&
                (oooSnap["droppedOutOfOrderFrames"] == 1L)

            // 5. Evaluate late frame exceeding lateThresholdUs (250ms)
            val lateIndex = effectiveFrameCount.toLong()
            val latePtsUs = effectiveFrameCount * 33_333L
            val lateArrivalNanos = 1_000_000_000L + (effectiveFrameCount * 33_333_000L) + (300_000L * 1_000L)
            val lateDecision = controller.evaluate(
                frameIndex = lateIndex,
                samplePtsUs = latePtsUs,
                arrivalFrameTimeNanos = lateArrivalNanos,
            )
            val lateSnap = controller.snapshot()
            val latePass = !lateDecision.accepted &&
                lateDecision.status == AdaptiveStreamTimelineDecisionStatus.DROPPED_LATE &&
                lateDecision.raw.contains("DROPPED_LATE") &&
                (lateSnap["droppedLateFrames"] == 1L)

            // 6. Evaluate too-far-future frame exceeding maxFutureLeadUs (1,000ms)
            val futureIndex = (effectiveFrameCount + 1).toLong()
            val currentArrivalNanos = 1_000_000_000L + (effectiveFrameCount * 33_333_000L)
            val futurePtsUs = (effectiveFrameCount * 33_333L) + 1_500_000L
            val futureDecision = controller.evaluate(
                frameIndex = futureIndex,
                samplePtsUs = futurePtsUs,
                arrivalFrameTimeNanos = currentArrivalNanos,
            )
            val futureSnap = controller.snapshot()
            val futurePass = !futureDecision.accepted &&
                futureDecision.status == AdaptiveStreamTimelineDecisionStatus.FAILED &&
                futureDecision.retryable &&
                futureDecision.raw.contains("too_far_in_future") &&
                (futureSnap["failedFrames"] == 1L) &&
                (futureSnap["acceptedFrames"] == effectiveFrameCount.toLong())

            // 6b. Retry the same future frame later with a matching arrivalFrameTimeNanos (proving retryable semantics)
            val validRetryArrivalNanos = 1_000_000_000L + (futurePtsUs * 1_000L)
            val retryDecision = controller.evaluate(
                frameIndex = futureIndex,
                samplePtsUs = futurePtsUs,
                arrivalFrameTimeNanos = validRetryArrivalNanos,
            )
            val retrySnap = controller.snapshot()
            val futureRetryPass = retryDecision.accepted &&
                retryDecision.status == AdaptiveStreamTimelineDecisionStatus.ACCEPTED &&
                retryDecision.raw.contains("ACCEPTED") &&
                (retrySnap["acceptedFrames"] == (effectiveFrameCount + 1).toLong()) &&
                (retrySnap["lastAcceptedFrameIndex"] == futureIndex) &&
                (retrySnap["lastAcceptedPtsUs"] == futurePtsUs) &&
                (retrySnap["failedFrames"] == 1L)

            // 7. Evaluate seek rebase (increments generationId and resets last accepted bounds)
            val preSeekGen = controller.generationId
            val seekArrivalNanos = validRetryArrivalNanos + 50_000_000L
            val seekTargetPtsUs = 500_000L
            val seekDecision = controller.rebase(
                reason = "user_seek",
                frameTimeNanos = seekArrivalNanos,
                mediaPtsUs = seekTargetPtsUs,
            )
            val seekSampleDecision = controller.evaluate(
                frameIndex = 200L,
                samplePtsUs = seekTargetPtsUs,
                arrivalFrameTimeNanos = seekArrivalNanos,
            )
            val seekSnap = controller.snapshot()
            val seekRebasePass = seekDecision.accepted &&
                seekDecision.status == AdaptiveStreamTimelineDecisionStatus.REBASED &&
                (controller.generationId > preSeekGen) &&
                seekSampleDecision.accepted &&
                seekSampleDecision.status == AdaptiveStreamTimelineDecisionStatus.ACCEPTED &&
                (seekSnap["rebaseCount"] == 1L) &&
                (seekSnap["lastAcceptedFrameIndex"] == 200L) &&
                (seekSnap["lastAcceptedPtsUs"] == seekTargetPtsUs)

            // 8. Evaluate rendition-step rebase (ABR switch step)
            val preAbrGen = controller.generationId
            val abrArrivalNanos = seekArrivalNanos + 100_000_000L
            val abrTargetPtsUs = 600_000L
            val abrDecision = controller.rebase(
                reason = "abr_switch_720p_to_1080p",
                frameTimeNanos = abrArrivalNanos,
                mediaPtsUs = abrTargetPtsUs,
            )
            val abrSampleDecision = controller.evaluate(
                frameIndex = 300L,
                samplePtsUs = abrTargetPtsUs,
                arrivalFrameTimeNanos = abrArrivalNanos,
            )
            val abrSnap = controller.snapshot()
            val renditionRebasePass = abrDecision.accepted &&
                abrDecision.status == AdaptiveStreamTimelineDecisionStatus.REBASED &&
                (controller.generationId > preAbrGen) &&
                abrSampleDecision.accepted &&
                abrSampleDecision.status == AdaptiveStreamTimelineDecisionStatus.ACCEPTED &&
                (abrSnap["rebaseCount"] == 2L) &&
                (abrSnap["lastAcceptedFrameIndex"] == 300L) &&
                (abrSnap["lastAcceptedPtsUs"] == abrTargetPtsUs)

            // 9. Evaluate live offset policy behavior (direct & via controller evaluate)
            val policy = AdaptiveStreamLiveOffsetPolicy(
                targetLiveOffsetMs = 3_000L,
                minLiveOffsetMs = 1_500L,
                maxLiveOffsetMs = 6_000L,
                minPlaybackSpeed = 0.97,
                maxPlaybackSpeed = 1.03,
            )
            val highOffset = policy.evaluate(7_000L)
            val lowOffset = policy.evaluate(1_000L)
            val rebufOffset = policy.evaluate(3_000L, rebuffered = true)
            val targetOffset = policy.evaluate(3_000L)
            val controllerEval = controller.evaluate(
                frameIndex = 301L,
                samplePtsUs = 633_333L,
                arrivalFrameTimeNanos = abrArrivalNanos + 33_333_000L,
                currentLiveOffsetMs = 7_000L,
            )
            val liveOffsetPolicyPass = highOffset.status == AdaptiveStreamSpeedDecisionStatus.SPEED_UP &&
                highOffset.recommendedSpeed == 1.03 &&
                lowOffset.status == AdaptiveStreamSpeedDecisionStatus.SLOW_DOWN &&
                lowOffset.recommendedSpeed == 0.97 &&
                rebufOffset.status == AdaptiveStreamSpeedDecisionStatus.REBUFFER_MARGIN &&
                rebufOffset.recommendedSpeed == 0.97 &&
                targetOffset.status == AdaptiveStreamSpeedDecisionStatus.HOLD &&
                targetOffset.recommendedSpeed == 1.0 &&
                controllerEval.accepted &&
                controllerEval.raw.contains("liveOffsetStatus=SPEED_UP")

            // 10. Evaluate invalid negative inputs
            val negIndexDec = controller.evaluate(-1L, 100_000L, 100_000_000L)
            val negPtsDec = controller.evaluate(400L, -1L, 100_000_000L)
            val negArrivalDec = controller.evaluate(400L, 100_000L, -1L)
            val negPolicyDec = policy.evaluate(-100L)
            val negStartRes = controller.start(-1L, 0L)
            val negRebaseDec = controller.rebase("test", -1L, 0L)

            val negativeInputPass = !negIndexDec.accepted &&
                negIndexDec.status == AdaptiveStreamTimelineDecisionStatus.FAILED &&
                !negIndexDec.retryable &&
                !negPtsDec.accepted &&
                negPtsDec.status == AdaptiveStreamTimelineDecisionStatus.FAILED &&
                !negPtsDec.retryable &&
                !negArrivalDec.accepted &&
                negArrivalDec.status == AdaptiveStreamTimelineDecisionStatus.FAILED &&
                !negArrivalDec.retryable &&
                !negPolicyDec.pass &&
                negPolicyDec.status == AdaptiveStreamSpeedDecisionStatus.FAILED &&
                !negPolicyDec.retryable &&
                (negStartRes["pass"] == false) &&
                !negRebaseDec.accepted &&
                negRebaseDec.status == AdaptiveStreamTimelineDecisionStatus.FAILED

            // 11. Reset behavior verification
            val midSnap = controller.snapshot()
            val resetResult = controller.reset()
            val resetSnap = controller.snapshot()

            val resetPass = (resetResult["pass"] == true) &&
                (resetSnap["acceptedFrames"] == 0L) &&
                (resetSnap["droppedLateFrames"] == 0L) &&
                (resetSnap["droppedOutOfOrderFrames"] == 0L) &&
                (resetSnap["droppedDuplicateFrames"] == 0L) &&
                (resetSnap["failedFrames"] == 0L) &&
                (resetSnap["rebaseCount"] == 0L) &&
                (resetSnap["generationId"] == 0L) &&
                (resetSnap["lastAcceptedFrameIndex"] == null) &&
                (resetSnap["lastAcceptedPtsUs"] == null) &&
                (resetSnap["lastSeenFrameIndex"] == null) &&
                (resetSnap["isStarted"] == false)

            val overallPass = sequentialPass &&
                duplicatePass &&
                outOfOrderPass &&
                latePass &&
                futurePass &&
                futureRetryPass &&
                seekRebasePass &&
                renditionRebasePass &&
                liveOffsetPolicyPass &&
                negativeInputPass &&
                resetPass

            val rawStatus = if (overallPass) {
                "status=OK;sequentialPass=true;duplicatePass=true;outOfOrderPass=true;latePass=true;futurePass=true;futureRetryPass=true;seekRebasePass=true;renditionRebasePass=true;liveOffsetPolicyPass=true;negativeInputPass=true;resetPass=true"
            } else {
                "status=STREAM_TIMELINE_VERIFICATION_FAILED;sequentialPass=$sequentialPass;duplicatePass=$duplicatePass;outOfOrderPass=$outOfOrderPass;latePass=$latePass;futurePass=$futurePass;futureRetryPass=$futureRetryPass;seekRebasePass=$seekRebasePass;renditionRebasePass=$renditionRebasePass;liveOffsetPolicyPass=$liveOffsetPolicyPass;negativeInputPass=$negativeInputPass;resetPass=$resetPass"
            }

            return mapOf(
                "pass" to overallPass,
                "raw" to rawStatus,
                "frameCount" to effectiveFrameCount,
                "sequentialPass" to sequentialPass,
                "duplicatePass" to duplicatePass,
                "outOfOrderPass" to outOfOrderPass,
                "latePass" to latePass,
                "futurePass" to futurePass,
                "futureRetryPass" to futureRetryPass,
                "seekRebasePass" to seekRebasePass,
                "renditionRebasePass" to renditionRebasePass,
                "liveOffsetPolicyPass" to liveOffsetPolicyPass,
                "negativeInputPass" to negativeInputPass,
                "resetPass" to resetPass,
                "initialSnap" to initialSnap,
                "sequentialSnap" to sequentialSnap,
                "midSnap" to midSnap,
                "resetSnap" to resetSnap,
            )
        } catch (t: Throwable) {
            return mapOf(
                "pass" to false,
                "raw" to "status=UNEXPECTED_ERROR;reason=${t.message}",
            )
        }
    }
}
