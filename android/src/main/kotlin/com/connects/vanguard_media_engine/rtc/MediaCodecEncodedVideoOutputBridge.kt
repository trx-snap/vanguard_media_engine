package com.connects.vanguard_media_engine.rtc

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Bundle
import android.util.Log
import android.view.Surface

/**
 * Bounded diagnostic bridge owning exactly one hardware AVC [MediaCodec] encoder instance and
 * its input [Surface], feeding real encoded output buffers into the existing transport-neutral
 * [RealtimeEncodedVideoOutputAdapter] / [RtcEncodedVideoFramePublisher] seam.
 *
 * ## Scope Boundary (P6-STREAM-EGRESS-HW-ENCODER-BRIDGE-A)
 * - Closes only the package hardware-encoder-output seam: real [MediaCodec] output buffers are
 *   wrapped as [RtcEncodedVideoFrame] and delivered through [adapter]. It does not close network
 *   publish.
 * - No [android.media.MediaMuxer], no file IO, no network sockets, no RTMP, no WebRTC/LiveKit SDK,
 *   no audio, and no ConnectsApp/app/editor wiring.
 * - Synthetic frame content is produced locally via [Surface.lockHardwareCanvas]/
 *   [Surface.unlockCanvasAndPost] directly on the encoder's own input surface -- no GLES/EGL
 *   context, no external decoder.
 *
 * ## Lifecycle
 * [BridgeState.IDLE] -> [configure] -> [BridgeState.CONFIGURED] -> [start] (explicitly starts both
 * [adapter] and the [MediaCodec] instance) -> [BridgeState.STARTED] -> [dispose] ->
 * [BridgeState.DISPOSED]. [dispose] is idempotent and stops/releases the codec and surface exactly
 * once; every lifecycle method fails closed (`pass=false`) once [BridgeState.DISPOSED] is reached.
 *
 * ## Scoped-Borrow Buffer Discipline
 * [drainOutput] sets the dequeued [java.nio.ByteBuffer]'s position/limit to the buffer info
 * offset/size, constructs an [RtcEncodedVideoFrame] around it, calls [RealtimeEncodedVideoOutputAdapter.publishFrame]
 * synchronously, and always calls `releaseOutputBuffer(index, false)` in a `finally` block. The
 * dequeued buffer reference is never stored on this instance beyond that scope.
 */
class MediaCodecEncodedVideoOutputBridge(
    publisher: RtcEncodedVideoFramePublisher,
) {
    enum class BridgeState { IDLE, CONFIGURED, STARTED, DISPOSED }

    companion object {
        private const val TAG = "MediaCodecEgressBridge"
        private val CODEC_MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val DEFAULT_DEQUEUE_TIMEOUT_US = 10_000L
        private const val DEFAULT_MAX_DRAIN_ITERATIONS = 32
    }

    /** The transport-neutral encoded video output adapter this bridge feeds. */
    val adapter: RealtimeEncodedVideoOutputAdapter = RealtimeEncodedVideoOutputAdapter(publisher)

    private var state: BridgeState = BridgeState.IDLE
    private var codec: MediaCodec? = null
    private var inputSurface: Surface? = null

    private var width: Int = 0
    private var height: Int = 0
    private var fps: Int = 0

    private var framesFed: Long = 0L
    private var nextFrameIndex: Long = 0L

    private var formatChangedObserved = false
    private var csd0Captured = false
    private var csd1Captured = false
    private var configBuffersObserved = 0
    private var normalBuffersDrained = 0
    private var keyFrameBuffersDrained = 0
    private var deltaFrameBuffersDrained = 0
    private var eosObserved = false
    private var lastPublishedPtsUs: Long = -1L
    private var lastPublishedDtsUs: Long = -1L
    private var monotonicPtsDtsViolation = false
    private var lastDeliveryStatus: String? = null
    private var disposeCount = 0
    private var lastError: String? = null

    /** Builds the [MediaFormat.MIMETYPE_VIDEO_AVC] surface-input encoder and its input [Surface]. */
    fun configure(width: Int, height: Int, fps: Int, bitrateBps: Int, iFrameIntervalSecs: Int): Map<String, Any?> {
        if (state != BridgeState.IDLE) {
            return failClosed("configure")
        }
        return try {
            this.width = width
            this.height = height
            this.fps = fps
            val format = MediaFormat.createVideoFormat(CODEC_MIME, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, iFrameIntervalSecs)
            }
            val enc = MediaCodec.createEncoderByType(CODEC_MIME)
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = enc.createInputSurface()
            codec = enc
            inputSurface = surface
            state = BridgeState.CONFIGURED
            mapOf(
                "pass" to true,
                "state" to state.name,
                "raw" to "status=CONFIGURED;width=$width;height=$height;fps=$fps;bitrateBps=$bitrateBps",
            )
        } catch (t: Throwable) {
            lastError = "configure_exception:${t.message}"
            mapOf("pass" to false, "state" to state.name, "raw" to "status=FAILED;reason=$lastError")
        }
    }

    /**
     * Explicitly starts both [adapter] and the underlying [MediaCodec] instance. Idempotent once
     * already [BridgeState.STARTED].
     */
    fun start(): Map<String, Any?> {
        if (state == BridgeState.STARTED) {
            return mapOf("pass" to true, "state" to state.name, "raw" to "status=STARTED;idempotent=true")
        }
        if (state != BridgeState.CONFIGURED) {
            return failClosed("start")
        }
        return try {
            val adapterResult = adapter.start()
            codec!!.start()
            state = BridgeState.STARTED
            mapOf(
                "pass" to (adapterResult["pass"] == true),
                "state" to state.name,
                "adapter" to adapterResult,
                "raw" to "status=STARTED",
            )
        } catch (t: Throwable) {
            lastError = "start_exception:${t.message}"
            mapOf("pass" to false, "state" to state.name, "raw" to "status=FAILED;reason=$lastError")
        }
    }

    /** Draws one deterministic synthetic frame onto the encoder's input surface. */
    fun feedSyntheticFrame(requestSyncFrame: Boolean = false): Map<String, Any?> {
        if (state != BridgeState.STARTED) {
            return failClosed("feedSyntheticFrame")
        }
        val enc = codec ?: return failClosed("feedSyntheticFrame")
        val surface = inputSurface ?: return failClosed("feedSyntheticFrame")
        return try {
            if (requestSyncFrame) {
                try {
                    val params = Bundle()
                    params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                    enc.setParameters(params)
                } catch (t: Throwable) {
                    Log.w(TAG, "feedSyntheticFrame: PARAMETER_KEY_REQUEST_SYNC_FRAME unsupported: $t")
                }
            }
            val canvas: Canvas = try {
                surface.lockHardwareCanvas()
            } catch (t: Throwable) {
                surface.lockCanvas(null)
            }
            val paint = Paint().apply {
                color = when ((framesFed % 4L).toInt()) {
                    0 -> Color.rgb(220, 40, 40)
                    1 -> Color.rgb(40, 200, 40)
                    2 -> Color.rgb(40, 60, 220)
                    else -> Color.rgb(230, 220, 40)
                }
            }
            canvas.drawColor(Color.BLACK)
            canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
            surface.unlockCanvasAndPost(canvas)
            framesFed++
            mapOf("pass" to true, "raw" to "status=FED;framesFed=$framesFed;requestSyncFrame=$requestSyncFrame")
        } catch (t: Throwable) {
            lastError = "feed_exception:${t.message}"
            mapOf("pass" to false, "raw" to "status=FAILED;reason=$lastError")
        }
    }

    /**
     * Drains currently available encoder output. Handles [MediaCodec.INFO_OUTPUT_FORMAT_CHANGED],
     * [MediaCodec.INFO_TRY_AGAIN_LATER], [MediaCodec.BUFFER_FLAG_CODEC_CONFIG], normal output,
     * key-frame flags, and end-of-stream. Codec-config-only buffers are recorded as CSD evidence
     * but never published as [RtcEncodedVideoFrame]s. Every dequeued buffer is released exactly
     * once in a `finally` block regardless of delivery outcome.
     */
    fun drainOutput(
        timeoutUs: Long = DEFAULT_DEQUEUE_TIMEOUT_US,
        maxIterations: Int = DEFAULT_MAX_DRAIN_ITERATIONS,
    ): List<Map<String, Any?>> {
        if (state != BridgeState.STARTED) {
            return listOf(failClosed("drainOutput"))
        }
        val enc = codec ?: return listOf(failClosed("drainOutput"))
        val events = mutableListOf<Map<String, Any?>>()
        val info = MediaCodec.BufferInfo()
        var iterations = 0
        while (iterations < maxIterations) {
            iterations++
            val outIdx = try {
                enc.dequeueOutputBuffer(info, timeoutUs)
            } catch (t: Throwable) {
                lastError = "dequeue_exception:${t.message}"
                events.add(mapOf("event" to "DEQUEUE_EXCEPTION", "reason" to lastError))
                break
            }
            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    events.add(mapOf("event" to "TRY_AGAIN_LATER"))
                    break
                }
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    formatChangedObserved = true
                    val fmt = enc.outputFormat
                    val hasCsd0 = fmt.containsKey("csd-0")
                    val hasCsd1 = fmt.containsKey("csd-1")
                    if (hasCsd0) csd0Captured = true
                    if (hasCsd1) csd1Captured = true
                    events.add(
                        mapOf(
                            "event" to "FORMAT_CHANGED",
                            "mime" to fmt.getString(MediaFormat.KEY_MIME),
                            "hasCsd0" to hasCsd0,
                            "hasCsd1" to hasCsd1,
                        ),
                    )
                }
                outIdx >= 0 -> {
                    var deliveryStatus: String? = null
                    var isKeyFrame = false
                    var publishedFrameIndex: Long? = null
                    var ptsUs: Long? = null
                    var isEos = false
                    try {
                        val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                        isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        isKeyFrame = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0

                        if (isConfig) {
                            configBuffersObserved++
                            if (info.size > 0) csd0Captured = true
                        } else if (info.size > 0) {
                            val buf = enc.getOutputBuffer(outIdx)
                            if (buf != null) {
                                buf.position(info.offset)
                                buf.limit(info.offset + info.size)
                                val frameIdx = nextFrameIndex
                                val pts = info.presentationTimeUs.coerceAtLeast(0L)
                                val frame = RtcEncodedVideoFrame(
                                    encodedData = buf,
                                    codec = CODEC_MIME,
                                    isKeyFrame = isKeyFrame,
                                    ptsUs = pts,
                                    dtsUs = pts,
                                    frameIndex = frameIdx,
                                )
                                val result = adapter.publishFrame(frame)
                                deliveryStatus = result.status.name
                                lastDeliveryStatus = deliveryStatus
                                if (result.accepted) {
                                    nextFrameIndex++
                                    normalBuffersDrained++
                                    publishedFrameIndex = frameIdx
                                    ptsUs = pts
                                    if (isKeyFrame) keyFrameBuffersDrained++ else deltaFrameBuffersDrained++
                                    if (lastPublishedPtsUs >= 0L &&
                                        (pts <= lastPublishedPtsUs || pts <= lastPublishedDtsUs)
                                    ) {
                                        monotonicPtsDtsViolation = true
                                    }
                                    lastPublishedPtsUs = pts
                                    lastPublishedDtsUs = pts
                                }
                            }
                        }
                    } finally {
                        try {
                            enc.releaseOutputBuffer(outIdx, false)
                        } catch (t: Throwable) {
                            lastError = "release_exception:${t.message}"
                        }
                    }
                    if (isEos) eosObserved = true
                    events.add(
                        mapOf(
                            "event" to "FRAME",
                            "isKeyFrame" to isKeyFrame,
                            "deliveryStatus" to deliveryStatus,
                            "frameIndex" to publishedFrameIndex,
                            "ptsUs" to ptsUs,
                            "isEos" to isEos,
                        ),
                    )
                    if (isEos) break
                }
                else -> {
                    // Ignore other negative MediaCodec.INFO_* codes (e.g. the deprecated
                    // INFO_OUTPUT_BUFFERS_CHANGED); nothing to drain this iteration.
                }
            }
        }
        return events
    }

    /** Signals end-of-stream to the encoder's input surface. */
    fun signalEndOfStream(): Map<String, Any?> {
        if (state != BridgeState.STARTED) {
            return failClosed("signalEndOfStream")
        }
        return try {
            codec!!.signalEndOfInputStream()
            mapOf("pass" to true, "raw" to "status=EOS_SIGNALED")
        } catch (t: Throwable) {
            lastError = "eos_exception:${t.message}"
            mapOf("pass" to false, "raw" to "status=FAILED;reason=$lastError")
        }
    }

    /** Passthrough to [RealtimeEncodedVideoOutputAdapter.pause] for the pause/resume proof lane. */
    fun pauseAdapter(): Map<String, Any?> = adapter.pause()

    /** Passthrough to [RealtimeEncodedVideoOutputAdapter.resume] for the pause/resume proof lane. */
    fun resumeAdapter(): Map<String, Any?> = adapter.resume()

    /** Returns the adapter's current lifecycle state. */
    fun adapterState(): RealtimeEncodedVideoOutputState = adapter.currentState()

    /** Returns whether the adapter's first-keyframe gate is currently open. */
    fun isAdapterKeyframeGateOpen(): Boolean = adapter.isKeyframeGateOpen()

    /** Immutable snapshot of bridge lifecycle state, drain counters, and last diagnostic error. */
    fun snapshot(): Map<String, Any?> = mapOf(
        "bridgeState" to state.name,
        "width" to width,
        "height" to height,
        "fps" to fps,
        "framesFed" to framesFed,
        "formatChangedObserved" to formatChangedObserved,
        "csd0Captured" to csd0Captured,
        "csd1Captured" to csd1Captured,
        "configBuffersObserved" to configBuffersObserved,
        "normalBuffersDrained" to normalBuffersDrained,
        "keyFrameBuffersDrained" to keyFrameBuffersDrained,
        "deltaFrameBuffersDrained" to deltaFrameBuffersDrained,
        "eosObserved" to eosObserved,
        "monotonicPtsDtsViolation" to monotonicPtsDtsViolation,
        "lastDeliveryStatus" to lastDeliveryStatus,
        "lastError" to lastError,
        "disposeCount" to disposeCount,
        "adapterSnapshot" to adapter.snapshot(),
    )

    /**
     * Idempotently stops/releases the codec and input surface exactly once and disposes [adapter].
     * Every subsequent lifecycle call fails closed once [BridgeState.DISPOSED] is reached.
     */
    fun dispose(): Map<String, Any?> {
        disposeCount++
        if (state == BridgeState.DISPOSED) {
            return mapOf(
                "pass" to true,
                "state" to state.name,
                "raw" to "status=DISPOSED;idempotent=true;disposeCount=$disposeCount",
            )
        }
        try {
            codec?.stop()
        } catch (t: Throwable) {
            lastError = "dispose_stop_exception:${t.message}"
        }
        try {
            codec?.release()
        } catch (t: Throwable) {
            lastError = "dispose_release_exception:${t.message}"
        }
        try {
            inputSurface?.release()
        } catch (t: Throwable) {
            lastError = "dispose_surface_exception:${t.message}"
        }
        codec = null
        inputSurface = null
        try {
            adapter.dispose()
        } catch (_: Throwable) {
            // adapter.dispose() never throws today; defensive no-op keeps bridge disposal
            // unconditional even if that invariant ever changes.
        }
        state = BridgeState.DISPOSED
        return mapOf("pass" to true, "state" to state.name, "raw" to "status=DISPOSED;disposeCount=$disposeCount")
    }

    private fun failClosed(op: String): Map<String, Any?> =
        mapOf("pass" to false, "state" to state.name, "raw" to "status=INVALID_STATE;op=$op;state=${state.name}")
}
