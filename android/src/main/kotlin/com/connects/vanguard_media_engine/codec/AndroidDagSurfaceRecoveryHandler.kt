package com.connects.vanguard_media_engine.codec

import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaExtractor
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import io.flutter.view.TextureRegistry
import java.util.concurrent.LinkedBlockingQueue

//
// Result type
//

/**
 * Vanguard Android True-DAG Phase 4B2B3B: surface restore result.
 *
 * Returned by [AndroidDagSurfaceRecoveryHandler.restoreSurface].
 * The session assigns its own fields from this value; the handler never
 * mutates session state directly.
 */
data class AndroidDagSurfaceRestoreResult(
    /** True when the restore (and optional preroll) completed without error. */
    val success: Boolean,
    /**
     * The re-fetched [Surface] that is now backing the native session.
     * Null on failure.
     */
    val surface: Surface?,
    /**
     * The newly-created native session ID.
     * Null on any failure that occurred at or after session creation
     * (the handler destroys the session before returning null here).
     */
    val sessionId: String?,
    /** The generation ID after the final bump performed during restore. */
    val generationId: Long,
    /** Updated rendered-frame count after optional preroll. */
    val renderedFrames: Int,
    /** Updated last-rendered PTS (us) after optional preroll. */
    val lastRenderedPtsUs: Long,
    /**
     * Diagnostic failure token, mirroring the raw reason tokens used
     * in [AndroidDagTexturePlaybackControlSession.lastRestoreFailureReason].
     * Null on success.
     */
    val failureReason: String?,
)

//
// Handler
//

/**
 * Vanguard Android True-DAG Phase 4B2B3B: stateless surface-restore helper.
 *
 * Encapsulates the surface-restore algorithm that was previously inlined in
 * [AndroidDagTexturePlaybackControlSession.handleSurfaceAvailable]:
 *
 *  1. Re-fetch + validate the surface from [surfaceProducer].
 *  2. Create a new native DAG/Vulkan session via [bridge].
 *  3. Parse the returned session ID.
 *  4. Bump the playback generation.
 *  5. Optionally seek + preroll via [AndroidDagSeekPrerollEngine] when
 *     [lastRenderedPtsUs] > 0.
 *  6. On ANY failure after native-session creation, destroy that session
 *     exactly once before returning a failure result.
 *
 * **Does NOT**:
 *  - Mutate session fields directly.
 *  - Own a HandlerThread, Choreographer callback, pending-play callback,
 *    or dispose lifecycle.
 *  - Call [surfaceProducer.setSize] (the session already did this during
 *    prepare and the surface producer retains the configured size).
 */
class AndroidDagSurfaceRecoveryHandler {

    companion object {
        private const val TAG = "DagSurfaceRecoveryHndlr"
    }

    /**
     * Executes the full surface-restore sequence.
     *
     * Must be called on the session's dedicated HandlerThread so that
     * ImageReader callbacks and [AndroidDagSeekPrerollEngine] run in the
     * correct threading context.
     *
     * @param surfaceProducer Flutter texture surface producer to re-fetch from.
     * @param bridge          Native Vanguard/Vulkan bridge.
     * @param extractor       MediaExtractor - required only when [lastRenderedPtsUs] > 0.
     * @param codec           MediaCodec   - required only when [lastRenderedPtsUs] > 0.
     * @param imageReader     ImageReader  - required only when [lastRenderedPtsUs] > 0.
     * @param imageQueue      Shared image queue shared with the session.
     * @param videoWidth      Frame width used when creating the native session.
     * @param videoHeight     Frame height used when creating the native session.
     * @param lastRenderedPtsUs Non-zero triggers preroll seek back to this PTS.
     * @param renderedFrames  Frame counter forwarded to the preroll engine.
     * @param currentGenerationId Current generation ID before any bump.
     * @param isDisposed      Lambda returning true when the parent session has been disposed.
     * @param shouldCancel    Lambda returning true when the restore/preroll should abort early.
     * @return [AndroidDagSurfaceRestoreResult] - inspect [AndroidDagSurfaceRestoreResult.success].
     */
    fun restoreSurface(
        surfaceProducer: TextureRegistry.SurfaceProducer,
        bridge: VanguardNativeBridge,
        extractor: MediaExtractor?,
        codec: MediaCodec?,
        imageReader: ImageReader?,
        imageQueue: LinkedBlockingQueue<Image>,
        videoWidth: Int,
        videoHeight: Int,
        lastRenderedPtsUs: Long,
        renderedFrames: Int,
        currentGenerationId: Long,
        isDisposed: () -> Boolean,
        shouldCancel: () -> Boolean,
    ): AndroidDagSurfaceRestoreResult {

        // Tracks the session ID created during this attempt so we can guarantee
        // exactly-once destruction on any subsequent failure.
        var restoreCreatedSessionId: String? = null

        try {
            // Guard: bail immediately if the session was disposed before we started.
            if (isDisposed()) {
                Log.d(TAG, "restoreSurface: cancelled - session disposed before surface fetch")
                return failure("restore_cancelled_disposed", currentGenerationId, renderedFrames, lastRenderedPtsUs)
            }

            // Step 1: Re-fetch and validate surface
            val newSurface = surfaceProducer.getSurface()
            if (!newSurface.isValid) {
                Log.w(TAG, "restoreSurface: getSurface() returned invalid surface")
                return failure("surface_invalid_after_available", currentGenerationId, renderedFrames, lastRenderedPtsUs)
            }

            // Step 2: Create native session
            val createResult = bridge.createAndroidDagPhase4B1TexturePlaybackSession(
                newSurface,
                videoWidth,
                videoHeight,
            )
            if (!createResult.startsWith("status=OK;")) {
                Log.e(TAG, "restoreSurface: native session create failed: $createResult")
                return failure("native_session_create_failed_on_restore;$createResult", currentGenerationId, renderedFrames, lastRenderedPtsUs)
            }

            // Step 3: Parse session ID
            val newSid = createResult.substringAfter("sessionId=").substringBefore(";").ifEmpty { null }
            if (newSid == null) {
                // No session was successfully recorded - nothing to destroy.
                Log.e(TAG, "restoreSurface: session id parse failed")
                return failure("session_id_parse_failed_on_restore", currentGenerationId, renderedFrames, lastRenderedPtsUs)
            }
            restoreCreatedSessionId = newSid

            // Step 4: Bump generation
            val bumpRes = bridge.bumpAndroidDagPhase4B1TexturePlaybackGeneration(newSid)
            if (!bumpRes.startsWith("status=OK;")) {
                Log.e(TAG, "restoreSurface: generation bump failed: $bumpRes")
                destroySafely(bridge, newSid)
                restoreCreatedSessionId = null
                return failure("generation_bump_failed_on_restore;$bumpRes", currentGenerationId, renderedFrames, lastRenderedPtsUs)
            }
            val genStr = bumpRes.substringAfter("generationId=").substringBefore(";")
            var activeGenId = genStr.toLongOrNull() ?: (currentGenerationId + 1)

            // Guard: check disposal after native session is live but before preroll.
            if (isDisposed()) {
                Log.d(TAG, "restoreSurface: cancelled -- session disposed after generation bump")
                destroySafely(bridge, newSid)
                restoreCreatedSessionId = null
                return failure("restore_cancelled_disposed", activeGenId, renderedFrames, lastRenderedPtsUs)
            }

            // Step 5: Optional preroll
            if (lastRenderedPtsUs > 0) {
                if (extractor == null || codec == null || imageReader == null) {
                    Log.e(TAG, "restoreSurface: preroll resources null (ex=$extractor dec=$codec reader=$imageReader)")
                    destroySafely(bridge, newSid)
                    restoreCreatedSessionId = null
                    return failure("restore_resources_null_on_preroll", activeGenId, renderedFrames, lastRenderedPtsUs)
                }

                // Drain queued images before seeking
                while (true) { val img = imageQueue.poll() ?: break; try { img.close() } catch (_: Throwable) {} }
                codec.flush()
                // NOTE: inputDone / outputDone reset is performed by the session before calling
                // restoreSurface() when preroll is expected (lastRenderedPtsUs > 0).
                extractor.seekTo(lastRenderedPtsUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

                // Extra generation bump before preroll (mirrors original behavior)
                val prerollBumpRes = bridge.bumpAndroidDagPhase4B1TexturePlaybackGeneration(newSid)
                if (prerollBumpRes.startsWith("status=OK;")) {
                    val prerollGenStr = prerollBumpRes.substringAfter("generationId=").substringBefore(";")
                    activeGenId = prerollGenStr.toLongOrNull() ?: (activeGenId + 1)
                }

                val engineResult = AndroidDagSeekPrerollEngine().run(
                    extractor = extractor,
                    codec = codec,
                    imageReader = imageReader,
                    imageQueue = imageQueue,
                    bridge = bridge,
                    sessionId = newSid,
                    videoWidth = videoWidth,
                    videoHeight = videoHeight,
                    seekTargetUs = lastRenderedPtsUs,
                    currentGenerationId = activeGenId,
                    renderedFramesBefore = renderedFrames,
                    deadlineMs = System.currentTimeMillis() + 8000L,
                    shouldCancel = shouldCancel,
                )

                if (engineResult.pass) {
                    Log.i(TAG, "restoreSurface: preroll OK; pts=${engineResult.seekRenderedPtsUs}")
                    return AndroidDagSurfaceRestoreResult(
                        success = true,
                        surface = newSurface,
                        sessionId = newSid,
                        generationId = engineResult.generationId,
                        renderedFrames = engineResult.renderedFrames,
                        lastRenderedPtsUs = engineResult.lastRenderedPtsUs,
                        failureReason = null,
                    )
                } else {
                    val failReason = if (shouldCancel()) {
                        "surface_relost_during_preroll"
                    } else {
                        "preroll_failed:${engineResult.failureReason}"
                    }
                    Log.w(TAG, "restoreSurface: preroll failed: $failReason")
                    destroySafely(bridge, newSid)
                    restoreCreatedSessionId = null
                    return failure(failReason, activeGenId, renderedFrames, lastRenderedPtsUs)
                }
            }

            // -- No preroll needed -- session is live and healthy
            Log.i(TAG, "restoreSurface: restore complete (no preroll); gen=$activeGenId")
            return AndroidDagSurfaceRestoreResult(
                success = true,
                surface = newSurface,
                sessionId = newSid,
                generationId = activeGenId,
                renderedFrames = renderedFrames,
                lastRenderedPtsUs = lastRenderedPtsUs,
                failureReason = null,
            )

        } catch (t: Throwable) {
            Log.e(TAG, "restoreSurface: exception during restore", t)
            val leaked = restoreCreatedSessionId
            if (leaked != null) {
                destroySafely(bridge, leaked)
                restoreCreatedSessionId = null
            }
            return failure("restore_exception:${t.javaClass.simpleName}", currentGenerationId, renderedFrames, lastRenderedPtsUs)
        }
    }

    // -- Private helpers

    private fun failure(
        reason: String,
        generationId: Long,
        renderedFrames: Int,
        lastRenderedPtsUs: Long,
    ) = AndroidDagSurfaceRestoreResult(
        success = false,
        surface = null,
        sessionId = null,
        generationId = generationId,
        renderedFrames = renderedFrames,
        lastRenderedPtsUs = lastRenderedPtsUs,
        failureReason = reason,
    )

    private fun destroySafely(bridge: VanguardNativeBridge, sessionId: String) {
        try {
            bridge.destroyAndroidDagPhase4B1TexturePlaybackSession(sessionId)
        } catch (_: Throwable) {}
    }
}
