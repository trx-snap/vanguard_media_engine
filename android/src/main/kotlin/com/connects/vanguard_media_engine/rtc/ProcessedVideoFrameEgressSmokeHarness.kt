package com.connects.vanguard_media_engine.rtc

import android.hardware.HardwareBuffer
import android.os.Build

/**
 * Diagnostic smoke harness verifying the [ProcessedVideoFrameEgressAdapter] lifecycle,
 * frame delivery, backpressure gating, orientation normalization, and scoped-borrow buffer safety
 * without any SDK, network, WebRTC, or LiveKit dependencies.
 *
 * ## Verification Invariants
 * - **Zero Room / Audio / Network Dependencies**: Pure video egress adapter smoke; does not touch
 *   LiveKit, WebRTC native rooms, audio tracks, or platform audio routing.
 * - **Scoped-Borrow Buffer Verification**: A single synthetic [HardwareBuffer] is created once and
 *   passed across adapter calls under scoped-borrow semantics. The harness retains exclusive
 *   buffer ownership and closes it in `finally` after all synchronous adapter calls complete.
 *   The adapter and publisher must never close the buffer before the harness `finally` block.
 * - **Mechanical & Platform Safety**: Returns a structured result map with `pass=false` rather
 *   than throwing uncaught exceptions on invalid arguments or unsupported OS levels.
 */
object ProcessedVideoFrameEgressSmokeHarness {

    /**
     * Executes the [ProcessedVideoFrameEgressAdapter] lifecycle and delivery smoke test.
     *
     * Verified scenarios:
     * 1. Pre-start publish — dropped as not-ready; publisher not called as accepted.
     * 2. start() + [frameCount] sequential publishes — all accepted.
     * 3. Non-cardinal rotation (91°) — normalized and accepted.
     * 4. pause() publish — dropped as not-ready.
     * 5. resume() publish — accepted.
     * 6. stop() publish — dropped as not-ready.
     * 7. dispose() — terminal state; further publish does not throw.
     * 8. Publisher accepted frame count equals expected accepted count.
     * 9. [HardwareBuffer] is not closed by adapter or publisher before harness `finally`.
     *
     * @param width Width of the synthetic frame buffer (must be > 0).
     * @param height Height of the synthetic frame buffer (must be > 0).
     * @param frameCount Number of sequential frames to publish during started state (must be > 0).
     * @return Structured map with `pass` (Boolean), `raw` (String), expected/actual counters,
     *   `adapterSnapshot`, and `publisherSnapshot`.
     */
    fun run(width: Int = 64, height: Int = 64, frameCount: Int = 3): Map<String, Any?> {
        if (width <= 0 || height <= 0 || frameCount <= 0) {
            return mapOf(
                "pass" to false,
                "raw" to "status=INVALID_ARGUMENT;reason=width, height, and frameCount must be positive;width=$width;height=$height;frameCount=$frameCount",
            )
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return mapOf(
                "pass" to false,
                "raw" to "status=UNSUPPORTED_API;reason=HardwareBuffer requires Android O (API 26) or higher;sdkInt=${Build.VERSION.SDK_INT}",
            )
        }

        val hardwareBuffer = try {
            HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )
        } catch (t: Throwable) {
            return mapOf(
                "pass" to false,
                "raw" to "status=HARDWARE_BUFFER_CREATION_FAILED;reason=${t.message}",
            )
        }

        try {
            val publisher = NoOpRtcVideoFramePublisher()
            // maxInFlightFrames=1 so backpressure is exercised predictably
            val adapter = ProcessedVideoFrameEgressAdapter(
                publisher = publisher,
                maxInFlightFrames = 1,
                sourceId = "vanguard_processed_egress",
            )

            var frameSeq = 0L
            // Monotonic base PTS; advance by 33 333 µs (~30 fps) per frame
            val ptsDeltaUs = 33_333L

            // ---------------------------------------------------------------
            // 1. Pre-start publish — must be dropped (not-ready); publisher
            //    must not record an accepted frame for this call.
            // ---------------------------------------------------------------
            val pubSnapshotBefore = publisher.snapshot()
            val pubAcceptedBefore = (pubSnapshotBefore["acceptedFrames"] as? Number)?.toLong() ?: -1L

            val resPreStart = adapter.publishProcessedFrame(
                hardwareBuffer = hardwareBuffer,
                width = width,
                height = height,
                ptsUs = frameSeq * ptsDeltaUs,
                rotationDegrees = 0,
                mirrored = false,
                frameIndex = frameSeq,
            )
            frameSeq++

            val pubSnapshotAfterPreStart = publisher.snapshot()
            val pubAcceptedAfterPreStart = (pubSnapshotAfterPreStart["acceptedFrames"] as? Number)?.toLong() ?: -1L

            val preStartDropped = !resPreStart.accepted &&
                resPreStart.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY
            // Publisher must not have recorded an additional accepted frame for this call
            val preStartPublisherNotCalled = pubAcceptedAfterPreStart == pubAcceptedBefore

            val preStartPass = preStartDropped && preStartPublisherNotCalled

            // ---------------------------------------------------------------
            // 2. start() + frameCount sequential publishes — all accepted
            // ---------------------------------------------------------------
            adapter.start()

            var startAcceptedCount = 0
            repeat(frameCount) {
                val res = adapter.publishProcessedFrame(
                    hardwareBuffer = hardwareBuffer,
                    width = width,
                    height = height,
                    ptsUs = frameSeq * ptsDeltaUs,
                    rotationDegrees = 0,
                    mirrored = false,
                    frameIndex = frameSeq,
                )
                frameSeq++
                if (res.accepted) startAcceptedCount++
            }
            val startDeliveryPass = startAcceptedCount == frameCount

            // ---------------------------------------------------------------
            // 3. Non-cardinal rotation (91°) — normalized and accepted
            // ---------------------------------------------------------------
            val resNonCardinal = adapter.publishProcessedFrame(
                hardwareBuffer = hardwareBuffer,
                width = width,
                height = height,
                ptsUs = frameSeq * ptsDeltaUs,
                rotationDegrees = 91,
                mirrored = false,
                frameIndex = frameSeq,
            )
            frameSeq++
            val nonCardinalPass = resNonCardinal.accepted

            // ---------------------------------------------------------------
            // 4. pause() — next publish must be dropped as not-ready
            // ---------------------------------------------------------------
            adapter.pause()

            val resPaused = adapter.publishProcessedFrame(
                hardwareBuffer = hardwareBuffer,
                width = width,
                height = height,
                ptsUs = frameSeq * ptsDeltaUs,
                rotationDegrees = 0,
                mirrored = false,
                frameIndex = frameSeq,
            )
            frameSeq++
            val pauseDropPass = !resPaused.accepted &&
                resPaused.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY

            // ---------------------------------------------------------------
            // 5. resume() — next publish must be accepted
            // ---------------------------------------------------------------
            adapter.resume()

            val resResumed = adapter.publishProcessedFrame(
                hardwareBuffer = hardwareBuffer,
                width = width,
                height = height,
                ptsUs = frameSeq * ptsDeltaUs,
                rotationDegrees = 0,
                mirrored = false,
                frameIndex = frameSeq,
            )
            frameSeq++
            val resumeAcceptPass = resResumed.accepted

            // ---------------------------------------------------------------
            // 6. stop() — next publish must be dropped as not-ready
            // ---------------------------------------------------------------
            adapter.stop()

            val resStopped = adapter.publishProcessedFrame(
                hardwareBuffer = hardwareBuffer,
                width = width,
                height = height,
                ptsUs = frameSeq * ptsDeltaUs,
                rotationDegrees = 0,
                mirrored = false,
                frameIndex = frameSeq,
            )
            frameSeq++
            val stopDropPass = !resStopped.accepted &&
                resStopped.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY

            // ---------------------------------------------------------------
            // 7. dispose() — terminal state; further publish must not throw
            // ---------------------------------------------------------------
            adapter.dispose()

            val resDisposed = try {
                adapter.publishProcessedFrame(
                    hardwareBuffer = hardwareBuffer,
                    width = width,
                    height = height,
                    ptsUs = frameSeq * ptsDeltaUs,
                    rotationDegrees = 0,
                    mirrored = false,
                    frameIndex = frameSeq,
                )
            } catch (t: Throwable) {
                null
            }
            frameSeq++
            val disposePass = resDisposed != null && !resDisposed.accepted

            // ---------------------------------------------------------------
            // 8. Publisher accepted frame count equals expected accepted count.
            //    Expected: frameCount (sequential) + 1 (non-cardinal rotation) + 1 (resume)
            // ---------------------------------------------------------------
            val expectedAccepted = (frameCount + 2).toLong() // sequential + non-cardinal + resumed
            val adapterSnapshot = adapter.snapshot()
            val publisherSnapshot = publisher.snapshot()
            val pubActualAccepted = (publisherSnapshot["acceptedFrames"] as? Number)?.toLong() ?: -1L
            val publisherCountPass = pubActualAccepted == expectedAccepted

            // ---------------------------------------------------------------
            // 8b. Backpressure telemetry must not be polluted by not-ready lifecycle drops.
            //     acceptedFrames in the backpressure snapshot must equal the number of started-path
            //     frame attempts (frameCount sequential + 1 non-cardinal + 1 resume).
            //     completedFrames must equal the same count, since each backpressure-accepted frame
            //     is synchronously completed in publishProcessedFrame's finally block.
            //     Frames dropped by the lifecycle gate (pre-start, pause, stop, dispose) must never
            //     increment backpressure slot counters.
            // ---------------------------------------------------------------
            val backpressureSnapshot = (adapterSnapshot["backpressure"] as? Map<*, *>)
            val bpAcceptedFrames = (backpressureSnapshot?.get("acceptedFrames") as? Number)?.toLong() ?: -1L
            val bpCompletedFrames = (backpressureSnapshot?.get("completedFrames") as? Number)?.toLong() ?: -1L
            // Started-path attempts: frameCount sequential + 1 non-cardinal + 1 resume
            val expectedBpAccepted = expectedAccepted
            val backpressureTelemetryPass =
                bpAcceptedFrames == expectedBpAccepted && bpCompletedFrames == expectedBpAccepted

            // ---------------------------------------------------------------
            // 9. HardwareBuffer not closed by adapter/publisher before harness finally.
            //    Validated implicitly: if it were closed, later publishProcessedFrame calls
            //    would either throw or produce anomalous results. We also verify the buffer
            //    object is still the same reference in scope at this point (it has not been
            //    replaced or nulled by the adapter, which only borrows it).
            // ---------------------------------------------------------------
            val bufferNotClosedByAdapter = !hardwareBuffer.isClosed

            val overallPass =
                preStartPass &&
                    startDeliveryPass &&
                    nonCardinalPass &&
                    pauseDropPass &&
                    resumeAcceptPass &&
                    stopDropPass &&
                    disposePass &&
                    publisherCountPass &&
                    backpressureTelemetryPass &&
                    bufferNotClosedByAdapter

            val rawStatus = if (overallPass) {
                "status=OK;expectedAccepted=$expectedAccepted;pubActualAccepted=$pubActualAccepted;" +
                    "bpAcceptedFrames=$bpAcceptedFrames;bpCompletedFrames=$bpCompletedFrames;" +
                    "bufferNotClosedByAdapter=$bufferNotClosedByAdapter"
            } else {
                "status=EGRESS_SMOKE_FAILED;" +
                    "preStartPass=$preStartPass;" +
                    "startDeliveryPass=$startDeliveryPass;" +
                    "nonCardinalPass=$nonCardinalPass;" +
                    "pauseDropPass=$pauseDropPass;" +
                    "resumeAcceptPass=$resumeAcceptPass;" +
                    "stopDropPass=$stopDropPass;" +
                    "disposePass=$disposePass;" +
                    "publisherCountPass=$publisherCountPass;" +
                    "backpressureTelemetryPass=$backpressureTelemetryPass;" +
                    "bpAcceptedFrames=$bpAcceptedFrames;bpCompletedFrames=$bpCompletedFrames;" +
                    "expectedBpAccepted=$expectedBpAccepted;" +
                    "bufferNotClosedByAdapter=$bufferNotClosedByAdapter;" +
                    "expectedAccepted=$expectedAccepted;" +
                    "pubActualAccepted=$pubActualAccepted"
            }

            return mapOf(
                "pass" to overallPass,
                "raw" to rawStatus,
                "expectedAccepted" to expectedAccepted,
                "actualAccepted" to pubActualAccepted,
                "adapterSnapshot" to adapterSnapshot,
                "publisherSnapshot" to publisherSnapshot,
                "frameCount" to frameCount,
                "bufferNotClosedByAdapter" to bufferNotClosedByAdapter,
                "bpAcceptedFrames" to bpAcceptedFrames,
                "bpCompletedFrames" to bpCompletedFrames,
            )
        } finally {
            // Harness owns and closes the buffer; adapter/publisher must never have closed it.
            hardwareBuffer.close()
        }
    }
}
