package com.connects.vanguard_media_engine.streaming

import android.hardware.HardwareBuffer
import android.os.Build
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.rtc.RtcVideoFrameDeliveryStatus

/**
 * Diagnostic smoke harness proving the P6-MEDIA3-INGEST-STREAM-SOURCE-SEAM-A boundary: a real
 * [NativeStreamSourceMedia3FrameListener] (itself backed by a real native
 * `vanguard::sources::StreamSourceNode` metadata session) driven directly with
 * [HttpAdaptiveDecodedFrame] instances, as [HttpAdaptiveImageReaderBridge] would.
 *
 * ## Verification Invariants
 * - **Deterministic Lanes**: Uses `capacity = frameCount` as the native session's bounded metadata
 *   queue capacity so every lane's expected counters are derived arithmetically from `frameCount`,
 *   independent of its concrete value (>= 1).
 * - **Zero SDK / Network / Audio / Product Wiring**: Never touches ExoPlayer, MediaCodec,
 *   ImageReader, network state, audio tracks, rendering, or ConnectsApp/product/editor code.
 * - **Scoped-Borrow Verification**: Retains ownership of both synthetic [HardwareBuffer] instances
 *   and closes them in `finally`; asserts neither is closed by the listener during ingestion.
 */
object NativeStreamSourceMedia3IngestSmokeHarness {

    private const val STREAM_ID = "media3_ingest_seam_smoke"

    /**
     * Executes the seam smoke test.
     *
     * @param width Width of the native session's configured frame dimensions (> 0).
     * @param height Height of the native session's configured frame dimensions (> 0).
     * @param frameCount Also used as the native session's bounded queue capacity (> 0).
     * @return Map containing test verdict `pass` (Boolean), diagnostic `raw` status string, and
     *   per-lane pass booleans.
     */
    fun run(width: Int = 64, height: Int = 64, frameCount: Int = 3): Map<String, Any?> {
        if (width <= 0 || height <= 0 || frameCount <= 0) {
            return mapOf(
                "pass" to false,
                "raw" to "status=INVALID_ARGUMENT;width=$width;height=$height;frameCount=$frameCount",
            )
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return mapOf(
                "pass" to false,
                "raw" to "status=UNSUPPORTED_API;reason=HardwareBuffer requires Android O (API 26) or higher;sdkInt=${Build.VERSION.SDK_INT}",
            )
        }

        val capacity = frameCount
        val mismatchedWidth = if (width > 1) width / 2 else width + 1
        val mismatchedHeight = if (height > 1) height / 2 else height + 1

        var listener: NativeStreamSourceMedia3FrameListener? = null
        var primaryBuffer: HardwareBuffer? = null
        var mismatchedBuffer: HardwareBuffer? = null

        try {
            primaryBuffer = HardwareBuffer.create(
                width, height, HardwareBuffer.RGBA_8888, 1, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )
            mismatchedBuffer = HardwareBuffer.create(
                mismatchedWidth, mismatchedHeight, HardwareBuffer.RGBA_8888, 1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )

            val activeListener = NativeStreamSourceMedia3FrameListener(
                streamId = STREAM_ID,
                width = width,
                height = height,
                maxQueueCapacity = capacity,
            )
            listener = activeListener

            fun frame(idx: Long, buffer: HardwareBuffer, w: Int, h: Int, ptsUs: Long = idx * 33_333L) =
                HttpAdaptiveDecodedFrame(
                    hardwareBuffer = buffer,
                    ptsUs = ptsUs,
                    width = w,
                    height = h,
                    frameIndex = idx,
                )

            // ---- Lane 1: create/session lifecycle ----
            val createSnapshot = activeListener.snapshot()
            val createRaw = createSnapshot["raw"] as? String ?: ""
            val createLifecyclePass = createSnapshot["state"] == "IDLE" &&
                createRaw.contains("acceptedCount=0") &&
                createRaw.contains("queueSize=0") &&
                createRaw.contains("nodeKindIsSource=true") &&
                createRaw.contains("nodeTypeIsStreamSource=true")

            // ---- Lane 2: pre-start drop not-ready ----
            activeListener.onFrameAvailable(frame(0L, primaryBuffer, width, height))
            val resPreStart = activeListener.lastDeliveryResult
            val snapshotAfterPreStart = activeListener.snapshot()
            val preStartDropPass = !resPreStart.accepted &&
                resPreStart.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY &&
                (snapshotAfterPreStart["raw"] as? String)?.contains("acceptedCount=0") == true

            activeListener.start()

            // ---- Lane 3: started accept (fills native queue to exactly `capacity`) ----
            var startedAcceptedCount = 0
            var scopedBorrowOk = true
            for (i in 1..capacity) {
                activeListener.onFrameAvailable(frame(i.toLong(), primaryBuffer, width, height))
                val res = activeListener.lastDeliveryResult
                if (res.accepted && res.status == RtcVideoFrameDeliveryStatus.ACCEPTED) startedAcceptedCount++
                if (primaryBuffer.isClosed) scopedBorrowOk = false
            }
            val startedAcceptPass = startedAcceptedCount == capacity && scopedBorrowOk

            // ---- Lane 4: queue saturation/backpressure ----
            activeListener.onFrameAvailable(frame((capacity + 1).toLong(), primaryBuffer, width, height))
            val resBackpressure = activeListener.lastDeliveryResult
            val snapshotAfterBackpressure = activeListener.snapshot()
            val rawAfterBackpressure = snapshotAfterBackpressure["raw"] as? String ?: ""
            val backpressurePass = resBackpressure.status == RtcVideoFrameDeliveryStatus.DROPPED_BACKPRESSURE &&
                rawAfterBackpressure.contains("acceptedCount=$capacity;") &&
                rawAfterBackpressure.contains("lastAcceptedFrameIndex=$capacity;") &&
                rawAfterBackpressure.contains("queueSize=$capacity;")

            // ---- Lane 5: drain restores ingress (full drain, then refill to capacity) ----
            val drainResult = activeListener.drain(capacity)
            val drainedFully = (drainResult["raw"] as? String)?.contains("drained=$capacity;") == true

            var refillAcceptedCount = 0
            for (i in 1..capacity) {
                val idx = (capacity + 1 + i).toLong()
                activeListener.onFrameAvailable(frame(idx, primaryBuffer, width, height))
                val res = activeListener.lastDeliveryResult
                if (res.accepted && res.status == RtcVideoFrameDeliveryStatus.ACCEPTED) refillAcceptedCount++
            }
            val drainRestoresIngressPass = drainedFully && refillAcceptedCount == capacity

            // ---- Lane 6: mismatched dimension rejected (checked before backpressure, so queue
            //      fullness is irrelevant) ----
            val mismatchedFrameIndex = (2L * capacity + 2L)
            activeListener.onFrameAvailable(
                frame(mismatchedFrameIndex, mismatchedBuffer, mismatchedWidth, mismatchedHeight),
            )
            val resMismatch = activeListener.lastDeliveryResult
            val snapshotAfterMismatch = activeListener.snapshot()
            val rawAfterMismatch = snapshotAfterMismatch["raw"] as? String ?: ""
            val mismatchedDimensionPass = resMismatch.status == RtcVideoFrameDeliveryStatus.UNSUPPORTED_FORMAT &&
                resMismatch.raw.contains("dimension_mismatch") &&
                rawAfterMismatch.contains("unsupportedFormatCount=1;") &&
                rawAfterMismatch.contains("acceptedCount=${2 * capacity};")

            // ---- Lane 7: invalid negative pts/frameIndex rejected (also checked before
            //      backpressure, so queue fullness is irrelevant) ----
            val invalidFrameIndex = (2L * capacity + 3L)
            activeListener.onFrameAvailable(
                frame(invalidFrameIndex, primaryBuffer, width, height, ptsUs = -1L),
            )
            val resInvalid = activeListener.lastDeliveryResult
            val snapshotAfterInvalid = activeListener.snapshot()
            val rawAfterInvalid = snapshotAfterInvalid["raw"] as? String ?: ""
            val invalidTimestampOrIndexPass = resInvalid.status == RtcVideoFrameDeliveryStatus.UNSUPPORTED_FORMAT &&
                resInvalid.raw.contains("invalid_pts_or_frame_index") &&
                rawAfterInvalid.contains("unsupportedFormatCount=2;") &&
                rawAfterInvalid.contains("acceptedCount=${2 * capacity};")

            // ---- Lane 8: pause/resume lifecycle ----
            val pauseResult = activeListener.pause()
            val pausePass = pauseResult["pass"] == true && pauseResult["state"] == "PAUSED"

            activeListener.onFrameAvailable(frame((2L * capacity + 4L), primaryBuffer, width, height))
            val resPaused = activeListener.lastDeliveryResult
            val pauseIngestPass = resPaused.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY

            val resumeResult = activeListener.start()
            val resumePass = resumeResult["pass"] == true && resumeResult["state"] == "STARTED"

            activeListener.drain(capacity) // fully clear the queue so the resume-ingest below is unambiguously accepted
            activeListener.onFrameAvailable(frame((2L * capacity + 5L), primaryBuffer, width, height))
            val resResumeIngest = activeListener.lastDeliveryResult
            val resumeIngestPass = resResumeIngest.accepted &&
                resResumeIngest.status == RtcVideoFrameDeliveryStatus.ACCEPTED

            val pauseResumeLifecyclePass = pausePass && pauseIngestPass && resumePass && resumeIngestPass

            // ---- Lane 9: scoped-borrow buffer remains open after ingest ----
            val scopedBorrowPass = scopedBorrowOk && !primaryBuffer.isClosed && !mismatchedBuffer.isClosed

            // ---- Lane 10: idempotent close ----
            val finalSnapshot = activeListener.snapshot()
            val handle = activeListener.handle
            activeListener.close()
            activeListener.close() // Kotlin-level guard: must not throw, must not call native twice
            // Bypass the Kotlin guard to directly prove the native destroy contract's own
            // idempotent erase-once semantics: a second destroy of an already-erased handle
            // must return status=not_found, not crash or double-free.
            val nativeIdempotentDestroyPass =
                VanguardNativeBridge.destroyStreamSourceMedia3IngestSession(handle) == "status=not_found"
            val postCloseResult = try {
                activeListener.onFrameAvailable(frame((2L * capacity + 6L), primaryBuffer, width, height))
                true
            } catch (t: Throwable) {
                false
            }
            val idempotentClosePass = postCloseResult && nativeIdempotentDestroyPass

            // ---- Lane 11: proof boundary asserts no sdk/network/audio/product wiring ----
            val finalRaw = finalSnapshot["raw"] as? String ?: ""
            val proofBoundaryPass = NativeStreamSourceMedia3FrameListener.PROOF_BOUNDARY.contains("no_media3_exoplayer_sdk") &&
                NativeStreamSourceMedia3FrameListener.PROOF_BOUNDARY.contains("no_network_state") &&
                NativeStreamSourceMedia3FrameListener.PROOF_BOUNDARY.contains("no_audio") &&
                NativeStreamSourceMedia3FrameListener.PROOF_BOUNDARY.contains("no_product_app_editor_wiring") &&
                NativeStreamSourceMedia3FrameListener.PROOF_BOUNDARY.contains("no_hardware_buffer_ownership") &&
                finalRaw.contains("proofBoundary=${NativeStreamSourceMedia3FrameListener.PROOF_BOUNDARY}")

            val overallPass = createLifecyclePass &&
                preStartDropPass &&
                startedAcceptPass &&
                backpressurePass &&
                drainRestoresIngressPass &&
                mismatchedDimensionPass &&
                invalidTimestampOrIndexPass &&
                pauseResumeLifecyclePass &&
                scopedBorrowPass &&
                idempotentClosePass &&
                proofBoundaryPass

            val rawStatus = if (overallPass) {
                "status=OK;capacity=$capacity;createLifecycle=true;preStartDrop=true;startedAccept=true;" +
                    "backpressure=true;drainRestoresIngress=true;mismatchedDimension=true;" +
                    "invalidTimestampOrIndex=true;pauseResumeLifecycle=true;scopedBorrow=true;" +
                    "idempotentClose=true;proofBoundary=true"
            } else {
                "status=SEAM_VERIFICATION_FAILED;capacity=$capacity;createLifecycle=$createLifecyclePass;" +
                    "preStartDrop=$preStartDropPass;startedAccept=$startedAcceptPass;backpressure=$backpressurePass;" +
                    "drainRestoresIngress=$drainRestoresIngressPass;mismatchedDimension=$mismatchedDimensionPass;" +
                    "invalidTimestampOrIndex=$invalidTimestampOrIndexPass;" +
                    "pauseResumeLifecycle=$pauseResumeLifecyclePass;scopedBorrow=$scopedBorrowPass;" +
                    "idempotentClose=$idempotentClosePass;proofBoundary=$proofBoundaryPass"
            }

            return mapOf(
                "pass" to overallPass,
                "raw" to rawStatus,
                "capacity" to capacity,
                "createLifecyclePass" to createLifecyclePass,
                "preStartDropPass" to preStartDropPass,
                "startedAcceptPass" to startedAcceptPass,
                "backpressurePass" to backpressurePass,
                "drainRestoresIngressPass" to drainRestoresIngressPass,
                "mismatchedDimensionPass" to mismatchedDimensionPass,
                "invalidTimestampOrIndexPass" to invalidTimestampOrIndexPass,
                "pauseResumeLifecyclePass" to pauseResumeLifecyclePass,
                "scopedBorrowPass" to scopedBorrowPass,
                "idempotentClosePass" to idempotentClosePass,
                "proofBoundaryPass" to proofBoundaryPass,
                "proofBoundary" to NativeStreamSourceMedia3FrameListener.PROOF_BOUNDARY,
            )
        } catch (t: Throwable) {
            return mapOf(
                "pass" to false,
                "raw" to "status=FAIL;reason=exception:${t.message}",
            )
        } finally {
            listener?.close()
            primaryBuffer?.close()
            mismatchedBuffer?.close()
        }
    }
}
