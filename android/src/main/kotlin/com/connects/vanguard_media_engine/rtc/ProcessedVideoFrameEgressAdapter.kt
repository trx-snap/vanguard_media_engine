package com.connects.vanguard_media_engine.rtc

import android.hardware.HardwareBuffer

/**
 * Adapts processed Vanguard True-DAG frames to the generic [RtcVideoFramePublisher] contract,
 * composing lifecycle, timestamp mapping, orientation normalization, and backpressure gating
 * into a single egress seam.
 *
 * ## Video-Only Domain Invariants
 * - **Video Only**: Operates strictly within the video egress domain. Zero ownership or awareness
 *   of room signaling, connection tokens, participant rosters, active speaker events, audio streams,
 *   or microphone resources. Room orchestration and audio capture/mixing are strictly forbidden.
 * - **No Buffer Retention or Closure**: Treats [HardwareBuffer] as a scoped-borrow only.
 *   This adapter does not retain, cache, copy, or close any caller-owned [HardwareBuffer] instance.
 *   Buffer lifecycle is owned exclusively by the producing pipeline (e.g., an upstream ImageReader
 *   pipeline or camera HAL). Consistent with the Android ImageReader documentation recommendation
 *   to use `acquireLatestImage` for realtime processing, unreleased images must not be held here.
 * - **Transport Agnostic**: Operates against the generic [RtcVideoFramePublisher] contract without
 *   any coupling to concrete WebRTC, LiveKit, or network transport implementations.
 * - **Thread-Safe**: All public lifecycle and frame-delivery methods are synchronized.
 *
 * ## Ownership & Composition
 * Internally composes:
 * - [RealtimeVideoOutputAdapter] — lifecycle and frame validation gate forwarding to [publisher].
 * - [RtcVideoTimestampMapper] — maps source PTS microseconds to strictly-monotonic nanoseconds.
 * - [RtcVideoBackpressureController] — bounds in-flight frame concurrency with [DROP_WHEN_BUSY] policy.
 *
 * @param publisher Downstream generic RTC video frame publisher destination.
 * @param maxInFlightFrames Maximum concurrent in-flight frames allowed (must be > 0).
 * @param sourceId Identifier for frames emitted by this adapter (must not be blank).
 */
class ProcessedVideoFrameEgressAdapter(
    publisher: RtcVideoFramePublisher,
    maxInFlightFrames: Int = 1,
    private val sourceId: String = "vanguard_processed_egress",
) {
    init {
        require(maxInFlightFrames > 0) {
            "ProcessedVideoFrameEgressAdapter: maxInFlightFrames must be > 0, got $maxInFlightFrames"
        }
        require(sourceId.isNotBlank()) {
            "ProcessedVideoFrameEgressAdapter: sourceId must not be blank"
        }
    }

    private val outputAdapter = RealtimeVideoOutputAdapter(publisher)
    private val timestampMapper = RtcVideoTimestampMapper()
    private val backpressureController = RtcVideoBackpressureController(
        maxInFlightFrames = maxInFlightFrames,
        mode = RtcVideoBackpressureMode.DROP_WHEN_BUSY,
    )

    // -------------------------------------------------------------------------
    // Lifecycle delegation
    // -------------------------------------------------------------------------

    /**
     * Starts the egress adapter, allowing frame delivery to proceed.
     *
     * Delegates to [RealtimeVideoOutputAdapter.start].
     */
    @Synchronized
    fun start(): Map<String, Any?> = outputAdapter.start()

    /**
     * Pauses the egress adapter; incoming frames are dropped as not-ready.
     *
     * Delegates to [RealtimeVideoOutputAdapter.pause].
     */
    @Synchronized
    fun pause(): Map<String, Any?> = outputAdapter.pause()

    /**
     * Resumes the egress adapter from paused or idle state.
     *
     * Delegates to [RealtimeVideoOutputAdapter.resume].
     */
    @Synchronized
    fun resume(): Map<String, Any?> = outputAdapter.resume()

    /**
     * Stops the egress adapter and returns it to idle; incoming frames are dropped as not-ready.
     *
     * Delegates to [RealtimeVideoOutputAdapter.stop].
     */
    @Synchronized
    fun stop(): Map<String, Any?> = outputAdapter.stop()

    /**
     * Transitions the egress adapter to [RealtimeVideoOutputState.FAILED], recording [reason].
     *
     * Delegates to [RealtimeVideoOutputAdapter.fail].
     */
    @Synchronized
    fun fail(reason: String): Map<String, Any?> = outputAdapter.fail(reason)

    /**
     * Permanently disposes the egress adapter to terminal [RealtimeVideoOutputState.DISPOSED].
     *
     * Delegates to [RealtimeVideoOutputAdapter.dispose].
     */
    @Synchronized
    fun dispose(): Map<String, Any?> = outputAdapter.dispose()

    // -------------------------------------------------------------------------
    // Frame delivery
    // -------------------------------------------------------------------------

    /**
     * Publishes a processed Vanguard DAG frame through the RTC egress pipeline.
     *
     * Processing order:
     * 1. [RealtimeVideoOutputAdapter.currentState] lifecycle gate — if not [RealtimeVideoOutputState.STARTED],
     *    immediately returns [RealtimeVideoOutputAdapter.dropNotReadyForCurrentState] without touching
     *    backpressure or timestamp machinery.
     * 2. [RtcVideoBackpressureController.tryAccept] gates in-flight concurrency; if the gate
     *    rejects the frame (backpressure drop), returns immediately without proceeding further.
     * 3. [RtcVideoOrientationPolicy.normalizeRotationDegrees] coerces [rotationDegrees] to a
     *    cardinal value (0, 90, 180, or 270).
     * 4. [RtcVideoTimestampMapper.mapPtsUs] converts [ptsUs] to a strictly-monotonic nanosecond
     *    timestamp for the [RealtimeVideoFrame] envelope.
     * 5. A [RealtimeVideoFrame] is constructed and forwarded to [RealtimeVideoOutputAdapter.publishFrame].
     * 6. [RtcVideoBackpressureController.markComplete] is called in a `finally` block to release
     *    the in-flight slot.
     *
     * This method does **not** retain, cache, copy, or close [hardwareBuffer]. The caller retains
     * full ownership and must close the buffer according to its own pipeline lifecycle.
     *
     * @param hardwareBuffer GPU-accessible [HardwareBuffer] under scoped-borrow semantics (caller-owned).
     * @param width Frame width in pixels (must be > 0).
     * @param height Frame height in pixels (must be > 0).
     * @param ptsUs Source video presentation timestamp in microseconds (must be >= 0).
     * @param rotationDegrees Raw display rotation in degrees; normalized to nearest cardinal.
     * @param mirrored Whether horizontal mirroring is required for display/publish semantics.
     * @param frameIndex Monotonically increasing frame sequence index (must be >= 0).
     * @return [RtcVideoFrameDeliveryResult] indicating acceptance, backpressure drop, or failure.
     */
    @Synchronized
    fun publishProcessedFrame(
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        ptsUs: Long,
        rotationDegrees: Int = 0,
        mirrored: Boolean = false,
        frameIndex: Long,
    ): RtcVideoFrameDeliveryResult {
        // 1. Lifecycle gate — must come first, before backpressure or timestamp work.
        //    IDLE/PAUSED/STOPPED/DISPOSED frames are pure not-ready drops; they must not
        //    mutate backpressure slots or timestamp telemetry.
        if (outputAdapter.currentState() != RealtimeVideoOutputState.STARTED) {
            return outputAdapter.dropNotReadyForCurrentState()
        }

        // 2. Backpressure gate — only reached when adapter is STARTED; markComplete only
        //    called if accepted.
        val gateResult = backpressureController.tryAccept(frameIndex)
        if (!gateResult.accepted) {
            return gateResult
        }

        // 3–6. Deliver through output adapter with in-flight slot held
        try {
            val normalizedRotation = RtcVideoOrientationPolicy.normalizeRotationDegrees(rotationDegrees)
            val timestampNs = timestampMapper.mapPtsUs(ptsUs)

            val frame = RealtimeVideoFrame(
                hardwareBuffer = hardwareBuffer,
                width = width,
                height = height,
                timestampNs = timestampNs,
                rotationDegrees = normalizedRotation,
                mirrored = mirrored,
                frameIndex = frameIndex,
                sourceId = sourceId,
            )

            return outputAdapter.publishFrame(frame)
        } finally {
            // Release the in-flight slot regardless of delivery outcome
            backpressureController.markComplete(frameIndex)
        }
    }

    // -------------------------------------------------------------------------
    // Telemetry
    // -------------------------------------------------------------------------

    /**
     * Returns an immutable snapshot map of current egress adapter telemetry, including
     * output adapter, timestamp mapper, and backpressure controller snapshots.
     */
    @Synchronized
    fun snapshot(): Map<String, Any?> = mapOf(
        "sourceId" to sourceId,
        "outputAdapter" to outputAdapter.snapshot(),
        "timestampMapper" to timestampMapper.snapshot(),
        "backpressure" to backpressureController.snapshot(),
    )
}
