package com.connects.vanguard_media_engine.rtc

import android.hardware.HardwareBuffer
import android.os.Build

/**
 * Diagnostic smoke harness validating [RealtimeVideoInputAdapter] lifecycle state transitions,
 * frame delivery counters, terminal-state behavior, and scoped-borrow buffer safety.
 *
 * ## Verification Invariants
 * - **Zero Room / Audio Dependencies**: Pure video ingress adapter smoke harness; does not touch
 *   LiveKit, WebRTC native rooms, audio tracks, or microphone resources.
 * - **Scoped-Borrow Buffer Verification**: Uses a single synthetic [HardwareBuffer] passed across
 *   consecutive frames under scoped-borrow semantics. The harness retains buffer ownership and closes
 *   it in `finally` after all adapter invocations have completed.
 * - **Mechanical & Platform Safety**: Returns a structured result map with `pass=false` rather than
 *   throwing uncaught exceptions on invalid arguments or unsupported OS levels.
 */
object RealtimeVideoInputAdapterSmokeHarness {

    /**
     * Executes the [RealtimeVideoInputAdapter] lifecycle and delivery smoke test.
     *
     * @param width Width of the synthetic frame buffer (> 0).
     * @param height Height of the synthetic frame buffer (> 0).
     * @param frameCount Number of sequential frames to ingest during started state (> 0).
     * @return Map containing test verdict `pass` (Boolean), diagnostic `raw` status string, and snapshot telemetry.
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
            val sink = NoOpRtcVideoFrameSink()
            val adapter = RealtimeVideoInputAdapter(sink)

            // 1. Initial State Verification (IDLE)
            val initialSnapshot = adapter.snapshot()
            val initialPass = (initialSnapshot["state"] == RealtimeVideoInputState.IDLE.name) &&
                (initialSnapshot["acceptedFrames"] == 0L) &&
                (initialSnapshot["droppedBackpressureFrames"] == 0L) &&
                (initialSnapshot["droppedNotReadyFrames"] == 0L) &&
                (initialSnapshot["unsupportedFormatFrames"] == 0L) &&
                (initialSnapshot["failedFrames"] == 0L)

            // 2. Ingest before start (should drop as NOT_READY)
            val framePre = RealtimeVideoFrame(
                hardwareBuffer = hardwareBuffer,
                width = width,
                height = height,
                timestampNs = 0L,
                rotationDegrees = 0,
                frameIndex = 0L,
                sourceId = "adapter_smoke",
            )
            val resPre = adapter.ingestFrame(framePre)
            val preStartPass = !resPre.accepted &&
                resPre.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY

            // 3. Start adapter & ingest frameCount frames
            val startRes = adapter.start()
            val startPass = (startRes["pass"] == true) &&
                (adapter.snapshot()["state"] == RealtimeVideoInputState.STARTED.name)

            var startAcceptedCount = 0
            for (i in 0 until frameCount) {
                val frame = RealtimeVideoFrame(
                    hardwareBuffer = hardwareBuffer,
                    width = width,
                    height = height,
                    timestampNs = (i + 1) * 33333333L,
                    rotationDegrees = 0,
                    frameIndex = (i + 1).toLong(),
                    sourceId = "adapter_smoke",
                )
                val res = adapter.ingestFrame(frame)
                if (res.accepted && res.status == RtcVideoFrameDeliveryStatus.ACCEPTED) {
                    startAcceptedCount++
                }
            }
            val startDeliveryPass = startAcceptedCount == frameCount

            // 4. Ingest invalid frame while STARTED (should reject with UNSUPPORTED_FORMAT via RtcVideoFrameValidator)
            val invalidFrame = RealtimeVideoFrame(
                hardwareBuffer = hardwareBuffer,
                width = width + 10,
                height = height,
                timestampNs = (frameCount + 1) * 33333333L,
                rotationDegrees = 0,
                frameIndex = (frameCount + 1).toLong(),
                sourceId = "adapter_smoke",
            )
            val resInvalid = adapter.ingestFrame(invalidFrame)
            val sinkSnapshotAfterInvalid = sink.snapshot()
            val sinkAcceptedAfterInvalid = (sinkSnapshotAfterInvalid["acceptedFrames"] as? Number)?.toLong() ?: -1L
            val invalidFrameRejected = !resInvalid.accepted &&
                resInvalid.status == RtcVideoFrameDeliveryStatus.UNSUPPORTED_FORMAT &&
                sinkAcceptedAfterInvalid == frameCount.toLong() &&
                (adapter.snapshot()["unsupportedFormatFrames"] == 1L)

            // 5. Pause adapter & ingest frame (should drop as NOT_READY)
            val pauseRes = adapter.pause()
            val pausePass = (pauseRes["pass"] == true) &&
                (adapter.snapshot()["state"] == RealtimeVideoInputState.PAUSED.name)

            val framePaused = RealtimeVideoFrame(
                hardwareBuffer = hardwareBuffer,
                width = width,
                height = height,
                timestampNs = (frameCount + 2) * 33333333L,
                rotationDegrees = 0,
                frameIndex = (frameCount + 2).toLong(),
                sourceId = "adapter_smoke",
            )
            val resPaused = adapter.ingestFrame(framePaused)
            val pauseDeliveryPass = !resPaused.accepted &&
                resPaused.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY

            // 6. Resume adapter & ingest 1 frame (should be ACCEPTED)
            val resumeRes = adapter.resume()
            val resumePass = (resumeRes["pass"] == true) &&
                (adapter.snapshot()["state"] == RealtimeVideoInputState.STARTED.name)

            val frameResume = RealtimeVideoFrame(
                hardwareBuffer = hardwareBuffer,
                width = width,
                height = height,
                timestampNs = (frameCount + 3) * 33333333L,
                rotationDegrees = 0,
                frameIndex = (frameCount + 3).toLong(),
                sourceId = "adapter_smoke",
            )
            val resResume = adapter.ingestFrame(frameResume)
            val resumeDeliveryPass = resResume.accepted &&
                resResume.status == RtcVideoFrameDeliveryStatus.ACCEPTED

            // 7. Stop adapter & ingest frame (should drop as NOT_READY)
            val stopRes = adapter.stop()
            val stopPass = (stopRes["pass"] == true) &&
                (adapter.snapshot()["state"] == RealtimeVideoInputState.IDLE.name)

            val frameStopped = RealtimeVideoFrame(
                hardwareBuffer = hardwareBuffer,
                width = width,
                height = height,
                timestampNs = (frameCount + 4) * 33333333L,
                rotationDegrees = 0,
                frameIndex = (frameCount + 4).toLong(),
                sourceId = "adapter_smoke",
            )
            val resStopped = adapter.ingestFrame(frameStopped)
            val stopDeliveryPass = !resStopped.accepted &&
                resStopped.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY

            // 8. Dispose adapter & ingest frame (should drop as NOT_READY and not throw)
            val disposeRes = adapter.dispose()
            val disposePass = (disposeRes["pass"] == true) &&
                (adapter.snapshot()["state"] == RealtimeVideoInputState.DISPOSED.name)

            val frameDisposed = RealtimeVideoFrame(
                hardwareBuffer = hardwareBuffer,
                width = width,
                height = height,
                timestampNs = (frameCount + 5) * 33333333L,
                rotationDegrees = 0,
                frameIndex = (frameCount + 5).toLong(),
                sourceId = "adapter_smoke",
            )
            val resDisposed = adapter.ingestFrame(frameDisposed)
            val disposeDeliveryPass = !resDisposed.accepted &&
                resDisposed.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY

            // 9. Final telemetry verification
            val adapterSnapshot = adapter.snapshot()
            val acceptedFrames = (adapterSnapshot["acceptedFrames"] as? Number)?.toLong() ?: -1L
            val droppedBackpressureFrames = (adapterSnapshot["droppedBackpressureFrames"] as? Number)?.toLong() ?: -1L
            val droppedNotReadyFrames = (adapterSnapshot["droppedNotReadyFrames"] as? Number)?.toLong() ?: -1L
            val unsupportedFormatFrames = (adapterSnapshot["unsupportedFormatFrames"] as? Number)?.toLong() ?: -1L
            val failedFrames = (adapterSnapshot["failedFrames"] as? Number)?.toLong() ?: -1L
            val finalState = adapterSnapshot["state"] as? String

            val sinkSnapshot = sink.snapshot()
            val sinkAcceptedFrames = (sinkSnapshot["acceptedFrames"] as? Number)?.toLong() ?: -1L

            val expectedAccepted = (frameCount + 1).toLong()
            val expectedDroppedNotReady = 4L // pre-start (1) + paused (1) + stopped (1) + disposed (1)
            val expectedUnsupportedFormat = 1L // invalid frame rejected during started state (1)

            val telemetryPass = acceptedFrames == expectedAccepted &&
                droppedBackpressureFrames == 0L &&
                droppedNotReadyFrames == expectedDroppedNotReady &&
                unsupportedFormatFrames == expectedUnsupportedFormat &&
                failedFrames == 0L &&
                finalState == RealtimeVideoInputState.DISPOSED.name &&
                sinkAcceptedFrames == expectedAccepted

            val overallPass = initialPass &&
                preStartPass &&
                startPass &&
                startDeliveryPass &&
                invalidFrameRejected &&
                pausePass &&
                pauseDeliveryPass &&
                resumePass &&
                resumeDeliveryPass &&
                stopPass &&
                stopDeliveryPass &&
                disposePass &&
                disposeDeliveryPass &&
                telemetryPass

            val rawStatus = if (overallPass) {
                "status=OK;acceptedFrames=$acceptedFrames;droppedNotReadyFrames=$droppedNotReadyFrames;unsupportedFormatFrames=$unsupportedFormatFrames;invalidFrameRejected=true;finalState=$finalState"
            } else {
                "status=ADAPTER_VERIFICATION_FAILED;initialPass=$initialPass;preStartPass=$preStartPass;startPass=$startPass;startDeliveryPass=$startDeliveryPass;invalidFrameRejected=$invalidFrameRejected;pausePass=$pausePass;pauseDeliveryPass=$pauseDeliveryPass;resumePass=$resumePass;resumeDeliveryPass=$resumeDeliveryPass;stopPass=$stopPass;stopDeliveryPass=$stopDeliveryPass;disposePass=$disposePass;disposeDeliveryPass=$disposeDeliveryPass;telemetryPass=$telemetryPass"
            }

            return mapOf(
                "pass" to overallPass,
                "raw" to rawStatus,
                "adapterSnapshot" to adapterSnapshot,
                "sinkSnapshot" to sinkSnapshot,
                "frameCount" to frameCount,
                "expectedAccepted" to expectedAccepted,
                "expectedDroppedNotReady" to expectedDroppedNotReady,
                "expectedUnsupportedFormat" to expectedUnsupportedFormat,
                "invalidFrameRejected" to invalidFrameRejected,
            )
        } finally {
            hardwareBuffer.close()
        }
    }
}
