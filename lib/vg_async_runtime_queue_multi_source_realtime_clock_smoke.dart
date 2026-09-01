// vg_async_runtime_queue_multi_source_realtime_clock_smoke.dart
// vanguard_media_engine -
// P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-REALTIME-CLOCK: Android
// True-DAG Phase 4 async runtime queue native worker-owned steady_clock
// realtime pacing over the TWO-SOURCE node-owned topology diagnostic smoke
// foundation (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice X4).
//
// Pure Dart typed model + invocation wrapper over the native
// `runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke` MethodChannel route.
// Diagnostic-only: validates that one real Android MediaExtractor/MediaCodec
// decoded track plus one Kotlin-synthetic PCM track feed two NODE-OWNED
// source rings in lockstep, that the native async runtime queue worker (the
// sole reader of std::chrono::steady_clock for render dispatch) jointly
// mixes them through the GraphAudioScheduler/AudioMixBusNode at unit gain,
// and that the mixed output ring drains into a Kotlin-owned MUTED
// AudioTrack MODE_STREAM write-accounting sink. No control command carries
// a caller-supplied time value; Kotlin never dispatches; playback head /
// AudioTimestamp / underrun facts are telemetry only.
//
// Honest non-claims (Kotlin driver Proof Boundary):
// kotlin_owned_audiotrack_sink_on_async_runtime_queue_multi_source_realtime_wall_clock_pacing_proof_only_real_decoder_plus_synthetic_track_to_async_runtime_queue_scheduler_output_ring_to_muted_audiotrack_mode_stream_sink_write_accounting_native_worker_owned_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_kotlin_owned_mediacodec_mediaextractor_and_audiotrack_lifecycle_synthetic_pcm_track_kotlin_owned_write_non_blocking_only_playback_head_and_audio_timestamp_telemetry_only_two_routed_tracks_unit_gain_lockstep_ingest_source_rings_spsc_output_ring_spsc_full_window_dispatch_only_window_aligned_expected_frame_count_no_joint_tail_flush_no_partial_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_synthetic_generator_reanchored_at_accepted_frame_axis_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_no_audible_output_no_speaker_route_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_dead_object_recovery_no_aaudio_no_opensl_no_oboe_no_latency_glitch_avsync_claim_no_zero_underrun_claim_no_realtime_priority_claim_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport {
  const VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.nativeProofBoundary,
    required this.failureReason,
    required this.details,
    required this.formatProbeOk,
    required this.decoderEosReachedOk,
    required this.realtimeWorkerClockOwnershipOk,
    required this.noCallerSuppliedNativeTimeOk,
    required this.noOwnerThreadDispatchOk,
    required this.controlCommandSerializationOk,
    required this.multiSourceRealDecoderIngestOk,
    required this.trackFrameAxisLockstepOk,
    required this.twoTrackContributionOk,
    required this.referenceMixChecksumOk,
    required this.checksumIdentityOk,
    required this.frameAccountingOk,
    required this.sinkWriteAccountingOk,
    required this.providerPoisoningOk,
    required this.audioTrackInitOk,
    required this.mutedOutputOk,
    required this.playbackHeadTelemetryOk,
    required this.realtimeNativeElapsedOk,
    required this.realtimeBacklogBoundOk,
    required this.seekEpochReanchorOk,
    required this.seekSinkEpochResetOk,
    required this.syntheticGeneratorReanchorOk,
    required this.workerJoinOnDestroyOk,
    required this.idempotentDestroyOk,
    required this.canonicalProofBoundaryOk,
    required this.ownerThreadAffinityOk,
    required this.sampleRate,
    required this.channelCount,
    required this.pcmEncoding,
    required this.expectedFrames,
    required this.preSeekFrames,
    required this.postSeekFrames,
    required this.seekTargetFrame,
    required this.sourceRingCapacityFrames,
    required this.outputRingCapacityFrames,
    required this.maxFramesPerMix,
    required this.preStartFillFrames,
    required this.generatorReanchorCount,
    required this.nativeRealtimeElapsedMs,
    required this.nativeTimingF0,
    required this.nativeTimingF1,
    required this.maxRenderCursorBacklogUs,
    required this.backlogSampleCount,
    required this.workerNoFramesDueWaits,
    required this.backpressureCountTelemetry,
    required this.totalFramesExtracted,
    required this.totalFramesAcceptedTrack0,
    required this.totalFramesAcceptedTrack1,
    required this.totalFramesRendered,
    required this.totalFramesPushed,
    required this.totalOutputFramesRead,
    required this.framesReadFromRing,
    required this.framesWrittenToSink,
    required this.residualFramesAtEnd,
    required this.framesDiscardedInSinkAtSeek,
    required this.playbackHeadDeltaTelemetryOnly,
    required this.underrunDeltaTelemetryOnly,
    required this.commandsEnqueued,
    required this.commandsProcessed,
    required this.commandErrors,
    required this.dispatchCount,
    required this.silenceCount,
    required this.providerTrack0ZeroFilledFrames,
    required this.providerTrack1ZeroFilledFrames,
    required this.providerTrack0UnderrunEvents,
    required this.providerTrack1UnderrunEvents,
    required this.providerTrack0ForwardSkipFrames,
    required this.providerTrack1ForwardSkipFrames,
    required this.providerTrack0RewindRejects,
    required this.providerTrack1RewindRejects,
    required this.workerThreadDistinct,
    required this.ownerDispatchCalls,
    required this.kotlinTrack0AcceptedChecksumHex,
    required this.nativeAcceptedChecksumTrack0Hex,
    required this.kotlinTrack1AcceptedChecksumHex,
    required this.nativeAcceptedChecksumTrack1Hex,
    required this.kotlinReferenceMixChecksumHex,
    required this.nativeOutputReadChecksumHex,
    required this.kotlinSinkWriteChecksumHex,
    required this.lanes,
    required this.metrics,
    required this.raw,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_REALTIME_CLOCK_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_REALTIME_CLOCK_SMOKE_FAIL';

  /// Canonical pass marker emitted by the native harness for
  /// envelope-enabled (X5 dynamic-gain-envelope) runs; default (X4
  /// unit-gain) runs keep [passMarkerConstant].
  static const String dynamicGainEnvelopePassMarkerConstant =
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_DYNAMIC_GAIN_ENVELOPE_SMOKE_PASS';

  /// Canonical fail marker emitted by the native harness for
  /// envelope-enabled (X5 dynamic-gain-envelope) runs.
  static const String dynamicGainEnvelopeFailMarkerConstant =
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_DYNAMIC_GAIN_ENVELOPE_SMOKE_FAIL';

  /// Canonical Kotlin driver proof boundary string (muted AudioTrack sink
  /// claim included) emitted by the native harness.
  static const String proofBoundaryConstant =
      'kotlin_owned_audiotrack_sink_on_async_runtime_queue_multi_source_realtime_wall_clock_pacing_proof_only_real_decoder_plus_synthetic_track_to_async_runtime_queue_scheduler_output_ring_to_muted_audiotrack_mode_stream_sink_write_accounting_native_worker_owned_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_kotlin_owned_mediacodec_mediaextractor_and_audiotrack_lifecycle_synthetic_pcm_track_kotlin_owned_write_non_blocking_only_playback_head_and_audio_timestamp_telemetry_only_two_routed_tracks_unit_gain_lockstep_ingest_source_rings_spsc_output_ring_spsc_full_window_dispatch_only_window_aligned_expected_frame_count_no_joint_tail_flush_no_partial_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_synthetic_generator_reanchored_at_accepted_frame_axis_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_no_audible_output_no_speaker_route_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_dead_object_recovery_no_aaudio_no_opensl_no_oboe_no_latency_glitch_avsync_claim_no_zero_underrun_claim_no_realtime_priority_claim_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes';

  /// Canonical native TU proof boundary string (NO native sink claim)
  /// observed via the snapshot and echoed by the harness.
  static const String nativeProofBoundaryConstant =
      'diagnostic_async_runtime_queue_multi_source_realtime_clock_native_worker_proof_only_real_decoder_plus_synthetic_track_node_owned_source_rings_to_graph_scheduler_audio_mix_bus_to_output_ring_worker_owned_std_chrono_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_on_any_control_command_two_routed_tracks_unit_gain_lockstep_source_rings_spsc_output_ring_spsc_full_window_dispatch_only_window_aligned_expected_frame_count_no_joint_tail_flush_no_partial_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_synthetic_generator_reanchored_at_accepted_frame_axis_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_native_audio_sink_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_audible_output_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_zero_underrun_claim_no_realtime_priority_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes';

  /// Frozen pre-start (and post-seek) lockstep source fill quota in frames,
  /// applied to min(acceptedFramesTrack0, acceptedFramesTrack1).
  static const int preStartFillQuotaFrames = 4096;

  /// Native realtime elapsed gate window, milliseconds (inclusive).
  static const int realtimeElapsedMinMs = 980;

  /// Native realtime elapsed gate window, milliseconds (inclusive).
  static const int realtimeElapsedMaxMs = 1350;

  /// Native render-cursor backlog bound, microseconds (exclusive).
  static const int backlogBoundUs = 250000;

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// Status string (e.g. 'pass', 'fail', or fail-closed reason token).
  final String status;

  /// Diagnostic marker string.
  final String marker;

  /// Kotlin driver proof boundary string (muted AudioTrack sink claim).
  final String proofBoundary;

  /// Native TU proof boundary string observed via the snapshot (no native
  /// sink claim).
  final String nativeProofBoundary;

  /// Failure reason token, if any.
  final String failureReason;

  /// Auxiliary execution details or trace breadcrumbs.
  final String details;

  // ---- Lanes --------------------------------------------------------------

  /// Whether the decoder output format resolved to PCM16 with 1-2 channels
  /// and a valid sample rate before the realtime session was created.
  final bool formatProbeOk;

  /// Whether the post-seek decode ran the codec out to a real output EOS.
  final bool decoderEosReachedOk;

  /// Whether the native worker thread was distinct, owned the monotonic
  /// steady_clock timebase, performed every dispatch over the two routed
  /// node-owned tracks, and finished with zero anomalies.
  final bool realtimeWorkerClockOwnershipOk;

  /// Whether the native snapshot carried the structural token proving no
  /// entry point accepts a caller-supplied time value.
  final bool noCallerSuppliedNativeTimeOk;

  /// Whether the owner thread performed zero dispatch calls.
  final bool noOwnerThreadDispatchOk;

  /// Whether both control commands (start/seek) were queue-serialized and
  /// executed in order with zero command errors.
  final bool controlCommandSerializationOk;

  /// Whether the real decoder supplied the whole track-0 timeline, the
  /// synthetic track-1 was non-silent, and the lockstep pre-start fill
  /// quota was met on min(accepted0, accepted1) before start.
  final bool multiSourceRealDecoderIngestOk;

  /// Whether both native accepted totals and the Kotlin reference cursor
  /// stayed in lockstep on the shared accepted-frame axis.
  final bool trackFrameAxisLockstepOk;

  /// Whether the mix checksum differed from both single-track checksums
  /// with a non-silent synthetic track (two-track contribution).
  final bool twoTrackContributionOk;

  /// Whether kotlinReferenceMix == nativeOutputRead == kotlinSinkWrite for
  /// the clamp16(s0 + s1) reference mix model.
  final bool referenceMixChecksumOk;

  /// Whether the full identity chain held: both per-track input
  /// identities, the mix identity, zero provider poisoning, and zero
  /// coordinator silence windows.
  final bool checksumIdentityOk;

  /// Whether accepted (both tracks) / rendered / pushed / read frame
  /// totals all equal the frozen expected timeline with the explicit
  /// pre/post seek split.
  final bool frameAccountingOk;

  /// Whether framesWrittenToSink + residualFramesAtEnd(0) ==
  /// totalOutputFramesRead == expectedFrames held losslessly.
  final bool sinkWriteAccountingOk;

  /// Whether every per-track provider poisoning counter (zero-filled
  /// frames, underrun events, forward skips, rewind rejects) was zero.
  final bool providerPoisoningOk;

  /// Whether the muted AudioTrack reached STATE_INITIALIZED with valid
  /// MODE_STREAM buffer geometry.
  final bool audioTrackInitOk;

  /// Whether the AudioTrack was muted (volume 0.0) before any play/write
  /// proof ran.
  final bool mutedOutputOk;

  /// Whether the unsigned-masked playback head progressed within the
  /// post-seek sink epoch (TELEMETRY lane only; the head is never a native
  /// anchor, timebase, or correction).
  final bool playbackHeadTelemetryOk;

  /// Whether the native worker's own steady_clock measured sampleRate
  /// frames of render-cursor progress in [980ms, 1350ms] inside the
  /// pre-seek epoch (excluding start pre-roll) — the primary realtime gate.
  final bool realtimeNativeElapsedOk;

  /// Whether the native max render-cursor backlog stayed below 250000us
  /// across every counted dispatch past the per-epoch warmup.
  final bool realtimeBacklogBoundOk;

  /// Whether the pre-EOS joint forward seek re-anchored BOTH tracks at
  /// exactly the accepted frame boundary with a cleanly consumed output
  /// ack and zero discards.
  final bool seekEpochReanchorOk;

  /// Whether the seek followed pause+flush at quiescence with zero staged
  /// residual and fully reset sink epoch baselines before re-preroll and
  /// play.
  final bool seekSinkEpochResetOk;

  /// Whether the synthetic generator was explicitly re-anchored exactly
  /// once at the joint seek's accepted frame.
  final bool syntheticGeneratorReanchorOk;

  /// Whether destroy set the stop flag, woke, and JOINED the worker.
  final bool workerJoinOnDestroyOk;

  /// Whether a second destroy and post-destroy snapshot returned not_found.
  final bool idempotentDestroyOk;

  /// Whether the native snapshot carried the multi-source realtime-clock
  /// TU's canonical proof boundary verbatim.
  final bool canonicalProofBoundaryOk;

  /// Whether every JNI and AudioTrack call stayed on the single Kotlin
  /// owner thread.
  final bool ownerThreadAffinityOk;

  // ---- Metrics ------------------------------------------------------------

  /// Decoder output sample rate.
  final int sampleRate;

  /// Decoder output channel count (1 or 2).
  final int channelCount;

  /// Decoder output PCM encoding (Android AudioFormat constant).
  final int pcmEncoding;

  /// Frozen expected timeline length in frames (pre + post seek budgets).
  final int expectedFrames;

  /// Window-aligned pre-seek frame budget (the joint seek boundary).
  final int preSeekFrames;

  /// Window-aligned post-seek frame budget.
  final int postSeekFrames;

  /// Shared accepted-frame-axis seek target confirmed by native.
  final int seekTargetFrame;

  /// Per-track source ring capacity in frames (X4 default 8192).
  final int sourceRingCapacityFrames;

  /// Output ring capacity in frames (X4 default 4096).
  final int outputRingCapacityFrames;

  /// Mix window size in frames (X4 default 256).
  final int maxFramesPerMix;

  /// min(accepted0, accepted1) when the native start was enqueued (must be
  /// >= [preStartFillQuotaFrames]).
  final int preStartFillFrames;

  /// Explicit synthetic generator re-anchor count (must be 1).
  final int generatorReanchorCount;

  /// Native worker steady_clock elapsed for sampleRate frames of
  /// render-cursor progress, milliseconds.
  final int nativeRealtimeElapsedMs;

  /// Native timing gate start frame (first window boundary >= 8192).
  final int nativeTimingF0;

  /// Native timing gate end frame (F0 + sampleRate).
  final int nativeTimingF1;

  /// Native max render-cursor backlog observed at counted dispatches,
  /// microseconds.
  final int maxRenderCursorBacklogUs;

  /// Count of native backlog samples folded into the max.
  final int backlogSampleCount;

  /// Worker waits where the next full window was not yet due (normal
  /// realtime steady state, never an anomaly).
  final int workerNoFramesDueWaits;

  /// Coordinator output-ring backpressure records (normal telemetry in X4,
  /// never required for pass).
  final int backpressureCountTelemetry;

  /// Total decoded frames produced by the codec (including truncated and
  /// discarded frames that never entered the proof stream).
  final int totalFramesExtracted;

  /// Total frames accepted into the track-0 (real decoder) source ring.
  final int totalFramesAcceptedTrack0;

  /// Total frames accepted into the track-1 (synthetic) source ring.
  final int totalFramesAcceptedTrack1;

  /// Total mixed frames rendered by the native worker.
  final int totalFramesRendered;

  /// Total mixed frames pushed into the output ring by the worker.
  final int totalFramesPushed;

  /// Total mixed frames destructively read back by the owner thread.
  final int totalOutputFramesRead;

  /// Total frames staged from the output ring into the sink path.
  final int framesReadFromRing;

  /// Total frames written to the muted AudioTrack sink.
  final int framesWrittenToSink;

  /// Staged-but-unwritten frames at the end of the run (must be 0).
  final int residualFramesAtEnd;

  /// Sink frames discarded by the seek flush (excluded from every
  /// checksum/identity claim; must be >= 0).
  final int framesDiscardedInSinkAtSeek;

  /// Unsigned-masked playback head progress of the post-seek sink epoch —
  /// telemetry only, never a native timebase.
  final int playbackHeadDeltaTelemetryOnly;

  /// AudioTrack underrun count delta across both epochs — telemetry only,
  /// never a verdict gate.
  final int underrunDeltaTelemetryOnly;

  /// Total control commands enqueued by the owner thread (must be 2).
  final int commandsEnqueued;

  /// Total control commands executed by the worker thread (must be 2).
  final int commandsProcessed;

  /// Worker-side command execution errors (must be 0).
  final int commandErrors;

  /// Worker dispatch count over the session.
  final int dispatchCount;

  /// Coordinator silence windows (asserted 0; generator/ingest-dependent,
  /// not a structural claim).
  final int silenceCount;

  /// Track-0 provider zero-filled frames (must be 0 — never in identity).
  final int providerTrack0ZeroFilledFrames;

  /// Track-1 provider zero-filled frames (must be 0 — never in identity).
  final int providerTrack1ZeroFilledFrames;

  /// Track-0 provider underrun events (must be 0).
  final int providerTrack0UnderrunEvents;

  /// Track-1 provider underrun events (must be 0).
  final int providerTrack1UnderrunEvents;

  /// Track-0 provider forward skip frames (must be 0).
  final int providerTrack0ForwardSkipFrames;

  /// Track-1 provider forward skip frames (must be 0).
  final int providerTrack1ForwardSkipFrames;

  /// Track-0 provider rewind rejects (must be 0).
  final int providerTrack0RewindRejects;

  /// Track-1 provider rewind rejects (must be 0).
  final int providerTrack1RewindRejects;

  /// Whether the native worker thread id differs from the owner thread id.
  final bool workerThreadDistinct;

  /// Owner-side dispatch call count (structurally 0).
  final int ownerDispatchCalls;

  /// 64-bit hexadecimal checksum computed on the Kotlin track-0 accepted
  /// side.
  final String kotlinTrack0AcceptedChecksumHex;

  /// 64-bit hexadecimal checksum computed on the native track-0 accepted
  /// side.
  final String nativeAcceptedChecksumTrack0Hex;

  /// 64-bit hexadecimal checksum computed on the Kotlin track-1 accepted
  /// side.
  final String kotlinTrack1AcceptedChecksumHex;

  /// 64-bit hexadecimal checksum computed on the native track-1 accepted
  /// side.
  final String nativeAcceptedChecksumTrack1Hex;

  /// 64-bit hexadecimal checksum of the Kotlin clamp16(s0+s1) reference
  /// mix model.
  final String kotlinReferenceMixChecksumHex;

  /// 64-bit hexadecimal checksum computed on the native output read side.
  final String nativeOutputReadChecksumHex;

  /// 64-bit hexadecimal checksum computed on the Kotlin sink side over
  /// exactly the frames handed to AudioTrack.write.
  final String kotlinSinkWriteChecksumHex;

  // ---- Raw & nested maps --------------------------------------------------

  /// Nested lanes map emitted by native smoke execution.
  final Map<String, Object?> lanes;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Map of raw string outputs emitted by native smoke execution.
  final Map<String, String> raw;

  /// Last error string from native execution, if any.
  final String lastError;

  // ---- Getters ------------------------------------------------------------

  Object? _laneOrMetric(String key) => lanes[key] ?? metrics[key] ?? raw[key];

  bool _boolFact(String key) {
    final v = _laneOrMetric(key);
    if (v is bool) return v;
    if (v is String) return v.trim().toLowerCase() == 'true';
    return false;
  }

  int _intFact(String key, [int defaultValue = 0]) {
    final v = _laneOrMetric(key);
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? defaultValue;
    return defaultValue;
  }

  double _doubleFact(String key, [double defaultValue = 0.0]) {
    final v = _laneOrMetric(key);
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim()) ?? defaultValue;
    return defaultValue;
  }

  /// Whether this run executed the X5 dynamic-gain-envelope mode (false for
  /// every default X4 unit-gain run).
  bool get envelopeProofEnabled => _boolFact('envelopeProofEnabled');

  /// Whether the native mix bus actually applied an envelope-bearing track
  /// gain (worker-folded telemetry; false in X4 mode).
  bool get envelopeApplied => _boolFact('envelopeApplied');

  /// Total native per-frame envelope evaluations folded by the worker
  /// (0 in X4 mode).
  int get envelopeEvaluations => _intFact('envelopeEvaluations');

  /// Minimum effective per-frame gain observed by the native mix bus across
  /// envelope-bearing tracks (0.0 in X4 mode).
  double get minEffectiveGain => _doubleFact('minEffectiveGain');

  /// Maximum effective per-frame gain observed by the native mix bus across
  /// envelope-bearing tracks (0.0 in X4 mode).
  double get maxEffectiveGain => _doubleFact('maxEffectiveGain');

  /// X5 dynamic-gain-envelope gate: envelope-enabled runs must prove a
  /// dynamic envelope shaped the mix (applied, evaluated, min strictly
  /// below max within [0,1]); default X4 runs must report the exact
  /// no-envelope defaults, proving unit-gain behavior was preserved.
  bool get dynamicGainEnvelopeGatesHeld {
    if (!envelopeProofEnabled) {
      return !envelopeApplied && envelopeEvaluations == 0;
    }
    return envelopeApplied &&
        envelopeEvaluations > 0 &&
        minEffectiveGain >= 0.0 &&
        maxEffectiveGain <= 1.0 &&
        minEffectiveGain < maxEffectiveGain;
  }

  /// Whether [proofBoundary] matches the canonical Kotlin driver boundary.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether [nativeProofBoundary] matches the canonical native TU
  /// boundary (no native sink claim).
  bool get nativeProofBoundaryOk =>
      nativeProofBoundary == nativeProofBoundaryConstant;

  /// Whether both per-track input identities held with non-empty
  /// checksums.
  bool get trackChecksumsMatch =>
      kotlinTrack0AcceptedChecksumHex.isNotEmpty &&
      kotlinTrack1AcceptedChecksumHex.isNotEmpty &&
      kotlinTrack0AcceptedChecksumHex == nativeAcceptedChecksumTrack0Hex &&
      kotlinTrack1AcceptedChecksumHex == nativeAcceptedChecksumTrack1Hex;

  /// Whether the mixed output identity held with non-empty checksums:
  /// kotlinReferenceMix == nativeOutputRead == kotlinSinkWrite.
  bool get mixChecksumsMatch =>
      kotlinReferenceMixChecksumHex.isNotEmpty &&
      nativeOutputReadChecksumHex.isNotEmpty &&
      kotlinSinkWriteChecksumHex.isNotEmpty &&
      kotlinReferenceMixChecksumHex == nativeOutputReadChecksumHex &&
      nativeOutputReadChecksumHex == kotlinSinkWriteChecksumHex;

  /// Whether the full checksum identity chain held.
  bool get checksumsMatch =>
      trackChecksumsMatch && mixChecksumsMatch && checksumIdentityOk;

  /// Whether every per-track provider poisoning counter was zero.
  bool get providerCountersClean =>
      providerTrack0ZeroFilledFrames == 0 &&
      providerTrack1ZeroFilledFrames == 0 &&
      providerTrack0UnderrunEvents == 0 &&
      providerTrack1UnderrunEvents == 0 &&
      providerTrack0ForwardSkipFrames == 0 &&
      providerTrack1ForwardSkipFrames == 0 &&
      providerTrack0RewindRejects == 0 &&
      providerTrack1RewindRejects == 0;

  /// Whether the lossless sink accounting identity held:
  /// framesWrittenToSink + residualFramesAtEnd(0) == totalOutputFramesRead
  /// == expectedFrames.
  bool get sinkAccountingBalanced =>
      residualFramesAtEnd == 0 &&
      framesWrittenToSink == framesReadFromRing &&
      framesWrittenToSink + residualFramesAtEnd == totalOutputFramesRead &&
      totalOutputFramesRead == expectedFrames &&
      sinkWriteAccountingOk;

  /// Whether the native realtime gates held: the worker's own steady_clock
  /// one-second elapsed inside [980ms, 1350ms] and the render-cursor
  /// backlog max below 250000us with at least one counted sample.
  bool get realtimeGatesHeld =>
      realtimeNativeElapsedOk &&
      nativeRealtimeElapsedMs >= realtimeElapsedMinMs &&
      nativeRealtimeElapsedMs <= realtimeElapsedMaxMs &&
      realtimeBacklogBoundOk &&
      maxRenderCursorBacklogUs >= 0 &&
      maxRenderCursorBacklogUs < backlogBoundUs &&
      backlogSampleCount >= 1;

  /// Whether all native diagnostic lanes passed according to the
  /// P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-REALTIME-CLOCK verification
  /// contract. Backpressure is normal telemetry and never required.
  bool get allNativeLanesPass =>
      pass &&
      status.toLowerCase() == 'pass' &&
      marker ==
          (envelopeProofEnabled
              ? dynamicGainEnvelopePassMarkerConstant
              : passMarkerConstant) &&
      dynamicGainEnvelopeGatesHeld &&
      (!envelopeProofEnabled || _boolFact('dynamicGainEnvelopeOk')) &&
      hasCanonicalProofBoundary &&
      nativeProofBoundaryOk &&
      formatProbeOk &&
      decoderEosReachedOk &&
      realtimeWorkerClockOwnershipOk &&
      noCallerSuppliedNativeTimeOk &&
      noOwnerThreadDispatchOk &&
      controlCommandSerializationOk &&
      multiSourceRealDecoderIngestOk &&
      trackFrameAxisLockstepOk &&
      twoTrackContributionOk &&
      referenceMixChecksumOk &&
      checksumIdentityOk &&
      frameAccountingOk &&
      sinkWriteAccountingOk &&
      providerPoisoningOk &&
      audioTrackInitOk &&
      mutedOutputOk &&
      playbackHeadTelemetryOk &&
      realtimeNativeElapsedOk &&
      realtimeBacklogBoundOk &&
      seekEpochReanchorOk &&
      seekSinkEpochResetOk &&
      syntheticGeneratorReanchorOk &&
      workerJoinOnDestroyOk &&
      idempotentDestroyOk &&
      canonicalProofBoundaryOk &&
      ownerThreadAffinityOk &&
      workerThreadDistinct &&
      ownerDispatchCalls == 0 &&
      commandsEnqueued == 2 &&
      commandsProcessed == 2 &&
      commandErrors == 0 &&
      checksumsMatch &&
      providerCountersClean &&
      realtimeGatesHeld &&
      expectedFrames > 0 &&
      preSeekFrames + postSeekFrames == expectedFrames &&
      totalFramesAcceptedTrack0 == expectedFrames &&
      totalFramesAcceptedTrack1 == expectedFrames &&
      totalFramesRendered == expectedFrames &&
      totalFramesPushed == expectedFrames &&
      totalOutputFramesRead == expectedFrames &&
      totalFramesExtracted >= expectedFrames &&
      sinkAccountingBalanced &&
      framesDiscardedInSinkAtSeek >= 0 &&
      playbackHeadDeltaTelemetryOnly > 0 &&
      seekTargetFrame == preSeekFrames &&
      preStartFillFrames >= preStartFillQuotaFrames &&
      generatorReanchorCount == 1 &&
      silenceCount == 0 &&
      (lastError.isEmpty || lastError == 'none' || lastError == 'null');

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport fromMap(
    Object? raw,
  ) {
    if (raw is! Map) {
      return _failShapedReport(
        reason: 'native_result_not_a_map',
        details: '',
        lastError: 'native_result_not_a_map',
        proofBoundary: '',
        nativeProofBoundary: '',
      );
    }

    final rawMapInput = raw['raw'];
    final parsedRaw = <String, String>{};
    if (rawMapInput is Map) {
      for (final entry in rawMapInput.entries) {
        final k = entry.key?.toString();
        final v = entry.value?.toString();
        if (k != null && v != null) {
          parsedRaw[k] = v;
        }
      }
    } else if (rawMapInput is String && rawMapInput.isNotEmpty) {
      for (final part in rawMapInput.split(';')) {
        final eq = part.indexOf('=');
        if (eq > 0) {
          final k = part.substring(0, eq).trim();
          final v = part.substring(eq + 1).trim();
          if (k.isNotEmpty) {
            parsedRaw[k] = v;
          }
        }
      }
    }

    final lanesRaw = raw['lanes'];
    final parsedLanes = <String, Object?>{};
    if (lanesRaw is Map) {
      for (final entry in lanesRaw.entries) {
        final k = entry.key?.toString();
        if (k != null) {
          parsedLanes[k] = entry.value;
        }
      }
    }

    final metricsRaw = raw['metrics'];
    final parsedMetrics = <String, Object?>{};
    if (metricsRaw is Map) {
      for (final entry in metricsRaw.entries) {
        final k = entry.key?.toString();
        if (k != null) {
          parsedMetrics[k] = entry.value;
        }
      }
    }

    bool parseBool(String key, [bool defaultValue = false]) {
      final v =
          parsedLanes[key] ?? raw[key] ?? parsedMetrics[key] ?? parsedRaw[key];
      if (v is bool) {
        return v;
      }
      if (v is String) {
        final lower = v.trim().toLowerCase();
        if (lower == 'true' || lower == 'pass' || lower == 'ok') {
          return true;
        }
        if (lower == 'false' || lower == 'fail') {
          return false;
        }
      }
      return defaultValue;
    }

    int parseInt(String key, [int defaultValue = 0]) {
      final v =
          parsedMetrics[key] ?? raw[key] ?? parsedLanes[key] ?? parsedRaw[key];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim()) ?? defaultValue;
      return defaultValue;
    }

    String parseString(String key, [String defaultValue = '']) {
      final v =
          raw[key] ?? parsedMetrics[key] ?? parsedLanes[key] ?? parsedRaw[key];
      if (v != null) return v.toString();
      return defaultValue;
    }

    final pass = parseBool(
      'pass',
      parsedRaw['status']?.toLowerCase() == 'pass',
    );
    final failureReason = parseString(
      'failureReason',
      parsedRaw['reason'] ?? '',
    );

    return VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport(
      pass: pass,
      status: parseString('status', pass ? 'pass' : 'fail'),
      marker: parseString(
        'marker',
        pass ? passMarkerConstant : failMarkerConstant,
      ),
      proofBoundary: parseString('proofBoundary'),
      nativeProofBoundary: parseString('nativeProofBoundary'),
      failureReason: failureReason,
      details: parseString('details'),
      formatProbeOk: parseBool('formatProbeOk'),
      decoderEosReachedOk: parseBool('decoderEosReachedOk'),
      realtimeWorkerClockOwnershipOk: parseBool(
        'realtimeWorkerClockOwnershipOk',
      ),
      noCallerSuppliedNativeTimeOk: parseBool('noCallerSuppliedNativeTimeOk'),
      noOwnerThreadDispatchOk: parseBool('noOwnerThreadDispatchOk'),
      controlCommandSerializationOk: parseBool('controlCommandSerializationOk'),
      multiSourceRealDecoderIngestOk: parseBool(
        'multiSourceRealDecoderIngestOk',
      ),
      trackFrameAxisLockstepOk: parseBool('trackFrameAxisLockstepOk'),
      twoTrackContributionOk: parseBool('twoTrackContributionOk'),
      referenceMixChecksumOk: parseBool('referenceMixChecksumOk'),
      checksumIdentityOk: parseBool('checksumIdentityOk'),
      frameAccountingOk: parseBool('frameAccountingOk'),
      sinkWriteAccountingOk: parseBool('sinkWriteAccountingOk'),
      providerPoisoningOk: parseBool('providerPoisoningOk'),
      audioTrackInitOk: parseBool('audioTrackInitOk'),
      mutedOutputOk: parseBool('mutedOutputOk'),
      playbackHeadTelemetryOk: parseBool('playbackHeadTelemetryOk'),
      realtimeNativeElapsedOk: parseBool('realtimeNativeElapsedOk'),
      realtimeBacklogBoundOk: parseBool('realtimeBacklogBoundOk'),
      seekEpochReanchorOk: parseBool('seekEpochReanchorOk'),
      seekSinkEpochResetOk: parseBool('seekSinkEpochResetOk'),
      syntheticGeneratorReanchorOk: parseBool('syntheticGeneratorReanchorOk'),
      workerJoinOnDestroyOk: parseBool('workerJoinOnDestroyOk'),
      idempotentDestroyOk: parseBool('idempotentDestroyOk'),
      canonicalProofBoundaryOk: parseBool('canonicalProofBoundaryOk'),
      ownerThreadAffinityOk: parseBool('ownerThreadAffinityOk'),
      sampleRate: parseInt('sampleRate'),
      channelCount: parseInt('channelCount'),
      pcmEncoding: parseInt('pcmEncoding'),
      expectedFrames: parseInt('expectedFrames'),
      preSeekFrames: parseInt('preSeekFrames'),
      postSeekFrames: parseInt('postSeekFrames'),
      seekTargetFrame: parseInt('seekTargetFrame', -1),
      sourceRingCapacityFrames: parseInt('sourceRingCapacityFrames'),
      outputRingCapacityFrames: parseInt('outputRingCapacityFrames'),
      maxFramesPerMix: parseInt('maxFramesPerMix'),
      preStartFillFrames: parseInt('preStartFillFrames'),
      generatorReanchorCount: parseInt('generatorReanchorCount', -1),
      nativeRealtimeElapsedMs: parseInt('nativeRealtimeElapsedMs', -1),
      nativeTimingF0: parseInt('nativeTimingF0', -1),
      nativeTimingF1: parseInt('nativeTimingF1', -1),
      maxRenderCursorBacklogUs: parseInt('maxRenderCursorBacklogUs', -1),
      backlogSampleCount: parseInt('backlogSampleCount', -1),
      workerNoFramesDueWaits: parseInt('workerNoFramesDueWaits', -1),
      backpressureCountTelemetry: parseInt('backpressureCountTelemetry', -1),
      totalFramesExtracted: parseInt('totalFramesExtracted'),
      totalFramesAcceptedTrack0: parseInt('totalFramesAcceptedTrack0'),
      totalFramesAcceptedTrack1: parseInt('totalFramesAcceptedTrack1'),
      totalFramesRendered: parseInt('totalFramesRendered', -1),
      totalFramesPushed: parseInt('totalFramesPushed', -1),
      totalOutputFramesRead: parseInt('totalOutputFramesRead'),
      framesReadFromRing: parseInt('framesReadFromRing'),
      framesWrittenToSink: parseInt('framesWrittenToSink'),
      residualFramesAtEnd: parseInt('residualFramesAtEnd', -1),
      framesDiscardedInSinkAtSeek: parseInt('framesDiscardedInSinkAtSeek', -1),
      playbackHeadDeltaTelemetryOnly: parseInt(
        'playbackHeadDeltaTelemetryOnly',
        -1,
      ),
      underrunDeltaTelemetryOnly: parseInt('underrunDeltaTelemetryOnly', -1),
      commandsEnqueued: parseInt('commandsEnqueued', -1),
      commandsProcessed: parseInt('commandsProcessed', -1),
      commandErrors: parseInt('commandErrors', -1),
      dispatchCount: parseInt('dispatchCount', -1),
      silenceCount: parseInt('silenceCount', -1),
      providerTrack0ZeroFilledFrames: parseInt(
        'providerTrack0ZeroFilledFrames',
        -1,
      ),
      providerTrack1ZeroFilledFrames: parseInt(
        'providerTrack1ZeroFilledFrames',
        -1,
      ),
      providerTrack0UnderrunEvents: parseInt(
        'providerTrack0UnderrunEvents',
        -1,
      ),
      providerTrack1UnderrunEvents: parseInt(
        'providerTrack1UnderrunEvents',
        -1,
      ),
      providerTrack0ForwardSkipFrames: parseInt(
        'providerTrack0ForwardSkipFrames',
        -1,
      ),
      providerTrack1ForwardSkipFrames: parseInt(
        'providerTrack1ForwardSkipFrames',
        -1,
      ),
      providerTrack0RewindRejects: parseInt('providerTrack0RewindRejects', -1),
      providerTrack1RewindRejects: parseInt('providerTrack1RewindRejects', -1),
      workerThreadDistinct: parseBool('workerThreadDistinct'),
      ownerDispatchCalls: parseInt('ownerDispatchCalls', -1),
      kotlinTrack0AcceptedChecksumHex: parseString(
        'kotlinTrack0AcceptedChecksumHex',
      ),
      nativeAcceptedChecksumTrack0Hex: parseString(
        'nativeAcceptedChecksumTrack0Hex',
      ),
      kotlinTrack1AcceptedChecksumHex: parseString(
        'kotlinTrack1AcceptedChecksumHex',
      ),
      nativeAcceptedChecksumTrack1Hex: parseString(
        'nativeAcceptedChecksumTrack1Hex',
      ),
      kotlinReferenceMixChecksumHex: parseString(
        'kotlinReferenceMixChecksumHex',
      ),
      nativeOutputReadChecksumHex: parseString('nativeOutputReadChecksumHex'),
      kotlinSinkWriteChecksumHex: parseString('kotlinSinkWriteChecksumHex'),
      lanes: Map<String, Object?>.unmodifiable(parsedLanes),
      metrics: Map<String, Object?>.unmodifiable(parsedMetrics),
      raw: Map<String, String>.unmodifiable(parsedRaw),
      lastError: parseString(
        'lastError',
        failureReason.isNotEmpty ? failureReason : '',
      ),
    );
  }

  /// Serializes the report back to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'status': status,
      'marker': marker,
      'proofBoundary': proofBoundary,
      'nativeProofBoundary': nativeProofBoundary,
      'failureReason': failureReason,
      'details': details,
      'lanes': Map<String, Object?>.from(lanes),
      'metrics': Map<String, Object?>.from(metrics),
      'raw': Map<String, String>.from(raw),
      'lastError': lastError,
    };
  }

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  static VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
  _failShapedReport({
    required String reason,
    required String details,
    required String lastError,
    String proofBoundary = proofBoundaryConstant,
    String nativeProofBoundary = '',
  }) {
    return VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundary,
      nativeProofBoundary: nativeProofBoundary,
      failureReason: reason,
      details: details,
      formatProbeOk: false,
      decoderEosReachedOk: false,
      realtimeWorkerClockOwnershipOk: false,
      noCallerSuppliedNativeTimeOk: false,
      noOwnerThreadDispatchOk: false,
      controlCommandSerializationOk: false,
      multiSourceRealDecoderIngestOk: false,
      trackFrameAxisLockstepOk: false,
      twoTrackContributionOk: false,
      referenceMixChecksumOk: false,
      checksumIdentityOk: false,
      frameAccountingOk: false,
      sinkWriteAccountingOk: false,
      providerPoisoningOk: false,
      audioTrackInitOk: false,
      mutedOutputOk: false,
      playbackHeadTelemetryOk: false,
      realtimeNativeElapsedOk: false,
      realtimeBacklogBoundOk: false,
      seekEpochReanchorOk: false,
      seekSinkEpochResetOk: false,
      syntheticGeneratorReanchorOk: false,
      workerJoinOnDestroyOk: false,
      idempotentDestroyOk: false,
      canonicalProofBoundaryOk: false,
      ownerThreadAffinityOk: false,
      sampleRate: 0,
      channelCount: 0,
      pcmEncoding: 0,
      expectedFrames: 0,
      preSeekFrames: 0,
      postSeekFrames: 0,
      seekTargetFrame: -1,
      sourceRingCapacityFrames: 0,
      outputRingCapacityFrames: 0,
      maxFramesPerMix: 0,
      preStartFillFrames: 0,
      generatorReanchorCount: -1,
      nativeRealtimeElapsedMs: -1,
      nativeTimingF0: -1,
      nativeTimingF1: -1,
      maxRenderCursorBacklogUs: -1,
      backlogSampleCount: -1,
      workerNoFramesDueWaits: -1,
      backpressureCountTelemetry: -1,
      totalFramesExtracted: 0,
      totalFramesAcceptedTrack0: 0,
      totalFramesAcceptedTrack1: 0,
      totalFramesRendered: -1,
      totalFramesPushed: -1,
      totalOutputFramesRead: 0,
      framesReadFromRing: 0,
      framesWrittenToSink: 0,
      residualFramesAtEnd: -1,
      framesDiscardedInSinkAtSeek: -1,
      playbackHeadDeltaTelemetryOnly: -1,
      underrunDeltaTelemetryOnly: -1,
      commandsEnqueued: -1,
      commandsProcessed: -1,
      commandErrors: -1,
      dispatchCount: -1,
      silenceCount: -1,
      providerTrack0ZeroFilledFrames: -1,
      providerTrack1ZeroFilledFrames: -1,
      providerTrack0UnderrunEvents: -1,
      providerTrack1UnderrunEvents: -1,
      providerTrack0ForwardSkipFrames: -1,
      providerTrack1ForwardSkipFrames: -1,
      providerTrack0RewindRejects: -1,
      providerTrack1RewindRejects: -1,
      workerThreadDistinct: false,
      ownerDispatchCalls: -1,
      kotlinTrack0AcceptedChecksumHex: '',
      nativeAcceptedChecksumTrack0Hex: '',
      kotlinTrack1AcceptedChecksumHex: '',
      nativeAcceptedChecksumTrack1Hex: '',
      kotlinReferenceMixChecksumHex: '',
      nativeOutputReadChecksumHex: '',
      kotlinSinkWriteChecksumHex: '',
      lanes: Map<String, Object?>.unmodifiable(<String, Object?>{
        'status': 'FAIL',
        'reason': reason,
      }),
      metrics: Map<String, Object?>.unmodifiable(<String, Object?>{
        'status': 'FAIL',
        'reason': reason,
      }),
      raw: Map<String, String>.unmodifiable(<String, String>{
        'status': 'FAIL',
        'reason': reason,
      }),
      lastError: lastError,
    );
  }

  /// Invokes the Android True-DAG Phase 4 async runtime queue multi-source
  /// realtime worker-owned wall-clock pacing diagnostic smoke harness.
  ///
  /// [sourcePath] must be a readable local media file with an audio track
  /// at least [durationSec] long. Defaults mirror the Kotlin coordinator;
  /// [timeout] bounds the call and is forwarded as `deadlineMs`. [channel]
  /// may be injected for testing. Any MethodChannel error yields an
  /// unsupported/fail-shaped report.
  static Future<VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport>
  runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke({
    required String sourcePath,
    double durationSec = 2.0,
    double seekTargetSec = 1.30,
    double preSeekBudgetSec = 1.20,
    double postSeekBudgetSec = 0.55,
    int sourceRingCapacityFrames = 8192,
    int outputRingCapacityFrames = 4096,
    int maxFramesPerMix = 256,
    bool envelopeProofEnabled = false,
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final args = <String, Object?>{
      'sourcePath': sourcePath,
      'durationSec': durationSec,
      'seekTargetSec': seekTargetSec,
      'preSeekBudgetSec': preSeekBudgetSec,
      'postSeekBudgetSec': postSeekBudgetSec,
      'sourceRingCapacityFrames': sourceRingCapacityFrames,
      'outputRingCapacityFrames': outputRingCapacityFrames,
      'maxFramesPerMix': maxFramesPerMix,
      'deadlineMs': timeout != null ? timeout.inMilliseconds : 30000,
      // Only sent for X5 dynamic-gain-envelope runs so the default X4
      // argument shape (and its exact-args tests) stays frozen.
      if (envelopeProofEnabled) 'envelopeProofEnabled': true,
    };
    try {
      final future = ch.invokeMethod<Object?>(methodName, args);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
        raw,
      );
    } on TimeoutException catch (te) {
      return _failShapedReport(
        reason: 'timeout',
        details: te.toString(),
        lastError: 'timeout: $te',
      );
    } on PlatformException catch (pe) {
      return _failShapedReport(
        reason: 'platform_exception:${pe.code}',
        details: pe.message ?? '',
        lastError: 'platform_exception:${pe.code}:${pe.message}',
      );
    } on MissingPluginException catch (mpe) {
      return _failShapedReport(
        reason: 'unsupported_platform',
        details: mpe.toString(),
        lastError: 'unsupported_platform: $mpe',
      );
    } catch (e) {
      return _failShapedReport(
        reason: 'exception:$e',
        details: e.toString(),
        lastError: 'exception:$e',
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.nativeProofBoundary == nativeProofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.formatProbeOk == formatProbeOk &&
        other.decoderEosReachedOk == decoderEosReachedOk &&
        other.realtimeWorkerClockOwnershipOk ==
            realtimeWorkerClockOwnershipOk &&
        other.noCallerSuppliedNativeTimeOk == noCallerSuppliedNativeTimeOk &&
        other.noOwnerThreadDispatchOk == noOwnerThreadDispatchOk &&
        other.controlCommandSerializationOk == controlCommandSerializationOk &&
        other.multiSourceRealDecoderIngestOk ==
            multiSourceRealDecoderIngestOk &&
        other.trackFrameAxisLockstepOk == trackFrameAxisLockstepOk &&
        other.twoTrackContributionOk == twoTrackContributionOk &&
        other.referenceMixChecksumOk == referenceMixChecksumOk &&
        other.checksumIdentityOk == checksumIdentityOk &&
        other.frameAccountingOk == frameAccountingOk &&
        other.sinkWriteAccountingOk == sinkWriteAccountingOk &&
        other.providerPoisoningOk == providerPoisoningOk &&
        other.audioTrackInitOk == audioTrackInitOk &&
        other.mutedOutputOk == mutedOutputOk &&
        other.playbackHeadTelemetryOk == playbackHeadTelemetryOk &&
        other.realtimeNativeElapsedOk == realtimeNativeElapsedOk &&
        other.realtimeBacklogBoundOk == realtimeBacklogBoundOk &&
        other.seekEpochReanchorOk == seekEpochReanchorOk &&
        other.seekSinkEpochResetOk == seekSinkEpochResetOk &&
        other.syntheticGeneratorReanchorOk == syntheticGeneratorReanchorOk &&
        other.workerJoinOnDestroyOk == workerJoinOnDestroyOk &&
        other.idempotentDestroyOk == idempotentDestroyOk &&
        other.canonicalProofBoundaryOk == canonicalProofBoundaryOk &&
        other.ownerThreadAffinityOk == ownerThreadAffinityOk &&
        other.sampleRate == sampleRate &&
        other.channelCount == channelCount &&
        other.pcmEncoding == pcmEncoding &&
        other.expectedFrames == expectedFrames &&
        other.preSeekFrames == preSeekFrames &&
        other.postSeekFrames == postSeekFrames &&
        other.seekTargetFrame == seekTargetFrame &&
        other.sourceRingCapacityFrames == sourceRingCapacityFrames &&
        other.outputRingCapacityFrames == outputRingCapacityFrames &&
        other.maxFramesPerMix == maxFramesPerMix &&
        other.preStartFillFrames == preStartFillFrames &&
        other.generatorReanchorCount == generatorReanchorCount &&
        other.nativeRealtimeElapsedMs == nativeRealtimeElapsedMs &&
        other.nativeTimingF0 == nativeTimingF0 &&
        other.nativeTimingF1 == nativeTimingF1 &&
        other.maxRenderCursorBacklogUs == maxRenderCursorBacklogUs &&
        other.backlogSampleCount == backlogSampleCount &&
        other.workerNoFramesDueWaits == workerNoFramesDueWaits &&
        other.backpressureCountTelemetry == backpressureCountTelemetry &&
        other.totalFramesExtracted == totalFramesExtracted &&
        other.totalFramesAcceptedTrack0 == totalFramesAcceptedTrack0 &&
        other.totalFramesAcceptedTrack1 == totalFramesAcceptedTrack1 &&
        other.totalFramesRendered == totalFramesRendered &&
        other.totalFramesPushed == totalFramesPushed &&
        other.totalOutputFramesRead == totalOutputFramesRead &&
        other.framesReadFromRing == framesReadFromRing &&
        other.framesWrittenToSink == framesWrittenToSink &&
        other.residualFramesAtEnd == residualFramesAtEnd &&
        other.framesDiscardedInSinkAtSeek == framesDiscardedInSinkAtSeek &&
        other.playbackHeadDeltaTelemetryOnly ==
            playbackHeadDeltaTelemetryOnly &&
        other.underrunDeltaTelemetryOnly == underrunDeltaTelemetryOnly &&
        other.commandsEnqueued == commandsEnqueued &&
        other.commandsProcessed == commandsProcessed &&
        other.commandErrors == commandErrors &&
        other.dispatchCount == dispatchCount &&
        other.silenceCount == silenceCount &&
        other.providerTrack0ZeroFilledFrames ==
            providerTrack0ZeroFilledFrames &&
        other.providerTrack1ZeroFilledFrames ==
            providerTrack1ZeroFilledFrames &&
        other.providerTrack0UnderrunEvents == providerTrack0UnderrunEvents &&
        other.providerTrack1UnderrunEvents == providerTrack1UnderrunEvents &&
        other.providerTrack0ForwardSkipFrames ==
            providerTrack0ForwardSkipFrames &&
        other.providerTrack1ForwardSkipFrames ==
            providerTrack1ForwardSkipFrames &&
        other.providerTrack0RewindRejects == providerTrack0RewindRejects &&
        other.providerTrack1RewindRejects == providerTrack1RewindRejects &&
        other.workerThreadDistinct == workerThreadDistinct &&
        other.ownerDispatchCalls == ownerDispatchCalls &&
        other.kotlinTrack0AcceptedChecksumHex ==
            kotlinTrack0AcceptedChecksumHex &&
        other.nativeAcceptedChecksumTrack0Hex ==
            nativeAcceptedChecksumTrack0Hex &&
        other.kotlinTrack1AcceptedChecksumHex ==
            kotlinTrack1AcceptedChecksumHex &&
        other.nativeAcceptedChecksumTrack1Hex ==
            nativeAcceptedChecksumTrack1Hex &&
        other.kotlinReferenceMixChecksumHex == kotlinReferenceMixChecksumHex &&
        other.nativeOutputReadChecksumHex == nativeOutputReadChecksumHex &&
        other.kotlinSinkWriteChecksumHex == kotlinSinkWriteChecksumHex &&
        mapEquals(other.lanes, lanes) &&
        mapEquals(other.metrics, metrics) &&
        mapEquals(other.raw, raw) &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hashAll([
    pass,
    status,
    marker,
    proofBoundary,
    nativeProofBoundary,
    failureReason,
    details,
    formatProbeOk,
    decoderEosReachedOk,
    realtimeWorkerClockOwnershipOk,
    noCallerSuppliedNativeTimeOk,
    noOwnerThreadDispatchOk,
    controlCommandSerializationOk,
    multiSourceRealDecoderIngestOk,
    trackFrameAxisLockstepOk,
    twoTrackContributionOk,
    referenceMixChecksumOk,
    checksumIdentityOk,
    frameAccountingOk,
    sinkWriteAccountingOk,
    providerPoisoningOk,
    audioTrackInitOk,
    mutedOutputOk,
    playbackHeadTelemetryOk,
    realtimeNativeElapsedOk,
    realtimeBacklogBoundOk,
    seekEpochReanchorOk,
    seekSinkEpochResetOk,
    syntheticGeneratorReanchorOk,
    workerJoinOnDestroyOk,
    idempotentDestroyOk,
    canonicalProofBoundaryOk,
    ownerThreadAffinityOk,
    sampleRate,
    channelCount,
    pcmEncoding,
    expectedFrames,
    preSeekFrames,
    postSeekFrames,
    seekTargetFrame,
    sourceRingCapacityFrames,
    outputRingCapacityFrames,
    maxFramesPerMix,
    preStartFillFrames,
    generatorReanchorCount,
    nativeRealtimeElapsedMs,
    nativeTimingF0,
    nativeTimingF1,
    maxRenderCursorBacklogUs,
    backlogSampleCount,
    workerNoFramesDueWaits,
    backpressureCountTelemetry,
    totalFramesExtracted,
    totalFramesAcceptedTrack0,
    totalFramesAcceptedTrack1,
    totalFramesRendered,
    totalFramesPushed,
    totalOutputFramesRead,
    framesReadFromRing,
    framesWrittenToSink,
    residualFramesAtEnd,
    framesDiscardedInSinkAtSeek,
    playbackHeadDeltaTelemetryOnly,
    underrunDeltaTelemetryOnly,
    commandsEnqueued,
    commandsProcessed,
    commandErrors,
    dispatchCount,
    silenceCount,
    providerTrack0ZeroFilledFrames,
    providerTrack1ZeroFilledFrames,
    providerTrack0UnderrunEvents,
    providerTrack1UnderrunEvents,
    providerTrack0ForwardSkipFrames,
    providerTrack1ForwardSkipFrames,
    providerTrack0RewindRejects,
    providerTrack1RewindRejects,
    workerThreadDistinct,
    ownerDispatchCalls,
    kotlinTrack0AcceptedChecksumHex,
    nativeAcceptedChecksumTrack0Hex,
    kotlinTrack1AcceptedChecksumHex,
    nativeAcceptedChecksumTrack1Hex,
    kotlinReferenceMixChecksumHex,
    nativeOutputReadChecksumHex,
    kotlinSinkWriteChecksumHex,
    _stableMapHash(lanes),
    _stableMapHash(metrics),
    _stableMapHash(raw),
    lastError,
  ]);

  static int _stableMapHash(Map<dynamic, dynamic> map) {
    final sortedKeys = map.keys.map((k) => k.toString()).toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'formatProbeOk: $formatProbeOk, '
      'decoderEosReachedOk: $decoderEosReachedOk, '
      'realtimeWorkerClockOwnershipOk: $realtimeWorkerClockOwnershipOk, '
      'noCallerSuppliedNativeTimeOk: $noCallerSuppliedNativeTimeOk, '
      'noOwnerThreadDispatchOk: $noOwnerThreadDispatchOk, '
      'controlCommandSerializationOk: $controlCommandSerializationOk, '
      'multiSourceRealDecoderIngestOk: $multiSourceRealDecoderIngestOk, '
      'trackFrameAxisLockstepOk: $trackFrameAxisLockstepOk, '
      'twoTrackContributionOk: $twoTrackContributionOk, '
      'referenceMixChecksumOk: $referenceMixChecksumOk, '
      'checksumIdentityOk: $checksumIdentityOk, '
      'frameAccountingOk: $frameAccountingOk, '
      'sinkWriteAccountingOk: $sinkWriteAccountingOk, '
      'providerPoisoningOk: $providerPoisoningOk, '
      'audioTrackInitOk: $audioTrackInitOk, '
      'mutedOutputOk: $mutedOutputOk, '
      'playbackHeadTelemetryOk: $playbackHeadTelemetryOk, '
      'realtimeNativeElapsedOk: $realtimeNativeElapsedOk, '
      'realtimeBacklogBoundOk: $realtimeBacklogBoundOk, '
      'seekEpochReanchorOk: $seekEpochReanchorOk, '
      'seekSinkEpochResetOk: $seekSinkEpochResetOk, '
      'syntheticGeneratorReanchorOk: $syntheticGeneratorReanchorOk, '
      'workerJoinOnDestroyOk: $workerJoinOnDestroyOk, '
      'idempotentDestroyOk: $idempotentDestroyOk, '
      'canonicalProofBoundaryOk: $canonicalProofBoundaryOk, '
      'ownerThreadAffinityOk: $ownerThreadAffinityOk, '
      'sampleRate: $sampleRate, '
      'channelCount: $channelCount, '
      'expectedFrames: $expectedFrames, '
      'preSeekFrames: $preSeekFrames, '
      'postSeekFrames: $postSeekFrames, '
      'seekTargetFrame: $seekTargetFrame, '
      'preStartFillFrames: $preStartFillFrames, '
      'generatorReanchorCount: $generatorReanchorCount, '
      'nativeRealtimeElapsedMs: $nativeRealtimeElapsedMs, '
      'nativeTimingF0: $nativeTimingF0, '
      'nativeTimingF1: $nativeTimingF1, '
      'maxRenderCursorBacklogUs: $maxRenderCursorBacklogUs, '
      'workerNoFramesDueWaits: $workerNoFramesDueWaits, '
      'backpressureCountTelemetry: $backpressureCountTelemetry, '
      'totalFramesAcceptedTrack0: $totalFramesAcceptedTrack0, '
      'totalFramesAcceptedTrack1: $totalFramesAcceptedTrack1, '
      'totalFramesRendered: $totalFramesRendered, '
      'totalFramesPushed: $totalFramesPushed, '
      'totalOutputFramesRead: $totalOutputFramesRead, '
      'framesReadFromRing: $framesReadFromRing, '
      'framesWrittenToSink: $framesWrittenToSink, '
      'residualFramesAtEnd: $residualFramesAtEnd, '
      'playbackHeadDeltaTelemetryOnly: $playbackHeadDeltaTelemetryOnly, '
      'underrunDeltaTelemetryOnly: $underrunDeltaTelemetryOnly, '
      'commandsEnqueued: $commandsEnqueued, '
      'commandsProcessed: $commandsProcessed, '
      'commandErrors: $commandErrors, '
      'silenceCount: $silenceCount, '
      'workerThreadDistinct: $workerThreadDistinct, '
      'ownerDispatchCalls: $ownerDispatchCalls, '
      'kotlinTrack0AcceptedChecksumHex: $kotlinTrack0AcceptedChecksumHex, '
      'nativeAcceptedChecksumTrack0Hex: $nativeAcceptedChecksumTrack0Hex, '
      'kotlinTrack1AcceptedChecksumHex: $kotlinTrack1AcceptedChecksumHex, '
      'nativeAcceptedChecksumTrack1Hex: $nativeAcceptedChecksumTrack1Hex, '
      'kotlinReferenceMixChecksumHex: $kotlinReferenceMixChecksumHex, '
      'nativeOutputReadChecksumHex: $nativeOutputReadChecksumHex, '
      'kotlinSinkWriteChecksumHex: $kotlinSinkWriteChecksumHex, '
      'lastError: $lastError)';
}
