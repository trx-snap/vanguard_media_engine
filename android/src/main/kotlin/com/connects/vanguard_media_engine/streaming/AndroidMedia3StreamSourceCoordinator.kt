package com.connects.vanguard_media_engine.streaming

import android.os.Handler
import io.flutter.plugin.common.MethodChannel

/**
 * Diagnostic MethodChannel coordinator for Vanguard Android True-DAG
 * P6-MEDIA3-INGEST-STREAM-SOURCE-SEAM-A.
 *
 * ## Diagnostic & Video-Only Invariants
 * - **Diagnostic Only**: Exposes the Media3 decoded-frame ingest seam smoke test over
 *   MethodChannel.
 * - **Video Only**: Operates strictly on decoded video frame metadata. Zero audio track/session/
 *   routing ownership.
 * - **Zero Media3/ExoPlayer Session Ownership**: Pure metadata-seam smoke test; does not
 *   instantiate ExoPlayer, MediaCodec, ImageReader, or touch network state.
 */
class AndroidMedia3StreamSourceCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private val OWNED_METHODS = setOf(
            "runAndroidDagPhase6Media3IngestStreamSourceSeamSmoke",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "runAndroidDagPhase6Media3IngestStreamSourceSeamSmoke" -> runMedia3IngestStreamSourceSeamSmoke(args, result)
            else -> return false
        }
        return true
    }

    // P6-MEDIA3-INGEST-STREAM-SOURCE-SEAM-A: diagnostic, video-only Media3 decoded-frame ingest
    // seam proving HttpAdaptiveFrameListener can forward frame metadata into a real native
    // vanguard::sources::StreamSourceNode-backed session. No real ExoPlayer/MediaCodec/
    // ImageReader ownership, no network state, no audio, no rendering, no product/editor/app
    // wiring.
    private fun runMedia3IngestStreamSourceSeamSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        val frameCount = (args?.get("frameCount") as? Number)?.toInt() ?: 3

        Thread {
            val smokeResult = NativeStreamSourceMedia3IngestSmokeHarness.run(
                width = width,
                height = height,
                frameCount = frameCount,
            )
            mainHandler.post {
                result.success(smokeResult)
            }
        }.start()
    }
}
