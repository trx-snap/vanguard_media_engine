package com.connects.vanguard_media_engine.camera

import android.content.Context
import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean

/**
 * P3-MULTICAM-NODE-SINGLE-CAM-INGEST-DESCRIPTOR-SPATIAL-RENDER: thin router +
 * lifecycle owner for the Flutter-visible single-camera ingest + dynamic-
 * descriptor GLES/OES spatial render smoke harness
 * ([AndroidCamera2SingleCamIngestSpatialSmokeHarness]).
 *
 * Mirrors [AndroidCamera2TextureSmokeCoordinator]'s ownership pattern exactly:
 * owns the `TextureRegistry.SurfaceProducer` for each active run, keyed by
 * textureId. The harness itself never releases the producer -- this
 * coordinator's dispose path is the sole releaser. A normal completion with
 * no prior dispose() leaves the producer alive for Dart to display via a
 * Texture widget; dispose() after completion releases immediately;
 * dispose() while the harness is still running only marks the request -- the
 * start thread performs the sole release once the harness returns.
 */
class AndroidCamera2SingleCamIngestSpatialSmokeCoordinator(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
    private val channel: MethodChannel,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VGCamera2SingleCamIngestSpatialSmokeCoordinator"
        private const val COMPLETE_METHOD = "onAndroidDagPhase3SingleCamIngestSpatialRenderSmokeComplete"

        private val OWNED_METHODS = setOf(
            "startAndroidDagPhase3SingleCamIngestSpatialRenderSmoke",
            "disposeAndroidDagPhase3SingleCamIngestSpatialRenderSmoke",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    private data class ActiveEntry(
        val harness: AndroidCamera2SingleCamIngestSpatialSmokeHarness,
        val surfaceProducer: TextureRegistry.SurfaceProducer,
        val released: AtomicBoolean = AtomicBoolean(false),
        // Set by the start thread once harness.run(...) has returned.
        val runCompleted: AtomicBoolean = AtomicBoolean(false),
        // Set by dispose() when it arrives while the harness is still running;
        // tells the start thread it, not dispose(), owns the eventual release.
        val disposeRequested: AtomicBoolean = AtomicBoolean(false),
    )

    private val activeEntries = mutableMapOf<Long, ActiveEntry>()

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "startAndroidDagPhase3SingleCamIngestSpatialRenderSmoke" -> start(args, result)
            "disposeAndroidDagPhase3SingleCamIngestSpatialRenderSmoke" -> dispose(args, result)
            else -> return false
        }
        return true
    }

    private fun start(args: Map<*, *>?, result: MethodChannel.Result) {
        val surfaceProducer = textureRegistry.createSurfaceProducer()
        val textureId = surfaceProducer.id()
        val harness = AndroidCamera2SingleCamIngestSpatialSmokeHarness(context)

        val entry = ActiveEntry(harness, surfaceProducer)
        synchronized(activeEntries) {
            activeEntries[textureId] = entry
        }

        Thread {
            val smokeResult = try {
                harness.run(surfaceProducer, args)
            } catch (t: Throwable) {
                Log.e(TAG, "P3-MULTICAM-NODE-SINGLE-CAM-INGEST-DESCRIPTOR-SPATIAL-RENDER harness execution error", t)
                AndroidCamera2SingleCamIngestSpatialSmokeHarness.exceptionResult(t)
            }
            entry.runCompleted.set(true)
            // The producer is released here only if a dispose() arrived while
            // the harness was still running (disposeRequested); a normal
            // completion with no prior dispose leaves it alive for Dart.
            var released = false
            synchronized(entry) {
                if (entry.disposeRequested.get()) {
                    released = releaseOnce(entry)
                }
            }
            if (released) {
                synchronized(activeEntries) { activeEntries.remove(textureId) }
            }
            val finalResult = smokeResult + mapOf(
                "textureId" to textureId,
                "surfaceProducerReleased" to released,
            )
            mainHandler.post {
                channel.invokeMethod(COMPLETE_METHOD, finalResult)
            }
        }.start()

        result.success(mapOf(
            "started" to true,
            "textureId" to textureId,
        ))
    }

    private fun dispose(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "disposeAndroidDagPhase3SingleCamIngestSpatialRenderSmoke: textureId required", null)
            return
        }
        val entry = synchronized(activeEntries) { activeEntries[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to true,
                "textureId" to textureId,
                "surfaceProducerReleased" to false,
                "raw" to "status=OK;already_disposed_or_not_found;textureId=$textureId",
            ))
            return
        }
        // Best-effort: signal cancellation in case the harness is still running.
        try { entry.harness.cancel() } catch (_: Throwable) {}

        // Ownership: never release the producer while the harness thread may
        // still be rendering into it. If the run already finished, release
        // now; otherwise just record the request -- the start thread performs
        // the sole release once harness.run(...) returns.
        var released = false
        var completedNow = false
        synchronized(entry) {
            if (entry.runCompleted.get()) {
                released = releaseOnce(entry)
                completedNow = true
            } else {
                entry.disposeRequested.set(true)
            }
        }
        if (completedNow) {
            synchronized(activeEntries) { activeEntries.remove(textureId) }
        }
        result.success(mapOf(
            "pass" to true,
            "textureId" to textureId,
            "surfaceProducerReleased" to released,
            "raw" to if (completedNow) {
                "status=OK;disposed=true;textureId=$textureId"
            } else {
                "status=OK;dispose_requested_pending_completion;textureId=$textureId"
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
            synchronized(entry) {
                if (entry.runCompleted.get()) {
                    releaseOnce(entry)
                } else {
                    entry.disposeRequested.set(true)
                }
            }
        }
    }

    private fun releaseOnce(entry: ActiveEntry): Boolean {
        if (!entry.released.compareAndSet(false, true)) {
            return false
        }
        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            try {
                entry.surfaceProducer.release()
            } catch (t: Throwable) {
                Log.w(TAG, "surfaceProducer.release() failed: ${t.javaClass.simpleName}: ${t.message}")
            }
        } else {
            mainHandler.post {
                try {
                    entry.surfaceProducer.release()
                } catch (t: Throwable) {
                    Log.w(TAG, "surfaceProducer.release() on mainHandler failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }
        return true
    }
}
