package com.connects.vanguard_media_engine.camera

import android.content.Context
import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * P3-MULTICAM-NODE-SINGLE-CAM-INGEST-VULKAN-SPATIAL-RENDER: thin router +
 * lifecycle owner for the Flutter-visible single-camera ingest + Vulkan
 * spatial render smoke harness
 * ([AndroidCamera2SingleCamIngestVulkanSpatialSmokeHarness]).
 *
 * Unlike [AndroidCamera2SingleCamIngestSpatialSmokeCoordinator] (the GLES
 * sibling), this route is readback-only and never presents to a Flutter
 * `Texture` -- it owns no `TextureRegistry.SurfaceProducer`. Each `start()`
 * call is instead keyed by a locally-generated monotonic `runId`. The
 * harness itself tears down every Camera2 and native Vulkan resource it
 * created before `run()` returns, so this coordinator has nothing left to
 * release on completion; `dispose()` is a best-effort cancellation signal
 * only (safe to call before start, during a run, after completion, or twice
 * -- always succeeds).
 */
class AndroidCamera2SingleCamIngestVulkanSpatialSmokeCoordinator(
    private val context: Context,
    private val channel: MethodChannel,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VGCamera2SingleCamIngestVulkanSpatialSmokeCoordinator"
        private const val COMPLETE_METHOD = "onAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmokeComplete"

        private val OWNED_METHODS = setOf(
            "startAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke",
            "disposeAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    private data class ActiveEntry(
        val harness: AndroidCamera2SingleCamIngestVulkanSpatialSmokeHarness,
        val runCompleted: AtomicBoolean = AtomicBoolean(false),
    )

    private val activeEntries = mutableMapOf<Long, ActiveEntry>()
    private val nextRunId = AtomicLong(1)

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "startAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke" -> start(args, result)
            "disposeAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke" -> dispose(args, result)
            else -> return false
        }
        return true
    }

    private fun start(args: Map<*, *>?, result: MethodChannel.Result) {
        val runId = nextRunId.getAndIncrement()
        val harness = AndroidCamera2SingleCamIngestVulkanSpatialSmokeHarness(context)

        val entry = ActiveEntry(harness)
        synchronized(activeEntries) {
            activeEntries[runId] = entry
        }

        Thread {
            val smokeResult = try {
                harness.run(args)
            } catch (t: Throwable) {
                Log.e(TAG, "P3-MULTICAM-NODE-SINGLE-CAM-INGEST-VULKAN-SPATIAL-RENDER harness execution error", t)
                AndroidCamera2SingleCamIngestVulkanSpatialSmokeHarness.exceptionResult(t)
            }
            entry.runCompleted.set(true)
            synchronized(activeEntries) { activeEntries.remove(runId) }
            val finalResult = smokeResult + mapOf("runId" to runId)
            mainHandler.post {
                channel.invokeMethod(COMPLETE_METHOD, finalResult)
            }
        }.start()

        result.success(mapOf(
            "started" to true,
            "runId" to runId,
        ))
    }

    private fun dispose(args: Map<*, *>?, result: MethodChannel.Result) {
        val runId = (args?.get("runId") as? Number)?.toLong()
        if (runId == null) {
            result.error("INVALID_ARG", "disposeAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke: runId required", null)
            return
        }
        val entry = synchronized(activeEntries) { activeEntries[runId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to true,
                "runId" to runId,
                "raw" to "status=OK;already_disposed_or_not_found;runId=$runId",
            ))
            return
        }
        // Best-effort: signal cancellation in case the harness is still
        // running. The harness owns and releases every Camera2/Vulkan
        // resource it created regardless of whether cancel() was called.
        try { entry.harness.cancel() } catch (_: Throwable) {}
        result.success(mapOf(
            "pass" to true,
            "runId" to runId,
            "raw" to if (entry.runCompleted.get()) {
                "status=OK;disposed=true;runId=$runId"
            } else {
                "status=OK;dispose_requested_pending_completion;runId=$runId"
            },
        ))
    }

    fun disposeAll() {
        val entriesToDispose = synchronized(activeEntries) {
            val list = activeEntries.values.toList()
            activeEntries.clear()
            list
        }
        entriesToDispose.forEach { entry ->
            try { entry.harness.cancel() } catch (_: Throwable) {}
        }
    }
}
