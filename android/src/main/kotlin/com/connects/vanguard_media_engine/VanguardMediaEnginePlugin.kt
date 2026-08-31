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
import com.connects.vanguard_media_engine.camera.AndroidCamera2ConcurrentSmokeCoordinator
import com.connects.vanguard_media_engine.camera.AndroidCamera2TextureSmokeCoordinator
import com.connects.vanguard_media_engine.camera.AndroidCameraGraphTransactionCoordinator
import com.connects.vanguard_media_engine.codec.AndroidDagTexturePlaybackCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioDecodeBridgeSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioGraphTopologySmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioGraphTransportClockSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioMixBusSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioRingBufferTransportSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioClockSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioDecoderRingWriterSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioDecoderRingIngestSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioGraphPipelineRealDecoderSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioGraphPipelineSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioPipelineIntegrationSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioTrackPlaybackSinkSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidAudioTransportCoordinatorSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidConcurrentDecodeSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidDagDiagnosticsCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidGlesTextureSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidMultiCamCompositorSmokeCoordinator
import com.connects.vanguard_media_engine.diagnostics.AndroidPassthroughRemuxSinkSmokeCoordinator
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
import com.connects.vanguard_media_engine.thermal.AndroidThermalStateBridge
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

    // ── Phase 4C1D1: DAG streaming playback coordinator ───────────────────────
    private var dagStreamingPlaybackCoordinator: AndroidDagStreamingPlaybackCoordinator? = null

    // ── Phase 4C3D: RTC video coordinator ─────────────────────────────────────
    private var rtcVideoCoordinator: AndroidRtcVideoCoordinator? = null

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

    // ── P3-MULTICAM-NODE: MultiCamCompositorNode native topology + layout ────
    // math smoke coordinator.
    private var multiCamCompositorSmokeCoordinator: AndroidMultiCamCompositorSmokeCoordinator? = null

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

    // ── ActivityAware binding (needed by videoAssetPickerCoordinator only) ────
    private var activityBinding: ActivityPluginBinding? = null

    // ── Camera session state (B2: single camera instance invariant) ───────────
    // Mirrors iOS plugin: cameraSource + renderer stored at plugin level.
    // Exactly one VanguardCameraSource may exist at a time.
    private var cameraSource: VanguardCameraSource? = null
    private var cameraTexture: TextureRegistry.SurfaceTextureEntry? = null

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
        )
        camera2TextureSmokeCoordinator = AndroidCamera2TextureSmokeCoordinator(
            context         = binding.applicationContext,
            textureRegistry = binding.textureRegistry,
            channel         = channel,
            mainHandler     = mainHandler,
        )
        dagStreamingPlaybackCoordinator = AndroidDagStreamingPlaybackCoordinator(
            context         = binding.applicationContext,
            textureRegistry = binding.textureRegistry,
            mainHandler     = mainHandler,
        )
        rtcVideoCoordinator = AndroidRtcVideoCoordinator(
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
        multiCamCompositorSmokeCoordinator = AndroidMultiCamCompositorSmokeCoordinator(
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
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        val args = call.arguments as? Map<*, *>

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
                Thread {
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(path)
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
                Thread {
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(path)
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
                val ext = path.substringAfterLast('.', "").lowercase()
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

                Thread {
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(path)

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
                            extractor.setDataSource(path)
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

                        // File size
                        val fileSizeBytes = java.io.File(path).length()

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

            // ── MultiCam capability fallback (read-only, parity with iOS routes) ────
            // Android does not implement live MultiCam/Duet capture in this slice.
            // These exist only so the Dart startup capability probe resolves instead
            // of hitting MissingPluginException; false/[] is a capability fallback,
            // not a Duet implementation.
            "isMultiCamSupported" -> {
                result.success(false)
            }

            "getMultiCamDeviceSets" -> {
                result.success(emptyList<List<Map<String, String>>>())
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
        // Tear down Phase 4C1D1 active streaming sessions.
        dagStreamingPlaybackCoordinator?.disposeAll()
        dagStreamingPlaybackCoordinator = null
        // Tear down Phase 4C3D RTC video coordinator.
        rtcVideoCoordinator = null
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
        camera2ConcurrentSmokeCoordinator = null
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
