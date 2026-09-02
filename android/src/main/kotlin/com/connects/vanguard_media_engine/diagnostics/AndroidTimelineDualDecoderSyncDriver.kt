package com.connects.vanguard_media_engine.diagnostics

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.codec.AndroidDagSourceInspectionResult
import com.connects.vanguard_media_engine.codec.AndroidDagSourceInspector
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P5-COMPOSITOR-TRANS (sub-slice DUAL-DECODER-SYNC): dual
 * MediaCodec synchronized ingest + overlap transition proof driver.
 *
 * Owns exactly two hardware decode pipelines (MediaExtractor + MediaCodec +
 * ImageReader.PRIVATE + HandlerThread each) and one lockstep stepping loop
 * that runs entirely on the calling (coordinator executor) thread:
 *
 *   1. lead-in: `clip0` alone produces [LEAD_FRAMES] frames,
 *   2. overlap: for every overlap frame one Image is stepped out of *each*
 *      decoder, paired on this thread, the SyncFence awaited (API 33+), and
 *      both HardwareBuffers handed to the native crossfade route with their
 *      dimensions / frame indexes / pts and the overlap progress; both
 *      HardwareBuffers and Images are closed after native returns,
 *   3. lead-out: `clip1` alone produces [LEAD_FRAMES] more frames,
 *   4. cleanup (always, idempotent, best effort, in this order per pipeline):
 *      queued Images, codec stop/release, Surface release, ImageReader close,
 *      HandlerThread quit, MediaExtractor release.
 *
 * Hardware decoders are selected by name; a missing hardware decoder fails
 * closed (never a software fallback). Every failure returns a fail-shaped map
 * with `pass=false` and the first failure reason; nothing here ever throws to
 * the coordinator.
 *
 * Diagnostic only: no AndroidTimelineExportSession change, no encoder/mux, no
 * audio, no product/editor UI.
 */
class AndroidTimelineDualDecoderSyncDriver(
    private val bridge: VanguardNativeBridge,
) {
    data class Request(
        val clip0Path: String,
        val clip1Path: String,
        val maxFrames: Int = DEFAULT_MAX_FRAMES,
        val overlapFrames: Int = DEFAULT_OVERLAP_FRAMES,
    )

    companion object {
        private const val TAG = "VanguardP5DualDecoderSync"

        const val PROOF_BOUNDARY =
            "native_android_dual_mediacodec_imagereader_ahb_to_vulkan_transition_crossfade_diagnostic_only_no_export"
        const val PASS_MARKER =
            "ANDROID_DAG_PHASE5_TIMELINE_DUAL_DECODER_SYNC_PHYSICAL_SMOKE_PASS"
        const val FAIL_MARKER =
            "ANDROID_DAG_PHASE5_TIMELINE_DUAL_DECODER_SYNC_PHYSICAL_SMOKE_FAIL"

        const val DEFAULT_MAX_FRAMES = 60
        const val DEFAULT_OVERLAP_FRAMES = 3
        const val MAX_FRAMES_LIMIT = 600
        const val OVERLAP_FRAMES_LIMIT = 60

        /** Frames each clip must produce alone before / after the overlap. */
        const val LEAD_FRAMES = 2

        val GATE_KEYS: List<String> = listOf(
            "argumentValidationOk",
            "fixtureFormatOk",
            "dualDecoderSetupOk",
            "leadInClip0Ok",
            "overlapPairAcquireOk",
            "overlapPtsMonotonicOk",
            "transitionProgressOk",
            "nativeImportOk",
            "nativeCrossfadeRenderOk",
            "leadOutClip1Ok",
            "resourceReleaseOk",
        )

        private const val IMAGE_READER_MAX_IMAGES = 3
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val IMAGE_ACQUIRE_TIMEOUT_MS = 1_000L
        private const val MAX_NO_OUTPUT_ATTEMPTS = 400
        private const val FENCE_WAIT_MS = 1_000L
        private const val PROGRESS_EPSILON = 1e-9

        /** Fail-shaped result map with every gate false. */
        fun failedMap(reason: String, status: String = "FAIL"): Map<String, Any?> {
            val map = LinkedHashMap<String, Any?>()
            map["pass"] = false
            map["status"] = status
            map["marker"] = FAIL_MARKER
            map["proofBoundary"] = PROOF_BOUNDARY
            map["failureReason"] = reason
            for (key in GATE_KEYS) map[key] = false
            map["allNativeLanesPass"] = false
            map["nativeAllLanesPass"] = false
            map["details"] = mapOf("reason" to reason)
            map["raw"] = "{\"pass\":false,\"status\":\"$status\",\"failureReason\":\"$reason\"}"
            return map
        }

        /** Returns null when the request is admissible, else a reason token. */
        fun validateRequest(request: Request): String? {
            if (request.clip0Path.isBlank()) return "clip0_path_empty"
            if (request.clip1Path.isBlank()) return "clip1_path_empty"
            if (request.maxFrames <= 0 || request.maxFrames > MAX_FRAMES_LIMIT) {
                return "max_frames_out_of_range;maxFrames=${request.maxFrames}"
            }
            if (request.overlapFrames <= 0 || request.overlapFrames > OVERLAP_FRAMES_LIMIT) {
                return "overlap_frames_out_of_range;overlapFrames=${request.overlapFrames}"
            }
            if (request.maxFrames < LEAD_FRAMES + request.overlapFrames) {
                return "max_frames_below_lead_plus_overlap;maxFrames=${request.maxFrames};" +
                    "required=${LEAD_FRAMES + request.overlapFrames}"
            }
            val f0 = File(request.clip0Path)
            val f1 = File(request.clip1Path)
            if (!f0.isFile || !f0.canRead()) return "clip0_not_readable"
            if (!f1.isFile || !f1.canRead()) return "clip1_not_readable"
            return null
        }

        private fun strictlyIncreasing(values: List<Long>): Boolean {
            for (i in 1 until values.size) {
                if (values[i] <= values[i - 1]) return false
            }
            return true
        }

        private fun jsonObjectToMap(obj: JSONObject): Map<String, Any?> {
            val out = LinkedHashMap<String, Any?>()
            val keys = obj.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                out[key] = convertJsonValue(obj.opt(key))
            }
            return out
        }

        private fun jsonArrayToList(arr: JSONArray): List<Any?> {
            val out = ArrayList<Any?>(arr.length())
            for (i in 0 until arr.length()) out.add(convertJsonValue(arr.opt(i)))
            return out
        }

        private fun convertJsonValue(value: Any?): Any? = when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> jsonObjectToMap(value)
            is JSONArray -> jsonArrayToList(value)
            is Boolean, is Int, is Long, is Double, is String -> value
            is Number -> value.toDouble()
            else -> value.toString()
        }

        private fun parseNativeJson(raw: String): Map<String, Any?> {
            return try {
                val map = jsonObjectToMap(JSONObject(raw)).toMutableMap()
                map["raw"] = raw
                map
            } catch (t: Throwable) {
                mapOf(
                    "pass" to false,
                    "status" to "FAIL",
                    "failureReason" to "native_result_not_json",
                    "raw" to raw,
                )
            }
        }

        private fun mapBool(map: Map<String, Any?>, key: String): Boolean = map[key] == true
    }

    /** Runs the whole diagnostic synchronously on the calling thread. */
    fun run(request: Request): Map<String, Any?> {
        val session = Session(request)
        try {
            session.execute()
        } catch (t: Throwable) {
            Log.e(TAG, "dual decoder sync run failed", t)
            session.fail("exception:${t.javaClass.simpleName}:${t.message}")
        } finally {
            session.cleanup()
        }
        return session.buildResult()
    }

    // ── One decoded frame handed across the lockstep loop ─────────────────────

    private class DecodedFrame(
        val image: Image,
        val ptsUs: Long,
        val timestampNs: Long,
        val frameIndex: Int,
        val fenceWaited: Boolean,
    )

    private sealed class StepOutcome {
        class Frame(val frame: DecodedFrame) : StepOutcome()
        object Eos : StepOutcome()
        class Failed(val reason: String) : StepOutcome()
    }

    // ── Single hardware decode pipeline ───────────────────────────────────────

    private class DecodePipeline(
        val label: String,
        private val inspection: AndroidDagSourceInspectionResult,
    ) {
        val width: Int = inspection.width
        val height: Int = inspection.height
        val mime: String = inspection.mime

        var decoderName: String? = null
            private set
        var framesProduced: Int = 0
            private set
        var openImages: Int = 0
            private set
        val closeSteps = LinkedHashMap<String, Boolean>()

        private var extractor: MediaExtractor? = inspection.extractor
        private var codec: MediaCodec? = null
        private var imageReader: ImageReader? = null
        private var surface: Surface? = null
        private var handlerThread: HandlerThread? = null
        private val imageQueue = LinkedBlockingQueue<Image>(IMAGE_READER_MAX_IMAGES)
        private var inputDone = false
        private var outputDone = false
        private val closed = AtomicBoolean(false)

        /** Hardware decoder + ImageReader.PRIVATE configure. Null on success. */
        fun prepare(): String? {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                return "api_level_below_29;sdk=${Build.VERSION.SDK_INT}"
            }
            val format = inspection.format ?: return "track_format_missing"
            if (extractor == null) return "extractor_missing"
            val name = selectHardwareDecoderName(mime)
                ?: return "no_hardware_decoder_available;mime=$mime"
            decoderName = name
            return try {
                val ht = HandlerThread("VgDualDecoderSync-$label").also {
                    handlerThread = it
                    it.start()
                }
                val reader = ImageReader.newInstance(
                    width,
                    height,
                    ImageFormat.PRIVATE,
                    IMAGE_READER_MAX_IMAGES,
                    HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
                ).also { imageReader = it }
                reader.setOnImageAvailableListener(
                    { r ->
                        try {
                            val img = r.acquireNextImage()
                            if (img != null && !imageQueue.offer(img)) {
                                img.close()
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "acquireNextImage failed for $label: $e")
                        }
                    },
                    Handler(ht.looper),
                )
                surface = reader.surface
                // The diagnostic samples the encoded (unrotated) buffer; zero any
                // track rotation so the decoder does not rotate the ImageReader
                // buffer behind our declared width/height.
                format.setInteger(MediaFormat.KEY_ROTATION, 0)
                val dec = MediaCodec.createByCodecName(name).also { codec = it }
                dec.configure(format, reader.surface, null, 0)
                dec.start()
                null
            } catch (t: Throwable) {
                "codec_configure_failed;reason=${t.javaClass.simpleName}:${t.message}"
            }
        }

        /**
         * Feeds input and drains output until one rendered frame's Image is
         * acquired (bounded), the decoder reports EOS, or a bounded number of
         * no-output attempts / [maxFrames] is exhausted.
         */
        fun nextFrame(maxFrames: Int): StepOutcome {
            if (closed.get()) return StepOutcome.Failed("pipeline_closed")
            val dec = codec ?: return StepOutcome.Failed("codec_missing")
            if (outputDone) return StepOutcome.Eos
            var noOutputAttempts = 0
            val info = MediaCodec.BufferInfo()
            while (true) {
                if (framesProduced >= maxFrames) {
                    return StepOutcome.Failed("max_frames_reached;maxFrames=$maxFrames")
                }
                feedInput(dec)
                val outIdx = dec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                if (outIdx >= 0) {
                    val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    val renderable = info.size > 0
                    dec.releaseOutputBuffer(outIdx, renderable)
                    if (isEos) outputDone = true
                    if (renderable) {
                        val image = imageQueue.poll(IMAGE_ACQUIRE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                            ?: return StepOutcome.Failed("image_acquire_timeout")
                        val fenceWaited = awaitFence(image)
                        val frameIndex = framesProduced
                        framesProduced++
                        openImages++
                        return StepOutcome.Frame(
                            DecodedFrame(image, info.presentationTimeUs, image.timestamp, frameIndex, fenceWaited),
                        )
                    }
                    if (isEos) return StepOutcome.Eos
                    noOutputAttempts = 0
                    continue
                }
                noOutputAttempts++
                if (noOutputAttempts >= MAX_NO_OUTPUT_ATTEMPTS) {
                    return StepOutcome.Failed("decoder_stalled;attempts=$noOutputAttempts")
                }
            }
        }

        /** Closes the frame's Image (the caller closes its HardwareBuffer first). */
        fun releaseFrame(frame: DecodedFrame) {
            try {
                frame.image.close()
            } catch (_: Throwable) {
            }
            openImages--
        }

        /**
         * Close order: queued Images, codec stop/release, Surface release,
         * ImageReader close, HandlerThread quit, MediaExtractor release.
         * Idempotent; every step is attempted; returns the failed step labels.
         */
        fun close(): List<String> {
            if (!closed.compareAndSet(false, true)) return emptyList()
            val errors = ArrayList<String>()
            fun step(name: String, block: () -> Unit) {
                try {
                    block()
                    closeSteps[name] = true
                } catch (t: Throwable) {
                    closeSteps[name] = false
                    errors.add("$label:$name:${t.javaClass.simpleName}")
                }
            }
            step("drainQueuedImages") {
                while (true) {
                    val img = imageQueue.poll() ?: break
                    try {
                        img.close()
                    } catch (_: Throwable) {
                    }
                }
            }
            step("codecStop") { codec?.stop() }
            step("codecRelease") {
                codec?.release()
                codec = null
            }
            step("surfaceRelease") {
                surface?.release()
                surface = null
            }
            step("imageReaderClose") {
                imageReader?.close()
                imageReader = null
            }
            step("handlerThreadQuit") {
                handlerThread?.quitSafely()
                handlerThread = null
            }
            step("extractorRelease") {
                extractor?.release()
                extractor = null
            }
            return errors
        }

        private fun feedInput(dec: MediaCodec) {
            val ex = extractor ?: return
            while (!inputDone) {
                val inIdx = dec.dequeueInputBuffer(0)
                if (inIdx < 0) return
                val buf = dec.getInputBuffer(inIdx)
                if (buf == null) {
                    dec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputDone = true
                    return
                }
                val size = ex.readSampleData(buf, 0)
                if (size < 0) {
                    dec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputDone = true
                } else {
                    dec.queueInputBuffer(inIdx, 0, size, ex.sampleTime, 0)
                    ex.advance()
                }
            }
        }

        /** Awaits the Image's SyncFence on API 33+. Returns true when waited. */
        private fun awaitFence(image: Image): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
            return try {
                val fence = image.fence
                try {
                    if (fence.isValid) {
                        fence.await(java.time.Duration.ofMillis(FENCE_WAIT_MS))
                    } else {
                        true
                    }
                } finally {
                    try {
                        fence.close()
                    } catch (_: Throwable) {
                    }
                }
            } catch (t: Throwable) {
                Log.w(TAG, "SyncFence exception for $label: $t")
                false
            }
        }

        private fun selectHardwareDecoderName(mime: String): String? {
            return try {
                val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
                list.codecInfos.firstOrNull { info ->
                    !info.isEncoder &&
                        info.isHardwareAccelerated &&
                        info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
                }?.name
            } catch (t: Throwable) {
                Log.w(TAG, "selectHardwareDecoderName failed for mime=$mime: $t")
                null
            }
        }
    }

    // ── One diagnostic run (state + lanes + result shaping) ───────────────────

    private inner class Session(private val request: Request) {
        private val startedMs = SystemClock.elapsedRealtime()
        private val gates = LinkedHashMap<String, Boolean>().apply {
            for (key in GATE_KEYS) put(key, false)
        }
        private val details = LinkedHashMap<String, Any?>()
        private var failureReason: String? = null
        private var unsupported = false
        private var pipeline0: DecodePipeline? = null
        private var pipeline1: DecodePipeline? = null
        private val nativeResults = ArrayList<Map<String, Any?>>()
        private var closeErrors: List<String> = emptyList()
        private var openImagesAfterClose = -1
        private var cleanedUp = false

        fun fail(reason: String) {
            if (failureReason == null) failureReason = reason
        }

        fun execute() {
            details["sdkInt"] = Build.VERSION.SDK_INT
            details["maxFrames"] = request.maxFrames
            details["overlapFrames"] = request.overlapFrames
            details["leadFrames"] = LEAD_FRAMES

            // ── Lane: argument validation ─────────────────────────────────────
            val argError = validateRequest(request)
            gates["argumentValidationOk"] = argError == null
            if (argError != null) {
                fail("invalid_argument:$argError")
                return
            }

            // ── Lane: fixture format (both real video tracks) ─────────────────
            val insp0 = AndroidDagSourceInspector().inspect(request.clip0Path)
            val insp1 = AndroidDagSourceInspector().inspect(request.clip1Path)
            val fmt0 = fixtureError(insp0)
            val fmt1 = fixtureError(insp1)
            recordFixture("clip0", insp0)
            recordFixture("clip1", insp1)
            gates["fixtureFormatOk"] = fmt0 == null && fmt1 == null
            if (fmt0 != null || fmt1 != null) {
                try { insp0.extractor?.release() } catch (_: Throwable) {}
                try { insp1.extractor?.release() } catch (_: Throwable) {}
                fail("fixture_format_failed:" + (fmt0?.let { "clip0:$it" } ?: "clip1:$fmt1"))
                return
            }
            // Extractor ownership transfers to the pipelines from here on;
            // cleanup() always closes both pipelines.
            val p0 = DecodePipeline("clip0", insp0).also { pipeline0 = it }
            val p1 = DecodePipeline("clip1", insp1).also { pipeline1 = it }

            // ── Lane: dual hardware decoder setup ─────────────────────────────
            val prep0 = p0.prepare()
            val prep1 = p1.prepare()
            details["clip0DecoderName"] = p0.decoderName
            details["clip1DecoderName"] = p1.decoderName
            details["clip0PrepareError"] = prep0
            details["clip1PrepareError"] = prep1
            gates["dualDecoderSetupOk"] = prep0 == null && prep1 == null
            if (prep0 != null || prep1 != null) {
                fail("dual_decoder_setup_failed:" + (prep0?.let { "clip0:$it" } ?: "clip1:$prep1"))
                return
            }

            // ── Lane: lead-in, clip0 alone ────────────────────────────────────
            val leadInPts = ArrayList<Long>()
            var leadInError: String? = null
            for (i in 0 until LEAD_FRAMES) {
                when (val step = p0.nextFrame(request.maxFrames)) {
                    is StepOutcome.Frame -> {
                        leadInPts.add(step.frame.ptsUs)
                        p0.releaseFrame(step.frame)
                    }
                    is StepOutcome.Eos -> {
                        leadInError = "lead_in_clip0_eos_after_${leadInPts.size}_frames"
                    }
                    is StepOutcome.Failed -> {
                        leadInError = "lead_in_clip0_failed:${step.reason}"
                    }
                }
                if (leadInError != null) break
            }
            details["leadInClip0PtsUs"] = leadInPts
            val leadInOk = leadInError == null && leadInPts.size == LEAD_FRAMES && strictlyIncreasing(leadInPts)
            gates["leadInClip0Ok"] = leadInOk
            if (!leadInOk) {
                fail(leadInError ?: "lead_in_clip0_pts_not_monotonic")
                return
            }

            // ── Lane: overlap window, one frame from each decoder per step ────
            val overlapPts0 = ArrayList<Long>()
            val overlapPts1 = ArrayList<Long>()
            val overlapTs0 = ArrayList<Long>()
            val overlapTs1 = ArrayList<Long>()
            val progresses = ArrayList<Double>()
            val fenceWaits = ArrayList<Boolean>()
            var pairsAcquired = 0
            var overlapError: String? = null
            for (i in 0 until request.overlapFrames) {
                val step0 = p0.nextFrame(request.maxFrames)
                val frame0 = (step0 as? StepOutcome.Frame)?.frame
                if (frame0 == null) {
                    overlapError = "overlap_clip0_" + describeStep(step0)
                    break
                }
                val step1 = p1.nextFrame(request.maxFrames)
                val frame1 = (step1 as? StepOutcome.Frame)?.frame
                if (frame1 == null) {
                    p0.releaseFrame(frame0)
                    overlapError = "overlap_clip1_" + describeStep(step1)
                    break
                }
                pairsAcquired++
                overlapPts0.add(frame0.ptsUs)
                overlapPts1.add(frame1.ptsUs)
                overlapTs0.add(frame0.timestampNs)
                overlapTs1.add(frame1.timestampNs)
                fenceWaits.add(frame0.fenceWaited && frame1.fenceWaited)
                // Strictly inside (0,1): the blend must really mix both layers.
                val progress = (i + 1).toDouble() / (request.overlapFrames + 1).toDouble()
                progresses.add(progress)

                var hwBuf0: HardwareBuffer? = null
                var hwBuf1: HardwareBuffer? = null
                try {
                    hwBuf0 = frame0.image.hardwareBuffer
                    hwBuf1 = frame1.image.hardwareBuffer
                    if (hwBuf0 == null || hwBuf1 == null) {
                        overlapError = "overlap_hardware_buffer_null;pair=$i"
                        break
                    }
                    val raw = bridge.renderAndroidDagPhase5TimelineDualDecoderSyncCrossfade(
                        hwBuf0,
                        p0.width,
                        p0.height,
                        frame0.frameIndex,
                        frame0.ptsUs,
                        hwBuf1,
                        p1.width,
                        p1.height,
                        frame1.frameIndex,
                        frame1.ptsUs,
                        progress,
                    )
                    nativeResults.add(parseNativeJson(raw))
                } catch (t: Throwable) {
                    Log.e(TAG, "native crossfade failed for pair $i", t)
                    nativeResults.add(
                        mapOf(
                            "pass" to false,
                            "status" to "FAIL",
                            "failureReason" to "native_exception:${t.javaClass.simpleName}",
                        ),
                    )
                } finally {
                    // Native has returned: HardwareBuffers first, then Images.
                    try { hwBuf0?.close() } catch (_: Throwable) {}
                    try { hwBuf1?.close() } catch (_: Throwable) {}
                    p0.releaseFrame(frame0)
                    p1.releaseFrame(frame1)
                }
            }
            details["overlapPairsAcquired"] = pairsAcquired
            details["overlapClip0PtsUs"] = overlapPts0
            details["overlapClip1PtsUs"] = overlapPts1
            details["overlapClip0ImageTimestampNs"] = overlapTs0
            details["overlapClip1ImageTimestampNs"] = overlapTs1
            details["overlapProgress"] = progresses
            details["overlapFenceWaited"] = fenceWaits
            details["overlapError"] = overlapError
            details["nativeResults"] = nativeResults

            val allPairs = overlapError == null && pairsAcquired == request.overlapFrames &&
                nativeResults.size == request.overlapFrames
            gates["overlapPairAcquireOk"] = allPairs
            gates["overlapPtsMonotonicOk"] = allPairs &&
                strictlyIncreasing(overlapPts0) && strictlyIncreasing(overlapPts1) &&
                strictlyIncreasing(overlapTs0) && strictlyIncreasing(overlapTs1) &&
                leadInPts.last() < overlapPts0.first()

            var progressOk = allPairs
            for (i in progresses.indices) {
                val p = progresses[i]
                val native = nativeResults.getOrNull(i)
                val from = native?.let { nestedDouble(it, "blendWeightFrom") }
                val to = native?.let { nestedDouble(it, "blendWeightTo") }
                val echoedProgress = native?.let { nestedDouble(it, "geometryProgress") }
                val inside = p.isFinite() && p > 0.0 && p < 1.0
                val increasing = i == 0 || p > progresses[i - 1]
                val echoOk = from != null && to != null && echoedProgress != null &&
                    kotlin.math.abs(from - (1.0 - p)) <= PROGRESS_EPSILON &&
                    kotlin.math.abs(to - p) <= PROGRESS_EPSILON &&
                    kotlin.math.abs(echoedProgress - p) <= PROGRESS_EPSILON
                if (!(inside && increasing && echoOk)) progressOk = false
            }
            gates["transitionProgressOk"] = progressOk

            gates["nativeImportOk"] = allPairs && nativeResults.all {
                mapBool(it, "argumentValidationOk") && mapBool(it, "vulkanSetupOk") && mapBool(it, "nativeImportOk")
            }
            gates["nativeCrossfadeRenderOk"] = allPairs && nativeResults.all {
                mapBool(it, "nativeCrossfadeRenderOk") && mapBool(it, "pass")
            }
            unsupported = nativeResults.any { (it["status"] as? String)?.equals("UNSUPPORTED", true) == true }
            if (overlapError != null) {
                fail(overlapError)
            } else if (!allPairs) {
                fail("overlap_pair_acquire_failed")
            } else if (gates["overlapPtsMonotonicOk"] != true) {
                fail("overlap_pts_not_monotonic")
            } else if (!progressOk) {
                fail("transition_progress_mismatch")
            } else if (gates["nativeImportOk"] != true || gates["nativeCrossfadeRenderOk"] != true) {
                val firstNativeFailure = nativeResults.firstOrNull { !mapBool(it, "pass") }
                    ?.get("failureReason") as? String
                fail("native_crossfade_failed:" + (firstNativeFailure ?: "unknown"))
            }
            if (!allPairs) return

            // ── Lane: lead-out, clip1 alone ───────────────────────────────────
            val leadOutPts = ArrayList<Long>()
            var leadOutError: String? = null
            for (i in 0 until LEAD_FRAMES) {
                when (val step = p1.nextFrame(request.maxFrames)) {
                    is StepOutcome.Frame -> {
                        leadOutPts.add(step.frame.ptsUs)
                        p1.releaseFrame(step.frame)
                    }
                    is StepOutcome.Eos -> {
                        leadOutError = "lead_out_clip1_eos_after_${leadOutPts.size}_frames"
                    }
                    is StepOutcome.Failed -> {
                        leadOutError = "lead_out_clip1_failed:${step.reason}"
                    }
                }
                if (leadOutError != null) break
            }
            details["leadOutClip1PtsUs"] = leadOutPts
            val leadOutOk = leadOutError == null && leadOutPts.size == LEAD_FRAMES &&
                strictlyIncreasing(leadOutPts) && overlapPts1.last() < leadOutPts.first()
            gates["leadOutClip1Ok"] = leadOutOk
            if (!leadOutOk) {
                fail(leadOutError ?: "lead_out_clip1_pts_not_monotonic")
            }
        }

        /** Always runs (finally). Idempotent. */
        fun cleanup() {
            if (cleanedUp) return
            cleanedUp = true
            val errors = ArrayList<String>()
            pipeline0?.let { errors.addAll(it.close()) }
            pipeline1?.let { errors.addAll(it.close()) }
            closeErrors = errors
            openImagesAfterClose = (pipeline0?.openImages ?: 0) + (pipeline1?.openImages ?: 0)
            details["closeErrors"] = errors
            details["openImagesAfterClose"] = openImagesAfterClose
            details["clip0CloseSteps"] = pipeline0?.closeSteps?.toMap() ?: emptyMap<String, Boolean>()
            details["clip1CloseSteps"] = pipeline1?.closeSteps?.toMap() ?: emptyMap<String, Boolean>()
            details["clip0FramesProduced"] = pipeline0?.framesProduced ?: 0
            details["clip1FramesProduced"] = pipeline1?.framesProduced ?: 0
            details["elapsedMs"] = SystemClock.elapsedRealtime() - startedMs

            val nativeReleaseOk = nativeResults.isNotEmpty() &&
                nativeResults.size == request.overlapFrames &&
                nativeResults.all { mapBool(it, "resourceReleaseOk") }
            gates["resourceReleaseOk"] = pipeline0 != null && pipeline1 != null &&
                errors.isEmpty() && openImagesAfterClose == 0 && nativeReleaseOk
            if (gates["resourceReleaseOk"] != true && failureReason == null) {
                fail("resource_release_incomplete")
            }
        }

        fun buildResult(): Map<String, Any?> {
            val nativeAll = nativeResults.isNotEmpty() &&
                nativeResults.size == request.overlapFrames &&
                nativeResults.all { mapBool(it, "allNativeLanesPass") && mapBool(it, "nativeAllLanesPass") }
            val pass = GATE_KEYS.all { gates[it] == true } && nativeAll
            if (!pass && failureReason == null) fail("gate_failed")
            val status = if (pass) "PASS" else if (unsupported) "UNSUPPORTED" else "FAIL"
            val map = LinkedHashMap<String, Any?>()
            map["pass"] = pass
            map["status"] = status
            map["marker"] = if (pass) PASS_MARKER else FAIL_MARKER
            map["proofBoundary"] = PROOF_BOUNDARY
            map["failureReason"] = if (pass) "" else (failureReason ?: "")
            for (key in GATE_KEYS) map[key] = gates[key] == true
            map["allNativeLanesPass"] = nativeAll
            map["nativeAllLanesPass"] = nativeAll
            map["details"] = details
            map["raw"] = try {
                JSONObject(map as Map<*, *>).toString()
            } catch (t: Throwable) {
                "{\"pass\":$pass,\"status\":\"$status\",\"failureReason\":\"${map["failureReason"]}\"}"
            }
            return map
        }

        private fun fixtureError(insp: AndroidDagSourceInspectionResult): String? {
            if (!insp.pass) return "inspection_failed;reason=${insp.failureReason}"
            if (!insp.mime.startsWith("video/")) return "not_a_video_track;mime=${insp.mime}"
            if (insp.width <= 0 || insp.height <= 0) return "invalid_dimensions;${insp.width}x${insp.height}"
            if (insp.extractor == null || insp.format == null) return "inspection_missing_extractor_or_format"
            return null
        }

        private fun recordFixture(prefix: String, insp: AndroidDagSourceInspectionResult) {
            details["${prefix}InspectionPass"] = insp.pass
            details["${prefix}Mime"] = insp.mime
            details["${prefix}Width"] = insp.width
            details["${prefix}Height"] = insp.height
            details["${prefix}RotationDegrees"] = insp.rotationDegrees
            details["${prefix}DurationUs"] = insp.durationUs
            details["${prefix}InspectionFailure"] = insp.failureReason
        }

        private fun describeStep(step: StepOutcome): String = when (step) {
            is StepOutcome.Frame -> "frame"
            is StepOutcome.Eos -> "eos_before_overlap_complete"
            is StepOutcome.Failed -> "failed:${step.reason}"
        }

        private fun nestedDouble(native: Map<String, Any?>, key: String): Double? {
            val nested = native["details"] as? Map<*, *> ?: return null
            return when (val v = nested[key]) {
                is Number -> v.toDouble()
                else -> null
            }
        }
    }
}
