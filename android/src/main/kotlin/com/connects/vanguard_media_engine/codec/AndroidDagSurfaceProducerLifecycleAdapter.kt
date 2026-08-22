package com.connects.vanguard_media_engine.codec

import android.util.Log
import io.flutter.view.TextureRegistry

/**
 * Vanguard Android True-DAG Phase 4B2B2B: SurfaceProducer lifecycle adapter.
 *
 * Implements [TextureRegistry.SurfaceProducer.Callback] and forwards
 * surface lifecycle events to caller-supplied lambdas. This class owns NO codec,
 * native session, or media-pipeline policy — it is purely a forwarding shim so
 * that [AndroidDagTexturePlaybackControlSession] can register a stable callback
 * object without coupling the Flutter API surface directly to session internals.
 *
 * Lifecycle contract (per Flutter docs):
 * - [onSurfaceAvailable] / [onSurfaceCreated]: a new Surface is ready; caller
 *   must re-fetch via `surfaceProducer.getSurface()` and recreate native output.
 * - [onSurfaceCleanup] / [onSurfaceDestroyed]: stop submitting to the current
 *   Surface immediately; do NOT call getSurface() until the next available event.
 *
 * Thread-safety: Flutter calls these callbacks on the platform thread. Lambdas
 * must post any heavy work to the session's HandlerThread internally.
 */
class AndroidDagSurfaceProducerLifecycleAdapter(
    private val onAvailable: () -> Unit,
    private val onCleanup: () -> Unit,
) : TextureRegistry.SurfaceProducer.Callback {

    companion object {
        private const val TAG = "DagSurfaceLifecycle"
    }

    /**
     * Called when a new Surface is available and the producer can begin rendering.
     * Forwards to [onAvailable].
     */
    override fun onSurfaceAvailable() {
        Log.d(TAG, "onSurfaceAvailable")
        try {
            onAvailable()
        } catch (t: Throwable) {
            Log.e(TAG, "onSurfaceAvailable lambda threw", t)
        }
    }

    /**
     * Called when the current Surface is no longer valid. Stop submitting immediately.
     * Forwards to [onCleanup].
     */
    override fun onSurfaceCleanup() {
        Log.d(TAG, "onSurfaceCleanup")
        try {
            onCleanup()
        } catch (t: Throwable) {
            Log.e(TAG, "onSurfaceCleanup lambda threw", t)
        }
    }

    // ── Deprecated API compatibility ──────────────────────────────────────────
    // Flutter SDK older than 3.27 may call the deprecated variants instead of the
    // new ones. We forward them to the same lambdas so the session behaves correctly
    // regardless of which SDK the host app compiles against.

    @Deprecated("Use onSurfaceAvailable", replaceWith = ReplaceWith("onSurfaceAvailable()"))
    override fun onSurfaceCreated() {
        Log.d(TAG, "onSurfaceCreated (deprecated -> onSurfaceAvailable)")
        try {
            onAvailable()
        } catch (t: Throwable) {
            Log.e(TAG, "onSurfaceCreated lambda threw", t)
        }
    }

    @Deprecated("Use onSurfaceCleanup", replaceWith = ReplaceWith("onSurfaceCleanup()"))
    override fun onSurfaceDestroyed() {
        Log.d(TAG, "onSurfaceDestroyed (deprecated -> onSurfaceCleanup)")
        try {
            onCleanup()
        } catch (t: Throwable) {
            Log.e(TAG, "onSurfaceDestroyed lambda threw", t)
        }
    }
}
