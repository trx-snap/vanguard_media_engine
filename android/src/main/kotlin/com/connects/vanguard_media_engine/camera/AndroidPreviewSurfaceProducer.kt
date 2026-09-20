package com.connects.vanguard_media_engine.camera

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.codec.AndroidDagSurfaceProducerLifecycleAdapter
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean

// Neutral SurfaceProducer seam for live GLES preview surfaces — not owned by
// Duet. Moved out of duet/AndroidDuetPreviewSurfaceProducer.kt (background/
// transform/layout/surface-contract ownership slice), which now aliases these
// types for source compatibility. Any single-input or multi-input live
// preview surface (GreenScreen, Duet, camera) may use this producer.
//
// Wraps a TextureRegistry.SurfaceProducer and tracks the surface lifecycle.
// Does NOT start a renderer or GLES context, and does NOT retain a Surface
// reference. SurfaceProducer owns producer lifecycle; callers may borrow the
// Surface via acquireSurface() but must never release it.
//
// State machine:
//   ATTACHED_WAITING_SURFACE → onSurfaceAvailable → SURFACE_AVAILABLE
//   SURFACE_AVAILABLE → onSurfaceCleanup → SURFACE_LOST
//   SURFACE_LOST → onSurfaceAvailable → SURFACE_AVAILABLE
//   any → beginRelease() → DETACHED; finishRelease() releases the producer exactly once

/**
 * Internal state of a preview surface producer.
 * Mirrors VGDuetPreviewTextureState on the Dart side.
 */
enum class AndroidPreviewSurfaceState {
    ATTACHED_WAITING_SURFACE,
    SURFACE_AVAILABLE,
    SURFACE_LOST,
    DETACHED,
}

/**
 * Wraps a [TextureRegistry.SurfaceProducer] and tracks the surface lifecycle
 * without retaining a Surface reference or starting a render loop.
 *
 * Threading:
 * - Flutter delivers lifecycle callbacks on the platform (main) thread. State
 *   transitions and the optional [onSurfaceAvailable] / [onSurfaceLost] hooks run
 *   synchronously inside that callback, so [AndroidPreviewSurfaceState.SURFACE_LOST] is
 *   already set before `onSurfaceCleanup` returns (a later compositor must stop
 *   submitting to the Surface before that point).
 * - [acquireSurface] is platform-thread only. A later render thread may receive
 *   the acquired Surface from the caller but must not call this itself.
 * - [beginRelease] / [finishRelease] / [release] may be called from any thread;
 *   producer calls are run inline on the platform thread or posted to [mainHandler].
 *
 * Hook contract: [onSurfaceAvailable] / [onSurfaceLost] fire only on real state
 * transitions driven by Flutter callbacks. The eager availability probe in `init`
 * never fires a hook (the object is still under construction); callers should
 * inspect [state] after construction. [beginRelease] does not fire [onSurfaceLost]
 * either, so the owner can stop a compositor explicitly between the two phases.
 */
class AndroidPreviewSurfaceProducer(
    textureRegistry: TextureRegistry,
    private val mainHandler: Handler,
    widthPx:  Int,
    heightPx: Int,
    private val onSurfaceAvailable: (() -> Unit)? = null,
    private val onSurfaceLost: (() -> Unit)? = null,
) {

    companion object {
        private const val TAG = "PreviewSurfaceProducer"
    }

    // ── SurfaceProducer ───────────────────────────────────────────────────────

    private val producer: TextureRegistry.SurfaceProducer =
        textureRegistry.createSurfaceProducer()

    /** Flutter texture registry ID for the Texture widget. */
    val textureId: Long = producer.id()

    // ── State ─────────────────────────────────────────────────────────────────

    @Volatile
    private var _state: AndroidPreviewSurfaceState = AndroidPreviewSurfaceState.ATTACHED_WAITING_SURFACE

    val state: AndroidPreviewSurfaceState get() = _state

    /** Phase 1 of release: callback cleared + DETACHED. */
    private val releaseBegun = AtomicBoolean(false)
    /** Phase 2 of release: producer.release() issued. */
    private val releaseFinished = AtomicBoolean(false)

    // ── Lifecycle adapter ─────────────────────────────────────────────────────

    private val lifecycleAdapter = AndroidDagSurfaceProducerLifecycleAdapter(
        onAvailable = { handleSurfaceAvailable() },
        onCleanup   = { handleSurfaceCleanup() },
    )

    // ── Init ──────────────────────────────────────────────────────────────────

    init {
        // Set output dimensions. No getSurface() call; producer owns the surface.
        try {
            producer.setSize(widthPx, heightPx)
        } catch (t: Throwable) {
            Log.w(TAG, "setSize($widthPx, $heightPx) threw: ${t.message}")
        }

        try {
            producer.setCallback(lifecycleAdapter)
            // After registering the callback the surface may already be available;
            // probe getSurface() to advance state immediately. No hook fires here.
            // Do NOT retain the Surface reference; SurfaceProducer owns it.
            val surface = producer.getSurface()
            if (surface != null && surface.isValid) {
                _state = AndroidPreviewSurfaceState.SURFACE_AVAILABLE
                Log.d(TAG, "textureId=$textureId SURFACE_AVAILABLE (eager probe)")
            }
        } catch (t: Throwable) {
            Log.w(TAG, "setCallback / initial probe threw: ${t.message}")
        }
    }

    // ── Lifecycle handlers (platform thread, synchronous) ─────────────────────

    private fun handleSurfaceAvailable() {
        if (_state == AndroidPreviewSurfaceState.DETACHED) return
        val previous = _state
        _state = AndroidPreviewSurfaceState.SURFACE_AVAILABLE
        Log.d(TAG, "textureId=$textureId SURFACE_AVAILABLE (from $previous)")
        if (previous != AndroidPreviewSurfaceState.SURFACE_AVAILABLE) {
            invokeHook("onSurfaceAvailable", onSurfaceAvailable)
        }
    }

    private fun handleSurfaceCleanup() {
        if (_state == AndroidPreviewSurfaceState.DETACHED) return
        val previous = _state
        // Must be set before returning: contract says stop submitting immediately.
        _state = AndroidPreviewSurfaceState.SURFACE_LOST
        Log.d(TAG, "textureId=$textureId SURFACE_LOST (from $previous)")
        if (previous != AndroidPreviewSurfaceState.SURFACE_LOST) {
            invokeHook("onSurfaceLost", onSurfaceLost)
        }
    }

    private fun invokeHook(name: String, hook: (() -> Unit)?) {
        if (hook == null) return
        try {
            hook()
        } catch (t: Throwable) {
            Log.e(TAG, "textureId=$textureId $name hook threw", t)
        }
    }

    // ── Surface egress ────────────────────────────────────────────────────────

    /**
     * Returns the producer's current [Surface] for a consumer to render into, or null.
     *
     * Non-null only when called on the platform (main) thread, release has not begun,
     * [state] is [AndroidPreviewSurfaceState.SURFACE_AVAILABLE], and the Surface is valid.
     * The returned Surface is owned by the [TextureRegistry.SurfaceProducer]; the
     * caller must NEVER call `Surface.release()` on it and must stop using it as
     * soon as [onSurfaceLost] fires or [state] leaves SURFACE_AVAILABLE.
     */
    fun acquireSurface(): Surface? {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            Log.w(TAG, "textureId=$textureId acquireSurface() called off the platform thread; returning null")
            return null
        }
        if (releaseBegun.get() || _state != AndroidPreviewSurfaceState.SURFACE_AVAILABLE) return null
        return try {
            val surface = producer.getSurface()
            if (surface != null && surface.isValid) surface else null
        } catch (t: Throwable) {
            Log.w(TAG, "textureId=$textureId getSurface() threw: ${t.message}")
            null
        }
    }

    // ── Release (two-phase, idempotent) ───────────────────────────────────────

    /**
     * Phase 1: clears the lifecycle callback and marks [AndroidPreviewSurfaceState.DETACHED].
     * After this, no further lifecycle events or hooks are delivered and
     * [acquireSurface] returns null. Does not release the producer and does not
     * fire [onSurfaceLost]; the owner stops any consumer explicitly before
     * [finishRelease]. Idempotent.
     */
    fun beginRelease() {
        if (!releaseBegun.compareAndSet(false, true)) return
        _state = AndroidPreviewSurfaceState.DETACHED
        runOnPlatformThread {
            try {
                // Null out callback before release per existing pattern.
                producer.setCallback(null)
            } catch (_: Throwable) {}
            Log.d(TAG, "textureId=$textureId release begun (DETACHED)")
        }
    }

    /**
     * Phase 2: releases the [TextureRegistry.SurfaceProducer] exactly once.
     * Calls [beginRelease] first if the owner skipped it. Idempotent.
     */
    fun finishRelease() {
        beginRelease()
        if (!releaseFinished.compareAndSet(false, true)) return
        runOnPlatformThread {
            try {
                producer.release()
                Log.d(TAG, "textureId=$textureId released")
            } catch (t: Throwable) {
                Log.w(TAG, "producer.release() failed: ${t.message}")
            }
        }
    }

    /**
     * Single-shot release: [beginRelease] then [finishRelease].
     * Safe to call from any thread; producer work runs on the platform thread.
     */
    fun release() {
        beginRelease()
        finishRelease()
    }

    private fun runOnPlatformThread(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            mainHandler.post { block() }
        }
    }

    // ── Map for MethodChannel reply ───────────────────────────────────────────

    /**
     * Returns a flat map suitable for returning via MethodChannel.
     * [state] maps to the Dart VGDuetPreviewTextureState.name string.
     */
    fun toResultMap(
        widthPx:    Int,
        heightPx:   Int,
        layoutRects: Map<String, Any>? = null,
    ): Map<String, Any?> {
        val stateStr = when (_state) {
            AndroidPreviewSurfaceState.ATTACHED_WAITING_SURFACE -> "attachedWaitingSurface"
            AndroidPreviewSurfaceState.SURFACE_AVAILABLE        -> "surfaceAvailable"
            AndroidPreviewSurfaceState.SURFACE_LOST             -> "surfaceLost"
            AndroidPreviewSurfaceState.DETACHED                 -> "detached"
        }
        return buildMap {
            put("textureId", textureId)
            put("width",  widthPx.toDouble())
            put("height", heightPx.toDouble())
            put("state",  stateStr)
            if (layoutRects != null) put("layoutRects", layoutRects)
        }
    }
}
