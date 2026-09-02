// vg_realtime_audio_playback_production_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK (Y8a): Android True-DAG Phase 4
// realtime audio playback production sink and clock diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runRealtimeAudioPlaybackProductionSmoke` MethodChannel route.
// Diagnostic-only - drives the production VanguardRealtimeAudioPlaybackSession
// (real MediaExtractor / MediaCodec -> Y5a external ingest -> Y1 transport ->
// sink-thread-owned non-zero-gain AudioTrack + presentation clock) through two
// scenarios:
//   1. Playthrough + bounded pause/resume to EOS.
//   2. Mid-playback stop/dispose verifying clean release.
//
// Required proof lanes (18 native lanes + canonical = 19 total):
//   1. formatProbeOk: format, duration, channel count, sample rate, and MIME probed successfully
//   2. preRollOk: pre-roll while PREPARED until ring_full or declared end fits
//   3. startOk: session and transport transition to PLAYING accepted cleanly
//   4. nonZeroGainAudioTrackOk: AudioTrack initialized with non-zero gain
//   5. playthroughAccountingOk: playthrough accounting matches declared frame count
//   6. checksumIdentityOk: decoder, transport, and sink checksums maintain identity
//   7. clockAnchoredOk: presentation clock anchored to writer head and monotonic
//   8. clockMonotonicOk: presentation clock values strictly monotonic
//   9. clockEpochBalancedOk: clock epoch balance maintained across pause/resume
//  10. clockPauseFrozenOk: presentation clock remains frozen during bounded pause
//  11. boundedPauseResumeOk: bounded pause and resume cleanly closes/reopens epoch
//  12. stopDisposeOk: stop and dispose mid-playback gracefully transitions state
//  13. decoderCancelledOnStopOk: MediaCodec/MediaExtractor worker joins and releases cleanly
//  14. transportDisposedOk: native transport state machine disposed cleanly
//  15. audioTrackReleasedOnceOk: AudioTrack released exactly once
//  16. threadOwnershipOk: strict thread ownership across decode, transport, and sink
//  17. noFeedbackOk: no audio feedback loop or invalid gain ramp detected
//  18. proofBoundaryOk: proof boundary string matches canonical contract exactly
//  19. canonical: aggregate pass evaluation holding across all required lanes
//
// Honest non-claims (Proof Boundary):
// production_engine_component_diagnostic_route_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_sink_thread_owned_audiotrack_and_presentation_clock_bounded_pause_resume_closes_reopens_clock_epoch_at_last_published_position_stop_dispose_release_once_no_seek_no_dead_object_recovery_no_product_no_editor_no_app_no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_no_jni

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGRealtimeAudioPlaybackProductionSmokeReport.runRealtimeAudioPlaybackProductionSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGRealtimeAudioPlaybackProductionSmokeReport {
  const VGRealtimeAudioPlaybackProductionSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.nativeProofBoundary,
    required this.failureReason,
    required this.details,
    required this.formatProbeOk,
    required this.preRollOk,
    required this.startOk,
    required this.nonZeroGainAudioTrackOk,
    required this.playthroughAccountingOk,
    required this.checksumIdentityOk,
    required this.clockAnchoredOk,
    required this.clockMonotonicOk,
    required this.clockEpochBalancedOk,
    required this.clockPauseFrozenOk,
    required this.boundedPauseResumeOk,
    required this.stopDisposeOk,
    required this.decoderCancelledOnStopOk,
    required this.transportDisposedOk,
    required this.audioTrackReleasedOnceOk,
    required this.threadOwnershipOk,
    required this.noFeedbackOk,
    required this.proofBoundaryOk,
    required this.canonical,
    required this.lanes,
    required this.metrics,
    this.lastError = '',
    this.raw = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName = 'runRealtimeAudioPlaybackProductionSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_PHYSICAL_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_PHYSICAL_SMOKE_FAIL';

  /// Canonical start marker string.
  static const String startMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_SMOKE_START';

  /// Canonical JSON prefix marker string.
  static const String jsonMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_JSON';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'production_engine_component_diagnostic_route_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_sink_thread_owned_audiotrack_and_presentation_clock_bounded_pause_resume_closes_reopens_clock_epoch_at_last_published_position_stop_dispose_release_once_no_seek_no_dead_object_recovery_no_product_no_editor_no_app_no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_no_jni';

  /// All required non-canonical native lane keys that must be evaluated and true.
  static const List<String> requiredNonCanonicalLanes = <String>[
    'formatProbeOk',
    'preRollOk',
    'startOk',
    'nonZeroGainAudioTrackOk',
    'playthroughAccountingOk',
    'checksumIdentityOk',
    'clockAnchoredOk',
    'clockMonotonicOk',
    'clockEpochBalancedOk',
    'clockPauseFrozenOk',
    'boundedPauseResumeOk',
    'stopDisposeOk',
    'decoderCancelledOnStopOk',
    'transportDisposedOk',
    'audioTrackReleasedOnceOk',
    'threadOwnershipOk',
    'noFeedbackOk',
    'proofBoundaryOk',
  ];

  /// All required native lane keys including canonical.
  static const List<String> requiredLanes = <String>[
    ...requiredNonCanonicalLanes,
    'canonical',
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

  // ---- Required Lanes -----------------------------------------------------

  /// Whether format, duration, channel count, sample rate, and MIME probed successfully.
  final bool formatProbeOk;

  /// Whether pre-roll succeeded while PREPARED.
  final bool preRollOk;

  /// Whether session and transport transition to PLAYING was accepted cleanly.
  final bool startOk;

  /// Whether AudioTrack initialized with non-zero gain.
  final bool nonZeroGainAudioTrackOk;

  /// Whether playthrough accounting matches declared frame count.
  final bool playthroughAccountingOk;

  /// Whether decoder, transport, and sink checksums maintain identity.
  final bool checksumIdentityOk;

  /// Whether presentation clock anchored to writer head and monotonic.
  final bool clockAnchoredOk;

  /// Whether presentation clock values strictly monotonic.
  final bool clockMonotonicOk;

  /// Whether clock epoch balance maintained across pause/resume.
  final bool clockEpochBalancedOk;

  /// Whether presentation clock remains frozen during bounded pause.
  final bool clockPauseFrozenOk;

  /// Whether bounded pause and resume cleanly closes/reopens epoch.
  final bool boundedPauseResumeOk;

  /// Whether stop and dispose mid-playback gracefully transitions state.
  final bool stopDisposeOk;

  /// Whether MediaCodec/MediaExtractor worker joins and releases cleanly on stop.
  final bool decoderCancelledOnStopOk;

  /// Whether native transport state machine disposed cleanly.
  final bool transportDisposedOk;

  /// Whether AudioTrack released exactly once.
  final bool audioTrackReleasedOnceOk;

  /// Whether strict thread ownership across decode, transport, and sink.
  final bool threadOwnershipOk;

  /// Whether no audio feedback loop or invalid gain ramp detected.
  final bool noFeedbackOk;

  /// Whether proof boundary string matches canonical contract exactly.
  final bool proofBoundaryOk;

  /// Canonical pass indicator.
  final bool canonical;

  /// Nested lanes map emitted by native smoke execution.
  final Map<String, Object?> lanes;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Last error string from native execution, if any.
  final String lastError;

  /// Raw textual summary returned by native smoke execution.
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

  /// Whether every required non-canonical lane passed.
  bool get allRequiredNonCanonicalLanesPass =>
      formatProbeOk &&
      preRollOk &&
      startOk &&
      nonZeroGainAudioTrackOk &&
      playthroughAccountingOk &&
      checksumIdentityOk &&
      clockAnchoredOk &&
      clockMonotonicOk &&
      clockEpochBalancedOk &&
      clockPauseFrozenOk &&
      boundedPauseResumeOk &&
      stopDisposeOk &&
      decoderCancelledOnStopOk &&
      transportDisposedOk &&
      audioTrackReleasedOnceOk &&
      threadOwnershipOk &&
      noFeedbackOk &&
      proofBoundaryOk;

  /// Whether this report meets all verification criteria for a passing smoke run.
  bool get isVerifiedPass =>
      pass &&
      status.trim().toLowerCase() == 'pass' &&
      hasPassMarker &&
      hasCanonicalProofBoundary &&
      canonical &&
      allRequiredNonCanonicalLanesPass &&
      failureReason.isEmpty &&
      (lastError.isEmpty || lastError == 'none' || lastError == 'null');

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGRealtimeAudioPlaybackProductionSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGRealtimeAudioPlaybackProductionSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        nativeProofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        formatProbeOk: false,
        preRollOk: false,
        startOk: false,
        nonZeroGainAudioTrackOk: false,
        playthroughAccountingOk: false,
        checksumIdentityOk: false,
        clockAnchoredOk: false,
        clockMonotonicOk: false,
        clockEpochBalancedOk: false,
        clockPauseFrozenOk: false,
        boundedPauseResumeOk: false,
        stopDisposeOk: false,
        decoderCancelledOnStopOk: false,
        transportDisposedOk: false,
        audioTrackReleasedOnceOk: false,
        threadOwnershipOk: false,
        noFeedbackOk: false,
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
      final v = raw[key] ?? parsedMetrics[key];
      return v?.toString() ?? defaultValue;
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

    final missingLanes = <String>[];
    for (final laneKey in requiredLanes) {
      if (parseBoolStrict(laneKey) == null) {
        missingLanes.add(laneKey);
      }
    }

    final formatProbeOk = parseBool('formatProbeOk');
    final preRollOk = parseBool('preRollOk');
    final startOk = parseBool('startOk');
    final nonZeroGainAudioTrackOk = parseBool('nonZeroGainAudioTrackOk');
    final playthroughAccountingOk = parseBool('playthroughAccountingOk');
    final checksumIdentityOk = parseBool('checksumIdentityOk');
    final clockAnchoredOk = parseBool('clockAnchoredOk');
    final clockMonotonicOk = parseBool('clockMonotonicOk');
    final clockEpochBalancedOk = parseBool('clockEpochBalancedOk');
    final clockPauseFrozenOk = parseBool('clockPauseFrozenOk');
    final boundedPauseResumeOk = parseBool('boundedPauseResumeOk');
    final stopDisposeOk = parseBool('stopDisposeOk');
    final decoderCancelledOnStopOk = parseBool('decoderCancelledOnStopOk');
    final transportDisposedOk = parseBool('transportDisposedOk');
    final audioTrackReleasedOnceOk = parseBool('audioTrackReleasedOnceOk');
    final threadOwnershipOk = parseBool('threadOwnershipOk');
    final noFeedbackOk = parseBool('noFeedbackOk');
    final proofBoundaryOk = parseBool('proofBoundaryOk');
    final canonical = parseBool('canonical', rawPass && missingLanes.isEmpty);

    final hasValidProofBoundary =
        proofBoundary == proofBoundaryConstant &&
        (nativeProofBoundary.isEmpty ||
            nativeProofBoundary == proofBoundaryConstant);
    final hasValidPassMarker = rawMarker == passMarkerConstant;

    final allRequiredNonCanonicalLanesTrue =
        formatProbeOk &&
        preRollOk &&
        startOk &&
        nonZeroGainAudioTrackOk &&
        playthroughAccountingOk &&
        checksumIdentityOk &&
        clockAnchoredOk &&
        clockMonotonicOk &&
        clockEpochBalancedOk &&
        clockPauseFrozenOk &&
        boundedPauseResumeOk &&
        stopDisposeOk &&
        decoderCancelledOnStopOk &&
        transportDisposedOk &&
        audioTrackReleasedOnceOk &&
        threadOwnershipOk &&
        noFeedbackOk &&
        proofBoundaryOk;

    final allRequiredLanesPresent = missingLanes.isEmpty;
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
        allRequiredLanesPresent &&
        allRequiredNonCanonicalLanesTrue &&
        canonical &&
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
          : (rawMarker.isNotEmpty ? rawMarker : failMarkerConstant);
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
      } else if (!allRequiredLanesPresent) {
        finalLastError = 'missing_lane_${missingLanes.first}';
        finalStatus = 'missing_lane';
      } else if (!allRequiredNonCanonicalLanesTrue) {
        finalLastError = 'lane_failed';
        finalStatus = 'lane_failed';
      } else if (!canonical) {
        finalLastError = 'canonical_failed';
        finalStatus = 'canonical_failed';
      } else {
        finalLastError = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
        finalStatus = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      }
    }

    final finalLanes = <String, Object?>{
      'formatProbeOk': formatProbeOk,
      'preRollOk': preRollOk,
      'startOk': startOk,
      'nonZeroGainAudioTrackOk': nonZeroGainAudioTrackOk,
      'playthroughAccountingOk': playthroughAccountingOk,
      'checksumIdentityOk': checksumIdentityOk,
      'clockAnchoredOk': clockAnchoredOk,
      'clockMonotonicOk': clockMonotonicOk,
      'clockEpochBalancedOk': clockEpochBalancedOk,
      'clockPauseFrozenOk': clockPauseFrozenOk,
      'boundedPauseResumeOk': boundedPauseResumeOk,
      'stopDisposeOk': stopDisposeOk,
      'decoderCancelledOnStopOk': decoderCancelledOnStopOk,
      'transportDisposedOk': transportDisposedOk,
      'audioTrackReleasedOnceOk': audioTrackReleasedOnceOk,
      'threadOwnershipOk': threadOwnershipOk,
      'noFeedbackOk': noFeedbackOk,
      'proofBoundaryOk': proofBoundaryOk,
      'canonical': canonical,
      ...parsedLanes,
    };

    return VGRealtimeAudioPlaybackProductionSmokeReport(
      pass: computedPass,
      status: finalStatus,
      marker: finalMarker,
      proofBoundary: proofBoundary,
      nativeProofBoundary: nativeProofBoundary,
      failureReason: failureReason,
      details: details,
      formatProbeOk: formatProbeOk,
      preRollOk: preRollOk,
      startOk: startOk,
      nonZeroGainAudioTrackOk: nonZeroGainAudioTrackOk,
      playthroughAccountingOk: playthroughAccountingOk,
      checksumIdentityOk: checksumIdentityOk,
      clockAnchoredOk: clockAnchoredOk,
      clockMonotonicOk: clockMonotonicOk,
      clockEpochBalancedOk: clockEpochBalancedOk,
      clockPauseFrozenOk: clockPauseFrozenOk,
      boundedPauseResumeOk: boundedPauseResumeOk,
      stopDisposeOk: stopDisposeOk,
      decoderCancelledOnStopOk: decoderCancelledOnStopOk,
      transportDisposedOk: transportDisposedOk,
      audioTrackReleasedOnceOk: audioTrackReleasedOnceOk,
      threadOwnershipOk: threadOwnershipOk,
      noFeedbackOk: noFeedbackOk,
      proofBoundaryOk: proofBoundaryOk,
      canonical: canonical,
      lanes: Map<String, Object?>.unmodifiable(finalLanes),
      metrics: Map<String, Object?>.unmodifiable(parsedMetrics),
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

  static VGRealtimeAudioPlaybackProductionSmokeReport _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{for (final k in requiredLanes) k: false};
    final metrics = <String, Object?>{
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGRealtimeAudioPlaybackProductionSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      nativeProofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      formatProbeOk: false,
      preRollOk: false,
      startOk: false,
      nonZeroGainAudioTrackOk: false,
      playthroughAccountingOk: false,
      checksumIdentityOk: false,
      clockAnchoredOk: false,
      clockMonotonicOk: false,
      clockEpochBalancedOk: false,
      clockPauseFrozenOk: false,
      boundedPauseResumeOk: false,
      stopDisposeOk: false,
      decoderCancelledOnStopOk: false,
      transportDisposedOk: false,
      audioTrackReleasedOnceOk: false,
      threadOwnershipOk: false,
      noFeedbackOk: false,
      proofBoundaryOk: false,
      canonical: false,
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      lastError: lastError,
      raw: 'pass=false;status=fail;marker=$failMarkerConstant;reason=$reason',
    );
  }

  /// Invokes the Android True-DAG Phase 4 Realtime Audio Playback Production Sink and Clock
  /// diagnostic smoke harness.
  ///
  /// [sourcePath] path to a media file with an audio track.
  /// [maxDurationSec] window duration in seconds (default 3.0).
  /// [maxFramesPerMix] quantum mix size in frames (default 256).
  /// [gain] AudioTrack volume gain (default 0.5).
  /// [deadlineMs] total deadline in milliseconds (default 30000).
  /// [pauseHoldMs] duration of pause hold in milliseconds (default 400).
  /// [maxPauseHoldMs] maximum allowed pause hold in milliseconds.
  /// [stopAfterMs] duration to play before mid-playback stop in milliseconds (default 300).
  /// [timeout] optionally bounds the invocation (defaults to 40 seconds).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGRealtimeAudioPlaybackProductionSmokeReport>
  runRealtimeAudioPlaybackProductionSmoke({
    required String sourcePath,
    double maxDurationSec = 3.0,
    int maxFramesPerMix = 256,
    double gain = 0.5,
    int deadlineMs = 30000,
    int pauseHoldMs = 400,
    int? maxPauseHoldMs,
    int stopAfterMs = 300,
    Duration timeout = const Duration(seconds: 40),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName, <String, dynamic>{
        'sourcePath': sourcePath,
        'maxDurationSec': maxDurationSec,
        'maxFramesPerMix': maxFramesPerMix,
        'gain': gain,
        'deadlineMs': deadlineMs,
        'pauseHoldMs': pauseHoldMs,
        'maxPauseHoldMs': ?maxPauseHoldMs,
        'stopAfterMs': stopAfterMs,
      });
      final raw = await future.timeout(timeout);
      return VGRealtimeAudioPlaybackProductionSmokeReport.fromMap(raw);
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
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGRealtimeAudioPlaybackProductionSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.nativeProofBoundary == nativeProofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.formatProbeOk == formatProbeOk &&
        other.preRollOk == preRollOk &&
        other.startOk == startOk &&
        other.nonZeroGainAudioTrackOk == nonZeroGainAudioTrackOk &&
        other.playthroughAccountingOk == playthroughAccountingOk &&
        other.checksumIdentityOk == checksumIdentityOk &&
        other.clockAnchoredOk == clockAnchoredOk &&
        other.clockMonotonicOk == clockMonotonicOk &&
        other.clockEpochBalancedOk == clockEpochBalancedOk &&
        other.clockPauseFrozenOk == clockPauseFrozenOk &&
        other.boundedPauseResumeOk == boundedPauseResumeOk &&
        other.stopDisposeOk == stopDisposeOk &&
        other.decoderCancelledOnStopOk == decoderCancelledOnStopOk &&
        other.transportDisposedOk == transportDisposedOk &&
        other.audioTrackReleasedOnceOk == audioTrackReleasedOnceOk &&
        other.threadOwnershipOk == threadOwnershipOk &&
        other.noFeedbackOk == noFeedbackOk &&
        other.proofBoundaryOk == proofBoundaryOk &&
        other.canonical == canonical &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    pass,
    status,
    marker,
    proofBoundary,
    nativeProofBoundary,
    failureReason,
    details,
    formatProbeOk,
    preRollOk,
    startOk,
    nonZeroGainAudioTrackOk,
    playthroughAccountingOk,
    checksumIdentityOk,
    clockAnchoredOk,
    clockMonotonicOk,
    clockEpochBalancedOk,
    clockPauseFrozenOk,
    boundedPauseResumeOk,
    stopDisposeOk,
    decoderCancelledOnStopOk,
  ]);

  @override
  String toString() =>
      'VGRealtimeAudioPlaybackProductionSmokeReport(pass: $pass, status: $status, '
      'marker: $marker, isVerifiedPass: $isVerifiedPass, '
      'formatProbeOk: $formatProbeOk, preRollOk: $preRollOk, startOk: $startOk, '
      'nonZeroGainAudioTrackOk: $nonZeroGainAudioTrackOk, '
      'playthroughAccountingOk: $playthroughAccountingOk, checksumIdentityOk: $checksumIdentityOk, '
      'clockAnchoredOk: $clockAnchoredOk, clockMonotonicOk: $clockMonotonicOk, '
      'clockEpochBalancedOk: $clockEpochBalancedOk, clockPauseFrozenOk: $clockPauseFrozenOk, '
      'boundedPauseResumeOk: $boundedPauseResumeOk, stopDisposeOk: $stopDisposeOk, '
      'decoderCancelledOnStopOk: $decoderCancelledOnStopOk, transportDisposedOk: $transportDisposedOk, '
      'audioTrackReleasedOnceOk: $audioTrackReleasedOnceOk, threadOwnershipOk: $threadOwnershipOk, '
      'noFeedbackOk: $noFeedbackOk, proofBoundaryOk: $proofBoundaryOk, '
      'canonical: $canonical, failureReason: $failureReason, lastError: $lastError)';
}
