// vg_async_runtime_queue_real_decoder_smoke.dart
// vanguard_media_engine - P4-AUDIO-ASYNC-RUNTIME-QUEUE-REAL-DECODER: Android
// True-DAG Phase 4 real MediaExtractor/MediaCodec decoder to async runtime
// queue scheduler diagnostic smoke foundation (under
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice X1).
//
// Pure Dart typed model + invocation wrapper over the native
// `runAsyncRuntimeQueueRealDecoderSmoke` MethodChannel route.
// Diagnostic-only: validates that a Kotlin-owned real synchronous
// MediaExtractor/MediaCodec PCM16 decode can feed the verified native async
// runtime queue scheduler session, with the native worker thread remaining
// the sole caller of the AudioClock mutators, the
// ClockedAudioTransportCoordinator control/dispatch path, and the
// output-ring producer role.
//
// Honest non-claims (Proof Boundary):
// kotlin_owned_real_decoder_to_async_runtime_queue_scheduler_proof_only_mediaextractor_mediacodec_sync_decode_owner_thread_to_native_async_worker_queue_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_media_time_worker_owned_clock_coordinator_output_ring_source_ring_spsc_caller_derived_accepted_frame_axis_ticks_only_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_audible_output_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_product_editor_app_wiring_no_export_route_changes_no_streaming_cache_no_ios_writer_local_eos_only_zero_fill_not_in_identity

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAsyncRuntimeQueueRealDecoderSmokeReport.runAsyncRuntimeQueueRealDecoderSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGAsyncRuntimeQueueRealDecoderSmokeReport {
  const VGAsyncRuntimeQueueRealDecoderSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.details,
    required this.formatProbeOk,
    required this.decoderEosReachedOk,
    required this.asyncWorkerOwnershipOk,
    required this.controlCommandSerializationOk,
    required this.realDecoderIngestOk,
    required this.sourceBackpressureRetryOk,
    required this.outputBackpressureOk,
    required this.checksumIdentityOk,
    required this.frameAccountingOk,
    required this.seekEpochReanchorOk,
    required this.noOwnerThreadDispatchOk,
    required this.foreignThreadRejectedOk,
    required this.workerJoinOnDestroyOk,
    required this.idempotentDestroyOk,
    required this.canonicalProofBoundaryOk,
    required this.sampleRate,
    required this.channelCount,
    required this.pcmEncoding,
    required this.expectedFrames,
    required this.preSeekFrames,
    required this.postSeekFrames,
    required this.seekTargetFrame,
    required this.totalFramesExtracted,
    required this.totalFramesAccepted,
    required this.totalFramesRendered,
    required this.totalFramesPushed,
    required this.totalOutputFramesRead,
    required this.framesTruncatedAtSeekBoundary,
    required this.framesDiscardedAfterBudget,
    required this.commandsEnqueued,
    required this.commandsProcessed,
    required this.commandErrors,
    required this.dispatchCount,
    required this.silenceCount,
    required this.backpressureCount,
    required this.writerBackpressureRejects,
    required this.providerFramesZeroFilled,
    required this.workerThreadDistinct,
    required this.ownerDispatchCalls,
    required this.kotlinAcceptedChecksumHex,
    required this.nativeAcceptedChecksumHex,
    required this.nativeOutputReadChecksumHex,
    required this.lanes,
    required this.metrics,
    required this.raw,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName = 'runAsyncRuntimeQueueRealDecoderSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_SMOKE_FAIL';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'kotlin_owned_real_decoder_to_async_runtime_queue_scheduler_proof_only_mediaextractor_mediacodec_sync_decode_owner_thread_to_native_async_worker_queue_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_media_time_worker_owned_clock_coordinator_output_ring_source_ring_spsc_caller_derived_accepted_frame_axis_ticks_only_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_audible_output_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_product_editor_app_wiring_no_export_route_changes_no_streaming_cache_no_ios_writer_local_eos_only_zero_fill_not_in_identity';

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

  // ---- Lanes (15 lanes) ---------------------------------------------------

  /// Whether the decoder output format resolved to PCM16 with 1-2 channels
  /// and a valid sample rate before the async session was created.
  final bool formatProbeOk;

  /// Whether the post-seek decode ran the codec out to a real output EOS.
  final bool decoderEosReachedOk;

  /// Whether the native worker thread was distinct, booted before any
  /// ingest, performed every dispatch, and finished with zero anomalies.
  final bool asyncWorkerOwnershipOk;

  /// Whether all four control commands (start/pause/resume/seek) were
  /// queue-serialized and executed in order with zero command errors.
  final bool controlCommandSerializationOk;

  /// Whether the real decoder supplied the entire frozen expected timeline
  /// into the source ring.
  final bool realDecoderIngestOk;

  /// Whether the paused source-ring fill produced a deterministic writer
  /// ring_full reject whose window was later retried losslessly.
  final bool sourceBackpressureRetryOk;

  /// Whether the worker recorded output-ring backpressure at exactly the
  /// ring capacity without overrunning the SPSC ring.
  final bool outputBackpressureOk;

  /// Whether Kotlin accepted, native accepted, and native output read
  /// checksums are identical with zero provider zero-fill/underrun/silence.
  final bool checksumIdentityOk;

  /// Whether accepted/rendered/pushed/read frame totals all equal the
  /// frozen expected timeline with zero skips or rewind rejects.
  final bool frameAccountingOk;

  /// Whether the pre-EOS forward seek re-anchored at exactly the accepted
  /// frame boundary with a cleanly consumed output ack and zero discards.
  final bool seekEpochReanchorOk;

  /// Whether the owner thread performed zero dispatch calls.
  final bool noOwnerThreadDispatchOk;

  /// Whether a deliberate foreign-thread call was rejected by native with
  /// wrong_owner_thread.
  final bool foreignThreadRejectedOk;

  /// Whether destroy set the stop flag, woke, and JOINED the worker.
  final bool workerJoinOnDestroyOk;

  /// Whether a second destroy and post-destroy snapshot returned not_found.
  final bool idempotentDestroyOk;

  /// Whether the native snapshot carried the verified async session TU's
  /// canonical proof boundary verbatim.
  final bool canonicalProofBoundaryOk;

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

  /// Total decoded frames produced by the codec (including truncated and
  /// discarded frames that never entered the proof stream).
  final int totalFramesExtracted;

  /// Total frames accepted into the source ring.
  final int totalFramesAccepted;

  /// Total frames rendered by the native worker.
  final int totalFramesRendered;

  /// Total frames pushed into the output ring by the worker.
  final int totalFramesPushed;

  /// Total frames read back by the owner thread.
  final int totalOutputFramesRead;

  /// Decoded frames honestly truncated (never ingested) at the aligned
  /// pre-seek budget boundary.
  final int framesTruncatedAtSeekBoundary;

  /// Decoded frames honestly discarded (never ingested) during the
  /// post-budget codec EOS run-out.
  final int framesDiscardedAfterBudget;

  /// Total control commands enqueued by the owner thread (must be 4).
  final int commandsEnqueued;

  /// Total control commands executed by the worker thread (must be 4).
  final int commandsProcessed;

  /// Worker-side command execution errors (must be 0).
  final int commandErrors;

  /// Worker dispatch count over the session.
  final int dispatchCount;

  /// Coordinator silence windows (must be 0).
  final int silenceCount;

  /// Coordinator output-ring backpressure records (must be >= 1).
  final int backpressureCount;

  /// Source-ring writer backpressure rejects (must be >= 1).
  final int writerBackpressureRejects;

  /// Provider zero-filled frames (must be 0 — never in identity).
  final int providerFramesZeroFilled;

  /// Whether the native worker thread id differs from the owner thread id.
  final bool workerThreadDistinct;

  /// Owner-side dispatch call count (structurally 0).
  final int ownerDispatchCalls;

  /// 64-bit hexadecimal checksum computed on the Kotlin accepted side.
  final String kotlinAcceptedChecksumHex;

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

  /// Whether the three checksums are non-empty and identical, and
  /// [checksumIdentityOk] is true.
  bool get checksumsMatch =>
      kotlinAcceptedChecksumHex.isNotEmpty &&
      nativeAcceptedChecksumHex.isNotEmpty &&
      nativeOutputReadChecksumHex.isNotEmpty &&
      kotlinAcceptedChecksumHex == nativeAcceptedChecksumHex &&
      nativeAcceptedChecksumHex == nativeOutputReadChecksumHex &&
      checksumIdentityOk;

  /// Whether all native diagnostic lanes passed according to the
  /// P4-AUDIO-ASYNC-RUNTIME-QUEUE-REAL-DECODER verification contract.
  bool get allNativeLanesPass =>
      pass &&
      status.toLowerCase() == 'pass' &&
      marker == passMarkerConstant &&
      hasCanonicalProofBoundary &&
      formatProbeOk &&
      decoderEosReachedOk &&
      asyncWorkerOwnershipOk &&
      controlCommandSerializationOk &&
      realDecoderIngestOk &&
      sourceBackpressureRetryOk &&
      outputBackpressureOk &&
      checksumIdentityOk &&
      frameAccountingOk &&
      seekEpochReanchorOk &&
      noOwnerThreadDispatchOk &&
      foreignThreadRejectedOk &&
      workerJoinOnDestroyOk &&
      idempotentDestroyOk &&
      canonicalProofBoundaryOk &&
      workerThreadDistinct &&
      ownerDispatchCalls == 0 &&
      commandsEnqueued == 4 &&
      commandsProcessed == 4 &&
      commandErrors == 0 &&
      checksumsMatch &&
      expectedFrames > 0 &&
      totalFramesAccepted == expectedFrames &&
      totalFramesRendered == expectedFrames &&
      totalFramesPushed == expectedFrames &&
      totalOutputFramesRead == expectedFrames &&
      totalFramesExtracted >= expectedFrames &&
      seekTargetFrame == preSeekFrames &&
      silenceCount == 0 &&
      providerFramesZeroFilled == 0 &&
      backpressureCount >= 1 &&
      writerBackpressureRejects >= 1 &&
      (lastError.isEmpty || lastError == 'none' || lastError == 'null');

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAsyncRuntimeQueueRealDecoderSmokeReport fromMap(Object? raw) {
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

    return VGAsyncRuntimeQueueRealDecoderSmokeReport(
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
      asyncWorkerOwnershipOk: parseBool('asyncWorkerOwnershipOk'),
      controlCommandSerializationOk: parseBool('controlCommandSerializationOk'),
      realDecoderIngestOk: parseBool('realDecoderIngestOk'),
      sourceBackpressureRetryOk: parseBool('sourceBackpressureRetryOk'),
      outputBackpressureOk: parseBool('outputBackpressureOk'),
      checksumIdentityOk: parseBool('checksumIdentityOk'),
      frameAccountingOk: parseBool('frameAccountingOk'),
      seekEpochReanchorOk: parseBool('seekEpochReanchorOk'),
      noOwnerThreadDispatchOk: parseBool('noOwnerThreadDispatchOk'),
      foreignThreadRejectedOk: parseBool('foreignThreadRejectedOk'),
      workerJoinOnDestroyOk: parseBool('workerJoinOnDestroyOk'),
      idempotentDestroyOk: parseBool('idempotentDestroyOk'),
      canonicalProofBoundaryOk: parseBool('canonicalProofBoundaryOk'),
      sampleRate: parseInt('sampleRate'),
      channelCount: parseInt('channelCount'),
      pcmEncoding: parseInt('pcmEncoding'),
      expectedFrames: parseInt('expectedFrames'),
      preSeekFrames: parseInt('preSeekFrames'),
      postSeekFrames: parseInt('postSeekFrames'),
      seekTargetFrame: parseInt('seekTargetFrame', -1),
      totalFramesExtracted: parseInt('totalFramesExtracted'),
      totalFramesAccepted: parseInt('totalFramesAccepted'),
      totalFramesRendered: parseInt('totalFramesRendered', -1),
      totalFramesPushed: parseInt('totalFramesPushed', -1),
      totalOutputFramesRead: parseInt('totalOutputFramesRead'),
      framesTruncatedAtSeekBoundary: parseInt('framesTruncatedAtSeekBoundary'),
      framesDiscardedAfterBudget: parseInt('framesDiscardedAfterBudget'),
      commandsEnqueued: parseInt('commandsEnqueued', -1),
      commandsProcessed: parseInt('commandsProcessed', -1),
      commandErrors: parseInt('commandErrors', -1),
      dispatchCount: parseInt('dispatchCount', -1),
      silenceCount: parseInt('silenceCount', -1),
      backpressureCount: parseInt('backpressureCount', -1),
      writerBackpressureRejects: parseInt('writerBackpressureRejects', -1),
      providerFramesZeroFilled: parseInt('providerFramesZeroFilled', -1),
      workerThreadDistinct: parseBool('workerThreadDistinct'),
      ownerDispatchCalls: parseInt('ownerDispatchCalls', -1),
      kotlinAcceptedChecksumHex: parseString('kotlinAcceptedChecksumHex'),
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

  static VGAsyncRuntimeQueueRealDecoderSmokeReport _failShapedReport({
    required String reason,
    required String details,
    required String lastError,
    String proofBoundary = proofBoundaryConstant,
  }) {
    return VGAsyncRuntimeQueueRealDecoderSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundary,
      failureReason: reason,
      details: details,
      formatProbeOk: false,
      decoderEosReachedOk: false,
      asyncWorkerOwnershipOk: false,
      controlCommandSerializationOk: false,
      realDecoderIngestOk: false,
      sourceBackpressureRetryOk: false,
      outputBackpressureOk: false,
      checksumIdentityOk: false,
      frameAccountingOk: false,
      seekEpochReanchorOk: false,
      noOwnerThreadDispatchOk: false,
      foreignThreadRejectedOk: false,
      workerJoinOnDestroyOk: false,
      idempotentDestroyOk: false,
      canonicalProofBoundaryOk: false,
      sampleRate: 0,
      channelCount: 0,
      pcmEncoding: 0,
      expectedFrames: 0,
      preSeekFrames: 0,
      postSeekFrames: 0,
      seekTargetFrame: -1,
      totalFramesExtracted: 0,
      totalFramesAccepted: 0,
      totalFramesRendered: -1,
      totalFramesPushed: -1,
      totalOutputFramesRead: 0,
      framesTruncatedAtSeekBoundary: 0,
      framesDiscardedAfterBudget: 0,
      commandsEnqueued: -1,
      commandsProcessed: -1,
      commandErrors: -1,
      dispatchCount: -1,
      silenceCount: -1,
      backpressureCount: -1,
      writerBackpressureRejects: -1,
      providerFramesZeroFilled: -1,
      workerThreadDistinct: false,
      ownerDispatchCalls: -1,
      kotlinAcceptedChecksumHex: '',
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

  /// Invokes the Android True-DAG Phase 4 real decoder to async runtime
  /// queue scheduler diagnostic smoke harness.
  ///
  /// [sourcePath] must be a readable local media file with an audio track.
  /// Defaults mirror the Kotlin coordinator; [timeout] bounds the call and
  /// is forwarded as `deadlineMs`. [channel] may be injected for testing.
  /// Any MethodChannel error yields an unsupported/fail-shaped report.
  static Future<VGAsyncRuntimeQueueRealDecoderSmokeReport>
  runAsyncRuntimeQueueRealDecoderSmoke({
    required String sourcePath,
    double durationSec = 1.0,
    double seekTargetSec = 0.35,
    double preSeekBudgetSec = 0.25,
    double postSeekBudgetSec = 0.30,
    int sourceRingCapacityFrames = 2048,
    int outputRingCapacityFrames = 1024,
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
      return VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(raw);
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
    return other is VGAsyncRuntimeQueueRealDecoderSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.formatProbeOk == formatProbeOk &&
        other.decoderEosReachedOk == decoderEosReachedOk &&
        other.asyncWorkerOwnershipOk == asyncWorkerOwnershipOk &&
        other.controlCommandSerializationOk == controlCommandSerializationOk &&
        other.realDecoderIngestOk == realDecoderIngestOk &&
        other.sourceBackpressureRetryOk == sourceBackpressureRetryOk &&
        other.outputBackpressureOk == outputBackpressureOk &&
        other.checksumIdentityOk == checksumIdentityOk &&
        other.frameAccountingOk == frameAccountingOk &&
        other.seekEpochReanchorOk == seekEpochReanchorOk &&
        other.noOwnerThreadDispatchOk == noOwnerThreadDispatchOk &&
        other.foreignThreadRejectedOk == foreignThreadRejectedOk &&
        other.workerJoinOnDestroyOk == workerJoinOnDestroyOk &&
        other.idempotentDestroyOk == idempotentDestroyOk &&
        other.canonicalProofBoundaryOk == canonicalProofBoundaryOk &&
        other.sampleRate == sampleRate &&
        other.channelCount == channelCount &&
        other.pcmEncoding == pcmEncoding &&
        other.expectedFrames == expectedFrames &&
        other.preSeekFrames == preSeekFrames &&
        other.postSeekFrames == postSeekFrames &&
        other.seekTargetFrame == seekTargetFrame &&
        other.totalFramesExtracted == totalFramesExtracted &&
        other.totalFramesAccepted == totalFramesAccepted &&
        other.totalFramesRendered == totalFramesRendered &&
        other.totalFramesPushed == totalFramesPushed &&
        other.totalOutputFramesRead == totalOutputFramesRead &&
        other.framesTruncatedAtSeekBoundary == framesTruncatedAtSeekBoundary &&
        other.framesDiscardedAfterBudget == framesDiscardedAfterBudget &&
        other.commandsEnqueued == commandsEnqueued &&
        other.commandsProcessed == commandsProcessed &&
        other.commandErrors == commandErrors &&
        other.dispatchCount == dispatchCount &&
        other.silenceCount == silenceCount &&
        other.backpressureCount == backpressureCount &&
        other.writerBackpressureRejects == writerBackpressureRejects &&
        other.providerFramesZeroFilled == providerFramesZeroFilled &&
        other.workerThreadDistinct == workerThreadDistinct &&
        other.ownerDispatchCalls == ownerDispatchCalls &&
        other.kotlinAcceptedChecksumHex == kotlinAcceptedChecksumHex &&
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
    asyncWorkerOwnershipOk,
    controlCommandSerializationOk,
    realDecoderIngestOk,
    sourceBackpressureRetryOk,
    outputBackpressureOk,
    checksumIdentityOk,
    frameAccountingOk,
    seekEpochReanchorOk,
    noOwnerThreadDispatchOk,
    foreignThreadRejectedOk,
    workerJoinOnDestroyOk,
    idempotentDestroyOk,
    canonicalProofBoundaryOk,
    sampleRate,
    channelCount,
    pcmEncoding,
    expectedFrames,
    preSeekFrames,
    postSeekFrames,
    seekTargetFrame,
    totalFramesExtracted,
    totalFramesAccepted,
    totalFramesRendered,
    totalFramesPushed,
    totalOutputFramesRead,
    framesTruncatedAtSeekBoundary,
    framesDiscardedAfterBudget,
    commandsEnqueued,
    commandsProcessed,
    commandErrors,
    dispatchCount,
    silenceCount,
    backpressureCount,
    writerBackpressureRejects,
    providerFramesZeroFilled,
    workerThreadDistinct,
    ownerDispatchCalls,
    kotlinAcceptedChecksumHex,
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
      'VGAsyncRuntimeQueueRealDecoderSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'formatProbeOk: $formatProbeOk, '
      'decoderEosReachedOk: $decoderEosReachedOk, '
      'asyncWorkerOwnershipOk: $asyncWorkerOwnershipOk, '
      'controlCommandSerializationOk: $controlCommandSerializationOk, '
      'realDecoderIngestOk: $realDecoderIngestOk, '
      'sourceBackpressureRetryOk: $sourceBackpressureRetryOk, '
      'outputBackpressureOk: $outputBackpressureOk, '
      'checksumIdentityOk: $checksumIdentityOk, '
      'frameAccountingOk: $frameAccountingOk, '
      'seekEpochReanchorOk: $seekEpochReanchorOk, '
      'noOwnerThreadDispatchOk: $noOwnerThreadDispatchOk, '
      'foreignThreadRejectedOk: $foreignThreadRejectedOk, '
      'workerJoinOnDestroyOk: $workerJoinOnDestroyOk, '
      'idempotentDestroyOk: $idempotentDestroyOk, '
      'canonicalProofBoundaryOk: $canonicalProofBoundaryOk, '
      'sampleRate: $sampleRate, '
      'channelCount: $channelCount, '
      'expectedFrames: $expectedFrames, '
      'preSeekFrames: $preSeekFrames, '
      'postSeekFrames: $postSeekFrames, '
      'seekTargetFrame: $seekTargetFrame, '
      'totalFramesExtracted: $totalFramesExtracted, '
      'totalFramesAccepted: $totalFramesAccepted, '
      'totalFramesRendered: $totalFramesRendered, '
      'totalFramesPushed: $totalFramesPushed, '
      'totalOutputFramesRead: $totalOutputFramesRead, '
      'framesTruncatedAtSeekBoundary: $framesTruncatedAtSeekBoundary, '
      'framesDiscardedAfterBudget: $framesDiscardedAfterBudget, '
      'commandsEnqueued: $commandsEnqueued, '
      'commandsProcessed: $commandsProcessed, '
      'commandErrors: $commandErrors, '
      'dispatchCount: $dispatchCount, '
      'silenceCount: $silenceCount, '
      'backpressureCount: $backpressureCount, '
      'writerBackpressureRejects: $writerBackpressureRejects, '
      'providerFramesZeroFilled: $providerFramesZeroFilled, '
      'workerThreadDistinct: $workerThreadDistinct, '
      'ownerDispatchCalls: $ownerDispatchCalls, '
      'kotlinAcceptedChecksumHex: $kotlinAcceptedChecksumHex, '
      'nativeAcceptedChecksumHex: $nativeAcceptedChecksumHex, '
      'nativeOutputReadChecksumHex: $nativeOutputReadChecksumHex, '
      'lastError: $lastError)';
}
