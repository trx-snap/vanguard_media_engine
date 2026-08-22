package com.connects.vanguard_media_engine.rtc

/**
 * Diagnostic smoke harness validating [RtcVideoBackpressureController] bounded frame-flow mechanics,
 * backpressure drop modes ([RtcVideoBackpressureMode.DROP_WHEN_BUSY], [RtcVideoBackpressureMode.LATEST_FRAME_WINS]),
 * concurrency limits, completion tracking, reset behavior, and negative frame index rejection.
 *
 * ## Verification Invariants
 * - **Zero Room / Audio Dependencies**: Operates strictly within the video domain without audio or room coupling.
 * - **Deterministic Verification**: Tests synthetic sequences against precise counter and state assertions.
 * - **Mechanical Safety**: Catches unexpected errors and returns structured result map with `pass=false`.
 */
object RtcVideoBackpressureSmokeHarness {

    /**
     * Executes the [RtcVideoBackpressureController] smoke verification suite.
     *
     * @return Map containing test verdict `pass` (Boolean), diagnostic `raw` status string, and test telemetry.
     */
    fun run(): Map<String, Any?> {
        try {
            // 1. Test DROP_WHEN_BUSY with maxInFlight = 1
            // Accept frame 0, attempt frame 1 (dropped), mark frame 0 complete, accept frame 2
            val dropCtrl = RtcVideoBackpressureController(
                maxInFlightFrames = 1,
                mode = RtcVideoBackpressureMode.DROP_WHEN_BUSY,
            )

            val dropRes0 = dropCtrl.tryAccept(0L)
            val dropRes1 = dropCtrl.tryAccept(1L)
            val dropComp0 = dropCtrl.markComplete(0L)
            val dropRes2 = dropCtrl.tryAccept(2L)
            val dropSnap = dropCtrl.snapshot()

            val dropWhenBusyPass = dropRes0.accepted &&
                dropRes0.status == RtcVideoFrameDeliveryStatus.ACCEPTED &&
                !dropRes1.accepted &&
                dropRes1.status == RtcVideoFrameDeliveryStatus.DROPPED_BACKPRESSURE &&
                dropRes1.raw.contains("DROP_WHEN_BUSY") &&
                dropComp0["pass"] == true &&
                dropRes2.accepted &&
                dropRes2.status == RtcVideoFrameDeliveryStatus.ACCEPTED &&
                (dropSnap["acceptedFrames"] == 2L) &&
                (dropSnap["droppedFrames"] == 1L) &&
                (dropSnap["completedFrames"] == 1L) &&
                (dropSnap["inFlightFrames"] == 1) &&
                (dropSnap["latestAcceptedFrameIndex"] == 2L) &&
                (dropSnap["latestDroppedFrameIndex"] == 1L)

            // 2. Test LATEST_FRAME_WINS with maxInFlight = 1
            // Accept frame 0, attempt frame 1 (dropped with replace_in_flight_deferred reason), mark frame 0 complete, accept frame 2
            val latestCtrl = RtcVideoBackpressureController(
                maxInFlightFrames = 1,
                mode = RtcVideoBackpressureMode.LATEST_FRAME_WINS,
            )

            val latestRes0 = latestCtrl.tryAccept(0L)
            val latestRes1 = latestCtrl.tryAccept(1L)
            val latestComp0 = latestCtrl.markComplete(0L)
            val latestRes2 = latestCtrl.tryAccept(2L)
            val latestSnap = latestCtrl.snapshot()

            val latestFrameWinsPass = latestRes0.accepted &&
                latestRes0.status == RtcVideoFrameDeliveryStatus.ACCEPTED &&
                !latestRes1.accepted &&
                latestRes1.status == RtcVideoFrameDeliveryStatus.DROPPED_BACKPRESSURE &&
                latestRes1.raw.contains("replace_in_flight_deferred") &&
                latestComp0["pass"] == true &&
                latestRes2.accepted &&
                latestRes2.status == RtcVideoFrameDeliveryStatus.ACCEPTED &&
                (latestSnap["acceptedFrames"] == 2L) &&
                (latestSnap["droppedFrames"] == 1L) &&
                (latestSnap["completedFrames"] == 1L) &&
                (latestSnap["inFlightFrames"] == 1) &&
                (latestSnap["latestAcceptedFrameIndex"] == 2L) &&
                (latestSnap["latestDroppedFrameIndex"] == 1L)

            // 3. Test maxInFlight = 2 accepts two frames before dropping
            val dualCtrl = RtcVideoBackpressureController(
                maxInFlightFrames = 2,
                mode = RtcVideoBackpressureMode.DROP_WHEN_BUSY,
            )

            val dualRes0 = dualCtrl.tryAccept(0L)
            val dualRes1 = dualCtrl.tryAccept(1L)
            val dualRes2 = dualCtrl.tryAccept(2L) // Dropped: inFlight=2 reached maxInFlight=2
            dualCtrl.markComplete(0L) // inFlight becomes 1
            val dualRes3 = dualCtrl.tryAccept(3L) // Accepted: inFlight becomes 2
            dualCtrl.markComplete(1L)
            dualCtrl.markComplete(3L)
            val dualSnap = dualCtrl.snapshot()

            val maxInFlight2Pass = dualRes0.accepted &&
                dualRes1.accepted &&
                !dualRes2.accepted &&
                dualRes2.status == RtcVideoFrameDeliveryStatus.DROPPED_BACKPRESSURE &&
                dualRes3.accepted &&
                (dualSnap["acceptedFrames"] == 3L) &&
                (dualSnap["droppedFrames"] == 1L) &&
                (dualSnap["completedFrames"] == 3L) &&
                (dualSnap["inFlightFrames"] == 0) &&
                (dualSnap["latestAcceptedFrameIndex"] == 3L) &&
                (dualSnap["latestDroppedFrameIndex"] == 2L)

            // 4. Test invalid negative frameIndex returns failed result
            val invalidCtrl = RtcVideoBackpressureController(maxInFlightFrames = 1)
            val invalidRes = invalidCtrl.tryAccept(-1L)
            val invalidSnap = invalidCtrl.snapshot()

            val invalidFrameIndexPass = !invalidRes.accepted &&
                invalidRes.status == RtcVideoFrameDeliveryStatus.FAILED &&
                !invalidRes.retryable &&
                (invalidSnap["failedFrames"] == 1L)

            // 5. Test invalid maxInFlightFrames constructor argument rejection
            var zeroRejected = false
            try {
                RtcVideoBackpressureController(maxInFlightFrames = 0)
            } catch (_: IllegalArgumentException) {
                zeroRejected = true
            }

            var negRejected = false
            try {
                RtcVideoBackpressureController(maxInFlightFrames = -1)
            } catch (_: IllegalArgumentException) {
                negRejected = true
            }

            val constructorValidationPass = zeroRejected && negRejected

            // 6. Test reset and idempotent markComplete on zero in-flight frames
            val resetResult = invalidCtrl.reset()
            val resetSnap = invalidCtrl.snapshot()
            val idempotentComp = invalidCtrl.markComplete(null)

            val resetPass = (resetResult["pass"] == true) &&
                (resetSnap["acceptedFrames"] == 0L) &&
                (resetSnap["droppedFrames"] == 0L) &&
                (resetSnap["completedFrames"] == 0L) &&
                (resetSnap["failedFrames"] == 0L) &&
                (resetSnap["inFlightFrames"] == 0) &&
                (resetSnap["latestAcceptedFrameIndex"] == null) &&
                (resetSnap["latestDroppedFrameIndex"] == null) &&
                (idempotentComp["pass"] == true) &&
                (idempotentComp["inFlightFrames"] == 0)

            val overallPass = dropWhenBusyPass &&
                latestFrameWinsPass &&
                maxInFlight2Pass &&
                invalidFrameIndexPass &&
                constructorValidationPass &&
                resetPass

            val rawStatus = if (overallPass) {
                "status=OK;dropWhenBusyPass=true;latestFrameWinsPass=true;maxInFlight2Pass=true;invalidFrameIndexPass=true;constructorValidationPass=true;resetPass=true"
            } else {
                "status=BACKPRESSURE_CONTROLLER_VERIFICATION_FAILED;dropWhenBusyPass=$dropWhenBusyPass;latestFrameWinsPass=$latestFrameWinsPass;maxInFlight2Pass=$maxInFlight2Pass;invalidFrameIndexPass=$invalidFrameIndexPass;constructorValidationPass=$constructorValidationPass;resetPass=$resetPass"
            }

            return mapOf(
                "pass" to overallPass,
                "raw" to rawStatus,
                "dropWhenBusyPass" to dropWhenBusyPass,
                "latestFrameWinsPass" to latestFrameWinsPass,
                "maxInFlight2Pass" to maxInFlight2Pass,
                "invalidFrameIndexPass" to invalidFrameIndexPass,
                "constructorValidationPass" to constructorValidationPass,
                "resetPass" to resetPass,
                "dropSnap" to dropSnap,
                "latestSnap" to latestSnap,
                "dualSnap" to dualSnap,
                "invalidSnap" to invalidSnap,
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
