package com.example.vanguard_media_engine_example

import android.app.Application
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.os.RemoteException
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate
import org.tensorflow.lite.gpu.GpuDelegateFactory

// ── Example-only out-of-process forced raw TensorFlow Lite GPU probe ─────────
//
// Diagnostic evidence only. This service is declared in the example app
// manifest with android:process=":gpuprobe", so it runs in a child process
// separate from the Flutter/MainActivity process. It does NOT touch the
// production Duet ladder (mediapipe_cpu -> mlkit -> none), does not add a
// raw_tflite_gpu tier, and is not reachable from the plugin.
//
// Why out-of-process:
//   MediaPipe Tasks GPU SIGABRTs below the JVM on SM-A566B / Android 16, and
//   the in-process raw TFLite probe respects CompatibilityList (supported=false
//   on that device) so it never reaches the GPU delegate. To learn what the raw
//   GPU delegate itself does when FORCED on such a device, the attempt has to
//   run where a vendor/native abort can only kill a disposable child process.
//   The parent converts child binder death into a normal failure payload.
//
// Binder API (example-only, Messenger-based, no AIDL):
//   parent -> child : Message(what=MSG_RUN_PROBE, replyTo=<parent Messenger>)
//   child  -> parent: Message(what=MSG_PROBE_STARTED, arg1=childPid,
//                             data{KEY_PROCESS_NAME})
//   child  -> parent: Message(what=MSG_PROBE_RESULT, data{KEY_RESULT_JSON})
//
// Ownership / threading (child process):
//   * The command is received on the child's main looper and dispatched to
//     exactly one owned single-thread worker ("DuetTfliteGpuIsolated-GPU").
//   * CompatibilityList is queried and RECORDED but BYPASSED: GpuDelegate +
//     Interpreter are created, invoked once on one synthetic RGB frame, and
//     closed (Interpreter before GpuDelegate) all on that worker thread.
//   * Single-shot: a Service instance accepts exactly one MSG_RUN_PROBE.
//   * A native abort kills this child process; the parent's DeathRecipient is
//     the proof. No signal handler is installed.
class TfliteGpuIsolatedProbeService : Service() {

    private val commandHandler = Handler(
        Looper.getMainLooper(),
        Handler.Callback { msg ->
            handleCommand(msg)
            true
        },
    )
    private val messenger = Messenger(commandHandler)
    private val started = AtomicBoolean(false)
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, WORKER_THREAD_NAME).apply { isDaemon = true }
    }

    override fun onCreate() {
        super.onCreate()
        log(
            "ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_SERVICE_CREATED" +
                " pid=${Process.myPid()} process=${currentProcessName()}",
        )
    }

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onDestroy() {
        try {
            worker.shutdown()
        } catch (_: Throwable) {
        }
        log("ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_SERVICE_DESTROYED pid=${Process.myPid()}")
        super.onDestroy()
    }

    /** Child main thread. */
    private fun handleCommand(msg: Message) {
        if (msg.what != MSG_RUN_PROBE) {
            Log.w(TAG, "Ignoring unknown command what=${msg.what}")
            return
        }
        val replyTo = msg.replyTo
        if (replyTo == null) {
            logFail("missing_reply_to", "MSG_RUN_PROBE arrived without replyTo; cannot report")
            return
        }
        val rawModelAssetPath = msg.data?.getString(KEY_MODEL_ASSET_PATH)
        val modelAssetPath = resolveModelAssetPath(rawModelAssetPath)
        if (modelAssetPath == null) {
            val message = "modelAssetPath failed validation: $rawModelAssetPath"
            logFail("invalid_model_asset_path", message)
            sendResult(
                replyTo,
                ProbeRun.failureJson(
                    code = "invalid_model_asset_path",
                    message = message,
                    throwable = null,
                    modelAssetPath = DEFAULT_MODEL_ASSET_PATH,
                ),
            )
            return
        }
        if (!started.compareAndSet(false, true)) {
            val json = ProbeRun.failureJson(
                code = "probe_already_running",
                message = "This service instance already ran its single-shot probe",
                throwable = null,
                modelAssetPath = modelAssetPath,
            )
            logFail("probe_already_running", "This service instance already ran its single-shot probe")
            sendResult(replyTo, json)
            return
        }
        try {
            worker.execute(ProbeRun(applicationContext, replyTo, modelAssetPath))
        } catch (e: RejectedExecutionException) {
            val message = "Worker rejected probe task: ${e.message}"
            logFail("worker_rejected", message)
            sendResult(replyTo, ProbeRun.failureJson("worker_rejected", message, e, modelAssetPath))
        }
    }

    // ── Single-shot probe run (worker thread) ────────────────────────────────

    private class ProbeRun(
        private val context: Context,
        private val replyTo: Messenger,
        private val modelAssetPath: String,
    ) : Runnable {

        private class ProbeFailure(
            val code: String,
            message: String,
            cause: Throwable?,
        ) : RuntimeException(message, cause)

        private class OutputSpec(
            val index: Int,
            val shape: IntArray,
            val type: DataType,
            val expectedBytes: Int,
            val buffer: ByteBuffer,
        )

        private class OutputStats(
            val index: Int,
            val bytes: Int,
            val min: Double,
            val max: Double,
            val positive: Long,
            val nonZero: Long,
            val nan: Long,
            val integerValued: Boolean,
        )

        // Worker-thread owned.
        private var gpuDelegate: GpuDelegate? = null
        private var interpreter: Interpreter? = null

        private var compatSupported: Boolean? = null
        private var compatError: String? = null
        private var optionsSource: String = "forced_default_options"
        private var precisionLossAllowed: Boolean? = null
        private var inferencePreference: Int? = null
        private var modelBytes: Int = 0
        private var inputShape: IntArray = IntArray(0)
        private var inputType: DataType? = null
        private var outputSpecs: List<OutputSpec> = emptyList()
        private var stats: List<OutputStats> = emptyList()
        private var outputNonZeroTotal: Long = 0L
        private var invokeMs: Long = -1L
        private var closeOk: Boolean? = null
        private var closeError: String? = null
        private var stage: String = "start"
        private val markers = ArrayList<String>()

        override fun run() {
            val startedAt = SystemClock.elapsedRealtime()
            val pid = Process.myPid()
            val processName = currentProcessName()
            mark(
                "ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_START pid=$pid process=$processName" +
                    " thread=${Thread.currentThread().name} model=$modelAssetPath forced=true",
            )
            sendStarted(pid, processName)

            val json: JSONObject = try {
                execute()
                val totalMs = SystemClock.elapsedRealtime() - startedAt
                mark(
                    "ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_PROBE_PASS" +
                        " compatSupported=$compatSupported bypass=true" +
                        " inputShape=${formatShape(inputShape)} inputType=$inputType" +
                        " outputShape=${outputSpecs.joinToString("|") { formatShape(it.shape) }}" +
                        " ${formatPrimaryStats(stats)}${formatExtraOutputs(stats)}" +
                        " outputNonZeroTotal=$outputNonZeroTotal invokeMs=$invokeMs closeOk=$closeOk totalMs=$totalMs",
                )
                buildJson(pass = true, code = "ok", message = "Forced GPU invoke completed", stack = null)
                    .put("totalMs", totalMs)
            } catch (f: ProbeFailure) {
                closeAfterFailure()
                val totalMs = SystemClock.elapsedRealtime() - startedAt
                logFail(f.code, f.message ?: "", f.cause)
                markers.add("ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_PROBE_FAIL code=${f.code} message=${f.message}")
                buildJson(pass = false, code = f.code, message = f.message ?: "", stack = f.cause?.stackTraceToString())
                    .put("totalMs", totalMs)
            } catch (t: Throwable) {
                closeAfterFailure()
                val totalMs = SystemClock.elapsedRealtime() - startedAt
                val message = "Unexpected ${t.javaClass.simpleName} at stage=$stage: ${t.message}"
                logFail("unexpected", message, t)
                markers.add("ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_PROBE_FAIL code=unexpected message=$message")
                buildJson(pass = false, code = "unexpected", message = message, stack = t.stackTraceToString())
                    .put("totalMs", totalMs)
            }

            sendResult(replyTo, json)
        }

        private fun execute() {
            // 1) CompatibilityList: record, then bypass.
            stage = "compat_check"
            var delegateOptions: GpuDelegateFactory.Options? = null
            try {
                val compatibilityList = CompatibilityList()
                try {
                    val supported = compatibilityList.isDelegateSupportedOnThisDevice
                    compatSupported = supported
                    if (supported) {
                        try {
                            val best = compatibilityList.bestOptionsForThisDevice
                            delegateOptions = best
                            optionsSource = "compat_best_options"
                        } catch (t: Throwable) {
                            compatError = "bestOptionsForThisDevice threw: ${t.message}"
                        }
                    }
                } finally {
                    try {
                        compatibilityList.close()
                    } catch (t: Throwable) {
                        Log.w(TAG, "CompatibilityList.close() threw: ${t.message}")
                    }
                }
            } catch (t: Throwable) {
                compatSupported = null
                compatError = "CompatibilityList failed: ${t.javaClass.simpleName}: ${t.message}"
            }
            val options = delegateOptions ?: GpuDelegateFactory.Options().also {
                optionsSource = "forced_default_options"
            }
            precisionLossAllowed = options.isPrecisionLossAllowed
            inferencePreference = options.inferencePreference
            mark(
                "ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_COMPAT supported=$compatSupported bypass=true" +
                    " optionsSource=$optionsSource precisionLossAllowed=$precisionLossAllowed" +
                    " inferencePreference=$inferencePreference" +
                    (compatError?.let { " compatError=$it" } ?: ""),
            )

            // 2) Model load into a direct ByteBuffer, verifying the TFL3 identifier.
            stage = "model_load"
            val model: ByteBuffer
            try {
                model = loadModelIntoDirectBuffer()
            } catch (t: Throwable) {
                throw ProbeFailure(
                    "model_load_failed",
                    "Failed to load $modelAssetPath into a direct ByteBuffer: ${t.message}",
                    t,
                )
            }
            modelBytes = model.capacity()

            // 3) Forced GpuDelegate creation (this is the bypass).
            stage = "gpu_delegate_create"
            val delegate: GpuDelegate
            try {
                delegate = GpuDelegate(options)
                gpuDelegate = delegate
            } catch (t: Throwable) {
                throw ProbeFailure(
                    "gpu_delegate_create_failed",
                    "Forced GpuDelegate creation failed: ${t.javaClass.simpleName}: ${t.message}",
                    t,
                )
            }
            mark("ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_DELEGATE_CREATED optionsSource=$optionsSource")

            // 4) Interpreter with the forced delegate.
            stage = "interpreter_create"
            val interp: Interpreter
            try {
                val interpreterOptions = Interpreter.Options()
                interpreterOptions.addDelegate(delegate)
                interp = Interpreter(model, interpreterOptions)
                interpreter = interp
                interp.allocateTensors()
            } catch (t: Throwable) {
                throw ProbeFailure(
                    "interpreter_init_failed",
                    "Interpreter creation/allocateTensors with forced GpuDelegate failed: ${t.javaClass.simpleName}: ${t.message}",
                    t,
                )
            }

            // 5) Tensor layout inspection + buffer allocation.
            stage = "tensor_inspect"
            val input: ByteBuffer
            try {
                input = inspectAndAllocateTensors(interp)
            } catch (t: Throwable) {
                throw ProbeFailure("tensor_layout_unsupported", "${t.message}", t)
            }
            mark(
                "ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_INTERPRETER_READY" +
                    " inputShape=${formatShape(inputShape)} inputType=$inputType" +
                    " outputShape=${outputSpecs.joinToString("|") { formatShape(it.shape) }}" +
                    " outputType=${outputSpecs.joinToString("|") { it.type.toString() }}" +
                    " outputCount=${outputSpecs.size} inputBytes=${input.capacity()}" +
                    " outputBytes=${outputSpecs.joinToString("|") { it.expectedBytes.toString() }}" +
                    " modelBytes=$modelBytes",
            )

            // 6) Exactly one synthetic RGB frame through the GPU delegate.
            stage = "invoke"
            try {
                fillSyntheticFrame(input, inputShape[2], inputShape[1], inputType ?: DataType.FLOAT32)
                val outputs = HashMap<Int, Any>(outputSpecs.size)
                for (spec in outputSpecs) {
                    spec.buffer.rewind()
                    outputs[spec.index] = spec.buffer
                }
                val t0 = SystemClock.elapsedRealtime()
                interp.runForMultipleInputsOutputs(arrayOf<Any>(input), outputs)
                invokeMs = SystemClock.elapsedRealtime() - t0
            } catch (t: Throwable) {
                throw ProbeFailure(
                    "gpu_invoke_failed",
                    "Forced GPU invoke failed: ${t.javaClass.simpleName}: ${t.message}",
                    t,
                )
            }

            // 7) Output statistics and coverage.
            stage = "output_stats"
            try {
                val computed = ArrayList<OutputStats>(outputSpecs.size)
                var total = 0L
                for (spec in outputSpecs) {
                    val liveBytes = interp.getOutputTensor(spec.index).numBytes()
                    if (liveBytes != spec.expectedBytes || spec.buffer.capacity() != spec.expectedBytes) {
                        throw IllegalStateException(
                            "Output[${spec.index}] byte capacity mismatch: tensor=$liveBytes buffer=${spec.buffer.capacity()} expected=${spec.expectedBytes}",
                        )
                    }
                    val s = computeStats(spec)
                    computed.add(s)
                    total += s.nonZero
                }
                stats = computed
                outputNonZeroTotal = total
            } catch (t: Throwable) {
                throw ProbeFailure("output_stats_failed", "Output statistics failed: ${t.message}", t)
            }
            mark(
                "ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_INVOKE_DONE invokeMs=$invokeMs" +
                    " ${formatPrimaryStats(stats)}${formatExtraOutputs(stats)} outputNonZeroTotal=$outputNonZeroTotal",
            )
            if (outputNonZeroTotal <= 0L) {
                throw ProbeFailure(
                    "zero_output_coverage",
                    "Forced GPU invoke completed but every output element is zero (or NaN); no output coverage",
                    null,
                )
            }

            // 8) Close Interpreter before GpuDelegate, on this worker thread.
            stage = "close"
            val error = closeTflite()
            if (error != null) {
                throw ProbeFailure(
                    "close_failed",
                    "Interpreter/GpuDelegate close threw after a completed invoke: ${error.message}",
                    error,
                )
            }
            mark("ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_CLOSE_PASS")
        }

        private fun loadModelIntoDirectBuffer(): ByteBuffer {
            val bytes = context.assets.open(modelAssetPath).use { it.readBytes() }
            if (bytes.size < 8) {
                throw IllegalStateException("model asset too small (${bytes.size} bytes)")
            }
            // TFLite flatbuffer file identifier "TFL3" lives at offset 4.
            val magic = String(bytes, 4, 4, Charsets.US_ASCII)
            if (magic != "TFL3") {
                throw IllegalStateException("model asset is not a TFL3 flatbuffer (identifier=$magic)")
            }
            val buffer = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder())
            buffer.put(bytes)
            buffer.rewind()
            return buffer
        }

        /** Returns the allocated direct input buffer. */
        private fun inspectAndAllocateTensors(interp: Interpreter): ByteBuffer {
            val inputCount = interp.inputTensorCount
            if (inputCount != 1) {
                throw IllegalStateException("Unsupported input tensor count=$inputCount (expected 1)")
            }
            val inTensor = interp.getInputTensor(0)
            val shape = inTensor.shape()
            val type = inTensor.dataType()
            if (shape.size != 4 || shape[0] != 1 || shape[3] != 3 || shape[1] <= 0 || shape[2] <= 0) {
                throw IllegalStateException(
                    "Unsupported input shape=${formatShape(shape)} (expected NHWC [1,h,w,3])",
                )
            }
            if (type != DataType.FLOAT32 && type != DataType.UINT8) {
                throw IllegalStateException("Unsupported input type=$type (expected FLOAT32 or UINT8)")
            }
            val expectedInputBytes = shape[1].toLong() * shape[2].toLong() * 3L * type.byteSize().toLong()
            if (expectedInputBytes <= 0L || expectedInputBytes > Int.MAX_VALUE.toLong()) {
                throw IllegalStateException("Input byte size out of range: $expectedInputBytes")
            }
            if (inTensor.numBytes().toLong() != expectedInputBytes) {
                throw IllegalStateException(
                    "Input tensor numBytes=${inTensor.numBytes()} != expected $expectedInputBytes",
                )
            }

            val outputCount = interp.outputTensorCount
            if (outputCount < 1) {
                throw IllegalStateException("Unsupported output tensor count=$outputCount (expected >= 1)")
            }
            val specs = ArrayList<OutputSpec>(outputCount)
            for (i in 0 until outputCount) {
                val outTensor = interp.getOutputTensor(i)
                val outShape = outTensor.shape()
                val outType = outTensor.dataType()
                if (outType != DataType.FLOAT32 && outType != DataType.UINT8 && outType != DataType.INT8) {
                    throw IllegalStateException(
                        "Unsupported output[$i] type=$outType (expected FLOAT32, UINT8 or INT8)",
                    )
                }
                if (outShape.isEmpty()) {
                    throw IllegalStateException("Unsupported output[$i] scalar/empty shape")
                }
                var elements = 1L
                for (dim in outShape) {
                    if (dim <= 0) {
                        throw IllegalStateException(
                            "Unsupported output[$i] shape=${formatShape(outShape)} (non-positive dim)",
                        )
                    }
                    elements *= dim.toLong()
                }
                val expected = elements * outType.byteSize().toLong()
                if (expected <= 0L || expected > Int.MAX_VALUE.toLong()) {
                    throw IllegalStateException("Output[$i] byte size out of range: $expected")
                }
                if (outTensor.numBytes().toLong() != expected) {
                    throw IllegalStateException(
                        "Output[$i] tensor numBytes=${outTensor.numBytes()} != expected $expected",
                    )
                }
                val buffer = ByteBuffer.allocateDirect(expected.toInt()).order(ByteOrder.nativeOrder())
                specs.add(OutputSpec(i, outShape, outType, expected.toInt(), buffer))
            }

            inputShape = shape
            inputType = type
            outputSpecs = specs
            return ByteBuffer.allocateDirect(expectedInputBytes.toInt()).order(ByteOrder.nativeOrder())
        }

        /**
         * Deterministic synthetic RGB frame: horizontal red gradient, vertical
         * green gradient, constant blue, plus a centred warm-toned ellipse so the
         * segmenter has a person-like blob to respond to. No camera involved.
         */
        private fun fillSyntheticFrame(input: ByteBuffer, width: Int, height: Int, type: DataType) {
            input.rewind()
            val cx = (width - 1) / 2.0
            val cy = (height - 1) / 2.0
            val rx = maxOf(1.0, width * 0.28)
            val ry = maxOf(1.0, height * 0.38)
            val wDen = if (width > 1) (width - 1).toFloat() else 1f
            val hDen = if (height > 1) (height - 1).toFloat() else 1f
            for (y in 0 until height) {
                val g0 = y / hDen
                val dy = (y - cy) / ry
                for (x in 0 until width) {
                    val dx = (x - cx) / rx
                    val inside = dx * dx + dy * dy <= 1.0
                    val r: Float
                    val g: Float
                    val b: Float
                    if (inside) {
                        r = 0.85f
                        g = 0.66f
                        b = 0.52f
                    } else {
                        r = x / wDen
                        g = g0
                        b = 0.5f
                    }
                    if (type == DataType.FLOAT32) {
                        input.putFloat(r)
                        input.putFloat(g)
                        input.putFloat(b)
                    } else {
                        input.put(toByte255(r))
                        input.put(toByte255(g))
                        input.put(toByte255(b))
                    }
                }
            }
            input.rewind()
        }

        private fun toByte255(v: Float): Byte = (v * 255f + 0.5f).toInt().coerceIn(0, 255).toByte()

        /** nonZero and positive exclude NaN; NaN is counted separately. */
        private fun computeStats(spec: OutputSpec): OutputStats {
            val buf = spec.buffer
            buf.rewind()
            var min = Double.POSITIVE_INFINITY
            var max = Double.NEGATIVE_INFINITY
            var positive = 0L
            var nonZero = 0L
            var nan = 0L
            when (spec.type) {
                DataType.FLOAT32 -> {
                    val floats = buf.asFloatBuffer()
                    val n = spec.expectedBytes / 4
                    for (i in 0 until n) {
                        val v = floats.get(i).toDouble()
                        if (v.isNaN()) {
                            nan++
                            continue
                        }
                        if (v < min) min = v
                        if (v > max) max = v
                        if (v > 0.0) positive++
                        if (v != 0.0) nonZero++
                    }
                }
                DataType.UINT8 -> {
                    for (i in 0 until spec.expectedBytes) {
                        val v = (buf.get(i).toInt() and 0xFF).toDouble()
                        if (v < min) min = v
                        if (v > max) max = v
                        if (v > 0.0) positive++
                        if (v != 0.0) nonZero++
                    }
                }
                DataType.INT8 -> {
                    for (i in 0 until spec.expectedBytes) {
                        val v = buf.get(i).toInt().toDouble()
                        if (v < min) min = v
                        if (v > max) max = v
                        if (v > 0.0) positive++
                        if (v != 0.0) nonZero++
                    }
                }
                else -> throw IllegalStateException("Unsupported output[${spec.index}] type=${spec.type}")
            }
            buf.rewind()
            return OutputStats(
                index = spec.index,
                bytes = spec.expectedBytes,
                min = min,
                max = max,
                positive = positive,
                nonZero = nonZero,
                nan = nan,
                integerValued = spec.type != DataType.FLOAT32,
            )
        }

        /** Worker thread only. Closes Interpreter before GpuDelegate. Returns the first Throwable, if any. */
        private fun closeTflite(): Throwable? {
            var error: Throwable? = null
            try {
                interpreter?.close()
            } catch (t: Throwable) {
                Log.w(TAG, "Interpreter.close() threw: ${t.message}")
                if (error == null) error = t
            }
            interpreter = null
            try {
                gpuDelegate?.close()
            } catch (t: Throwable) {
                Log.w(TAG, "GpuDelegate.close() threw: ${t.message}")
                if (error == null) error = t
            }
            gpuDelegate = null
            outputSpecs = emptyList()
            closeOk = error == null
            closeError = error?.let { "${it.javaClass.simpleName}: ${it.message}" }
            return error
        }

        private fun closeAfterFailure() {
            if (interpreter == null && gpuDelegate == null) return
            val error = closeTflite()
            mark("ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_CLOSE_AFTER_FAIL ok=${error == null}")
        }

        private fun sendStarted(pid: Int, processName: String) {
            try {
                val msg = Message.obtain(null, MSG_PROBE_STARTED)
                msg.arg1 = pid
                msg.data = Bundle().apply { putString(KEY_PROCESS_NAME, processName) }
                replyTo.send(msg)
            } catch (e: RemoteException) {
                Log.w(TAG, "Failed to send MSG_PROBE_STARTED to parent: ${e.message}")
            }
        }

        private fun buildJson(pass: Boolean, code: String, message: String, stack: String?): JSONObject {
            val json = JSONObject()
            json.put("pass", pass)
            json.put("code", code)
            json.put("message", message)
            json.put("route", ROUTE)
            json.put("childPid", Process.myPid())
            json.put("childProcess", currentProcessName())
            json.put("workerThread", Thread.currentThread().name)
            json.put("stage", stage)
            json.put("forced", true)
            val compat = JSONObject()
            compat.put("supported", compatSupported ?: JSONObject.NULL)
            compat.put("bypass", true)
            compat.put("error", compatError ?: JSONObject.NULL)
            compat.put("optionsSource", optionsSource)
            compat.put("precisionLossAllowed", precisionLossAllowed ?: JSONObject.NULL)
            compat.put("inferencePreference", inferencePreference ?: JSONObject.NULL)
            json.put("compat", compat)
            json.put("modelAsset", modelAssetPath)
            json.put("modelBytes", modelBytes)
            json.put("modelIdentifier", if (modelBytes > 0) "TFL3" else JSONObject.NULL)
            json.put("inputShape", JSONArray(inputShape.toList()))
            json.put("inputType", inputType?.toString() ?: JSONObject.NULL)
            val outputs = JSONArray()
            for (spec in outputSpecs) {
                outputs.put(
                    JSONObject()
                        .put("index", spec.index)
                        .put("shape", JSONArray(spec.shape.toList()))
                        .put("type", spec.type.toString())
                        .put("bytes", spec.expectedBytes),
                )
            }
            json.put("outputs", outputs)
            val statsArray = JSONArray()
            for (s in stats) {
                statsArray.put(
                    JSONObject()
                        .put("index", s.index)
                        .put("bytes", s.bytes)
                        .put("min", jsonNumber(s.min))
                        .put("max", jsonNumber(s.max))
                        .put("positive", s.positive)
                        .put("nonZero", s.nonZero)
                        .put("nan", s.nan),
                )
            }
            json.put("stats", statsArray)
            json.put("outputNonZeroTotal", outputNonZeroTotal)
            json.put("invokeMs", invokeMs)
            json.put("closeOk", closeOk ?: JSONObject.NULL)
            json.put("closeError", closeError ?: JSONObject.NULL)
            json.put("stack", stack ?: JSONObject.NULL)
            json.put("markers", JSONArray(markers))
            return json
        }

        private fun mark(line: String) {
            markers.add(line)
            log(line)
        }

        // ── Formatting helpers ───────────────────────────────────────────────

        private fun formatShape(shape: IntArray): String = shape.joinToString(",", "[", "]")

        private fun formatValue(value: Double, integerValued: Boolean): String {
            if (value.isNaN() || value.isInfinite()) return value.toString()
            return if (integerValued) value.toLong().toString() else String.format(Locale.US, "%.6f", value)
        }

        private fun formatPrimaryStats(stats: List<OutputStats>): String {
            val s = stats.firstOrNull() ?: return "outputMin=NA outputMax=NA positive=0 nonZero=0 nan=0 bytes=0"
            return "outputMin=${formatValue(s.min, s.integerValued)}" +
                " outputMax=${formatValue(s.max, s.integerValued)}" +
                " positive=${s.positive} nonZero=${s.nonZero} nan=${s.nan} bytes=${s.bytes}"
        }

        private fun formatExtraOutputs(stats: List<OutputStats>): String {
            if (stats.size <= 1) return ""
            return " outputs=" + stats.drop(1).joinToString(";") { s ->
                "{index=${s.index} min=${formatValue(s.min, s.integerValued)}" +
                    " max=${formatValue(s.max, s.integerValued)}" +
                    " positive=${s.positive} nonZero=${s.nonZero} nan=${s.nan} bytes=${s.bytes}}"
            }
        }

        companion object {
            /** Minimal failure JSON for pre-run rejections (no probe state). */
            fun failureJson(
                code: String,
                message: String,
                throwable: Throwable?,
                modelAssetPath: String = DEFAULT_MODEL_ASSET_PATH,
            ): JSONObject {
                return JSONObject()
                    .put("pass", false)
                    .put("code", code)
                    .put("message", message)
                    .put("route", ROUTE)
                    .put("childPid", Process.myPid())
                    .put("childProcess", currentProcessName())
                    .put("stage", "pre_run")
                    .put("forced", true)
                    .put("modelAsset", modelAssetPath)
                    .put("outputNonZeroTotal", 0L)
                    .put("stack", throwable?.stackTraceToString() ?: JSONObject.NULL)
                    .put("markers", JSONArray())
            }

            /** org.json rejects NaN/Infinity; encode them as strings. */
            private fun jsonNumber(v: Double): Any = if (v.isNaN() || v.isInfinite()) v.toString() else v
        }
    }

    companion object {
        private const val TAG = "DuetTfliteGpuIsolated"
        private const val WORKER_THREAD_NAME = "DuetTfliteGpuIsolated-GPU"
        const val DEFAULT_MODEL_ASSET_PATH = "selfie_segmenter.tflite"
        const val ROUTE = "raw_tflite_interpreter_forced_gpu_delegate_isolated_process"

        // Messenger protocol (example-only).
        const val MSG_RUN_PROBE = 1
        const val MSG_PROBE_STARTED = 2
        const val MSG_PROBE_RESULT = 3
        const val KEY_PROCESS_NAME = "processName"
        const val KEY_RESULT_JSON = "resultJson"
        const val KEY_MODEL_ASSET_PATH = "modelAssetPath"

        /**
         * Relative Android asset path check: non-empty, no leading slash
         * (absolute), no ".." traversal, no backslash, no control characters.
         */
        fun isValidModelAssetPath(path: String): Boolean {
            if (path.isEmpty()) return false
            if (path.startsWith("/")) return false
            if (path.contains("..")) return false
            if (path.contains("\\")) return false
            if (path.any { it.isISOControl() }) return false
            return true
        }

        fun resolveModelAssetPath(path: String?): String? {
            if (path == null) return DEFAULT_MODEL_ASSET_PATH
            if (!isValidModelAssetPath(path)) return null
            return path
        }

        private fun log(line: String) {
            Log.i(TAG, line)
            println(line)
        }

        private fun logFail(code: String, message: String, throwable: Throwable? = null) {
            val line = "ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_PROBE_FAIL code=$code message=$message"
            Log.e(TAG, line, throwable)
            println(line)
        }

        private fun sendResult(replyTo: Messenger, json: JSONObject) {
            try {
                val msg = Message.obtain(null, MSG_PROBE_RESULT)
                msg.data = Bundle().apply { putString(KEY_RESULT_JSON, json.toString()) }
                replyTo.send(msg)
                log("ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_RESULT_SENT code=${json.optString("code")} pass=${json.optBoolean("pass")}")
            } catch (e: RemoteException) {
                Log.w(TAG, "Failed to send MSG_PROBE_RESULT to parent (parent gone?): ${e.message}")
            }
        }

        fun currentProcessName(): String {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                try {
                    return Application.getProcessName()
                } catch (_: Throwable) {
                }
            }
            return try {
                File("/proc/self/cmdline").readText().substringBefore('\u0000').trim()
            } catch (_: Throwable) {
                "unknown"
            }
        }

        /** Converts a child result JSON string into StandardMessageCodec-compatible Map/List values. */
        fun jsonToCodecMap(jsonText: String): Map<String, Any?> {
            return jsonObjectToMap(JSONObject(jsonText))
        }

        private fun jsonObjectToMap(obj: JSONObject): Map<String, Any?> {
            val map = LinkedHashMap<String, Any?>()
            val keys = obj.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                map[key] = jsonValueToCodec(obj.opt(key))
            }
            return map
        }

        private fun jsonArrayToList(array: JSONArray): List<Any?> {
            val list = ArrayList<Any?>(array.length())
            for (i in 0 until array.length()) {
                list.add(jsonValueToCodec(array.opt(i)))
            }
            return list
        }

        private fun jsonValueToCodec(value: Any?): Any? = when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> jsonObjectToMap(value)
            is JSONArray -> jsonArrayToList(value)
            is Boolean, is Int, is Long, is Double, is String -> value
            is Number -> value.toDouble()
            else -> value.toString()
        }
    }
}
