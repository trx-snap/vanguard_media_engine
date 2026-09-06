package com.connects.vanguard_media_engine.rtc

import android.hardware.HardwareBuffer
import android.os.Build
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge

/**
 * Diagnostic smoke harness proving the P6-WEBRTC-INGEST-STREAM-SOURCE-SEAM-A boundary: a real
 * [RealtimeVideoInputAdapter] wired to a real [NativeStreamSourceRtcVideoFrameSink] (itself backed by
 * a real native `vanguard::sources::StreamSourceNode` metadata session).
 *
 * ## Verification Invariants
 * - **Deterministic Lanes**: Uses `capacity = frameCount` as the native session's bounded metadata
 *   queue capacity so every lane's expected counters are derived arithmetically from `frameCount`,
 *   independent of its concrete value (>= 1).
 * - **Zero SDK / Network / Audio / Product Wiring**: Never touches WebRTC, LiveKit, room signaling,
 *   audio tracks, rendering, or ConnectsApp/product/editor code.
 * - **Scoped-Borrow Verification**: Retains ownership of both synthetic [HardwareBuffer] instances and
 *   closes them in `finally`; asserts neither is closed by the sink during ingestion.
 */
object NativeStreamSourceRtcIngestSmokeHarness {

    private const val STREAM_ID = "webrtc_ingest_seam_smoke"

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

        var sink: NativeStreamSourceRtcVideoFrameSink? = null
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

            sink = NativeStreamSourceRtcVideoFrameSink(
                streamId = STREAM_ID,
                width = width,
                height = height,
                maxQueueCapacity = capacity,
            )
            val adapter = RealtimeVideoInputAdapter(sink)

            fun frame(idx: Long, buffer: HardwareBuffer, w: Int, h: Int) = RealtimeVideoFrame(
                hardwareBuffer = buffer,
                width = w,
                height = h,
                timestampNs = idx * 33_333_333L,
                rotationDegrees = 0,
                frameIndex = idx,
                sourceId = "seam_smoke",
            )

            // ---- Lane 1: create/session lifecycle ----
            val createSnapshot = sink.snapshot()
            val createRaw = createSnapshot["raw"] as? String ?: ""
            val createLifecyclePass = createSnapshot["state"] == "IDLE" &&
                createRaw.contains("acceptedCount=0") &&
                createRaw.contains("queueSize=0") &&
                createRaw.contains("nodeKindIsSource=true") &&
                createRaw.contains("nodeTypeIsStreamSource=true")

            // ---- Lane 2: pre-start adapter drop not-ready (adapter gates before calling sink) ----
            val resPreStart = adapter.ingestFrame(frame(0L, primaryBuffer, width, height))
            val snapshotAfterPreStart = sink.snapshot()
            val preStartPass = !resPreStart.accepted &&
                resPreStart.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY &&
                (snapshotAfterPreStart["raw"] as? String)?.contains("acceptedCount=0") == true

            adapter.start()
            sink.start()

            // ---- Lane 3: started accept (fills native queue to exactly `capacity`) ----
            var startedAcceptedCount = 0
            var scopedBorrowOk = true
            for (i in 1..capacity) {
                val res = adapter.ingestFrame(frame(i.toLong(), primaryBuffer, width, height))
                if (res.accepted && res.status == RtcVideoFrameDeliveryStatus.ACCEPTED) startedAcceptedCount++
                if (primaryBuffer.isClosed) scopedBorrowOk = false
            }
            val startedAcceptPass = startedAcceptedCount == capacity && scopedBorrowOk

            // ---- Lane 4: queue saturation/backpressure ----
            val resBackpressure = adapter.ingestFrame(frame((capacity + 1).toLong(), primaryBuffer, width, height))
            val snapshotAfterBackpressure = sink.snapshot()
            val rawAfterBackpressure = snapshotAfterBackpressure["raw"] as? String ?: ""
            val backpressurePass = resBackpressure.status == RtcVideoFrameDeliveryStatus.DROPPED_BACKPRESSURE &&
                rawAfterBackpressure.contains("acceptedCount=$capacity;") &&
                rawAfterBackpressure.contains("lastAcceptedFrameIndex=$capacity;") &&
                rawAfterBackpressure.contains("queueSize=$capacity;")

            // ---- Lane 5: drain restores ingress (full drain, then refill to capacity) ----
            val drainResult = sink.drain(capacity)
            val drainedFully = (drainResult["raw"] as? String)?.contains("drained=$capacity;") == true

            var refillAcceptedCount = 0
            for (i in 1..capacity) {
                val idx = (capacity + 1 + i).toLong()
                val res = adapter.ingestFrame(frame(idx, primaryBuffer, width, height))
                if (res.accepted && res.status == RtcVideoFrameDeliveryStatus.ACCEPTED) refillAcceptedCount++
            }
            val drainRestoresIngressPass = drainedFully && refillAcceptedCount == capacity

            // ---- Lane 6: mismatched dimension rejected (checked before backpressure, so queue
            //      fullness is irrelevant) ----
            val mismatchedFrameIndex = (2L * capacity + 2L)
            val resMismatch = adapter.ingestFrame(
                frame(mismatchedFrameIndex, mismatchedBuffer, mismatchedWidth, mismatchedHeight),
            )
            val snapshotAfterMismatch = sink.snapshot()
            val rawAfterMismatch = snapshotAfterMismatch["raw"] as? String ?: ""
            val mismatchedDimensionPass = resMismatch.status == RtcVideoFrameDeliveryStatus.UNSUPPORTED_FORMAT &&
                rawAfterMismatch.contains("unsupportedFormatCount=1;") &&
                rawAfterMismatch.contains("acceptedCount=${2 * capacity};")

            // ---- Lane 7: pause/resume lifecycle ----
            val pauseResult = sink.pause()
            val pausePass = pauseResult["pass"] == true && pauseResult["state"] == "PAUSED"

            val resPaused = adapter.ingestFrame(frame((2L * capacity + 3L), primaryBuffer, width, height))
            val pauseIngestPass = resPaused.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY

            val resumeResult = sink.start()
            val resumePass = resumeResult["pass"] == true && resumeResult["state"] == "STARTED"

            sink.drain(capacity) // fully clear the queue so the resume-ingest below is unambiguously accepted
            val resResumeIngest = adapter.ingestFrame(frame((2L * capacity + 4L), primaryBuffer, width, height))
            val resumeIngestPass = resResumeIngest.accepted &&
                resResumeIngest.status == RtcVideoFrameDeliveryStatus.ACCEPTED

            val pauseResumeLifecyclePass = pausePass && pauseIngestPass && resumePass && resumeIngestPass

            // ---- Lane 8: scoped-borrow buffer remains open after ingest ----
            val scopedBorrowFinalPass = scopedBorrowOk && !primaryBuffer.isClosed && !mismatchedBuffer.isClosed

            // ---- Lane 9: idempotent close ----
            val finalSnapshot = sink.snapshot()
            val handle = sink.handle
            sink.close()
            sink.close() // Kotlin-level guard: must not throw, must not call native twice
            // Bypass the Kotlin guard to directly prove the native destroy contract's own
            // idempotent erase-once semantics: a second destroy of an already-erased handle
            // must return status=not_found, not crash or double-free.
            val nativeIdempotentDestroyPass =
                VanguardNativeBridge.destroyStreamSourceRtcIngestSession(handle) == "status=not_found"
            val postCloseResult = try {
                adapter.ingestFrame(frame((2L * capacity + 5L), primaryBuffer, width, height))
                true
            } catch (t: Throwable) {
                false
            }
            val idempotentClosePass = postCloseResult && nativeIdempotentDestroyPass

            // ---- Lane 10: proof boundary asserts no sdk/network/audio/product wiring ----
            val finalRaw = finalSnapshot["raw"] as? String ?: ""
            val proofBoundaryPass = NativeStreamSourceRtcVideoFrameSink.PROOF_BOUNDARY.contains("no_webrtc_livekit_sdk") &&
                NativeStreamSourceRtcVideoFrameSink.PROOF_BOUNDARY.contains("no_network_room_session") &&
                NativeStreamSourceRtcVideoFrameSink.PROOF_BOUNDARY.contains("no_audio") &&
                NativeStreamSourceRtcVideoFrameSink.PROOF_BOUNDARY.contains("no_product_app_editor_wiring") &&
                NativeStreamSourceRtcVideoFrameSink.PROOF_BOUNDARY.contains("no_hardware_buffer_ownership") &&
                finalRaw.contains("proofBoundary=${NativeStreamSourceRtcVideoFrameSink.PROOF_BOUNDARY}")

            val overallPass = createLifecyclePass &&
                preStartPass &&
                startedAcceptPass &&
                backpressurePass &&
                drainRestoresIngressPass &&
                mismatchedDimensionPass &&
                pauseResumeLifecyclePass &&
                scopedBorrowFinalPass &&
                idempotentClosePass &&
                proofBoundaryPass

            val rawStatus = if (overallPass) {
                "status=OK;capacity=$capacity;createLifecycle=true;preStart=true;startedAccept=true;" +
                    "backpressure=true;drainRestoresIngress=true;mismatchedDimension=true;" +
                    "pauseResumeLifecycle=true;scopedBorrow=true;idempotentClose=true;proofBoundary=true"
            } else {
                "status=SEAM_VERIFICATION_FAILED;capacity=$capacity;createLifecycle=$createLifecyclePass;" +
                    "preStart=$preStartPass;startedAccept=$startedAcceptPass;backpressure=$backpressurePass;" +
                    "drainRestoresIngress=$drainRestoresIngressPass;mismatchedDimension=$mismatchedDimensionPass;" +
                    "pauseResumeLifecycle=$pauseResumeLifecyclePass;scopedBorrow=$scopedBorrowFinalPass;" +
                    "idempotentClose=$idempotentClosePass;proofBoundary=$proofBoundaryPass"
            }

            return mapOf(
                "pass" to overallPass,
                "raw" to rawStatus,
                "capacity" to capacity,
                "createLifecyclePass" to createLifecyclePass,
                "preStartPass" to preStartPass,
                "startedAcceptPass" to startedAcceptPass,
                "backpressurePass" to backpressurePass,
                "drainRestoresIngressPass" to drainRestoresIngressPass,
                "mismatchedDimensionPass" to mismatchedDimensionPass,
                "pauseResumeLifecyclePass" to pauseResumeLifecyclePass,
                "scopedBorrowPass" to scopedBorrowFinalPass,
                "idempotentClosePass" to idempotentClosePass,
                "proofBoundaryPass" to proofBoundaryPass,
                "proofBoundary" to NativeStreamSourceRtcVideoFrameSink.PROOF_BOUNDARY,
            )
        } catch (t: Throwable) {
            return mapOf(
                "pass" to false,
                "raw" to "status=FAIL;reason=exception:${t.message}",
            )
        } finally {
            sink?.close()
            primaryBuffer?.close()
            mismatchedBuffer?.close()
        }
    }
}
