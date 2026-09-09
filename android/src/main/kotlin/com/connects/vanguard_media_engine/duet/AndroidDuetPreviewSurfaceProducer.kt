package com.connects.vanguard_media_engine.duet

import android.os.Handler
import android.util.Log
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean

// VG-DUET-SLICE-4A: SurfaceProducer seam for true Duet preview.
//
// Wraps a TextureRegistry.SurfaceProducer and tracks the surface lifecycle.
// Does NOT start a renderer, GLES context, or retain a Surface reference
// beyond the state-tracking callback. SurfaceProducer owns producer lifecycle.
//
// State machine:
//   ATTACHED_WAITING_SURFACE → onSurfaceAvailable → SURFACE_AVAILABLE
//   SURFACE_AVAILABLE → onSurfaceCleanup → SURFACE_LOST
//   SURFACE_LOST → onSurfaceAvailable → SURFACE_AVAILABLE
//   any → release() → DETACHED (released exactly once)

/**
 * Internal state of the Duet preview surface producer.
 * Mirrors VGDuetPreviewTextureState on the Dart side.
 */
enum class DuetSurfaceState {
    ATTACHED_WAITING_SURFACE,
    SURFACE_AVAILABLE,
    SURFACE_LOST,
    DETACHED,
}

/**
 * Wraps a [TextureRegistry.SurfaceProducer] and tracks the surface lifecycle
 * without retaining a Surface reference or starting a render loop.
 *
 * All callback and release operations post to [mainHandler] from any thread.
 */
class AndroidDuetPreviewSurfaceProducer(
    textureRegistry: TextureRegistry,
    private val mainHandler: Handler,
    widthPx:  Int,
    heightPx: Int,
) {

    companion object {
        private const val TAG = "DuetPreviewSurface"
    }

    // ── SurfaceProducer ───────────────────────────────────────────────────────

    private val producer: TextureRegistry.SurfaceProducer =
        textureRegistry.createSurfaceProducer()

    /** Flutter texture registry ID for the Texture widget. */
    val textureId: Long = producer.id()

    // ── State ─────────────────────────────────────────────────────────────────

    @Volatile
    private var _state: DuetSurfaceState = DuetSurfaceState.ATTACHED_WAITING_SURFACE

    val state: DuetSurfaceState get() = _state

    private val released = AtomicBoolean(false)

    // ── Init ──────────────────────────────────────────────────────────────────

    init {
        // Set output dimensions. No getSurface() call; producer owns the surface.
        try {
            producer.setSize(widthPx, heightPx)
        } catch (t: Throwable) {
            Log.w(TAG, "setSize($widthPx, $heightPx) threw: ${t.message}")
        }

        // Register lifecycle callback using the existing adapter from the codec layer.
        val callback = object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                mainHandler.post {
                    if (_state != DuetSurfaceState.DETACHED) {
                        _state = DuetSurfaceState.SURFACE_AVAILABLE
                        Log.d(TAG, "textureId=$textureId SURFACE_AVAILABLE")
                    }
                }
            }

            override fun onSurfaceCleanup() {
                mainHandler.post {
                    if (_state != DuetSurfaceState.DETACHED) {
                        _state = DuetSurfaceState.SURFACE_LOST
                        Log.d(TAG, "textureId=$textureId SURFACE_LOST")
                    }
                }
            }

            // Deprecated API compatibility: forward to the same handlers.
            @Deprecated("Use onSurfaceAvailable", replaceWith = ReplaceWith("onSurfaceAvailable()"))
            override fun onSurfaceCreated() = onSurfaceAvailable()

            @Deprecated("Use onSurfaceCleanup", replaceWith = ReplaceWith("onSurfaceCleanup()"))
            override fun onSurfaceDestroyed() = onSurfaceCleanup()
        }

        try {
            producer.setCallback(callback)
            // After registering the callback the surface may already be available;
            // probe getSurface() to potentially advance state immediately.
            // Do NOT retain the Surface reference; SurfaceProducer owns it.
            val surface = producer.getSurface()
            if (surface != null && surface.isValid) {
                _state = DuetSurfaceState.SURFACE_AVAILABLE
                Log.d(TAG, "textureId=$textureId SURFACE_AVAILABLE (eager probe)")
            }
        } catch (t: Throwable) {
            Log.w(TAG, "setCallback / initial probe threw: ${t.message}")
        }
    }

    // ── Release (idempotent) ──────────────────────────────────────────────────

    /**
     * Releases the [TextureRegistry.SurfaceProducer] exactly once.
     * Transitions state to [DuetSurfaceState.DETACHED].
     * Safe to call from any thread; release is posted to [mainHandler].
     */
    fun release() {
        if (!released.compareAndSet(false, true)) return
        _state = DuetSurfaceState.DETACHED
        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            releaseInternal()
        } else {
            mainHandler.post { releaseInternal() }
        }
    }

    private fun releaseInternal() {
        try {
            // Null out callback before release per existing pattern.
            producer.setCallback(null)
        } catch (_: Throwable) {}
        try {
            producer.release()
            Log.d(TAG, "textureId=$textureId released")
        } catch (t: Throwable) {
            Log.w(TAG, "producer.release() failed: ${t.message}")
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
            DuetSurfaceState.ATTACHED_WAITING_SURFACE -> "attachedWaitingSurface"
            DuetSurfaceState.SURFACE_AVAILABLE        -> "surfaceAvailable"
            DuetSurfaceState.SURFACE_LOST             -> "surfaceLost"
            DuetSurfaceState.DETACHED                 -> "detached"
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
