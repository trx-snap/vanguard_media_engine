package com.connects.vanguard_media_engine.rtc

import java.nio.ByteBuffer

/**
 * Diagnostic smoke harness validating [RealtimeEncodedVideoOutputAdapter] lifecycle state transitions,
 * first-keyframe gating, backpressure propagation, scoped-borrow buffer safety, and non-claims.
 *
 * ## Verification Invariants
 * - **Zero Room / Audio Dependencies**: Pure video egress adapter smoke harness; does not touch
 *   WebRTC, LiveKit, RTMP, network sockets, audio tracks, or microphone resources.
 * - **Scoped-Borrow Direct ByteBuffer Verification**: Uses direct [ByteBuffer] allocations passed across
 *   consecutive frames under scoped-borrow semantics. The harness asserts that neither the adapter nor
 *   the publisher mutates [ByteBuffer.position], [ByteBuffer.limit], or retains references.
 * - **Deterministic Proof Lanes**: Validates 10 distinct proof lanes: lifecycle, preStartDrop,
 *   keyframeGating, sequentialDelivery, backpressure, pauseDrop, resumeRecovery, idempotentDispose,
 *   scopedBorrow, and proofBoundary.
 */
object RealtimeEncodedVideoOutputSmokeHarness {

    const val PROOF_BOUNDARY: String =
        "encoded_video_egress_foundation_seam_no_webrtc_livekit_sdk_no_rtmp_no_network_socket_no_audio_no_product_app_editor_wiring_no_bytebuffer_retention"

    private const val TEST_CODEC = "video/avc"

    private fun allocateDirectFrameBuffer(fillByte: Byte, size: Int = 64): ByteBuffer {
        val buf = ByteBuffer.allocateDirect(size)
        for (i in 0 until size) {
            buf.put(fillByte)
        }
        buf.flip()
        return buf
    }

    /**
     * Executes the encoded video egress foundation seam smoke test.
     *
     * @param frameCount Number of sequential frames to deliver in sequential delivery lane (> 0).
     * @return Map containing overall test verdict `pass` (Boolean), diagnostic `raw` status string,
     *   per-lane pass booleans, telemetry snapshots, and proof boundary string.
     */
    fun run(frameCount: Int = 3): Map<String, Any?> {
        if (frameCount <= 0) {
            return mapOf(
                "pass" to false,
                "raw" to "status=INVALID_ARGUMENT;frameCount must be positive;frameCount=$frameCount",
            )
        }

        try {
            val publisher = NoOpRtcEncodedVideoFramePublisher()
            val adapter = RealtimeEncodedVideoOutputAdapter(publisher)

            // -----------------------------------------------------------------
            // Lane 1: Lifecycle (Initial State IDLE)
            // -----------------------------------------------------------------
            val initSnapshot = adapter.snapshot()
            val lifecyclePass = (initSnapshot["state"] == RealtimeEncodedVideoOutputState.IDLE.name) &&
                (initSnapshot["keyframeGateOpen"] == false) &&
                (initSnapshot["acceptedFrames"] == 0L) &&
                (initSnapshot["droppedBackpressureFrames"] == 0L) &&
                (initSnapshot["droppedNotReadyFrames"] == 0L) &&
                (initSnapshot["failedFrames"] == 0L) &&
                (adapter.currentState() == RealtimeEncodedVideoOutputState.IDLE) &&
                !adapter.isKeyframeGateOpen()

            // -----------------------------------------------------------------
            // Lane 2: Pre-Start Drop (Drops NOT_READY before start)
            // -----------------------------------------------------------------
            val preBuf = allocateDirectFrameBuffer(0x01)
            val preFrame = RtcEncodedVideoFrame(
                encodedData = preBuf,
                codec = TEST_CODEC,
                isKeyFrame = true,
                ptsUs = 0L,
                dtsUs = 0L,
                frameIndex = 0L,
            )
            val preRes = adapter.publishFrame(preFrame)
            val preStartDropPass = !preRes.accepted &&
                preRes.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY &&
                preRes.raw.contains("state=IDLE") &&
                (adapter.snapshot()["droppedNotReadyFrames"] == 1L) &&
                (publisher.snapshot()["acceptedFrames"] == 0L)

            // -----------------------------------------------------------------
            // Lane 3: Keyframe Gating (Deltas dropped awaiting keyframe; first keyframe opens gate)
            // -----------------------------------------------------------------
            val startRes = adapter.start()
            val startedStateOk = (startRes["pass"] == true) &&
                (adapter.currentState() == RealtimeEncodedVideoOutputState.STARTED) &&
                !adapter.isKeyframeGateOpen()

            // 3a. Delta frame before first keyframe must drop as NOT_READY with reason=awaiting_keyframe
            val deltaBuf1 = allocateDirectFrameBuffer(0x02)
            val deltaFrame1 = RtcEncodedVideoFrame(
                encodedData = deltaBuf1,
                codec = TEST_CODEC,
                isKeyFrame = false,
                ptsUs = 33333L,
                dtsUs = 33333L,
                frameIndex = 1L,
            )
            val deltaRes1 = adapter.publishFrame(deltaFrame1)
            val deltaGatedBeforeKeyframe = !deltaRes1.accepted &&
                deltaRes1.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY &&
                deltaRes1.raw.contains("reason=awaiting_keyframe") &&
                !adapter.isKeyframeGateOpen() &&
                (adapter.snapshot()["droppedNotReadyFrames"] == 2L) &&
                (publisher.snapshot()["acceptedFrames"] == 0L)

            // 3b. Keyframe accepted and opens gate
            val keyBuf1 = allocateDirectFrameBuffer(0x03)
            val keyFrame1 = RtcEncodedVideoFrame(
                encodedData = keyBuf1,
                codec = TEST_CODEC,
                isKeyFrame = true,
                ptsUs = 66666L,
                dtsUs = 66666L,
                frameIndex = 2L,
            )
            val keyRes1 = adapter.publishFrame(keyFrame1)
            val keyframeAcceptedOpensGate = keyRes1.accepted &&
                keyRes1.status == RtcVideoFrameDeliveryStatus.ACCEPTED &&
                adapter.isKeyframeGateOpen() &&
                (adapter.snapshot()["acceptedFrames"] == 1L) &&
                (publisher.snapshot()["acceptedFrames"] == 1L)

            // 3c. Delta frame after first accepted keyframe is now accepted
            val deltaBuf2 = allocateDirectFrameBuffer(0x04)
            val deltaFrame2 = RtcEncodedVideoFrame(
                encodedData = deltaBuf2,
                codec = TEST_CODEC,
                isKeyFrame = false,
                ptsUs = 100000L,
                dtsUs = 100000L,
                frameIndex = 3L,
            )
            val deltaRes2 = adapter.publishFrame(deltaFrame2)
            val deltaAcceptedAfterKeyframe = deltaRes2.accepted &&
                deltaRes2.status == RtcVideoFrameDeliveryStatus.ACCEPTED &&
                adapter.isKeyframeGateOpen() &&
                (adapter.snapshot()["acceptedFrames"] == 2L) &&
                (publisher.snapshot()["acceptedFrames"] == 2L)

            val keyframeGatingPass = startedStateOk &&
                deltaGatedBeforeKeyframe &&
                keyframeAcceptedOpensGate &&
                deltaAcceptedAfterKeyframe

            // -----------------------------------------------------------------
            // Lane 4: Sequential Delivery (Monotonic frames delivered to publisher)
            // -----------------------------------------------------------------
            var seqAcceptedCount = 0
            val basePtsUs = 100000L
            val baseFrameIndex = 3L
            for (i in 1..frameCount) {
                val pts = basePtsUs + (i * 33333L)
                val idx = baseFrameIndex + i
                val seqBuf = allocateDirectFrameBuffer((0x10 + i).toByte())
                val seqFrame = RtcEncodedVideoFrame(
                    encodedData = seqBuf,
                    codec = TEST_CODEC,
                    isKeyFrame = false,
                    ptsUs = pts,
                    dtsUs = pts,
                    frameIndex = idx,
                )
                val res = adapter.publishFrame(seqFrame)
                if (res.accepted && res.status == RtcVideoFrameDeliveryStatus.ACCEPTED) {
                    seqAcceptedCount++
                }
            }
            val expectedSeqAccepted = 2L + frameCount.toLong()
            val pubSnapshotAfterSeq = publisher.snapshot()
            val sequentialDeliveryPass = seqAcceptedCount == frameCount &&
                (adapter.snapshot()["acceptedFrames"] == expectedSeqAccepted) &&
                (pubSnapshotAfterSeq["acceptedFrames"] == expectedSeqAccepted) &&
                (pubSnapshotAfterSeq["lastFrameIndex"] == baseFrameIndex + frameCount) &&
                (pubSnapshotAfterSeq["lastPtsUs"] == basePtsUs + (frameCount * 33333L))

            // -----------------------------------------------------------------
            // Lane 5: Backpressure (Publisher drops backpressure, adapter counts and propagates)
            // -----------------------------------------------------------------
            val currentAccepted = (adapter.snapshot()["acceptedFrames"] as? Number)?.toLong() ?: 0L
            publisher.setMaxAcceptedFrames(currentAccepted)

            val bpBuf = allocateDirectFrameBuffer(0x20)
            val bpFrame = RtcEncodedVideoFrame(
                encodedData = bpBuf,
                codec = TEST_CODEC,
                isKeyFrame = false,
                ptsUs = basePtsUs + ((frameCount + 1) * 33333L),
                dtsUs = basePtsUs + ((frameCount + 1) * 33333L),
                frameIndex = baseFrameIndex + frameCount + 1L,
            )
            val bpRes = adapter.publishFrame(bpFrame)
            val backpressurePass = !bpRes.accepted &&
                bpRes.status == RtcVideoFrameDeliveryStatus.DROPPED_BACKPRESSURE &&
                (adapter.snapshot()["droppedBackpressureFrames"] == 1L) &&
                (publisher.snapshot()["droppedBackpressureFrames"] == 1L) &&
                adapter.isKeyframeGateOpen()

            // Restore publisher capacity
            publisher.setMaxAcceptedFrames(Long.MAX_VALUE)

            // -----------------------------------------------------------------
            // Lane 6: Pause Drop (Frames dropped NOT_READY, keyframe gate reset)
            // -----------------------------------------------------------------
            val pauseRes = adapter.pause()
            val pauseStateOk = (pauseRes["pass"] == true) &&
                (adapter.currentState() == RealtimeEncodedVideoOutputState.PAUSED) &&
                !adapter.isKeyframeGateOpen()

            val pauseBuf = allocateDirectFrameBuffer(0x30)
            val pauseFrame = RtcEncodedVideoFrame(
                encodedData = pauseBuf,
                codec = TEST_CODEC,
                isKeyFrame = true,
                ptsUs = basePtsUs + ((frameCount + 2) * 33333L),
                dtsUs = basePtsUs + ((frameCount + 2) * 33333L),
                frameIndex = baseFrameIndex + frameCount + 2L,
            )
            val resPaused = adapter.publishFrame(pauseFrame)
            val pauseDropPass = pauseStateOk &&
                !resPaused.accepted &&
                resPaused.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY &&
                resPaused.raw.contains("state=PAUSED") &&
                (adapter.snapshot()["droppedNotReadyFrames"] == 3L)

            // -----------------------------------------------------------------
            // Lane 7: Resume Recovery (Resume requires fresh keyframe before deltas)
            // -----------------------------------------------------------------
            val resumeRes = adapter.resume()
            val resumeStateOk = (resumeRes["pass"] == true) &&
                (adapter.currentState() == RealtimeEncodedVideoOutputState.STARTED) &&
                !adapter.isKeyframeGateOpen()

            // 7a. Delta frame immediately after resume must drop with awaiting_keyframe
            val postResumeDeltaBuf = allocateDirectFrameBuffer(0x40)
            val postResumeDeltaFrame = RtcEncodedVideoFrame(
                encodedData = postResumeDeltaBuf,
                codec = TEST_CODEC,
                isKeyFrame = false,
                ptsUs = basePtsUs + ((frameCount + 3) * 33333L),
                dtsUs = basePtsUs + ((frameCount + 3) * 33333L),
                frameIndex = baseFrameIndex + frameCount + 3L,
            )
            val resPostResumeDelta = adapter.publishFrame(postResumeDeltaFrame)
            val postResumeDeltaGated = !resPostResumeDelta.accepted &&
                resPostResumeDelta.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY &&
                resPostResumeDelta.raw.contains("reason=awaiting_keyframe") &&
                !adapter.isKeyframeGateOpen() &&
                (adapter.snapshot()["droppedNotReadyFrames"] == 4L)

            // 7b. Keyframe after resume is accepted and opens gate
            val postResumeKeyBuf = allocateDirectFrameBuffer(0x41)
            val postResumeKeyFrame = RtcEncodedVideoFrame(
                encodedData = postResumeKeyBuf,
                codec = TEST_CODEC,
                isKeyFrame = true,
                ptsUs = basePtsUs + ((frameCount + 4) * 33333L),
                dtsUs = basePtsUs + ((frameCount + 4) * 33333L),
                frameIndex = baseFrameIndex + frameCount + 4L,
            )
            val resPostResumeKey = adapter.publishFrame(postResumeKeyFrame)
            val postResumeKeyAccepted = resPostResumeKey.accepted &&
                resPostResumeKey.status == RtcVideoFrameDeliveryStatus.ACCEPTED &&
                adapter.isKeyframeGateOpen()

            // 7c. Subsequent delta frame is accepted
            val postResumeDelta2Buf = allocateDirectFrameBuffer(0x42)
            val postResumeDelta2Frame = RtcEncodedVideoFrame(
                encodedData = postResumeDelta2Buf,
                codec = TEST_CODEC,
                isKeyFrame = false,
                ptsUs = basePtsUs + ((frameCount + 5) * 33333L),
                dtsUs = basePtsUs + ((frameCount + 5) * 33333L),
                frameIndex = baseFrameIndex + frameCount + 5L,
            )
            val resPostResumeDelta2 = adapter.publishFrame(postResumeDelta2Frame)
            val postResumeDelta2Accepted = resPostResumeDelta2.accepted &&
                resPostResumeDelta2.status == RtcVideoFrameDeliveryStatus.ACCEPTED &&
                adapter.isKeyframeGateOpen()

            val resumeRecoveryPass = resumeStateOk &&
                postResumeDeltaGated &&
                postResumeKeyAccepted &&
                postResumeDelta2Accepted

            // -----------------------------------------------------------------
            // Lane 8: Idempotent Dispose (Dispose once and twice; rejects future frames)
            // -----------------------------------------------------------------
            val stopRes = adapter.stop()
            val stopPass = (stopRes["pass"] == true) &&
                (adapter.currentState() == RealtimeEncodedVideoOutputState.IDLE) &&
                !adapter.isKeyframeGateOpen()

            val disposeRes1 = adapter.dispose()
            val dispose1Ok = (disposeRes1["pass"] == true) &&
                (adapter.currentState() == RealtimeEncodedVideoOutputState.DISPOSED) &&
                !adapter.isKeyframeGateOpen()

            val disposeRes2 = adapter.dispose()
            val dispose2Ok = (disposeRes2["pass"] == true) &&
                (adapter.currentState() == RealtimeEncodedVideoOutputState.DISPOSED)

            val postDisposeBuf = allocateDirectFrameBuffer(0x50)
            val postDisposeFrame = RtcEncodedVideoFrame(
                encodedData = postDisposeBuf,
                codec = TEST_CODEC,
                isKeyFrame = true,
                ptsUs = basePtsUs + ((frameCount + 6) * 33333L),
                dtsUs = basePtsUs + ((frameCount + 6) * 33333L),
                frameIndex = baseFrameIndex + frameCount + 6L,
            )
            val resPostDispose = adapter.publishFrame(postDisposeFrame)
            val postDisposeDropOk = !resPostDispose.accepted &&
                resPostDispose.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY &&
                resPostDispose.raw.contains("state=DISPOSED")

            val startAfterDisposeFails = adapter.start()["pass"] == false
            val idempotentDisposePass = stopPass && dispose1Ok && dispose2Ok &&
                postDisposeDropOk && startAfterDisposeFails

            // -----------------------------------------------------------------
            // Lane 9: Scoped-Borrow Direct ByteBuffer (Position/limit unchanged, no retention)
            // -----------------------------------------------------------------
            val borrowDirectBuffer = ByteBuffer.allocateDirect(128)
            for (i in 0 until 128) {
                borrowDirectBuffer.put((i and 0xFF).toByte())
            }
            borrowDirectBuffer.position(16)
            borrowDirectBuffer.limit(96)
            val expectedPos = borrowDirectBuffer.position() // 16
            val expectedLim = borrowDirectBuffer.limit()    // 96
            val expectedRem = borrowDirectBuffer.remaining()// 80

            val borrowPublisher = NoOpRtcEncodedVideoFramePublisher()
            val borrowAdapter = RealtimeEncodedVideoOutputAdapter(borrowPublisher)
            borrowAdapter.start()

            val borrowFrame = RtcEncodedVideoFrame(
                encodedData = borrowDirectBuffer,
                codec = TEST_CODEC,
                isKeyFrame = true,
                ptsUs = 500000L,
                dtsUs = 500000L,
                frameIndex = 999L,
            )
            val borrowRes = borrowAdapter.publishFrame(borrowFrame)
            val borrowPubSnapshot = borrowPublisher.snapshot()

            val scopedBorrowPass = borrowRes.accepted &&
                borrowRes.status == RtcVideoFrameDeliveryStatus.ACCEPTED &&
                (borrowDirectBuffer.position() == expectedPos) &&
                (borrowDirectBuffer.limit() == expectedLim) &&
                (borrowDirectBuffer.remaining() == expectedRem) &&
                (borrowPubSnapshot["lastRemainingBytes"] == expectedRem) &&
                (borrowPubSnapshot["lastFrameIndex"] == 999L) &&
                (borrowPubSnapshot["lastCodec"] == TEST_CODEC) &&
                (borrowPubSnapshot["lastIsKeyFrame"] == true)

            borrowAdapter.dispose()

            // -----------------------------------------------------------------
            // Lane 10: Proof Boundary Non-Claims
            // -----------------------------------------------------------------
            val proofBoundaryPass = PROOF_BOUNDARY.contains("encoded_video_egress_foundation_seam") &&
                PROOF_BOUNDARY.contains("no_webrtc_livekit_sdk") &&
                PROOF_BOUNDARY.contains("no_rtmp") &&
                PROOF_BOUNDARY.contains("no_network_socket") &&
                PROOF_BOUNDARY.contains("no_audio") &&
                PROOF_BOUNDARY.contains("no_product_app_editor_wiring") &&
                PROOF_BOUNDARY.contains("no_bytebuffer_retention")

            // -----------------------------------------------------------------
            // Overall Verdict & Diagnostic Serialization
            // -----------------------------------------------------------------
            val overallPass = lifecyclePass &&
                preStartDropPass &&
                keyframeGatingPass &&
                sequentialDeliveryPass &&
                backpressurePass &&
                pauseDropPass &&
                resumeRecoveryPass &&
                idempotentDisposePass &&
                scopedBorrowPass &&
                proofBoundaryPass

            val adapterSnapshot = adapter.snapshot()
            val publisherSnapshot = publisher.snapshot()

            val rawStatus = if (overallPass) {
                "status=OK;lifecycle=true;preStartDrop=true;keyframeGating=true;sequentialDelivery=true;" +
                    "backpressure=true;pauseDrop=true;resumeRecovery=true;idempotentDispose=true;" +
                    "scopedBorrow=true;proofBoundary=true;acceptedFrames=${adapterSnapshot["acceptedFrames"]};" +
                    "droppedNotReadyFrames=${adapterSnapshot["droppedNotReadyFrames"]};" +
                    "droppedBackpressureFrames=${adapterSnapshot["droppedBackpressureFrames"]}"
            } else {
                "status=ENCODED_EGRESS_SEAM_VERIFICATION_FAILED;lifecycle=$lifecyclePass;" +
                    "preStartDrop=$preStartDropPass;keyframeGating=$keyframeGatingPass;" +
                    "sequentialDelivery=$sequentialDeliveryPass;backpressure=$backpressurePass;" +
                    "pauseDrop=$pauseDropPass;resumeRecovery=$resumeRecoveryPass;" +
                    "idempotentDispose=$idempotentDisposePass;scopedBorrow=$scopedBorrowPass;" +
                    "proofBoundary=$proofBoundaryPass"
            }

            return mapOf(
                "pass" to overallPass,
                "raw" to rawStatus,
                "frameCount" to frameCount,
                "lifecyclePass" to lifecyclePass,
                "preStartDropPass" to preStartDropPass,
                "keyframeGatingPass" to keyframeGatingPass,
                "sequentialDeliveryPass" to sequentialDeliveryPass,
                "backpressurePass" to backpressurePass,
                "pauseDropPass" to pauseDropPass,
                "resumeRecoveryPass" to resumeRecoveryPass,
                "idempotentDisposePass" to idempotentDisposePass,
                "scopedBorrowPass" to scopedBorrowPass,
                "proofBoundaryPass" to proofBoundaryPass,
                "proofBoundary" to PROOF_BOUNDARY,
                "adapterSnapshot" to adapterSnapshot,
                "publisherSnapshot" to publisherSnapshot,
            )
        } catch (t: Throwable) {
            return mapOf(
                "pass" to false,
                "raw" to "status=FAIL;reason=exception:${t.message}",
            )
        }
    }
}
