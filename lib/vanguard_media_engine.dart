import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ffi/ffi.dart';

// P1B-09: Dart layer for the opt-in graph-runtime path.
import 'vg_playback_client.dart';
import 'vg_playback_session.dart';
import 'vg_filter_spec.dart';
// MethodChannel router — sole owner of setMethodCallHandler.
import 'src/channel/vanguard_channel_dispatcher.dart';

export 'vanguard_texture_view.dart';
export 'vanguard_media_preparer.dart';
export 'vg_filter_spec.dart';
// P4-10: expose session factory and session type for filter-chain callers.
export 'vg_playback_client.dart';
export 'vg_playback_session.dart';
// Phase 6D.1A: typed camera session + preview widget.
export 'vg_camera_session.dart';
export 'vg_camera_preview.dart';
// MC-22: Production MultiCam preview widget (composited dual-camera texture).
export 'vg_multicam_preview.dart';
// Phase 6: continuous device-aware zoom capability model.
export 'vg_camera_zoom_capabilities.dart';
// Phase 3-Unit A: Android Camera2 hardware/thermal capability probe report.
export 'vg_camera_hardware_capability_report.dart';
// Phase 3-Unit C: Android Camera2 readiness & fallback planner.
export 'vg_camera2_readiness_plan.dart';
// Phase 3-Unit E: Android Camera2 Session Configuration Eligibility Planner.
export 'vg_camera2_session_configuration_plan.dart';
// Phase 3-Unit F: Android Camera2 guarded concurrent SessionConfiguration validation.
export 'vg_camera2_concurrent_session_validation.dart';
// Phase 3-Unit H: Android Camera2 single-camera open/close lifecycle smoke foundation.
export 'vg_camera2_open_close_smoke.dart';
// Phase 3-Unit I: Android Camera2 single-camera ImageReader frame smoke foundation.
export 'vg_camera2_image_reader_frame_smoke.dart';
// Phase 3-Unit J: Android Camera2 single-camera PRIVATE ImageReader HardwareBuffer frame smoke foundation.
export 'vg_camera2_hardware_buffer_frame_smoke.dart';
// Phase 3-Unit K: Android Camera2 PRIVATE ImageReader HardwareBuffer native-render frame smoke foundation.
export 'vg_camera2_native_render_frame_smoke.dart';
// Phase 3-Unit L: Android Camera2 PRIVATE ImageReader HardwareBuffer Multi-Frame Native Render Loop Smoke Foundation.
export 'vg_camera2_native_render_loop_smoke.dart';
// Phase 3-Unit M: Android Camera2 PRIVATE ImageReader HardwareBuffer Flutter Texture Native Render Loop Smoke Foundation.
export 'vg_camera2_texture_native_render_loop_smoke.dart';
// P3-CAM-CONCURRENT: Android Camera2 dual-camera concurrent PRIVATE AHardwareBuffer ingest smoke foundation.
export 'vg_camera2_concurrent_ingest_smoke.dart';
// P3-MULTICAM-NODE: Android True-DAG MultiCamCompositorNode native topology and layout math smoke foundation.
export 'vg_multicam_compositor_smoke.dart';
// P3-MULTICAM-NODE: Android True-DAG Phase 3 GLES-first spatial multi-texture diagnostic render pass smoke foundation.
export 'vg_multicam_spatial_gles_render_smoke.dart';
// P3-MULTICAM-NODE (SPATIAL-VULKAN-RENDER): Android True-DAG Phase 3 Vulkan two-texture spatial layout render smoke foundation.
export 'vg_multicam_spatial_vulkan_render_smoke.dart';
// P4-AUDIO-MIXBUS: Android True-DAG Phase 4 AudioMixBusNode PCM16 mix-math diagnostic smoke foundation.
export 'vg_audio_mix_bus_smoke.dart';
// P4-AUDIO-GRAPH-TOPOLOGY: Android True-DAG Phase 4 AudioMixBusNode DAG topology & graph-gated diagnostic mix smoke foundation.
export 'vg_audio_graph_topology_smoke.dart';
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK: Android True-DAG Phase 4 synchronous graph-edge-routed audio window scheduler smoke foundation.
export 'vg_audio_graph_transport_clock_smoke.dart';
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice B: Android True-DAG Phase 4 native SPSC audio ring-buffer transport smoke foundation.
export 'vg_audio_ring_buffer_transport_smoke.dart';
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice C: Android True-DAG Phase 4 platform-neutral native AudioClock diagnostic smoke foundation.
export 'vg_audio_clock_smoke.dart';
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice D: Android True-DAG Phase 4 native ClockedAudioTransportCoordinator smoke foundation.
export 'vg_audio_transport_coordinator_smoke.dart';
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice E: Android True-DAG Phase 4 native AudioDecoderRingWriter smoke foundation.
export 'vg_audio_decoder_ring_writer_smoke.dart';
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice F: Android True-DAG Phase 4 native closed-loop ingest-to-transport audio graph pipeline integration smoke foundation.
export 'vg_audio_pipeline_integration_smoke.dart';
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice G3: Android True-DAG Phase 4 native audio decoder ring ingest diagnostic smoke foundation.
export 'vg_audio_decoder_ring_ingest_smoke.dart';
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice H1: Android True-DAG Phase 4 session-scoped closed-loop native audio graph pipeline smoke foundation.
export 'vg_audio_graph_pipeline_smoke.dart';
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice H2: Android True-DAG Phase 4 real MediaExtractor/MediaCodec decoder closed-loop native audio graph pipeline smoke foundation.
export 'vg_real_decoder_pipeline_smoke.dart';
// P4-AUDIO-AUDIOTRACK-OUTPUT-SINK-WRITE: Android True-DAG Phase 4 AudioTrack output sink write diagnostic smoke foundation.
export 'vg_audiotrack_output_sink_smoke.dart';
// P4-AUDIO-MULTI-SOURCE-GRAPH-PIPELINE: Android True-DAG Phase 4 multi-source closed-loop native audio graph pipeline smoke foundation.
export 'vg_multi_source_graph_pipeline_smoke.dart';
// P4-AUDIO-MULTI-SOURCE-AUDIOTRACK-SINK: Android True-DAG Phase 4 multi-source AudioTrack output sink write diagnostic smoke foundation.
export 'vg_multi_source_audio_track_sink_smoke.dart';
// P4-AUDIO-DECODER-SOURCE-NODE-WIRING: Android True-DAG Phase 4 node-owned decoded audio source graph pipeline smoke foundation.
export 'vg_node_owned_audio_source_graph_pipeline_smoke.dart';
// P4-AUDIO-REAL-DECODER-NODE-OWNED-PIPELINE: Android True-DAG Phase 4 real MediaExtractor/MediaCodec decoder node-owned audio source graph pipeline smoke foundation.
export 'vg_node_owned_real_decoder_pipeline_smoke.dart';
// P4-AUDIO-NODE-OWNED-SINK-CLOCKED-TRANSPORT: Android True-DAG Phase 4 node-owned sink-clocked transport smoke foundation.
export 'vg_node_owned_sink_clocked_transport_smoke.dart';
// P4-AUDIO-MULTI-SOURCE-NODE-OWNED-PIPELINE: Android True-DAG Phase 4 multi-source node-owned closed-loop native audio graph pipeline smoke foundation.
export 'vg_multi_source_node_owned_pipeline_smoke.dart';
// P4-AUDIO-AAUDIO-NODE-OWNED-SINK-DIAGNOSTIC: Android True-DAG Phase 4 node-owned pipeline muted native AAudio callback sink smoke foundation.
export 'vg_aaudio_node_owned_sink_smoke.dart';
// P4-AUDIO-MIXBUS-TIMELINE-OWNERSHIP: Android True-DAG Phase 4 AudioMixBusNode timeline-aware per-frame volume envelope diagnostic smoke foundation.
export 'vg_audio_mixbus_timeline_smoke.dart';
// P4-AUDIO-SCHEDULER-ENVELOPE-WIRING: Android True-DAG Phase 4 GraphAudioScheduler per-source static-gain/envelope wiring diagnostic smoke foundation.
export 'vg_audio_scheduler_envelope_smoke.dart';
// P4-AUDIO-PASS2-GRAPH-NATIVE-SESSION: Android True-DAG Phase 4 N-source node-owned ring audio graph export session diagnostic smoke foundation.
export 'vg_audio_graph_export_session_smoke.dart';
// P4-AUDIO-RUNTIME-QUEUE-SCHEDULER: Android True-DAG Phase 4 diagnostic async runtime queue/backpressure scheduler integration smoke foundation.
export 'vg_async_runtime_queue_scheduler_smoke.dart';
// P4-AUDIO-ASYNC-RUNTIME-QUEUE-REAL-DECODER (sub-slice X1): Android True-DAG Phase 4 real MediaExtractor/MediaCodec decoder to async runtime queue scheduler smoke foundation.
export 'vg_async_runtime_queue_real_decoder_smoke.dart';
// P4-AUDIO-ASYNC-RUNTIME-QUEUE-AUDIOTRACK-SINK (sub-slice X2): Android True-DAG Phase 4 async runtime queue output ring to Kotlin-owned muted AudioTrack sink smoke foundation.
export 'vg_async_runtime_queue_audiotrack_sink_smoke.dart';
// P4-AUDIO-ASYNC-RUNTIME-QUEUE-REALTIME-CLOCK-PACING (sub-slice X3): Android True-DAG Phase 4 async runtime queue native worker-owned steady_clock realtime pacing smoke foundation.
export 'vg_async_runtime_queue_realtime_clock_smoke.dart';
// P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-REALTIME-CLOCK (sub-slice X4): Android True-DAG Phase 4 async runtime queue two-source node-owned worker-owned steady_clock realtime pacing smoke foundation.
export 'vg_async_runtime_queue_multi_source_realtime_clock_smoke.dart';
// P4-AUDIO-REALTIME-PLAYBACK-TRANSPORT-CORE (Y1): Android True-DAG Phase 4 realtime playback transport core diagnostic smoke foundation.
export 'vg_realtime_playback_transport_core_smoke.dart';
// P4-AUDIO-REALTIME-PLAYBACK-AUDIOTRACK-SINK (Y2): Android True-DAG Phase 4 realtime playback AudioTrack sink diagnostic smoke foundation.
export 'vg_realtime_playback_audiotrack_sink_smoke.dart';
// P4-AUDIO-REALTIME-PLAYBACK-INTERACTIVE-CONTROLS (Y3): Android True-DAG Phase 4 realtime playback interactive transport controls diagnostic smoke foundation.
export 'vg_realtime_playback_interactive_controls_smoke.dart';
// P4-AUDIO-REALTIME-PLAYBACK-FOCUS-RESPONSE (Y4a): Android True-DAG Phase 4 realtime playback audio focus and becoming noisy response diagnostic smoke foundation.
export 'vg_realtime_playback_focus_response_smoke.dart';
// P4-AUDIO-REALTIME-PLAYBACK-SINK-FAULT-TOLERANCE (Y4b): Android True-DAG Phase 4 realtime playback AudioTrack sink fault tolerance diagnostic smoke foundation.
export 'vg_realtime_playback_sink_fault_tolerance_smoke.dart';
// P4-AUDIO-REALTIME-PLAYBACK-EXTERNAL-INGEST-SEAM (Y5a): Android True-DAG Phase 4 realtime playback external PCM16 ingest seam diagnostic smoke foundation.
export 'vg_realtime_playback_ingest_seam_smoke.dart';
// P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER (Y5b): Android True-DAG Phase 4 realtime playback real MediaExtractor/MediaCodec PCM16 decode to external ingest seam diagnostic smoke foundation.
export 'vg_realtime_playback_real_decoder_smoke.dart';
// P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-INTEGRATION-A (Y6a): Android True-DAG Phase 4 realtime playback pipeline integration diagnostic smoke foundation.
export 'vg_realtime_playback_pipeline_integration_smoke.dart';
// Phase 3-Unit U: Android Camera2 Mid-Recording Thermal Load-Shedding Policy & Mitigation Planner.
export 'vg_camera2_thermal_load_shedding_policy.dart';
// Phase 3-Unit V: Android Camera2 Thermal Load-Shedding Monitor & Telemetry Coordinator Foundation.
export 'vg_camera2_thermal_load_shedding_monitor.dart';

// Phase 6D.3: typed recording result.
export 'vg_recording_stats.dart';
// Phase 6D.4: typed photo capture result.
export 'vg_photo_capture_result.dart';
// Phase 6C.1A: product-control descriptor schema (pure value objects).
export 'vg_parameter_descriptor.dart';
export 'vg_effect_catalog.dart';
export 'vg_preset_descriptor.dart';
// Phase 6C.1B: Dart-only graph transaction engine.
export 'vg_graph_transaction.dart';
// Phase 7 Stage 7.1: non-destructive timeline descriptor models (pure data).
export 'vg_clip_descriptor.dart';
export 'vg_transition_descriptor.dart';
// Phase 7.22A: time remap descriptor foundation (descriptor-only; no rendering).
export 'vg_time_remap_descriptor.dart';
// Phase 7.11: per-clip spatial transform + opacity descriptor.
export 'vg_clip_transform_descriptor.dart';
// Phase 7.23: keyframe transform track foundation (descriptor + interpolation math; no rendering).
export 'vg_transform_keyframe_descriptor.dart';
// Phase 7.x-A: Dual-Camera Editor Consumption Descriptor Foundation.
export 'vg_dual_camera_descriptor.dart';
// MC-1B: Live dual-camera preview layout config (pure Dart; no clip/session semantics).
export 'vg_live_preview_config.dart';
// MC-2: Typed MultiCam device-set models and Dart selection policy.
export 'vg_multicam_device_set.dart';
// Phase 7 Stage 7.7: formal editor draft recipe and controller API.
export 'vg_editor_draft.dart';
export 'vg_editor_value.dart';
export 'vg_editor_controller.dart';
export 'vg_editor_export_request.dart';
export 'vg_editor_export_result.dart';
// Phase 7.8C: public editor texture presentation view widget.
export 'vg_editor_texture_view.dart';
// Phase 7.8D: public editor preview readiness evaluator.
export 'vg_editor_preview_readiness.dart';
// Phase 5-Unit J: public editor export readiness evaluator.
export 'vg_editor_export_readiness.dart';
// Phase 2-Unit W: public passthrough remux preflight evaluator.
export 'vg_passthrough_remux_evaluator.dart';
// Phase 2-Unit AA: public Android passthrough remux capability client.
export 'vg_passthrough_remux_capability_client.dart';
// Phase 2-Unit AB: public passthrough remux decision planner.
export 'vg_passthrough_remux_decision.dart';
export 'vg_editor_export_admission.dart';
// Phase 2-Unit AE: public Android passthrough remux execution client.
export 'vg_passthrough_remux_client.dart';
// Phase 2-Unit AF: public admission-driven export execution client.
export 'vg_editor_admission_export_client.dart';
// Audio Slice M: recording result models.
export 'vg_audio_recording_models.dart';
// Phase 8: canvas and overlay descriptors
export 'vg_canvas_descriptor.dart';
export 'vg_overlay_descriptor.dart';
// Phase 8.14A: audio sidecar export muxer descriptor.
export 'vg_audio_sidecar_plan.dart';
// Phase 8.15B: offline audio ducking engine.
export 'vg_audio_ducking_engine.dart';
// Phase 8.15C: native offline audio waveform extraction.
export 'vg_waveform_extractor.dart';
// Phase 8.16: standalone AVPlayer-backed audio playback service.
export 'vg_audio_playback_service.dart';
// Phase 8.17: disk-backed waveform result cache.
export 'vg_waveform_cache.dart';
// Phase 7.20D: Dart model for reverse sidecar asset state.
export 'vg_reverse_sidecar_status.dart';
// Phase 10-C: one-shot headless timeline export API (no controller, no texture).
export 'vg_timeline_exporter.dart';
// Phase 10-C: shared media-stack image optimizer (UMF/Vanguard owned; no FFmpeg).
export 'vg_image_optimizer.dart';
// Phase 10-C Slice T: managed, cancellable iOS audio extraction service.
export 'src/audio_extraction/vg_audio_extraction_service.dart';
// ROI Signal / Server-Ready Sidecar Dart Models (ROI-1A)
export 'src/roi/vg_roi_models.dart';
export 'src/roi/vg_roi_coordinate_converter.dart';
export 'src/roi/vg_roi_transform_mapper.dart';
// ROI-4A: Export-space sidecar mapper (capture → export_output_normalized)
export 'src/roi/vg_roi_export_mapper.dart';
// ROI-5E.1: In-memory single-sample imported ROI sidecar builder
export 'src/roi/vg_imported_roi_sidecar_builder.dart';
// P5-ANIM-ROI: Pure-Dart animated / keyframed ROI sidecar builder
export 'src/roi/vg_roi_keyframe_sidecar_builder.dart';
// Audio Track Interaction S-P1: timeline-scoped live filter-chain control.
export 'vg_timeline_live_controls.dart';
// V-B1/V-B2: per-track live mix-gain control (no updateDraft call).
export 'vg_timeline_audio_mix_controls.dart';
// Phase 4C6E: public package-level streaming cache/prewarm API surface (Android-backed).
export 'vg_streaming_cache_client.dart';
// Phase 4C6K: public streaming cache prewarm request planner.
export 'vg_streaming_cache_prewarm_plan.dart';
// Phase 4C6R: public streaming cache prewarm priority/eviction planner.
export 'vg_streaming_cache_priority_planner.dart';
// Phase 4C7B: public package-level adaptive streaming playback API client.
export 'vg_streaming_playback_client.dart';
// Phase 4C7E: public streaming preflight advisory API client.
export 'vg_streaming_preflight_client.dart';
// Phase 4C7G: public streaming startup plan helper.
export 'vg_streaming_startup_plan.dart';
// Phase 4C7I: public streaming source descriptor & source set.
export 'vg_streaming_source_descriptor.dart';
// Phase 4C7K: public streaming source selector.
export 'vg_streaming_source_selector.dart';
// Phase 4C7M: public streaming playback decision planner.
export 'vg_streaming_playback_decision.dart';
// Phase 4C7O: public streaming playback controller facade.
export 'vg_streaming_playback_controller.dart';
// Phase 4C7Q: public streaming playback texture view widget.
export 'vg_streaming_playback_view.dart';
// Phase 4C7AA: public streaming playback status summary helper.
export 'vg_streaming_playback_status_summary.dart';
// Phase 4C7AC: public streaming playback status poller.
export 'vg_streaming_playback_status_poller.dart';
// Phase 4C7AI: public streaming playback health advisor.
export 'vg_streaming_playback_health_advisor.dart';
// Phase 4C7AK: public streaming playback recovery planner.
export 'vg_streaming_playback_recovery_plan.dart';
// Phase 4C7AM: public streaming playback resilience monitor.
export 'vg_streaming_playback_resilience_monitor.dart';
// Phase 4C7AQ: public streaming playback retry budget planner.
export 'vg_streaming_playback_retry_budget.dart';
// Phase 4C7AS: public streaming playback retry journal.
export 'vg_streaming_playback_retry_journal.dart';
// Phase 4C7AU: public streaming playback resilience decision planner.
export 'vg_streaming_playback_resilience_decision.dart';
// Phase 4C7AW: public streaming playback resilience coordinator.
export 'vg_streaming_playback_resilience_coordinator.dart';
// Phase 4C7BC: public streaming playback resilience evaluation binder.
export 'vg_streaming_playback_resilience_binder.dart';
// Phase 4C7BD: public streaming playback route planner.
export 'vg_streaming_playback_route_plan.dart';
// Phase 4C7BE: public streaming offline asset eligibility planner.
export 'vg_streaming_offline_asset_eligibility.dart';
// Phase 4C7BF: public streaming offline asset acquisition request planner.
export 'vg_streaming_offline_asset_acquisition_plan.dart';
// Phase 4C7BG: public streaming offline playback preparation planner.
export 'vg_streaming_offline_playback_preparation_plan.dart';
// Phase 4C7BH: public streaming offline asset lifecycle status model.
export 'vg_streaming_offline_asset_lifecycle.dart';
// Phase 4C7BI: public streaming offline asset MethodChannel client contract.
export 'vg_streaming_offline_asset_client.dart';
// Phase 4C7BJ: public streaming offline asset status poller.
export 'vg_streaming_offline_asset_status_poller.dart';
// Phase 4C7BK: public streaming offline asset lifecycle monitor.
export 'vg_streaming_offline_asset_lifecycle_monitor.dart';
// Phase 4C3V: public RTC video diagnostics client.
export 'vg_rtc_video_diagnostics_client.dart';
// Phase 4C4J: public adaptive stream timeline diagnostics client.
export 'vg_streaming_timeline_diagnostics_client.dart';
// Phase 4C5H: public streaming manifest policy validation client.
export 'vg_streaming_manifest_policy_client.dart';
// Phase 4C5J: public streaming codec capability client.
export 'vg_streaming_codec_capability_client.dart';
// Phase 4C5L: public streaming manifest rendition diagnostics client.
export 'vg_streaming_manifest_rendition_client.dart';
// Phase 4C5N: public streaming compatibility decision client.
export 'vg_streaming_compatibility_decision_client.dart';
// Phase 4C5P: public streaming preflight composite evaluator.
export 'vg_streaming_preflight_composite_evaluator.dart';

const String _libName = 'vanguard_media_engine';

/// The dynamic library in which the symbols for [VanguardMediaEngineBindings] can be found.
final DynamicLibrary _dylib = () {
  if (Platform.isIOS) {
    // On iOS, the C++ code is statically linked into the Runner binary by CocoaPods.
    // DynamicLibrary.process() searches all symbols already loaded in the process.
    return DynamicLibrary.process();
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open('$_libName.framework/$_libName');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}();

// ─────────────────────────────────────────────────────────────────────────────
// FFI Typedefs
// ─────────────────────────────────────────────────────────────────────────────

typedef _c_engine_create = Pointer<Void> Function(Int32 mode);
typedef _EngineCreate = Pointer<Void> Function(int mode);

typedef _c_engine_destroy = Void Function(Pointer<Void> engine);
typedef _EngineDestroy = void Function(Pointer<Void> engine);

typedef _c_add_video_node =
    Void Function(
      Pointer<Void> engine,
      Pointer<Utf8> path,
      Double startTime,
      Int32 layerId,
    );
typedef _AddVideoNode =
    void Function(
      Pointer<Void> engine,
      Pointer<Utf8> path,
      double startTime,
      int layerId,
    );

typedef _c_add_bitmap_overlay =
    Void Function(
      Pointer<Void> engine,
      Pointer<Utf8> id,
      Double startTime,
      Double duration,
      Int32 layerId,
    );
typedef _AddBitmapOverlay =
    void Function(
      Pointer<Void> engine,
      Pointer<Utf8> id,
      double startTime,
      double duration,
      int layerId,
    );

typedef _c_add_audio_node =
    Void Function(Pointer<Void> engine, Pointer<Utf8> path, Double startTime);
typedef _AddAudioNode =
    void Function(Pointer<Void> engine, Pointer<Utf8> path, double startTime);

typedef _c_set_node_duration =
    Void Function(Pointer<Void> engine, Pointer<Utf8> path, Double duration);
typedef _SetNodeDuration =
    void Function(Pointer<Void> engine, Pointer<Utf8> path, double duration);

typedef _c_set_playhead = Void Function(Pointer<Void> engine, Double timeSec);
typedef _SetPlayhead = void Function(Pointer<Void> engine, double timeSec);

typedef _c_get_duration = Double Function(Pointer<Void> engine);
typedef _GetDuration = double Function(Pointer<Void> engine);

// T10: Error introspection — check after any FFI call on Android to detect silent failures.
typedef _c_last_error = Int32 Function(Pointer<Void> unused);
typedef _LastError = int Function(Pointer<Void> unused);

class _VanguardFFI {
  static final _EngineCreate create = _dylib
      .lookupFunction<_c_engine_create, _EngineCreate>(
        'vanguard_engine_create',
      );
  static final _EngineDestroy destroy = _dylib
      .lookupFunction<_c_engine_destroy, _EngineDestroy>(
        'vanguard_engine_destroy',
      );
  static final _AddVideoNode addVideoNode = _dylib
      .lookupFunction<_c_add_video_node, _AddVideoNode>(
        'vanguard_engine_add_video_node',
      );
  static final _AddBitmapOverlay addBitmapOverlay = _dylib
      .lookupFunction<_c_add_bitmap_overlay, _AddBitmapOverlay>(
        'vanguard_engine_add_bitmap_overlay',
      );
  static final _AddAudioNode addAudioNode = _dylib
      .lookupFunction<_c_add_audio_node, _AddAudioNode>(
        'vanguard_engine_add_audio_node',
      );
  static final _SetNodeDuration setNodeDuration = _dylib
      .lookupFunction<_c_set_node_duration, _SetNodeDuration>(
        'vanguard_engine_set_node_duration',
      );
  static final _SetPlayhead setPlayhead = _dylib
      .lookupFunction<_c_set_playhead, _SetPlayhead>(
        'vanguard_engine_set_playhead',
      );
  static final _GetDuration getDuration = _dylib
      .lookupFunction<_c_get_duration, _GetDuration>(
        'vanguard_engine_get_duration',
      );
  static final _LastError lastError = _dylib
      .lookupFunction<_c_last_error, _LastError>('vanguard_engine_last_error');
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Phase 10 Slice 10A — Thermal Guard
// ─────────────────────────────────────────────────────────────────────────────

/// Dart representation of the native ProcessInfo.ThermalState.
///
/// Raw values mirror iOS ProcessInfo.ThermalState.rawValue:
///   nominal = 0, fair = 1, serious = 2, critical = 3
///
/// Received via the `onThermalStateChanged` MethodChannel callback
/// and by querying `getThermalState`.
enum VGThermalState {
  /// No thermal issues. All capabilities enabled.
  nominal,

  /// Slight thermal load. All capabilities still enabled.
  fair,

  /// Elevated thermal load. Vanguard natively reduces GPU/ML load.
  /// Dart/product: show warning; export may be slower.
  serious,

  /// Critical thermal load. Vanguard natively disables Metal filter chain.
  /// Dart/product: block new export/camera/record start.
  critical;

  /// Converts a native rawValue (0–3) to [VGThermalState].
  /// Returns [nominal] for any unrecognised value (defensive).
  static VGThermalState fromRaw(int raw) {
    return switch (raw) {
      1 => VGThermalState.fair,
      2 => VGThermalState.serious,
      3 => VGThermalState.critical,
      _ => VGThermalState.nominal,
    };
  }
}

/// Static thermal state monitor for the Vanguard media engine.
///
/// Receives `onThermalStateChanged` callbacks via [VanguardChannelDispatcher].
/// Self-registers lazily on first use.
///
/// ## Usage
///
/// ```dart
/// // Listen to changes:
/// VGThermalMonitor.onThermalStateChanged.listen((state) { ... });
///
/// // Query current state:
/// final state = await VGThermalMonitor.getThermalState();
///
/// // Simulate in debug builds only:
/// await VGThermalMonitor.simulateThermalState(VGThermalState.critical);
/// ```
final class VGThermalMonitor {
  // Private constructor: static-only API.
  const VGThermalMonitor._();

  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');

  // Internal mutable state.
  static VGThermalState _currentState = VGThermalState.nominal;
  static final StreamController<VGThermalState> _stateController =
      StreamController<VGThermalState>.broadcast();

  // Dispatcher self-registration state.
  // Once registered, the subscription lives for the isolate lifetime.
  static bool _dispatcherRegistered = false;
  // ignore: unused_field — held to prevent GC of the subscription token
  static VGThermalSubscription? _thermalSubscription;

  /// The most recently observed thermal state.
  static VGThermalState get currentState => _currentState;

  /// Broadcast stream of thermal state transitions.
  ///
  /// Emits every time the native `onThermalStateChanged` callback fires.
  /// Obtain an initial value via [getThermalState] and then subscribe here
  /// for subsequent changes.
  static Stream<VGThermalState> get onThermalStateChanged {
    _ensureDispatcherRegistered();
    return _stateController.stream;
  }

  /// Queries the current native thermal state from the device.
  ///
  /// Updates [currentState] and returns the result. Safe to call at any time.
  static Future<VGThermalState> getThermalState() async {
    _ensureDispatcherRegistered();
    final raw = await _channel.invokeMethod<int>('getThermalState') ?? 0;
    final state = VGThermalState.fromRaw(raw);
    _currentState = state;
    return state;
  }

  /// Debug-only: simulate a thermal state transition without reaching real thermal load.
  ///
  /// Calls the native `simulateThermalState` route (compiled out in release builds)
  /// which invokes `notifyThermalStateChanged` on the plugin, causing the normal
  /// `onThermalStateChanged` callback path to fire.
  ///
  /// Safe to call in debug builds only. In release this method is a no-op.
  static Future<void> simulateThermalState(VGThermalState state) async {
    if (!kDebugMode) return;
    await _channel.invokeMethod<void>('simulateThermalState', {
      'rawValue': state.index,
    });
  }

  /// Lazily self-registers with [VanguardChannelDispatcher].
  ///
  /// The closure captures [_onNativeStateChanged] from within this library,
  /// so the library-private method is accessible. Registration is permanent
  /// for the isolate lifetime — thermal events require no engine instance.
  static void _ensureDispatcherRegistered() {
    if (_dispatcherRegistered) return;
    _dispatcherRegistered = true;
    _thermalSubscription = VanguardChannelDispatcher.instance
        .registerThermalStateListener(
          (rawValue) => _onNativeStateChanged(rawValue),
        );
  }

  /// Internal: updates current state and emits the stream event.
  ///
  /// Called via the dispatcher closure; not a public method.
  static void _onNativeStateChanged(int rawValue) {
    final state = VGThermalState.fromRaw(rawValue);
    _currentState = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Original Public API continues below
// ─────────────────────────────────────────────────────────────────────────────

enum VanguardMode { nleOffline, livestream }

class VanguardEngine {
  // G-01: Hot-reload protection.
  // In debug mode, a static reference to the last-created instance is kept.
  // When a new VanguardEngine is constructed (which happens on hot-reload because
  // widget init runs again), the previous instance is disposed before creating
  // a new one. This prevents C++ engine leaks and orphaned texture IDs.
  // In release builds kDebugMode = false so this path is compiled out entirely.
  static VanguardEngine? _devInstance;

  late final Pointer<Void> _enginePtr;
  final MethodChannel _channel = const MethodChannel('vanguard_media_engine');

  // Guards against double-dispose. Both dispose() and _disposeSync() check
  // this flag and no-op early if already called. Critical for integration tests
  // where T2's factory constructor would otherwise call _disposeSync() on a
  // T1 engine whose await dispose() has already run (use-after-free crash).
  bool _disposed = false;

  // Dispatcher subscription tokens. Stored so we can unregister on dispose.
  VGPlaybackCompleteSubscription? _playbackCompleteSub;
  VGDurationProbedSubscription? _durationProbedSub;
  VGExportSubscription? _exportProgressSub;

  // ── Camera API — static so no C++ engine is allocated for camera use ─────────
  // Camera operations use the same native method channel as the engine but do
  // NOT require a Vanguard timeline engine. Using a static channel avoids the
  // _devInstance hot-reload dispose side-effect and C++ FFI allocation.
  static const _cameraChannel = MethodChannel('vanguard_media_engine');

  // Tracks textureId → videoPath to allow management of multiple renderers
  final Map<int, String> _activeRenderers = {};

  // P1B-09: Tracks textureId → VGPlaybackSession for the opt-in graph-runtime path.
  // Populated in createVideoTexture; cleared in disposeTexture and dispose().
  // Keys always mirror _activeRenderers so both maps stay in sync.
  final Map<int, VGPlaybackSession> _sessions = {};

  // P4-10: Narrow public accessor so playground/filter callers can retrieve
  // the session for an active textureId without exposing the full map.
  // Returns null if the textureId was created via the legacy path or camera.
  VGPlaybackSession? sessionForTexture(int textureId) => _sessions[textureId];

  /// Optional callbacks from the UI
  void Function(String path, double duration)? onNodeDurationProbed;
  void Function(int textureId)? onPlaybackComplete;
  void Function(double progress)? onExportProgress;

  // G-01: Factory constructor enables hot-reload protection without changing
  // the public API call site. In release builds this is identical to a plain
  // constructor (kDebugMode is a compile-time constant = false).
  factory VanguardEngine({VanguardMode mode = VanguardMode.nleOffline}) {
    if (kDebugMode && _devInstance != null) {
      // Hot-reload detected: dispose the previous C++ engine synchronously.
      // This cannot be truly awaited in a factory, but dispose() can be called
      // eagerly to release native resources before the next instance is created.
      // The Dart GC may finalize the old instance later, but native destruction
      // happens now via the sync portion of dispose().
      _devInstance!._disposeSync();
    }
    final instance = VanguardEngine._internal(mode);
    if (kDebugMode) _devInstance = instance;
    return instance;
  }

  /// Creates a test instance that bypasses native FFI library loading.
  @visibleForTesting
  factory VanguardEngine.forTesting() => VanguardEngine._forTesting();

  VanguardEngine._forTesting() : _enginePtr = nullptr;

  VanguardEngine._internal(VanguardMode mode) {
    _enginePtr = _VanguardFFI.create(mode.index);
    // Register dispatcher subscriptions (dispatcher owns the channel handler).
    final dispatcher = VanguardChannelDispatcher.instance;
    dispatcher.ensureHandlerRegistered();
    _playbackCompleteSub = dispatcher.registerPlaybackCompleteListener((
      textureId,
    ) {
      if (_disposed) return;
      // Guard: only forward if this engine owns the texture.
      if (_activeRenderers.containsKey(textureId)) {
        onPlaybackComplete?.call(textureId);
      }
    });
    _durationProbedSub = dispatcher.registerDurationProbedListener((
      String path,
      double duration,
    ) {
      if (_disposed) return;
      // Update C++ TimelineManager with the probed duration.
      final pathPtr = path.toNativeUtf8();
      _VanguardFFI.setNodeDuration(_enginePtr, pathPtr, duration);
      calloc.free(pathPtr);
      onNodeDurationProbed?.call(path, duration);
    });
    // Export progress: forward to the UI callback. VanguardChannelDispatcher
    // stores export listeners as a LIFO stack, not a single slot: if
    // VanguardTimelineExporter concurrently registers its own listener for a
    // headless export, its registration temporarily takes over
    // onExportProgress delivery while running, and this registration
    // resumes receiving events once the exporter's finally block
    // unregisters -- it is never clobbered.
    _exportProgressSub = dispatcher.registerExportListener((double progress) {
      if (_disposed) return;
      onExportProgress?.call(progress);
    });
  }

  /// Synchronous native teardown — called during hot-reload when a new instance
  /// is being created before the old one's async dispose() completes.
  /// Does NOT await channel calls (fire-and-forget to avoid deadlock in factory).
  void _disposeSync() {
    if (_disposed) return; // already fully disposed by await dispose() — skip
    _disposed = true;
    // Unregister dispatcher subscriptions before destroying the engine pointer.
    // This ensures late callbacks after destruction are dropped by the dispatcher.
    final dispatcher = VanguardChannelDispatcher.instance;
    if (_playbackCompleteSub != null) {
      dispatcher.unregisterPlaybackCompleteListener(_playbackCompleteSub!);
      _playbackCompleteSub = null;
    }
    if (_durationProbedSub != null) {
      dispatcher.unregisterDurationProbedListener(_durationProbedSub!);
      _durationProbedSub = null;
    }
    if (_exportProgressSub != null) {
      dispatcher.unregisterExportListener(_exportProgressSub!);
      _exportProgressSub = null;
    }
    for (final id in _activeRenderers.keys) {
      _channel.invokeMethod('dispose', {'textureId': id}); // fire-and-forget
    }
    _activeRenderers.clear();
    _VanguardFFI.destroy(_enginePtr);
  }

  /// T10: Reads the last error code from the C++ layer.
  /// Returns 0 on success, non-zero on error.
  /// Useful after FFI calls on Android to detect silent OOM or null-arg failures.
  int get lastNativeError => _VanguardFFI.lastError(_enginePtr);

  /// G-02: Returns the current masterClock position in seconds from the native engine.
  /// Used by the A/V sync integration test to measure audio-vs-wall-clock drift.
  /// In production this is not called per-frame — only for testing and diagnostics.
  ///
  /// Phase 2 Step 7: pass [textureId] to route through the registry runtime for
  /// that specific session. Omit (or pass null) to use the renderer fallback
  /// (pre-Phase-2 behaviour — valid for legacy callers and camera/export paths).
  Future<double> getMasterClockSeconds({int? textureId}) async {
    final args = textureId != null ? {'textureId': textureId} : null;
    final seconds = await _channel.invokeMethod<double>('getMasterClock', args);
    return seconds ?? 0.0;
  }

  /// G-02-T3: Native-backed settle for post-seek stabilisation (test-only).
  ///
  /// Sleeps [ms] milliseconds on a native background thread and delivers
  /// result() when done.  More reliable than [Future.delayed] for the
  /// post-seek settle window because the Dart event loop can enter a degraded
  /// state after 50+ rapid MethodChannel calls.  The native bg-thread sleep
  /// has zero Dart event-loop dependency and zero iOS main-RunLoop interaction
  /// during the wait; result() is delivered at T+ms when the RunLoop is clear.
  Future<void> settleMs(int ms) async {
    await _channel.invokeMethod<void>('settleMs', {'ms': ms});
  }

  /// G-02-T3: Suppress all AVAssetImageGenerator activity (test-only).
  ///
  /// Call BEFORE a seek storm (while the iOS main thread is idle) to prevent
  /// any internal AVFoundation XPC dispatch from blocking the main thread
  /// during the critical settle / measurement window.  Suppression has zero
  /// effect on masterClock, audio, or playback frame delivery.
  Future<void> pauseSeekPreviews() async {
    await _channel.invokeMethod<void>('pauseSeekPreviews');
  }

  /// G-02-T3: Restore seek-preview generation after a paused window (test-only).
  Future<void> resumeSeekPreviews() async {
    await _channel.invokeMethod<void>('resumeSeekPreviews');
  }

  /// Creates a native GPU texture for a video file and registers it with Flutter.
  /// Returns a record with [textureId], [width], and [height] (the actual display
  /// dimensions of the video after applying preferredTransform).
  /// Use [textureId] with [VanguardTextureView] and pass [width]/[height] to it
  /// so the preview container sizes correctly for both portrait and landscape video.
  Future<({int textureId, int width, int height})> createVideoTexture(
    String path, {
    required double startTime,
    int layerId = 0,
  }) async {
    // P1B-09: Route through VGPlaybackClient which normalises both the legacy
    // Map return and the new graph-runtime Map return into a VGPlaybackSession.
    // _activeRenderers is still populated for dispose() and hot-reload safety.
    //
    // Width/height: VGPlaybackClient.createSession() calls `createTexture` and
    // returns both a parsed VGPlaybackSession and the raw map via a record so
    // we can extract dimensions without a second channel call.
    final (session: session, raw: rawMap) =
        await VGPlaybackClient.createSessionRaw(path);

    // Register node in C++ timeline — moved after await so the synchronous
    // FFI call does not freeze the Dart isolate before createSessionRaw can
    // complete. (Experiment: confirms addVideoNode was the isolate-blocking cause.)
    addVideoNode(path, startTime: startTime, layerId: layerId);
    final id = session.textureId;
    if (id < 0) {
      throw Exception('[Vanguard] Failed to create texture for: $path');
    }
    _activeRenderers[id] = path;
    _sessions[id] = session;

    final w = (rawMap?['width'] as num?)?.toInt() ?? 1080;
    final h = (rawMap?['height'] as num?)?.toInt() ?? 1920;
    return (textureId: id, width: w, height: h);
  }

  Future<void> play(int textureId) async {
    // P1B-09: Delegate to session if one exists; fall back to raw channel call
    // so callers that bypassed VGPlaybackClient (e.g. camera renderer IDs) still
    // work identically to before.
    final session = _sessions[textureId];
    if (session != null) {
      await session.play();
    } else {
      await _channel.invokeMethod('play', {'textureId': textureId});
    }
  }

  Future<void> pause(int textureId) async {
    // P1B-09: Delegate to session if one exists.
    final session = _sessions[textureId];
    if (session != null) {
      await session.pause();
    } else {
      await _channel.invokeMethod('pause', {'textureId': textureId});
    }
  }

  Future<void> seekTo(int textureId, double seconds) async {
    setPlayhead(seconds);
    // P1B-09: Delegate to session if one exists.
    final session = _sessions[textureId];
    if (session != null) {
      await session.seekTo(seconds);
    } else {
      await _channel.invokeMethod('seekTo', {
        'textureId': textureId,
        'seconds': seconds,
      });
    }
  }

  Future<void> disposeTexture(int textureId) async {
    // P1B-09: Delegate to session if one exists; disposes native resources and
    // marks the session as disposed (idempotent guard on VGPlaybackSession).
    final session = _sessions.remove(textureId);
    if (session != null) {
      await session.dispose();
    } else {
      await _channel.invokeMethod('dispose', {'textureId': textureId});
    }
    _activeRenderers.remove(textureId);
  }

  // ─────────────────────────────────────────────────────────────────────
  // Camera API (Phase 1–3) — static: no VanguardEngine instance required
  // ─────────────────────────────────────────────────────────────────────

  /// Starts the native camera session and registers a GPU preview texture.
  /// Returns the Flutter textureId. Display it with [Texture(textureId: id)].
  ///
  /// [position]: 1 = back (default), 2 = front.
  /// [fps]: target frame rate (30 recommended for all devices).
  ///
  /// The _videoCallback is wired to the renderer BEFORE the capture session
  /// starts, eliminating any callback-arrival-before-wire race.
  static Future<int> startCamera({int position = 1, int fps = 30}) async {
    final id = await _cameraChannel.invokeMethod<int>('startCamera', {
      'position': position,
      'fps': fps,
    });
    if (id == null || id < 0) {
      throw StateError('[Vanguard] startCamera: native returned no texture id');
    }
    return id;
  }

  /// Stops the camera session and unregisters the preview texture.
  /// Call in the widget's dispose() or on back-navigation.
  static Future<void> stopCamera() async {
    await _cameraChannel.invokeMethod<void>('stopCamera');
  }

  /// Sets the active camera filter chain.
  ///
  /// Requires VG_USE_CAMERA_GRAPH=1.
  /// Empty list clears filters (swaps back to passthrough).
  /// Current step may return UNSUPPORTED_CAMERA_FILTER_RESOURCE_CONTRACT if no safe no-pool filter exists.
  ///
  /// PlatformException codes:
  /// - 'GRAPH_MODE_DISABLED' if camera graph mode is disabled.
  /// - 'NO_CAMERA_GRAPH' if the camera graph session is not running.
  /// - 'BAD_ARGS' if filters parameters are malformed.
  /// - 'UNKNOWN_FILTER' if the filter type is unrecognized.
  /// - 'UNSUPPORTED_CAMERA_FILTER_RESOURCE_CONTRACT' if a filter cannot be safely constructed without a resource/dimension contract.
  static Future<void> setCameraFilterChain(List<VGFilterSpec> filters) async {
    await _cameraChannel.invokeMethod<void>('setCameraFilterChain', {
      'filters': filters.map((f) => f.toJson()).toList(),
    });
  }

  /// Swaps to the given sensor without tearing down the session (~150 ms).
  /// The texture id returned by [startCamera] remains valid — no widget rebuild.
  ///
  /// [position]: 1 = back, 2 = front.
  ///
  /// Throws [PlatformException] with code 'RECORDING_ACTIVE' if called while
  /// a recording is active. Guard by disabling the button in recording state.
  static Future<void> switchCamera({int position = 1}) async {
    await _cameraChannel.invokeMethod<void>('switchCamera', {
      'position': position,
    });
  }

  /// Sets zoom level. 1.0 = no zoom; clamped to device max on native side.
  /// Throttle callers to ≤30 Hz from pinch gesture handlers:
  ///   onScaleUpdate: (d) { if (/* 33ms elapsed */) VanguardEngine.setZoom(d.scale * base); }
  static Future<void> setZoom(double factor) async {
    await _cameraChannel.invokeMethod<void>('setZoom', {'factor': factor});
  }

  /// Tap-to-focus and tap-to-expose. [x] and [y] are normalised (0.0–1.0).
  /// Map a tap's local offset on the Texture widget:
  ///   x = tapOffset.dx / textureWidth, y = tapOffset.dy / textureHeight.
  static Future<void> setFocusPoint(double x, double y) async {
    await _cameraChannel.invokeMethod<void>('setFocusPoint', {'x': x, 'y': y});
  }

  /// Toggles the continuous video torch. [mode]: 'on' | 'off'.
  /// Named setTorchMode — this controls the video torch, not the photo flash.
  /// No-op on devices without a torch (most front cameras, simulator).
  static Future<void> setTorchMode(String mode) async {
    await _cameraChannel.invokeMethod<void>('setTorchMode', {'mode': mode});
  }

  /// Captures the current live camera frame as a JPEG and writes it to [path].
  ///
  /// [path] must be a writable absolute path with a .jpg extension.
  /// Safe to call while a video recording is active — does not affect the
  /// ongoing AVAssetWriter write.
  ///
  /// Returns the absolute path of the written file on success.
  ///
  /// [captureMode] is an optional hint controlling which native pipeline is
  /// used on iOS. See [VGCameraSession.takePhoto] for accepted values.
  ///
  /// Throws [PlatformException] with one of:
  ///   'NO_FRAME'    — camera started but no frame delivered yet (~100ms window)
  ///   'SWITCHING'   — a camera switch is in progress (~150ms window)
  ///   'ENCODE_FAIL' — JPEG encoding or disk write failed
  ///   'NO_CAMERA'   — startCamera was not called
  static Future<String> takePhoto(String path, {String? captureMode}) async {
    final filePath = await _cameraChannel.invokeMethod<String>('takePhoto', {
      'path': path,
      if (captureMode != null) 'captureMode': captureMode,
    });
    if (filePath == null) {
      throw PlatformException(
        code: 'ENCODE_FAIL',
        message: 'takePhoto returned null path',
      );
    }
    return filePath;
  }

  /// Loads a local image file (JPEG / PNG / HEIC / WebP) into the Vanguard GPU
  /// pipeline and returns a [textureId] for display via [VanguardTextureView].
  ///
  /// [path] must be a readable absolute path to an existing image file.
  ///
  /// The image is decoded to a [CVPixelBuffer] and held in the renderer's
  /// [_latestPixelBuffer]. It is re-fired on every [seek] call (the image
  /// source re-fires its single frame rather than advancing). All
  /// [VanguardFilterNode] filters (LUT, beauty, ML segmentation) are active
  /// on the image frame — identical behaviour to a video frame.
  ///
  /// Obeys the max-1-renderer rule: any existing texture (video or image) is
  /// disposed before this one is created.
  ///
  /// Throws [PlatformException] with:
  ///   'INVALID_ARG'    — path argument missing
  ///   'FILE_NOT_FOUND' — file does not exist at the given path
  static Future<int> createImageTexture(String path) async {
    // Native returns {"textureId": N, "width": W, "height": H} — a Map, not a
    // bare int. Unpack it the same way createVideoTexture does.
    final rawMap = await _cameraChannel.invokeMethod<Map<Object?, Object?>>(
      'createImageTexture',
      {'path': path},
    );
    final textureId = (rawMap?['textureId'] as num?)?.toInt();
    if (textureId == null || textureId < 0) {
      throw PlatformException(
        code: 'ENCODE_FAIL',
        message: 'createImageTexture returned null or invalid textureId',
      );
    }
    return textureId;
  }

  // ─────────────────────────────────────────────────────────────────────
  // Recording API (Phase 4) — also static (camera-mode only, no C++ engine)
  // ─────────────────────────────────────────────────────────────────────

  /// Begins video recording to [path]. Must be called after [startCamera].
  /// [path] must be a writable local path with a .mp4 extension.
  static Future<void> startRecording(String path) async {
    await _cameraChannel.invokeMethod<void>('startRecording', {'path': path});
  }

  /// Stops recording and finalises the MP4.
  /// Returns a map with keys:
  ///   'filePath'     (String)  — the completed file
  ///   'droppedFrames' (int)    — frames the hardware dropped
  ///   'totalFrames'  (int)     — total frames presented
  ///   'dropRate'     (double)  — droppedFrames / totalFrames
  static Future<Map<String, dynamic>> stopRecording() async {
    final raw = await _cameraChannel.invokeMethod<Map>('stopRecording');
    return Map<String, dynamic>.from(raw ?? {});
  }

  /// Exports the timeline as a single .mp4 using hardware encoding.
  ///
  /// - [clips]: ordered list of clip specs with path + trim range
  /// - [outputPath]: destination .mp4 path
  /// - [audioPath]: optional external audio track (mp3/m4a) to mix in
  /// - [audioStart]: trim start within the audio track (seconds)
  /// - [bitrate]: target video bitrate in bps (default: 4,000,000)
  /// - [maxSeconds]: hard duration cap (default: 30s)
  ///
  /// Each clip map must contain: { 'path', 'trimStart', 'trimEnd' }.
  /// Progress events fire [onExportProgress] (0.0 → 1.0).
  /// Returns the output file path on success.
  Future<String> startExport({
    required List<Map<String, dynamic>> clips,
    required String outputPath,
    String? audioPath,
    double audioStart = 0.0,
    int bitrate = 4000000,
    double maxSeconds = 30.0,
  }) async {
    final result = await _channel.invokeMethod<Map>('startExport', {
      'clips': clips,
      'outputPath': outputPath,
      'audioPath': audioPath,
      'audioStart': audioStart,
      'bitrate': bitrate,
      'maxSeconds': maxSeconds,
    });
    final success = result?['success'] as bool? ?? false;
    if (!success) throw Exception('[Vanguard] Export failed for: $outputPath');
    return result!['outputPath'] as String;
  }

  /// Cancels any in-progress export. The [startExport] Future will resolve
  /// with a FlutterError rather than hanging indefinitely.
  Future<void> cancelExport() async {
    await _channel.invokeMethod('cancelExport');
  }

  /// Extracts the audio track from a video file to a .m4a file.
  /// Uses AVFoundation — no FFmpeg required.
  ///
  /// - [videoPath]: source video (mp4/mov/any AVFoundation-supported)
  /// - [outputPath]: destination .m4a path
  /// - [trimStart] / [trimEnd]: optional time range within the source audio
  ///
  /// Returns the path to the extracted .m4a file.
  Future<String> extractAudio({
    required String videoPath,
    required String outputPath,
    double trimStart = 0.0,
    double? trimEnd,
  }) async {
    final result = await _channel.invokeMethod<String>('extractAudio', {
      'videoPath': videoPath,
      'outputPath': outputPath,
      'trimStart': trimStart,
      'trimEnd': trimEnd ?? double.infinity,
    });
    if (result == null)
      throw Exception('[Vanguard] Audio extraction failed for: $videoPath');
    return result;
  }

  /// Probes the native duration of a video file using AVURLAsset.
  ///
  /// Uses a lightweight native AVURLAsset.duration read — no renderer, no
  /// decoder pipeline, no FFmpeg. Safe to call for any local video path.
  ///
  /// Returns the duration in seconds, or `null` if the asset cannot be loaded
  /// (e.g. missing file, unrecognised codec — caller should fall back).
  ///
  /// This replaces `VideoPlayerController.file` as the I-5-compliant duration
  /// probing path. (Phase A2-S1 validation fix.)
  static Future<double?> probeVideoDuration(String videoPath) async {
    final result = await _cameraChannel.invokeMethod<double>(
      'probeVideoDuration',
      {'path': videoPath},
    );
    if (result == null || result < 0) return null;
    return result;
  }

  /// Returns duration + pixel dimensions for a video file — native replacement
  /// for FFmpegKit metadata probes in [story_export_service.dart].
  ///
  /// Returns a map with keys:
  ///   `duration` — seconds as double, or -1.0 on failure
  ///   `width`    — pixel width as int (0 on failure)
  ///   `height`   — pixel height as int (0 on failure)
  ///
  /// Does NOT call FFmpegKit. Uses MediaMetadataRetriever (Android) and
  /// AVURLAsset / AVAssetTrack.naturalSize (iOS).
  static Future<Map<String, dynamic>?> probeVideoInfo(String videoPath) async {
    final raw = await _cameraChannel.invokeMethod<Map>('probeVideoInfo', {
      'path': videoPath,
    });
    if (raw == null) return null;
    return {
      'duration': (raw['duration'] as num?)?.toDouble() ?? -1.0,
      'width': (raw['width'] as num?)?.toInt() ?? 0,
      'height': (raw['height'] as num?)?.toInt() ?? 0,
    };
  }

  /// Exposes native still-image export session.
  static Future<Map<String, dynamic>> exportImage({
    required String sourcePath,
    required String outputPath,
    String format = 'jpeg',
    double quality = 0.92,
    List<Map<String, dynamic>> filters = const [],
    String orientationPolicy = 'preserve',
  }) async {
    final result = await _cameraChannel.invokeMethod<Map>('exportImage', {
      'sourcePath': sourcePath,
      'outputPath': outputPath,
      'format': format,
      'quality': quality,
      'filters': filters,
      'orientationPolicy': orientationPolicy,
    });
    return Map<String, dynamic>.from(result ?? {});
  }

  /// Phase 3A: iOS-native static-image-to-video exporter.
  ///
  /// Converts a PNG image + audio source to a [durationSeconds] MP4.
  /// Uses AVAssetWriter + CVPixelBuffer frame pump on iOS — no FFmpegKit.
  ///
  /// - [imagePath]:         Local path to source PNG
  /// - [audioPath]:         Local path to audio source (.m4a / .mp3 / .wav)
  /// - [audioStartSeconds]: Seek offset into audio source (default 0)
  /// - [outputPath]:        Destination MP4 path (must be writable)
  /// - [durationSeconds]:   Target output duration (default 15.0)
  ///
  /// Returns the output file path on success, or null on failure.
  ///
  /// Platform: iOS only. Use StoryExportService._flattenImageToVideoFFmpeg on Android.
  static Future<String?> flattenImageToVideo({
    required String imagePath,
    required String audioPath,
    double audioStartSeconds = 0.0,
    required String outputPath,
    double durationSeconds = 15.0,
  }) async {
    final raw = await _cameraChannel.invokeMethod<Map>('flattenImageToVideo', {
      'imagePath': imagePath,
      'audioPath': audioPath,
      'audioStartSeconds': audioStartSeconds,
      'outputPath': outputPath,
      'durationSeconds': durationSeconds,
    });
    if (raw?['success'] == true) {
      return raw!['outputPath'] as String?;
    }
    return null;
  }

  /// Phase 3B: iOS-native flattenVideo — PNG overlay + optional audio mix.
  ///
  /// Composites a full-frame PNG (rendered text stickers / filters) over a
  /// video clip and optionally mixes in external music.
  ///
  /// - [videoPath]:         Source video path
  /// - [overlayPNGPath]:    Full-frame overlay PNG file
  /// - [audioPath]:         Optional music file. If null, video audio passes through.
  /// - [audioStartSeconds]: Seek offset into external audio (default 0)
  /// - [outputPath]:        Destination MP4 path
  /// - [durationSeconds]:   Target output duration (default 15.0)
  ///
  /// Returns the output file path on success, or null on failure.
  ///
  /// Platform: iOS only. Use StoryExportService._flattenVideoFFmpeg on Android.
  static Future<String?> flattenVideo({
    required String videoPath,
    required String overlayPNGPath,
    String? audioPath,
    double audioStartSeconds = 0.0,
    required String outputPath,
    double durationSeconds = 15.0,
  }) async {
    final raw = await _cameraChannel.invokeMethod<Map>('flattenVideo', {
      'videoPath': videoPath,
      'overlayPNGPath': overlayPNGPath,
      'audioPath': audioPath,
      'audioStartSeconds': audioStartSeconds,
      'outputPath': outputPath,
      'durationSeconds': durationSeconds,
    });
    if (raw?['success'] == true) {
      return raw!['outputPath'] as String?;
    }
    return null;
  }

  /// Phase 3C: iOS-native compositeDualCamera — back cam fullscreen + front cam PiP
  /// with rounded corners and fill-mode scale.
  ///
  /// Composites [backPath] (full-frame background, downscaled from 4K) +
  /// [frontPath] (bottom-right PiP, 35% width, 24px corner radius).
  ///
  /// All PiP geometry is computed natively from AVAssetTrack — no geometry
  /// arguments in the method channel. Dart passes only file paths.
  ///
  /// Audio: back camera audio only (front mic discarded — matches FFmpeg -map 0:a?).
  /// Duration: min(back, front) clip length, capped at 15s.
  ///
  /// Returns the output file path on success, or null on failure.
  ///
  /// Platform: iOS only. Use StoryExportService._compositeDualCameraFFmpeg on Android.
  static Future<String?> compositeDualCamera({
    required String backPath,
    required String frontPath,
    required String outputPath,
  }) async {
    final raw = await _cameraChannel.invokeMethod<Map>('compositeDualCamera', {
      'backPath': backPath,
      'frontPath': frontPath,
      'outputPath': outputPath,
    });
    if (raw?['success'] == true) {
      return raw!['outputPath'] as String?;
    }
    return null;
  }

  /// Generates evenly-spaced JPEG thumbnail frames from a video.
  ///
  /// Static route that uses the camera method channel without allocating a C++
  /// timeline engine or causing hot-reload engine teardown.
  ///
  /// When [maxWidth], [maxHeight], and [jpegQuality] are omitted, platforms
  /// preserve their historical defaults (iOS limits to 120x214 with 0.6 quality
  /// for filmstrips; Android preserves unconstrained frame dimensions and quality 72).
  /// Pass explicit dimensions and quality (e.g. 640x640, 0.82) for high-resolution
  /// gallery thumbnails across all platforms.
  static Future<List<Uint8List>> extractThumbnails({
    required String videoPath,
    required int count,
    required double duration,
    int? maxWidth,
    int? maxHeight,
    double? jpegQuality,
  }) async {
    final args = <String, dynamic>{
      'videoPath': videoPath,
      'count': count,
      'duration': duration,
    };
    if (maxWidth != null) args['maxWidth'] = maxWidth;
    if (maxHeight != null) args['maxHeight'] = maxHeight;
    if (jpegQuality != null) args['jpegQuality'] = jpegQuality;

    final result = await _cameraChannel.invokeMethod<List>(
      'generateThumbnails',
      args,
    );
    if (result == null) return [];
    return result.whereType<Uint8List>().toList();
  }

  /// Generates evenly-spaced JPEG thumbnail frames from a video for the filmstrip UI.
  ///
  /// - [videoPath]: source video
  /// - [count]: number of thumbnails to generate (typically 8–10 per clip)
  /// - [duration]: native duration of the clip in seconds
  /// - [maxWidth]: optional max width constraint
  /// - [maxHeight]: optional max height constraint
  /// - [jpegQuality]: optional JPEG compression quality (0.0 to 1.0)
  ///
  /// Returns a list of JPEG bytes for each thumbnail.
  Future<List<Uint8List>> generateThumbnails({
    required String videoPath,
    required int count,
    required double duration,
    int? maxWidth,
    int? maxHeight,
    double? jpegQuality,
  }) {
    return extractThumbnails(
      videoPath: videoPath,
      count: count,
      duration: duration,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      jpegQuality: jpegQuality,
    );
  }

  /// UMF V2 Slice 2A: Saves a local video file (.mp4, .mov, .m4v) to the platform
  /// photo library (iOS Photos / PHPhotoLibrary; Android MediaStore / Gallery).
  ///
  /// - [filePath]: absolute POSIX path to the local video file.
  /// - [channel]: optional [MethodChannel] override for unit testing.
  ///
  /// Returns `true` on success.
  /// Throws [PlatformException] on native permission denial, PhotoKit failure
  /// (iOS), or MediaStore/legacy-storage failure (Android — saved under
  /// Movies/ConnectsApp via MediaStore on API 29+, or a scoped legacy fallback
  /// on API 24-28).
  static Future<bool> saveVideoToPhotoLibrary(
    String filePath, {
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _cameraChannel;
    final result = await ch.invokeMethod<bool>('saveVideoToPhotoLibrary', {
      'filePath': filePath,
    });
    return result ?? false;
  }

  // ── C++ Timeline API ──────────────────────────────────────────────────────

  void addVideoNode(String path, {required double startTime, int layerId = 0}) {
    final ptr = path.toNativeUtf8();
    _VanguardFFI.addVideoNode(_enginePtr, ptr, startTime, layerId);
    calloc.free(ptr);
  }

  void addBitmapOverlay(
    String overlayId, {
    required double startTime,
    required double duration,
    int layerId = 10,
  }) {
    final ptr = overlayId.toNativeUtf8();
    _VanguardFFI.addBitmapOverlay(
      _enginePtr,
      ptr,
      startTime,
      duration,
      layerId,
    );
    calloc.free(ptr);
  }

  void addAudioNode(String path, {required double startTime}) {
    final ptr = path.toNativeUtf8();
    _VanguardFFI.addAudioNode(_enginePtr, ptr, startTime);
    calloc.free(ptr);
  }

  void setPlayhead(double timeSec) {
    _VanguardFFI.setPlayhead(_enginePtr, timeSec);
  }

  double get duration => _VanguardFFI.getDuration(_enginePtr);

  /// T4: dispose() is now async and awaits each 'dispose' channel call.
  /// Previously it fire-and-forgot the channel calls, meaning the native texture
  /// could be unregistered AFTER vanguard_engine_destroy() ran, causing
  /// a use-after-free in VanguardMediaEnginePlugin.renderers[textureId].
  Future<void> dispose() async {
    if (_disposed) return; // idempotent — guard against double-dispose
    _disposed = true;
    // Clear _devInstance NOW — before awaiting — so that if T2's factory
    // constructor runs during our await, it won't call _disposeSync() on us.
    if (kDebugMode) _devInstance = null;
    // Unregister dispatcher subscriptions before destroying the engine pointer.
    // This ensures late callbacks after destruction are dropped by the dispatcher.
    final dispatcher = VanguardChannelDispatcher.instance;
    if (_playbackCompleteSub != null) {
      dispatcher.unregisterPlaybackCompleteListener(_playbackCompleteSub!);
      _playbackCompleteSub = null;
    }
    if (_durationProbedSub != null) {
      dispatcher.unregisterDurationProbedListener(_durationProbedSub!);
      _durationProbedSub = null;
    }
    if (_exportProgressSub != null) {
      dispatcher.unregisterExportListener(_exportProgressSub!);
      _exportProgressSub = null;
    }
    final ids = List<int>.from(_activeRenderers.keys);
    for (final id in ids) {
      // Await each call — ensures the native renderer is fully disposed
      // (CADisplayLink invalidated, CVPixelBufferPool released, texture unregistered)
      // before we destroy the C++ engine.
      await _channel.invokeMethod('dispose', {'textureId': id});
    }
    _activeRenderers.clear();
    _VanguardFFI.destroy(_enginePtr);
  }
}
