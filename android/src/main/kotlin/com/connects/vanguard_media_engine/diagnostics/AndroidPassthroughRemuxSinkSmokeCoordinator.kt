package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.export.AndroidAudioRemuxer
import com.connects.vanguard_media_engine.export.AndroidPassthroughRemuxSampleIntegrityVerifier
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Android True-DAG P2-CPP-PASSTHROUGH: verification smoke coordinator.
 *
 * Owns [METHOD_NAME] MethodChannel route for validating native C++
 * PassthroughRemuxSinkNode DAG topology evaluation followed by real
 * MediaExtractor + MediaMuxer passthrough stream copy and sample integrity
 * verification.
 */
class AndroidPassthroughRemuxSinkSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP2CppPassthrough"
        private const val METHOD_NAME = "runAndroidDagPhase2CppPassthroughSmoke"
        private const val PROOF_BOUNDARY =
            "native_passthrough_remux_sink_node_validation_and_real_remux_sample_integrity"

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
        val sourcePath = args?.get("sourcePath") as? String
        val outputDir = args?.get("outputDir") as? String

        if (sourcePath.isNullOrBlank() || outputDir.isNullOrBlank()) {
            result.error(
                "P2_CPP_PASSTHROUGH_SMOKE_FAILED",
                "runAndroidDagPhase2CppPassthroughSmoke: 'sourcePath' and 'outputDir' required",
                null,
            )
            return
        }

        Thread {
            var generatedOutputFile: File? = null
            try {
                val srcFile = File(sourcePath)
                if (!srcFile.exists() || !srcFile.canRead()) {
                    mainHandler.post {
                        result.success(
                            makeFailedMap("source_missing_or_unreadable;sourcePath=$sourcePath")
                        )
                    }
                    return@Thread
                }

                val outDirFile = File(outputDir)
                if (!outDirFile.exists() || !outDirFile.isDirectory) {
                    mainHandler.post {
                        result.success(
                            makeFailedMap("output_dir_missing_or_not_directory;outputDir=$outputDir")
                        )
                    }
                    return@Thread
                }

                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    lifecycleObserver = VanguardLifecycleObserver(diagnostics),
                    diagnostics = diagnostics,
                    codecAdapter = null,
                )

                // ── Lane A: Native direct topology ─────────────────────────
                var directSessionId: String? = null
                var directCreateRaw = "status=FAIL;reason=not_run"
                var directValidateRaw = "status=FAIL;reason=not_run"
                var directDestroyRaw = "status=FAIL;reason=not_run"

                try {
                    directCreateRaw = nativeBridge.createAndroidDagPhase2PassthroughRemuxSinkSession(
                        sourceNodeId = "source_node",
                        sinkNodeId = "passthrough_sink",
                        startPtsUs = 0L,
                        durationUs = 1_000_000L,
                        requiresAudio = true,
                    )
                    directSessionId = extractSessionId(directCreateRaw)
                    if (directSessionId != null && directCreateRaw.startsWith("status=PASS")) {
                        directValidateRaw = nativeBridge.validateAndroidDagPhase2PassthroughRemuxSinkSession(
                            sessionId = directSessionId,
                            timelinePtsUs = 0L,
                            connectVideo = true,
                            connectAudio = true,
                            processingNodeCount = 0,
                        )
                    } else {
                        directValidateRaw = "status=FAIL;reason=session_create_failed"
                    }
                } finally {
                    if (directSessionId != null) {
                        directDestroyRaw = nativeBridge.destroyAndroidDagPhase2PassthroughRemuxSinkSession(
                            sessionId = directSessionId,
                        )
                    }
                }

                val directCreatePass = directCreateRaw.startsWith("status=PASS")
                val directValidatePass = directValidateRaw.startsWith("status=PASS") &&
                    directValidateRaw.contains("directPath=true") &&
                    directValidateRaw.contains("sinkActive=true")
                val directDestroyPass = directDestroyRaw.startsWith("status=PASS")
                val laneAPass = directCreatePass && directValidatePass && directDestroyPass

                // ── Lane B: Native ineligible topology ───────────────────────
                var ineligSessionId: String? = null
                var ineligCreateRaw = "status=FAIL;reason=not_run"
                var ineligValidateRaw = "status=FAIL;reason=not_run"
                var ineligDestroyRaw = "status=FAIL;reason=not_run"

                try {
                    ineligCreateRaw = nativeBridge.createAndroidDagPhase2PassthroughRemuxSinkSession(
                        sourceNodeId = "source_node",
                        sinkNodeId = "passthrough_sink",
                        startPtsUs = 0L,
                        durationUs = 1_000_000L,
                        requiresAudio = true,
                    )
                    ineligSessionId = extractSessionId(ineligCreateRaw)
                    if (ineligSessionId != null && ineligCreateRaw.startsWith("status=PASS")) {
                        ineligValidateRaw = nativeBridge.validateAndroidDagPhase2PassthroughRemuxSinkSession(
                            sessionId = ineligSessionId,
                            timelinePtsUs = 0L,
                            connectVideo = true,
                            connectAudio = true,
                            processingNodeCount = 1,
                        )
                    } else {
                        ineligValidateRaw = "status=FAIL;reason=session_create_failed"
                    }
                } finally {
                    if (ineligSessionId != null) {
                        ineligDestroyRaw = nativeBridge.destroyAndroidDagPhase2PassthroughRemuxSinkSession(
                            sessionId = ineligSessionId,
                        )
                    }
                }

                val ineligCreatePass = ineligCreateRaw.startsWith("status=PASS")
                val ineligValidatePass = ineligValidateRaw.startsWith("status=FAIL") &&
                    ineligValidateRaw.contains("reason=not_direct_path")
                val ineligDestroyPass = ineligDestroyRaw.startsWith("status=PASS")
                val laneBPass = ineligCreatePass && ineligValidatePass && ineligDestroyPass

                // ── Lane C: Remux-after-native-pass ──────────────────────────
                var remuxExecutedAfterNativePass = false
                val ineligibleRemuxExecuted = false
                var remuxSuccess = false
                var remuxReason = "not_executed"
                var videoSamples = 0
                var audioSamples = 0
                var outputSizeBytes = 0L
                var videoIntegrityMap: Map<String, Any?>? = null
                var audioIntegrityMap: Map<String, Any?>? = null
                var laneCPass = false

                try {
                    if (laneAPass) {
                        remuxExecutedAfterNativePass = true
                        val timestamp = System.currentTimeMillis()
                        val finalFile = File(outDirFile, "p2_cpp_passthrough_${timestamp}.mp4")
                        generatedOutputFile = finalFile
                        val finalPath = finalFile.absolutePath

                        val remuxResult = AndroidAudioRemuxer.remux(
                            videoPath = sourcePath,
                            audioPath = sourcePath,
                            finalPath = finalPath,
                        )

                        remuxSuccess = remuxResult.success
                        remuxReason = remuxResult.reason
                        videoSamples = remuxResult.videoSamples
                        audioSamples = remuxResult.audioSamples
                        outputSizeBytes = remuxResult.outputSizeBytes

                        if (remuxResult.success) {
                            val videoIntegrity = AndroidPassthroughRemuxSampleIntegrityVerifier.compareTrack(
                                sourcePath = sourcePath,
                                outputPath = finalPath,
                                mimePrefix = "video/",
                                trackType = "video",
                            )
                            val audioIntegrity = AndroidPassthroughRemuxSampleIntegrityVerifier.compareTrack(
                                sourcePath = sourcePath,
                                outputPath = finalPath,
                                mimePrefix = "audio/",
                                trackType = "audio",
                            )
                            videoIntegrityMap = videoIntegrity.toMap()
                            audioIntegrityMap = audioIntegrity.toMap()

                            laneCPass = videoIntegrity.pass &&
                                audioIntegrity.pass &&
                                remuxResult.videoSamples > 0 &&
                                remuxResult.audioSamples > 0 &&
                                remuxResult.outputSizeBytes > 0L
                        }
                    }
                } finally {
                    if (generatedOutputFile != null) {
                        try {
                            if (generatedOutputFile.exists()) {
                                generatedOutputFile.delete()
                            }
                        } catch (_: Throwable) {}
                    }
                }

                val overallPass = laneAPass && laneBPass && laneCPass

                val payload = mapOf(
                    "pass" to overallPass,
                    "proofBoundary" to PROOF_BOUNDARY,
                    "nativeDirectRaw" to directValidateRaw,
                    "nativeDirectDestroyRaw" to directDestroyRaw,
                    "nativeIneligibleRaw" to ineligValidateRaw,
                    "nativeIneligibleDestroyRaw" to ineligDestroyRaw,
                    "remuxExecutedAfterNativePass" to remuxExecutedAfterNativePass,
                    "ineligibleRemuxExecuted" to ineligibleRemuxExecuted,
                    "remuxSuccess" to remuxSuccess,
                    "remuxReason" to remuxReason,
                    "videoSamples" to videoSamples,
                    "audioSamples" to audioSamples,
                    "outputSizeBytes" to outputSizeBytes,
                    "videoIntegrity" to videoIntegrityMap,
                    "audioIntegrity" to audioIntegrityMap,
                    "nonClaims" to makeNonClaims(),
                )

                mainHandler.post {
                    result.success(payload)
                }
            } catch (t: Throwable) {
                Log.e(TAG, "runAndroidDagPhase2CppPassthroughSmoke failed", t)
                mainHandler.post {
                    result.success(
                        makeFailedMap("exception:${t.javaClass.simpleName}:${t.message}")
                    )
                }
            } finally {
                if (generatedOutputFile != null) {
                    try {
                        if (generatedOutputFile.exists()) {
                            generatedOutputFile.delete()
                        }
                    } catch (_: Throwable) {}
                }
            }
        }.start()
    }

    private fun extractSessionId(raw: String): String? {
        val parts = raw.split(";")
        for (part in parts) {
            val kv = part.split("=")
            if (kv.size == 2 && kv[0] == "sessionId") {
                return kv[1]
            }
        }
        return null
    }

    private fun makeNonClaims(): Map<String, Boolean> = mapOf(
        "productionExportRouteRefactor" to false,
        "roiSidecarOrdering" to false,
        "productMultiClipTimelinePresentation" to false,
        "appWiring" to false,
        "p2AudioDecBridge" to false,
        "streamingCache" to false,
        "editorPlayback" to false,
        "iOS" to false,
        "ndkMuxing" to false,
    )

    private fun makeFailedMap(reason: String): Map<String, Any?> = mapOf(
        "pass" to false,
        "proofBoundary" to PROOF_BOUNDARY,
        "nativeDirectRaw" to "status=FAIL;reason=$reason",
        "nativeDirectDestroyRaw" to "status=FAIL;reason=$reason",
        "nativeIneligibleRaw" to "status=FAIL;reason=$reason",
        "nativeIneligibleDestroyRaw" to "status=FAIL;reason=$reason",
        "remuxExecutedAfterNativePass" to false,
        "ineligibleRemuxExecuted" to false,
        "remuxSuccess" to false,
        "remuxReason" to reason,
        "videoSamples" to 0,
        "audioSamples" to 0,
        "outputSizeBytes" to 0L,
        "videoIntegrity" to null,
        "audioIntegrity" to null,
        "nonClaims" to makeNonClaims(),
    )
}
