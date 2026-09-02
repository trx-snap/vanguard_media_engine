package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P5-COMPOSITOR-TRANS (sub-slice DUAL-DECODER-SYNC):
 * verification smoke coordinator.
 *
 * Owns exactly the [METHOD_NAME] MethodChannel route. Parses the two clip
 * paths plus optional `maxFrames` / `overlapFrames`, fails closed on missing
 * or malformed arguments (fail-shaped map, `argumentValidationOk=false`,
 * never PASS), and runs [AndroidTimelineDualDecoderSyncDriver] on a single
 * dedicated background executor (never the main thread) because the driver
 * blocks on MediaCodec dequeues, ImageReader delivery and the synchronous
 * native Vulkan crossfade. The parsed result map is posted back through
 * [mainHandler]. Expected failures (busy, native exception) return a
 * fail-shaped map with `pass=false`, never a thrown MethodChannel error.
 *
 * Diagnostic only: no export session route change, no product UI.
 */
class AndroidTimelineDualDecoderSyncSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP5DualDecoderSync"
        private const val METHOD_NAME = "runAndroidDagPhase5TimelineDualDecoderSyncSmoke"

        private const val ARG_CLIP0_PATH = "clip0Path"
        private const val ARG_CLIP1_PATH = "clip1Path"
        private const val ARG_MAX_FRAMES = "maxFrames"
        private const val ARG_OVERLAP_FRAMES = "overlapFrames"

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vanguard-p5-dual-decoder-sync-smoke").apply { isDaemon = true }
    }
    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        if (method != METHOD_NAME) {
            return false
        }
        runSmoke(args, result)
        return true
    }

    /**
     * Releases the background executor. Safe to call more than once. An
     * in-flight run finishes on its own thread; the driver's finally block
     * releases both decoder pipelines and native destroys its own VkDevice
     * before the run completes.
     */
    fun disposeAll() {
        if (disposed.compareAndSet(false, true)) {
            executor.shutdown()
        }
    }

    private fun runSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        if (disposed.get()) {
            result.success(AndroidTimelineDualDecoderSyncDriver.failedMap("coordinator_disposed"))
            return
        }
        val request = when (val parsed = parseRequest(args)) {
            is ParsedArgs.Invalid -> {
                result.success(
                    AndroidTimelineDualDecoderSyncDriver.failedMap("invalid_argument:${parsed.reason}"),
                )
                return
            }
            is ParsedArgs.Valid -> parsed.request
        }
        if (!active.compareAndSet(false, true)) {
            result.success(AndroidTimelineDualDecoderSyncDriver.failedMap("smoke_already_active"))
            return
        }
        try {
            executor.execute {
                try {
                    val diagnostics = VanguardDiagnostics()
                    val nativeBridge = VanguardNativeBridge(
                        lifecycleObserver = VanguardLifecycleObserver(diagnostics),
                        diagnostics = diagnostics,
                        codecAdapter = null,
                    )
                    val payload = normalize(AndroidTimelineDualDecoderSyncDriver(nativeBridge).run(request))
                    mainHandler.post { result.success(payload) }
                } catch (t: Throwable) {
                    Log.e(TAG, "$METHOD_NAME failed", t)
                    mainHandler.post {
                        result.success(
                            AndroidTimelineDualDecoderSyncDriver.failedMap(
                                "exception:${t.javaClass.simpleName}:${t.message}",
                            ),
                        )
                    }
                } finally {
                    active.set(false)
                }
            }
        } catch (t: Throwable) {
            // Executor rejected the task (e.g. disposed concurrently).
            active.set(false)
            Log.e(TAG, "$METHOD_NAME could not be scheduled", t)
            result.success(
                AndroidTimelineDualDecoderSyncDriver.failedMap("executor_rejected:${t.javaClass.simpleName}"),
            )
        }
    }

    private sealed class ParsedArgs {
        class Valid(val request: AndroidTimelineDualDecoderSyncDriver.Request) : ParsedArgs()
        class Invalid(val reason: String) : ParsedArgs()
    }

    private fun parseRequest(args: Map<*, *>?): ParsedArgs {
        if (args == null) return ParsedArgs.Invalid("arguments_missing")
        val clip0 = args[ARG_CLIP0_PATH] as? String
        val clip1 = args[ARG_CLIP1_PATH] as? String
        if (clip0.isNullOrBlank()) return ParsedArgs.Invalid("${ARG_CLIP0_PATH}_missing_or_empty")
        if (clip1.isNullOrBlank()) return ParsedArgs.Invalid("${ARG_CLIP1_PATH}_missing_or_empty")

        val maxFrames = when (val parsed = parseOptionalInt(args, ARG_MAX_FRAMES)) {
            is OptionalInt.Absent -> AndroidTimelineDualDecoderSyncDriver.DEFAULT_MAX_FRAMES
            is OptionalInt.Present -> parsed.value
            is OptionalInt.Invalid -> return ParsedArgs.Invalid("${ARG_MAX_FRAMES}_invalid")
        }
        val overlapFrames = when (val parsed = parseOptionalInt(args, ARG_OVERLAP_FRAMES)) {
            is OptionalInt.Absent -> AndroidTimelineDualDecoderSyncDriver.DEFAULT_OVERLAP_FRAMES
            is OptionalInt.Present -> parsed.value
            is OptionalInt.Invalid -> return ParsedArgs.Invalid("${ARG_OVERLAP_FRAMES}_invalid")
        }
        val request = AndroidTimelineDualDecoderSyncDriver.Request(
            clip0Path = clip0,
            clip1Path = clip1,
            maxFrames = maxFrames,
            overlapFrames = overlapFrames,
        )
        // Range / readability checks live in the driver so both entry points
        // agree; surface them here too so a bad request never starts a thread.
        val rangeError = AndroidTimelineDualDecoderSyncDriver.validateRequest(request)
        if (rangeError != null) return ParsedArgs.Invalid(rangeError)
        return ParsedArgs.Valid(request)
    }

    private sealed class OptionalInt {
        object Absent : OptionalInt()
        class Present(val value: Int) : OptionalInt()
        object Invalid : OptionalInt()
    }

    private fun parseOptionalInt(args: Map<*, *>, key: String): OptionalInt {
        if (!args.containsKey(key)) return OptionalInt.Absent
        return when (val raw = args[key]) {
            null -> OptionalInt.Absent
            is Int -> OptionalInt.Present(raw)
            is Long -> if (raw in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) {
                OptionalInt.Present(raw.toInt())
            } else {
                OptionalInt.Invalid
            }
            else -> OptionalInt.Invalid
        }
    }

    /** Defensive defaults so the Dart side always sees the contract keys. */
    private fun normalize(raw: Map<String, Any?>): Map<String, Any?> {
        val map = LinkedHashMap(raw)
        if (map["pass"] !is Boolean) map["pass"] = false
        if (map["status"] !is String) map["status"] = if (map["pass"] == true) "PASS" else "FAIL"
        if (map["proofBoundary"] !is String) {
            map["proofBoundary"] = AndroidTimelineDualDecoderSyncDriver.PROOF_BOUNDARY
        }
        if (map["marker"] !is String) map["marker"] = AndroidTimelineDualDecoderSyncDriver.FAIL_MARKER
        if (map["failureReason"] !is String) map["failureReason"] = ""
        for (key in AndroidTimelineDualDecoderSyncDriver.GATE_KEYS) {
            if (map[key] !is Boolean) map[key] = false
        }
        if (map["allNativeLanesPass"] !is Boolean) map["allNativeLanesPass"] = false
        if (map["nativeAllLanesPass"] !is Boolean) map["nativeAllLanesPass"] = map["allNativeLanesPass"]
        if (map["details"] !is Map<*, *>) map["details"] = emptyMap<String, Any?>()
        if (map["raw"] !is String) map["raw"] = ""
        return map
    }
}
