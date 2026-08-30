package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import com.connects.vanguard_media_engine.codec.AndroidMultiStreamDecodeCoordinator
import com.connects.vanguard_media_engine.codec.AndroidMultiStreamDecodeRequest
import com.connects.vanguard_media_engine.codec.AndroidMultiStreamDecodeStreamSpec
import io.flutter.plugin.common.MethodChannel

/**
 * Android True-DAG P2-CONCURRENT-DEC: verification smoke coordinator.
 *
 * Owns [METHOD_NAME] MethodChannel route for testing concurrent hardware
 * decoding of 2+ video streams. Parses arguments, runs the decode session on a
 * background thread, and posts results back to [mainHandler].
 */
class AndroidConcurrentDecodeSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val METHOD_NAME = "runAndroidDagPhase2ConcurrentDecodeSmoke"

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

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

    private fun runSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val rawStreams = args?.get("streams") as? List<*>
        if (rawStreams == null || rawStreams.size < 2) {
            result.error(
                "P2_CONCURRENT_DECODE_SMOKE_FAILED",
                "runAndroidDagPhase2ConcurrentDecodeSmoke: 'streams' list with at least 2 entries required",
                null,
            )
            return
        }

        val specs = mutableListOf<AndroidMultiStreamDecodeStreamSpec>()
        for ((index, item) in rawStreams.withIndex()) {
            val map = item as? Map<*, *>
            if (map == null) {
                result.error(
                    "P2_CONCURRENT_DECODE_SMOKE_FAILED",
                    "runAndroidDagPhase2ConcurrentDecodeSmoke: stream at index $index is not a Map",
                    null,
                )
                return
            }
            val sourceNodeId = map["sourceNodeId"] as? String
            val path = map["path"] as? String
            val frameCount = (map["frameCount"] as? Number)?.toInt()

            if (sourceNodeId.isNullOrEmpty() || path.isNullOrEmpty() || frameCount == null || frameCount <= 0) {
                result.error(
                    "P2_CONCURRENT_DECODE_SMOKE_FAILED",
                    "runAndroidDagPhase2ConcurrentDecodeSmoke: invalid stream spec at index $index: sourceNodeId=$sourceNodeId, path=$path, frameCount=$frameCount",
                    null,
                )
                return
            }

            specs.add(AndroidMultiStreamDecodeStreamSpec(sourceNodeId, path, frameCount))
        }

        val generationId = (args["generationId"] as? Number)?.toLong() ?: 1L
        val request = AndroidMultiStreamDecodeRequest(specs, generationId)

        Thread {
            try {
                val coordinator = AndroidMultiStreamDecodeCoordinator()
                val smokeResult = coordinator.run(request)
                mainHandler.post {
                    result.success(smokeResult)
                }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "P2_CONCURRENT_DECODE_SMOKE_FAILED",
                        "runAndroidDagPhase2ConcurrentDecodeSmoke failed with exception: ${t.message}",
                        t.stackTraceToString(),
                    )
                }
            }
        }.start()
    }
}
