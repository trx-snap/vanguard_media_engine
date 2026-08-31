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

        // ── P4 True-DAG V4.3 sub-slice G1: audio decoder ring ingest diagnostic session core ─
        // Native JNI session seam for the future real MediaCodec-to-
        // AudioDecoderRingWriter ingest proof. Kotlin will remain the sole
        // owner of MediaCodec/MediaExtractor; native only accepts
        // already-decoded interleaved little-endian signed PCM16 handed
        // across a direct java.nio.ByteBuffer (data starts at byte offset 0)
        // and feeds it through AudioDecoderRingWriter into an
        // AudioSpscAudioRingBuffer, then drains/verifies on the reader side.
        // Every non-destroy call must run on the session's creating thread
        // (native fails closed with status=wrong_owner_thread otherwise).
        // No native worker threads, no AudioTrack/AAudio/OpenSL/Oboe, no
        // realtime or audible playback, no file IO, no wall-clock reads.

        // Returns an opaque session handle, or 0 on invalid input
        // (sampleRate <= 0, channelCount not in {1,2}, ringCapacityFrames
        // not a power of two in [64, 65536]) or when the 4-live-session
        // registry cap is reached.
        external fun createAudioDecoderRingIngestSmokeSession(
            sampleRate: Int,
            channelCount: Int,
            ringCapacityFrames: Int,
        ): Long

        // Accepted frames are clamped to
        // min(frameCount, 8192, framesThatFitInBuffer).
        external fun ingestAudioDecoderRingPcm16(
            sessionHandle: Long,
            pcm: java.nio.ByteBuffer,
            frameCount: Int,
        ): String

        external fun drainAudioDecoderRingIngestSession(
            sessionHandle: Long,
            maxFrames: Int,
        ): String

        external fun requestAudioDecoderRingIngestSeek(
            sessionHandle: Long,
            targetFrame: Long,
        ): String

        external fun setAudioDecoderRingIngestEos(
            sessionHandle: Long,
        ): String

        // Idempotent erase-once; callable from any thread. Handle 0/unknown
        // returns status=not_found.
        external fun destroyAudioDecoderRingIngestSmokeSession(
            sessionHandle: Long,
        ): String

        // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice H1: session-scoped closed-loop audio graph pipeline seam ─
        // Step-driven native session over the full diagnostic rig:
        // AudioDecoderRingWriter -> source AudioSpscAudioRingBuffer ->
        // RingBufferAudioSampleProvider -> GraphAudioScheduler ->
        // AudioMixBusNode -> ClockedAudioTransportCoordinator -> output
        // AudioSpscAudioRingBuffer -> consumer drain. Exactly one routed
        // source track at unit gain; Kotlin hands synthetic interleaved
        // little-endian signed PCM16 across a direct java.nio.ByteBuffer and
        // derives every clock tick itself (native never reads a wall clock).
        // Every non-destroy call must run on the session's creating thread
        // (native fails closed with status=wrong_owner_thread otherwise).
        // No native worker threads, no MediaCodec/MediaExtractor, no
        // AudioTrack/AAudio/OpenSL/Oboe, no realtime or audible playback,
        // no file IO. Forward-only seek; writer-local EOS only.

        // Returns an opaque session handle, or 0 on invalid input
        // (sampleRate not in [8000, 192000], channelCount not in {1,2},
        // maxFramesPerMix not in [1, 8192], ring capacities not powers of
        // two in [64, 65536], outputRingCapacityFrames < maxFramesPerMix,
        // sourceRingCapacityFrames < 2*maxFramesPerMix) or when the
        // 4-live-session registry cap is reached.
        external fun createAudioGraphPipelineSmokeSession(
            sampleRate: Int,
            channelCount: Int,
            sourceRingCapacityFrames: Int,
            outputRingCapacityFrames: Int,
            maxFramesPerMix: Int,
        ): Long

        // Accepted frames are clamped to
        // min(frameCount, 8192, framesThatFitInBuffer).
        external fun ingestAudioGraphPipelinePcm16(
            handle: Long,
            pcm: java.nio.ByteBuffer,
            frameCount: Int,
        ): String

        // Starts the transport clock at (sysTimeNs, mediaPtsUs) and parks
        // the dispatch cursor awaiting the output ring's seek ack; drain the
        // ack before the first dispatching step.
        external fun startAudioGraphPipeline(
            handle: Long,
            mediaPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // One bounded dispatch attempt at the caller-derived sysTimeNs tick.
        // flushTail=false requires a full window of source frames
        // (status=deferred_insufficient_source otherwise, with no mutation);
        // flushTail=true (writer EOS required) advances exactly the
        // remaining source frames (tail_flush_partial_window /
        // tail_flush_complete). Every step status reports
        // sourceAvailableReadFrames.
        external fun stepAudioGraphPipeline(
            handle: Long,
            sysTimeNs: Long,
            flushTail: Boolean,
        ): String

        // Output-ring reader side: consumes a pending start/seek ack first,
        // then pops and checksums up to maxFrames of mixed PCM.
        external fun drainAudioGraphPipelineOutput(
            handle: Long,
            maxFrames: Int,
        ): String

        // P4-AUDIO-AUDIOTRACK-OUTPUT-SINK-WRITE (sub-slice I) output-ring
        // reader: consumes a pending start/seek ack first, then pops up to
        // maxFrames of mixed PCM16 directly into the caller's direct
        // ByteBuffer at byte offset 0 (single pop, no native scratch) so the
        // same buffer can be handed to android.media.AudioTrack.
        // maxFrames == 0 is a legal ack-only read. A single run must pop
        // frames through exactly one of drain/read.
        external fun readAudioGraphPipelineOutputPcm16(
            handle: Long,
            pcmBuffer: java.nio.ByteBuffer,
            maxFrames: Int,
        ): String

        // Forward-only seek. Requires a fully drained output ring, an empty
        // source ring, and targetFrame >= the provider's cursor; the caller
        // must drain the output-ring ack next.
        external fun seekAudioGraphPipeline(
            handle: Long,
            targetPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // Writer-local EOS only (cleared by the next successful seek).
        external fun setAudioGraphPipelineEos(
            handle: Long,
        ): String

        // Full diagnostic snapshot, including the fixed-at-construction
        // scratch/storage capacities used to prove zero native steady-state
        // allocation across repeated cycles.
        external fun snapshotAudioGraphPipeline(
            handle: Long,
        ): String

        // Idempotent erase-once; callable from any thread. Handle 0/unknown
        // returns status=not_found.
        external fun destroyAudioGraphPipelineSmokeSession(
            handle: Long,
        ): String

        // ── P4-AUDIO-MULTI-SOURCE-GRAPH-PIPELINE: session-scoped two-source closed-loop audio graph pipeline seam ─
        // Step-driven native session over the two-track diagnostic rig:
        // per-track AudioDecoderRingWriter -> source AudioSpscAudioRingBuffer
        // -> RingBufferAudioSampleProvider (track 0 = real-decoder PCM,
        // track 1 = Kotlin-synthesized PCM) -> GraphAudioScheduler ->
        // AudioMixBusNode (multi_source_src0 -> primary_audio_in,
        // multi_source_src1 -> secondary_audio_in, unit gain) ->
        // ClockedAudioTransportCoordinator -> output ring -> consumer drain.
        // The native frame axis is the SHARED ACCEPTED FRAME COUNT (full
        // overlap only): the joint dispatch gate needs a full window on BOTH
        // source rings, the joint tail flush needs BOTH writers EOS with
        // identical residuals, and the one forward seek reanchors BOTH
        // tracks at a single accepted frame cursor. Handles minted here are
        // NOT interchangeable with the one-source graph-pipeline session
        // registry. Every non-destroy call must run on the session's
        // creating thread (native fails closed with
        // status=wrong_owner_thread otherwise). No native worker threads, no
        // MediaCodec/MediaExtractor, no AudioTrack/AAudio/OpenSL/Oboe, no
        // realtime or audible playback, no file IO, no wall-clock reads.

        // Returns an opaque session handle, or 0 on invalid input (same
        // bounds as the one-source seam) or when the two-track route did not
        // resolve exactly (routedSourceCount 2 in src0, src1 order) or the
        // 4-live-session registry cap is reached.
        external fun createMultiSourceAudioGraphPipelineSmokeSession(
            sampleRate: Int,
            channelCount: Int,
            sourceRingCapacityFrames: Int,
            outputRingCapacityFrames: Int,
            maxFramesPerMix: Int,
        ): Long

        // Per-track producer side; trackIndex must be 0 or 1
        // (status=invalid_track_index otherwise, no mutation). Accepted
        // frames are clamped to min(frameCount, 8192, framesThatFitInBuffer).
        external fun ingestMultiSourceAudioGraphPipelinePcm16(
            handle: Long,
            trackIndex: Int,
            pcmBuffer: java.nio.ByteBuffer,
            frameCount: Int,
        ): String

        // Starts the transport clock at (sysTimeNs, mediaPtsUs) and parks
        // the dispatch cursor awaiting the output ring's seek ack; drain the
        // ack before the first dispatching step.
        external fun startMultiSourceAudioGraphPipeline(
            handle: Long,
            mediaPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // One bounded dispatch attempt at the caller-derived sysTimeNs tick.
        // flushTail=false requires a full window on BOTH source rings
        // (status=deferred_insufficient_joint_source otherwise, with no
        // mutation; no EOS term); flushTail=true requires BOTH writers EOS
        // and identical per-track residuals
        // (tail_flush_track_length_mismatch otherwise, no zero-fill) and
        // advances exactly min(avail0, avail1, maxFramesPerMix) frames
        // (tail_flush_partial_window / tail_flush_complete). Every step
        // status reports both per-track sourceAvailableReadFrames.
        external fun stepMultiSourceAudioGraphPipeline(
            handle: Long,
            sysTimeNs: Long,
            flushTail: Boolean,
        ): String

        // Output-ring reader side: consumes a pending start/seek ack first,
        // then pops and checksums up to maxFrames of mixed PCM.
        external fun drainMultiSourceAudioGraphPipelineOutput(
            handle: Long,
            maxFrames: Int,
        ): String

        // P4-AUDIO-MULTI-SOURCE-AUDIOTRACK-SINK (sub-slice K) output-ring
        // reader: consumes a pending start/seek ack first, then pops up to
        // maxFrames of mixed two-track PCM16 directly into the caller's
        // direct ByteBuffer at byte offset 0 (single pop, no native
        // scratch) so the same buffer can be handed to
        // android.media.AudioTrack. maxFrames == 0 is a legal ack-only
        // read. A single run must pop frames through exactly one of
        // drain/read.
        external fun readMultiSourceAudioGraphPipelineOutputPcm16(
            sessionHandle: Long,
            pcmBuffer: java.nio.ByteBuffer,
            maxFrames: Int,
        ): String

        // Forward-only joint seek. Requires a fully drained output ring,
        // both source rings empty, and the shared accepted-frame axis
        // intact (track_frame_axis_divergence otherwise); reanchors BOTH
        // tracks at the same accepted frame. The caller must drain the
        // output-ring ack next.
        external fun seekMultiSourceAudioGraphPipeline(
            handle: Long,
            targetPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // Per-track writer-local EOS only (cleared by the next successful
        // seek); trackIndex must be 0 or 1. The joint tail flush requires
        // both tracks EOS together.
        external fun setMultiSourceAudioGraphPipelineEos(
            handle: Long,
            trackIndex: Int,
        ): String

        // Full diagnostic snapshot with Track0/Track1-suffixed per-track
        // keys, the fixed-at-construction scratch/storage capacities used to
        // prove zero native steady-state allocation, and the verbatim proof
        // boundary. Never silently truncated (status=snapshot_overflow fails
        // closed instead).
        external fun snapshotMultiSourceAudioGraphPipeline(
            handle: Long,
        ): String

        // Idempotent erase-once; callable from any thread. Handle 0/unknown
        // returns status=not_found.
        external fun destroyMultiSourceAudioGraphPipelineSmokeSession(
            handle: Long,
        ): String

        // ── P4-AUDIO-DECODER-SOURCE-NODE-WIRING: session-scoped node-owned-source closed-loop audio graph pipeline seam ─
        // Step-driven native session over the node-owned-transport diagnostic
        // rig: DecodedAudioPcmSourceNode (6-arg constructor) owns its source
        // AudioSpscAudioRingBuffer + AudioDecoderRingWriter +
        // RingBufferAudioSampleProvider triple by composition, and
        // GraphAudioScheduler auto-discovers the provider from graph
        // topology alone (tag-dispatched constructor; no external provider
        // map, no hybrid routing) -> AudioMixBusNode ->
        // ClockedAudioTransportCoordinator -> output ring -> consumer drain.
        // Diagnostic node-owned decoded audio source ring/provider wiring
        // proof only: no production export or pass-2 graph reroute, no
        // product/editor UI, no ConnectsApp, no streaming/cache, no iOS.
        // Kotlin hands synthetic interleaved little-endian signed PCM16
        // across a direct java.nio.ByteBuffer and derives every clock tick
        // itself (native never reads a wall clock). Every non-destroy call
        // must run on the session's creating thread (native fails closed
        // with status=wrong_owner_thread otherwise). No native worker
        // threads, no MediaCodec/MediaExtractor ownership in C++, no
        // AudioTrack/AAudio/OpenSL/Oboe, no realtime/audio-focus/route/
        // dead-object/audible/speaker/latency/glitch claims, no file IO.
        // Handles minted here are NOT interchangeable with any other
        // pipeline session registry. Forward-only seek; writer-local EOS
        // only.

        // Returns an opaque session handle, or 0 on invalid input
        // (sampleRate not in [8000, 192000], channelCount not in {1,2},
        // maxFramesPerMix not in [1, 8192], ring capacities not powers of
        // two in [64, 65536], outputRingCapacityFrames < maxFramesPerMix,
        // sourceRingCapacityFrames < 2*maxFramesPerMix), when the
        // auto-discovered route did not resolve to exactly the one
        // node-owned source track, or when the 4-live-session registry cap
        // is reached. sourceRingCapacityFrames is the node's explicit
        // ringCapacityFrames constructor argument.
        external fun createNodeOwnedAudioSourceGraphPipelineSmokeSession(
            sampleRate: Int,
            channelCount: Int,
            sourceRingCapacityFrames: Int,
            outputRingCapacityFrames: Int,
            maxFramesPerMix: Int,
        ): Long

        // Producer side, writing through the NODE-OWNED ring writer.
        // Accepted frames are clamped to
        // min(frameCount, 8192, framesThatFitInBuffer).
        external fun ingestNodeOwnedAudioSourceGraphPipelinePcm16(
            handle: Long,
            pcm: java.nio.ByteBuffer,
            frameCount: Int,
        ): String

        // Starts the transport clock at (sysTimeNs, mediaPtsUs) and parks
        // the dispatch cursor awaiting the output ring's seek ack; drain the
        // ack before the first dispatching step.
        external fun startNodeOwnedAudioSourceGraphPipeline(
            handle: Long,
            mediaPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // One bounded dispatch attempt at the caller-derived sysTimeNs tick;
        // the scheduler pulls from the auto-discovered node-owned provider.
        // flushTail=false requires a full window of source frames
        // (status=deferred_insufficient_source otherwise, with no mutation);
        // flushTail=true (writer EOS required) advances exactly the
        // remaining source frames (tail_flush_partial_window /
        // tail_flush_complete). Every step status reports
        // sourceAvailableReadFrames.
        external fun stepNodeOwnedAudioSourceGraphPipeline(
            handle: Long,
            sysTimeNs: Long,
            flushTail: Boolean,
        ): String

        // Output-ring reader side: consumes a pending start/seek ack first,
        // then pops and checksums up to maxFrames of mixed PCM.
        external fun drainNodeOwnedAudioSourceGraphPipelineOutput(
            handle: Long,
            maxFrames: Int,
        ): String

        // Forward-only seek. Requires a fully drained output ring, an empty
        // node-owned source ring, and targetFrame >= the node-owned
        // provider's cursor; the caller must drain the output-ring ack next.
        external fun seekNodeOwnedAudioSourceGraphPipeline(
            handle: Long,
            targetPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // Writer-local EOS only (cleared by the next successful seek).
        external fun setNodeOwnedAudioSourceGraphPipelineEos(
            handle: Long,
        ): String

        // Full diagnostic snapshot including the node-owned-wiring facts
        // (routedSourceCount, routedSourceId0, nodeOwnsRing), provider
        // underrun/skip/rewind metrics, and the fixed-at-construction
        // scratch/storage capacities used to prove zero native steady-state
        // allocation across repeated cycles.
        external fun snapshotNodeOwnedAudioSourceGraphPipeline(
            handle: Long,
        ): String

        // Idempotent erase-once; callable from any thread. Handle 0/unknown
        // returns status=not_found.
        external fun destroyNodeOwnedAudioSourceGraphPipelineSmokeSession(
            handle: Long,
        ): String
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

    // ── P4-AUDIO-GRAPH-TOPOLOGY: native AudioMixBusNode DAG topology & gated mix ─
    // diagnostic. Pure in-memory C++ graph topology + playhead evaluation gating +
    // synthetic PCM mix micro-proof. Stack-scoped, single-threaded, synchronous.
    // No threads, AudioTrack, AAudio, Oboe, MediaCodec, MediaExtractor, files,
    // Surface, GL, export/muxer, editor playback, or product UI.
    external fun runAndroidDagPhase4AudioGraphTopologySmoke(): String

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK: synchronous graph-edge-routed audio window scheduler proof ─
    // Pure in-memory C++ graph edge routing, exact frame window math, PTS derivation,
    // microsecond drift prevention, timeline gating, mixed PCM checksum verification,
    // silence windows, stale generation rejection, sample rate mismatch rejection,
    // and capacity guard micro-proof. Stack-scoped, single-threaded, synchronous.
    // No AudioTrack, AAudio, Oboe, realtime or audible playback, queues, backpressure,
    // threads, files, MediaCodec, MediaExtractor, export reroute, editor playback,
    // product UI, streaming, or iOS.
    external fun runAndroidDagPhase4AudioGraphTransportClockSmoke(): String

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice B: native SPSC audio ring-buffer transport primitive + diagnostic provider adapter ─
    // SPSC primitive + diagnostic provider only; no realtime/audible playback,
    // no AudioTrack/AAudio/OpenSL/Oboe, no realtime clock ownership,
    // no production decoder writer, no MediaCodec/MediaExtractor,
    // no C++->Kotlin callback, no export reroute, no streaming/cache,
    // no app/editor/product UI, no iOS, does not close P4-AUDIO-GRAPH-TRANSPORT-CLOCK
    // or P4-AUDIO-MIXBUS.
    external fun runAndroidDagPhase4AudioRingBufferTransportSmoke(): String

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice C: platform-neutral native AudioClock diagnostic ─
    // Caller-clocked, lock-free monotonic media-position tracker + drift-telemetry native proof.
    // Pure in-memory C++ lock-free monotonic timebase; no AudioTrack/AAudio/OpenSL/Oboe,
    // no audible playback, no production decoder writer, no export reroute, no streaming,
    // no iOS, no product/editor UI, no internal wall-clock read.
    external fun runAndroidDagPhase4AudioClockSmoke(): String

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice D: native ClockedAudioTransportCoordinator diagnostic ─
    // Caller-clocked, clock-driven audio transport coordinator native proof.
    // Pure in-memory C++ proof; no AudioTrack/AAudio/OpenSL/Oboe, no OS callbacks,
    // no production decoder writer, no export reroute, no streaming, no iOS,
    // no product/editor UI, no internal wall-clock read, no threads, no locks,
    // no float timebase, no resample, no speed change, no source provider ring seek,
    // output ring only, unity speed only.
    external fun runAndroidDagPhase4AudioTransportCoordinatorSmoke(): String

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice E: native decoder-to-source-ring ingest seam diagnostic ─
    // Standalone producer-side AudioDecoderRingWriter proof: pushes PCM16 into an
    // AudioSpscAudioRingBuffer via tryPushFrames()/requestSeek() only. Pure in-memory
    // C++ proof; no MediaCodec/MediaExtractor/AudioTrack/AAudio/OpenSL/Oboe, no
    // realtime or audible playback, no OS callbacks, no threads, no locks, no file IO,
    // no export reroute, no streaming, no iOS, no product/editor UI, no
    // DecodedAudioPcmSourceNode wiring, no scheduler integration, no resample.
    // Writer-local EOS only.
    external fun runAndroidDagPhase4AudioDecoderRingWriterSmoke(): String

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice F: closed-loop ingest-to-transport audio graph pipeline integration diagnostic ─
    // AudioDecoderRingWriter -> source AudioSpscAudioRingBuffer(s) ->
    // RingBufferAudioSampleProvider(s) -> GraphAudioScheduler -> AudioMixBusNode ->
    // ClockedAudioTransportCoordinator -> output AudioSpscAudioRingBuffer -> consumer
    // drain, all inside one single-threaded native call. Pure in-memory C++ proof;
    // no MediaCodec/MediaExtractor/AudioTrack/AAudio/OpenSL/Oboe, no realtime or
    // audible playback, no OS callbacks, no threads, no locks, no file IO, no
    // wall-clock read (caller-supplied sysTimeNs only), no resample, no speed change,
    // no export or pass-2 graph reroute, no streaming/cache, no iOS, no
    // product/editor UI. DecodedAudioPcmSourceNode is a topology anchor only (no PCM
    // ingest/retention). Writer-local EOS only.
    external fun runAndroidDagPhase4AudioPipelineIntegrationSmoke(): String

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
