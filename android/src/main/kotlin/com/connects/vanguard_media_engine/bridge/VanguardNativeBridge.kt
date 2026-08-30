package com.connects.vanguard_media_engine.bridge

import android.graphics.SurfaceTexture
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

    // ── Vulkan-first export: native session seam (create/render/destroy) ────
    external fun createAndroidTimelineVulkanExportSession(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    external fun renderAndroidTimelineVulkanExportFrame(
        sessionId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
    ): String

    external fun destroyAndroidTimelineVulkanExportSession(
        sessionId: String,
    ): String

    // ── Vulkan-first export: padded/cropped decoder-buffer render seam ──────
    // Renders an aspect-preserving-fit destination sub-rect
    // ([destFitX],[destFitY])-([destFitX]+[destFitWidth],[destFitY]+[destFitHeight])
    // of the [width]x[height] output geometry, sourced from the crop rect
    // ([cropLeft],[cropTop])-([cropRight],[cropBottom]) of [hardwareBuffer],
    // which may be padded larger than the clip's real decoded source extent.
    // Native cross-checks the crop against the AHardwareBuffer's own
    // imported descriptor dimensions, not just the Kotlin-supplied crop
    // rect, and validates the destination rect lies fully within
    // [width]x[height]. [rotationDegrees] must be exactly 0, 90, 180, or 270
    // -- native fails closed before importing or rendering the buffer for
    // any other value. Callers that want the full output extent (no
    // letterbox/pillarbox) pass destFitX=0, destFitY=0, destFitWidth=width,
    // destFitHeight=height.
    // [colorMatrix] (Phase 10), when non-null, must be exactly 20 raw
    // (un-normalized) finite floats -- the same 4x5 row-major
    // ColorFilter.matrix convention as AndroidTimelineVideoEncoder's GLES
    // uniform upload. Native validates the length before importing the
    // buffer and fails closed with "vulkan_color_matrix_invalid:len=N" on
    // mismatch; native normalizes the four additive offset entries (indices
    // 4, 9, 14, 19) by /255.0 exactly once. Null means identity (no filter).
    external fun renderAndroidTimelineVulkanExportFrameCropped(
        sessionId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        cropLeft: Int,
        cropTop: Int,
        cropRight: Int,
        cropBottom: Int,
        rotationDegrees: Int,
        destFitX: Int,
        destFitY: Int,
        destFitWidth: Int,
        destFitHeight: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
        colorMatrix: FloatArray?,
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
    // Phase 1-Unit AY extends this route with a diagnostic-only frameDelayMs
    // (default 0, AX-compatible) used to hold the frame loop open long
    // enough for an active-dispose/cancellation physical proof.
    // Phase 1-Unit AZ extends this route with rotationDegrees (default 0)
    // and mirrorHorizontal (default false) render-transform arguments,
    // preserving AX/AY-compatible defaults.
    external fun runAndroidDagPhase1AXGlesTextureRenderSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        frameCount: Int,
        frameDurationUs: Long,
        frameDelayMs: Int,
        rotationDegrees: Int,
        mirrorHorizontal: Boolean,
    ): String

    // ── Phase 1-Unit BB: Android GLES SurfaceProducer texture DAG two-source composition & playhead evaluation smoke ──
    // Phase 1-Unit BC extends this route with a diagnostic-only frameDelayMs
    // (default 0, BB-compatible), matching the Unit AY pattern, used to hold
    // the frame loop open long enough for an active-dispose/cancellation
    // physical proof.
    // Phase 1-Unit BD extends this route with independent per-source
    // rotationDegrees/mirrorHorizontal render-transform arguments (default
    // 0 / false, BB/BC-compatible), matching the Unit AZ pattern.
    // Phase 1-Unit BE extends this route with independent per-source
    // sourceKindA/sourceKindB arguments ("2d" or "oes", default "2d",
    // BB/BC/BD-compatible) selecting the target permutation (2D vs OES) for
    // each source's HardwareBuffer import.
    external fun runAndroidDagPhase1BBGlesTextureCompositionDagSmoke(
        surface: Surface,
        bufferA: HardwareBuffer,
        bufferB: HardwareBuffer,
        width: Int,
        height: Int,
        frameCount: Int,
        frameDurationUs: Long,
        frameDelayMs: Int,
        rotationDegreesA: Int,
        mirrorHorizontalA: Boolean,
        rotationDegreesB: Int,
        mirrorHorizontalB: Boolean,
        sourceKindA: String,
        sourceKindB: String,
    ): String

    // ── Phase 1-Unit AW-OES: Android GLES decoded SurfaceTexture/OES DAG render foundation ──
    // Session-based route (create/render/destroy), matching the Phase 4A
    // pattern. Original Phase 1-Unit AW (ImageReader.PRIVATE +
    // AHardwareBuffer import of the decoded frame) remains DEFERRED /
    // VERIFIED_PHYSICAL_FAILURE (`ahb_import_unsupported_format`); this route
    // decodes onto a SurfaceTexture bound to a native-allocated
    // GL_TEXTURE_EXTERNAL_OES texture instead and never imports an
    // AHardwareBuffer.
    external fun createAndroidDagPhase1AWOESSession(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    external fun renderAndroidDagPhase1AWOESFrame(
        sessionId: String,
        surfaceTexture: SurfaceTexture,
        presentationTimeUs: Long,
        frameIndex: Int,
        rotationDegrees: Int,
        mirrorHorizontal: Boolean,
    ): String

    external fun destroyAndroidDagPhase1AWOESSession(
        sessionId: String,
    ): String

    // ── P2-CONCURRENT-DEC: Multi-stream concurrent hardware decode ingest ───
    // validation diagnostic. Additive-only: validates sourceNodeId admission and
    // imports/releases an AHardwareBuffer within one JNI call per ingest, with no
    // cross-call buffer retention and no PiP/compositor presentation.
    external fun createAndroidDagPhase2ConcurrentDecodeSession(
        sourceNodeIds: Array<String>,
    ): String

    external fun ingestAndroidDagPhase2ConcurrentDecodeFrame(
        sessionId: String,
        sourceNodeId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
        generationId: Long,
        rotationDegrees: Int,
        mirrorHorizontal: Boolean,
    ): String

    external fun destroyAndroidDagPhase2ConcurrentDecodeSession(
        sessionId: String,
    ): String

    // ── P2-CPP-PASSTHROUGH: PassthroughRemuxSinkNode native foundation ──────
    // validation. Additive-only: validates DAG topology/timeline correctness
    // for a passthrough remux sink ahead of any production remux work. Kotlin
    // remains the sole owner of MediaExtractor/MediaMuxer; native never
    // touches media file IO here.
    external fun createAndroidDagPhase2PassthroughRemuxSinkSession(
        sourceNodeId: String,
        sinkNodeId: String,
        startPtsUs: Long,
        durationUs: Long,
        requiresAudio: Boolean,
    ): String

    external fun validateAndroidDagPhase2PassthroughRemuxSinkSession(
        sessionId: String,
        timelinePtsUs: Long,
        connectVideo: Boolean,
        connectAudio: Boolean,
        processingNodeCount: Int,
    ): String

    external fun destroyAndroidDagPhase2PassthroughRemuxSinkSession(
        sessionId: String,
    ): String

    // ── P2-AUDIO-DEC-BRIDGE: bounded native decoded-PCM audio source bridge ─
    // foundation. Kotlin remains the sole owner of MediaExtractor/MediaCodec
    // OS audio decoding; native only receives already-decoded 16-bit
    // interleaved PCM chunks over a direct java.nio.ByteBuffer and
    // validates/accumulates them as a DAG audio source boundary for future
    // native C++ audio nodes. No file IO, no production mixdown/export route
    // changes.
    external fun createAndroidDagPhase2AudioDecodeBridgeSession(
        sourceNodeId: String,
        sampleRate: Int,
        channelCount: Int,
        expectedFrameCount: Int,
        timelineStartPtsUs: Long,
    ): String

    external fun ingestAndroidDagPhase2AudioDecodeBridgePcm(
        sessionId: String,
        pcm16Buffer: java.nio.ByteBuffer,
        frameCount: Int,
        bufferPtsUs: Long,
        isEndOfStream: Boolean,
    ): String

    external fun validateAndroidDagPhase2AudioDecodeBridgeSession(
        sessionId: String,
    ): String

    external fun destroyAndroidDagPhase2AudioDecodeBridgeSession(
        sessionId: String,
    ): String

    // ── P4-AUDIO-MIXBUS: bounded native PCM16 mix-bus foundation diagnostic ──
    // AudioMixBusNode is platform-neutral C++: no JNI/Android/thread/file IO
    // inside the node itself. Native only mixes already-decoded interleaved
    // PCM16 tracks handed across direct java.nio.ByteBuffers; Kotlin remains
    // the sole owner of MediaExtractor/MediaCodec/AudioTrack. No decoder, no
    // AAC, no export/mixdown route, no realtime playback wiring here.
    external fun createAndroidDagPhase4AudioMixBusSession(
        nodeId: String,
        sampleRate: Int,
        channelCount: Int,
        maxFramesPerMix: Int,
    ): String

    external fun addAndroidDagPhase4AudioMixBusTrack(
        sessionId: String,
        pcm16Buffer: java.nio.ByteBuffer,
        frameCount: Int,
        sampleRate: Int,
        channelCount: Int,
        gain: Double,
    ): String

    external fun mixAndroidDagPhase4AudioMixBusSession(
        sessionId: String,
        framesToMix: Int,
        outBuffer: java.nio.ByteBuffer,
    ): String

    external fun destroyAndroidDagPhase4AudioMixBusSession(
        sessionId: String,
    ): String

    // ── P3-CAM-CONCURRENT: Camera2 dual-camera concurrent PRIVATE AHardwareBuffer ─
    // ingest validation diagnostic. Kotlin remains the sole owner of Camera2
    // device/session lifecycle (CameraManager.openCamera, CameraCaptureSession);
    // native only validates cameraSourceNodeId admission and imports/releases an
    // AHardwareBuffer within one JNI call per ingest, with no cross-call buffer
    // retention, no Camera2 ownership in C++, and no compositor/PiP/split/
    // recording/export claim. Mirrors the P2-CONCURRENT-DEC registry pattern with
    // P3 camera-specific naming.
    external fun createAndroidDagPhase3CameraConcurrentIngestSession(
        cameraSourceNodeIds: Array<String>,
    ): String

    external fun ingestAndroidDagPhase3CameraConcurrentFrame(
        sessionId: String,
        cameraSourceNodeId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        cameraTimestampNs: Long,
        frameIndex: Int,
        generationId: Long,
        rotationDegrees: Int,
        mirrorHorizontal: Boolean,
    ): String

    external fun destroyAndroidDagPhase3CameraConcurrentIngestSession(
        sessionId: String,
    ): String

    // ── P3-MULTICAM-NODE: MultiCamCompositorNode native topology + PiP/split ──
    // layout-math foundation diagnostic. Pure in-memory C++ math only: builds
    // MultiCamCompositorNode instances and calls the free ComputeMultiCamLayout()
    // function with synthetic inputs. No threads, no Camera2, no GLES/Vulkan,
    // no file IO, no recording/export claim.
    external fun runAndroidDagPhase3MultiCamCompositorSmoke(): String

    // ── P3-MULTICAM-NODE: GLES-first spatial multi-texture diagnostic render ──
    // pass physical proof. Render-only: draws two already-imported textures
    // into two independent glViewport-scoped pixel rectangles derived from
    // vanguard::compositors::ComputeMultiCamLayout() (PiP/split layout math),
    // via GlesBackend::diagnosticRenderMultiCamSpatialCompositeForReadback()/
    // diagnosticPresentMultiCamSpatialComposite(). Native fills bufferA solid
    // opaque red and bufferB solid opaque blue; the caller allocates both
    // buffers uninitialized. No camera open, no Vulkan, no OES physical
    // proof, no recording/export, no product UI.
    external fun runAndroidDagPhase3MultiCamSpatialGlesRenderSmoke(
        surface: Surface,
        bufferA: HardwareBuffer,
        bufferB: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    fun initialize() {
        val report = probeCapabilities()
        diagnostics.logCapabilities(report)
    }
}
