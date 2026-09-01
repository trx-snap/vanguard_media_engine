// vg_async_runtime_queue_realtime_clock_smoke.dart
// vanguard_media_engine - P4-AUDIO-ASYNC-RUNTIME-QUEUE-REALTIME-CLOCK-PACING:
// Android True-DAG Phase 4 async runtime queue native worker-owned monotonic
// wall-clock render/dispatch timebase realtime pacing diagnostic smoke
// foundation (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice X3).
//
// Pure Dart typed model + invocation wrapper over the native
// `runAsyncRuntimeQueueRealtimeClockSmoke` MethodChannel route.
// Diagnostic-only: validates that the async runtime queue NATIVE WORKER
// thread reads std::chrono::steady_clock itself, passes those ns values to
// AudioClock / ClockedAudioTransportCoordinator, and paces dispatch in
// realtime (native per-epoch one-second timing gate plus a render-cursor
// backlog bound), while Kotlin owns MediaExtractor/MediaCodec decode, the
// source-ring producer role, the output-ring consumer role, and the muted
// AudioTrack MODE_STREAM sink writes. No control command carries a
// caller-supplied time value; playback head / AudioTimestamp / underrun
// facts are telemetry only, never a native anchor, timebase, or correction.
//
// Honest non-claims (Proof Boundary):
// kotlin_owned_audiotrack_sink_on_async_runtime_queue_realtime_wall_clock_pacing_proof_only_real_decoder_to_async_runtime_queue_scheduler_output_ring_to_muted_audiotrack_mode_stream_native_worker_owned_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_kotlin_owned_mediacodec_mediaextractor_and_audiotrack_lifecycle_write_non_blocking_only_playback_head_and_audio_timestamp_telemetry_only_no_audible_output_no_speaker_route_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_zero_underrun_claim_no_realtime_priority_claim_no_fleet_claim_no_product_editor_app_wiring_no_export_route_no_streaming_cache_no_ios_no_cpp_primitive_changes

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAsyncRuntimeQueueRealtimeClockSmokeReport.runAsyncRuntimeQueueRealtimeClockSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGAsyncRuntimeQueueRealtimeClockSmokeReport {
  const VGAsyncRuntimeQueueRealtimeClockSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.details,
    required this.formatProbeOk,
    required this.decoderEosReachedOk,
    required this.realtimeWorkerClockOwnershipOk,
    required this.noCallerSuppliedNativeTimeOk,
    required this.noOwnerThreadDispatchOk,
    required this.controlCommandSerializationOk,
    required this.realDecoderIngestOk,
    required this.checksumIdentityOk,
    required this.frameAccountingOk,
    required this.sinkWriteAccountingOk,
    required this.audioTrackInitOk,
    required this.mutedOutputOk,
    required this.playbackHeadTelemetryOk,
    required this.realtimeNativeElapsedOk,
    required this.realtimeBacklogBoundOk,
    required this.seekEpochReanchorOk,
    required this.seekSinkEpochResetOk,
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
    required this.nativeRealtimeElapsedMs,
    required this.nativeTimingF0,
    required this.nativeTimingF1,
    required this.maxRenderCursorBacklogUs,
    required this.backlogSampleCount,
    required this.workerNoFramesDueWaits,
    required this.totalFramesExtracted,
    required this.totalFramesAccepted,
    required this.totalFramesRendered,
    required this.totalFramesPushed,
    required this.totalOutputFramesRead,
    required this.framesReadFromRing,
    required this.framesWrittenToSink,
    required this.residualFramesAtEnd,
    required this.framesDiscardedInSinkAtSeek,
    required this.playbackHeadDeltaTelemetryOnly,
    required this.underrunDeltaTelemetryOnly,
    required this.audioTimestampAttemptCount,
    required this.audioTimestampSuccessCount,
    required this.commandsEnqueued,
    required this.commandsProcessed,
    required this.commandErrors,
    required this.dispatchCount,
    required this.silenceCount,
    required this.backpressureCount,
    required this.providerFramesZeroFilled,
    required this.workerThreadDistinct,
    required this.ownerDispatchCalls,
    required this.kotlinAcceptedChecksumHex,
    required this.kotlinSinkChecksumHex,
    required this.nativeAcceptedChecksumHex,
    required this.nativeOutputReadChecksumHex,
    required this.lanes,
    required this.metrics,
    required this.raw,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName = 'runAsyncRuntimeQueueRealtimeClockSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REALTIME_CLOCK_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REALTIME_CLOCK_SMOKE_FAIL';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'kotlin_owned_audiotrack_sink_on_async_runtime_queue_realtime_wall_clock_pacing_proof_only_real_decoder_to_async_runtime_queue_scheduler_output_ring_to_muted_audiotrack_mode_stream_native_worker_owned_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_kotlin_owned_mediacodec_mediaextractor_and_audiotrack_lifecycle_write_non_blocking_only_playback_head_and_audio_timestamp_telemetry_only_no_audible_output_no_speaker_route_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_zero_underrun_claim_no_realtime_priority_claim_no_fleet_claim_no_product_editor_app_wiring_no_export_route_no_streaming_cache_no_ios_no_cpp_primitive_changes';

  /// Frozen pre-start (and post-seek) source fill quota in frames.
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

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

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
  /// steady_clock timebase, performed every dispatch, and finished with
  /// zero anomalies and zero nonmonotonic-time events.
  final bool realtimeWorkerClockOwnershipOk;

  /// Whether the native snapshot carried the structural token proving no
  /// entry point accepts a caller-supplied time value.
  final bool noCallerSuppliedNativeTimeOk;

  /// Whether the owner thread performed zero dispatch calls.
  final bool noOwnerThreadDispatchOk;

  /// Whether both control commands (start/seek) were queue-serialized and
  /// executed in order with zero command errors.
  final bool controlCommandSerializationOk;

  /// Whether the real decoder supplied the entire frozen expected timeline
  /// into the source ring, with the pre-start fill quota met before start.
  final bool realDecoderIngestOk;

  /// Whether Kotlin accepted, native accepted, native output read, and
  /// Kotlin sink checksums are identical with zero provider
  /// zero-fill/underrun/silence.
  final bool checksumIdentityOk;

  /// Whether accepted/rendered/pushed/read frame totals all equal the
  /// frozen expected timeline with zero skips or rewind rejects.
  final bool frameAccountingOk;

  /// Whether framesWrittenToSink + residualFramesAtEnd(0) ==
  /// totalOutputFramesRead == expectedFrames held losslessly.
  final bool sinkWriteAccountingOk;

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

  /// Whether the pre-EOS forward seek re-anchored at exactly the accepted
  /// frame boundary with a cleanly consumed output ack and zero discards.
  final bool seekEpochReanchorOk;

  /// Whether the seek followed pause+flush at quiescence with zero staged
  /// residual and fully reset sink epoch baselines before re-preroll and
  /// play.
  final bool seekSinkEpochResetOk;

  /// Whether destroy set the stop flag, woke, and JOINED the worker.
  final bool workerJoinOnDestroyOk;

  /// Whether a second destroy and post-destroy snapshot returned not_found.
  final bool idempotentDestroyOk;

  /// Whether the native snapshot carried the realtime-clock TU's canonical
  /// proof boundary verbatim.
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

  /// Window-aligned pre-seek frame budget (the seek boundary).
  final int preSeekFrames;

  /// Window-aligned post-seek frame budget.
  final int postSeekFrames;

  /// Accepted-frame-axis seek target confirmed by native.
  final int seekTargetFrame;

  /// Source ring capacity in frames (X3 default 8192).
  final int sourceRingCapacityFrames;

  /// Output ring capacity in frames (X3 default 4096).
  final int outputRingCapacityFrames;

  /// Mix window size in frames (X3 default 256).
  final int maxFramesPerMix;

  /// Frames ingested before the native start was enqueued (must be >=
  /// [preStartFillQuotaFrames]).
  final int preStartFillFrames;

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

  /// Total decoded frames produced by the codec (including truncated and
  /// discarded frames that never entered the proof stream).
  final int totalFramesExtracted;

  /// Total frames accepted into the source ring.
  final int totalFramesAccepted;

  /// Total frames rendered by the native worker.
  final int totalFramesRendered;

  /// Total frames pushed into the output ring by the worker.
  final int totalFramesPushed;

  /// Total frames destructively read back by the owner thread.
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

  /// AudioTimestamp sampling attempts — telemetry only.
  final int audioTimestampAttemptCount;

  /// AudioTimestamp sampling successes — telemetry only.
  final int audioTimestampSuccessCount;

  /// Total control commands enqueued by the owner thread (must be 2).
  final int commandsEnqueued;

  /// Total control commands executed by the worker thread (must be 2).
  final int commandsProcessed;

  /// Worker-side command execution errors (must be 0).
  final int commandErrors;

  /// Worker dispatch count over the session.
  final int dispatchCount;

  /// Coordinator silence windows (must be 0).
  final int silenceCount;

  /// Coordinator output-ring backpressure records (normal telemetry in X3,
  /// never required for pass).
  final int backpressureCount;

  /// Provider zero-filled frames (must be 0 — never in identity).
  final int providerFramesZeroFilled;

  /// Whether the native worker thread id differs from the owner thread id.
  final bool workerThreadDistinct;

  /// Owner-side dispatch call count (structurally 0).
  final int ownerDispatchCalls;

  /// 64-bit hexadecimal checksum computed on the Kotlin accepted side.
  final String kotlinAcceptedChecksumHex;

  /// 64-bit hexadecimal checksum computed on the Kotlin sink side over
  /// exactly the frames handed to AudioTrack.write.
  final String kotlinSinkChecksumHex;

  /// 64-bit hexadecimal checksum computed on the native accepted side.
  final String nativeAcceptedChecksumHex;

  /// 64-bit hexadecimal checksum computed on the native output read side.
  final String nativeOutputReadChecksumHex;

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

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether the four checksums are non-empty and identical, and
  /// [checksumIdentityOk] is true.
  bool get checksumsMatch =>
      kotlinAcceptedChecksumHex.isNotEmpty &&
      kotlinSinkChecksumHex.isNotEmpty &&
      nativeAcceptedChecksumHex.isNotEmpty &&
      nativeOutputReadChecksumHex.isNotEmpty &&
      kotlinAcceptedChecksumHex == nativeAcceptedChecksumHex &&
      nativeAcceptedChecksumHex == nativeOutputReadChecksumHex &&
      nativeOutputReadChecksumHex == kotlinSinkChecksumHex &&
      checksumIdentityOk;

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
  /// P4-AUDIO-ASYNC-RUNTIME-QUEUE-REALTIME-CLOCK-PACING verification
  /// contract. Backpressure is normal telemetry and never required.
  bool get allNativeLanesPass =>
      pass &&
      status.toLowerCase() == 'pass' &&
      marker == passMarkerConstant &&
      hasCanonicalProofBoundary &&
      formatProbeOk &&
      decoderEosReachedOk &&
      realtimeWorkerClockOwnershipOk &&
      noCallerSuppliedNativeTimeOk &&
      noOwnerThreadDispatchOk &&
      controlCommandSerializationOk &&
      realDecoderIngestOk &&
      checksumIdentityOk &&
      frameAccountingOk &&
      sinkWriteAccountingOk &&
      audioTrackInitOk &&
      mutedOutputOk &&
      playbackHeadTelemetryOk &&
      realtimeNativeElapsedOk &&
      realtimeBacklogBoundOk &&
      seekEpochReanchorOk &&
      seekSinkEpochResetOk &&
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
      realtimeGatesHeld &&
      expectedFrames > 0 &&
      totalFramesAccepted == expectedFrames &&
      totalFramesRendered == expectedFrames &&
      totalFramesPushed == expectedFrames &&
      totalOutputFramesRead == expectedFrames &&
      totalFramesExtracted >= expectedFrames &&
      sinkAccountingBalanced &&
      framesDiscardedInSinkAtSeek >= 0 &&
      playbackHeadDeltaTelemetryOnly > 0 &&
      seekTargetFrame == preSeekFrames &&
      preStartFillFrames >= preStartFillQuotaFrames &&
      silenceCount == 0 &&
      providerFramesZeroFilled == 0 &&
      (lastError.isEmpty || lastError == 'none' || lastError == 'null');

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAsyncRuntimeQueueRealtimeClockSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return _failShapedReport(
        reason: 'native_result_not_a_map',
        details: '',
        lastError: 'native_result_not_a_map',
        proofBoundary: '',
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

    return VGAsyncRuntimeQueueRealtimeClockSmokeReport(
      pass: pass,
      status: parseString('status', pass ? 'pass' : 'fail'),
      marker: parseString(
        'marker',
        pass ? passMarkerConstant : failMarkerConstant,
      ),
      proofBoundary: parseString('proofBoundary'),
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
      realDecoderIngestOk: parseBool('realDecoderIngestOk'),
      checksumIdentityOk: parseBool('checksumIdentityOk'),
      frameAccountingOk: parseBool('frameAccountingOk'),
      sinkWriteAccountingOk: parseBool('sinkWriteAccountingOk'),
      audioTrackInitOk: parseBool('audioTrackInitOk'),
      mutedOutputOk: parseBool('mutedOutputOk'),
      playbackHeadTelemetryOk: parseBool('playbackHeadTelemetryOk'),
      realtimeNativeElapsedOk: parseBool('realtimeNativeElapsedOk'),
      realtimeBacklogBoundOk: parseBool('realtimeBacklogBoundOk'),
      seekEpochReanchorOk: parseBool('seekEpochReanchorOk'),
      seekSinkEpochResetOk: parseBool('seekSinkEpochResetOk'),
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
      nativeRealtimeElapsedMs: parseInt('nativeRealtimeElapsedMs', -1),
      nativeTimingF0: parseInt('nativeTimingF0', -1),
      nativeTimingF1: parseInt('nativeTimingF1', -1),
      maxRenderCursorBacklogUs: parseInt('maxRenderCursorBacklogUs', -1),
      backlogSampleCount: parseInt('backlogSampleCount', -1),
      workerNoFramesDueWaits: parseInt('workerNoFramesDueWaits', -1),
      totalFramesExtracted: parseInt('totalFramesExtracted'),
      totalFramesAccepted: parseInt('totalFramesAccepted'),
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
      audioTimestampAttemptCount: parseInt('audioTimestampAttemptCount'),
      audioTimestampSuccessCount: parseInt('audioTimestampSuccessCount'),
      commandsEnqueued: parseInt('commandsEnqueued', -1),
      commandsProcessed: parseInt('commandsProcessed', -1),
      commandErrors: parseInt('commandErrors', -1),
      dispatchCount: parseInt('dispatchCount', -1),
      silenceCount: parseInt('silenceCount', -1),
      backpressureCount: parseInt('backpressureCount', -1),
      providerFramesZeroFilled: parseInt('providerFramesZeroFilled', -1),
      workerThreadDistinct: parseBool('workerThreadDistinct'),
      ownerDispatchCalls: parseInt('ownerDispatchCalls', -1),
      kotlinAcceptedChecksumHex: parseString('kotlinAcceptedChecksumHex'),
      kotlinSinkChecksumHex: parseString('kotlinSinkChecksumHex'),
      nativeAcceptedChecksumHex: parseString('nativeAcceptedChecksumHex'),
      nativeOutputReadChecksumHex: parseString('nativeOutputReadChecksumHex'),
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

  static VGAsyncRuntimeQueueRealtimeClockSmokeReport _failShapedReport({
    required String reason,
    required String details,
    required String lastError,
    String proofBoundary = proofBoundaryConstant,
  }) {
    return VGAsyncRuntimeQueueRealtimeClockSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundary,
      failureReason: reason,
      details: details,
      formatProbeOk: false,
      decoderEosReachedOk: false,
      realtimeWorkerClockOwnershipOk: false,
      noCallerSuppliedNativeTimeOk: false,
      noOwnerThreadDispatchOk: false,
      controlCommandSerializationOk: false,
      realDecoderIngestOk: false,
      checksumIdentityOk: false,
      frameAccountingOk: false,
      sinkWriteAccountingOk: false,
      audioTrackInitOk: false,
      mutedOutputOk: false,
      playbackHeadTelemetryOk: false,
      realtimeNativeElapsedOk: false,
      realtimeBacklogBoundOk: false,
      seekEpochReanchorOk: false,
      seekSinkEpochResetOk: false,
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
      nativeRealtimeElapsedMs: -1,
      nativeTimingF0: -1,
      nativeTimingF1: -1,
      maxRenderCursorBacklogUs: -1,
      backlogSampleCount: -1,
      workerNoFramesDueWaits: -1,
      totalFramesExtracted: 0,
      totalFramesAccepted: 0,
      totalFramesRendered: -1,
      totalFramesPushed: -1,
      totalOutputFramesRead: 0,
      framesReadFromRing: 0,
      framesWrittenToSink: 0,
      residualFramesAtEnd: -1,
      framesDiscardedInSinkAtSeek: -1,
      playbackHeadDeltaTelemetryOnly: -1,
      underrunDeltaTelemetryOnly: -1,
      audioTimestampAttemptCount: 0,
      audioTimestampSuccessCount: 0,
      commandsEnqueued: -1,
      commandsProcessed: -1,
      commandErrors: -1,
      dispatchCount: -1,
      silenceCount: -1,
      backpressureCount: -1,
      providerFramesZeroFilled: -1,
      workerThreadDistinct: false,
      ownerDispatchCalls: -1,
      kotlinAcceptedChecksumHex: '',
      kotlinSinkChecksumHex: '',
      nativeAcceptedChecksumHex: '',
      nativeOutputReadChecksumHex: '',
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

  /// Invokes the Android True-DAG Phase 4 async runtime queue realtime
  /// worker-owned wall-clock pacing diagnostic smoke harness.
  ///
  /// [sourcePath] must be a readable local media file with an audio track
  /// at least [durationSec] long. Defaults mirror the Kotlin coordinator;
  /// [timeout] bounds the call and is forwarded as `deadlineMs`. [channel]
  /// may be injected for testing. Any MethodChannel error yields an
  /// unsupported/fail-shaped report.
  static Future<VGAsyncRuntimeQueueRealtimeClockSmokeReport>
  runAsyncRuntimeQueueRealtimeClockSmoke({
    required String sourcePath,
    double durationSec = 2.0,
    double seekTargetSec = 1.30,
    double preSeekBudgetSec = 1.20,
    double postSeekBudgetSec = 0.55,
    int sourceRingCapacityFrames = 8192,
    int outputRingCapacityFrames = 4096,
    int maxFramesPerMix = 256,
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
    };
    try {
      final future = ch.invokeMethod<Object?>(methodName, args);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(raw);
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
    return other is VGAsyncRuntimeQueueRealtimeClockSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.formatProbeOk == formatProbeOk &&
        other.decoderEosReachedOk == decoderEosReachedOk &&
        other.realtimeWorkerClockOwnershipOk ==
            realtimeWorkerClockOwnershipOk &&
        other.noCallerSuppliedNativeTimeOk == noCallerSuppliedNativeTimeOk &&
        other.noOwnerThreadDispatchOk == noOwnerThreadDispatchOk &&
        other.controlCommandSerializationOk == controlCommandSerializationOk &&
        other.realDecoderIngestOk == realDecoderIngestOk &&
        other.checksumIdentityOk == checksumIdentityOk &&
        other.frameAccountingOk == frameAccountingOk &&
        other.sinkWriteAccountingOk == sinkWriteAccountingOk &&
        other.audioTrackInitOk == audioTrackInitOk &&
        other.mutedOutputOk == mutedOutputOk &&
        other.playbackHeadTelemetryOk == playbackHeadTelemetryOk &&
        other.realtimeNativeElapsedOk == realtimeNativeElapsedOk &&
        other.realtimeBacklogBoundOk == realtimeBacklogBoundOk &&
        other.seekEpochReanchorOk == seekEpochReanchorOk &&
        other.seekSinkEpochResetOk == seekSinkEpochResetOk &&
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
        other.nativeRealtimeElapsedMs == nativeRealtimeElapsedMs &&
        other.nativeTimingF0 == nativeTimingF0 &&
        other.nativeTimingF1 == nativeTimingF1 &&
        other.maxRenderCursorBacklogUs == maxRenderCursorBacklogUs &&
        other.backlogSampleCount == backlogSampleCount &&
        other.workerNoFramesDueWaits == workerNoFramesDueWaits &&
        other.totalFramesExtracted == totalFramesExtracted &&
        other.totalFramesAccepted == totalFramesAccepted &&
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
        other.audioTimestampAttemptCount == audioTimestampAttemptCount &&
        other.audioTimestampSuccessCount == audioTimestampSuccessCount &&
        other.commandsEnqueued == commandsEnqueued &&
        other.commandsProcessed == commandsProcessed &&
        other.commandErrors == commandErrors &&
        other.dispatchCount == dispatchCount &&
        other.silenceCount == silenceCount &&
        other.backpressureCount == backpressureCount &&
        other.providerFramesZeroFilled == providerFramesZeroFilled &&
        other.workerThreadDistinct == workerThreadDistinct &&
        other.ownerDispatchCalls == ownerDispatchCalls &&
        other.kotlinAcceptedChecksumHex == kotlinAcceptedChecksumHex &&
        other.kotlinSinkChecksumHex == kotlinSinkChecksumHex &&
        other.nativeAcceptedChecksumHex == nativeAcceptedChecksumHex &&
        other.nativeOutputReadChecksumHex == nativeOutputReadChecksumHex &&
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
    failureReason,
    details,
    formatProbeOk,
    decoderEosReachedOk,
    realtimeWorkerClockOwnershipOk,
    noCallerSuppliedNativeTimeOk,
    noOwnerThreadDispatchOk,
    controlCommandSerializationOk,
    realDecoderIngestOk,
    checksumIdentityOk,
    frameAccountingOk,
    sinkWriteAccountingOk,
    audioTrackInitOk,
    mutedOutputOk,
    playbackHeadTelemetryOk,
    realtimeNativeElapsedOk,
    realtimeBacklogBoundOk,
    seekEpochReanchorOk,
    seekSinkEpochResetOk,
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
    nativeRealtimeElapsedMs,
    nativeTimingF0,
    nativeTimingF1,
    maxRenderCursorBacklogUs,
    backlogSampleCount,
    workerNoFramesDueWaits,
    totalFramesExtracted,
    totalFramesAccepted,
    totalFramesRendered,
    totalFramesPushed,
    totalOutputFramesRead,
    framesReadFromRing,
    framesWrittenToSink,
    residualFramesAtEnd,
    framesDiscardedInSinkAtSeek,
    playbackHeadDeltaTelemetryOnly,
    underrunDeltaTelemetryOnly,
    audioTimestampAttemptCount,
    audioTimestampSuccessCount,
    commandsEnqueued,
    commandsProcessed,
    commandErrors,
    dispatchCount,
    silenceCount,
    backpressureCount,
    providerFramesZeroFilled,
    workerThreadDistinct,
    ownerDispatchCalls,
    kotlinAcceptedChecksumHex,
    kotlinSinkChecksumHex,
    nativeAcceptedChecksumHex,
    nativeOutputReadChecksumHex,
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
      'VGAsyncRuntimeQueueRealtimeClockSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'formatProbeOk: $formatProbeOk, '
      'decoderEosReachedOk: $decoderEosReachedOk, '
      'realtimeWorkerClockOwnershipOk: $realtimeWorkerClockOwnershipOk, '
      'noCallerSuppliedNativeTimeOk: $noCallerSuppliedNativeTimeOk, '
      'noOwnerThreadDispatchOk: $noOwnerThreadDispatchOk, '
      'controlCommandSerializationOk: $controlCommandSerializationOk, '
      'realDecoderIngestOk: $realDecoderIngestOk, '
      'checksumIdentityOk: $checksumIdentityOk, '
      'frameAccountingOk: $frameAccountingOk, '
      'sinkWriteAccountingOk: $sinkWriteAccountingOk, '
      'audioTrackInitOk: $audioTrackInitOk, '
      'mutedOutputOk: $mutedOutputOk, '
      'playbackHeadTelemetryOk: $playbackHeadTelemetryOk, '
      'realtimeNativeElapsedOk: $realtimeNativeElapsedOk, '
      'realtimeBacklogBoundOk: $realtimeBacklogBoundOk, '
      'seekEpochReanchorOk: $seekEpochReanchorOk, '
      'seekSinkEpochResetOk: $seekSinkEpochResetOk, '
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
      'nativeRealtimeElapsedMs: $nativeRealtimeElapsedMs, '
      'nativeTimingF0: $nativeTimingF0, '
      'nativeTimingF1: $nativeTimingF1, '
      'maxRenderCursorBacklogUs: $maxRenderCursorBacklogUs, '
      'workerNoFramesDueWaits: $workerNoFramesDueWaits, '
      'totalFramesAccepted: $totalFramesAccepted, '
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
      'backpressureCount: $backpressureCount, '
      'providerFramesZeroFilled: $providerFramesZeroFilled, '
      'workerThreadDistinct: $workerThreadDistinct, '
      'ownerDispatchCalls: $ownerDispatchCalls, '
      'kotlinAcceptedChecksumHex: $kotlinAcceptedChecksumHex, '
      'kotlinSinkChecksumHex: $kotlinSinkChecksumHex, '
      'nativeAcceptedChecksumHex: $nativeAcceptedChecksumHex, '
      'nativeOutputReadChecksumHex: $nativeOutputReadChecksumHex, '
      'lastError: $lastError)';
}
