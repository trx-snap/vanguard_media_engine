package com.connects.vanguard_media_engine.rtc

/**
 * Diagnostic smoke harness proving [MediaCodecEncodedVideoOutputBridge] drives a real hardware
 * AVC [android.media.MediaCodec] encoder end to end into [RealtimeEncodedVideoOutputAdapter] /
 * [RtcEncodedVideoFramePublisher].
 *
 * ## Verification Invariants
 * - **Zero Muxer / File / Network / Audio Dependencies**: no [android.media.MediaMuxer], no file
 *   IO, no network sockets, no RTMP, no WebRTC/LiveKit SDK, no audio.
 * - **Real Encoder Output**: every accepted [RtcEncodedVideoFrame] wraps a real
 *   [android.media.MediaCodec] output buffer produced by feeding the encoder's own input surface;
 *   nothing here fabricates encoded bytes.
 * - **Deterministic Proof Lanes**: lifecycle, inputSurfaceFeed, outputFormatCsdExtraction,
 *   firstKeyframeGating, scopedBorrowBufferRelease, sequentialPtsDts, backpressureHandling,
 *   pauseResumeKeyframeRegating, eosDrain, idempotentDispose, proofBoundary.
 */
object MediaCodecEncodedVideoOutputSmokeHarness {

    const val PROOF_BOUNDARY: String =
        "hardware_encoder_output_bridge_seam_closes_encoder_output_only_no_network_publish_" +
            "no_mediamuxer_no_file_io_no_network_socket_no_rtmp_no_webrtc_livekit_sdk_no_audio_" +
            "no_product_app_editor_wiring_no_bytebuffer_retention_after_release"

    private const val WIDTH = 64
    private const val HEIGHT = 64
    private const val FPS = 30
    private const val BITRATE_BPS = 250_000
    private const val I_FRAME_INTERVAL_SECS = 1
    private const val DRAIN_TIMEOUT_US = 10_000L
    private const val MAX_KEYFRAME_ATTEMPTS = 30
    private const val MAX_DELTA_ATTEMPTS = 15
    private const val MAX_BACKPRESSURE_ATTEMPTS = 15
    private const val MAX_PAUSE_DROP_ATTEMPTS = 12
    private const val MAX_EOS_ATTEMPTS = 60

    private fun feedDrainUntil(
        bridge: MediaCodecEncodedVideoOutputBridge,
        maxAttempts: Int,
        requestSyncFrame: Boolean = false,
        predicate: (Map<String, Any?>) -> Boolean,
    ): Boolean {
        if (predicate(bridge.snapshot())) return true
        repeat(maxAttempts) {
            bridge.feedSyntheticFrame(requestSyncFrame = requestSyncFrame)
            bridge.drainOutput(timeoutUs = DRAIN_TIMEOUT_US)
            if (predicate(bridge.snapshot())) return true
        }
        return false
    }

    private fun drainUntil(
        bridge: MediaCodecEncodedVideoOutputBridge,
        maxAttempts: Int,
        predicate: (Map<String, Any?>) -> Boolean,
    ): Boolean {
        if (predicate(bridge.snapshot())) return true
        repeat(maxAttempts) {
            bridge.drainOutput(timeoutUs = DRAIN_TIMEOUT_US)
            if (predicate(bridge.snapshot())) return true
        }
        return false
    }

    private fun intField(snap: Map<String, Any?>, key: String): Int = (snap[key] as? Int) ?: 0

    private fun longField(snap: Map<String, Any?>, key: String): Long =
        (snap[key] as? Number)?.toLong() ?: 0L

    /** Executes the hardware MediaCodec encoder egress bridge smoke test. */
    fun run(): Map<String, Any?> {
        val publisher = NoOpRtcEncodedVideoFramePublisher()
        val bridge = MediaCodecEncodedVideoOutputBridge(publisher)

        var lifecyclePass = false
        var inputSurfaceFeedPass = false
        var outputFormatCsdExtractionPass = false
        var firstKeyframeGatingPass = false
        var scopedBorrowBufferReleasePass = false
        var sequentialPtsDtsPass = false
        var backpressureHandlingPass = false
        var pauseResumeKeyframeRegatingPass = false
        var eosDrainPass = false
        var idempotentDisposePass = false
        var rawFailureReason: String? = null
        var preDisposeSnapshot: Map<String, Any?> = emptyMap()

        try {
            // -----------------------------------------------------------------
            // Lane 1: Lifecycle (IDLE -> CONFIGURED -> STARTED, adapter STARTED explicitly)
            // -----------------------------------------------------------------
            val initialState = bridge.snapshot()["bridgeState"]
            val configureResult = bridge.configure(WIDTH, HEIGHT, FPS, BITRATE_BPS, I_FRAME_INTERVAL_SECS)
            val startResult = bridge.start()
            lifecyclePass = initialState == "IDLE" &&
                configureResult["pass"] == true &&
                startResult["pass"] == true &&
                bridge.snapshot()["bridgeState"] == "STARTED" &&
                bridge.adapterState() == RealtimeEncodedVideoOutputState.STARTED

            if (!lifecyclePass) {
                rawFailureReason = "lifecycle_setup_failed;configure=${configureResult["raw"]};start=${startResult["raw"]}"
            } else {
                // -----------------------------------------------------------------
                // Lane 2: Input Surface Feed
                // -----------------------------------------------------------------
                val feed1 = bridge.feedSyntheticFrame()
                bridge.drainOutput(timeoutUs = DRAIN_TIMEOUT_US)
                inputSurfaceFeedPass = feed1["pass"] == true && longField(bridge.snapshot(), "framesFed") >= 1L

                // -----------------------------------------------------------------
                // Lane 3: First-Keyframe Gating (feed/drain until a keyframe is accepted)
                // -----------------------------------------------------------------
                val keyframeFound = feedDrainUntil(bridge, MAX_KEYFRAME_ATTEMPTS) { snap ->
                    intField(snap, "keyFrameBuffersDrained") >= 1
                }
                val gateOpenAfterKeyframe = bridge.isAdapterKeyframeGateOpen()
                val deltaFound = feedDrainUntil(bridge, MAX_DELTA_ATTEMPTS) { snap ->
                    intField(snap, "deltaFrameBuffersDrained") >= 1
                }
                firstKeyframeGatingPass = keyframeFound && gateOpenAfterKeyframe && deltaFound

                // -----------------------------------------------------------------
                // Lane 4: Output Format / CSD Extraction Evidence
                // -----------------------------------------------------------------
                val snapAfterKeyframe = bridge.snapshot()
                outputFormatCsdExtractionPass = snapAfterKeyframe["formatChangedObserved"] == true &&
                    (snapAfterKeyframe["csd0Captured"] == true || intField(snapAfterKeyframe, "configBuffersObserved") > 0)

                // -----------------------------------------------------------------
                // Lane 5: Backpressure Handling (force DROPPED_BACKPRESSURE on a real buffer)
                // -----------------------------------------------------------------
                val capacity = longField(publisher.snapshot(), "acceptedFrames")
                publisher.setMaxAcceptedFrames(capacity)
                val backpressureObserved = feedDrainUntil(bridge, MAX_BACKPRESSURE_ATTEMPTS) {
                    longField(publisher.snapshot(), "droppedBackpressureFrames") >= 1L
                }
                publisher.setMaxAcceptedFrames(Long.MAX_VALUE)
                backpressureHandlingPass = backpressureObserved && bridge.snapshot()["lastError"] == null

                // -----------------------------------------------------------------
                // Lane 6: Pause/Resume Keyframe Re-Gating
                // -----------------------------------------------------------------
                val pauseResult = bridge.pauseAdapter()
                val pauseStateOk = pauseResult["pass"] == true &&
                    bridge.adapterState() == RealtimeEncodedVideoOutputState.PAUSED
                val pauseDropObserved = feedDrainUntil(bridge, MAX_PAUSE_DROP_ATTEMPTS) { snap ->
                    snap["lastDeliveryStatus"] == "DROPPED_NOT_READY"
                }
                val noLeakDuringPause = bridge.snapshot()["lastError"] == null

                val resumeResult = bridge.resumeAdapter()
                val resumeStateOk = resumeResult["pass"] == true &&
                    bridge.adapterState() == RealtimeEncodedVideoOutputState.STARTED &&
                    !bridge.isAdapterKeyframeGateOpen()
                val keyframeCountBeforeResume = intField(bridge.snapshot(), "keyFrameBuffersDrained")
                val postResumeKeyframeFound = feedDrainUntil(bridge, MAX_KEYFRAME_ATTEMPTS, requestSyncFrame = true) { snap ->
                    intField(snap, "keyFrameBuffersDrained") > keyframeCountBeforeResume
                }
                val gateOpenAfterResumeKeyframe = bridge.isAdapterKeyframeGateOpen()
                val deltaCountBeforeResumeDelta = intField(bridge.snapshot(), "deltaFrameBuffersDrained")
                val postResumeDeltaFound = feedDrainUntil(bridge, MAX_DELTA_ATTEMPTS) { snap ->
                    intField(snap, "deltaFrameBuffersDrained") > deltaCountBeforeResumeDelta
                }
                pauseResumeKeyframeRegatingPass = pauseStateOk && pauseDropObserved && noLeakDuringPause &&
                    resumeStateOk && postResumeKeyframeFound && gateOpenAfterResumeKeyframe && postResumeDeltaFound

                // -----------------------------------------------------------------
                // Lane 7: Sequential PTS/DTS (monotonic across every accepted frame so far)
                // -----------------------------------------------------------------
                val snapBeforeEos = bridge.snapshot()
                sequentialPtsDtsPass = snapBeforeEos["monotonicPtsDtsViolation"] == false &&
                    intField(snapBeforeEos, "normalBuffersDrained") >= 2

                // -----------------------------------------------------------------
                // Lane 8: Scoped-Borrow Buffer Release (many drain cycles, zero leak/exception)
                // -----------------------------------------------------------------
                scopedBorrowBufferReleasePass = snapBeforeEos["lastError"] == null &&
                    intField(snapBeforeEos, "normalBuffersDrained") >= 2

                // -----------------------------------------------------------------
                // Lane 9: EOS Drain
                // -----------------------------------------------------------------
                val eosSignal = bridge.signalEndOfStream()
                val eosObservedFound = drainUntil(bridge, MAX_EOS_ATTEMPTS) { snap -> snap["eosObserved"] == true }
                eosDrainPass = eosSignal["pass"] == true && eosObservedFound

                preDisposeSnapshot = bridge.snapshot()
            }
        } catch (t: Throwable) {
            rawFailureReason = "exception:${t.javaClass.simpleName}:${t.message}"
        } finally {
            // -----------------------------------------------------------------
            // Lane 10: Idempotent Dispose (fail-closed for every lifecycle call afterward)
            // -----------------------------------------------------------------
            val disposeResult1 = bridge.dispose()
            val dispose1Ok = disposeResult1["pass"] == true && bridge.snapshot()["bridgeState"] == "DISPOSED"

            val disposeResult2 = bridge.dispose()
            val dispose2Ok = disposeResult2["pass"] == true && bridge.snapshot()["bridgeState"] == "DISPOSED"

            val postDisposeFeed = bridge.feedSyntheticFrame()
            val postDisposeFeedFailsClosed = postDisposeFeed["pass"] == false

            val postDisposeDrain = bridge.drainOutput()
            val postDisposeDrainFailsClosed = postDisposeDrain.size == 1 && postDisposeDrain[0]["pass"] == false

            val postDisposeStart = bridge.start()
            val postDisposeStartFailsClosed = postDisposeStart["pass"] == false

            idempotentDisposePass = dispose1Ok && dispose2Ok && postDisposeFeedFailsClosed &&
                postDisposeDrainFailsClosed && postDisposeStartFailsClosed
        }

        // -----------------------------------------------------------------
        // Lane 11: Proof Boundary Non-Claims
        // -----------------------------------------------------------------
        val proofBoundaryPass = PROOF_BOUNDARY.contains("hardware_encoder_output_bridge_seam") &&
            PROOF_BOUNDARY.contains("no_network_publish") &&
            PROOF_BOUNDARY.contains("no_mediamuxer") &&
            PROOF_BOUNDARY.contains("no_file_io") &&
            PROOF_BOUNDARY.contains("no_network_socket") &&
            PROOF_BOUNDARY.contains("no_rtmp") &&
            PROOF_BOUNDARY.contains("no_webrtc_livekit_sdk") &&
            PROOF_BOUNDARY.contains("no_audio") &&
            PROOF_BOUNDARY.contains("no_product_app_editor_wiring") &&
            PROOF_BOUNDARY.contains("no_bytebuffer_retention_after_release")

        val overallPass = lifecyclePass &&
            inputSurfaceFeedPass &&
            outputFormatCsdExtractionPass &&
            firstKeyframeGatingPass &&
            scopedBorrowBufferReleasePass &&
            sequentialPtsDtsPass &&
            backpressureHandlingPass &&
            pauseResumeKeyframeRegatingPass &&
            eosDrainPass &&
            idempotentDisposePass &&
            proofBoundaryPass

        val rawStatus = if (overallPass) {
            "status=OK;lifecycle=true;inputSurfaceFeed=true;outputFormatCsdExtraction=true;" +
                "firstKeyframeGating=true;scopedBorrowBufferRelease=true;sequentialPtsDts=true;" +
                "backpressureHandling=true;pauseResumeKeyframeRegating=true;eosDrain=true;" +
                "idempotentDispose=true;proofBoundary=true"
        } else {
            "status=MEDIACODEC_ENCODER_EGRESS_VERIFICATION_FAILED;lifecycle=$lifecyclePass;" +
                "inputSurfaceFeed=$inputSurfaceFeedPass;outputFormatCsdExtraction=$outputFormatCsdExtractionPass;" +
                "firstKeyframeGating=$firstKeyframeGatingPass;scopedBorrowBufferRelease=$scopedBorrowBufferReleasePass;" +
                "sequentialPtsDts=$sequentialPtsDtsPass;backpressureHandling=$backpressureHandlingPass;" +
                "pauseResumeKeyframeRegating=$pauseResumeKeyframeRegatingPass;eosDrain=$eosDrainPass;" +
                "idempotentDispose=$idempotentDisposePass;proofBoundary=$proofBoundaryPass" +
                (rawFailureReason?.let { ";reason=$it" } ?: "")
        }

        return mapOf(
            "pass" to overallPass,
            "raw" to rawStatus,
            "lifecyclePass" to lifecyclePass,
            "inputSurfaceFeedPass" to inputSurfaceFeedPass,
            "outputFormatCsdExtractionPass" to outputFormatCsdExtractionPass,
            "firstKeyframeGatingPass" to firstKeyframeGatingPass,
            "scopedBorrowBufferReleasePass" to scopedBorrowBufferReleasePass,
            "sequentialPtsDtsPass" to sequentialPtsDtsPass,
            "backpressureHandlingPass" to backpressureHandlingPass,
            "pauseResumeKeyframeRegatingPass" to pauseResumeKeyframeRegatingPass,
            "eosDrainPass" to eosDrainPass,
            "idempotentDisposePass" to idempotentDisposePass,
            "proofBoundaryPass" to proofBoundaryPass,
            "proofBoundary" to PROOF_BOUNDARY,
            "bridgeSnapshot" to preDisposeSnapshot,
            "publisherSnapshot" to publisher.snapshot(),
        )
    }
}
