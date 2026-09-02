// vg_realtime_playback_pipeline_pause_resume_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-PAUSE-RESUME (Y6b): Android True-DAG Phase 4
// realtime playback pipeline pause/resume diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runRealtimePlaybackPipelinePauseResumeSmoke` MethodChannel route.
// Diagnostic-only - validates real MediaExtractor / MediaCodec synchronous
// PCM16 decode feeding into the Y5a external ingest seam, native Y1 transport,
// and non-zero-gain AudioTrack sink with deterministic pause/resume ordering:
// sink park -> transport pause -> frozen hold -> sink unpark -> transport resume -> EOS.
//
// Required proof lanes (16 native gates + proofBoundaryOk + canonical = 18 total):
//   1. formatProbeOk: format, duration, channel count, sample rate, and MIME probed successfully
//   2. preRollOk: pre-roll while PREPARED until ring_full or declared end fits
//   3. initialDrainOk: positive initial sink writes before park/pause
//   4. sinkParkAckOk: sink parked acked on sink thread with AudioTrack.pause()
//   5. pauseCommandOk: transport.pause() accepted and state moved to PAUSED
//   6. sinkPausedOk: AudioTrack PLAYSTATE_PAUSED held with zero violations
//   7. pauseHoldFrozenOk: hold frozen with zero native dispatches/pushes/drains/writes
//   8. resumeCommandOk: transport.resume() accepted and state moved to PLAYING
//   9. sinkResumedOk: sink unpark acked on sink thread with AudioTrack.play()
//  10. postResumeDrainOk: sink drained and progressed post-resume to EOS
//  11. sinkWriteAccountingOk: exact frames read from transport and written to sink
//  12. checksumIdentityOk: decoder, native pushed, native drained, and sink checksums match
//  13. playbackHeadAdvancedOk: playback head advanced past post-unpark position
//  14. transportCompletedOk: transport completed cleanly with lastError none
//  15. threadOwnershipOk: strict thread ownership across decode, transport, and sink threads
//  16. lifecycleDisposeOk: clean media and AudioTrack release, idempotent state machine dispose
//
// Honest non-claims (Proof Boundary):
// realtime_playback_pipeline_pause_resume_diagnostic_only_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_single_track_forward_playthrough_pause_resume_only_sink_park_before_transport_pause_sink_unpark_before_transport_resume_no_seek_no_flush_no_feed_reanchor_no_presentation_clock_no_av_sync_no_interactive_controls_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_product_no_editor_no_app_wiring_no_ios_no_streaming_no_cache_no_cpp_changes

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGRealtimePlaybackPipelinePauseResumeSmokeReport.runRealtimePlaybackPipelinePauseResumeSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGRealtimePlaybackPipelinePauseResumeSmokeReport {
  const VGRealtimePlaybackPipelinePauseResumeSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.nativeProofBoundary,
    required this.failureReason,
    required this.details,
    required this.formatProbeOk,
    required this.preRollOk,
    required this.initialDrainOk,
    required this.sinkParkAckOk,
    required this.pauseCommandOk,
    required this.sinkPausedOk,
    required this.pauseHoldFrozenOk,
    required this.resumeCommandOk,
    required this.sinkResumedOk,
    required this.postResumeDrainOk,
    required this.sinkWriteAccountingOk,
    required this.checksumIdentityOk,
    required this.playbackHeadAdvancedOk,
    required this.transportCompletedOk,
    required this.threadOwnershipOk,
    required this.lifecycleDisposeOk,
    required this.proofBoundaryOk,
    required this.canonical,
    required this.lanes,
    required this.metrics,
    this.lastError = '',
    this.raw = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runRealtimePlaybackPipelinePauseResumeSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_PHYSICAL_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_PHYSICAL_SMOKE_FAIL';

  /// Canonical start marker string.
  static const String startMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_SMOKE_START';

  /// Canonical JSON prefix marker string.
  static const String jsonMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_JSON';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'realtime_playback_pipeline_pause_resume_diagnostic_only_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_single_track_forward_playthrough_pause_resume_only_sink_park_before_transport_pause_sink_unpark_before_transport_resume_no_seek_no_flush_no_feed_reanchor_no_presentation_clock_no_av_sync_no_interactive_controls_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_product_no_editor_no_app_wiring_no_ios_no_streaming_no_cache_no_cpp_changes';

  /// All required native gate keys that must be present and evaluate to true.
  static const List<String> requiredGateKeys = <String>[
    'formatProbeOk',
    'preRollOk',
    'initialDrainOk',
    'sinkParkAckOk',
    'pauseCommandOk',
    'sinkPausedOk',
    'pauseHoldFrozenOk',
    'resumeCommandOk',
    'sinkResumedOk',
    'postResumeDrainOk',
    'sinkWriteAccountingOk',
    'checksumIdentityOk',
    'playbackHeadAdvancedOk',
    'transportCompletedOk',
    'threadOwnershipOk',
    'lifecycleDisposeOk',
  ];

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// Status string (e.g. 'pass', 'fail', or fail-closed reason token).
  final String status;

  /// Diagnostic marker string.
  final String marker;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// Native proof boundary string.
  final String nativeProofBoundary;

  /// Failure reason token, if any.
  final String failureReason;

  /// Auxiliary execution details or trace breadcrumbs.
  final String details;

  // ---- Gates --------------------------------------------------------------

  /// Whether extractor probed format, duration, channel count, sample rate, and MIME.
  final bool formatProbeOk;

  /// Whether pre-roll completed while PREPARED until ring_full or stream end.
  final bool preRollOk;

  /// Whether initial sink writes and playback occurred before park/pause.
  final bool initialDrainOk;

  /// Whether sink park was acknowledged on the sink thread with AudioTrack.pause().
  final bool sinkParkAckOk;

  /// Whether transport pause command was accepted and state moved to PAUSED.
  final bool pauseCommandOk;

  /// Whether sink observed AudioTrack PLAYSTATE_PAUSED with zero violations.
  final bool sinkPausedOk;

  /// Whether hold remained frozen with zero native/sink activity delta.
  final bool pauseHoldFrozenOk;

  /// Whether transport resume command was accepted and state moved to PLAYING.
  final bool resumeCommandOk;

  /// Whether sink unpark was acknowledged on the sink thread with AudioTrack.play().
  final bool sinkResumedOk;

  /// Whether sink drained and progressed post-resume to EOS.
  final bool postResumeDrainOk;

  /// Whether sink write accounting matched declared frame counts.
  final bool sinkWriteAccountingOk;

  /// Whether decoder, native pushed, native drained, and sink checksums matched identically.
  final bool checksumIdentityOk;

  /// Whether playback head progression advanced post-unpark.
  final bool playbackHeadAdvancedOk;

  /// Whether transport completed into State.COMPLETED cleanly.
  final bool transportCompletedOk;

  /// Whether strict thread ownership across decode, transport, and sink threads held.
  final bool threadOwnershipOk;

  /// Whether lifecycle dispose released media, AudioTrack, and joined threads cleanly.
  final bool lifecycleDisposeOk;

  /// Whether proof boundary matched on native side.
  final bool proofBoundaryOk;

  /// Canonical pass indicator.
  final bool canonical;

  /// Nested lanes map emitted by native smoke execution.
  final Map<String, Object?> lanes;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Last error string from native execution, if any.
  final String lastError;

  /// Raw telemetry payload string.
  final String raw;

  // ---- Getters ------------------------------------------------------------

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary =>
      proofBoundary == proofBoundaryConstant &&
      (nativeProofBoundary.isEmpty ||
          nativeProofBoundary == proofBoundaryConstant);

  /// Whether [marker] matches the canonical pass marker constant.
  bool get hasPassMarker => marker == passMarkerConstant;

  /// Whether [marker] matches the canonical fail marker constant.
  bool get hasFailMarker => marker == failMarkerConstant;

  /// Independent computation of verified pass.
  /// Requires pass==true, status=='pass', canonical PASS marker, exact proof boundary,
  /// empty failureReason, and every required gate true.
  bool get isVerifiedPass =>
      pass == true &&
      status.trim().toLowerCase() == 'pass' &&
      hasPassMarker &&
      hasCanonicalProofBoundary &&
      failureReason.isEmpty &&
      formatProbeOk &&
      preRollOk &&
      initialDrainOk &&
      sinkParkAckOk &&
      pauseCommandOk &&
      sinkPausedOk &&
      pauseHoldFrozenOk &&
      resumeCommandOk &&
      sinkResumedOk &&
      postResumeDrainOk &&
      sinkWriteAccountingOk &&
      checksumIdentityOk &&
      playbackHeadAdvancedOk &&
      transportCompletedOk &&
      threadOwnershipOk &&
      lifecycleDisposeOk;

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGRealtimePlaybackPipelinePauseResumeSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGRealtimePlaybackPipelinePauseResumeSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        nativeProofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        formatProbeOk: false,
        preRollOk: false,
        initialDrainOk: false,
        sinkParkAckOk: false,
        pauseCommandOk: false,
        sinkPausedOk: false,
        pauseHoldFrozenOk: false,
        resumeCommandOk: false,
        sinkResumedOk: false,
        postResumeDrainOk: false,
        sinkWriteAccountingOk: false,
        checksumIdentityOk: false,
        playbackHeadAdvancedOk: false,
        transportCompletedOk: false,
        threadOwnershipOk: false,
        lifecycleDisposeOk: false,
        proofBoundaryOk: false,
        canonical: false,
        lanes: <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
        },
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
        },
        lastError: 'native_result_not_a_map',
        raw:
            'pass=false;status=fail;marker=$failMarkerConstant;reason=native_result_not_a_map',
      );
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

    bool? parseBoolStrict(String key) {
      final v = parsedLanes[key] ?? raw[key] ?? parsedMetrics[key];
      if (v is bool) return v;
      if (v is String) {
        final lower = v.trim().toLowerCase();
        if (lower == 'true' ||
            lower == 'pass' ||
            lower == 'ok' ||
            lower == 'success') {
          return true;
        }
        if (lower == 'false' || lower == 'fail') {
          return false;
        }
      }
      return null;
    }

    bool parseBool(String key, [bool defaultValue = false]) {
      return parseBoolStrict(key) ?? defaultValue;
    }

    String parseString(String key, [String defaultValue = '']) {
      final v = raw[key] ?? parsedMetrics[key] ?? parsedLanes[key];
      if (v != null) return v.toString();
      return defaultValue;
    }

    final rawPass = parseBool('pass');
    final rawStatus = parseString('status', rawPass ? 'pass' : 'fail');
    final rawMarker = parseString(
      'marker',
      rawPass ? passMarkerConstant : failMarkerConstant,
    );
    final proofBoundary = parseString('proofBoundary');
    final nativeProofBoundary = parseString(
      'nativeProofBoundary',
      proofBoundary,
    );
    final failureReason = parseString('failureReason');
    final details = parseString('details');
    final rawString = parseString(
      'raw',
      'pass=$rawPass;status=$rawStatus;marker=$rawMarker',
    );

    final missingGates = <String>[];
    for (final gateKey in requiredGateKeys) {
      if (parseBoolStrict(gateKey) == null) {
        missingGates.add(gateKey);
      }
    }

    final formatProbeOk = parseBool('formatProbeOk');
    final preRollOk = parseBool('preRollOk');
    final initialDrainOk = parseBool('initialDrainOk');
    final sinkParkAckOk = parseBool('sinkParkAckOk');
    final pauseCommandOk = parseBool('pauseCommandOk');
    final sinkPausedOk = parseBool('sinkPausedOk');
    final pauseHoldFrozenOk = parseBool('pauseHoldFrozenOk');
    final resumeCommandOk = parseBool('resumeCommandOk');
    final sinkResumedOk = parseBool('sinkResumedOk');
    final postResumeDrainOk = parseBool('postResumeDrainOk');
    final sinkWriteAccountingOk = parseBool('sinkWriteAccountingOk');
    final checksumIdentityOk = parseBool('checksumIdentityOk');
    final playbackHeadAdvancedOk = parseBool('playbackHeadAdvancedOk');
    final transportCompletedOk = parseBool('transportCompletedOk');
    final threadOwnershipOk = parseBool('threadOwnershipOk');
    final lifecycleDisposeOk = parseBool('lifecycleDisposeOk');
    final proofBoundaryOk = parseBool('proofBoundaryOk');
    final canonical = parseBool('canonical', rawPass && missingGates.isEmpty);

    final hasValidProofBoundary =
        proofBoundary == proofBoundaryConstant &&
        (nativeProofBoundary.isEmpty ||
            nativeProofBoundary == proofBoundaryConstant);
    final hasValidPassMarker = rawMarker == passMarkerConstant;

    final allRequiredGatesTrue =
        formatProbeOk &&
        preRollOk &&
        initialDrainOk &&
        sinkParkAckOk &&
        pauseCommandOk &&
        sinkPausedOk &&
        pauseHoldFrozenOk &&
        resumeCommandOk &&
        sinkResumedOk &&
        postResumeDrainOk &&
        sinkWriteAccountingOk &&
        checksumIdentityOk &&
        playbackHeadAdvancedOk &&
        transportCompletedOk &&
        threadOwnershipOk &&
        lifecycleDisposeOk;

    final allRequiredGatesPresent = missingGates.isEmpty;
    final explicitLastError = parseString('lastError');
    final hasNoLastError =
        explicitLastError.isEmpty ||
        explicitLastError == 'none' ||
        explicitLastError == 'null';
    final hasNoFailureReason = failureReason.isEmpty;

    final computedPass =
        rawPass &&
        rawStatus.trim().toLowerCase() == 'pass' &&
        hasValidPassMarker &&
        hasValidProofBoundary &&
        allRequiredGatesPresent &&
        allRequiredGatesTrue &&
        hasNoLastError &&
        hasNoFailureReason;

    final String finalStatus;
    final String finalMarker;
    final String finalLastError;

    if (computedPass) {
      finalStatus = rawStatus;
      finalMarker = passMarkerConstant;
      finalLastError = '';
    } else {
      finalMarker = (rawMarker == passMarkerConstant)
          ? failMarkerConstant
          : rawMarker;
      if (failureReason.isNotEmpty) {
        finalLastError = failureReason;
        finalStatus = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      } else if (!hasNoLastError) {
        finalLastError = explicitLastError;
        finalStatus = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      } else if (!hasValidProofBoundary) {
        finalLastError = 'proof_boundary_mismatch';
        finalStatus = 'proof_boundary_mismatch';
      } else if (!hasValidPassMarker) {
        finalLastError = 'marker_mismatch';
        finalStatus = 'marker_mismatch';
      } else if (!allRequiredGatesPresent) {
        finalLastError = 'missing_gate_${missingGates.first}';
        finalStatus = 'missing_gate';
      } else if (!allRequiredGatesTrue) {
        finalLastError = 'gate_failed';
        finalStatus = 'gate_failed';
      } else {
        finalLastError = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
        finalStatus = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      }
    }

    final finalLanes = <String, Object?>{
      'formatProbeOk': formatProbeOk,
      'preRollOk': preRollOk,
      'initialDrainOk': initialDrainOk,
      'sinkParkAckOk': sinkParkAckOk,
      'pauseCommandOk': pauseCommandOk,
      'sinkPausedOk': sinkPausedOk,
      'pauseHoldFrozenOk': pauseHoldFrozenOk,
      'resumeCommandOk': resumeCommandOk,
      'sinkResumedOk': sinkResumedOk,
      'postResumeDrainOk': postResumeDrainOk,
      'sinkWriteAccountingOk': sinkWriteAccountingOk,
      'checksumIdentityOk': checksumIdentityOk,
      'playbackHeadAdvancedOk': playbackHeadAdvancedOk,
      'transportCompletedOk': transportCompletedOk,
      'threadOwnershipOk': threadOwnershipOk,
      'lifecycleDisposeOk': lifecycleDisposeOk,
      'proofBoundaryOk': proofBoundaryOk,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{...parsedMetrics};

    return VGRealtimePlaybackPipelinePauseResumeSmokeReport(
      pass: computedPass,
      status: finalStatus,
      marker: finalMarker,
      proofBoundary: proofBoundary,
      nativeProofBoundary: nativeProofBoundary,
      failureReason: failureReason,
      details: details,
      formatProbeOk: formatProbeOk,
      preRollOk: preRollOk,
      initialDrainOk: initialDrainOk,
      sinkParkAckOk: sinkParkAckOk,
      pauseCommandOk: pauseCommandOk,
      sinkPausedOk: sinkPausedOk,
      pauseHoldFrozenOk: pauseHoldFrozenOk,
      resumeCommandOk: resumeCommandOk,
      sinkResumedOk: sinkResumedOk,
      postResumeDrainOk: postResumeDrainOk,
      sinkWriteAccountingOk: sinkWriteAccountingOk,
      checksumIdentityOk: checksumIdentityOk,
      playbackHeadAdvancedOk: playbackHeadAdvancedOk,
      transportCompletedOk: transportCompletedOk,
      threadOwnershipOk: threadOwnershipOk,
      lifecycleDisposeOk: lifecycleDisposeOk,
      proofBoundaryOk: proofBoundaryOk,
      canonical: canonical,
      lanes: Map<String, Object?>.unmodifiable(finalLanes),
      metrics: Map<String, Object?>.unmodifiable(finalMetrics),
      lastError: finalLastError,
      raw: rawString,
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
      'lastError': lastError,
      'raw': raw,
    };
  }

  Map<String, Object?> toJson() => toMap();

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  static VGRealtimePlaybackPipelinePauseResumeSmokeReport
  _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      for (final k in requiredGateKeys) k: false,
      'proofBoundaryOk': false,
      'canonical': false,
    };
    final metrics = <String, Object?>{
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGRealtimePlaybackPipelinePauseResumeSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      nativeProofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      formatProbeOk: false,
      preRollOk: false,
      initialDrainOk: false,
      sinkParkAckOk: false,
      pauseCommandOk: false,
      sinkPausedOk: false,
      pauseHoldFrozenOk: false,
      resumeCommandOk: false,
      sinkResumedOk: false,
      postResumeDrainOk: false,
      sinkWriteAccountingOk: false,
      checksumIdentityOk: false,
      playbackHeadAdvancedOk: false,
      transportCompletedOk: false,
      threadOwnershipOk: false,
      lifecycleDisposeOk: false,
      proofBoundaryOk: false,
      canonical: false,
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      lastError: lastError,
      raw: 'pass=false;status=fail;marker=$failMarkerConstant;reason=$reason',
    );
  }

  /// Invokes the Android True-DAG Phase 4 Realtime Playback Pipeline Pause/Resume
  /// diagnostic smoke harness.
  ///
  /// [sourcePath] path to a media file with an audio track.
  /// [maxDurationSec] window duration in seconds (default 3.0).
  /// [maxFramesPerMix] quantum mix size in frames (default 256).
  /// [baseVolume] AudioTrack non-zero gain (default 0.5).
  /// [deadlineMs] total deadline in milliseconds (default 30000).
  /// [pauseHoldMs] duration of frozen pause hold in milliseconds (default 150).
  /// [timeout] optionally bounds the invocation (defaults to 35 seconds).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGRealtimePlaybackPipelinePauseResumeSmokeReport>
  runRealtimePlaybackPipelinePauseResumeSmoke({
    required String sourcePath,
    double maxDurationSec = 3.0,
    int maxFramesPerMix = 256,
    double baseVolume = 0.5,
    int deadlineMs = 30000,
    int pauseHoldMs = 150,
    Duration timeout = const Duration(seconds: 35),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName, <String, dynamic>{
        'sourcePath': sourcePath,
        'maxDurationSec': maxDurationSec,
        'maxFramesPerMix': maxFramesPerMix,
        'baseVolume': baseVolume,
        'deadlineMs': deadlineMs,
        'pauseHoldMs': pauseHoldMs,
      });
      final raw = await future.timeout(timeout);
      return VGRealtimePlaybackPipelinePauseResumeSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return _makeErrorFallbackReport(
        reason: 'timeout',
        details: te.toString(),
        lastError: 'timeout: $te',
      );
    } on PlatformException catch (pe) {
      return _makeErrorFallbackReport(
        reason: 'platform_exception:${pe.code}',
        details: pe.message ?? '',
        lastError: 'platform_exception:${pe.code}:${pe.message}',
      );
    } catch (e) {
      return _makeErrorFallbackReport(
        reason: 'exception:$e',
        details: e.toString(),
        lastError: 'exception:$e',
      );
    }
  }

  @override
  String toString() =>
      'VGRealtimePlaybackPipelinePauseResumeSmokeReport(pass: $pass, status: $status, '
      'marker: $marker, isVerifiedPass: $isVerifiedPass, '
      'formatProbeOk: $formatProbeOk, preRollOk: $preRollOk, initialDrainOk: $initialDrainOk, '
      'sinkParkAckOk: $sinkParkAckOk, pauseCommandOk: $pauseCommandOk, sinkPausedOk: $sinkPausedOk, '
      'pauseHoldFrozenOk: $pauseHoldFrozenOk, resumeCommandOk: $resumeCommandOk, '
      'sinkResumedOk: $sinkResumedOk, postResumeDrainOk: $postResumeDrainOk, '
      'sinkWriteAccountingOk: $sinkWriteAccountingOk, checksumIdentityOk: $checksumIdentityOk, '
      'playbackHeadAdvancedOk: $playbackHeadAdvancedOk, transportCompletedOk: $transportCompletedOk, '
      'threadOwnershipOk: $threadOwnershipOk, lifecycleDisposeOk: $lifecycleDisposeOk, '
      'proofBoundaryOk: $proofBoundaryOk, canonical: $canonical, failureReason: $failureReason, '
      'lastError: $lastError)';
}
