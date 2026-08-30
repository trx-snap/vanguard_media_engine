package com.connects.vanguard_media_engine.codec

import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver

/** One requested video stream in an [AndroidMultiStreamDecodeRequest]. */
data class AndroidMultiStreamDecodeStreamSpec(
    val sourceNodeId: String,
    val videoPath: String,
    val frameCount: Int,
)

/** Request for one [AndroidMultiStreamDecodeCoordinator.run] invocation. */
data class AndroidMultiStreamDecodeRequest(
    val streams: List<AndroidMultiStreamDecodeStreamSpec>,
    val generationId: Long = 1L,
)

/**
 * Vanguard Android True-DAG P2-CONCURRENT-DEC: multi-stream concurrent hardware
 * decode ingest validation coordinator.
 *
 * Additive foundation unit only: validates that 2+ independent video streams can
 * be decoded concurrently via separate hardware MediaCodec/ImageReader/Surface
 * pipelines while feeding a single additive native Phase2 concurrent-decode
 * diagnostic session keyed by source node id. Does not perform PiP/compositor
 * presentation, does not retain native frame storage, and does not touch the
 * existing Phase 4B1 texture-playback route.
 *
 * One coordinator thread pumps all admitted streams serially (round-robin); each
 * stream's own per-session native mutex is enforced natively around
 * import/release/counters, not here.
 */
class AndroidMultiStreamDecodeCoordinator(
    private val bridge: VanguardNativeBridge = defaultBridge(),
) {
    companion object {
        // Bounded no-progress budget: a stream that returns NoImageAvailable this
        // many consecutive pumps without any Ingested progress is treated as
        // stalled and removed from rotation, so a wedged stream cannot spin
        // run() forever.
        private const val MAX_CONSECUTIVE_NO_IMAGE_PUMPS = 40

        private fun defaultBridge(): VanguardNativeBridge {
            val diagnostics = VanguardDiagnostics()
            return VanguardNativeBridge(VanguardLifecycleObserver(diagnostics), diagnostics, null)
        }
    }

    fun run(request: AndroidMultiStreamDecodeRequest): Map<String, Any?> {
        val streamSpecs = request.streams

        if (streamSpecs.size < 2) {
            return failureResult("insufficient_streams;count=${streamSpecs.size}")
        }
        if (streamSpecs.map { it.sourceNodeId }.toSet().size != streamSpecs.size) {
            return failureResult("duplicate_source_node_id")
        }
        val invalidFrameCount = streamSpecs.firstOrNull { it.frameCount <= 0 }
        if (invalidFrameCount != null) {
            return failureResult(
                "invalid_frame_count;sourceNodeId=${invalidFrameCount.sourceNodeId};" +
                    "frameCount=${invalidFrameCount.frameCount}",
            )
        }

        // Preflight-inspect every source before admitting anything, so the mime
        // admission group can be checked before any codec/slot resources exist.
        val inspections = LinkedHashMap<String, AndroidDagSourceInspectionResult>()
        for (spec in streamSpecs) {
            val inspection = AndroidDagSourceInspector().inspect(spec.videoPath)
            if (!inspection.pass) {
                inspections.values.forEach { insp -> try { insp.extractor?.release() } catch (_: Throwable) {} }
                return failureResult(
                    "source_inspection_failed;sourceNodeId=${spec.sourceNodeId};reason=${inspection.failureReason}",
                )
            }
            inspections[spec.sourceNodeId] = inspection
        }
        // This preflight pass only checks admission; AndroidMediaCodecVideoStream.prepare()
        // re-inspects and owns the real extractor used for decode.
        inspections.values.forEach { insp -> try { insp.extractor?.release() } catch (_: Throwable) {} }

        val mimeGroup = inspections.values.first().mime
        if (inspections.values.any { it.mime != mimeGroup }) {
            return failureResult("mime_admission_group_mismatch")
        }

        val advisoryMax = AndroidConcurrentDecoderSlotPolicy().getAdvisoryMaxInstances(mimeGroup)
        val pool = AndroidConcurrentDecoderPool(advisoryMax)
        val streams = mutableListOf<AndroidMediaCodecVideoStream>()
        var sessionId: String? = null

        try {
            var admissionFailure: String? = null
            for (spec in streamSpecs) {
                if (!pool.acquireSlot()) {
                    admissionFailure = "slot_admission_failed;sourceNodeId=${spec.sourceNodeId};advisoryMax=$advisoryMax"
                    break
                }
                val stream = AndroidMediaCodecVideoStream(spec.sourceNodeId, spec.videoPath, pool)
                val prepareError = stream.prepare()
                if (prepareError != null) {
                    // close() releases the slot acquired above even though prepare() failed.
                    stream.close()
                    admissionFailure = "stream_prepare_failed;sourceNodeId=${spec.sourceNodeId};reason=$prepareError"
                    break
                }
                streams.add(stream)
            }

            if (admissionFailure != null) {
                return failureResult(admissionFailure)
            }

            val createResult = bridge.createAndroidDagPhase2ConcurrentDecodeSession(
                streamSpecs.map { it.sourceNodeId }.toTypedArray(),
            )
            if (!createResult.startsWith("status=OK;")) {
                return failureResult("native_session_create_failed;nativeResult=${createResult.take(160)}")
            }
            sessionId = createResult.substringAfter("sessionId=").substringBefore(";").ifEmpty { null }
                ?: return failureResult("native_session_id_parse_failed")

            val requestedFrames = streamSpecs.associate { it.sourceNodeId to it.frameCount }
            val active = ArrayDeque(streams)
            val perStreamError = mutableMapOf<String, String>()
            val consecutiveNoImagePumps = mutableMapOf<String, Int>()

            // Round-robin pump: one coordinator thread pumps all active streams
            // serially until each reaches its requested frame count or hits
            // EOS/failure. Failing streams are removed from rotation. A stream
            // stuck returning NoImageAvailable is bounded by
            // MAX_CONSECUTIVE_NO_IMAGE_PUMPS so it cannot spin this loop forever.
            while (active.isNotEmpty()) {
                val stream = active.removeFirst()
                val target = requestedFrames[stream.sourceNodeId] ?: 0
                if (stream.framesIngested >= target) {
                    continue
                }

                val sid = sessionId
                val outcome = stream.pumpOnce { hwBuf, timelinePtsUs, frameIndex ->
                    bridge.ingestAndroidDagPhase2ConcurrentDecodeFrame(
                        sid,
                        stream.sourceNodeId,
                        hwBuf,
                        stream.width,
                        stream.height,
                        timelinePtsUs,
                        frameIndex,
                        request.generationId,
                        stream.rotationDegrees,
                        false,
                    )
                }

                when (outcome) {
                    is PumpOutcome.Ingested -> {
                        consecutiveNoImagePumps[stream.sourceNodeId] = 0
                        if (stream.framesIngested < target) {
                            active.addLast(stream)
                        }
                    }
                    is PumpOutcome.NoImageAvailable -> {
                        val idle = (consecutiveNoImagePumps[stream.sourceNodeId] ?: 0) + 1
                        consecutiveNoImagePumps[stream.sourceNodeId] = idle
                        if (idle >= MAX_CONSECUTIVE_NO_IMAGE_PUMPS) {
                            perStreamError[stream.sourceNodeId] =
                                "stalled_no_progress;sourceNodeId=${stream.sourceNodeId};" +
                                    "framesIngested=${stream.framesIngested};requestedFrameCount=$target;" +
                                    "consecutiveNoImagePumps=$idle"
                        } else {
                            active.addLast(stream)
                        }
                    }
                    is PumpOutcome.Eos -> {
                        // Ended before reaching its requested frame count; not retried.
                    }
                    is PumpOutcome.Failed -> {
                        perStreamError[stream.sourceNodeId] = outcome.reason
                    }
                }
            }

            val totalIngested = streams.sumOf { it.framesIngested }
            val allReachedTarget = streams.all { it.framesIngested >= (requestedFrames[it.sourceNodeId] ?: 0) }
            val pass = allReachedTarget && perStreamError.isEmpty()

            return mapOf(
                "pass" to pass,
                "sessionId" to sessionId,
                "mime" to mimeGroup,
                "streamCount" to streams.size,
                "totalFramesIngested" to totalIngested,
                "framesIngestedBySourceNodeId" to streams.associate { it.sourceNodeId to it.framesIngested },
                "errorsBySourceNodeId" to perStreamError,
                "raw" to if (pass) {
                    "status=PASS;streamCount=${streams.size};totalFramesIngested=$totalIngested"
                } else {
                    "status=FAIL;streamCount=${streams.size};totalFramesIngested=$totalIngested;" +
                        "errors=${perStreamError.entries.joinToString(",") { "${it.key}:${it.value}" }}"
                },
            )
        } finally {
            // Always cleanup: close every admitted stream (releases codec/reader/
            // extractor/pool slot) and destroy the native session, regardless of
            // pass/fail/exception.
            streams.forEach { stream -> try { stream.close() } catch (_: Throwable) {} }
            val sid = sessionId
            if (sid != null) {
                try { bridge.destroyAndroidDagPhase2ConcurrentDecodeSession(sid) } catch (_: Throwable) {}
            }
        }
    }

    private fun failureResult(reason: String): Map<String, Any?> = mapOf(
        "pass" to false,
        "sessionId" to null,
        "raw" to "status=FAIL;reason=$reason",
    )
}
