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

    // ── Phase 1-Unit U: Android GLES backend offscreen EGL lifecycle smoke ──
    external fun runAndroidDagPhase1UGlesBackendSmoke(): String

    // ── Phase 1-Unit V: Android GLES backend window-surface attach/detach smoke ──
    external fun runAndroidDagPhase1VGlesSurfaceSmoke(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit W: Android GLES backend window-surface clear/swap presentation diagnostic ──
    external fun runAndroidDagPhase1WGlesWindowPresentSmoke(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit X: Android GLES backend window-surface shader-quad draw/swap presentation diagnostic ──
    external fun runAndroidDagPhase1XGlesShaderQuadSmoke(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit Y: Android GLES backend AHardwareBuffer RGBA import foundation smoke ──
    external fun runAndroidDagPhase1YGlesImportSmoke(
        bufferA: HardwareBuffer,
        bufferB: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit Z: Android GLES backend identity renderFrame textured-quad presentation smoke ──
    external fun runAndroidDagPhase1ZGlesRenderFrameSmoke(
        surface: Surface,
        bufferA: HardwareBuffer,
        bufferB: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AB: Android GLES backend diagnostic read-pixels physical smoke ──
    external fun runAndroidDagPhase1ABGlesReadPixelsSmoke(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AC: Android GLES renderFrame texture-content readback physical smoke ──
    external fun runAndroidDagPhase1ACGlesRenderFrameContentSmoke(
        surface: Surface,
        buffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AD: Android GLES renderFrame asymmetric UV mapping physical smoke ──
    external fun runAndroidDagPhase1ADGlesRenderFrameTransformMappingSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AE: Android GLES backend AHardwareBuffer acquire-fence wait/close foundation smoke ──
    external fun runAndroidDagPhase1AEGlesAcquireFenceSmoke(
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AF: Android GLES RGBX AHardwareBuffer renderFrame content readback physical smoke ──
    external fun runAndroidDagPhase1AFGlesRgbxRenderFrameContentSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AG: Android GLES AHardwareBuffer import guard fail-closed physical smoke ──
    external fun runAndroidDagPhase1AGGlesImportGuardSmoke(
        validBuffer: HardwareBuffer,
        missingUsageBuffer: HardwareBuffer,
        unsupportedFormatBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AH: Android GLES YCBCR_420_888 AHardwareBuffer import guard fail-closed physical proof ──
    external fun runAndroidDagPhase1AHGlesYcbcrImportGuardSmoke(
        validBuffer: HardwareBuffer,
        ycbcrBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AI: Android GLES/EGL extension and native-fence capability inventory physical proof ──
    external fun runAndroidDagPhase1AIGlesExtensionCapabilitySmoke(): String

    // ── Phase 1-Unit AJ: Android GLES EGL native-fence FD lifecycle physical proof ──
    external fun runAndroidDagPhase1AJGlesNativeFenceFdSmoke(): String

    // ── Phase 1-Unit AK: Android GLES releaseHardwareBuffer live release-fence output physical proof ──
    external fun runAndroidDagPhase1AKGlesReleaseFenceProductionSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AL: Android GLES releaseHardwareBuffer nullptr release-fence output physical proof ──
    external fun runAndroidDagPhase1ALGlesReleaseNullFenceSmoke(
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AM: Android GLES renderFrame -> EGL native-fence GPU chain physical proof ──
    external fun runAndroidDagPhase1AMGlesRenderFenceChainSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AN: Android GLES acquire-fence import -> renderFrame content physical proof ──
    external fun runAndroidDagPhase1ANGlesAcquireFenceRenderContentSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AR: Android GLES external texture YCBCR_420_888 AHardwareBuffer import foundation physical smoke ──
    external fun runAndroidDagPhase1ARGlesExternalTextureSmoke(
        surface: Surface,
        rgbaBuffer: HardwareBuffer,
        ycbcrBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AS: Android GLES two-texture compositor RGBA blend foundation smoke ──
    external fun runAndroidDagPhase1ASGlesTwoTextureCompositorSmoke(
        surface: Surface,
        bufferA: HardwareBuffer,
        bufferB: HardwareBuffer,
        ycbcrBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AT: Android GLES mixed external/OES two-texture composition foundation physical proof ──
    external fun runAndroidDagPhase1ATGlesMixedTextureCompositorSmoke(
        surface: Surface,
        rgbaBufferA: HardwareBuffer,
        rgbaBufferB: HardwareBuffer,
        ycbcrBufferA: HardwareBuffer,
        ycbcrBufferB: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AV: Android GLES DAG playhead evaluation + multi-frame render smoke ──
    external fun runAndroidDagPhase1AVGlesEvalRenderSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        frameCount: Int,
        frameDurationUs: Long,
    ): String

    // ── Phase 1-Unit AX: Android GLES SurfaceProducer texture DAG render smoke ──
    external fun runAndroidDagPhase1AXGlesTextureRenderSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        frameCount: Int,
        frameDurationUs: Long,
    ): String

    fun initialize() {
        val report = probeCapabilities()
        diagnostics.logCapabilities(report)
    }
}
