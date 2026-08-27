package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Phase 1-Unit AX: thin router + lifecycle owner for the Flutter-visible
 * Android GLES SurfaceProducer texture DAG render smoke harness
 * ([AndroidGlesTextureDagRenderSmokeHarness]).
 *
 * Owns the `TextureRegistry.SurfaceProducer` for each active run, keyed by
 * textureId. The harness itself never releases the producer — this
 * coordinator's dispose path is the sole releaser. Mirrors
 * AndroidCamera2TextureSmokeCoordinator's ownership pattern: a completion
 * with no prior dispose() leaves the producer alive for Dart to display via
 * a Texture widget; dispose() after completion releases immediately;
 * dispose() while the harness is still running only marks the request — the
 * start thread performs the sole release once the harness returns.
 */
class AndroidGlesTextureSmokeCoordinator(
    private val textureRegistry: TextureRegistry,
    private val channel: MethodChannel,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VGGlesTextureSmokeCoordinator"
        private const val COMPLETE_METHOD = "onAndroidDagPhase1AXGlesTextureRenderSmokeComplete"

        // Phase 1-Unit BA: SurfaceProducer two-texture (AS RGBA + AT mixed
        // OES/2D) compositor physical proof, combined into one callback.
        private const val BA_COMPLETE_METHOD = "onAndroidDagPhase1BAGlesTextureCompositorSmokeComplete"
        private const val BA_DEFAULT_DIMENSION = 64
        private const val BA_PROOF_BOUNDARY =
            "gles_surfaceproducer_two_texture_compositor_foundation_no_decoded_input_no_product_ui"

        private val OWNED_METHODS = setOf(
            "startAndroidDagPhase1AXGlesTextureRenderSmoke",
            "disposeAndroidDagPhase1AXGlesTextureRenderSmoke",
            "startAndroidDagPhase1BAGlesTextureCompositorSmoke",
            "disposeAndroidDagPhase1BAGlesTextureCompositorSmoke",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    private data class ActiveEntry(
        val harness: AndroidGlesTextureDagRenderSmokeHarness,
        val surfaceProducer: TextureRegistry.SurfaceProducer,
        val released: AtomicBoolean = AtomicBoolean(false),
        // Set by the start thread once harness.run(...) has returned.
        val runCompleted: AtomicBoolean = AtomicBoolean(false),
        // Set by dispose() when it arrives while the harness is still running;
        // tells the start thread it, not dispose(), owns the eventual release.
        val disposeRequested: AtomicBoolean = AtomicBoolean(false),
    )

    private val activeEntries = mutableMapOf<Long, ActiveEntry>()

    // Phase 1-Unit BA: kept separate from [activeEntries] so AX and BA
    // texture IDs can never collide in state ownership, even though both are
    // keyed by SurfaceProducer id.
    private data class BaActiveEntry(
        val surfaceProducer: TextureRegistry.SurfaceProducer,
        val released: AtomicBoolean = AtomicBoolean(false),
        val runCompleted: AtomicBoolean = AtomicBoolean(false),
        val disposeRequested: AtomicBoolean = AtomicBoolean(false),
    )

    private val baActiveEntries = mutableMapOf<Long, BaActiveEntry>()

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "startAndroidDagPhase1AXGlesTextureRenderSmoke" -> start(args, result)
            "disposeAndroidDagPhase1AXGlesTextureRenderSmoke" -> dispose(args, result)
            "startAndroidDagPhase1BAGlesTextureCompositorSmoke" -> startBa(args, result)
            "disposeAndroidDagPhase1BAGlesTextureCompositorSmoke" -> disposeBa(args, result)
            else -> return false
        }
        return true
    }

    private fun start(args: Map<*, *>?, result: MethodChannel.Result) {
        val surfaceProducer = textureRegistry.createSurfaceProducer()
        val textureId = surfaceProducer.id()
        val harness = AndroidGlesTextureDagRenderSmokeHarness()

        val entry = ActiveEntry(harness, surfaceProducer)
        synchronized(activeEntries) {
            activeEntries[textureId] = entry
        }

        Thread {
            val smokeResult = try {
                harness.run(surfaceProducer, args)
            } catch (t: Throwable) {
                Log.e(TAG, "Phase 1-Unit AX harness execution error", t)
                AndroidGlesTextureDagRenderSmokeHarness.exceptionResult(t)
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
            result.error("INVALID_ARG", "disposeAndroidDagPhase1AXGlesTextureRenderSmoke: textureId required", null)
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

        // Ownership: never release the producer while the harness thread may
        // still be rendering into it. If the run already finished, release
        // now; otherwise just record the request — the start thread performs
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
            synchronized(entry) {
                if (entry.runCompleted.get()) {
                    releaseOnce(entry)
                } else {
                    entry.disposeRequested.set(true)
                }
            }
        }

        val baEntriesToDispose = synchronized(baActiveEntries) {
            val list = baActiveEntries.values.toList()
            baActiveEntries.clear()
            list
        }
        baEntriesToDispose.forEach { entry ->
            synchronized(entry) {
                if (entry.runCompleted.get()) {
                    releaseOnceBa(entry)
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
        if (Looper.myLooper() == Looper.getMainLooper()) {
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

    // ── Phase 1-Unit BA: SurfaceProducer two-texture (AS+AT) compositor smoke ──

    private fun startBa(args: Map<*, *>?, result: MethodChannel.Result) {
        val widthArg = (args?.get("width") as? Number)?.toInt()
        val heightArg = (args?.get("height") as? Number)?.toInt()
        if (widthArg != null && widthArg <= 0) {
            result.error("INVALID_ARG", "startAndroidDagPhase1BAGlesTextureCompositorSmoke: width must be positive", null)
            return
        }
        if (heightArg != null && heightArg <= 0) {
            result.error("INVALID_ARG", "startAndroidDagPhase1BAGlesTextureCompositorSmoke: height must be positive", null)
            return
        }
        val width = widthArg ?: BA_DEFAULT_DIMENSION
        val height = heightArg ?: BA_DEFAULT_DIMENSION

        val surfaceProducer = textureRegistry.createSurfaceProducer()
        val textureId = surfaceProducer.id()
        val entry = BaActiveEntry(surfaceProducer)
        synchronized(baActiveEntries) {
            baActiveEntries[textureId] = entry
        }

        Thread {
            var producerSurface: Surface? = null
            var asResult: Map<String, Any?> = baNotRunResult()
            var atResult: Map<String, Any?> = baNotRunResult()
            var thrown: Throwable? = null
            try {
                surfaceProducer.setSize(width, height)
                val surface = surfaceProducer.getSurface()
                producerSurface = surface
                asResult = try {
                    AndroidGlesTwoTextureCompositorSmokeHarness.runGlesTwoTextureCompositorSmokeForSurface(surface, width, height)
                } catch (t: Throwable) {
                    Log.e(TAG, "Phase 1-Unit BA AS lane execution error", t)
                    baLaneFailureResult(t)
                }
                atResult = try {
                    AndroidGlesTwoTextureCompositorSmokeHarness.runGlesMixedTextureCompositorSmokeForSurface(surface, width, height)
                } catch (t: Throwable) {
                    Log.e(TAG, "Phase 1-Unit BA AT lane execution error", t)
                    baLaneFailureResult(t)
                }
            } catch (t: Throwable) {
                Log.e(TAG, "Phase 1-Unit BA surface acquisition error", t)
                thrown = t
                asResult = baLaneFailureResult(t)
                atResult = baLaneFailureResult(t)
            } finally {
                // The Surface obtained from the SurfaceProducer is owned by
                // this coordinator, not the harness (which never releases a
                // caller-provided Surface) — release it once AS/AT finish.
                // The SurfaceProducer itself is released only via
                // releaseOnceBa()'s dispose-driven lifecycle below.
                try {
                    producerSurface?.release()
                } catch (_: Throwable) {
                }
            }

            entry.runCompleted.set(true)
            var released = false
            synchronized(entry) {
                if (entry.disposeRequested.get()) {
                    released = releaseOnceBa(entry)
                }
            }
            if (released) {
                synchronized(baActiveEntries) { baActiveEntries.remove(textureId) }
            }

            val asPass = asResult["pass"] == true
            val atPass = atResult["pass"] == true
            val overallPass = thrown == null && asPass && atPass
            val raw = "status=${if (overallPass) "PASS" else "FAIL"};asPass=$asPass;atPass=$atPass;textureId=$textureId;width=$width;height=$height" +
                (thrown?.let { ";lastError=exception:${it.javaClass.simpleName.ifEmpty { "unknown_exception" }}" } ?: "")

            val finalResult = mapOf(
                "pass" to overallPass,
                "textureId" to textureId,
                "surfaceProducerReleased" to released,
                "asResult" to asResult,
                "atResult" to atResult,
                "width" to width,
                "height" to height,
                "proofBoundary" to BA_PROOF_BOUNDARY,
                "raw" to raw,
            )
            mainHandler.post {
                channel.invokeMethod(BA_COMPLETE_METHOD, finalResult)
            }
        }.start()

        result.success(mapOf(
            "started" to true,
            "textureId" to textureId,
        ))
    }

    private fun disposeBa(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "disposeAndroidDagPhase1BAGlesTextureCompositorSmoke: textureId required", null)
            return
        }
        val entry = synchronized(baActiveEntries) { baActiveEntries[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to true,
                "textureId" to textureId,
                "surfaceProducerReleased" to false,
                "raw" to "status=OK;already_disposed_or_not_found;textureId=$textureId",
            ))
            return
        }

        // Same ownership rule as AX's dispose(): never release the producer
        // while the worker thread may still be rendering into it.
        var released = false
        var completedNow = false
        synchronized(entry) {
            if (entry.runCompleted.get()) {
                released = releaseOnceBa(entry)
                completedNow = true
            } else {
                entry.disposeRequested.set(true)
            }
        }
        if (completedNow) {
            synchronized(baActiveEntries) { baActiveEntries.remove(textureId) }
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

    private fun releaseOnceBa(entry: BaActiveEntry): Boolean {
        if (!entry.released.compareAndSet(false, true)) {
            return false
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            try {
                entry.surfaceProducer.release()
            } catch (t: Throwable) {
                Log.w(TAG, "BA surfaceProducer.release() failed: ${t.javaClass.simpleName}: ${t.message}")
            }
        } else {
            mainHandler.post {
                try {
                    entry.surfaceProducer.release()
                } catch (t: Throwable) {
                    Log.w(TAG, "BA surfaceProducer.release() on mainHandler failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }
        return true
    }

    private fun baNotRunResult(): Map<String, Any?> = mapOf(
        "pass" to false,
        "raw" to "status=FAIL;lastError=not_run",
        "lastError" to "not_run",
    )

    private fun baLaneFailureResult(t: Throwable): Map<String, Any?> {
        val reason = "exception:${t.javaClass.simpleName.ifEmpty { "unknown_exception" }}"
        return mapOf(
            "pass" to false,
            "raw" to "status=FAIL;lastError=$reason",
            "lastError" to reason,
        )
    }
}
