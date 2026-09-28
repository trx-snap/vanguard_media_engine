package com.connects.vanguard_media_engine.livestream

// ── AndroidLivestreamMediaSourceCoordinator ──────────────────────────────────
//
// I1 (livestream live media source switching, Option A): owns WHICH producer
// feeds the retained virtual camera Surface of the live LiveKit track — the
// Vanguard camera egress or an AndroidLivestreamImagePump — and the generation
// bookkeeping that lets rapid setMediaSource calls supersede each other so only
// the latest request commits. The WebRTC track, its Surface and the stock-free
// virtual camera SPI are untouched: AndroidVanguardLiveKitBridge stays the SPI
// owner and only routes "setMediaSource" here.
//
// Producer hand-off (a BufferQueue accepts ONE connected producer at a time):
//   camera → image
//     1. validate the path synchronously, decode/aspect-fill it on a
//        background thread (never on the main or GPU thread);
//     2. detach the camera egress from the Surface (the camera itself keeps
//        running: preview is unaffected);
//     3. start the image pump on the retained Surface; it binds once the camera
//        GPU thread has disconnected (bounded retries);
//     4. ONLY after the pump's first frame is on the Surface: suspend CameraX
//        (VanguardCameraSource.suspendCapture — use cases unbound, camera
//        device closed, beauty/green-screen/overlay state retained);
//     5. commit mode=image and reply.
//   image → image
//     the running pump uploads the new texture and swaps it in only after a
//     clean upload (the old image keeps streaming meanwhile); the request is
//     committed only from that upload result, bounded by a timeout.
//   image → camera
//     1. resume CameraX (VanguardCameraSource.resumeCapture rebinds through the
//        normal bindUseCases path); the image pump keeps ticking and the
//        request stays pending — bounded by CAMERA_RESUME_TIMEOUT_MS — until
//        the first completed camera capture, an error, or supersession;
//     2. on the first completed capture: verify every up-front reason the
//        egress attach could be refused while the pump still owns the Surface,
//        then stop the pump (blocking, so the Surface is disconnected) and
//        attach the camera egress;
//     3. commit mode=camera ONLY once the attach was accepted, then reply.
//
// Committed mode ("mediaSource" in getStats) is only ever camera or image
// while a producer is actually bound; MODE_NONE is reported — never as a
// success reply — when a hand-off failed closed and no producer feeds the
// Surface, or while a rollback is still resuming the camera. The next
// setMediaSource(camera) re-binds the egress; setMediaSource(image) starts a
// pump. Failure policy: invalid path / decode failure / pump failure /
// camera-suspend refusal reject the request and preserve (or restore) the
// camera producer; a camera resume failure or timeout rejects the request and
// keeps the image producer running (re-suspending the camera). Every reply is
// delivered exactly once.
//
// Threading: main thread only (MethodChannel calls, bridge callbacks, camera
// first-frame callbacks which VanguardCameraSource already posts to the main
// executor). Pump callbacks arrive on the pump thread and are re-posted here.
// Decoding runs on a dedicated single-thread executor.

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.VanguardCameraSource
import com.connects.vanguard_media_engine.camera.CameraOverlayState
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

internal class AndroidLivestreamMediaSourceCoordinator(
    private val cameraSourceProvider: () -> VanguardCameraSource?,
    private val retainedSurfaceProvider: () -> Surface?,
    private val egressWidth: Int,
    private val egressHeight: Int,
    private val egressMirror: Boolean,
    private val egressFps: Int,
) {
    companion object {
        private const val TAG = "VGLivestreamMediaSource"

        const val MODE_CAMERA = "camera"
        const val MODE_IMAGE = "image"
        /** Stats-only: no producer is bound (failed-closed hand-off or rollback in flight). */
        const val MODE_NONE = "none"

        private const val PUMP_START_TIMEOUT_MS = 4000L
        private const val IMAGE_REPLACE_TIMEOUT_MS = 3000L
        private const val CAMERA_RESUME_TIMEOUT_MS = 6000L
    }

    private class PendingRequest(
        val generation: Long,
        val result: MethodChannel.Result,
        val targetMode: String,
        val imagePath: String?,
    ) {
        var timeout: Runnable? = null
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val decodeExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "VGLivestreamMediaSourceDecode").apply { priority = Thread.NORM_PRIORITY - 1 }
    }

    // ── Main-thread state ────────────────────────────────────────────────────
    private var disposed = false
    private var generation = 0L
    private var pending: PendingRequest? = null

    // Committed mode, reported through getStats: MODE_CAMERA / MODE_IMAGE only
    // while that producer is bound, MODE_NONE otherwise (see header).
    private var committedMode = MODE_CAMERA
    private var committedImagePath: String? = null

    // Actual resource state; a superseding request reconciles from these, not
    // from the committed mode.
    private var pump: AndroidLivestreamImagePump? = null
    private var cameraSuspended = false

    private val pumpListener = object : AndroidLivestreamImagePump.Listener {
        override fun onFirstFrameRendered(pump: AndroidLivestreamImagePump) {
            mainHandler.post { onPumpFirstFrame(pump) }
        }

        override fun onFailed(pump: AndroidLivestreamImagePump, reason: String) {
            mainHandler.post { onPumpFailed(pump, reason) }
        }
    }

    // ── MethodChannel entry (main thread) ────────────────────────────────────

    /** Handles the bridge's "setMediaSource" call: `{mode: "camera"}` or `{mode: "image", imagePath}`. */
    fun handleSetMediaSource(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("UNAVAILABLE", "Livestream media source coordinator is disposed", null)
            return
        }
        val args = call.arguments as? Map<*, *>
        when (val mode = args?.get("mode") as? String) {
            MODE_CAMERA -> requestCamera(result)
            MODE_IMAGE -> requestImage(args?.get("imagePath") as? String, result)
            else -> result.error("INVALID_ARGUMENT", "mode must be \"camera\" or \"image\" (got $mode)", null)
        }
    }

    /** Overlay list changed (any producer): the image pump burns the new list into its frames. */
    fun onOverlayStateChanged(state: CameraOverlayState?) {
        pump?.setOverlay(state)
    }

    /**
     * The virtual camera track is ending (bridge stopVirtualEgress). Cancels
     * any in-flight request, stops the image pump and resumes the camera
     * capture if image mode had suspended it (camera-first baseline for the
     * next track; there is no Surface left to bind an egress to). Main thread.
     */
    fun onEgressStopping(reason: String) {
        if (disposed) return
        val hadPump = pump != null
        cancelPending("EGRESS_STOPPED", "The livestream egress stopped ($reason)")
        stopPump()
        if (cameraSuspended) {
            cameraSuspended = false
            val source = cameraSourceProvider()
            if (source != null && source.isCaptureSuspended) {
                var refused = false
                source.resumeCapture(
                    onFirstFrame = { Log.i(TAG, "camera resumed after egress stop ($reason)") },
                    onError = { e ->
                        refused = true
                        Log.e(TAG, "camera resume after egress stop failed: ${e.message}")
                    },
                )
                if (refused) {
                    cameraSuspended = source.isCaptureSuspended
                    commit(MODE_NONE, null)
                    Log.e(TAG, "ANDROID_LIVESTREAM_MEDIA_SOURCE_PRODUCER_LOST context=egress_stop cameraSuspended=$cameraSuspended")
                    return
                }
            }
        }
        if (hadPump) Log.i(TAG, "ANDROID_LIVESTREAM_MEDIA_SOURCE_RESET reason=$reason")
        // No track remains, so "camera" here means the camera capture is (being)
        // restored as the only producer the next track can start from.
        commit(MODE_CAMERA, null)
    }

    /**
     * The camera source is about to stop (stopCamera / restart / engine
     * detach). Cancels any in-flight request and stops the pump; the camera is
     * NOT resumed because it is being torn down. Main thread.
     */
    fun onCameraSourceStopping() {
        if (disposed) return
        cancelPending("CAMERA_STOPPED", "The Vanguard camera stopped")
        stopPump()
        cameraSuspended = false
        commit(MODE_CAMERA, null)
    }

    /** Engine teardown. Idempotent; the coordinator is inert afterwards. */
    fun dispose() {
        if (disposed) return
        onCameraSourceStopping()
        disposed = true
        decodeExecutor.shutdownNow()
    }

    /** Extra fields merged into the bridge's getStats reply. */
    fun statsFields(): Map<String, Any?> = mapOf(
        "mediaSource" to committedMode,
        "mediaSourceImagePath" to committedImagePath,
        "imagePumpFrames" to (pump?.framesRendered ?: 0L),
        "imagePumpImagePath" to pump?.imagePath,
        "cameraSuspended" to cameraSuspended,
    )

    // ── Requests ─────────────────────────────────────────────────────────────

    private fun requestImage(imagePath: String?, result: MethodChannel.Result) {
        // Camera source and retained Surface only gate the request here; both
        // are re-resolved once the background decode finishes.
        if (requireRunningCamera(result) == null) return
        if (requireRetainedSurface(result) == null) return
        val invalid = validateImagePath(imagePath)
        if (invalid != null) {
            // Rejected before any generation change: the current producer and
            // any in-flight request are untouched.
            result.error("INVALID_IMAGE_PATH", invalid, null)
            return
        }
        val path = imagePath!!
        val active = pump
        if (active != null && active.imagePath == path && committedMode == MODE_IMAGE && pending == null) {
            result.success(successMap(MODE_IMAGE, path))
            return
        }
        val gen = beginRequest(result, MODE_IMAGE, path)
        Log.i(TAG, "setMediaSource image gen=$gen path=$path (pump=${active != null} cameraSuspended=$cameraSuspended)")
        val width = egressWidth
        val height = egressHeight
        decodeExecutor.execute {
            val decoded = try {
                AndroidLivestreamImagePump.decode(path, width, height)
            } catch (t: Throwable) {
                val message = "${t.javaClass.simpleName}: ${t.message}"
                mainHandler.post { failRequest(gen, "IMAGE_DECODE_FAILED", message) }
                return@execute
            }
            mainHandler.post { applyDecodedImage(gen, path, decoded) }
        }
    }

    // Main thread, after the background decode.
    private fun applyDecodedImage(gen: Long, path: String, decoded: AndroidLivestreamImagePump.DecodedImage) {
        if (disposed || gen != generation || pending?.generation != gen) {
            // Superseded or cancelled while decoding: the newer request owns the producer state.
            decoded.recycle()
            Log.i(TAG, "decoded image for stale gen=$gen dropped")
            return
        }
        val source = cameraSourceProvider()
        val surface = retainedSurfaceProvider()
        if (source == null || !source.running) {
            decoded.recycle()
            failRequest(gen, "NO_ACTIVE_CAMERA", "Vanguard camera stopped while decoding the image")
            return
        }
        if (surface == null || !surface.isValid) {
            decoded.recycle()
            failRequest(gen, "NO_ACTIVE_STREAM", "The virtual camera track went away while decoding the image")
            return
        }

        val existing = pump
        if (existing != null) {
            // Image → image: the running pump keeps streaming the old image
            // until the new texture is uploaded; commit only from that result.
            existing.replaceImage(decoded) { ok, reason ->
                mainHandler.post { onImageReplaced(gen, existing, path, ok, reason) }
            }
            armTimeout(gen, IMAGE_REPLACE_TIMEOUT_MS) {
                failRequest(
                    gen,
                    "IMAGE_REPLACE_TIMEOUT",
                    "The image upload did not complete within ${IMAGE_REPLACE_TIMEOUT_MS}ms; the previous image keeps streaming",
                )
            }
            return
        }

        // Camera → image. The Surface takes one producer: let the camera egress
        // go first (camera keeps running for the preview), then bind the pump.
        source.detachEgressSurface()
        val started = AndroidLivestreamImagePump(surface, egressWidth, egressHeight, egressFps, pumpListener)
        pump = started
        started.setOverlay(source.currentOverlayState)
        started.start(decoded)
        armTimeout(gen, PUMP_START_TIMEOUT_MS) {
            Log.e(TAG, "image pump did not render within ${PUMP_START_TIMEOUT_MS}ms; restoring camera producer")
            stopPump()
            restoreCameraProducer("pump_start_timeout")
            failRequest(gen, "IMAGE_PUMP_START_TIMEOUT", "The image producer did not start within ${PUMP_START_TIMEOUT_MS}ms")
        }
    }

    // Main thread. Result of an image → image hot replacement.
    private fun onImageReplaced(
        gen: Long,
        target: AndroidLivestreamImagePump,
        path: String,
        ok: Boolean,
        reason: String?,
    ) {
        if (disposed) return
        if (pump !== target) {
            Log.i(TAG, "image replace result (ok=$ok) for a stopped pump ignored")
            return
        }
        val request = pending
        if (request == null || request.generation != gen) {
            // Superseded: a newer request reconciles the committed state; the
            // pump reports what it actually renders through imagePath/stats.
            if (ok) Log.i(TAG, "image replaced for superseded gen=$gen (pump now renders $path)")
            return
        }
        if (!ok) {
            // The previous image is untouched and keeps streaming; nothing to commit.
            failRequest(gen, "IMAGE_REPLACE_FAILED", reason ?: "image upload failed")
            return
        }
        commit(MODE_IMAGE, path)
        Log.i(TAG, "ANDROID_LIVESTREAM_MEDIA_SOURCE_COMMITTED mode=image swap=hot path=$path")
        completeRequest(gen, successMap(MODE_IMAGE, path))
    }

    // Main thread. The pump's first frame is on the Surface.
    private fun onPumpFirstFrame(rendered: AndroidLivestreamImagePump) {
        if (disposed || pump !== rendered) return
        val request = pending
        if (request == null || request.targetMode != MODE_IMAGE) {
            // Superseded by a camera request that already reconciled (or is
            // reconciling) from the resource state; nothing to commit here.
            return
        }
        val gen = request.generation
        clearTimeout(request)
        if (!cameraSuspended) {
            val source = cameraSourceProvider()
            val suspended = source != null && source.suspendCapture()
            if (!suspended) {
                // The invariant "camera suspended in image mode" cannot be met
                // (e.g. a recording is active): roll back to the camera producer.
                stopPump()
                restoreCameraProducer("camera_suspend_rejected")
                failRequest(gen, "CAMERA_SUSPEND_REJECTED", "The camera could not be suspended for image mode")
                return
            }
            cameraSuspended = true
        }
        val path = request.imagePath ?: rendered.imagePath
        commit(MODE_IMAGE, path)
        Log.i(TAG, "ANDROID_LIVESTREAM_MEDIA_SOURCE_COMMITTED mode=image path=$path cameraSuspended=true")
        completeRequest(gen, successMap(MODE_IMAGE, path))
    }

    // Main thread. The pump failed (bind/draw); bring the camera producer back.
    private fun onPumpFailed(failedPump: AndroidLivestreamImagePump, reason: String) {
        if (disposed || pump !== failedPump) return
        Log.e(TAG, "image pump failed ($reason); restoring camera producer")
        stopPump()
        val request = pending
        if (request != null && request.targetMode == MODE_CAMERA) {
            // A camera switch is already in flight (resume accepted): its first
            // frame / timeout path finishes the hand-off and replies.
            if (!cameraSuspended) {
                // No producer is bound until that hand-off lands; say so in stats.
                commit(MODE_NONE, null)
                Log.i(TAG, "camera switch gen=${request.generation} pending; egress attach deferred to its first frame")
                return
            }
        }
        restoreCameraProducer("pump_failed:$reason")
        if (request != null && request.targetMode == MODE_IMAGE) {
            failRequest(request.generation, "IMAGE_PUMP_FAILED", reason)
        }
    }

    private fun requestCamera(result: MethodChannel.Result) {
        val source = requireRunningCamera(result) ?: return
        if (requireRetainedSurface(result) == null) return
        val gen = beginRequest(result, MODE_CAMERA, null)
        Log.i(
            TAG,
            "setMediaSource camera gen=$gen (pump=${pump != null} cameraSuspended=$cameraSuspended committed=$committedMode)",
        )
        if (pump == null && !cameraSuspended) {
            if (committedMode == MODE_CAMERA) {
                // Already the camera producer (or a superseded image request
                // that never got past decoding): nothing was ever detached.
                completeRequest(gen, successMap(MODE_CAMERA, null))
                return
            }
            // No producer is bound (a previous hand-off failed closed, or a
            // rollback is still resuming the camera): bind the egress now.
            if (bindCameraEgressOrFailClosed("camera_request")) {
                completeRequest(gen, successMap(MODE_CAMERA, null))
            } else {
                failRequest(gen, "CAMERA_EGRESS_ATTACH_FAILED", "The camera egress could not bind the virtual camera surface")
            }
            return
        }
        if (cameraSuspended) {
            // Resume CameraX first; the pump keeps feeding the track meanwhile.
            var refused = false
            source.resumeCapture(
                onFirstFrame = { onCameraFirstFrame(gen) },
                onError = { e ->
                    refused = true
                    failRequest(gen, "CAMERA_RESUME_FAILED", "${e.javaClass.simpleName}: ${e.message}")
                },
            )
            if (refused) {
                // Image producer untouched; the source reports whether it is still suspended.
                cameraSuspended = source.isCaptureSuspended
                return
            }
            cameraSuspended = false
            // Accepted: the request stays pending until the first completed
            // capture (onCameraFirstFrame), supersession, or this timeout.
            armTimeout(gen, CAMERA_RESUME_TIMEOUT_MS) { onCameraResumeTimeout(gen) }
            return
        }
        // Camera already capturing (e.g. a superseded switch left the pump
        // running): hand the Surface back right away.
        finishCameraSwitch(gen)
    }

    // Main thread (VanguardCameraSource posts to the main executor).
    private fun onCameraFirstFrame(gen: Long) {
        if (disposed) return
        val request = pending
        if (request == null || request.generation != gen || request.targetMode != MODE_CAMERA) return
        finishCameraSwitch(gen)
    }

    // Main thread. No completed capture arrived after the resume was accepted.
    private fun onCameraResumeTimeout(gen: Long) {
        Log.e(TAG, "no camera frame within ${CAMERA_RESUME_TIMEOUT_MS}ms after resume (gen=$gen)")
        if (pump != null) {
            // Image producer kept; return the camera to the suspended steady state.
            returnToImageSteadyState("camera_resume_timeout")
        } else {
            commit(MODE_NONE, null)
            Log.e(TAG, "ANDROID_LIVESTREAM_MEDIA_SOURCE_PRODUCER_LOST context=camera_resume_timeout (no pump)")
        }
        failRequest(
            gen,
            "CAMERA_RESUME_TIMEOUT",
            "No camera frame within ${CAMERA_RESUME_TIMEOUT_MS}ms; the image producer keeps running",
        )
    }

    // Main thread. Hands the Surface from the pump to the camera egress and
    // commits camera mode only once the attach was accepted.
    private fun finishCameraSwitch(gen: Long) {
        val request = pending
        if (request != null && request.generation == gen) clearTimeout(request)
        // The egress can only be attached after the pump has released the
        // Surface, so check every up-front refusal reason first, while the
        // image producer is still live and can simply be kept.
        val blocker = cameraEgressAttachBlocker()
        if (blocker != null) {
            if (pump != null) {
                Log.e(TAG, "camera egress cannot bind ($blocker); image producer kept")
                returnToImageSteadyState("egress_attach_blocked")
            } else {
                commit(MODE_NONE, null)
                Log.e(TAG, "ANDROID_LIVESTREAM_MEDIA_SOURCE_PRODUCER_LOST context=egress_attach_blocked ($blocker)")
            }
            failRequest(gen, "CAMERA_EGRESS_ATTACH_FAILED", "The camera egress cannot bind the virtual camera surface: $blocker")
            return
        }
        stopPump()
        if (bindCameraEgressOrFailClosed("camera_switch")) {
            completeRequest(gen, successMap(MODE_CAMERA, null))
        } else {
            failRequest(
                gen,
                "CAMERA_EGRESS_ATTACH_FAILED",
                "The camera egress refused the virtual camera surface after the image producer stopped; " +
                    "no producer is bound — retry setMediaSource",
            )
        }
    }

    // ── Producer helpers (main thread) ───────────────────────────────────────

    private fun stopPump() {
        val active = pump ?: return
        pump = null
        active.stop()
    }

    /** Null when an egress attach can be requested right now; otherwise the up-front refusal reason. */
    private fun cameraEgressAttachBlocker(): String? {
        val source = cameraSourceProvider() ?: return "camera source missing"
        if (!source.running) return "camera source not running"
        if (source.isCaptureSuspended) return "camera capture suspended"
        val surface = retainedSurfaceProvider() ?: return "virtual camera surface missing"
        if (!surface.isValid) return "virtual camera surface invalid"
        return null
    }

    private fun attachCameraEgress(): Boolean {
        val source = cameraSourceProvider() ?: return false
        val surface = retainedSurfaceProvider() ?: return false
        if (!surface.isValid) return false
        return source.attachEgressSurface(surface, egressWidth, egressHeight, egressMirror)
    }

    // Attaches the camera egress and commits MODE_CAMERA only if the attach
    // was accepted; otherwise records MODE_NONE (no producer bound) explicitly.
    private fun bindCameraEgressOrFailClosed(context: String): Boolean {
        if (attachCameraEgress()) {
            commit(MODE_CAMERA, null)
            Log.i(TAG, "ANDROID_LIVESTREAM_MEDIA_SOURCE_COMMITTED mode=camera context=$context")
            return true
        }
        commit(MODE_NONE, null)
        Log.e(TAG, "ANDROID_LIVESTREAM_MEDIA_SOURCE_PRODUCER_LOST context=$context (camera egress attach refused)")
        return false
    }

    // The camera was resumed for a switch that did not complete while the pump
    // is still the producer: re-suspend it so image mode keeps its invariant.
    private fun returnToImageSteadyState(reason: String) {
        if (pump == null || cameraSuspended) return
        val source = cameraSourceProvider() ?: return
        val suspended = source.suspendCapture()
        cameraSuspended = suspended || source.isCaptureSuspended
        Log.w(TAG, "camera re-suspended=$cameraSuspended after $reason; image producer kept")
    }

    // After a pump failure/rollback (pump already stopped): bring the camera
    // producer back. MODE_CAMERA is committed only once the egress is actually
    // bound; while a resume is still waiting for its first frame the stats say
    // MODE_NONE (restoration pending). Callers reply to their own request.
    private fun restoreCameraProducer(context: String) {
        val source = cameraSourceProvider()
        if (cameraSuspended) {
            cameraSuspended = false
            if (source != null && source.isCaptureSuspended) {
                commit(MODE_NONE, null)
                Log.w(TAG, "ANDROID_LIVESTREAM_MEDIA_SOURCE_RESTORE_PENDING context=$context resuming camera before egress re-bind")
                var refused = false
                source.resumeCapture(
                    onFirstFrame = {
                        // Still unbound and nothing newer took over: bind now.
                        if (!disposed && pump == null && !cameraSuspended && committedMode == MODE_NONE) {
                            bindCameraEgressOrFailClosed("restore:$context")
                        }
                    },
                    onError = { e ->
                        refused = true
                        Log.e(TAG, "camera resume during rollback failed: ${e.message}")
                    },
                )
                if (refused) {
                    cameraSuspended = source.isCaptureSuspended
                    commit(MODE_NONE, null)
                    Log.e(TAG, "ANDROID_LIVESTREAM_MEDIA_SOURCE_PRODUCER_LOST context=$context (camera resume refused)")
                }
                return
            }
        }
        bindCameraEgressOrFailClosed(context)
    }

    private fun commit(mode: String, imagePath: String?) {
        committedMode = mode
        committedImagePath = imagePath
    }

    // ── Request bookkeeping (main thread) ────────────────────────────────────

    private fun beginRequest(result: MethodChannel.Result, targetMode: String, imagePath: String?): Long {
        pending?.let { old ->
            clearTimeout(old)
            Log.i(TAG, "request gen=${old.generation} superseded")
            old.result.error("SUPERSEDED", "A newer setMediaSource request replaced this one", null)
        }
        generation++
        pending = PendingRequest(generation, result, targetMode, imagePath)
        return generation
    }

    private fun completeRequest(gen: Long, payload: Map<String, Any?>) {
        val request = pending ?: return
        if (request.generation != gen) return
        clearTimeout(request)
        pending = null
        request.result.success(payload)
    }

    private fun failRequest(gen: Long, code: String, message: String?) {
        val request = pending ?: return
        if (request.generation != gen) return
        clearTimeout(request)
        pending = null
        Log.w(TAG, "setMediaSource gen=$gen failed: $code: $message")
        request.result.error(code, message, null)
    }

    private fun cancelPending(code: String, message: String) {
        val request = pending ?: return
        clearTimeout(request)
        pending = null
        generation++
        request.result.error(code, message, null)
    }

    private fun armTimeout(gen: Long, delayMs: Long, onTimeout: () -> Unit) {
        val request = pending ?: return
        if (request.generation != gen) return
        clearTimeout(request)
        val runnable = Runnable {
            val current = pending
            if (current != null && current.generation == gen) {
                current.timeout = null
                onTimeout()
            }
        }
        request.timeout = runnable
        mainHandler.postDelayed(runnable, delayMs)
    }

    private fun clearTimeout(request: PendingRequest) {
        request.timeout?.let { mainHandler.removeCallbacks(it) }
        request.timeout = null
    }

    // ── Preconditions / validation ───────────────────────────────────────────

    private fun requireRunningCamera(result: MethodChannel.Result): VanguardCameraSource? {
        val source = cameraSourceProvider()
        if (source == null || !source.running) {
            result.error("NO_ACTIVE_CAMERA", "Vanguard camera is not running", null)
            return null
        }
        return source
    }

    private fun requireRetainedSurface(result: MethodChannel.Result): Surface? {
        val surface = retainedSurfaceProvider()
        if (surface == null || !surface.isValid) {
            result.error("NO_ACTIVE_STREAM", "No Vanguard virtual camera track is live", null)
            return null
        }
        return surface
    }

    /** Null when valid, otherwise the rejection reason. Cheap: no decode here. */
    private fun validateImagePath(path: String?): String? {
        if (path.isNullOrBlank()) return "imagePath is required"
        if (path.contains("://")) return "imagePath must be a local filesystem path, not a URI: $path"
        if (!path.startsWith("/")) return "imagePath must be absolute: $path"
        val file = File(path)
        if (!file.isFile) return "imagePath does not exist or is not a file: $path"
        if (!file.canRead()) return "imagePath is not readable: $path"
        return null
    }

    private fun successMap(mode: String, imagePath: String?): Map<String, Any?> = mapOf(
        "status" to "committed",
        "mode" to mode,
        "imagePath" to imagePath,
    )
}
