package com.connects.vanguard_media_engine.bridge

import android.hardware.HardwareBuffer
import android.view.Surface
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.diagnostics.BackendCapabilityReport
import com.connects.vanguard_media_engine.codec.PlatformCodecAdapter

class VanguardNativeBridge(
    private val lifecycleObserver: VanguardLifecycleObserver,
    private val diagnostics: VanguardDiagnostics,
    private val codecAdapter: PlatformCodecAdapter?
) {

    companion object {
        init {
            System.loadLibrary("vanguard_media_engine")
        }
    }

    external fun probeCapabilities(): BackendCapabilityReport

    external fun runAndroidDagRenderSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    external fun runAndroidDagRenderLoopSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        frameCount: Int,
    ): String

    external fun runAndroidDagPhase3CEvalRenderSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        frameCount: Int,
        frameDurationUs: Long,
    ): String

    // ── Phase 4A: MediaCodec decode → ImageReader → native DAG → Vulkan ─────
    external fun createAndroidDagPhase4ADecoderSmokeSession(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    external fun renderAndroidDagPhase4ADecoderSmokeFrame(
        sessionId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
    ): String

    external fun destroyAndroidDagPhase4ADecoderSmokeSession(
        sessionId: String,
    ): String

    // ── Phase 4B1A: Texture playback smoke ──────────────────────────────────
    external fun createAndroidDagPhase4B1TexturePlaybackSession(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    external fun renderAndroidDagPhase4B1TexturePlaybackFrame(
        sessionId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
    ): String

    external fun destroyAndroidDagPhase4B1TexturePlaybackSession(
        sessionId: String,
    ): String

    // ── Phase 4B1B: Generation-aware texture playback controls ──────────────
    external fun bumpAndroidDagPhase4B1TexturePlaybackGeneration(
        sessionId: String,
    ): String

    external fun renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration(
        sessionId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
        generationId: Long,
        rotationDegrees: Int,
        mirrorHorizontal: Boolean,
    ): String

    // ── Phase 5: MediaCodec encoder input surface smoke ─────────────────────
    external fun createAndroidDagPhase5EncoderSmokeSession(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    external fun renderAndroidDagPhase5EncoderSmokeFrame(
        sessionId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
    ): String

    external fun destroyAndroidDagPhase5EncoderSmokeSession(
        sessionId: String,
    ): String

    fun initialize() {
        val report = probeCapabilities()
        diagnostics.logCapabilities(report)
    }
}
