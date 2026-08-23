package com.connects.vanguard_media_engine.rtc

/**
 * Diagnostic smoke harness validating [RtcVideoJitterBufferController] metadata-only timeline evaluation,
 * sequential on-time frame acceptance, duplicate frame dropping, out-of-order frame dropping,
 * late frame threshold dropping, too-far-future frame rejection, retryable future frame re-evaluation and acceptance,
 * invalid negative parameter rejection, constructor argument validation, and reset behavior.
 *
 * ## Verification Invariants
 * - **Metadata Only / Zero Buffer Retention**: Operates strictly on numeric timestamps and frame indices.
 *   Never imports, allocates, retains, or touches [android.hardware.HardwareBuffer] or [RealtimeVideoFrame].
 * - **Zero Room / Audio Dependencies**: Operates strictly within the video transport timeline domain without audio or room coupling.
 * - **Deterministic Verification**: Tests synthetic sequences against precise counter and state assertions.
 * - **Mechanical Safety**: Catches unexpected errors and returns structured result map with `pass=false`.
 */
object RtcVideoJitterBufferSmokeHarness {

    /**
     * Executes the [RtcVideoJitterBufferController] smoke verification suite.
     *
     * @param frameCount Number of sequential on-time frames to evaluate in the initial pass (default 5).
     * @return Map containing test verdict `pass` (Boolean), diagnostic `raw` status string, and test telemetry.
     */
    fun run(frameCount: Int = 5): Map<String, Any?> {
        try {
            val effectiveFrameCount = if (frameCount > 0) frameCount else 5
            val controller = RtcVideoJitterBufferController(
                targetPlayoutDelayNs = 66_666_666L,
                maxLateThresholdNs = 100_000_000L,
                maxFutureThresholdNs = 250_000_000L,
            )

            val initialSnap = controller.snapshot()

            // 1. Evaluate sequential on-time frames
            var allSequentialAccepted = true
            for (i in 0 until effectiveFrameCount) {
                val frameIndex = i.toLong()
                val timestampNs = 1_000_000_000L + (i * 33_333_333L)
                val arrivalTimeNs = timestampNs // Arrives immediately, well within target delay & late threshold
                val decision = controller.evaluate(frameIndex, timestampNs, arrivalTimeNs)
                if (!decision.accepted || decision.status != RtcVideoJitterDecisionStatus.ACCEPTED) {
                    allSequentialAccepted = false
                }
            }

            val sequentialSnap = controller.snapshot()
            val expectedLastIndex = (effectiveFrameCount - 1).toLong()
            val expectedLastTs = 1_000_000_000L + ((effectiveFrameCount - 1) * 33_333_333L)

            val sequentialPass = allSequentialAccepted &&
                (sequentialSnap["acceptedFrames"] == effectiveFrameCount.toLong()) &&
                (sequentialSnap["droppedLateFrames"] == 0L) &&
                (sequentialSnap["droppedOutOfOrderFrames"] == 0L) &&
                (sequentialSnap["droppedDuplicateFrames"] == 0L) &&
                (sequentialSnap["failedFrames"] == 0L) &&
                (sequentialSnap["lastAcceptedFrameIndex"] == expectedLastIndex) &&
                (sequentialSnap["lastAcceptedTimestampNs"] == expectedLastTs)

            // 2. Evaluate duplicate frame (same index / timestamp as last accepted)
            val dupDecision = controller.evaluate(
                frameIndex = expectedLastIndex,
                timestampNs = expectedLastTs,
                arrivalTimeNs = expectedLastTs + 10_000_000L,
            )
            val dupSnap = controller.snapshot()
            val duplicatePass = !dupDecision.accepted &&
                dupDecision.status == RtcVideoJitterDecisionStatus.DROPPED_DUPLICATE &&
                dupDecision.raw.contains("DROPPED_DUPLICATE") &&
                (dupSnap["droppedDuplicateFrames"] == 1L)

            // 3. Evaluate out-of-order older frame (frame 0 arriving after frame N)
            val oooDecision = controller.evaluate(
                frameIndex = 0L,
                timestampNs = 1_000_000_000L,
                arrivalTimeNs = expectedLastTs + 20_000_000L,
            )
            val oooSnap = controller.snapshot()
            val outOfOrderPass = !oooDecision.accepted &&
                oooDecision.status == RtcVideoJitterDecisionStatus.DROPPED_OUT_OF_ORDER &&
                oooDecision.raw.contains("DROPPED_OUT_OF_ORDER") &&
                (oooSnap["droppedOutOfOrderFrames"] == 1L)

            // 4. Evaluate late frame exceeding maxLateThresholdNs
            val lateFrameIndex = effectiveFrameCount.toLong()
            val lateTimestampNs = 1_000_000_000L + (effectiveFrameCount * 33_333_333L)
            val lateTargetPlayoutTimeNs = lateTimestampNs + controller.targetPlayoutDelayNs
            // arrivalTime is 50ms past targetPlayoutTime + maxLateThresholdNs
            val lateArrivalTimeNs = lateTargetPlayoutTimeNs + controller.maxLateThresholdNs + 50_000_000L
            val lateDecision = controller.evaluate(
                frameIndex = lateFrameIndex,
                timestampNs = lateTimestampNs,
                arrivalTimeNs = lateArrivalTimeNs,
            )
            val lateSnap = controller.snapshot()
            val latePass = !lateDecision.accepted &&
                lateDecision.status == RtcVideoJitterDecisionStatus.DROPPED_LATE &&
                lateDecision.raw.contains("DROPPED_LATE") &&
                (lateSnap["droppedLateFrames"] == 1L)

            // 5. Evaluate too-far-future frame exceeding maxFutureThresholdNs
            val futureFrameIndex = (effectiveFrameCount + 1).toLong()
            val currentArrivalNs = 1_000_000_000L + (effectiveFrameCount * 33_333_333L)
            // timestamp far in the future
            val futureTimestampNs = currentArrivalNs + controller.maxFutureThresholdNs + 200_000_000L
            val futureDecision = controller.evaluate(
                frameIndex = futureFrameIndex,
                timestampNs = futureTimestampNs,
                arrivalTimeNs = currentArrivalNs,
            )
            val futureSnap = controller.snapshot()
            val futurePass = !futureDecision.accepted &&
                futureDecision.status == RtcVideoJitterDecisionStatus.FAILED &&
                futureDecision.retryable &&
                futureDecision.raw.contains("too_far_in_future") &&
                (futureSnap["failedFrames"] == 1L) &&
                (futureSnap["acceptedFrames"] == effectiveFrameCount.toLong())

            // 5b. Retry the same future frame later with a valid arrivalTimeNs (proving retryable semantics)
            val validRetryArrivalTimeNs = futureTimestampNs // Arrives on time relative to future timestamp
            val retryDecision = controller.evaluate(
                frameIndex = futureFrameIndex,
                timestampNs = futureTimestampNs,
                arrivalTimeNs = validRetryArrivalTimeNs,
            )
            val retrySnap = controller.snapshot()
            val futureRetryPass = retryDecision.accepted &&
                retryDecision.status == RtcVideoJitterDecisionStatus.ACCEPTED &&
                retryDecision.raw.contains("ACCEPTED") &&
                (retrySnap["acceptedFrames"] == (effectiveFrameCount + 1).toLong()) &&
                (retrySnap["lastAcceptedFrameIndex"] == futureFrameIndex) &&
                (retrySnap["lastAcceptedTimestampNs"] == futureTimestampNs) &&
                (retrySnap["failedFrames"] == 1L)

            // 6. Evaluate invalid negative inputs
            val negIndexDec = controller.evaluate(-1L, 1_000_000_000L, 1_000_000_000L)
            val negTsDec = controller.evaluate(100L, -1L, 1_000_000_000L)
            val negArrDec = controller.evaluate(100L, 1_000_000_000L, -1L)
            val negSnap = controller.snapshot()
            val negativeInputPass = !negIndexDec.accepted &&
                negIndexDec.status == RtcVideoJitterDecisionStatus.FAILED &&
                !negIndexDec.retryable &&
                !negTsDec.accepted &&
                negTsDec.status == RtcVideoJitterDecisionStatus.FAILED &&
                !negTsDec.retryable &&
                !negArrDec.accepted &&
                negArrDec.status == RtcVideoJitterDecisionStatus.FAILED &&
                !negArrDec.retryable &&
                (negSnap["failedFrames"] == 4L) // 1 from future + 3 from negative

            // 7. Constructor argument validation
            var zeroDelayRejected = false
            try {
                RtcVideoJitterBufferController(targetPlayoutDelayNs = 0L)
            } catch (_: IllegalArgumentException) {
                zeroDelayRejected = true
            }

            var negLateRejected = false
            try {
                RtcVideoJitterBufferController(maxLateThresholdNs = -1L)
            } catch (_: IllegalArgumentException) {
                negLateRejected = true
            }

            var zeroFutureRejected = false
            try {
                RtcVideoJitterBufferController(maxFutureThresholdNs = 0L)
            } catch (_: IllegalArgumentException) {
                zeroFutureRejected = true
            }

            val constructorValidationPass = zeroDelayRejected && negLateRejected && zeroFutureRejected

            // 8. Reset behavior verification
            val midSnap = controller.snapshot()
            val resetResult = controller.reset()
            val resetSnap = controller.snapshot()

            val resetPass = (resetResult["pass"] == true) &&
                (resetSnap["acceptedFrames"] == 0L) &&
                (resetSnap["droppedLateFrames"] == 0L) &&
                (resetSnap["droppedOutOfOrderFrames"] == 0L) &&
                (resetSnap["droppedDuplicateFrames"] == 0L) &&
                (resetSnap["failedFrames"] == 0L) &&
                (resetSnap["lastAcceptedFrameIndex"] == null) &&
                (resetSnap["lastAcceptedTimestampNs"] == null) &&
                (resetSnap["lastSeenFrameIndex"] == null)

            val overallPass = sequentialPass &&
                duplicatePass &&
                outOfOrderPass &&
                latePass &&
                futurePass &&
                futureRetryPass &&
                negativeInputPass &&
                constructorValidationPass &&
                resetPass

            val rawStatus = if (overallPass) {
                "status=OK;sequentialPass=true;duplicatePass=true;outOfOrderPass=true;latePass=true;futurePass=true;futureRetryPass=true;negativeInputPass=true;constructorValidationPass=true;resetPass=true"
            } else {
                "status=JITTER_BUFFER_VERIFICATION_FAILED;sequentialPass=$sequentialPass;duplicatePass=$duplicatePass;outOfOrderPass=$outOfOrderPass;latePass=$latePass;futurePass=$futurePass;futureRetryPass=$futureRetryPass;negativeInputPass=$negativeInputPass;constructorValidationPass=$constructorValidationPass;resetPass=$resetPass"
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
                "negativeInputPass" to negativeInputPass,
                "constructorValidationPass" to constructorValidationPass,
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
