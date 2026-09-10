package com.connects.vanguard_media_engine

import android.content.Context
import android.media.ExifInterface
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.NonNull
import com.connects.vanguard_media_engine.audio.AndroidWaveformCacheCoordinator
import com.connects.vanguard_media_engine.audio.AndroidWaveformExtractor
import com.connects.vanguard_media_engine.audio.AndroidWaveformResult
import com.connects.vanguard_media_engine.audio_extraction.AndroidAudioExtractionCoordinator
import com.connects.vanguard_media_engine.audio_playback.AndroidAudioPlaybackCoordinator
import com.connects.vanguard_media_engine.audio_recording.AndroidAudioRecordingCoordinator
import com.connects.vanguard_media_engine.camera.AndroidCamera2CapabilityProbe
import com.connects.vanguard_media_engine.camera.AndroidCamera2ConcurrentSmokeCoordinator
import com.connects.vanguard_media_engine.camera.AndroidCamera2MultiCamPreviewCoordinator
import com.connects.vanguard_media_engine.camera.AndroidCamera2SingleCamIngestSpatialSmokeCoordinator
import com.connects.vanguard_media_engine.camera.AndroidCamera2SingleCamIngestVulkanSpatialSmokeCoordinator
import com.connects.vanguard_media_engine.camera.AndroidCamera2TextureSmokeCoordinator
import com.connects.vanguard_media_engine.camera.AndroidCameraGraphTransactionCoordinator
import com.connects.vanguard_media_engine.camera.AndroidCameraXThermalActuationRouter
import com.connects.vanguard_media_engine.codec.AndroidDagTexturePlaybackCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAaudioNodeOwnedSinkSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAsyncRuntimeQueueAudioTrackSinkSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAsyncRuntimeQueueRealDecoderSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAsyncRuntimeQueueMultiSourceRealtimeClockSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAsyncRuntimeQueueRealtimeClockSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAsyncRuntimeQueueSchedulerSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioDecodeBridgeSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioGraphExportSessionSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioGraphTopologySmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioGraphTransportClockSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioMixBusSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioMixBusTimelineSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioSchedulerEnvelopeSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioRingBufferTransportSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioClockSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioDecoderRingWriterSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioDecoderRingIngestSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioGraphPipelineRealDecoderSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioGraphPipelineSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioPipelineIntegrationSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioTrackPlaybackSinkSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioTransportCoordinatorSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidBeautyV2GlesRenderSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidConcurrentDecodeSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidDagDiagnosticsCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidGlesExportOverlayProductionSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidGlesDualOesTransitionSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidGlesExportBeautySeamSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidGlesExportOverlaySeamSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidGlesTextureSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidMultiCamCompositorSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidMulticamDynamicDescriptorSpatialVulkanRenderSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidMulticamSpatialVulkanRenderSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidMultiSourceAudioGraphPipelineSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidMultiSourceAudioTrackPlaybackSinkCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidMultiSourceNodeOwnedPipelineSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidNodeOwnedAudioSourceGraphPipelineSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidNodeOwnedAudioSourceRealDecoderSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidNodeOwnedAudioTrackSinkClockedTransportSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidPassthroughRemuxSinkSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimePlaybackAudioTrackSinkSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimePlaybackFocusResponseSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimePlaybackIngestSeamSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimePlaybackInteractiveControlsSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimePlaybackPipelineIntegrationSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimePlaybackPipelinePauseResumeSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimePlaybackPipelineFocusResponseSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimePlaybackPipelineSinkFaultToleranceSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimePlaybackPipelineTimestampStabilizationSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimePlaybackPipelineClockSyncSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimePlaybackPipelineSeekSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimePlaybackRealDecoderSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimePlaybackSinkFaultToleranceSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimePlaybackTransportCoreSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidTimelineCompositorSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidTimelineTransitionGlesRenderSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidTimelineOverlayGlesRenderSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidTimelineOverlayTextRasterizerSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidTimelineDualDecoderSyncSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidTimelineTransitionVulkanRenderSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidTimelineOverlayVulkanRenderSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidBeautyV2VulkanRenderSmokeCoordinator
import com.connects.vanguard_media_engine.editor.AndroidEditorPlaybackCoordinator
import com.connects.vanguard_media_engine.editor.AndroidTimelineLiveControlCoordinator
import com.connects.vanguard_media_engine.export.AndroidEditorExportCoordinator
import com.connects.vanguard_media_engine.export.AndroidStillImageDecoder
import com.connects.vanguard_media_engine.export.AndroidStillImageExportCoordinator
import com.connects.vanguard_media_engine.image.AndroidImageCompressionCoordinator
import com.connects.vanguard_media_engine.image.AndroidImageOptimizer
import com.connects.vanguard_media_engine.photo_library.AndroidPhotoLibrarySaveCoordinator
import com.connects.vanguard_media_engine.photo_library.AndroidVideoAssetPickerCoordinator
import com.connects.vanguard_media_engine.rtc.AndroidRtcVideoCoordinator
import com.connects.vanguard_media_engine.sidecar.AndroidReverseSidecarCoordinator
import com.connects.vanguard_media_engine.streaming.AndroidDagStreamingPlaybackCoordinator
import com.connects.vanguard_media_engine.streaming.AndroidMedia3StreamSourceCoordinator
import com.connects.vanguard_media_engine.thermal.AndroidThermalStateBridge
import com.connects.vanguard_media_engine.util.AndroidUriDataSourceHelper
import com.connects.vanguard_media_engine.duet.AndroidDuetMethodHandler
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean

class VanguardMediaEnginePlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var binding: FlutterPlugin.FlutterPluginBinding

    // ── Video editor renderers (existing, keyed by textureId) ─────────────────
    private val renderers = mutableMapOf<Long, VanguardGLRenderer>()

    // ── Phase 4B1: DAG texture playback coordinator ───────────────────────────
    private var dagTexturePlaybackCoordinator: AndroidDagTexturePlaybackCoordinator? = null

    // ── Phase 3-Unit M: Camera2 texture native-render loop smoke coordinator ──
    private var camera2TextureSmokeCoordinator: AndroidCamera2TextureSmokeCoordinator? = null

    // -- P3-MULTICAM-NODE-SINGLE-CAM-INGEST-DESCRIPTOR-SPATIAL-RENDER: single- --
    // camera ingest + dynamic-descriptor GLES/OES spatial render smoke coordinator.
    private var camera2SingleCamIngestSpatialSmokeCoordinator: AndroidCamera2SingleCamIngestSpatialSmokeCoordinator? = null

    // -- P3-MULTICAM-NODE-SINGLE-CAM-INGEST-VULKAN-SPATIAL-RENDER: real --
    // Camera2 YUV_420_888 ingest + Vulkan spatial render smoke coordinator.
    private var camera2SingleCamIngestVulkanSpatialSmokeCoordinator:
        AndroidCamera2SingleCamIngestVulkanSpatialSmokeCoordinator? = null

    // ── Phase 4C1D1: DAG streaming playback coordinator ───────────────────────
    private var dagStreamingPlaybackCoordinator: AndroidDagStreamingPlaybackCoordinator? = null

    // ── Phase 4C3D: RTC video coordinator ─────────────────────────────────────
    private var rtcVideoCoordinator: AndroidRtcVideoCoordinator? = null

    // ── P6-MEDIA3-INGEST-STREAM-SOURCE-SEAM-A: Media3 stream-source ingest seam coordinator ──
    private var media3StreamSourceCoordinator: AndroidMedia3StreamSourceCoordinator? = null

    // ── Phase 7.8A-Android: editor playback control coordinator ───────────────
    private var editorPlaybackCoordinator: AndroidEditorPlaybackCoordinator? = null

    // ── Phase 10-C-3N: timeline live filter-chain control guard bridge ────────
    // Owns "timeline_setFilterChain" -- honest guard route only. Does NOT
    // implement live visual filter evaluation on Android; see
    // AndroidTimelineLiveControlCoordinator's header for the full non-claims.
    private var timelineLiveControlCoordinator: AndroidTimelineLiveControlCoordinator? = null

    // ── Camera graph transaction guard bridge ──────────────────────────────────
    // Owns "applyGraphTransaction" -- honest guard route only. Does NOT
    // implement camera graph filter execution on Android; see
    // AndroidCameraGraphTransactionCoordinator's header for the full
    // non-claims.
    private var cameraGraphTransactionCoordinator: AndroidCameraGraphTransactionCoordinator? = null

    // ── P3-CAM-CONCURRENT-STARTMULTICAM-FAIL-CLOSED-ANDROID-HANDLER: owns ─────
    // "startMultiCamPreview" / "stopMultiCamPreview" as explicit fail-closed
    // guard routes. Does NOT implement real concurrent camera capture; see
    // AndroidCamera2MultiCamPreviewCoordinator's header for the full non-claims.
    private var multiCamPreviewCoordinator: AndroidCamera2MultiCamPreviewCoordinator? = null

    // ── Diagnostic smoke routes (Phases 2O2B3/2O2B4/2Q/3C/4A/5 + Audio Unit B) ─
    private var dagDiagnosticsCoordinator: AndroidDagDiagnosticsCoordinator? = null

    // ── Phase 2: concurrent decode verification smoke coordinator ─────────────
    private var concurrentDecodeSmokeCoordinator: AndroidConcurrentDecodeSmokeCoordinator? = null

    // ── P2-CPP-PASSTHROUGH: native passthrough remux sink smoke coordinator ───
    private var passthroughRemuxSinkSmokeCoordinator: AndroidPassthroughRemuxSinkSmokeCoordinator? = null

    // ── P2-AUDIO-DEC-BRIDGE: native decoded-PCM audio source bridge smoke ─────
    private var audioDecodeBridgeSmokeCoordinator: AndroidAudioDecodeBridgeSmokeCoordinator? = null

    // ── P4-AUDIO-MIXBUS: native PCM16 mix-bus foundation smoke coordinator ────
    private var audioMixBusSmokeCoordinator: AndroidAudioMixBusSmokeCoordinator? = null

    // ── P4-AUDIO-GRAPH-TOPOLOGY: native AudioMixBusNode DAG topology & gated mix smoke coordinator ────
    private var audioGraphTopologySmokeCoordinator: AndroidAudioGraphTopologySmokeCoordinator? = null

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK: native graph-edge-routed audio window scheduler smoke coordinator ────
    private var audioGraphTransportClockSmokeCoordinator: AndroidAudioGraphTransportClockSmokeCoordinator? = null

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice B: native SPSC audio ring-buffer transport smoke coordinator ────
    private var audioRingBufferTransportSmokeCoordinator: AndroidAudioRingBufferTransportSmokeCoordinator? = null

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice C: platform-neutral native AudioClock smoke coordinator ────
    private var audioClockSmokeCoordinator: AndroidAudioClockSmokeCoordinator? = null

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice D: native ClockedAudioTransportCoordinator smoke coordinator ────
    private var audioTransportCoordinatorSmokeCoordinator: AndroidAudioTransportCoordinatorSmokeCoordinator? = null

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice E: native AudioDecoderRingWriter smoke coordinator ────
    private var audioDecoderRingWriterSmokeCoordinator: AndroidAudioDecoderRingWriterSmokeCoordinator? = null

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice F: native closed-loop audio pipeline integration smoke coordinator ────
    private var audioPipelineIntegrationSmokeCoordinator: AndroidAudioPipelineIntegrationSmokeCoordinator? = null

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice G2b: Kotlin MediaCodec/MediaExtractor decoder ring-ingest smoke coordinator ────
    private var audioDecoderRingIngestSmokeCoordinator: AndroidAudioDecoderRingIngestSmokeCoordinator? = null

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice H1: session-scoped closed-loop audio graph pipeline smoke coordinator ────
    private var audioGraphPipelineSmokeCoordinator: AndroidAudioGraphPipelineSmokeCoordinator? = null

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice H2: real MediaExtractor/MediaCodec decoder closed-loop audio graph pipeline smoke coordinator ────
    // Registration-only glue; cohesive coordinator extraction from this
    // oversized plugin is deferred because this slice only mirrors the
    // established diagnostic route wiring.
    private var audioGraphPipelineRealDecoderSmokeCoordinator: AndroidAudioGraphPipelineRealDecoderSmokeCoordinator? = null

    // ── P4-AUDIO-AUDIOTRACK-OUTPUT-SINK-WRITE (P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice I): Kotlin AudioTrack output sink smoke coordinator ────
    // Registration-only glue; cohesive coordinator extraction from this
    // oversized plugin is deferred because this slice only mirrors the
    // established diagnostic route wiring.
    private var audioTrackPlaybackSinkSmokeCoordinator: AndroidAudioTrackPlaybackSinkSmokeCoordinator? = null

    // ── P4-AUDIO-MULTI-SOURCE-GRAPH-PIPELINE: two-source (real decoder + synthetic) closed-loop audio graph pipeline smoke coordinator ────
    // Registration-only glue; cohesive coordinator extraction from this
    // oversized plugin is deferred because this slice only mirrors the
    // established diagnostic route wiring.
    private var multiSourceAudioGraphPipelineSmokeCoordinator: AndroidMultiSourceAudioGraphPipelineSmokeCoordinator? = null

    // ── P4-AUDIO-MULTI-SOURCE-AUDIOTRACK-SINK (P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice K): multi-source AudioTrack output sink smoke coordinator ────
    // Registration-only glue; cohesive coordinator extraction from this
    // oversized plugin is deferred because this slice only mirrors the
    // established diagnostic route wiring.
    private var multiSourceAudioTrackPlaybackSinkCoordinator: AndroidMultiSourceAudioTrackPlaybackSinkCoordinator? = null

    // ── P4-AUDIO-MULTI-SOURCE-NODE-OWNED-PIPELINE: two-source node-owned closed-loop audio graph pipeline smoke coordinator ────
    // Registration-only glue; cohesive coordinator extraction from this
    // oversized plugin is deferred because this slice only mirrors the
    // established diagnostic route wiring.
    private var multiSourceNodeOwnedPipelineSmokeCoordinator: AndroidMultiSourceNodeOwnedPipelineSmokeCoordinator? = null

    // ── P4-AUDIO-DECODER-SOURCE-NODE-WIRING: node-owned-source closed-loop audio graph pipeline smoke coordinator ────
    // Registration-only glue; cohesive coordinator extraction from this
    // oversized plugin is deferred because this slice only mirrors the
    // established diagnostic route wiring.
    private var nodeOwnedAudioSourceGraphPipelineSmokeCoordinator: AndroidNodeOwnedAudioSourceGraphPipelineSmokeCoordinator? = null

    // ── P4-AUDIO-REAL-DECODER-NODE-OWNED-PIPELINE: real MediaExtractor/MediaCodec decoder to node-owned-source audio graph pipeline smoke coordinator ────
    // Registration-only glue; cohesive coordinator extraction from this
    // oversized plugin is deferred because this slice only mirrors the
    // established diagnostic route wiring.
    private var nodeOwnedAudioSourceRealDecoderSmokeCoordinator: AndroidNodeOwnedAudioSourceRealDecoderSmokeCoordinator? = null

    // ── P4-AUDIO-NODE-OWNED-SINK-CLOCKED-TRANSPORT (P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice O): node-owned pipeline muted AudioTrack sink-clocked transport smoke coordinator ────
    // Registration-only glue; cohesive coordinator extraction from this
    // oversized plugin is deferred because this slice only mirrors the
    // established diagnostic route wiring.
    private var nodeOwnedAudioTrackSinkClockedTransportSmokeCoordinator: AndroidNodeOwnedAudioTrackSinkClockedTransportSmokeCoordinator? = null

    // ── P4-AUDIO-AAUDIO-NODE-OWNED-SINK-DIAGNOSTIC: two-source node-owned pipeline muted native AAudio callback sink smoke coordinator ────
    // Registration-only glue; cohesive coordinator extraction from this
    // oversized plugin is deferred because this slice only mirrors the
    // established diagnostic route wiring.
    private var aaudioNodeOwnedSinkSmokeCoordinator: AndroidAaudioNodeOwnedSinkSmokeCoordinator? = null

    // ── P4-AUDIO-MIXBUS-TIMELINE-OWNERSHIP: native AudioMixBusNode timeline-aware ────
    // per-frame volume envelope diagnostic smoke coordinator. Registration-only
    // glue mirroring the established one-shot diagnostic route wiring.
    private var audioMixBusTimelineSmokeCoordinator: AndroidAudioMixBusTimelineSmokeCoordinator? = null

    // ── P4-AUDIO-SCHEDULER-ENVELOPE-WIRING: GraphAudioScheduler per-source ────
    // static-gain/envelope wiring diagnostic smoke coordinator. Registration-only
    // glue mirroring the established one-shot diagnostic route wiring.
    private var audioSchedulerEnvelopeSmokeCoordinator: AndroidAudioSchedulerEnvelopeSmokeCoordinator? = null

    // ── P4-AUDIO-PASS2-GRAPH-NATIVE-SESSION: N-source native True-DAG audio ────
    // graph export session diagnostic smoke coordinator. Registration-only
    // glue mirroring the established diagnostic route wiring.
    private var audioGraphExportSessionSmokeCoordinator: AndroidAudioGraphExportSessionSmokeCoordinator? = null

    // ── P4-AUDIO-RUNTIME-QUEUE-SCHEDULER: diagnostic async runtime queue/ ────
    // backpressure scheduler integration smoke coordinator. Registration-only
    // glue mirroring the established diagnostic route wiring.
    private var asyncRuntimeQueueSchedulerSmokeCoordinator: AndroidAsyncRuntimeQueueSchedulerSmokeCoordinator? = null

    // ── P4-AUDIO-ASYNC-RUNTIME-QUEUE-REAL-DECODER (sub-slice X1): real ────
    // MediaExtractor/MediaCodec decoder to async runtime queue scheduler
    // smoke coordinator. Registration-only glue mirroring the established
    // diagnostic route wiring.
    private var asyncRuntimeQueueRealDecoderSmokeCoordinator: AndroidAsyncRuntimeQueueRealDecoderSmokeCoordinator? = null

    // ── P4-AUDIO-ASYNC-RUNTIME-QUEUE-AUDIOTRACK-SINK (sub-slice X2): async ────
    // runtime queue output ring to Kotlin-owned muted AudioTrack sink smoke
    // coordinator. Registration-only glue mirroring the established
    // diagnostic route wiring.
    private var asyncRuntimeQueueAudioTrackSinkSmokeCoordinator: AndroidAsyncRuntimeQueueAudioTrackSinkSmokeCoordinator? = null

    // ── P4-AUDIO-ASYNC-RUNTIME-QUEUE-REALTIME-CLOCK-PACING (sub-slice X3): ────
    // async runtime queue realtime worker-owned steady_clock pacing smoke
    // coordinator. Registration-only glue mirroring the established
    // diagnostic route wiring.
    private var asyncRuntimeQueueRealtimeClockSmokeCoordinator: AndroidAsyncRuntimeQueueRealtimeClockSmokeCoordinator? = null

    // ── P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-REALTIME-CLOCK (sub-slice ──
    // X4): two-source node-owned async runtime queue realtime worker-owned
    // steady_clock pacing smoke coordinator. Registration-only glue
    // mirroring the established diagnostic route wiring.
    private var asyncRuntimeQueueMultiSourceRealtimeClockSmokeCoordinator: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockSmokeCoordinator? = null

    // ── P4-AUDIO-REALTIME-PLAYBACK-TRANSPORT-CORE (Y1): production True-DAG ──
    // realtime playback transport core smoke coordinator. Registration-only
    // glue mirroring the established diagnostic route wiring.
    private var realtimePlaybackTransportCoreSmokeCoordinator: AndroidRealtimePlaybackTransportCoreSmokeCoordinator? = null

    // ── P4-AUDIO-REALTIME-PLAYBACK-AUDIOTRACK-SINK (Y2): production True-DAG ──
    // realtime playback AudioTrack sink smoke coordinator. Registration-only
    // glue mirroring the established diagnostic route wiring.
    private var realtimePlaybackAudioTrackSinkSmokeCoordinator: AndroidRealtimePlaybackAudioTrackSinkSmokeCoordinator? = null

    // ── P4-AUDIO-REALTIME-PLAYBACK-INTERACTIVE-CONTROLS (Y3): production True-DAG ──
    // realtime playback interactive transport controls smoke coordinator. Registration-only
    // glue mirroring the established diagnostic route wiring.
    private var realtimePlaybackInteractiveControlsSmokeCoordinator: AndroidRealtimePlaybackInteractiveControlsSmokeCoordinator? = null

    // ── P4-AUDIO-REALTIME-PLAYBACK-FOCUS-RESPONSE (Y4a): production True-DAG ──
    // realtime playback audio focus / becoming-noisy response smoke coordinator.
    // Registration-only glue mirroring the established diagnostic route wiring.
    private var realtimePlaybackFocusResponseSmokeCoordinator: AndroidRealtimePlaybackFocusResponseSmokeCoordinator? = null

    // ── P4-AUDIO-REALTIME-PLAYBACK-SINK-FAULT-TOLERANCE (Y4b): production True-DAG ──
    // realtime playback AudioTrack sink fault tolerance (synthetic dead-object
    // recovery + route-change listener handoff) smoke coordinator.
    // Registration-only glue mirroring the established diagnostic route wiring.
    private var realtimePlaybackSinkFaultToleranceSmokeCoordinator: AndroidRealtimePlaybackSinkFaultToleranceSmokeCoordinator? = null

    // ── P4-AUDIO-REALTIME-PLAYBACK-EXTERNAL-INGEST-SEAM (Y5a): production True-DAG ──
    // realtime playback external PCM16 ingest seam smoke coordinator (Kotlin
    // synthetic producer -> owner-thread native source-ring ingest; no codec).
    // Registration-only glue mirroring the established diagnostic route wiring.
    private var realtimePlaybackIngestSeamSmokeCoordinator: AndroidRealtimePlaybackIngestSeamSmokeCoordinator? = null

    // ── P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER (Y5b): production True-DAG ──
    // realtime playback MediaExtractor/MediaCodec decoder smoke coordinator (real
    // decoder -> owner-thread generation-pinned postIngest to Y5a seam).
    // Registration-only glue mirroring the established diagnostic route wiring.
    private var realtimePlaybackRealDecoderSmokeCoordinator: AndroidRealtimePlaybackRealDecoderSmokeCoordinator? = null

    // ── P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-INTEGRATION-A (Y6a): production True-DAG ──
    // realtime playback pipeline integration smoke coordinator (real decoder
    // thread -> Y5a ingest seam -> Y1 transport -> non-zero-gain AudioTrack sink
    // thread). Registration-only glue mirroring the established diagnostic route wiring.
    private var realtimePlaybackPipelineIntegrationSmokeCoordinator: AndroidRealtimePlaybackPipelineIntegrationSmokeCoordinator? = null

    // ── P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-PAUSE-RESUME (Y6b): production True-DAG ──
    // realtime playback pipeline pause/resume smoke coordinator (Y6a pipeline shape
    // with a phase-controlled AudioTrack sink: sink park -> transport pause ->
    // frozen hold -> transport resume -> sink unpark -> EOS). Registration-only
    // glue mirroring the established diagnostic route wiring.
    private var realtimePlaybackPipelinePauseResumeSmokeCoordinator: AndroidRealtimePlaybackPipelinePauseResumeSmokeCoordinator? = null

    // ── P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SEEK (Y6c): production True-DAG ──
    // realtime playback pipeline mid-stream seek smoke coordinator (Y6a/Y6b
    // pipeline shape: feed held at a window-aligned anchor -> sink park ->
    // transport pause -> AudioTrack flush on the sink thread -> transport seek
    // while PAUSED -> decoder re-anchor + stale-generation probe -> post-seek
    // pre-roll -> sink unpark -> transport resume -> EOS). Registration-only
    // glue mirroring the established diagnostic route wiring.
    private var realtimePlaybackPipelineSeekSmokeCoordinator: AndroidRealtimePlaybackPipelineSeekSmokeCoordinator? = null

    // ── P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-FOCUS-RESPONSE (Y6d): production ──
    // True-DAG realtime playback pipeline focus / becoming-noisy response smoke
    // coordinator (Y6a/Y6b pipeline shape + one Y4a focus controller per
    // scenario: real decode -> Y5a ingest -> Y1 transport -> non-zero-gain
    // AudioTrack; the sink thread applies synthetic focus / noisy events, the
    // coordinator owns transport commands; EOS_COMPLETION,
    // BECOMING_NOISY_TERMINAL, PERMANENT_LOSS_TERMINAL). Registration-only
    // glue mirroring the established diagnostic route wiring.
    private var realtimePlaybackPipelineFocusResponseSmokeCoordinator: AndroidRealtimePlaybackPipelineFocusResponseSmokeCoordinator? = null

    // ── P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SINK-FAULT-TOLERANCE (Y6e): production ──
    // True-DAG realtime playback pipeline sink fault tolerance smoke
    // coordinator (Y6a/Y6b pipeline shape + one Y4b routing controller per
    // scenario: real decode -> Y5a ingest -> Y1 transport -> non-zero-gain
    // AudioTrack; the sink thread owns every AudioTrack call, applies routing
    // events and recovers the one synthetic dead object, the coordinator owns
    // transport commands; EOS_WITH_DEAD_OBJECT_RECOVERY,
    // ROUTE_DISCONNECT_TERMINAL). Registration-only glue mirroring the
    // established diagnostic route wiring.
    private var realtimePlaybackPipelineSinkFaultToleranceSmokeCoordinator: AndroidRealtimePlaybackPipelineSinkFaultToleranceSmokeCoordinator? = null

    // ── P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-TIMESTAMP-STABILIZATION (Y6f) ──
    // Registration-only glue for the Y6f timestamp-stabilization smoke route
    // (X13 getTimestamp poll-cadence / per-epoch frame-monotonicity lifted
    // into the Y6 pipeline; sink thread owns AudioTrack + getTimestamp,
    // coordinator owns transport commands; FORWARD_PLAYTHROUGH_TIMESTAMP,
    // DEAD_OBJECT_EPOCH_RESET_TIMESTAMP). Timestamp telemetry is inert.
    private var realtimePlaybackPipelineTimestampStabilizationSmokeCoordinator: AndroidRealtimePlaybackPipelineTimestampStabilizationSmokeCoordinator? = null

    // Registration-only glue for the Y7 clock-synchronization smoke route
    // (Y6f pipeline + read-only downstream presentation clock written by the
    // sink thread at the post-write poll point, snapshotted by any thread;
    // FORWARD_PLAYTHROUGH_CLOCK_SYNC, DEAD_OBJECT_CLOCK_EPOCH_RESET). The
    // clock is diagnostic only and controls nothing.
    private var realtimePlaybackPipelineClockSyncSmokeCoordinator: AndroidRealtimePlaybackPipelineClockSyncSmokeCoordinator? = null

    // ── P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK (Y8a): production ──
    // session + sink-thread-owned AudioTrack/presentation clock smoke
    // coordinator (bounded pause/resume to EOS, stop/dispose mid-playback).
    private var realtimeAudioPlaybackProductionSmokeCoordinator: AndroidRealtimeAudioPlaybackProductionSmokeCoordinator? = null

    // ── P3-MULTICAM-NODE: MultiCamCompositorNode native topology + layout ────
    // math smoke coordinator.
    private var multiCamCompositorSmokeCoordinator: AndroidMultiCamCompositorSmokeCoordinator? = null

    // ── P3-MULTICAM-NODE (SPATIAL-VULKAN-RENDER): VulkanMultiCamSpatialCompositor ──
    // two-texture layout raster/readback proof smoke coordinator.
    private var multicamSpatialVulkanRenderSmokeCoordinator:
        AndroidMulticamSpatialVulkanRenderSmokeCoordinator? = null

    // -- P3-MULTICAM-NODE-VULKAN-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER: caller- --
    // supplied Dart layout descriptor primitives -> native Vulkan spatial
    // render/readback smoke coordinator.
    private var multicamDynamicDescriptorSpatialVulkanRenderSmokeCoordinator:
        AndroidMulticamDynamicDescriptorSpatialVulkanRenderSmokeCoordinator? = null

    // ── P5-COMPOSITOR-TRANS (NODE-TOPOLOGY-MATH): VGTimelineCompositorNode ──
    // native topology + transition math smoke coordinator.
    private var timelineCompositorSmokeCoordinator: AndroidTimelineCompositorSmokeCoordinator? = null

    // ── P5-COMPOSITOR-TRANS (GLES-RENDER): GlesTimelineTransitionCompositor ──
    // shader/raster proof smoke coordinator.
    private var timelineTransitionGlesRenderSmokeCoordinator:
        AndroidTimelineTransitionGlesRenderSmokeCoordinator? = null

    // ── P5-OVERLAYS-TRANS (GLES-RENDER): GlesOverlayCompositor multi-layer ──
    // overlay shader/raster proof smoke coordinator.
    private var timelineOverlayGlesRenderSmokeCoordinator:
        AndroidTimelineOverlayGlesRenderSmokeCoordinator? = null

    // ── P5-GLES-EXPORT-OVERLAY-SEAM-A: diagnostic-only seam proving a real ──
    // MediaCodec decode -> SurfaceTexture -> GL_TEXTURE_EXTERNAL_OES frame
    // still routes into the caller-current GlesOverlayCompositor helper.
    private var glesExportOverlaySeamSmokeCoordinator:
        AndroidGlesExportOverlaySeamSmokeCoordinator? = null

    // ── P5-GLES-EXPORT-OVERLAY-PRODUCTION-ROUTE-A: diagnostic coordinator ──
    // verifying production AndroidTimelineVideoEncoder routes overlays through GLES.
    private var glesExportOverlayProductionSmokeCoordinator:
        AndroidGlesExportOverlayProductionSmokeCoordinator? = null

    // ── P5-OVERLAYS-TEXT-RASTERIZER-DIAGNOSTIC: AndroidTimelineOverlayTextRasterizer
    // helper proof smoke coordinator.
    private var timelineOverlayTextRasterizerSmokeCoordinator:
        AndroidTimelineOverlayTextRasterizerSmokeCoordinator? = null

    // ── P5-BEAUTY-V2-GLES-RENDER: GlesBeautyV2Compositor 3-pass bilateral ──
    // beauty smoothing shader/raster + CPU-reference-parity proof smoke
    // coordinator.
    private var beautyV2GlesRenderSmokeCoordinator:
        AndroidBeautyV2GlesRenderSmokeCoordinator? = null

    // -- P5-GLES-EXPORT-OES-2D-BEAUTY-RESOLVE-READINESS: diagnostic-only ----
    // seam proving a real MediaCodec decode -> SurfaceTexture ->
    // GL_TEXTURE_EXTERNAL_OES frame, resolved to GL_TEXTURE_2D RGBA8, still
    // routes into the caller-current GlesBeautyV2Compositor::DrawBeautyV2
    // helper on a current-verified ES3 context.
    private var glesExportBeautySeamSmokeCoordinator:
        AndroidGlesExportBeautySeamSmokeCoordinator? = null

    // -- P5-GLES-EXPORT-DUAL-OES-TRANSITION-READINESS: diagnostic-only ------
    // proof that two real MediaCodec decodes, each feeding its own
    // SurfaceTexture/GL_TEXTURE_EXTERNAL_OES texture on one caller-owned ES3
    // EGL context, still route into GlesTimelineTransitionCompositor.
    private var glesDualOesTransitionSmokeCoordinator:
        AndroidGlesDualOesTransitionSmokeCoordinator? = null

    // ── P5-COMPOSITOR-TRANS (VULKAN-RENDER): VulkanTimelineTransitionCompositor ──
    // shader/raster proof smoke coordinator.
    private var timelineTransitionVulkanRenderSmokeCoordinator:
        AndroidTimelineTransitionVulkanRenderSmokeCoordinator? = null

    // ── P5-OVERLAYS-TRANS (VULKAN-RENDER): VulkanOverlayCompositor multi-layer ──
    // overlay shader/raster proof smoke coordinator.
    private var timelineOverlayVulkanRenderSmokeCoordinator:
        AndroidTimelineOverlayVulkanRenderSmokeCoordinator? = null

    // ── P5-COMPOSITOR-TRANS (DUAL-DECODER-SYNC): dual MediaCodec synchronized ──
    // ingest -> AHardwareBuffer -> Vulkan crossfade proof smoke coordinator.
    private var timelineDualDecoderSyncSmokeCoordinator:
        AndroidTimelineDualDecoderSyncSmokeCoordinator? = null

    // ── P5-BEAUTY-V2-VULKAN-RENDER: VulkanBeautyV2Compositor 3-pass bilateral ──
    // beauty smoothing shader/raster + CPU-reference-parity proof smoke
    // coordinator.
    private var beautyV2VulkanRenderSmokeCoordinator:
        AndroidBeautyV2VulkanRenderSmokeCoordinator? = null

    // ── P3-CAM-CONCURRENT: Camera2 dual-camera concurrent ingest smoke ────────
    private var camera2ConcurrentSmokeCoordinator: AndroidCamera2ConcurrentSmokeCoordinator? = null

    // ── Phase 3-Unit T: Android OS thermal listener lifecycle bridge ──────────
    private var thermalStateBridge: AndroidThermalStateBridge? = null

    // ── Phase 1-Unit AX: GLES SurfaceProducer texture DAG render smoke coordinator ──
    private var glesTextureSmokeCoordinator: AndroidGlesTextureSmokeCoordinator? = null

    // -- Export Unit C / Phase 2-Unit AD: production export coordinator --------
    // Owns "exportTimeline" and "exportPassthroughRemux" (shared export lock).
    // Does NOT own "cancelExport" -- the plugin tries this coordinator's
    // cancelActiveExport() first, then falls back to the legacy activeEncoder
    // cancel path below.
    private var editorExportCoordinator: AndroidEditorExportCoordinator? = null

    // ── Phase 5-Unit AD / Phase 10-C-3L: still-image export session bridge ───
    // Owns "exportImage" -- Android parity with the exportImage case in
    // VanguardMediaEnginePlugin.swift (colorMatrix filters + "preserve"
    // orientation policy only; see AndroidStillImageExportCoordinator).
    private var stillImageExportCoordinator: AndroidStillImageExportCoordinator? = null

    // ── Phase 5-Unit AE / Phase 10-C-3M: still-image compression coordinator ──
    // Owns "compressImage" -- Android parity with the compressImage case in
    // VanguardMediaEnginePlugin.swift.
    private var imageCompressionCoordinator: AndroidImageCompressionCoordinator? = null

    // ── Phase 5-Unit Q / Phase 7.20: reverse sidecar coordinator ──────────────
    // Owns "prepareReverseSidecars", "getSidecarStatus", "cleanupReverseSidecars".
    // Never emits state=ready in this slice — see AndroidReverseSidecarCoordinator.
    private var reverseSidecarCoordinator: AndroidReverseSidecarCoordinator? = null

    // ── Phase 5-Unit V / Phase 4-Unit D: managed audio extraction coordinator ──
    // Owns "beginAudioExtraction" and "cancelAudioExtraction" -- Android parity
    // with VanguardAudioExtractionHandler.swift.
    private var audioExtractionCoordinator: AndroidAudioExtractionCoordinator? = null

    // ── Phase 5-Unit X / Phase 4-Unit F: disk-backed waveform result cache ────
    // Owns the six "waveformCache_*" routes -- Android parity with
    // VGWaveformCacheMethodHandler.swift.
    private var waveformCacheCoordinator: AndroidWaveformCacheCoordinator? = null

    // ── Phase 5-Unit Y / Phase 4-Unit G: standalone audio playback coordinator ─
    // Owns the seven "audioPlayback_*" routes -- Android parity with
    // VGAudioPlaybackService.m (iOS).
    private var audioPlaybackCoordinator: AndroidAudioPlaybackCoordinator? = null

    // ── Phase 5-Unit Z / UMF V2 Slice 2A: photo library save coordinator ──────
    // Owns "saveVideoToPhotoLibrary" -- Android parity with
    // VGPhotoLibrarySaveHandler.swift (iOS).
    private var photoLibrarySaveCoordinator: AndroidPhotoLibrarySaveCoordinator? = null

    // ── Phase 5-Unit AB / Phase 10F-Slice 2B / UMF V2 Slice 2B: video asset picker ──
    // Owns the eight "checkPhotoLibraryPermission" / "fetchPhotoVideos" / ...
    // routes -- Android parity with VGVideoAssetPickerHandler.swift (iOS).
    // Also an ActivityAware-driven PluginRegistry.RequestPermissionsResultListener.
    private var videoAssetPickerCoordinator: AndroidVideoAssetPickerCoordinator? = null

    // ── Phase 4-Unit H / Phase 5-Unit AC: audio recording coordinator ─────────
    // Owns "startAudioRecording" and "stopAudioRecording" -- Android parity
    // with VGAudioRecordingHandler.swift (iOS), bounded to a timeline-independent
    // slice (startPTS frozen to 0.0; no NO_TIMELINE dependency).
    private var audioRecordingCoordinator: AndroidAudioRecordingCoordinator? = null

    // ── VG-DUET-SLICE-2: Duet session lifecycle / dispatch handler ────────────
    // Owns all 10 Duet MethodChannel routes. Plugin is a thin router only.
    // Initialized lazily once mainHandler is available (onAttachedToEngine).
    private var duetMethodHandler: AndroidDuetMethodHandler? = null

    // ── ActivityAware binding (needed by videoAssetPickerCoordinator only) ────
    private var activityBinding: ActivityPluginBinding? = null

    // ── Camera session state (B2: single camera instance invariant) ───────────
    // Mirrors iOS plugin: cameraSource + renderer stored at plugin level.
    // Exactly one VanguardCameraSource may exist at a time.
    private var cameraSource: VanguardCameraSource? = null
    private var cameraTexture: TextureRegistry.SurfaceTextureEntry? = null

    // -- P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: CameraX thermal FPS router ----
    private var cameraXThermalActuationRouter: AndroidCameraXThermalActuationRouter? = null

    // ── Image texture loaders (B3: keyed by textureId) ────────────────────────
    private val imageLoaders = mutableMapOf<Long, VanguardImageTextureLoader>()

    // ── Main thread handler (B3: for posting background-thread results) ─────────
    private val mainHandler = Handler(Looper.getMainLooper())

    // ── B4-S5: active export encoder — plugin-level ref for cancelExport ─────────
    // Cleared in encoder.finish{} callback and on cancelExport.
    @Volatile private var activeEncoder: VanguardMediaCodecEncoder? = null

    // ── Phase 5-Unit W / Phase 4-Unit E: extractWaveform detach guard ─────────
    // Checked before every extractWaveform reply so no channel call happens
    // after onDetachedFromEngine.
    @Volatile private var detached = false

    companion object {
        private const val TAG = "VanguardPlugin"
    }

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        detached = false
        this.binding = binding
        this.context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "vanguard_media_engine")
        channel.setMethodCallHandler(this)
        thermalStateBridge = AndroidThermalStateBridge(
            context     = binding.applicationContext,
            channel     = channel,
            mainHandler = mainHandler,
        ).also { it.start() }
        dagTexturePlaybackCoordinator = AndroidDagTexturePlaybackCoordinator(
            textureRegistry = binding.textureRegistry,
            channel         = channel,
            mainHandler     = mainHandler,
            context         = binding.applicationContext,
        )
        camera2TextureSmokeCoordinator = AndroidCamera2TextureSmokeCoordinator(
            context         = binding.applicationContext,
            textureRegistry = binding.textureRegistry,
            channel         = channel,
            mainHandler     = mainHandler,
        )
        camera2SingleCamIngestSpatialSmokeCoordinator = AndroidCamera2SingleCamIngestSpatialSmokeCoordinator(
            context         = binding.applicationContext,
            textureRegistry = binding.textureRegistry,
            channel         = channel,
            mainHandler     = mainHandler,
        )
        camera2SingleCamIngestVulkanSpatialSmokeCoordinator = AndroidCamera2SingleCamIngestVulkanSpatialSmokeCoordinator(
            context     = binding.applicationContext,
            channel     = channel,
            mainHandler = mainHandler,
        )
        dagStreamingPlaybackCoordinator = AndroidDagStreamingPlaybackCoordinator(
            context         = binding.applicationContext,
            textureRegistry = binding.textureRegistry,
            mainHandler     = mainHandler,
        )
        rtcVideoCoordinator = AndroidRtcVideoCoordinator(
            mainHandler = mainHandler,
        )
        media3StreamSourceCoordinator = AndroidMedia3StreamSourceCoordinator(
            mainHandler = mainHandler,
        )
        editorPlaybackCoordinator = AndroidEditorPlaybackCoordinator(
            textureRegistry = binding.textureRegistry,
            channel         = channel,
            mainHandler     = mainHandler,
            context         = binding.applicationContext,
        )
        timelineLiveControlCoordinator = AndroidTimelineLiveControlCoordinator(
            activeTextureIdProvider = { editorPlaybackCoordinator?.activeTimelineTextureId() },
        )
        cameraGraphTransactionCoordinator = AndroidCameraGraphTransactionCoordinator(
            hasActiveCameraProvider = { cameraSource != null },
        )
        multiCamPreviewCoordinator = AndroidCamera2MultiCamPreviewCoordinator(
            context               = binding.applicationContext,
            hasActiveSingleCamera = { cameraSource != null },
        )
        cameraXThermalActuationRouter = AndroidCameraXThermalActuationRouter(
            cameraSourceProvider = { cameraSource },
        )
        dagDiagnosticsCoordinator = AndroidDagDiagnosticsCoordinator(
            context       = binding.applicationContext,
            mainHandler   = mainHandler,
            thermalBridge = thermalStateBridge!!,
        )
        concurrentDecodeSmokeCoordinator = AndroidConcurrentDecodeSmokeCoordinator(
            mainHandler = mainHandler,
        )
        passthroughRemuxSinkSmokeCoordinator = AndroidPassthroughRemuxSinkSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioDecodeBridgeSmokeCoordinator = AndroidAudioDecodeBridgeSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioMixBusSmokeCoordinator = AndroidAudioMixBusSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioGraphTopologySmokeCoordinator = AndroidAudioGraphTopologySmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioGraphTransportClockSmokeCoordinator = AndroidAudioGraphTransportClockSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioRingBufferTransportSmokeCoordinator = AndroidAudioRingBufferTransportSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioClockSmokeCoordinator = AndroidAudioClockSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioTransportCoordinatorSmokeCoordinator = AndroidAudioTransportCoordinatorSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioDecoderRingWriterSmokeCoordinator = AndroidAudioDecoderRingWriterSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioPipelineIntegrationSmokeCoordinator = AndroidAudioPipelineIntegrationSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioDecoderRingIngestSmokeCoordinator = AndroidAudioDecoderRingIngestSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioGraphPipelineSmokeCoordinator = AndroidAudioGraphPipelineSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioGraphPipelineRealDecoderSmokeCoordinator = AndroidAudioGraphPipelineRealDecoderSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioTrackPlaybackSinkSmokeCoordinator = AndroidAudioTrackPlaybackSinkSmokeCoordinator(
            mainHandler = mainHandler,
        )
        multiSourceAudioGraphPipelineSmokeCoordinator = AndroidMultiSourceAudioGraphPipelineSmokeCoordinator(
            mainHandler = mainHandler,
        )
        multiSourceAudioTrackPlaybackSinkCoordinator = AndroidMultiSourceAudioTrackPlaybackSinkCoordinator(
            mainHandler = mainHandler,
        )
        multiSourceNodeOwnedPipelineSmokeCoordinator = AndroidMultiSourceNodeOwnedPipelineSmokeCoordinator(
            mainHandler = mainHandler,
        )
        nodeOwnedAudioSourceGraphPipelineSmokeCoordinator = AndroidNodeOwnedAudioSourceGraphPipelineSmokeCoordinator(
            mainHandler = mainHandler,
        )
        nodeOwnedAudioSourceRealDecoderSmokeCoordinator = AndroidNodeOwnedAudioSourceRealDecoderSmokeCoordinator(
            mainHandler = mainHandler,
        )
        nodeOwnedAudioTrackSinkClockedTransportSmokeCoordinator = AndroidNodeOwnedAudioTrackSinkClockedTransportSmokeCoordinator(
            mainHandler = mainHandler,
        )
        aaudioNodeOwnedSinkSmokeCoordinator = AndroidAaudioNodeOwnedSinkSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioMixBusTimelineSmokeCoordinator = AndroidAudioMixBusTimelineSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioSchedulerEnvelopeSmokeCoordinator = AndroidAudioSchedulerEnvelopeSmokeCoordinator(
            mainHandler = mainHandler,
        )
        audioGraphExportSessionSmokeCoordinator = AndroidAudioGraphExportSessionSmokeCoordinator(
            mainHandler = mainHandler,
        )
        asyncRuntimeQueueSchedulerSmokeCoordinator = AndroidAsyncRuntimeQueueSchedulerSmokeCoordinator(
            mainHandler = mainHandler,
        )
        asyncRuntimeQueueRealDecoderSmokeCoordinator = AndroidAsyncRuntimeQueueRealDecoderSmokeCoordinator(
            mainHandler = mainHandler,
        )
        asyncRuntimeQueueAudioTrackSinkSmokeCoordinator = AndroidAsyncRuntimeQueueAudioTrackSinkSmokeCoordinator(
            mainHandler = mainHandler,
        )
        asyncRuntimeQueueRealtimeClockSmokeCoordinator = AndroidAsyncRuntimeQueueRealtimeClockSmokeCoordinator(
            mainHandler = mainHandler,
        )
        asyncRuntimeQueueMultiSourceRealtimeClockSmokeCoordinator = AndroidAsyncRuntimeQueueMultiSourceRealtimeClockSmokeCoordinator(
            context = binding.applicationContext,
            mainHandler = mainHandler,
        )
        realtimePlaybackTransportCoreSmokeCoordinator = AndroidRealtimePlaybackTransportCoreSmokeCoordinator(
            mainHandler = mainHandler,
        )
        realtimePlaybackAudioTrackSinkSmokeCoordinator = AndroidRealtimePlaybackAudioTrackSinkSmokeCoordinator(
            mainHandler = mainHandler,
        )
        realtimePlaybackInteractiveControlsSmokeCoordinator = AndroidRealtimePlaybackInteractiveControlsSmokeCoordinator(
            mainHandler = mainHandler,
        )
        realtimePlaybackFocusResponseSmokeCoordinator = AndroidRealtimePlaybackFocusResponseSmokeCoordinator(
            context = binding.applicationContext,
            mainHandler = mainHandler,
        )
        realtimePlaybackSinkFaultToleranceSmokeCoordinator = AndroidRealtimePlaybackSinkFaultToleranceSmokeCoordinator(
            mainHandler = mainHandler,
        )
        realtimePlaybackIngestSeamSmokeCoordinator = AndroidRealtimePlaybackIngestSeamSmokeCoordinator(
            mainHandler = mainHandler,
        )
        realtimePlaybackRealDecoderSmokeCoordinator = AndroidRealtimePlaybackRealDecoderSmokeCoordinator(
            mainHandler = mainHandler,
        )
        realtimePlaybackPipelineIntegrationSmokeCoordinator = AndroidRealtimePlaybackPipelineIntegrationSmokeCoordinator(
            mainHandler = mainHandler,
        )
        realtimePlaybackPipelinePauseResumeSmokeCoordinator = AndroidRealtimePlaybackPipelinePauseResumeSmokeCoordinator(
            mainHandler = mainHandler,
        )
        realtimePlaybackPipelineSeekSmokeCoordinator = AndroidRealtimePlaybackPipelineSeekSmokeCoordinator(
            mainHandler = mainHandler,
        )
        realtimePlaybackPipelineFocusResponseSmokeCoordinator = AndroidRealtimePlaybackPipelineFocusResponseSmokeCoordinator(
            context = binding.applicationContext,
            mainHandler = mainHandler,
        )
        realtimePlaybackPipelineSinkFaultToleranceSmokeCoordinator = AndroidRealtimePlaybackPipelineSinkFaultToleranceSmokeCoordinator(
            mainHandler = mainHandler,
        )
        realtimePlaybackPipelineTimestampStabilizationSmokeCoordinator = AndroidRealtimePlaybackPipelineTimestampStabilizationSmokeCoordinator(
            mainHandler = mainHandler,
        )
        realtimePlaybackPipelineClockSyncSmokeCoordinator = AndroidRealtimePlaybackPipelineClockSyncSmokeCoordinator(
            mainHandler = mainHandler,
        )
        realtimeAudioPlaybackProductionSmokeCoordinator = AndroidRealtimeAudioPlaybackProductionSmokeCoordinator(
            context = binding.applicationContext,
            mainHandler = mainHandler,
        )
        multiCamCompositorSmokeCoordinator = AndroidMultiCamCompositorSmokeCoordinator(
            mainHandler = mainHandler,
        )
        multicamSpatialVulkanRenderSmokeCoordinator = AndroidMulticamSpatialVulkanRenderSmokeCoordinator(
            mainHandler = mainHandler,
        )
        multicamDynamicDescriptorSpatialVulkanRenderSmokeCoordinator =
            AndroidMulticamDynamicDescriptorSpatialVulkanRenderSmokeCoordinator(
                mainHandler = mainHandler,
            )
        timelineCompositorSmokeCoordinator = AndroidTimelineCompositorSmokeCoordinator(
            mainHandler = mainHandler,
        )
        timelineTransitionGlesRenderSmokeCoordinator = AndroidTimelineTransitionGlesRenderSmokeCoordinator(
            mainHandler = mainHandler,
        )
        timelineOverlayGlesRenderSmokeCoordinator = AndroidTimelineOverlayGlesRenderSmokeCoordinator(
            mainHandler = mainHandler,
        )
        glesExportOverlaySeamSmokeCoordinator = AndroidGlesExportOverlaySeamSmokeCoordinator(
            mainHandler = mainHandler,
        )
        glesExportOverlayProductionSmokeCoordinator = AndroidGlesExportOverlayProductionSmokeCoordinator(
            mainHandler = mainHandler,
        )
        timelineOverlayTextRasterizerSmokeCoordinator = AndroidTimelineOverlayTextRasterizerSmokeCoordinator(
            mainHandler = mainHandler,
        )
        beautyV2GlesRenderSmokeCoordinator = AndroidBeautyV2GlesRenderSmokeCoordinator(
            mainHandler = mainHandler,
        )
        glesExportBeautySeamSmokeCoordinator = AndroidGlesExportBeautySeamSmokeCoordinator(
            mainHandler = mainHandler,
        )
        glesDualOesTransitionSmokeCoordinator = AndroidGlesDualOesTransitionSmokeCoordinator(
            mainHandler = mainHandler,
        )
        timelineTransitionVulkanRenderSmokeCoordinator = AndroidTimelineTransitionVulkanRenderSmokeCoordinator(
            mainHandler = mainHandler,
        )
        timelineOverlayVulkanRenderSmokeCoordinator = AndroidTimelineOverlayVulkanRenderSmokeCoordinator(
            mainHandler = mainHandler,
        )
        timelineDualDecoderSyncSmokeCoordinator = AndroidTimelineDualDecoderSyncSmokeCoordinator(
            mainHandler = mainHandler,
        )
        beautyV2VulkanRenderSmokeCoordinator = AndroidBeautyV2VulkanRenderSmokeCoordinator(
            mainHandler = mainHandler,
        )
        camera2ConcurrentSmokeCoordinator = AndroidCamera2ConcurrentSmokeCoordinator(
            context     = binding.applicationContext,
            mainHandler = mainHandler,
        )
        editorExportCoordinator = AndroidEditorExportCoordinator(
            context     = binding.applicationContext,
            channel     = channel,
            mainHandler = mainHandler,
        )
        glesTextureSmokeCoordinator = AndroidGlesTextureSmokeCoordinator(
            textureRegistry = binding.textureRegistry,
            channel         = channel,
            mainHandler     = mainHandler,
        )
        stillImageExportCoordinator = AndroidStillImageExportCoordinator(
            context     = binding.applicationContext,
            mainHandler = mainHandler,
        )
        imageCompressionCoordinator = AndroidImageCompressionCoordinator(
            context     = binding.applicationContext,
            mainHandler = mainHandler,
        )
        reverseSidecarCoordinator = AndroidReverseSidecarCoordinator(
            context     = binding.applicationContext,
            mainHandler = mainHandler,
        )
        audioExtractionCoordinator = AndroidAudioExtractionCoordinator(
            context     = binding.applicationContext,
            mainHandler = mainHandler,
        )
        waveformCacheCoordinator = AndroidWaveformCacheCoordinator(
            context     = binding.applicationContext,
            mainHandler = mainHandler,
        )
        audioPlaybackCoordinator = AndroidAudioPlaybackCoordinator(
            mainHandler = mainHandler,
        )
        photoLibrarySaveCoordinator = AndroidPhotoLibrarySaveCoordinator(
            context     = binding.applicationContext,
            mainHandler = mainHandler,
        )
        videoAssetPickerCoordinator = AndroidVideoAssetPickerCoordinator(
            context     = binding.applicationContext,
            mainHandler = mainHandler,
        )
        audioRecordingCoordinator = AndroidAudioRecordingCoordinator(
            context     = binding.applicationContext,
            mainHandler = mainHandler,
        )
        // VG-DUET-SLICE-4A: initialize Duet handler after mainHandler is available, pass textureRegistry.
        // VG-DUET-LIVE-CAMERA: pass applicationContext for AndroidDuetCameraSource CameraX binding.
        duetMethodHandler = AndroidDuetMethodHandler(
            mainHandler,
            binding.textureRegistry,
            binding.applicationContext,
            onDuetEvent = { payload -> mainHandler.post { channel.invokeMethod("onDuetEvent", payload) } },
        )
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        val args = call.arguments as? Map<*, *>

        // ── VG-DUET-SLICE-2: Duet session lifecycle dispatch ──────────────────
        // Intercept all 10 Duet routes before the main switch. Plugin is a thin
        // router only — no session logic lives here.
        if (AndroidDuetMethodHandler.ownsMethod(call.method)) {
            val handler = duetMethodHandler
            if (handler != null) {
                handler.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Duet method handler unavailable", null)
            }
            return
        }

        if (AndroidDagTexturePlaybackCoordinator.ownsMethod(call.method)) {
            val coord = dagTexturePlaybackCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android DAG texture playback coordinator unavailable", null)
            }
            return
        }

        if (AndroidCamera2TextureSmokeCoordinator.ownsMethod(call.method)) {
            val coord = camera2TextureSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android Camera2 texture smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidCamera2SingleCamIngestSpatialSmokeCoordinator.ownsMethod(call.method)) {
            val coord = camera2SingleCamIngestSpatialSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android Camera2 single-cam ingest spatial smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidCamera2SingleCamIngestVulkanSpatialSmokeCoordinator.ownsMethod(call.method)) {
            val coord = camera2SingleCamIngestVulkanSpatialSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android Camera2 single-cam ingest Vulkan spatial smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidDagStreamingPlaybackCoordinator.ownsMethod(call.method)) {
            val coord = dagStreamingPlaybackCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android DAG streaming playback coordinator unavailable", null)
            }
            return
        }

        if (AndroidRtcVideoCoordinator.ownsMethod(call.method)) {
            val coord = rtcVideoCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android RTC video coordinator unavailable", null)
            }
            return
        }

        if (AndroidMedia3StreamSourceCoordinator.ownsMethod(call.method)) {
            val coord = media3StreamSourceCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android Media3 stream-source ingest seam coordinator unavailable", null)
            }
            return
        }

        if (AndroidEditorPlaybackCoordinator.ownsMethod(call.method)) {
            val coord = editorPlaybackCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android editor playback coordinator unavailable", null)
            }
            return
        }

        if (AndroidDagDiagnosticsCoordinator.ownsMethod(call.method)) {
            val coord = dagDiagnosticsCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android DAG diagnostics coordinator unavailable", null)
            }
            return
        }

        if (AndroidCameraXThermalActuationRouter.ownsMethod(call.method)) {
            val router = cameraXThermalActuationRouter
            if (router != null) {
                router.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android CameraX thermal actuation router unavailable", null)
            }
            return
        }

        if (AndroidConcurrentDecodeSmokeCoordinator.ownsMethod(call.method)) {
            val coord = concurrentDecodeSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android concurrent decode smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidPassthroughRemuxSinkSmokeCoordinator.ownsMethod(call.method)) {
            val coord = passthroughRemuxSinkSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android passthrough remux sink smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidGlesTextureSmokeCoordinator.ownsMethod(call.method)) {
            val coord = glesTextureSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android GLES texture smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioDecodeBridgeSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioDecodeBridgeSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio decode bridge smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioMixBusSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioMixBusSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio mix bus smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioGraphTopologySmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioGraphTopologySmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio graph topology smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioGraphTransportClockSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioGraphTransportClockSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio graph transport clock smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioRingBufferTransportSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioRingBufferTransportSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio ring buffer transport smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioClockSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioClockSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio clock smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioTransportCoordinatorSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioTransportCoordinatorSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio transport coordinator smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioDecoderRingWriterSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioDecoderRingWriterSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio decoder ring writer smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioPipelineIntegrationSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioPipelineIntegrationSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio pipeline integration smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioGraphPipelineSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioGraphPipelineSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio graph pipeline smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioGraphPipelineRealDecoderSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioGraphPipelineRealDecoderSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android real decoder audio graph pipeline smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioTrackPlaybackSinkSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioTrackPlaybackSinkSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android AudioTrack output sink smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidMultiSourceAudioTrackPlaybackSinkCoordinator.ownsMethod(call.method)) {
            val coord = multiSourceAudioTrackPlaybackSinkCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android multi-source AudioTrack output sink smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidMultiSourceAudioGraphPipelineSmokeCoordinator.ownsMethod(call.method)) {
            val coord = multiSourceAudioGraphPipelineSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android multi-source audio graph pipeline smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidMultiSourceNodeOwnedPipelineSmokeCoordinator.ownsMethod(call.method)) {
            val coord = multiSourceNodeOwnedPipelineSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android multi-source node-owned pipeline smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidNodeOwnedAudioSourceGraphPipelineSmokeCoordinator.ownsMethod(call.method)) {
            val coord = nodeOwnedAudioSourceGraphPipelineSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android node-owned audio source graph pipeline smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidNodeOwnedAudioSourceRealDecoderSmokeCoordinator.ownsMethod(call.method)) {
            val coord = nodeOwnedAudioSourceRealDecoderSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android node-owned audio source real decoder pipeline smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidNodeOwnedAudioTrackSinkClockedTransportSmokeCoordinator.ownsMethod(call.method)) {
            val coord = nodeOwnedAudioTrackSinkClockedTransportSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android node-owned AudioTrack sink-clocked transport smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAaudioNodeOwnedSinkSmokeCoordinator.ownsMethod(call.method)) {
            val coord = aaudioNodeOwnedSinkSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android AAudio node-owned sink smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioMixBusTimelineSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioMixBusTimelineSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio mix-bus timeline smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioSchedulerEnvelopeSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioSchedulerEnvelopeSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio scheduler envelope smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioGraphExportSessionSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioGraphExportSessionSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio graph export session smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAsyncRuntimeQueueSchedulerSmokeCoordinator.ownsMethod(call.method)) {
            val coord = asyncRuntimeQueueSchedulerSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android async runtime queue scheduler smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAsyncRuntimeQueueRealDecoderSmokeCoordinator.ownsMethod(call.method)) {
            val coord = asyncRuntimeQueueRealDecoderSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android async runtime queue real decoder smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAsyncRuntimeQueueAudioTrackSinkSmokeCoordinator.ownsMethod(call.method)) {
            val coord = asyncRuntimeQueueAudioTrackSinkSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android async runtime queue AudioTrack sink smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAsyncRuntimeQueueRealtimeClockSmokeCoordinator.ownsMethod(call.method)) {
            val coord = asyncRuntimeQueueRealtimeClockSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android async runtime queue realtime clock smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidAsyncRuntimeQueueMultiSourceRealtimeClockSmokeCoordinator.ownsMethod(call.method)) {
            val coord = asyncRuntimeQueueMultiSourceRealtimeClockSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android async runtime queue multi-source realtime clock smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidRealtimePlaybackTransportCoreSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimePlaybackTransportCoreSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime playback transport core smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidRealtimePlaybackAudioTrackSinkSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimePlaybackAudioTrackSinkSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime playback AudioTrack sink smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidRealtimePlaybackInteractiveControlsSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimePlaybackInteractiveControlsSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime playback interactive controls smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidRealtimePlaybackFocusResponseSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimePlaybackFocusResponseSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime playback focus response smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidRealtimePlaybackSinkFaultToleranceSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimePlaybackSinkFaultToleranceSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime playback sink fault tolerance smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidRealtimePlaybackIngestSeamSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimePlaybackIngestSeamSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime playback ingest seam smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidRealtimePlaybackRealDecoderSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimePlaybackRealDecoderSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime playback real decoder smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidRealtimePlaybackPipelineIntegrationSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimePlaybackPipelineIntegrationSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime playback pipeline integration smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidRealtimePlaybackPipelinePauseResumeSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimePlaybackPipelinePauseResumeSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime playback pipeline pause/resume smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidRealtimePlaybackPipelineSeekSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimePlaybackPipelineSeekSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime playback pipeline seek smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidRealtimePlaybackPipelineFocusResponseSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimePlaybackPipelineFocusResponseSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime playback pipeline focus response smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidRealtimePlaybackPipelineSinkFaultToleranceSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimePlaybackPipelineSinkFaultToleranceSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime playback pipeline sink fault tolerance smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidRealtimePlaybackPipelineTimestampStabilizationSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimePlaybackPipelineTimestampStabilizationSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime playback pipeline timestamp stabilization smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidRealtimePlaybackPipelineClockSyncSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimePlaybackPipelineClockSyncSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime playback pipeline clock sync smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.ownsMethod(call.method)) {
            val coord = realtimeAudioPlaybackProductionSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android realtime audio playback production smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidAudioDecoderRingIngestSmokeCoordinator.ownsMethod(call.method)) {
            val coord = audioDecoderRingIngestSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio decoder ring ingest smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidMultiCamCompositorSmokeCoordinator.ownsMethod(call.method)) {
            val coord = multiCamCompositorSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android multi-cam compositor smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidMulticamSpatialVulkanRenderSmokeCoordinator.ownsMethod(call.method)) {
            val coord = multicamSpatialVulkanRenderSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android multi-cam spatial Vulkan render smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidMulticamDynamicDescriptorSpatialVulkanRenderSmokeCoordinator.ownsMethod(call.method)) {
            val coord = multicamDynamicDescriptorSpatialVulkanRenderSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android multi-cam dynamic-descriptor spatial Vulkan render smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidTimelineCompositorSmokeCoordinator.ownsMethod(call.method)) {
            val coord = timelineCompositorSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android timeline compositor smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidTimelineTransitionGlesRenderSmokeCoordinator.ownsMethod(call.method)) {
            val coord = timelineTransitionGlesRenderSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android timeline transition GLES render smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidTimelineOverlayGlesRenderSmokeCoordinator.ownsMethod(call.method)) {
            val coord = timelineOverlayGlesRenderSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android timeline overlay GLES render smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidGlesExportOverlaySeamSmokeCoordinator.ownsMethod(call.method)) {
            val coord = glesExportOverlaySeamSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android GLES export overlay seam smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidGlesExportOverlayProductionSmokeCoordinator.ownsMethod(call.method)) {
            val coord = glesExportOverlayProductionSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android GLES export overlay production smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidTimelineOverlayTextRasterizerSmokeCoordinator.ownsMethod(call.method)) {
            val coord = timelineOverlayTextRasterizerSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android timeline overlay text rasterizer smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidBeautyV2GlesRenderSmokeCoordinator.ownsMethod(call.method)) {
            val coord = beautyV2GlesRenderSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android beauty V2 GLES render smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidGlesExportBeautySeamSmokeCoordinator.ownsMethod(call.method)) {
            val coord = glesExportBeautySeamSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android GLES export beauty seam smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidGlesDualOesTransitionSmokeCoordinator.ownsMethod(call.method)) {
            val coord = glesDualOesTransitionSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android GLES dual OES transition smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidTimelineTransitionVulkanRenderSmokeCoordinator.ownsMethod(call.method)) {
            val coord = timelineTransitionVulkanRenderSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android timeline transition Vulkan render smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidTimelineOverlayVulkanRenderSmokeCoordinator.ownsMethod(call.method)) {
            val coord = timelineOverlayVulkanRenderSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android timeline overlay Vulkan render smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidBeautyV2VulkanRenderSmokeCoordinator.ownsMethod(call.method)) {
            val coord = beautyV2VulkanRenderSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android beauty V2 Vulkan render smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidTimelineDualDecoderSyncSmokeCoordinator.ownsMethod(call.method)) {
            val coord = timelineDualDecoderSyncSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error(
                    "UNAVAILABLE",
                    "Android timeline dual decoder sync smoke coordinator unavailable",
                    null,
                )
            }
            return
        }

        if (AndroidCamera2ConcurrentSmokeCoordinator.ownsMethod(call.method)) {
            val coord = camera2ConcurrentSmokeCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android Camera2 concurrent ingest smoke coordinator unavailable", null)
            }
            return
        }

        if (AndroidThermalStateBridge.ownsMethod(call.method)) {
            val bridge = thermalStateBridge
            if (bridge != null) {
                bridge.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android thermal state bridge unavailable", null)
            }
            return
        }

        if (AndroidReverseSidecarCoordinator.ownsMethod(call.method)) {
            val coord = reverseSidecarCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android reverse sidecar coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioExtractionCoordinator.ownsMethod(call.method)) {
            val coord = audioExtractionCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio extraction coordinator unavailable", null)
            }
            return
        }

        if (AndroidWaveformCacheCoordinator.ownsMethod(call.method)) {
            val coord = waveformCacheCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android waveform cache coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioPlaybackCoordinator.ownsMethod(call.method)) {
            val coord = audioPlaybackCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio playback coordinator unavailable", null)
            }
            return
        }

        if (AndroidPhotoLibrarySaveCoordinator.ownsMethod(call.method)) {
            val coord = photoLibrarySaveCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android photo library save coordinator unavailable", null)
            }
            return
        }

        if (AndroidVideoAssetPickerCoordinator.ownsMethod(call.method)) {
            val coord = videoAssetPickerCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android video asset picker coordinator unavailable", null)
            }
            return
        }

        if (AndroidAudioRecordingCoordinator.ownsMethod(call.method)) {
            val coord = audioRecordingCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android audio recording coordinator unavailable", null)
            }
            return
        }

        if (AndroidStillImageExportCoordinator.ownsMethod(call.method)) {
            val coord = stillImageExportCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android still-image export coordinator unavailable", null)
            }
            return
        }

        if (AndroidImageCompressionCoordinator.ownsMethod(call.method)) {
            val coord = imageCompressionCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android image compression coordinator unavailable", null)
            }
            return
        }

        if (AndroidTimelineLiveControlCoordinator.ownsMethod(call.method)) {
            val coord = timelineLiveControlCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android timeline live control coordinator unavailable", null)
            }
            return
        }

        if (AndroidCameraGraphTransactionCoordinator.ownsMethod(call.method)) {
            val coord = cameraGraphTransactionCoordinator
            if (coord != null) {
                coord.handleMethodCall(call.method, args, result)
            } else {
                result.error("UNAVAILABLE", "Android camera graph transaction coordinator unavailable", null)
            }
            return
        }

        if (AndroidCamera2MultiCamPreviewCoordinator.ownsMethod(call.method)) {
            val coord = multiCamPreviewCoordinator
            if (coord != null) {
                @Suppress("UNCHECKED_CAST")
                coord.handle(call.method, args as? Map<String, Any?>, result)
            } else {
                result.error("UNAVAILABLE", "Android multicam preview coordinator unavailable", null)
            }
            return
        }

        when (call.method) {

            "createTexture" -> {
                val path = args?.get("path") as? String
                    ?: return result.error("INVALID_ARG", "path required", null)

                val renderer = VanguardGLRenderer(
                    context         = context,
                    videoPath       = path,
                    textureRegistry = binding.textureRegistry,
                    methodChannel   = channel
                )
                renderers[renderer.textureId] = renderer
                result.success(renderer.textureId)
            }

            "play" -> {
                val textureId = (args?.get("textureId") as? Number)?.toLong() ?: return
                renderers[textureId]?.play()
                result.success(null)
            }

            "pause" -> {
                val textureId = (args?.get("textureId") as? Number)?.toLong() ?: return
                renderers[textureId]?.pause()
                result.success(null)
            }

            "seekTo" -> {
                // Phase 3: seekTo hook — MediaExtractor seekTo implementation
                // will be wired in Phase 4 alongside scrubber UI
                result.success(null)
            }

            "dispose" -> {
                val textureId = (args?.get("textureId") as? Number)?.toLong() ?: return
                // B3: dispose covers both GL video renderers and image texture loaders.
                renderers[textureId]?.dispose()
                renderers.remove(textureId)
                imageLoaders[textureId]?.dispose()
                imageLoaders.remove(textureId)
                result.success(null)
            }

            // ─── B3: Media fundamentals ─────────────────────────────────────────────────

            "probeVideoDuration" -> {
                // Mirrors iOS: AVURLAsset.duration — returns seconds as Double, -1.0 on failure.
                // Off main thread: setDataSource can block on I/O.
                val path = args?.get("path") as? String
                if (path == null) {
                    result.error("INVALID_ARG", "probeVideoDuration: path required", null)
                    return
                }
                // Slice 2: path may be POSIX or content:// — helper picks the overload.
                val probeContext = context
                Thread {
                    val retriever = MediaMetadataRetriever()
                    try {
                        AndroidUriDataSourceHelper.setRetrieverDataSource(retriever, path, probeContext)
                        val ms = retriever
                            .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                            ?.toLongOrNull() ?: -1L
                        val seconds = if (ms >= 0L) ms / 1000.0 else -1.0
                        mainHandler.post { result.success(seconds) }
                    } catch (e: Exception) {
                        Log.e(TAG, "probeVideoDuration: $e")
                        mainHandler.post { result.success(-1.0) } // matches iOS null→null contract
                    } finally {
                        try { retriever.release() } catch (_: Exception) {}
                    }
                }.start()
            }

            // ─── Phase-1 metadata: probeVideoInfo (returns duration + dimensions) ────────
            "probeVideoInfo" -> {
                // Returns {duration: Double, width: Int, height: Int} for a video file.
                // Used by story_export_service to replace FFmpegKit metadata probes.
                // Android: MediaMetadataRetriever (same retriever used by probeVideoDuration).
                val path = args?.get("path") as? String
                if (path == null) {
                    result.error("INVALID_ARG", "probeVideoInfo: path required", null)
                    return
                }
                // Slice 2: path may be POSIX or content:// — helper picks the overload.
                val probeContext = context
                Thread {
                    val retriever = MediaMetadataRetriever()
                    try {
                        AndroidUriDataSourceHelper.setRetrieverDataSource(retriever, path, probeContext)
                        val ms      = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: -1L
                        val wStr    = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                        val hStr    = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                        val seconds = if (ms >= 0L) ms / 1000.0 else -1.0
                        val w       = wStr?.toIntOrNull() ?: 0
                        val h       = hStr?.toIntOrNull() ?: 0
                        mainHandler.post {
                            result.success(mapOf("duration" to seconds, "width" to w, "height" to h))
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "probeVideoInfo: $e")
                        mainHandler.post {
                            result.success(mapOf("duration" to -1.0, "width" to 0, "height" to 0))
                        }
                    } finally {
                        try { retriever.release() } catch (_: Exception) {}
                    }
                }.start()
            }

            // ── inspectMedia ──────────────────────────────────────────────────────────
            // Extended media probe (superset of probeVideoInfo). Returns full MediaInfo
            // map needed by VanguardMediaPreparer decision logic.
            // probeVideoInfo is kept unchanged — do not remove it.
            "inspectMedia" -> {
                val path = args?.get("path") as? String
                if (path == null) {
                    result.error("INVALID_ARG", "inspectMedia: path required", null)
                    return
                }

                // Container / kind classification computed up front (extension-based fast
                // path) so still images can bypass MediaMetadataRetriever/MediaExtractor
                // entirely below -- neither API can read still-image bounds/EXIF reliably.
                // Slice 2: for content:// derive the extension from the last path segment
                // only, so provider authorities (e.g. "com.android.providers.media") are
                // never mistaken for an extension. POSIX derivation is unchanged.
                val ext = if (AndroidUriDataSourceHelper.isContentUri(path)) {
                    val lastSegment = android.net.Uri.parse(path).lastPathSegment ?: ""
                    lastSegment.substringAfterLast('.', "").lowercase()
                } else {
                    path.substringAfterLast('.', "").lowercase()
                }
                val container = when (ext) {
                    "mp4", "m4v"   -> "mp4"
                    "mov"          -> "mov"
                    "mkv"          -> "mkv"
                    "webm"         -> "webm"
                    "avi"          -> "avi"
                    "jpg", "jpeg"  -> "jpeg"
                    "png"          -> "png"
                    "heic"         -> "heic"
                    "webp"         -> "webp"
                    "m4a"          -> "m4a"
                    "mp3"          -> "mp3"
                    "aac"          -> "aac"
                    else           -> ext
                }
                val imageExts = setOf("jpg","jpeg","png","heic","webp","gif","bmp","tiff")
                val audioExts = setOf("m4a","aac","mp3","wav","flac","ogg")

                // Phase 5-Unit U: still-image path — probes real bounds/EXIF via
                // AndroidStillImageDecoder instead of failing closed on zero dimensions.
                if (imageExts.contains(ext)) {
                    Thread {
                        val bounds = AndroidStillImageDecoder.probeBounds(path)
                        if (bounds == null) {
                            mainHandler.post {
                                result.error("INSPECT_FAILED", "inspectMedia: unreadable image bounds", null)
                            }
                            return@Thread
                        }
                        val exifOrientation = AndroidStillImageDecoder.readExifOrientation(path)
                        val displayBounds = AndroidStillImageDecoder.getDisplayBounds(
                            bounds.width, bounds.height, exifOrientation,
                        )

                        // rotationDegrees is null for mirrored/transpose/transverse/undefined —
                        // Unit U does not claim raw portrait-space EXIF coordinate rotation.
                        val rotationDeg = when (exifOrientation) {
                            ExifInterface.ORIENTATION_NORMAL     -> 0
                            ExifInterface.ORIENTATION_ROTATE_90  -> 90
                            ExifInterface.ORIENTATION_ROTATE_180 -> 180
                            ExifInterface.ORIENTATION_ROTATE_270 -> 270
                            else -> null
                        }
                        val orientationStatus = if (rotationDeg != null) "valid" else "ambiguous"
                        val hasRotationTransform = rotationDeg == 90 || rotationDeg == 180 || rotationDeg == 270

                        // Matrix values mirror the existing video cardinal-rotation mapping below.
                        val tA: Double; val tB: Double; val tC: Double; val tD: Double
                        when (rotationDeg ?: 0) {
                            90  -> { tA =  0.0; tB =  1.0; tC = -1.0; tD =  0.0 }
                            180 -> { tA = -1.0; tB =  0.0; tC =  0.0; tD = -1.0 }
                            270 -> { tA =  0.0; tB = -1.0; tC =  1.0; tD =  0.0 }
                            else -> { tA =  1.0; tB =  0.0; tC =  0.0; tD =  1.0 }
                        }

                        val fileSizeBytes = java.io.File(path).length()

                        mainHandler.post {
                            result.success(mapOf(
                                "kind"                 to "image",
                                "container"            to container,
                                "videoCodec"           to "",
                                "audioCodec"           to "",
                                "width"                to bounds.width,
                                "height"               to bounds.height,
                                "durationSeconds"      to 0.0,
                                "bitrateKbps"          to 0,
                                "fps"                  to 0.0,
                                "fileSizeBytes"        to fileSizeBytes,
                                "hasVideo"             to false,
                                "hasAudio"             to false,
                                "isHDR"                to false,
                                "hasMoovAtFront"       to false,
                                "hasRotationTransform" to hasRotationTransform,
                                "hasEmbeddedMetadata"  to false,
                                "encodedWidth"         to bounds.width,
                                "encodedHeight"        to bounds.height,
                                "displayWidth"         to displayBounds.width,
                                "displayHeight"        to displayBounds.height,
                                "rotationDegrees"      to rotationDeg,
                                "transformA"           to tA,
                                "transformB"           to tB,
                                "transformC"           to tC,
                                "transformD"           to tD,
                                "transformTx"          to 0.0,
                                "transformTy"          to 0.0,
                                "orientationStatus"    to orientationStatus,
                            ))
                        }
                    }.start()
                    return
                }

                // Slice 2: video path may be POSIX or content:// — helper picks the
                // Context+Uri overloads and the resolver-backed size query.
                val inspectContext = context
                Thread {
                    val retriever = MediaMetadataRetriever()
                    try {
                        AndroidUriDataSourceHelper.setRetrieverDataSource(retriever, path, inspectContext)

                        // Duration
                        val ms      = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: -1L
                        val seconds = if (ms >= 0L) ms / 1000.0 else -1.0

                        // Dimensions
                        val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                        val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0

                        // Bitrate (container-level; acceptable for decision logic)
                        val bitrateRaw = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toLongOrNull() ?: 0L
                        val bitrateKbps = (bitrateRaw / 1000L).toInt()

                        // FPS
                        val fpsStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)
                        val fps = fpsStr?.toDoubleOrNull() ?: 0.0

                        // Track presence
                        val hasVideo = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes"
                        val hasAudio = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"

                        // Rotation (non-zero means rotation metadata is present as transform, not baked)
                        val rotationStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                        val hasRotationTransform = (rotationStr?.toIntOrNull() ?: 0) != 0

                        // ROI-5A.1 — Orientation evidence from integer rotation metadata.
                        // Android MediaMetadataRetriever returns rotation as 0/90/180/270 or null.
                        // Mirroring is not exposed via this API; validMirrored is iOS-only.
                        val rotationDeg = rotationStr?.toIntOrNull()
                        val isCardinal = rotationDeg != null &&
                            (rotationDeg == 0 || rotationDeg == 90 || rotationDeg == 180 || rotationDeg == 270)

                        val hasVideoTrack = w > 0 && h > 0
                        val orientationStatus = when {
                            !hasVideoTrack -> "noVideoTrack"
                            isCardinal     -> "valid"
                            else           -> "ambiguous"
                        }

                        // Display dimensions: swap for 90°/270°.
                        val displayW: Int
                        val displayH: Int
                        if (hasVideoTrack && isCardinal &&
                            (rotationDeg == 90 || rotationDeg == 270)) {
                            displayW = h
                            displayH = w
                        } else {
                            displayW = w
                            displayH = h
                        }

                        // Synthesize matrix values from integer rotation for cross-platform parity.
                        // Camera-produced clips are 0° (identity); gallery clips may differ.
                        val tA: Double; val tB: Double; val tC: Double; val tD: Double
                        when (if (isCardinal) rotationDeg else 0) {
                            90  -> { tA =  0.0; tB =  1.0; tC = -1.0; tD =  0.0 }
                            180 -> { tA = -1.0; tB =  0.0; tC =  0.0; tD = -1.0 }
                            270 -> { tA =  0.0; tB = -1.0; tC =  1.0; tD =  0.0 }
                            else -> { tA =  1.0; tB =  0.0; tC =  0.0; tD =  1.0 }
                        }


                        // Embedded GPS metadata
                        val location = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION)
                        val hasEmbeddedMetadata = location != null

                        // Codec — derive from MIME type (most reliable approach on Android)
                        // METADATA_KEY_MIMETYPE returns container MIME e.g. "video/mp4".
                        // We need to use MediaExtractor to get per-track codec MIME.
                        // For the decision policy, we only need to distinguish h264 / hevc / other.
                        val mimeType = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE) ?: ""
                        // Use MediaExtractor for accurate per-track codec detection
                        var videoCodec = ""
                        var audioCodec = ""
                        try {
                            val extractor = android.media.MediaExtractor()
                            AndroidUriDataSourceHelper.setExtractorDataSource(extractor, path, inspectContext)
                            for (i in 0 until extractor.trackCount) {
                                val fmt  = extractor.getTrackFormat(i)
                                val mime = fmt.getString(android.media.MediaFormat.KEY_MIME) ?: ""
                                when {
                                    mime.startsWith("video/") && videoCodec.isEmpty() -> {
                                        videoCodec = when (mime) {
                                            "video/avc",    // H.264 / AVC
                                            "video/AVE"     -> "h264"
                                            "video/hevc"    -> "hevc"
                                            "video/x-vnd.on2.vp9",
                                            "video/vp9"     -> "vp9"
                                            "video/av01"    -> "av1"
                                            "video/mp4v-es" -> "mpeg4"
                                            else            -> mime
                                        }
                                    }
                                    mime.startsWith("audio/") && audioCodec.isEmpty() -> {
                                        audioCodec = when (mime) {
                                            "audio/mp4a-latm" -> "aac"
                                            "audio/ac3"       -> "ac3"
                                            "audio/eac3"      -> "ac3"
                                            "audio/mpeg"      -> "mp3"
                                            "audio/opus"      -> "opus"
                                            "audio/raw"       -> "pcm"
                                            else              -> mime
                                        }
                                    }
                                }
                            }
                            extractor.release()
                        } catch (_: Exception) {
                            // MediaExtractor codec detection failed — fall back to container MIME
                            // "unknown" audioCodec treated as safe (aac assumed) in Dart policy
                        }

                        // File size (POSIX: File.length(); content://: OpenableColumns.SIZE
                        // then PFD statSize fallback, cursor/PFD closed by the helper).
                        val fileSizeBytes = AndroidUriDataSourceHelper.fileSizeBytes(path, inspectContext)

                        // MediaKind (ext/container/imageExts/audioExts derived above,
                        // before the still-image bypass check).
                        val kind = when {
                            imageExts.contains(ext)  -> "image"
                            audioExts.contains(ext)  -> "audio"
                            hasVideo || listOf("mp4","mov","mkv","webm","avi","m4v").contains(ext) -> "video"
                            else -> "unknown"
                        }

                        // isHDR: METADATA_KEY_COLOR_TRANSFER requires API 30+; conservative false below.
                        val isHDR = false

                        // hasMoovAtFront: conservatively false by default (see implementation plan §B2).
                        val hasMoovAtFront = false

                        mainHandler.post {
                            // Build result map. Existing keys are preserved unchanged.
                            val resultMap = mutableMapOf<String, Any?>(
                                "kind"                 to kind,
                                "container"            to container,
                                "videoCodec"           to videoCodec,
                                "audioCodec"           to audioCodec,
                                "width"                to w,
                                "height"               to h,
                                "durationSeconds"      to seconds,
                                "bitrateKbps"          to bitrateKbps,
                                "fps"                  to fps,
                                "fileSizeBytes"        to fileSizeBytes,
                                "hasVideo"             to hasVideo,
                                "hasAudio"             to hasAudio,
                                "isHDR"                to isHDR,
                                "hasMoovAtFront"       to hasMoovAtFront,
                                "hasRotationTransform" to hasRotationTransform,
                                "hasEmbeddedMetadata"  to hasEmbeddedMetadata,
                                // ROI-5A.1 orientation evidence (additive).
                                "encodedWidth"         to w,
                                "encodedHeight"        to h,
                                "displayWidth"         to displayW,
                                "displayHeight"        to displayH,
                                // rotationDegrees: null when non-cardinal or no track.
                                "rotationDegrees"      to if (isCardinal) rotationDeg else null,
                                "transformA"           to tA,
                                "transformB"           to tB,
                                "transformC"           to tC,
                                "transformD"           to tD,
                                "transformTx"          to 0.0,
                                "transformTy"          to 0.0,
                                "orientationStatus"    to orientationStatus,
                            )
                            result.success(resultMap)
                        }

                    } catch (e: Exception) {
                        Log.e(TAG, "inspectMedia: $e")
                        mainHandler.post {
                            result.error("INSPECT_FAILED", "inspectMedia: ${e.message}", null)
                        }
                    } finally {
                        try { retriever.release() } catch (_: Exception) {}
                    }
                }.start()
            }

            // ── optimizeImage (Phase 5 Unit E) ──────────────────────────────────────────
            // Thin route -- all decode/resize/encode policy lives in AndroidImageOptimizer.
            "optimizeImage" -> {
                AndroidImageOptimizer.optimize(context, args, result, mainHandler)
            }

            "generateThumbnails" -> {
                // Mirrors iOS: AVAssetImageGenerator — returns List<ByteArray> (JPEG frames).
                // Dart side: List<Uint8List> — ByteArray maps directly.
                val videoPath = args?.get("videoPath") as? String
                val count     = (args?.get("count")    as? Number)?.toInt()    ?: 8
                val duration  = (args?.get("duration") as? Number)?.toDouble() ?: 0.0
                val maxWidth  = (args?.get("maxWidth") as? Number)?.toInt()
                val maxHeight = (args?.get("maxHeight") as? Number)?.toInt()
                val jpegQuality = (args?.get("jpegQuality") as? Number)?.toDouble()
                if (videoPath == null) {
                    result.error("INVALID_ARG", "generateThumbnails: videoPath required", null)
                    return
                }
                Thread {
                    val frames = VanguardThumbnailExtractor.extract(
                        videoPath, count, duration, maxWidth, maxHeight, jpegQuality
                    )
                    mainHandler.post { result.success(frames) }
                }.start()
            }

            // ── ROI-5B.1: Display-Oriented Frame Extraction Evidence ──────────
            // Diagnostic-only. Decodes the first frame via MediaMetadataRetriever
            // and returns its Bitmap dimensions. The Bitmap is recycled immediately
            // — no JPEG encoding, no file writes, no face detection.
            //
            // rotationHandling = "platformDecoderUnverified": Android API 29+
            // getFrameAtTime() auto-rotates by METADATA_KEY_VIDEO_ROTATION, but
            // behaviour on older APIs is not guaranteed. ROI-5B.2 physical smoke
            // will compare these dimensions against inspectMedia.displayWidth/
            // displayHeight on real devices to verify correctness.
            "extractDisplayOrientedFrameEvidence" -> {
                val videoPath = args?.get("videoPath") as? String
                if (videoPath.isNullOrEmpty()) {
                    result.error("INVALID_ARG",
                        "extractDisplayOrientedFrameEvidence: videoPath required", null)
                    return
                }
                Thread {
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(videoPath)
                        val bitmap = retriever.getFrameAtTime(
                            0L,
                            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        )
                        if (bitmap != null) {
                            val w = bitmap.width
                            val h = bitmap.height
                            bitmap.recycle() // release immediately — no further use
                            mainHandler.post {
                                result.success(mapOf(
                                    "extractedFrameWidth"     to w,
                                    "extractedFrameHeight"    to h,
                                    "method"                  to "MediaMetadataRetriever.getFrameAtTime",
                                    "rotationHandling"        to "platformDecoderUnverified",
                                    "displayTransformApplied" to null,
                                    "requestedTimeSeconds"    to 0.0,
                                ))
                            }
                        } else {
                            mainHandler.post {
                                result.error("DECODE_FAILED",
                                    "extractDisplayOrientedFrameEvidence: getFrameAtTime returned null",
                                    null)
                            }
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "extractDisplayOrientedFrameEvidence: $e")
                        mainHandler.post {
                            result.error("DECODE_FAILED",
                                "extractDisplayOrientedFrameEvidence: ${e.message}", null)
                        }
                    } finally {
                        try { retriever.release() } catch (_: Exception) {}
                    }
                }.start()
            }

            // ROI-5C.1 Android stub — blocked until ROI-5B Android smoke passes.
            // Android face detection is NOT implemented in this slice.
            // Returns UNSUPPORTED_PLATFORM so Dart can handle it gracefully.
            "extractImportedFaceScanEvidence" -> {
                result.error(
                    "UNSUPPORTED_PLATFORM",
                    "ROI-5C Android face scan evidence is blocked until " +
                        "ROI-5B Android smoke passes",
                    null,
                )
            }


            "createImageTexture" -> {

                // Mirrors iOS: CVPixelBuffer → Metal Texture — returns textureId.
                // Android: BitmapFactory → Surface.lockCanvas() → Flutter SurfaceTexture.
                val path = args?.get("path") as? String
                if (path == null) {
                    result.error("INVALID_ARG", "createImageTexture: path required", null)
                    return
                }
                if (!java.io.File(path).exists()) {
                    result.error("FILE_NOT_FOUND", "createImageTexture: not found: $path", null)
                    return
                }
                val loader = VanguardImageTextureLoader(path, binding.textureRegistry)
                loader.load(
                    onLoaded = { id ->
                        imageLoaders[id] = loader
                        result.success(id)
                    },
                    onError = { e ->
                        // textureEntry already released inside VanguardImageTextureLoader.load()
                        result.error("ENCODE_FAIL", e.message, null)
                    }
                )
            }

            // ─── Export Unit C: production exportTimeline ──────────────────────────────
            // Delegates entirely to AndroidEditorExportCoordinator. Independent of the
            // legacy startExport/VanguardMediaCodecEncoder dev-proof path below.
            "exportTimeline" -> {
                val coord = editorExportCoordinator
                if (coord != null) {
                    coord.exportTimeline(args, result)
                } else {
                    result.error("UNAVAILABLE", "Android editor export coordinator unavailable", null)
                }
            }

            // --- Phase 2-Unit AD: production exportPassthroughRemux --------------------
            // Delegates entirely to AndroidEditorExportCoordinator, sharing its
            // single-export lock with exportTimeline.
            "exportPassthroughRemux" -> {
                val coord = editorExportCoordinator
                if (coord != null) {
                    coord.exportPassthroughRemux(args, result)
                } else {
                    result.error("UNAVAILABLE", "Android editor export coordinator unavailable", null)
                }
            }

            // --- Phase 5-Unit AA / Phase 2-Unit AI: production normalizeVideo -----------
            // Delegates entirely to AndroidEditorExportCoordinator, sharing its
            // single-export lock with exportTimeline / exportPassthroughRemux.
            "normalizeVideo" -> {
                val coord = editorExportCoordinator
                if (coord != null) {
                    coord.normalizeVideo(args, result)
                } else {
                    result.error("UNAVAILABLE", "Android editor export coordinator unavailable", null)
                }
            }

            "startExport" -> {
                // B3: Dart sends List<Map<String,dynamic>> {path, trimStart, trimEnd}.
                // B4-S2: per-clip trim seek + EOS boundary.
                // B4-S4: if audioPath provided, encoder writes video-only to a temp path;
                //        after finish, remuxVideoWithAudio() merges video + audio into
                //        outputPath via a fresh MediaMuxer (2-pass, no encoder changes).
                @Suppress("UNCHECKED_CAST")
                val clipMaps   = (args?.get("clips") as? List<*>)?.filterIsInstance<Map<*, *>>()
                val outputPath = args?.get("outputPath") as? String
                val audioPath  = args?.get("audioPath")  as? String   // B4-S4
                val bitrate    = (args?.get("bitrate")    as? Number)?.toInt()    ?: 1_200_000
                val maxSeconds = (args?.get("maxSeconds") as? Number)?.toDouble() ?: 30.0

                // B4-S2: per-clip trim spec.
                data class ClipSpec(val path: String, val trimStart: Double, val trimEnd: Double?)
                val clipSpecs = clipMaps?.mapNotNull { m ->
                    val path = m["path"] as? String ?: return@mapNotNull null
                    ClipSpec(
                        path      = path,
                        trimStart = (m["trimStart"] as? Number)?.toDouble() ?: 0.0,
                        trimEnd   = (m["trimEnd"]   as? Number)?.toDouble(),
                    )
                } ?: emptyList()

                if (clipSpecs.isEmpty() || outputPath == null) {
                    result.error("INVALID_ARG", "clips (non-empty) and outputPath required", null)
                    return
                }

                // B4-S4: encoder writes to a temp file when audio must be merged afterwards.
                val needAudioMux = audioPath != null && java.io.File(audioPath).exists()
                val encoderOutputPath = if (needAudioMux) "$outputPath.vtmp" else outputPath

                val encoder = VanguardMediaCodecEncoder(
                    outputPath    = encoderOutputPath,
                    bitrate       = bitrate,
                    maxSeconds    = maxSeconds,
                    methodChannel = channel
                )
                encoder.prepare()
                activeEncoder = encoder  // B4-S5: store for cancelExport

                // Decode each clip through the encoder.
                // B4-S2: each clip is seeked to trimStart; input stops at trimEnd.
                Thread {
                    for (spec in clipSpecs) {
                        if (encoder.cancelled) break  // B4-S5: stop between clips on cancel
                        val extractor = MediaExtractor()
                        extractor.setDataSource(spec.path)

                        var trackIndex = -1
                        for (i in 0 until extractor.trackCount) {
                            val format = extractor.getTrackFormat(i)
                            if (format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                                trackIndex = i; break
                            }
                        }
                        if (trackIndex < 0) { extractor.release(); continue }
                        extractor.selectTrack(trackIndex)

                        // B4-S2: seek to trimStart before decoding
                        val trimStartUs = (spec.trimStart * 1_000_000L).toLong()
                        if (trimStartUs > 0L) {
                            extractor.seekTo(trimStartUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                        }
                        // Long.MAX_VALUE = no trimEnd constraint (full clip after trimStart)
                        val trimEndUs = spec.trimEnd?.let { (it * 1_000_000L).toLong() } ?: Long.MAX_VALUE

                        val decoder = MediaCodec.createDecoderByType(
                            extractor.getTrackFormat(trackIndex).getString(MediaFormat.KEY_MIME)!!
                        )
                        decoder.configure(extractor.getTrackFormat(trackIndex), null, null, 0)
                        decoder.start()

                        val info = MediaCodec.BufferInfo()
                        var inputDone = false
                        while (true) {
                            // B4-S5 (fix): on cancel, queue decoder EOS exactly once so the
                            // decoder drain loop can break naturally. Without this, the decoder
                            // never sees EOS and the while(true) hangs indefinitely.
                            if (encoder.cancelled && !inputDone) {
                                val inIdx = decoder.dequeueInputBuffer(10_000)
                                if (inIdx >= 0) {
                                    decoder.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                    inputDone = true
                                }
                                // If no buffer slot yet, loop — EOS queued on next iteration.
                            }
                            if (!inputDone) {
                                val inIdx = decoder.dequeueInputBuffer(10_000)
                                if (inIdx >= 0) {
                                    val buf  = decoder.getInputBuffer(inIdx)!!
                                    val size = extractor.readSampleData(buf, 0)
                                    // B4-S2: stop feeding at natural EOS or trimEnd boundary
                                    if (size < 0 || extractor.sampleTime > trimEndUs) {
                                        decoder.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                        inputDone = true
                                    } else {
                                        decoder.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                                        extractor.advance()
                                    }
                                }
                            }
                            val outIdx = decoder.dequeueOutputBuffer(info, 10_000)
                            if (outIdx >= 0) {
                                // render=true → frame goes to encoder input surface via GL
                                decoder.releaseOutputBuffer(outIdx, true)
                                encoder.submitFrame()
                                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                            }
                        }
                        decoder.stop(); decoder.release(); extractor.release()
                    }
                    encoder.finish { success ->
                        activeEncoder = null  // B4-S5: clear plugin-level ref

                        // B4-S5 (fix): cancelled — clean up output files, resolve startExport as failed.
                        // Both output paths must be cleaned:
                        //   needAudioMux=true  → encoderOutputPath (.vtmp) is the partial file
                        //   needAudioMux=false → outputPath itself is the partial/corrupt file
                        if (encoder.cancelled) {
                            if (needAudioMux) {
                                java.io.File(encoderOutputPath).delete()
                            } else {
                                java.io.File(outputPath).delete()
                            }
                            result.success(mapOf("outputPath" to outputPath, "success" to false))
                            return@finish
                        }

                        if (!success) {
                            // Encode failed — clean up temp and return failure.
                            if (needAudioMux) java.io.File(encoderOutputPath).delete()
                            result.success(mapOf("outputPath" to outputPath, "success" to false))
                            return@finish
                        }
                        if (needAudioMux) {
                            // B4-S4: remux video-only temp + audio into final output.
                            try {
                                remuxVideoWithAudio(encoderOutputPath, audioPath!!, outputPath)
                                java.io.File(encoderOutputPath).delete()
                                result.success(mapOf("outputPath" to outputPath, "success" to true))
                            } catch (e: Exception) {
                                Log.e(TAG, "remuxVideoWithAudio: $e")
                                // Fall back to video-only: rename temp to final
                                java.io.File(encoderOutputPath).renameTo(java.io.File(outputPath))
                                result.success(mapOf("outputPath" to outputPath, "success" to true))
                            }
                        } else {
                            result.success(mapOf("outputPath" to outputPath, "success" to true))
                        }
                    }
                }.start()
            }

            // ─── Camera pipeline (B2) ────────────────────────────────────────────────

            "startCamera" -> {
                // Extract Dart args — mirrors iOS: position (1=back, 2=front), fps.
                val positionInt = (args?.get("position") as? Number)?.toInt() ?: 1
                val fps         = (args?.get("fps")      as? Number)?.toInt() ?: 30
                val lensFacing  = if (positionInt == 2)
                    androidx.camera.core.CameraSelector.LENS_FACING_FRONT
                else
                    androidx.camera.core.CameraSelector.LENS_FACING_BACK

                // I-2 HARD RESET: stop any existing camera session before creating
                // a new one. Mirrors iOS: teardownCameraAsync → cameraSource?.stop().
                val prev = cameraSource
                if (prev != null) {
                    Log.w(TAG, "startCamera: previous session still active — stopping first")
                    prev.stop()
                    cameraSource = null
                    val prevTex = cameraTexture
                    if (prevTex != null) {
                        Log.i("VanguardTex", "[RELEASE/reset] textureId=${prevTex.id()}")
                        prevTex.release()
                    }
                    cameraTexture = null
                }

                val textureEntry = binding.textureRegistry.createSurfaceTexture()
                Log.i("VanguardTex", "[CREATE] textureId=${textureEntry.id()}")
                val source = VanguardCameraSource(
                    context      = context,
                    textureEntry = textureEntry,
                    lensFacing   = lensFacing,
                    frameRate    = fps,
                )
                cameraTexture = textureEntry
                cameraSource  = source

                source.start(
                    onStarted = {
                        Log.d(TAG, "startCamera: live, textureId=${textureEntry.id()}")
                        result.success(textureEntry.id())
                    },
                    onError = { e ->
                        Log.e(TAG, "startCamera: failed — ${e.message}")
                        cameraSource = null
                        val errTex = cameraTexture
                        if (errTex != null) {
                            Log.i("VanguardTex", "[RELEASE/error] textureId=${errTex.id()}")
                            errTex.release()
                        }
                        cameraTexture = null
                        result.error("CAMERA_ERROR", e.message, null)
                    }
                )
            }

            "stopCamera" -> {
                // Idempotent: safe to call even if no camera is running.
                Log.d(TAG, "stopCamera")
                cameraSource?.stop()
                cameraSource = null
                val tex = cameraTexture
                if (tex != null) {
                    Log.i("VanguardTex", "[RELEASE] textureId=${tex.id()}")
                    tex.release()
                }
                cameraTexture = null
                result.success(null)
            }

            "switchCamera" -> {
                val src = cameraSource
                if (src == null) {
                    result.error("NO_CAMERA", "Camera not started", null)
                    return
                }
                if (src.isRecording) {
                    // Mirror iOS: reject switch while recording is active.
                    result.error("RECORDING_ACTIVE",
                        "Cannot switch camera while recording", null)
                    return
                }
                src.switchCamera(
                    onStarted = { result.success(null) },
                    onError   = { e -> result.error("CAMERA_ERROR", e.message, null) }
                )
            }

            "takePhoto" -> {
                val src = cameraSource
                if (src == null) {
                    result.error("NO_CAMERA", "Camera not started", null)
                    return
                }
                val path = args?.get("path") as? String
                if (path == null) {
                    result.error("INVALID_ARG", "takePhoto: path required", null)
                    return
                }
                src.takePhoto(
                    outputPath = path,
                    onResult   = { savedPath -> result.success(savedPath) },
                    onError    = { e -> result.error("CAPTURE_ERROR", e.message, null) }
                )
            }

            "startRecording" -> {
                val src = cameraSource
                if (src == null) {
                    result.error("NO_CAMERA", "Camera not started", null)
                    return
                }
                val path = args?.get("path") as? String
                if (path == null) {
                    result.error("INVALID_ARG", "startRecording: path required", null)
                    return
                }
                src.startRecording(
                    outputPath = path,
                    onStarted  = { result.success(null) },
                    onError    = { e -> result.error("REC_FAIL", e.message, null) }
                )
            }

            "stopRecording" -> {
                val src = cameraSource
                if (src == null) {
                    // Camera already gone — return an empty result to match iOS no-op path.
                    result.success(mapOf(
                        "filePath"      to "",
                        "droppedFrames" to 0,
                        "totalFrames"   to 0,
                        "dropRate"      to 0.0
                    ))
                    return
                }
                src.stopRecording(
                    onFinalized = { filePath, droppedFrames, totalFrames ->
                        // Mirror iOS result map shape exactly so Dart
                        // VanguardEngine.stopRecording() parses without change.
                        result.success(mapOf(
                            "filePath"      to filePath,
                            "droppedFrames" to droppedFrames,
                            "totalFrames"   to totalFrames,
                            "dropRate"      to if (totalFrames > 0)
                                droppedFrames.toDouble() / totalFrames.toDouble()
                            else 0.0
                        ))
                    },
                    onError = { e -> result.error("STOP_FAIL", e.message, null) }
                )
            }

            "isRecordingActive" -> {
                result.success(cameraSource?.isRecordingActive ?: false)
            }

            "setZoom" -> {
                // Dart sends the factor as "factor" (see vg_camera_session.dart);
                // "level" kept as a fallback for backwards compatibility.
                val factor = (args?.get("factor") as? Number)?.toFloat()
                    ?: (args?.get("level") as? Number)?.toFloat() ?: 1.0f
                cameraSource?.setZoom(factor)
                result.success(null)
            }

            "getCameraZoomCapabilities" -> {
                val src = cameraSource
                if (src == null) {
                    result.error("NO_CAMERA", "getCameraZoomCapabilities: no active camera session", null)
                    return
                }
                val caps = src.zoomCapabilities()
                if (caps == null) {
                    result.error("NO_DEVICE", "getCameraZoomCapabilities: no active capture device", null)
                    return
                }
                result.success(caps)
            }

            "setTorchMode" -> {
                // Dart passes mode as String ("on"/"off") — mirrors iOS contract.
                val mode    = args?.get("mode") as? String ?: "off"
                val enabled = mode == "on"
                cameraSource?.setTorchMode(enabled)
                result.success(null)
            }

            "setFocusPoint" -> {
                val x = (args?.get("x") as? Number)?.toFloat() ?: 0.5f
                val y = (args?.get("y") as? Number)?.toFloat() ?: 0.5f
                cameraSource?.setFocusPoint(x, y)
                result.success(null)
            }

            // ── isCameraReady: Android parity with iOS cameraSource?.isCameraReady ──
            // Backs the Dart post-startCamera readiness poll (vg_camera_session.dart).
            // Read-only — does not allocate, start, or stop any camera session.
            "isCameraReady" -> {
                result.success(cameraSource?.isCameraReady ?: false)
            }

            // -- MultiCam capability query (read-only Camera2 probe) ---------------------
            // Backed by AndroidCamera2CapabilityProbe.probe(), which only calls
            // CameraManager.getCameraIdList / getCameraCharacteristics / concurrentCameraIds.
            // Never opens a camera, never starts a capture session, does not require
            // camera permission. Android does not implement live MultiCam/Duet capture
            // in this slice; these routes only surface hardware capability data.
            "isMultiCamSupported" -> {
                val supported = try {
                    AndroidCamera2CapabilityProbe(context).probe()["supportsConcurrentCamera"] as? Boolean
                        ?: false
                } catch (t: Throwable) {
                    Log.w(TAG, "isMultiCamSupported: probe failed: ${t.javaClass.simpleName}: ${t.message}")
                    false
                }
                result.success(supported)
            }

            "getMultiCamDeviceSets" -> {
                val deviceSets = try {
                    val probeResult = AndroidCamera2CapabilityProbe(context).probe()
                    @Suppress("UNCHECKED_CAST")
                    val concurrentIdSets =
                        probeResult["concurrentCameraIdSets"] as? List<List<String>> ?: emptyList()
                    @Suppress("UNCHECKED_CAST")
                    val cameras = probeResult["cameras"] as? List<Map<String, Any?>> ?: emptyList()
                    val camerasById = cameras.associateBy { it["cameraId"] as? String }
                    concurrentIdSets
                        .filter { it.size >= 2 }
                        .map { idSet ->
                            idSet.map { cameraId ->
                                val camera = camerasById[cameraId]
                                val lensFacing = camera?.get("lensFacing") as? String ?: "unknown"
                                val isLogicalMultiCamera =
                                    camera?.get("isLogicalMultiCamera") as? Boolean ?: false
                                val deviceType = if (isLogicalMultiCamera) "logicalMultiCamera" else "camera2"
                                val localizedName = when (lensFacing) {
                                    "front" -> "Front Camera $cameraId"
                                    "back" -> "Back Camera $cameraId"
                                    else -> "Camera $cameraId"
                                }
                                mapOf(
                                    "uniqueId" to cameraId,
                                    "localizedName" to localizedName,
                                    "position" to lensFacing,
                                    "deviceType" to deviceType,
                                )
                            }
                        }
                } catch (t: Throwable) {
                    Log.w(TAG, "getMultiCamDeviceSets: probe failed: ${t.javaClass.simpleName}: ${t.message}")
                    emptyList<List<Map<String, Any?>>>()
                }
                result.success(deviceSets)
            }

            // ─── B4-S5: cancelExport ──────────────────────────────────────────────────
            // Stops the active encoder by setting its cancelled flag.
            // The encode thread will see the flag on next submitFrame() or loop iteration,
            // stop feeding input, let the decoder drain to EOS, then call encoder.finish()
            // which cleans up temp files and resolves the pending startExport Future.
            "cancelExport" -> {
                // Export Unit C / Phase 2-Unit AD: try the production coordinator
                // first. If it had an active export (exportTimeline or
                // exportPassthroughRemux), it replies EXPORT_CANCELLED to the
                // pending call itself -- cancelExport just acks immediately.
                val coordCancelled = editorExportCoordinator?.cancelActiveExport() ?: false
                if (coordCancelled) {
                    Log.i(TAG, "cancelExport: coordinator export cancellation signalled")
                    result.success(null)
                } else {
                    // Legacy startExport / VanguardMediaCodecEncoder cancel path — unchanged.
                    val enc = activeEncoder
                    if (enc != null) {
                        enc.cancel()
                        activeEncoder = null
                        Log.i(TAG, "cancelExport: cancellation signalled")
                    } else {
                        Log.d(TAG, "cancelExport: no active export")
                    }
                    result.success(null)
                }
            }

            // ─── B4-S1: extractAudio ──────────────────────────────────────────────────
            // Mirrors iOS AVAssetExportSession audio-only preset.
            // Dart sends trimEnd: double.infinity for no-trim; isFinite() guard → null.
            "extractAudio" -> {
                val videoPath  = args?.get("videoPath")  as? String
                val outputPath = args?.get("outputPath") as? String
                val trimStart  = (args?.get("trimStart") as? Number)?.toDouble() ?: 0.0
                val trimEndRaw = (args?.get("trimEnd")   as? Number)?.toDouble()
                val trimEnd    = if (trimEndRaw != null && trimEndRaw.isFinite()) trimEndRaw else null

                if (videoPath == null || outputPath == null) {
                    result.error("INVALID_ARG", "extractAudio: videoPath and outputPath required", null)
                    return
                }
                Thread {
                    try {
                        val path = VanguardAudioExtractor.extract(
                            videoPath    = videoPath,
                            outputPath   = outputPath,
                            trimStartSec = trimStart,
                            trimEndSec   = trimEnd,
                        )
                        mainHandler.post { result.success(path) }
                    } catch (e: Exception) {
                        Log.e(TAG, "extractAudio: $e")
                        mainHandler.post { result.error("EXTRACT_FAIL", e.message, null) }
                    }
                }.start()
            }

            // ─── Phase 5-Unit W / Phase 4-Unit E: extractWaveform ──────────────────────
            // Android parity with VGWaveformExtractor.m (iOS). The plugin only parses
            // args and launches a daemon thread; AndroidWaveformExtractor owns all
            // decode/validation logic and returns a synchronous result.
            "extractWaveform" -> {
                val path = args?.get("path") as? String
                val samplesPerSecond = (args?.get("samplesPerSecond") as? Number)?.toInt()
                val maxDurationSeconds = (args?.get("maxDurationSeconds") as? Number)?.toDouble()

                val fired = AtomicBoolean(false)
                fun replySuccess(map: Map<String, Any?>) {
                    if (fired.compareAndSet(false, true)) {
                        mainHandler.post { if (!detached) result.success(map) }
                    }
                }
                fun replyError(code: String, message: String?) {
                    if (fired.compareAndSet(false, true)) {
                        mainHandler.post { if (!detached) result.error(code, message, null) }
                    }
                }

                try {
                    Thread({
                        when (val outcome = AndroidWaveformExtractor.extract(path, samplesPerSecond, maxDurationSeconds)) {
                            is AndroidWaveformResult.Success -> replySuccess(
                                mapOf(
                                    "samples" to outcome.samples,
                                    "durationSeconds" to outcome.durationSeconds,
                                    "samplesPerSecond" to outcome.samplesPerSecond,
                                    "pointCount" to outcome.pointCount,
                                )
                            )
                            is AndroidWaveformResult.Failure -> replyError(outcome.code, outcome.message)
                        }
                    }, "VGWaveformExtractor").apply { isDaemon = true }.start()
                } catch (t: Throwable) {
                    Log.e(TAG, "extractWaveform: failed to start thread: $t")
                    replyError("WAVEFORM_ERROR", t.message ?: t.javaClass.simpleName)
                }
            }

            else -> result.notImplemented()
        }
    }

    // ─── B4-S4: remuxVideoWithAudio ──────────────────────────────────────────────
    //
    // 2-pass audio mux strategy:
    //   1. VanguardMediaCodecEncoder writes video-only to a temp .vtmp path.
    //   2. This function stream-copies video from temp + audio from audioPath
    //      into the final output using a fresh MediaMuxer.
    //
    // Why 2-pass instead of modifying the encoder's internal muxer:
    //   MediaMuxer requires addTrack() for ALL tracks before muxer.start().
    //   The encoder's video track format is only known after INFO_OUTPUT_FORMAT_CHANGED
    //   fires asynchronously during the first encode frame. Adding audio before
    //   that event fires is not possible without a major encoder refactor.
    //   The 2-pass approach is the minimal-risk solution: it reuses proven stream-copy
    //   code (same pattern as VanguardAudioExtractor) and leaves the encoder intact.
    //
    // Falls back gracefully: if this throws, startExport renames the temp to final
    // (video-only output) rather than crashing.
    //
    private fun remuxVideoWithAudio(videoOnlyPath: String, audioPath: String, finalPath: String) {
        val videoEx = MediaExtractor()
        val audioEx = MediaExtractor()
        try {
            videoEx.setDataSource(videoOnlyPath)
            audioEx.setDataSource(audioPath)

            // Find video track
            var videoTrack = -1
            var videoFormat: android.media.MediaFormat? = null
            for (i in 0 until videoEx.trackCount) {
                val f = videoEx.getTrackFormat(i)
                if (f.getString(android.media.MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                    videoTrack = i; videoFormat = f; break
                }
            }

            // Find audio track
            var audioTrack = -1
            var audioFormat: android.media.MediaFormat? = null
            for (i in 0 until audioEx.trackCount) {
                val f = audioEx.getTrackFormat(i)
                if (f.getString(android.media.MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    audioTrack = i; audioFormat = f; break
                }
            }

            if (videoTrack < 0 || videoFormat == null) {
                throw IllegalStateException("remuxVideoWithAudio: no video track in $videoOnlyPath")
            }

            videoEx.selectTrack(videoTrack)

            // Muxer: add video first, then audio (if present), before start()
            val muxer = android.media.MediaMuxer(finalPath, android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val muxVideoTrack = muxer.addTrack(videoFormat)
            val muxAudioTrack = if (audioTrack >= 0 && audioFormat != null) {
                audioEx.selectTrack(audioTrack)
                muxer.addTrack(audioFormat)
            } else -1
            muxer.start()

            val buf  = java.nio.ByteBuffer.allocate(1024 * 1024)  // 1MB handles any video NAL unit
            val info = android.media.MediaCodec.BufferInfo()

            // Stream-copy video
            while (true) {
                val size = videoEx.readSampleData(buf, 0)
                if (size < 0) break
                info.offset             = 0
                info.size               = size
                info.presentationTimeUs = videoEx.sampleTime
                info.flags              = videoEx.sampleFlags
                muxer.writeSampleData(muxVideoTrack, buf, info)
                videoEx.advance()
            }

            // Stream-copy audio (if available)
            if (muxAudioTrack >= 0) {
                while (true) {
                    val size = audioEx.readSampleData(buf, 0)
                    if (size < 0) break
                    info.offset             = 0
                    info.size               = size
                    info.presentationTimeUs = audioEx.sampleTime
                    info.flags              = audioEx.sampleFlags
                    muxer.writeSampleData(muxAudioTrack, buf, info)
                    audioEx.advance()
                }
            }

            muxer.stop()
            muxer.release()
            Log.i(TAG, "remuxVideoWithAudio OK → $finalPath")
        } finally {
            try { videoEx.release() } catch (_: Exception) {}
            try { audioEx.release() } catch (_: Exception) {}
        }
    }

        override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        // Phase 5-Unit W / Phase 4-Unit E: block any further extractWaveform replies.
        detached = true
        // Phase 3-Unit T: unregister the OS thermal listener before dropping the channel handler.
        thermalStateBridge?.shutdown()
        thermalStateBridge = null
        channel.setMethodCallHandler(null)
        // B2: Tear down camera session first — prevents leaked CameraX session
        // on hot-restart (Flutter re-attaches the engine to a new surface).
        cameraSource?.stop()
        cameraSource = null
        val detachTex = cameraTexture
        if (detachTex != null) {
            Log.i("VanguardTex", "[RELEASE/detach] textureId=${detachTex.id()}")
            detachTex.release()
        }
        cameraTexture = null
        // Tear down editor renderers.
        renderers.values.forEach { it.dispose() }
        renderers.clear()
        // Tear down Phase 4B1 active sessions (4B1A & 4B1B) and release their texture entries.
        dagTexturePlaybackCoordinator?.disposeAll()
        dagTexturePlaybackCoordinator = null
        // Tear down Phase 3-Unit M active camera texture smoke runs and release their producers.
        camera2TextureSmokeCoordinator?.disposeAll()
        camera2TextureSmokeCoordinator = null
        // Tear down P3-MULTICAM-NODE-SINGLE-CAM-INGEST-DESCRIPTOR-SPATIAL-RENDER active runs.
        camera2SingleCamIngestSpatialSmokeCoordinator?.disposeAll()
        camera2SingleCamIngestSpatialSmokeCoordinator = null
        // P3-MULTICAM-NODE-SINGLE-CAM-INGEST-VULKAN-SPATIAL-RENDER: cancel any
        // in-flight run. The harness owns and releases its own Camera2/Vulkan
        // resources before returning regardless of cancellation.
        camera2SingleCamIngestVulkanSpatialSmokeCoordinator?.disposeAll()
        camera2SingleCamIngestVulkanSpatialSmokeCoordinator = null
        // Tear down Phase 4C1D1 active streaming sessions.
        dagStreamingPlaybackCoordinator?.disposeAll()
        dagStreamingPlaybackCoordinator = null
        // Tear down Phase 4C3D RTC video coordinator.
        rtcVideoCoordinator = null
        // Tear down P6-MEDIA3-INGEST-STREAM-SOURCE-SEAM-A coordinator. Holds no active sessions
        // across calls (each smoke run owns and closes its own native session).
        media3StreamSourceCoordinator = null
        // Tear down Phase 7.8A-Android editor playback coordinator.
        editorPlaybackCoordinator?.disposeAll()
        editorPlaybackCoordinator = null
        // Diagnostics coordinator holds no native resources — just drop it.
        dagDiagnosticsCoordinator = null
        concurrentDecodeSmokeCoordinator = null
        passthroughRemuxSinkSmokeCoordinator = null
        audioDecodeBridgeSmokeCoordinator = null
        audioRingBufferTransportSmokeCoordinator = null
        audioClockSmokeCoordinator = null
        audioTransportCoordinatorSmokeCoordinator = null
        audioPipelineIntegrationSmokeCoordinator = null
        // Sub-slice G2b: stop replying before dropping; any in-flight decoder
        // run finishes naturally on its own thread.
        audioDecoderRingIngestSmokeCoordinator?.disposeAll()
        audioDecoderRingIngestSmokeCoordinator = null
        // Sub-slice H1: stop replying before dropping; any in-flight driver
        // run finishes naturally on its own thread and destroys its own
        // native session.
        audioGraphPipelineSmokeCoordinator?.disposeAll()
        audioGraphPipelineSmokeCoordinator = null
        // Sub-slice H2: stop replying before dropping; any in-flight real
        // decoder run finishes naturally on its own thread and destroys its
        // own native session.
        audioGraphPipelineRealDecoderSmokeCoordinator?.disposeAll()
        audioGraphPipelineRealDecoderSmokeCoordinator = null
        // Sub-slice I: trips the driver cancellation flag so an in-flight
        // sink run releases its AudioTrack and native session promptly; its
        // reply is dropped.
        audioTrackPlaybackSinkSmokeCoordinator?.disposeAll()
        audioTrackPlaybackSinkSmokeCoordinator = null
        // P4-AUDIO-MULTI-SOURCE-GRAPH-PIPELINE: trips the driver
        // cancellation flag so an in-flight two-source run releases its
        // codec/extractor and native session promptly; its reply is dropped.
        multiSourceAudioGraphPipelineSmokeCoordinator?.disposeAll()
        multiSourceAudioGraphPipelineSmokeCoordinator = null
        // Sub-slice K: trips the driver cancellation flag so an in-flight
        // multi-source sink run releases its AudioTrack, codec/extractor,
        // and native session promptly; its reply is dropped.
        multiSourceAudioTrackPlaybackSinkCoordinator?.disposeAll()
        multiSourceAudioTrackPlaybackSinkCoordinator = null
        // P4-AUDIO-MULTI-SOURCE-NODE-OWNED-PIPELINE: trips the driver
        // cancellation flag so an in-flight two-source node-owned run
        // releases its codec/extractor and native session promptly; its
        // reply is dropped.
        multiSourceNodeOwnedPipelineSmokeCoordinator?.disposeAll()
        multiSourceNodeOwnedPipelineSmokeCoordinator = null
        // P4-AUDIO-DECODER-SOURCE-NODE-WIRING: stop replying before
        // dropping; an in-flight node-owned-source run finishes naturally on
        // its own thread and destroys its own native session.
        nodeOwnedAudioSourceGraphPipelineSmokeCoordinator?.disposeAll()
        nodeOwnedAudioSourceGraphPipelineSmokeCoordinator = null
        // P4-AUDIO-REAL-DECODER-NODE-OWNED-PIPELINE: stop replying before
        // dropping; an in-flight real-decoder node-owned run finishes
        // naturally on its own thread and destroys its own native session.
        nodeOwnedAudioSourceRealDecoderSmokeCoordinator?.disposeAll()
        nodeOwnedAudioSourceRealDecoderSmokeCoordinator = null
        // P4-AUDIO-NODE-OWNED-SINK-CLOCKED-TRANSPORT: trips the driver
        // cancellation flag so an in-flight sink-clocked run releases its
        // AudioTrack, codec/extractor, and native session promptly; its
        // reply is dropped.
        nodeOwnedAudioTrackSinkClockedTransportSmokeCoordinator?.disposeAll()
        nodeOwnedAudioTrackSinkClockedTransportSmokeCoordinator = null
        // P4-AUDIO-AAUDIO-NODE-OWNED-SINK-DIAGNOSTIC: trips the driver
        // cancellation flag so an in-flight muted-AAudio-sink run releases
        // its codec/extractor and native session (stopping/closing the
        // AAudio stream on its own worker thread) promptly; its reply is
        // dropped.
        aaudioNodeOwnedSinkSmokeCoordinator?.disposeAll()
        aaudioNodeOwnedSinkSmokeCoordinator = null
        // P4-AUDIO-MIXBUS-TIMELINE-OWNERSHIP: the native route is one-shot
        // and stack-scoped (no OS resource); dispose only drops any
        // in-flight reply after detach.
        audioMixBusTimelineSmokeCoordinator?.disposeAll()
        audioMixBusTimelineSmokeCoordinator = null
        // P4-AUDIO-SCHEDULER-ENVELOPE-WIRING: the native route is one-shot
        // and stack-scoped (no OS resource); dispose only drops any
        // in-flight reply after detach.
        audioSchedulerEnvelopeSmokeCoordinator?.disposeAll()
        audioSchedulerEnvelopeSmokeCoordinator = null
        // P4-AUDIO-PASS2-GRAPH-NATIVE-SESSION: stop replying before
        // dropping; an in-flight run finishes naturally on its own worker
        // thread and destroys its own native sessions.
        audioGraphExportSessionSmokeCoordinator?.disposeAll()
        audioGraphExportSessionSmokeCoordinator = null
        // P4-AUDIO-RUNTIME-QUEUE-SCHEDULER: stop replying before dropping;
        // an in-flight run finishes naturally on its own thread and
        // destroys (stop flag + join) its own native sessions in its
        // finally block.
        asyncRuntimeQueueSchedulerSmokeCoordinator?.disposeAll()
        asyncRuntimeQueueSchedulerSmokeCoordinator = null
        // P4-AUDIO-ASYNC-RUNTIME-QUEUE-REAL-DECODER: stop replying before
        // dropping; an in-flight real-decoder run finishes naturally on its
        // own thread and destroys (stop flag + join) its own native session
        // in its finally block.
        asyncRuntimeQueueRealDecoderSmokeCoordinator?.disposeAll()
        asyncRuntimeQueueRealDecoderSmokeCoordinator = null
        // P4-AUDIO-ASYNC-RUNTIME-QUEUE-AUDIOTRACK-SINK: stop replying before
        // dropping; an in-flight sink run finishes naturally on its own
        // thread, releases its own AudioTrack, and destroys (stop flag +
        // join) its own native session in its finally block.
        asyncRuntimeQueueAudioTrackSinkSmokeCoordinator?.disposeAll()
        asyncRuntimeQueueAudioTrackSinkSmokeCoordinator = null
        // P4-AUDIO-ASYNC-RUNTIME-QUEUE-REALTIME-CLOCK-PACING: stop replying
        // before dropping; an in-flight realtime-clock run finishes
        // naturally on its own thread, releases its own AudioTrack, and
        // destroys (stop flag + join) its own native session in its
        // finally block.
        asyncRuntimeQueueRealtimeClockSmokeCoordinator?.disposeAll()
        asyncRuntimeQueueRealtimeClockSmokeCoordinator = null
        // X4: same detach-safe teardown — an in-flight multi-source
        // realtime-clock run finishes naturally on its own thread,
        // releases its own AudioTrack, and destroys (stop flag + join) its
        // own native session in its finally block.
        asyncRuntimeQueueMultiSourceRealtimeClockSmokeCoordinator?.disposeAll()
        asyncRuntimeQueueMultiSourceRealtimeClockSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-TRANSPORT-CORE (Y1): stop replying before
        // dropping; an in-flight run finishes naturally on its own thread and
        // disposes its state machine in its finally block.
        realtimePlaybackTransportCoreSmokeCoordinator?.disposeAll()
        realtimePlaybackTransportCoreSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-AUDIOTRACK-SINK (Y2): stop replying before
        // dropping; an in-flight run finishes naturally on its own thread,
        // releases its AudioTrack, and disposes its state machine in its finally block.
        realtimePlaybackAudioTrackSinkSmokeCoordinator?.disposeAll()
        realtimePlaybackAudioTrackSinkSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-INTERACTIVE-CONTROLS (Y3): stop replying before
        // dropping; an in-flight run finishes naturally on its own thread,
        // releases its AudioTrack, and disposes its state machine in its finally block.
        realtimePlaybackInteractiveControlsSmokeCoordinator?.disposeAll()
        realtimePlaybackInteractiveControlsSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-FOCUS-RESPONSE (Y4a): flip cancel and dispose
        // the active state machine only; an in-flight run fails closed on its own
        // thread and its sink finally releases the AudioTrack, unregisters the
        // noisy receiver, and abandons focus.
        realtimePlaybackFocusResponseSmokeCoordinator?.disposeAll()
        realtimePlaybackFocusResponseSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-SINK-FAULT-TOLERANCE (Y4b): flip cancel and
        // dispose the active state machine only; an in-flight run fails closed on
        // its own thread and its sink finally detaches the routing listener and
        // releases every AudioTrack instance it created.
        realtimePlaybackSinkFaultToleranceSmokeCoordinator?.disposeAll()
        realtimePlaybackSinkFaultToleranceSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-EXTERNAL-INGEST-SEAM (Y5a): stop replying
        // before dropping; an in-flight run finishes on its own thread and
        // disposes its state machine / destroys its raw session in finally.
        realtimePlaybackIngestSeamSmokeCoordinator?.disposeAll()
        realtimePlaybackIngestSeamSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER (Y5b): stop replying
        // before dropping; an in-flight run finishes on its own thread and
        // cancels/disposes its adapter in finally.
        realtimePlaybackRealDecoderSmokeCoordinator?.disposeAll()
        realtimePlaybackRealDecoderSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-INTEGRATION-A (Y6a): stop replying
        // before dropping; an in-flight run is cancelled, its decoder/sink
        // threads release MediaCodec/MediaExtractor/AudioTrack on their own
        // threads and the run thread disposes its state machine in finally.
        realtimePlaybackPipelineIntegrationSmokeCoordinator?.disposeAll()
        realtimePlaybackPipelineIntegrationSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-PAUSE-RESUME (Y6b): stop replying
        // before dropping; an in-flight run is cancelled (a parked sink thread
        // wakes on cancel), its decoder/sink threads release MediaCodec/
        // MediaExtractor/AudioTrack on their own threads and the run thread
        // disposes its state machine in finally.
        realtimePlaybackPipelinePauseResumeSmokeCoordinator?.disposeAll()
        realtimePlaybackPipelinePauseResumeSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SEEK (Y6c): stop replying before
        // dropping; an in-flight run is cancelled (a parked sink thread wakes
        // on cancel), its decoder/sink threads release MediaCodec/
        // MediaExtractor/AudioTrack on their own threads and the run thread
        // disposes its state machine in finally.
        realtimePlaybackPipelineSeekSmokeCoordinator?.disposeAll()
        realtimePlaybackPipelineSeekSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-FOCUS-RESPONSE (Y6d): stop replying
        // before dropping; an in-flight run is cancelled (a parked sink thread
        // wakes on cancel), its decoder/sink threads release MediaCodec/
        // MediaExtractor/AudioTrack on their own threads, each scenario releases
        // its focus controller (receiver unregistered, focus abandoned) in
        // finally and the run thread disposes its state machine in finally.
        realtimePlaybackPipelineFocusResponseSmokeCoordinator?.disposeAll()
        realtimePlaybackPipelineFocusResponseSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SINK-FAULT-TOLERANCE (Y6e): stop
        // replying before dropping; an in-flight run is cancelled (a parked or
        // gated sink thread wakes on cancel), its decoder/sink threads release
        // MediaCodec/MediaExtractor/AudioTrack on their own threads, the sink
        // thread releases its routing controller (listener detached) before the
        // track and the run thread disposes its state machine in finally.
        realtimePlaybackPipelineSinkFaultToleranceSmokeCoordinator?.disposeAll()
        realtimePlaybackPipelineSinkFaultToleranceSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-TIMESTAMP-STABILIZATION (Y6f): cancel
        // an in-flight run (its decoder/sink threads release MediaCodec/
        // MediaExtractor/AudioTrack on their own threads; the run thread
        // disposes its state machine in finally).
        realtimePlaybackPipelineTimestampStabilizationSmokeCoordinator?.disposeAll()
        realtimePlaybackPipelineTimestampStabilizationSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-CLOCK-SYNCHRONIZATION (Y7): cancel an
        // in-flight run (same thread-owned release shape as Y6f; the
        // presentation clock is plain Kotlin state with nothing to release).
        realtimePlaybackPipelineClockSyncSmokeCoordinator?.disposeAll()
        realtimePlaybackPipelineClockSyncSmokeCoordinator = null
        // P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK (Y8a): cancel an
        // in-flight production session without blocking (its own threads
        // release MediaCodec/MediaExtractor/AudioTrack; the smoke worker
        // disposes the session and its transport in finally).
        realtimeAudioPlaybackProductionSmokeCoordinator?.disposeAll()
        realtimeAudioPlaybackProductionSmokeCoordinator = null
        camera2ConcurrentSmokeCoordinator = null
        // P3-MULTICAM-NODE (SPATIAL-VULKAN-RENDER): release the smoke executor. An
        // in-flight run owns its VkDevice/images on its own thread and destroys
        // them in the native call before returning.
        multicamSpatialVulkanRenderSmokeCoordinator?.disposeAll()
        multicamSpatialVulkanRenderSmokeCoordinator = null
        // P3-MULTICAM-NODE-VULKAN-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER: release the
        // smoke executor. An in-flight run owns its VkDevice/images on its own
        // thread and destroys them in the native call before returning.
        multicamDynamicDescriptorSpatialVulkanRenderSmokeCoordinator?.disposeAll()
        multicamDynamicDescriptorSpatialVulkanRenderSmokeCoordinator = null
        // P5-COMPOSITOR-TRANS (NODE-TOPOLOGY-MATH): release the smoke executor.
        timelineCompositorSmokeCoordinator?.disposeAll()
        timelineCompositorSmokeCoordinator = null
        // P5-COMPOSITOR-TRANS (GLES-RENDER): release the smoke executor. An
        // in-flight run owns its EGL context/textures on its own thread and
        // tears them down in the native call before returning.
        timelineTransitionGlesRenderSmokeCoordinator?.disposeAll()
        timelineTransitionGlesRenderSmokeCoordinator = null
        // P5-OVERLAYS-TRANS (GLES-RENDER): release the smoke executor. An
        // in-flight run owns its EGL context/textures on its own thread and
        // tears them down in the native call before returning.
        timelineOverlayGlesRenderSmokeCoordinator?.disposeAll()
        timelineOverlayGlesRenderSmokeCoordinator = null
        // P5-GLES-EXPORT-OVERLAY-SEAM-A: release the smoke executor. An
        // in-flight run owns its EGL context/textures/MediaCodec on its own
        // thread and tears them down in the harness before returning.
        glesExportOverlaySeamSmokeCoordinator?.disposeAll()
        glesExportOverlaySeamSmokeCoordinator = null
        // P5-GLES-EXPORT-OVERLAY-PRODUCTION-ROUTE-A: release the smoke executor.
        glesExportOverlayProductionSmokeCoordinator?.disposeAll()
        glesExportOverlayProductionSmokeCoordinator = null
        // P5-OVERLAYS-TEXT-RASTERIZER-DIAGNOSTIC: release the smoke executor.
        timelineOverlayTextRasterizerSmokeCoordinator?.disposeAll()
        timelineOverlayTextRasterizerSmokeCoordinator = null
        // P5-BEAUTY-V2-GLES-RENDER: release the smoke executor. An in-flight
        // run owns its EGL context/textures on its own thread and tears them
        // down in the native call before returning.
        beautyV2GlesRenderSmokeCoordinator?.disposeAll()
        beautyV2GlesRenderSmokeCoordinator = null
        // P5-GLES-EXPORT-OES-2D-BEAUTY-RESOLVE-READINESS: release the smoke
        // executor. An in-flight run owns its EGL context/textures/
        // MediaCodec on its own thread and tears them down in the harness
        // before returning.
        glesExportBeautySeamSmokeCoordinator?.disposeAll()
        glesExportBeautySeamSmokeCoordinator = null
        // P5-GLES-EXPORT-DUAL-OES-TRANSITION-READINESS: release the smoke
        // executor. An in-flight run owns its EGL context/textures/dual
        // MediaCodec on its own thread and tears them down in the harness
        // before returning.
        glesDualOesTransitionSmokeCoordinator?.disposeAll()
        glesDualOesTransitionSmokeCoordinator = null
        // P5-COMPOSITOR-TRANS (VULKAN-RENDER): release the smoke executor. An
        // in-flight run owns its VkDevice/images on its own thread and destroys
        // them in the native call before returning.
        timelineTransitionVulkanRenderSmokeCoordinator?.disposeAll()
        timelineTransitionVulkanRenderSmokeCoordinator = null
        // P5-OVERLAYS-TRANS (VULKAN-RENDER): release the smoke executor. An
        // in-flight run owns its VkDevice/images on its own thread and destroys
        // them in the native call before returning.
        timelineOverlayVulkanRenderSmokeCoordinator?.disposeAll()
        timelineOverlayVulkanRenderSmokeCoordinator = null
        // P5-COMPOSITOR-TRANS (DUAL-DECODER-SYNC): release the smoke executor.
        // An in-flight run owns both MediaCodec/ImageReader pipelines and its
        // native VkDevice on its own thread and releases them in the driver's
        // finally block before the run completes.
        timelineDualDecoderSyncSmokeCoordinator?.disposeAll()
        timelineDualDecoderSyncSmokeCoordinator = null
        // P5-BEAUTY-V2-VULKAN-RENDER: release the smoke executor. An
        // in-flight run owns its VkDevice/images on its own thread and
        // destroys them in the native call before returning.
        beautyV2VulkanRenderSmokeCoordinator?.disposeAll()
        beautyV2VulkanRenderSmokeCoordinator = null
        // Export Unit C / Phase 2-Unit AD: cancel any in-flight exportTimeline
        // or exportPassthroughRemux and drop temps.
        editorExportCoordinator?.disposeAll()
        editorExportCoordinator = null
        // Tear down Phase 1-Unit AX active GLES texture smoke runs and release their producers.
        glesTextureSmokeCoordinator?.disposeAll()
        glesTextureSmokeCoordinator = null
        // Tear down Phase 5-Unit Q reverse sidecar coordinator state + executor.
        reverseSidecarCoordinator?.disposeAll()
        reverseSidecarCoordinator = null
        // Tear down Phase 5-Unit V / Phase 4-Unit D audio extraction coordinator.
        audioExtractionCoordinator?.disposeAll()
        audioExtractionCoordinator = null
        // Tear down Phase 5-Unit X / Phase 4-Unit F waveform cache coordinator.
        waveformCacheCoordinator?.disposeAll()
        waveformCacheCoordinator = null
        // Tear down Phase 5-Unit Y / Phase 4-Unit G audio playback coordinator.
        audioPlaybackCoordinator?.disposeAll()
        audioPlaybackCoordinator = null
        // Tear down Phase 5-Unit Z / UMF V2 Slice 2A photo library save coordinator.
        photoLibrarySaveCoordinator?.disposeAll()
        photoLibrarySaveCoordinator = null
        // Tear down Phase 5-Unit AB / Phase 10F-Slice 2B / UMF V2 Slice 2B video
        // asset picker coordinator -- settles any pending permission reply. Unregister
        // the permission listener first so no Activity binding is retained past
        // engine teardown.
        videoAssetPickerCoordinator?.let { coord ->
            activityBinding?.removeRequestPermissionsResultListener(coord)
        }
        activityBinding = null
        videoAssetPickerCoordinator?.disposeAll()
        videoAssetPickerCoordinator = null
        // Tear down Phase 4-Unit H / Phase 5-Unit AC audio recording coordinator.
        audioRecordingCoordinator?.disposeAll()
        audioRecordingCoordinator = null
        // Tear down Phase 5-Unit AD / Phase 10-C-3L still-image export coordinator.
        stillImageExportCoordinator?.disposeAll()
        stillImageExportCoordinator = null
        // Tear down Phase 5-Unit AE / Phase 10-C-3M image compression coordinator.
        imageCompressionCoordinator?.disposeAll()
        imageCompressionCoordinator = null
        // Phase 10-C-3N timeline live control coordinator is stateless (no native
        // resources) -- just drop the reference, no disposeAll() to call.
        timelineLiveControlCoordinator = null
        // Camera graph transaction coordinator is stateless (no native
        // resources) -- just drop the reference, no disposeAll() to call.
        cameraGraphTransactionCoordinator = null
        // Multicam preview coordinator is stateless (no native resources,
        // opens no camera) -- just drop the reference, no disposeAll() to call.
        multiCamPreviewCoordinator = null
        // CameraX thermal actuation router is a stateless dispatch shim over
        // cameraSource (already stopped/nulled above) -- just drop the
        // reference, no disposeAll() to call.
        cameraXThermalActuationRouter = null
        // VG-DUET-SLICE-2: cancel any in-flight probe and release active session.
        duetMethodHandler?.disposeAll()
        duetMethodHandler = null
    }

    // ── ActivityAware (Phase 5-Unit AB / Phase 10F-Slice 2B / UMF V2 Slice 2B) ─
    // Only videoAssetPickerCoordinator needs an Activity reference (requestPermissions /
    // shouldShowRequestPermissionRationale / startActivity for settings + the
    // limited-library re-picker). All other coordinators are Activity-agnostic.

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        val coord = videoAssetPickerCoordinator ?: return
        activityBinding = binding
        binding.addRequestPermissionsResultListener(coord)
        coord.onActivityAttached(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        val coord = videoAssetPickerCoordinator
        if (coord != null) {
            activityBinding?.removeRequestPermissionsResultListener(coord)
            coord.onActivityDetachedForConfigChanges()
        }
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        val coord = videoAssetPickerCoordinator ?: return
        binding.addRequestPermissionsResultListener(coord)
        coord.onActivityReattached(binding.activity)
    }

    override fun onDetachedFromActivity() {
        val coord = videoAssetPickerCoordinator
        if (coord != null) {
            activityBinding?.removeRequestPermissionsResultListener(coord)
            coord.onActivityDetachedFinal()
        }
        activityBinding = null
    }
}
