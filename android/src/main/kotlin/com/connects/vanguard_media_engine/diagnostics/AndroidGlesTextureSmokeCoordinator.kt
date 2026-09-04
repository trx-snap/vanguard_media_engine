package com.connects.vanguard_media_engine.diagnostics

import android.hardware.HardwareBuffer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
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

        // Phase 1-Unit BB: SurfaceProducer two-source composition DAG +
        // playhead evaluation physical proof.
        private const val BB_COMPLETE_METHOD = "onAndroidDagPhase1BBGlesTextureCompositionDagSmokeComplete"

        // Phase 1-Unit AW-OES: decoded SurfaceTexture/OES DAG render
        // foundation physical proof.
        private const val AW_OES_COMPLETE_METHOD = "onAndroidDagPhase1AWOESGlesDecodedOesSmokeComplete"

        // P3-MULTICAM-NODE: GLES-first spatial multi-texture diagnostic
        // render pass physical proof.
        private const val SPATIAL_COMPLETE_METHOD = "onAndroidDagPhase3MultiCamSpatialGlesRenderSmokeComplete"
        private const val SPATIAL_DEFAULT_DIMENSION = 128
        private const val SPATIAL_PROOF_BOUNDARY =
            "native_multicam_spatial_gles_two_texture_layout_render_readback_only_no_vulkan_no_camera_no_oes_proof_no_opacity_no_corner_radius_no_recording_no_product"

        // P3-MULTICAM-NODE-GLES-OES-SPATIAL-RENDER: bounded OES extension of
        // the spatial route above. Allocation/execution/parsing lives in
        // [AndroidMultiCamSpatialGlesOesSmokeHarness]; this coordinator only
        // owns SurfaceProducer creation/threading/dispose bookkeeping.
        private const val OES_COMPLETE_METHOD = "onAndroidDagPhase3MultiCamSpatialGlesOesRenderSmokeComplete"
        private const val OES_DEFAULT_DIMENSION = 128

        private val OWNED_METHODS = setOf(
            "startAndroidDagPhase1AXGlesTextureRenderSmoke",
            "disposeAndroidDagPhase1AXGlesTextureRenderSmoke",
            "startAndroidDagPhase1BAGlesTextureCompositorSmoke",
            "disposeAndroidDagPhase1BAGlesTextureCompositorSmoke",
            "startAndroidDagPhase1BBGlesTextureCompositionDagSmoke",
            "disposeAndroidDagPhase1BBGlesTextureCompositionDagSmoke",
            "startAndroidDagPhase1AWOESGlesDecodedOesSmoke",
            "disposeAndroidDagPhase1AWOESGlesDecodedOesSmoke",
            "startAndroidDagPhase3MultiCamSpatialGlesRenderSmoke",
            "disposeAndroidDagPhase3MultiCamSpatialGlesRenderSmoke",
            "startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke",
            "disposeAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke",
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

    // Phase 1-Unit BB: kept separate from [activeEntries] and
    // [baActiveEntries] so AX/BA/BB texture IDs can never collide in state
    // ownership, even though all are keyed by SurfaceProducer id.
    private data class BbActiveEntry(
        val harness: AndroidGlesTextureCompositionDagSmokeHarness,
        val surfaceProducer: TextureRegistry.SurfaceProducer,
        val released: AtomicBoolean = AtomicBoolean(false),
        val runCompleted: AtomicBoolean = AtomicBoolean(false),
        val disposeRequested: AtomicBoolean = AtomicBoolean(false),
    )

    private val bbActiveEntries = mutableMapOf<Long, BbActiveEntry>()

    // Phase 1-Unit AW-OES: kept separate from all entries above so AX/BA/BB/
    // AW-OES texture IDs can never collide in state ownership, even though
    // all are keyed by SurfaceProducer id.
    private data class AwOesActiveEntry(
        val harness: AndroidGlesDecodedOesSmokeHarness,
        val surfaceProducer: TextureRegistry.SurfaceProducer,
        val released: AtomicBoolean = AtomicBoolean(false),
        val runCompleted: AtomicBoolean = AtomicBoolean(false),
        val disposeRequested: AtomicBoolean = AtomicBoolean(false),
    )

    private val awOesActiveEntries = mutableMapOf<Long, AwOesActiveEntry>()

    // P3-MULTICAM-NODE: kept separate from all entries above so AX/BA/BB/
    // AW-OES/spatial texture IDs can never collide in state ownership, even
    // though all are keyed by SurfaceProducer id. No harness object is
    // owned here -- the native call is made directly on the worker thread,
    // matching the "extend the coordinator, not plugin dispatch" contract.
    private data class SpatialActiveEntry(
        val surfaceProducer: TextureRegistry.SurfaceProducer,
        val released: AtomicBoolean = AtomicBoolean(false),
        val runCompleted: AtomicBoolean = AtomicBoolean(false),
        val disposeRequested: AtomicBoolean = AtomicBoolean(false),
    )

    private val spatialActiveEntries = mutableMapOf<Long, SpatialActiveEntry>()

    // P3-MULTICAM-NODE-GLES-OES-SPATIAL-RENDER: kept separate from all
    // entries above so no texture id ownership can ever collide, even
    // though all are keyed by SurfaceProducer id.
    private data class OesActiveEntry(
        val surfaceProducer: TextureRegistry.SurfaceProducer,
        val released: AtomicBoolean = AtomicBoolean(false),
        val runCompleted: AtomicBoolean = AtomicBoolean(false),
        val disposeRequested: AtomicBoolean = AtomicBoolean(false),
    )

    private val oesActiveEntries = mutableMapOf<Long, OesActiveEntry>()

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "startAndroidDagPhase1AXGlesTextureRenderSmoke" -> start(args, result)
            "disposeAndroidDagPhase1AXGlesTextureRenderSmoke" -> dispose(args, result)
            "startAndroidDagPhase1BAGlesTextureCompositorSmoke" -> startBa(args, result)
            "disposeAndroidDagPhase1BAGlesTextureCompositorSmoke" -> disposeBa(args, result)
            "startAndroidDagPhase1BBGlesTextureCompositionDagSmoke" -> startBb(args, result)
            "disposeAndroidDagPhase1BBGlesTextureCompositionDagSmoke" -> disposeBb(args, result)
            "startAndroidDagPhase1AWOESGlesDecodedOesSmoke" -> startAwOes(args, result)
            "disposeAndroidDagPhase1AWOESGlesDecodedOesSmoke" -> disposeAwOes(args, result)
            "startAndroidDagPhase3MultiCamSpatialGlesRenderSmoke" -> startSpatial(args, result)
            "disposeAndroidDagPhase3MultiCamSpatialGlesRenderSmoke" -> disposeSpatial(args, result)
            "startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke" -> startOes(args, result)
            "disposeAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke" -> disposeOes(args, result)
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

        val bbEntriesToDispose = synchronized(bbActiveEntries) {
            val list = bbActiveEntries.values.toList()
            bbActiveEntries.clear()
            list
        }
        bbEntriesToDispose.forEach { entry ->
            synchronized(entry) {
                if (entry.runCompleted.get()) {
                    releaseOnceBb(entry)
                } else {
                    entry.disposeRequested.set(true)
                }
            }
        }

        val awOesEntriesToDispose = synchronized(awOesActiveEntries) {
            val list = awOesActiveEntries.values.toList()
            awOesActiveEntries.clear()
            list
        }
        awOesEntriesToDispose.forEach { entry ->
            synchronized(entry) {
                if (entry.runCompleted.get()) {
                    releaseOnceAwOes(entry)
                } else {
                    entry.disposeRequested.set(true)
                    entry.harness.cancel()
                }
            }
        }

        val spatialEntriesToDispose = synchronized(spatialActiveEntries) {
            val list = spatialActiveEntries.values.toList()
            spatialActiveEntries.clear()
            list
        }
        spatialEntriesToDispose.forEach { entry ->
            synchronized(entry) {
                if (entry.runCompleted.get()) {
                    releaseOnceSpatial(entry)
                } else {
                    entry.disposeRequested.set(true)
                }
            }
        }

        val oesEntriesToDispose = synchronized(oesActiveEntries) {
            val list = oesActiveEntries.values.toList()
            oesActiveEntries.clear()
            list
        }
        oesEntriesToDispose.forEach { entry ->
            synchronized(entry) {
                if (entry.runCompleted.get()) {
                    releaseOnceOes(entry)
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

    // ── Phase 1-Unit BB: SurfaceProducer two-source composition DAG smoke ──

    private fun startBb(args: Map<*, *>?, result: MethodChannel.Result) {
        val widthArg = (args?.get("width") as? Number)?.toInt()
        val heightArg = (args?.get("height") as? Number)?.toInt()
        val frameCountArg = (args?.get("frameCount") as? Number)?.toInt()
        val frameDurationUsArg = (args?.get("frameDurationUs") as? Number)?.toLong()
        if (widthArg != null && widthArg <= 0) {
            result.error("INVALID_ARG", "startAndroidDagPhase1BBGlesTextureCompositionDagSmoke: width must be positive", null)
            return
        }
        if (heightArg != null && heightArg <= 0) {
            result.error("INVALID_ARG", "startAndroidDagPhase1BBGlesTextureCompositionDagSmoke: height must be positive", null)
            return
        }
        if (frameCountArg != null && frameCountArg <= 0) {
            result.error("INVALID_ARG", "startAndroidDagPhase1BBGlesTextureCompositionDagSmoke: frameCount must be positive", null)
            return
        }
        if (frameDurationUsArg != null && frameDurationUsArg <= 0) {
            result.error("INVALID_ARG", "startAndroidDagPhase1BBGlesTextureCompositionDagSmoke: frameDurationUs must be positive", null)
            return
        }

        val surfaceProducer = textureRegistry.createSurfaceProducer()
        val textureId = surfaceProducer.id()
        val harness = AndroidGlesTextureCompositionDagSmokeHarness()

        val entry = BbActiveEntry(harness, surfaceProducer)
        synchronized(bbActiveEntries) {
            bbActiveEntries[textureId] = entry
        }

        Thread {
            val smokeResult = try {
                harness.run(surfaceProducer, args)
            } catch (t: Throwable) {
                Log.e(TAG, "Phase 1-Unit BB harness execution error", t)
                AndroidGlesTextureCompositionDagSmokeHarness.exceptionResult(t)
            }
            entry.runCompleted.set(true)
            // Same ownership rule as AX: the producer is released here only if
            // a dispose() arrived while the harness was still running; a
            // normal completion with no prior dispose leaves it alive for Dart.
            var released = false
            synchronized(entry) {
                if (entry.disposeRequested.get()) {
                    released = releaseOnceBb(entry)
                }
            }
            if (released) {
                synchronized(bbActiveEntries) { bbActiveEntries.remove(textureId) }
            }
            val finalResult = smokeResult + mapOf(
                "textureId" to textureId,
                "surfaceProducerReleased" to released,
            )
            mainHandler.post {
                channel.invokeMethod(BB_COMPLETE_METHOD, finalResult)
            }
        }.start()

        result.success(mapOf(
            "started" to true,
            "textureId" to textureId,
        ))
    }

    private fun disposeBb(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "disposeAndroidDagPhase1BBGlesTextureCompositionDagSmoke: textureId required", null)
            return
        }
        val entry = synchronized(bbActiveEntries) { bbActiveEntries[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to true,
                "textureId" to textureId,
                "surfaceProducerReleased" to false,
                "raw" to "status=OK;already_disposed_or_not_found;textureId=$textureId",
            ))
            return
        }

        var released = false
        var completedNow = false
        synchronized(entry) {
            if (entry.runCompleted.get()) {
                released = releaseOnceBb(entry)
                completedNow = true
            } else {
                entry.disposeRequested.set(true)
            }
        }
        if (completedNow) {
            synchronized(bbActiveEntries) { bbActiveEntries.remove(textureId) }
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

    private fun releaseOnceBb(entry: BbActiveEntry): Boolean {
        if (!entry.released.compareAndSet(false, true)) {
            return false
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            try {
                entry.surfaceProducer.release()
            } catch (t: Throwable) {
                Log.w(TAG, "BB surfaceProducer.release() failed: ${t.javaClass.simpleName}: ${t.message}")
            }
        } else {
            mainHandler.post {
                try {
                    entry.surfaceProducer.release()
                } catch (t: Throwable) {
                    Log.w(TAG, "BB surfaceProducer.release() on mainHandler failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }
        return true
    }

    // ── Phase 1-Unit AW-OES: decoded SurfaceTexture/OES DAG render smoke ──

    private fun startAwOes(args: Map<*, *>?, result: MethodChannel.Result) {
        val videoPath = args?.get("videoPath") as? String
        if (videoPath.isNullOrEmpty()) {
            result.error("INVALID_ARG", "startAndroidDagPhase1AWOESGlesDecodedOesSmoke: videoPath required", null)
            return
        }
        val maxFramesArg = (args.get("maxFrames") as? Number)?.toInt()
        if (maxFramesArg != null && maxFramesArg <= 0) {
            result.error("INVALID_ARG", "startAndroidDagPhase1AWOESGlesDecodedOesSmoke: maxFrames must be positive", null)
            return
        }

        val surfaceProducer = textureRegistry.createSurfaceProducer()
        val textureId = surfaceProducer.id()
        val harness = AndroidGlesDecodedOesSmokeHarness()

        val entry = AwOesActiveEntry(harness, surfaceProducer)
        synchronized(awOesActiveEntries) {
            awOesActiveEntries[textureId] = entry
        }

        Thread {
            val smokeResult = try {
                harness.run(surfaceProducer, args)
            } catch (t: Throwable) {
                Log.e(TAG, "Phase 1-Unit AW-OES harness execution error", t)
                AndroidGlesDecodedOesSmokeHarness.exceptionResult(t)
            }
            entry.runCompleted.set(true)
            // Same ownership rule as AX/BB: the producer is released here
            // only if a dispose() arrived while the harness was still
            // running; a normal completion with no prior dispose leaves it
            // alive for Dart to display via a Texture widget.
            var released = false
            synchronized(entry) {
                if (entry.disposeRequested.get()) {
                    released = releaseOnceAwOes(entry)
                }
            }
            if (released) {
                synchronized(awOesActiveEntries) { awOesActiveEntries.remove(textureId) }
            }
            val finalResult = smokeResult + mapOf(
                "textureId" to textureId,
                "surfaceProducerReleased" to released,
            )
            mainHandler.post {
                channel.invokeMethod(AW_OES_COMPLETE_METHOD, finalResult)
            }
        }.start()

        result.success(mapOf(
            "started" to true,
            "textureId" to textureId,
        ))
    }

    private fun disposeAwOes(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "disposeAndroidDagPhase1AWOESGlesDecodedOesSmoke: textureId required", null)
            return
        }
        val entry = synchronized(awOesActiveEntries) { awOesActiveEntries[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to true,
                "textureId" to textureId,
                "surfaceProducerReleased" to false,
                "raw" to "status=OK;already_disposed_or_not_found;textureId=$textureId",
            ))
            return
        }

        // Same ownership rule as AX/BB's dispose(): never release the
        // producer while the worker thread may still be rendering into it.
        // Unlike AX/BB, the AW-OES harness also honors an explicit cancel()
        // request so its MediaCodec decode loop can exit early instead of
        // always running to completion.
        var released = false
        var completedNow = false
        synchronized(entry) {
            if (entry.runCompleted.get()) {
                released = releaseOnceAwOes(entry)
                completedNow = true
            } else {
                entry.disposeRequested.set(true)
                entry.harness.cancel()
            }
        }
        if (completedNow) {
            synchronized(awOesActiveEntries) { awOesActiveEntries.remove(textureId) }
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

    private fun releaseOnceAwOes(entry: AwOesActiveEntry): Boolean {
        if (!entry.released.compareAndSet(false, true)) {
            return false
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            try {
                entry.surfaceProducer.release()
            } catch (t: Throwable) {
                Log.w(TAG, "AW-OES surfaceProducer.release() failed: ${t.javaClass.simpleName}: ${t.message}")
            }
        } else {
            mainHandler.post {
                try {
                    entry.surfaceProducer.release()
                } catch (t: Throwable) {
                    Log.w(TAG, "AW-OES surfaceProducer.release() on mainHandler failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }
        return true
    }

    // ── P3-MULTICAM-NODE: GLES-first spatial multi-texture diagnostic render pass ──

    private fun startSpatial(args: Map<*, *>?, result: MethodChannel.Result) {
        val widthArg = (args?.get("width") as? Number)?.toInt()
        val heightArg = (args?.get("height") as? Number)?.toInt()
        if (widthArg != null && widthArg <= 0) {
            result.error("INVALID_ARG", "startAndroidDagPhase3MultiCamSpatialGlesRenderSmoke: width must be positive", null)
            return
        }
        if (heightArg != null && heightArg <= 0) {
            result.error("INVALID_ARG", "startAndroidDagPhase3MultiCamSpatialGlesRenderSmoke: height must be positive", null)
            return
        }
        val width = widthArg ?: SPATIAL_DEFAULT_DIMENSION
        val height = heightArg ?: SPATIAL_DEFAULT_DIMENSION

        val surfaceProducer = textureRegistry.createSurfaceProducer()
        val textureId = surfaceProducer.id()
        val entry = SpatialActiveEntry(surfaceProducer)
        synchronized(spatialActiveEntries) {
            spatialActiveEntries[textureId] = entry
        }

        Thread {
            var producerSurface: Surface? = null
            var bufferA: HardwareBuffer? = null
            var bufferB: HardwareBuffer? = null
            var raw = spatialFailureResult("not_run")
            try {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    raw = spatialFailureResult("api_below_26")
                } else {
                    surfaceProducer.setSize(width, height)
                    val surface = surfaceProducer.getSurface()
                    producerSurface = surface

                    val allocatedBufferA = HardwareBuffer.create(
                        width,
                        height,
                        HardwareBuffer.RGBA_8888,
                        1,
                        HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
                    )
                    bufferA = allocatedBufferA
                    val allocatedBufferB = HardwareBuffer.create(
                        width,
                        height,
                        HardwareBuffer.RGBA_8888,
                        1,
                        HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
                    )
                    bufferB = allocatedBufferB

                    val diagnostics = VanguardDiagnostics()
                    val nativeBridge = VanguardNativeBridge(
                        VanguardLifecycleObserver(diagnostics),
                        diagnostics,
                        null,
                    )
                    raw = nativeBridge.runAndroidDagPhase3MultiCamSpatialGlesRenderSmoke(
                        surface,
                        allocatedBufferA,
                        allocatedBufferB,
                        width,
                        height,
                    )
                }
            } catch (t: Throwable) {
                Log.e(TAG, "P3-MULTICAM-NODE spatial render smoke execution error", t)
                raw = spatialFailureResult("exception:${t.javaClass.simpleName.ifEmpty { "unknown_exception" }}")
            } finally {
                try {
                    bufferA?.close()
                } catch (_: Throwable) {
                }
                try {
                    bufferB?.close()
                } catch (_: Throwable) {
                }
                try {
                    producerSurface?.release()
                } catch (_: Throwable) {
                }
            }

            entry.runCompleted.set(true)
            // Same ownership rule as AX/BB/AW-OES: the producer is released
            // here only if a dispose() arrived while still running; a
            // normal completion with no prior dispose leaves it alive for
            // Dart to display via a Texture widget.
            var released = false
            synchronized(entry) {
                if (entry.disposeRequested.get()) {
                    released = releaseOnceSpatial(entry)
                }
            }
            if (released) {
                synchronized(spatialActiveEntries) { spatialActiveEntries.remove(textureId) }
            }

            val finalResult = parseSpatialResult(raw) + mapOf(
                "textureId" to textureId,
                "surfaceProducerReleased" to released,
                "width" to width,
                "height" to height,
            )
            mainHandler.post {
                channel.invokeMethod(SPATIAL_COMPLETE_METHOD, finalResult)
            }
        }.start()

        result.success(mapOf(
            "started" to true,
            "textureId" to textureId,
        ))
    }

    private fun disposeSpatial(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "disposeAndroidDagPhase3MultiCamSpatialGlesRenderSmoke: textureId required", null)
            return
        }
        val entry = synchronized(spatialActiveEntries) { spatialActiveEntries[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to true,
                "textureId" to textureId,
                "surfaceProducerReleased" to false,
                "raw" to "status=OK;already_disposed_or_not_found;textureId=$textureId",
            ))
            return
        }

        // Same ownership rule as AX/BB/AW-OES's dispose(): never release the
        // producer while the worker thread may still be rendering into it.
        var released = false
        var completedNow = false
        synchronized(entry) {
            if (entry.runCompleted.get()) {
                released = releaseOnceSpatial(entry)
                completedNow = true
            } else {
                entry.disposeRequested.set(true)
            }
        }
        if (completedNow) {
            synchronized(spatialActiveEntries) { spatialActiveEntries.remove(textureId) }
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

    private fun releaseOnceSpatial(entry: SpatialActiveEntry): Boolean {
        if (!entry.released.compareAndSet(false, true)) {
            return false
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            try {
                entry.surfaceProducer.release()
            } catch (t: Throwable) {
                Log.w(TAG, "Spatial surfaceProducer.release() failed: ${t.javaClass.simpleName}: ${t.message}")
            }
        } else {
            mainHandler.post {
                try {
                    entry.surfaceProducer.release()
                } catch (t: Throwable) {
                    Log.w(TAG, "Spatial surfaceProducer.release() on mainHandler failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }
        return true
    }

    private fun parseSpatialResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val proofBoundary = parsed["proofBoundary"] ?: SPATIAL_PROOF_BOUNDARY
        val lastError = parsed["lastError"] ?: ""
        val metrics = mapOf(
            "clientVersion" to (parsed["clientVersion"]?.toIntOrNull() ?: 0),
            "vendor" to (parsed["vendor"] ?: ""),
            "renderer" to (parsed["renderer"] ?: ""),
            "version" to (parsed["version"] ?: ""),
            "bufferADescribe" to (parsed["bufferADescribe"] ?: "not_run"),
            "bufferAFill" to (parsed["bufferAFill"] ?: "not_run"),
            "bufferBDescribe" to (parsed["bufferBDescribe"] ?: "not_run"),
            "bufferBFill" to (parsed["bufferBFill"] ?: "not_run"),
            "preInitLane" to (parsed["preInitLane"] ?: "not_run"),
            "preInitLastError" to (parsed["preInitLastError"] ?: ""),
            "initialize" to (parsed["initialize"] ?: "not_run"),
            "attach" to (parsed["attach"] ?: "not_run"),
            "importBufferA" to (parsed["importBufferA"] ?: "not_run"),
            "handleA" to (parsed["handleA"]?.toLongOrNull() ?: 0L),
            "targetA" to (parsed["targetA"]?.toLongOrNull() ?: 0L),
            "importBufferB" to (parsed["importBufferB"] ?: "not_run"),
            "handleB" to (parsed["handleB"]?.toLongOrNull() ?: 0L),
            "targetB" to (parsed["targetB"]?.toLongOrNull() ?: 0L),
            "invalidHandleLane" to (parsed["invalidHandleLane"] ?: "not_run"),
            "invalidHandleLastError" to (parsed["invalidHandleLastError"] ?: ""),
            "invalidRectLane" to (parsed["invalidRectLane"] ?: "not_run"),
            "invalidRectLastError" to (parsed["invalidRectLastError"] ?: ""),
            "topBottomSplitOk" to (parsed["topBottomSplitOk"]?.equals("true", ignoreCase = true) ?: false),
            "topBottomSplitLastError" to (parsed["topBottomSplitLastError"] ?: ""),
            "leftRightSplitOk" to (parsed["leftRightSplitOk"]?.equals("true", ignoreCase = true) ?: false),
            "leftRightSplitLastError" to (parsed["leftRightSplitLastError"] ?: ""),
            "pipTopLeftOk" to (parsed["pipTopLeftOk"]?.equals("true", ignoreCase = true) ?: false),
            "pipTopLeftLastError" to (parsed["pipTopLeftLastError"] ?: ""),
            "pipFreeFloatingOk" to (parsed["pipFreeFloatingOk"]?.equals("true", ignoreCase = true) ?: false),
            "pipFreeFloatingLastError" to (parsed["pipFreeFloatingLastError"] ?: ""),
            "sentinelClearOk" to (parsed["sentinelClearOk"]?.equals("true", ignoreCase = true) ?: false),
            "presentComposite" to (parsed["presentComposite"] ?: "not_run"),
            "presentCompositeLastError" to (parsed["presentCompositeLastError"] ?: ""),
            "releaseBufferA" to (parsed["releaseBufferA"] ?: "not_run"),
            "releaseBufferAFence" to (parsed["releaseBufferAFence"]?.toIntOrNull() ?: -1),
            "hasAAfterRelease" to (parsed["hasAAfterRelease"]?.equals("true", ignoreCase = true) ?: false),
            "releaseBufferB" to (parsed["releaseBufferB"] ?: "not_run"),
            "releaseBufferBFence" to (parsed["releaseBufferBFence"]?.toIntOrNull() ?: -1),
            "hasBAfterRelease" to (parsed["hasBAfterRelease"]?.equals("true", ignoreCase = true) ?: false),
            "postReleaseLane" to (parsed["postReleaseLane"] ?: "not_run"),
            "postReleaseLastError" to (parsed["postReleaseLastError"] ?: ""),
            "detach" to (parsed["detach"] ?: "not_run"),
            "shutdown" to (parsed["shutdown"] ?: "not_run"),
            "idempotentShutdown" to (parsed["idempotentShutdown"] ?: "not_run"),
        )

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "proofBoundary" to proofBoundary,
            "metrics" to metrics,
            "lastError" to lastError,
        )
    }

    private fun spatialFailureResult(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;" +
        "bufferADescribe=not_run;bufferAFill=not_run;bufferBDescribe=not_run;bufferBFill=not_run;" +
        "preInitLane=not_run;preInitLastError=;" +
        "initialize=not_run;attach=not_run;" +
        "importBufferA=not_run;handleA=0;targetA=0;importBufferB=not_run;handleB=0;targetB=0;" +
        "invalidHandleLane=not_run;invalidHandleLastError=;" +
        "invalidRectLane=not_run;invalidRectLastError=;" +
        "topBottomSplitOk=false;topBottomSplitLastError=;" +
        "leftRightSplitOk=false;leftRightSplitLastError=;" +
        "pipTopLeftOk=false;pipTopLeftLastError=;" +
        "pipFreeFloatingOk=false;pipFreeFloatingLastError=;" +
        "sentinelClearOk=false;" +
        "presentComposite=not_run;presentCompositeLastError=;" +
        "releaseBufferA=not_run;releaseBufferAFence=-1;hasAAfterRelease=false;" +
        "releaseBufferB=not_run;releaseBufferBFence=-1;hasBAfterRelease=false;" +
        "postReleaseLane=not_run;postReleaseLastError=;" +
        "detach=not_run;shutdown=not_run;idempotentShutdown=not_run;" +
        "proofBoundary=$SPATIAL_PROOF_BOUNDARY;" +
        "lastError=$reason"

    // -- P3-MULTICAM-NODE-GLES-OES-SPATIAL-RENDER: bounded OES extension --

    private fun startOes(args: Map<*, *>?, result: MethodChannel.Result) {
        val widthArg = (args?.get("width") as? Number)?.toInt()
        val heightArg = (args?.get("height") as? Number)?.toInt()
        if (widthArg != null && widthArg <= 0) {
            result.error("INVALID_ARG", "startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke: width must be positive", null)
            return
        }
        if (heightArg != null && heightArg <= 0) {
            result.error("INVALID_ARG", "startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke: height must be positive", null)
            return
        }
        val width = widthArg ?: OES_DEFAULT_DIMENSION
        val height = heightArg ?: OES_DEFAULT_DIMENSION

        val surfaceProducer = textureRegistry.createSurfaceProducer()
        val textureId = surfaceProducer.id()
        val entry = OesActiveEntry(surfaceProducer)
        synchronized(oesActiveEntries) {
            oesActiveEntries[textureId] = entry
        }

        Thread {
            var producerSurface: Surface? = null
            var harnessResult: Map<String, Any?> = emptyMap()
            try {
                surfaceProducer.setSize(width, height)
                val surface = surfaceProducer.getSurface()
                producerSurface = surface
                harnessResult = AndroidMultiCamSpatialGlesOesSmokeHarness.runGlesOesSpatialSmokeForSurface(
                    surface,
                    width,
                    height,
                )
            } catch (t: Throwable) {
                Log.e(TAG, "P3-MULTICAM-NODE-GLES-OES-SPATIAL-RENDER harness execution error", t)
                harnessResult = mapOf(
                    "pass" to false,
                    "raw" to "status=FAIL;lastError=exception:${t.javaClass.simpleName.ifEmpty { "unknown_exception" }}",
                    "proofBoundary" to AndroidMultiCamSpatialGlesOesSmokeHarness.PROOF_BOUNDARY,
                    "metrics" to emptyMap<String, Any?>(),
                    "lastError" to "exception:${t.javaClass.simpleName.ifEmpty { "unknown_exception" }}",
                )
            } finally {
                // The Surface obtained from the SurfaceProducer is owned by
                // this coordinator, not the harness (which never releases a
                // caller-provided Surface) -- release it once the harness
                // finishes. The SurfaceProducer itself is released only via
                // releaseOnceOes()'s dispose-driven lifecycle below.
                try {
                    producerSurface?.release()
                } catch (_: Throwable) {
                }
            }

            entry.runCompleted.set(true)
            // Same ownership rule as AX/BB/AW-OES/Spatial: the producer is
            // released here only if a dispose() arrived while still
            // running; a normal completion with no prior dispose leaves it
            // alive for Dart to display via a Texture widget.
            var released = false
            synchronized(entry) {
                if (entry.disposeRequested.get()) {
                    released = releaseOnceOes(entry)
                }
            }
            if (released) {
                synchronized(oesActiveEntries) { oesActiveEntries.remove(textureId) }
            }

            val finalResult = harnessResult + mapOf(
                "textureId" to textureId,
                "surfaceProducerReleased" to released,
                "width" to width,
                "height" to height,
            )
            mainHandler.post {
                channel.invokeMethod(OES_COMPLETE_METHOD, finalResult)
            }
        }.start()

        result.success(mapOf(
            "started" to true,
            "textureId" to textureId,
        ))
    }

    private fun disposeOes(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "disposeAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke: textureId required", null)
            return
        }
        val entry = synchronized(oesActiveEntries) { oesActiveEntries[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to true,
                "textureId" to textureId,
                "surfaceProducerReleased" to false,
                "raw" to "status=OK;already_disposed_or_not_found;textureId=$textureId",
            ))
            return
        }

        // Same ownership rule as AX/BB/AW-OES/Spatial's dispose(): never
        // release the producer while the worker thread may still be
        // rendering into it.
        var released = false
        var completedNow = false
        synchronized(entry) {
            if (entry.runCompleted.get()) {
                released = releaseOnceOes(entry)
                completedNow = true
            } else {
                entry.disposeRequested.set(true)
            }
        }
        if (completedNow) {
            synchronized(oesActiveEntries) { oesActiveEntries.remove(textureId) }
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

    private fun releaseOnceOes(entry: OesActiveEntry): Boolean {
        if (!entry.released.compareAndSet(false, true)) {
            return false
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            try {
                entry.surfaceProducer.release()
            } catch (t: Throwable) {
                Log.w(TAG, "OES surfaceProducer.release() failed: ${t.javaClass.simpleName}: ${t.message}")
            }
        } else {
            mainHandler.post {
                try {
                    entry.surfaceProducer.release()
                } catch (t: Throwable) {
                    Log.w(TAG, "OES surfaceProducer.release() on mainHandler failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }
        return true
    }
}
