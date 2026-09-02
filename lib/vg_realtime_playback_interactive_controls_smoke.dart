// vg_realtime_playback_interactive_controls_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-INTERACTIVE-CONTROLS (Y3): Android True-DAG Phase 4
// realtime playback interactive transport controls diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runRealtimePlaybackInteractiveControlsSmoke` MethodChannel route.
// Diagnostic-only - validates the VanguardRealtimePlaybackInteractiveControlsSink Kotlin adapter
// driven by the authoritative VanguardRealtimePlaybackTransportStateMachine (Y1),
// draining mixed PCM16 into a muted android.media.AudioTrack MODE_STREAM sink and verifying
// interactive pause/resume and seek synchronization.
//
// Honest non-claims (Proof Boundary):
// muted_diagnostic_audiotrack_interactive_controls_only_synthetic_pcm_from_y1_transport_no_mediacodec_no_mediaextractor_no_audio_focus_no_route_change_no_dead_object_recovery_no_production_presentation_clock_no_av_sync_no_audible_output_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_native_cpp_changes

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGRealtimePlaybackInteractiveControlsSmokeReport.runRealtimePlaybackInteractiveControlsSmoke],
/// mirroring the native Kotlin smoke coordinator's payload map.
@immutable
class VGRealtimePlaybackInteractiveControlsSmokeReport {
  const VGRealtimePlaybackInteractiveControlsSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.nativeProofBoundary,
    required this.failureReason,
    required this.details,
    required this.audioTrackInitOk,
    required this.mutedOutputOk,
    required this.initialDrainOk,
    required this.pauseCommandOk,
    required this.sinkPausedOk,
    required this.pauseHoldFrozenOk,
    required this.resumeCommandOk,
    required this.sinkResumedOk,
    required this.activeBeforeSeekOk,
    required this.seekCommandOk,
    required this.sinkFlushAtSeekOk,
    required this.postSeekDrainOk,
    required this.transportCompletedOk,
    required this.checksumIdentityOk,
    required this.sinkWriteAccountingOk,
    required this.audioTrackReleasedOk,
    required this.lifecycleOk,
    required this.canonical,
    required this.sampleRate,
    required this.channelCount,
    required this.maxFramesPerMix,
    required this.declaredFrameCount,
    required this.pauseHoldMs,
    required this.preControlFrames,
    required this.seekTargetFrame,
    required this.framesReadFromTransport,
    required this.framesWrittenPreSeek,
    required this.sinkFramesDiscardedAtSeek,
    required this.framesWrittenPostSeek,
    required this.totalFramesWrittenToSink,
    required this.expectedFramesWrittenToSink,
    required this.playbackHeadAtPause,
    required this.playbackHeadAtSeek,
    required this.playbackHeadFinal,
    required this.pauseSnapshotDispatchCount,
    required this.pauseSnapshotPushedFrames,
    required this.pauseHoldDispatchDelta,
    required this.pauseHoldPushedDelta,
    required this.activeProbeAttempts,
    required this.activeProbeDrainedFrames,
    required this.seekGenerationBefore,
    required this.seekGenerationAfter,
    required this.seekReplyPositionFrame,
    required this.seekReplyDiscardedFrames,
    required this.finalReplyPositionFrame,
    required this.finalReplyDiscardedFrames,
    required this.drainIterations,
    required this.partialWriteCount,
    required this.zeroWriteCount,
    required this.flushCount,
    required this.releaseCount,
    required this.kotlinSinkChecksumHex,
    required this.nativeDrainedChecksumHex,
    required this.transportStopCalled,
    required this.transportStopAccepted,
    required this.transportState,
    required this.lanes,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runRealtimePlaybackInteractiveControlsSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_PHYSICAL_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_PHYSICAL_SMOKE_FAIL';

  /// Canonical start marker string.
  static const String startMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_SMOKE_START';

  /// Canonical JSON prefix marker string.
  static const String jsonMarkerConstant =
      'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_JSON';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'muted_diagnostic_audiotrack_interactive_controls_only_synthetic_pcm_from_y1_transport_no_mediacodec_no_mediaextractor_no_audio_focus_no_route_change_no_dead_object_recovery_no_production_presentation_clock_no_av_sync_no_audible_output_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_native_cpp_changes';

  /// All required native lane keys that must be present and reported.
  static const List<String> requiredNativeLaneKeys = <String>[
    'audioTrackInitOk',
    'mutedOutputOk',
    'initialDrainOk',
    'pauseCommandOk',
    'sinkPausedOk',
    'pauseHoldFrozenOk',
    'resumeCommandOk',
    'sinkResumedOk',
    'activeBeforeSeekOk',
    'seekCommandOk',
    'sinkFlushAtSeekOk',
    'postSeekDrainOk',
    'transportCompletedOk',
    'checksumIdentityOk',
    'sinkWriteAccountingOk',
    'audioTrackReleasedOk',
    'lifecycleOk',
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

  // ---- Lanes --------------------------------------------------------------

  /// Whether AudioTrack initialized successfully.
  final bool audioTrackInitOk;

  /// Whether AudioTrack volume was set to 0.0 (muted).
  final bool mutedOutputOk;

  /// Whether pre-control initial drain succeeded.
  final bool initialDrainOk;

  /// Whether pause command was accepted by transport state machine.
  final bool pauseCommandOk;

  /// Whether AudioTrack sink paused successfully.
  final bool sinkPausedOk;

  /// Whether native dispatch & push remained frozen during pause hold.
  final bool pauseHoldFrozenOk;

  /// Whether resume command was accepted by transport state machine.
  final bool resumeCommandOk;

  /// Whether AudioTrack sink resumed to playing.
  final bool sinkResumedOk;

  /// Whether transport was active and advancing before seek.
  final bool activeBeforeSeekOk;

  /// Whether seek command was accepted and generation advanced.
  final bool seekCommandOk;

  /// Whether AudioTrack was paused and flushed exactly once at seek.
  final bool sinkFlushAtSeekOk;

  /// Whether post-seek drain to EOS completed with exact frame count.
  final bool postSeekDrainOk;

  /// Whether transport state machine reached COMPLETED state.
  final bool transportCompletedOk;

  /// Whether Kotlin sink checksum matches native drained checksum.
  final bool checksumIdentityOk;

  /// Whether total frames written to sink equals expected frames written.
  final bool sinkWriteAccountingOk;

  /// Whether AudioTrack was stopped and released with releaseCount == 1.
  final bool audioTrackReleasedOk;

  /// Whether full lifecycle clean up succeeded (releaseCount == 1).
  final bool lifecycleOk;

  /// Canonical pass indicator.
  final bool canonical;

  // ---- Metrics ------------------------------------------------------------

  final int sampleRate;
  final int channelCount;
  final int maxFramesPerMix;
  final int declaredFrameCount;
  final int pauseHoldMs;
  final int preControlFrames;
  final int seekTargetFrame;
  final int framesReadFromTransport;
  final int framesWrittenPreSeek;
  final int sinkFramesDiscardedAtSeek;
  final int framesWrittenPostSeek;
  final int totalFramesWrittenToSink;
  final int expectedFramesWrittenToSink;
  final int playbackHeadAtPause;
  final int playbackHeadAtSeek;
  final int playbackHeadFinal;
  final int pauseSnapshotDispatchCount;
  final int pauseSnapshotPushedFrames;
  final int pauseHoldDispatchDelta;
  final int pauseHoldPushedDelta;
  final int activeProbeAttempts;
  final int activeProbeDrainedFrames;
  final int seekGenerationBefore;
  final int seekGenerationAfter;
  final int seekReplyPositionFrame;
  final int seekReplyDiscardedFrames;
  final int finalReplyPositionFrame;
  final int finalReplyDiscardedFrames;
  final int drainIterations;
  final int partialWriteCount;
  final int zeroWriteCount;
  final int flushCount;
  final int releaseCount;
  final String kotlinSinkChecksumHex;
  final String nativeDrainedChecksumHex;
  final bool transportStopCalled;
  final bool transportStopAccepted;
  final String transportState;

  /// Nested lanes map emitted by native smoke execution.
  final Map<String, Object?> lanes;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Last error string from native execution, if any.
  final String lastError;

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

  /// Whether all native diagnostic lanes passed according to the contract.
  bool get allNativeLanesPass {
    if (!pass) return false;
    if (status.toLowerCase() != 'pass') return false;
    if (!hasCanonicalProofBoundary) return false;
    if (!hasPassMarker) return false;
    if (!audioTrackInitOk) return false;
    if (!mutedOutputOk) return false;
    if (!initialDrainOk) return false;
    if (!pauseCommandOk) return false;
    if (!sinkPausedOk) return false;
    if (!pauseHoldFrozenOk) return false;
    if (!resumeCommandOk) return false;
    if (!sinkResumedOk) return false;
    if (!activeBeforeSeekOk) return false;
    if (!seekCommandOk) return false;
    if (!sinkFlushAtSeekOk) return false;
    if (!postSeekDrainOk) return false;
    if (!transportCompletedOk) return false;
    if (!checksumIdentityOk) return false;
    if (!sinkWriteAccountingOk) return false;
    if (!audioTrackReleasedOk) return false;
    if (!lifecycleOk) return false;
    if (!canonical) return false;
    if (releaseCount != 1) return false;
    if (totalFramesWrittenToSink != expectedFramesWrittenToSink ||
        framesWrittenPreSeek < preControlFrames ||
        framesWrittenPostSeek != (declaredFrameCount - seekTargetFrame) ||
        totalFramesWrittenToSink !=
            (framesWrittenPreSeek + framesWrittenPostSeek) ||
        declaredFrameCount <= 0 ||
        preControlFrames <= 0 ||
        seekTargetFrame <= preControlFrames ||
        declaredFrameCount <= seekTargetFrame) {
      return false;
    }
    if (pauseHoldDispatchDelta != 0 || pauseHoldPushedDelta != 0) return false;
    if (seekGenerationAfter != seekGenerationBefore + 1) return false;
    if (transportState != 'COMPLETED') return false;
    if (kotlinSinkChecksumHex.isEmpty ||
        nativeDrainedChecksumHex.isEmpty ||
        kotlinSinkChecksumHex.toLowerCase() !=
            nativeDrainedChecksumHex.toLowerCase()) {
      return false;
    }
    if (lastError.isNotEmpty && lastError != 'none' && lastError != 'null') {
      return false;
    }
    if (failureReason.isNotEmpty) return false;
    return true;
  }

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGRealtimePlaybackInteractiveControlsSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGRealtimePlaybackInteractiveControlsSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        nativeProofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        audioTrackInitOk: false,
        mutedOutputOk: false,
        initialDrainOk: false,
        pauseCommandOk: false,
        sinkPausedOk: false,
        pauseHoldFrozenOk: false,
        resumeCommandOk: false,
        sinkResumedOk: false,
        activeBeforeSeekOk: false,
        seekCommandOk: false,
        sinkFlushAtSeekOk: false,
        postSeekDrainOk: false,
        transportCompletedOk: false,
        checksumIdentityOk: false,
        sinkWriteAccountingOk: false,
        audioTrackReleasedOk: false,
        lifecycleOk: false,
        canonical: false,
        sampleRate: 0,
        channelCount: 0,
        maxFramesPerMix: 0,
        declaredFrameCount: 0,
        pauseHoldMs: 0,
        preControlFrames: 0,
        seekTargetFrame: 0,
        framesReadFromTransport: 0,
        framesWrittenPreSeek: 0,
        sinkFramesDiscardedAtSeek: 0,
        framesWrittenPostSeek: 0,
        totalFramesWrittenToSink: 0,
        expectedFramesWrittenToSink: 0,
        playbackHeadAtPause: 0,
        playbackHeadAtSeek: 0,
        playbackHeadFinal: 0,
        pauseSnapshotDispatchCount: 0,
        pauseSnapshotPushedFrames: 0,
        pauseHoldDispatchDelta: 0,
        pauseHoldPushedDelta: 0,
        activeProbeAttempts: 0,
        activeProbeDrainedFrames: 0,
        seekGenerationBefore: 0,
        seekGenerationAfter: 0,
        seekReplyPositionFrame: -1,
        seekReplyDiscardedFrames: -1,
        finalReplyPositionFrame: -1,
        finalReplyDiscardedFrames: -1,
        drainIterations: 0,
        partialWriteCount: 0,
        zeroWriteCount: 0,
        flushCount: 0,
        releaseCount: 0,
        kotlinSinkChecksumHex: '',
        nativeDrainedChecksumHex: '',
        transportStopCalled: false,
        transportStopAccepted: false,
        transportState: '',
        lanes: <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
        },
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
        },
        lastError: 'native_result_not_a_map',
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

    int? parseIntStrict(String key) {
      final v = parsedMetrics[key] ?? raw[key] ?? parsedLanes[key];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    int parseInt(String key, [int defaultValue = 0]) {
      return parseIntStrict(key) ?? defaultValue;
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

    final missingLanes = <String>[];
    for (final laneKey in requiredNativeLaneKeys) {
      if (parseBoolStrict(laneKey) == null) {
        missingLanes.add(laneKey);
      }
    }

    final audioTrackInitOk = parseBool('audioTrackInitOk');
    final mutedOutputOk = parseBool('mutedOutputOk');
    final initialDrainOk = parseBool('initialDrainOk');
    final pauseCommandOk = parseBool('pauseCommandOk');
    final sinkPausedOk = parseBool('sinkPausedOk');
    final pauseHoldFrozenOk = parseBool('pauseHoldFrozenOk');
    final resumeCommandOk = parseBool('resumeCommandOk');
    final sinkResumedOk = parseBool('sinkResumedOk');
    final activeBeforeSeekOk = parseBool('activeBeforeSeekOk');
    final seekCommandOk = parseBool('seekCommandOk');
    final sinkFlushAtSeekOk = parseBool('sinkFlushAtSeekOk');
    final postSeekDrainOk = parseBool('postSeekDrainOk');
    final transportCompletedOk = parseBool('transportCompletedOk');
    final checksumIdentityOk = parseBool('checksumIdentityOk');
    final sinkWriteAccountingOk = parseBool('sinkWriteAccountingOk');
    final audioTrackReleasedOk = parseBool('audioTrackReleasedOk');
    final lifecycleOk = parseBool('lifecycleOk');
    final canonical = parseBool('canonical', rawPass && missingLanes.isEmpty);

    final sampleRate = parseInt('sampleRate');
    final channelCount = parseInt('channelCount');
    final maxFramesPerMix = parseInt('maxFramesPerMix');
    final declaredFrameCount = parseInt('declaredFrameCount');
    final pauseHoldMs = parseInt('pauseHoldMs');
    final preControlFrames = parseInt('preControlFrames');
    final seekTargetFrame = parseInt('seekTargetFrame');
    final framesReadFromTransport = parseInt('framesReadFromTransport');
    final framesWrittenPreSeek = parseInt('framesWrittenPreSeek');
    final sinkFramesDiscardedAtSeek = parseInt('sinkFramesDiscardedAtSeek');
    final framesWrittenPostSeek = parseInt('framesWrittenPostSeek');
    final totalFramesWrittenToSink = parseInt('totalFramesWrittenToSink');
    final expectedFramesWrittenToSink = parseInt('expectedFramesWrittenToSink');
    final playbackHeadAtPause = parseInt('playbackHeadAtPause');
    final playbackHeadAtSeek = parseInt('playbackHeadAtSeek');
    final playbackHeadFinal = parseInt('playbackHeadFinal');
    final pauseSnapshotDispatchCount = parseInt('pauseSnapshotDispatchCount');
    final pauseSnapshotPushedFrames = parseInt('pauseSnapshotPushedFrames');
    final pauseHoldDispatchDelta = parseInt('pauseHoldDispatchDelta');
    final pauseHoldPushedDelta = parseInt('pauseHoldPushedDelta');
    final activeProbeAttempts = parseInt('activeProbeAttempts');
    final activeProbeDrainedFrames = parseInt('activeProbeDrainedFrames');
    final seekGenerationBefore = parseInt('seekGenerationBefore');
    final seekGenerationAfter = parseInt('seekGenerationAfter');
    final seekReplyPositionFrame = parseInt('seekReplyPositionFrame', -1);
    final seekReplyDiscardedFrames = parseInt('seekReplyDiscardedFrames', -1);
    final finalReplyPositionFrame = parseInt('finalReplyPositionFrame', -1);
    final finalReplyDiscardedFrames = parseInt('finalReplyDiscardedFrames', -1);
    final drainIterations = parseInt('drainIterations');
    final partialWriteCount = parseInt('partialWriteCount');
    final zeroWriteCount = parseInt('zeroWriteCount');
    final flushCount = parseInt('flushCount');
    final releaseCount = parseInt('releaseCount');
    final kotlinSinkChecksumHex = parseString('kotlinSinkChecksumHex');
    final nativeDrainedChecksumHex = parseString('nativeDrainedChecksumHex');
    final transportStopCalled = parseBool('transportStopCalled');
    final transportStopAccepted = parseBool('transportStopAccepted');
    final transportState = parseString('transportState');

    final hasValidProofBoundary =
        proofBoundary == proofBoundaryConstant &&
        (nativeProofBoundary.isEmpty ||
            nativeProofBoundary == proofBoundaryConstant);
    final hasValidPassMarker = rawMarker == passMarkerConstant;

    final allRequiredLanesTrue =
        audioTrackInitOk &&
        mutedOutputOk &&
        initialDrainOk &&
        pauseCommandOk &&
        sinkPausedOk &&
        pauseHoldFrozenOk &&
        resumeCommandOk &&
        sinkResumedOk &&
        activeBeforeSeekOk &&
        seekCommandOk &&
        sinkFlushAtSeekOk &&
        postSeekDrainOk &&
        transportCompletedOk &&
        checksumIdentityOk &&
        sinkWriteAccountingOk &&
        audioTrackReleasedOk &&
        lifecycleOk &&
        canonical;

    final allRequiredLanesPresent = missingLanes.isEmpty;

    final validFrameAccounting =
        totalFramesWrittenToSink == expectedFramesWrittenToSink &&
        framesWrittenPreSeek >= preControlFrames &&
        framesWrittenPostSeek == (declaredFrameCount - seekTargetFrame) &&
        expectedFramesWrittenToSink ==
            (framesWrittenPreSeek + (declaredFrameCount - seekTargetFrame)) &&
        totalFramesWrittenToSink ==
            (framesWrittenPreSeek + framesWrittenPostSeek) &&
        declaredFrameCount > 0 &&
        preControlFrames > 0 &&
        seekTargetFrame > preControlFrames &&
        declaredFrameCount > seekTargetFrame;

    final validPostSeek =
        framesWrittenPostSeek == (declaredFrameCount - seekTargetFrame);

    final validReleaseCount = releaseCount == 1;

    final validChecksumHex =
        kotlinSinkChecksumHex.isNotEmpty &&
        nativeDrainedChecksumHex.isNotEmpty &&
        kotlinSinkChecksumHex.toLowerCase() ==
            nativeDrainedChecksumHex.toLowerCase();

    final validTransportState = transportState == 'COMPLETED';

    final validPauseSeekMetrics =
        pauseHoldDispatchDelta == 0 &&
        pauseHoldPushedDelta == 0 &&
        seekGenerationAfter == (seekGenerationBefore + 1);

    final explicitLastError = parseString('lastError');
    final hasNoLastError =
        explicitLastError.isEmpty ||
        explicitLastError == 'none' ||
        explicitLastError == 'null';
    final hasNoFailureReason = failureReason.isEmpty;

    final pass =
        rawPass &&
        rawStatus.toLowerCase() == 'pass' &&
        hasValidPassMarker &&
        hasValidProofBoundary &&
        allRequiredLanesPresent &&
        allRequiredLanesTrue &&
        validFrameAccounting &&
        validPostSeek &&
        validReleaseCount &&
        validChecksumHex &&
        validTransportState &&
        validPauseSeekMetrics &&
        hasNoLastError &&
        hasNoFailureReason;

    final String status;
    final String marker;
    final String lastError;

    if (pass) {
      status = rawStatus;
      marker = passMarkerConstant;
      lastError = '';
    } else {
      marker = (rawMarker == passMarkerConstant)
          ? failMarkerConstant
          : rawMarker;
      if (failureReason.isNotEmpty) {
        lastError = failureReason;
        status = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      } else if (!hasNoLastError) {
        lastError = explicitLastError;
        status = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      } else if (!hasValidProofBoundary) {
        lastError = 'proof_boundary_mismatch';
        status = 'proof_boundary_mismatch';
      } else if (!hasValidPassMarker) {
        lastError = 'marker_mismatch';
        status = 'marker_mismatch';
      } else if (!allRequiredLanesPresent) {
        lastError = 'missing_lane_${missingLanes.first}';
        status = 'missing_lane';
      } else if (!allRequiredLanesTrue) {
        lastError = 'lane_failed';
        status = 'lane_failed';
      } else if (!validFrameAccounting) {
        lastError = 'frame_accounting_mismatch';
        status = 'frame_accounting_mismatch';
      } else if (!validPostSeek) {
        lastError = 'post_seek_mismatch';
        status = 'post_seek_mismatch';
      } else if (!validReleaseCount) {
        lastError = 'release_count_mismatch';
        status = 'release_count_mismatch';
      } else if (!validChecksumHex) {
        lastError = 'checksum_hex_mismatch';
        status = 'checksum_hex_mismatch';
      } else if (!validTransportState) {
        lastError = 'transport_state_mismatch';
        status = 'transport_state_mismatch';
      } else if (!validPauseSeekMetrics) {
        lastError = 'pause_seek_metrics_mismatch';
        status = 'pause_seek_metrics_mismatch';
      } else {
        lastError = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
        status = rawStatus.toLowerCase() == 'pass' ? 'fail' : rawStatus;
      }
    }

    final finalLanes = <String, Object?>{
      'audioTrackInitOk': audioTrackInitOk,
      'mutedOutputOk': mutedOutputOk,
      'initialDrainOk': initialDrainOk,
      'pauseCommandOk': pauseCommandOk,
      'sinkPausedOk': sinkPausedOk,
      'pauseHoldFrozenOk': pauseHoldFrozenOk,
      'resumeCommandOk': resumeCommandOk,
      'sinkResumedOk': sinkResumedOk,
      'activeBeforeSeekOk': activeBeforeSeekOk,
      'seekCommandOk': seekCommandOk,
      'sinkFlushAtSeekOk': sinkFlushAtSeekOk,
      'postSeekDrainOk': postSeekDrainOk,
      'transportCompletedOk': transportCompletedOk,
      'checksumIdentityOk': checksumIdentityOk,
      'sinkWriteAccountingOk': sinkWriteAccountingOk,
      'audioTrackReleasedOk': audioTrackReleasedOk,
      'lifecycleOk': lifecycleOk,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{
      'sampleRate': sampleRate,
      'channelCount': channelCount,
      'maxFramesPerMix': maxFramesPerMix,
      'declaredFrameCount': declaredFrameCount,
      'pauseHoldMs': pauseHoldMs,
      'preControlFrames': preControlFrames,
      'seekTargetFrame': seekTargetFrame,
      'framesReadFromTransport': framesReadFromTransport,
      'framesWrittenPreSeek': framesWrittenPreSeek,
      'sinkFramesDiscardedAtSeek': sinkFramesDiscardedAtSeek,
      'framesWrittenPostSeek': framesWrittenPostSeek,
      'totalFramesWrittenToSink': totalFramesWrittenToSink,
      'expectedFramesWrittenToSink': expectedFramesWrittenToSink,
      'playbackHeadAtPause': playbackHeadAtPause,
      'playbackHeadAtSeek': playbackHeadAtSeek,
      'playbackHeadFinal': playbackHeadFinal,
      'pauseSnapshotDispatchCount': pauseSnapshotDispatchCount,
      'pauseSnapshotPushedFrames': pauseSnapshotPushedFrames,
      'pauseHoldDispatchDelta': pauseHoldDispatchDelta,
      'pauseHoldPushedDelta': pauseHoldPushedDelta,
      'activeProbeAttempts': activeProbeAttempts,
      'activeProbeDrainedFrames': activeProbeDrainedFrames,
      'seekGenerationBefore': seekGenerationBefore,
      'seekGenerationAfter': seekGenerationAfter,
      'seekReplyPositionFrame': seekReplyPositionFrame,
      'seekReplyDiscardedFrames': seekReplyDiscardedFrames,
      'finalReplyPositionFrame': finalReplyPositionFrame,
      'finalReplyDiscardedFrames': finalReplyDiscardedFrames,
      'drainIterations': drainIterations,
      'partialWriteCount': partialWriteCount,
      'zeroWriteCount': zeroWriteCount,
      'flushCount': flushCount,
      'releaseCount': releaseCount,
      'kotlinSinkChecksumHex': kotlinSinkChecksumHex,
      'nativeDrainedChecksumHex': nativeDrainedChecksumHex,
      'transportStopCalled': transportStopCalled,
      'transportStopAccepted': transportStopAccepted,
      'transportState': transportState,
      ...parsedMetrics,
    };

    return VGRealtimePlaybackInteractiveControlsSmokeReport(
      pass: pass,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      nativeProofBoundary: nativeProofBoundary,
      failureReason: failureReason,
      details: details,
      audioTrackInitOk: audioTrackInitOk,
      mutedOutputOk: mutedOutputOk,
      initialDrainOk: initialDrainOk,
      pauseCommandOk: pauseCommandOk,
      sinkPausedOk: sinkPausedOk,
      pauseHoldFrozenOk: pauseHoldFrozenOk,
      resumeCommandOk: resumeCommandOk,
      sinkResumedOk: sinkResumedOk,
      activeBeforeSeekOk: activeBeforeSeekOk,
      seekCommandOk: seekCommandOk,
      sinkFlushAtSeekOk: sinkFlushAtSeekOk,
      postSeekDrainOk: postSeekDrainOk,
      transportCompletedOk: transportCompletedOk,
      checksumIdentityOk: checksumIdentityOk,
      sinkWriteAccountingOk: sinkWriteAccountingOk,
      audioTrackReleasedOk: audioTrackReleasedOk,
      lifecycleOk: lifecycleOk,
      canonical: canonical,
      sampleRate: sampleRate,
      channelCount: channelCount,
      maxFramesPerMix: maxFramesPerMix,
      declaredFrameCount: declaredFrameCount,
      pauseHoldMs: pauseHoldMs,
      preControlFrames: preControlFrames,
      seekTargetFrame: seekTargetFrame,
      framesReadFromTransport: framesReadFromTransport,
      framesWrittenPreSeek: framesWrittenPreSeek,
      sinkFramesDiscardedAtSeek: sinkFramesDiscardedAtSeek,
      framesWrittenPostSeek: framesWrittenPostSeek,
      totalFramesWrittenToSink: totalFramesWrittenToSink,
      expectedFramesWrittenToSink: expectedFramesWrittenToSink,
      playbackHeadAtPause: playbackHeadAtPause,
      playbackHeadAtSeek: playbackHeadAtSeek,
      playbackHeadFinal: playbackHeadFinal,
      pauseSnapshotDispatchCount: pauseSnapshotDispatchCount,
      pauseSnapshotPushedFrames: pauseSnapshotPushedFrames,
      pauseHoldDispatchDelta: pauseHoldDispatchDelta,
      pauseHoldPushedDelta: pauseHoldPushedDelta,
      activeProbeAttempts: activeProbeAttempts,
      activeProbeDrainedFrames: activeProbeDrainedFrames,
      seekGenerationBefore: seekGenerationBefore,
      seekGenerationAfter: seekGenerationAfter,
      seekReplyPositionFrame: seekReplyPositionFrame,
      seekReplyDiscardedFrames: seekReplyDiscardedFrames,
      finalReplyPositionFrame: finalReplyPositionFrame,
      finalReplyDiscardedFrames: finalReplyDiscardedFrames,
      drainIterations: drainIterations,
      partialWriteCount: partialWriteCount,
      zeroWriteCount: zeroWriteCount,
      flushCount: flushCount,
      releaseCount: releaseCount,
      kotlinSinkChecksumHex: kotlinSinkChecksumHex,
      nativeDrainedChecksumHex: nativeDrainedChecksumHex,
      transportStopCalled: transportStopCalled,
      transportStopAccepted: transportStopAccepted,
      transportState: transportState,
      lanes: Map<String, Object?>.unmodifiable(finalLanes),
      metrics: Map<String, Object?>.unmodifiable(finalMetrics),
      lastError: lastError,
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
    };
  }

  Map<String, Object?> toJson() => toMap();

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  static VGRealtimePlaybackInteractiveControlsSmokeReport
  _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      'audioTrackInitOk': false,
      'mutedOutputOk': false,
      'initialDrainOk': false,
      'pauseCommandOk': false,
      'sinkPausedOk': false,
      'pauseHoldFrozenOk': false,
      'resumeCommandOk': false,
      'sinkResumedOk': false,
      'activeBeforeSeekOk': false,
      'seekCommandOk': false,
      'sinkFlushAtSeekOk': false,
      'postSeekDrainOk': false,
      'transportCompletedOk': false,
      'checksumIdentityOk': false,
      'sinkWriteAccountingOk': false,
      'audioTrackReleasedOk': false,
      'lifecycleOk': false,
      'canonical': false,
    };
    final metrics = <String, Object?>{
      'sampleRate': 0,
      'channelCount': 0,
      'maxFramesPerMix': 0,
      'declaredFrameCount': 0,
      'pauseHoldMs': 0,
      'preControlFrames': 0,
      'seekTargetFrame': 0,
      'framesReadFromTransport': 0,
      'framesWrittenPreSeek': 0,
      'sinkFramesDiscardedAtSeek': 0,
      'framesWrittenPostSeek': 0,
      'totalFramesWrittenToSink': 0,
      'expectedFramesWrittenToSink': 0,
      'playbackHeadAtPause': 0,
      'playbackHeadAtSeek': 0,
      'playbackHeadFinal': 0,
      'pauseSnapshotDispatchCount': 0,
      'pauseSnapshotPushedFrames': 0,
      'pauseHoldDispatchDelta': 0,
      'pauseHoldPushedDelta': 0,
      'activeProbeAttempts': 0,
      'activeProbeDrainedFrames': 0,
      'seekGenerationBefore': 0,
      'seekGenerationAfter': 0,
      'seekReplyPositionFrame': -1,
      'seekReplyDiscardedFrames': -1,
      'finalReplyPositionFrame': -1,
      'finalReplyDiscardedFrames': -1,
      'drainIterations': 0,
      'partialWriteCount': 0,
      'zeroWriteCount': 0,
      'flushCount': 0,
      'releaseCount': 0,
      'kotlinSinkChecksumHex': '',
      'nativeDrainedChecksumHex': '',
      'transportStopCalled': false,
      'transportStopAccepted': false,
      'transportState': '',
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGRealtimePlaybackInteractiveControlsSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      nativeProofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      audioTrackInitOk: false,
      mutedOutputOk: false,
      initialDrainOk: false,
      pauseCommandOk: false,
      sinkPausedOk: false,
      pauseHoldFrozenOk: false,
      resumeCommandOk: false,
      sinkResumedOk: false,
      activeBeforeSeekOk: false,
      seekCommandOk: false,
      sinkFlushAtSeekOk: false,
      postSeekDrainOk: false,
      transportCompletedOk: false,
      checksumIdentityOk: false,
      sinkWriteAccountingOk: false,
      audioTrackReleasedOk: false,
      lifecycleOk: false,
      canonical: false,
      sampleRate: 0,
      channelCount: 0,
      maxFramesPerMix: 0,
      declaredFrameCount: 0,
      pauseHoldMs: 0,
      preControlFrames: 0,
      seekTargetFrame: 0,
      framesReadFromTransport: 0,
      framesWrittenPreSeek: 0,
      sinkFramesDiscardedAtSeek: 0,
      framesWrittenPostSeek: 0,
      totalFramesWrittenToSink: 0,
      expectedFramesWrittenToSink: 0,
      playbackHeadAtPause: 0,
      playbackHeadAtSeek: 0,
      playbackHeadFinal: 0,
      pauseSnapshotDispatchCount: 0,
      pauseSnapshotPushedFrames: 0,
      pauseHoldDispatchDelta: 0,
      pauseHoldPushedDelta: 0,
      activeProbeAttempts: 0,
      activeProbeDrainedFrames: 0,
      seekGenerationBefore: 0,
      seekGenerationAfter: 0,
      seekReplyPositionFrame: -1,
      seekReplyDiscardedFrames: -1,
      finalReplyPositionFrame: -1,
      finalReplyDiscardedFrames: -1,
      drainIterations: 0,
      partialWriteCount: 0,
      zeroWriteCount: 0,
      flushCount: 0,
      releaseCount: 0,
      kotlinSinkChecksumHex: '',
      nativeDrainedChecksumHex: '',
      transportStopCalled: false,
      transportStopAccepted: false,
      transportState: '',
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      lastError: lastError,
    );
  }

  /// Invokes the Android True-DAG Phase 4 Realtime Playback Interactive Transport Controls
  /// diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation (defaults to 20 seconds).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGRealtimePlaybackInteractiveControlsSmokeReport>
  runRealtimePlaybackInteractiveControlsSmoke({
    Duration timeout = const Duration(seconds: 20),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(methodName);
      final raw = await future.timeout(timeout);
      return VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(raw);
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
    return other is VGRealtimePlaybackInteractiveControlsSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.nativeProofBoundary == nativeProofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.audioTrackInitOk == audioTrackInitOk &&
        other.mutedOutputOk == mutedOutputOk &&
        other.initialDrainOk == initialDrainOk &&
        other.pauseCommandOk == pauseCommandOk &&
        other.sinkPausedOk == sinkPausedOk &&
        other.pauseHoldFrozenOk == pauseHoldFrozenOk &&
        other.resumeCommandOk == resumeCommandOk &&
        other.sinkResumedOk == sinkResumedOk &&
        other.activeBeforeSeekOk == activeBeforeSeekOk &&
        other.seekCommandOk == seekCommandOk &&
        other.sinkFlushAtSeekOk == sinkFlushAtSeekOk &&
        other.postSeekDrainOk == postSeekDrainOk &&
        other.transportCompletedOk == transportCompletedOk &&
        other.checksumIdentityOk == checksumIdentityOk &&
        other.sinkWriteAccountingOk == sinkWriteAccountingOk &&
        other.audioTrackReleasedOk == audioTrackReleasedOk &&
        other.lifecycleOk == lifecycleOk &&
        other.canonical == canonical &&
        other.sampleRate == sampleRate &&
        other.channelCount == channelCount &&
        other.maxFramesPerMix == maxFramesPerMix &&
        other.declaredFrameCount == declaredFrameCount &&
        other.pauseHoldMs == pauseHoldMs &&
        other.preControlFrames == preControlFrames &&
        other.seekTargetFrame == seekTargetFrame &&
        other.framesReadFromTransport == framesReadFromTransport &&
        other.framesWrittenPreSeek == framesWrittenPreSeek &&
        other.sinkFramesDiscardedAtSeek == sinkFramesDiscardedAtSeek &&
        other.framesWrittenPostSeek == framesWrittenPostSeek &&
        other.totalFramesWrittenToSink == totalFramesWrittenToSink &&
        other.expectedFramesWrittenToSink == expectedFramesWrittenToSink &&
        other.playbackHeadAtPause == playbackHeadAtPause &&
        other.playbackHeadAtSeek == playbackHeadAtSeek &&
        other.playbackHeadFinal == playbackHeadFinal &&
        other.pauseSnapshotDispatchCount == pauseSnapshotDispatchCount &&
        other.pauseSnapshotPushedFrames == pauseSnapshotPushedFrames &&
        other.pauseHoldDispatchDelta == pauseHoldDispatchDelta &&
        other.pauseHoldPushedDelta == pauseHoldPushedDelta &&
        other.activeProbeAttempts == activeProbeAttempts &&
        other.activeProbeDrainedFrames == activeProbeDrainedFrames &&
        other.seekGenerationBefore == seekGenerationBefore &&
        other.seekGenerationAfter == seekGenerationAfter &&
        other.seekReplyPositionFrame == seekReplyPositionFrame &&
        other.seekReplyDiscardedFrames == seekReplyDiscardedFrames &&
        other.finalReplyPositionFrame == finalReplyPositionFrame &&
        other.finalReplyDiscardedFrames == finalReplyDiscardedFrames &&
        other.drainIterations == drainIterations &&
        other.partialWriteCount == partialWriteCount &&
        other.zeroWriteCount == zeroWriteCount &&
        other.flushCount == flushCount &&
        other.releaseCount == releaseCount &&
        other.kotlinSinkChecksumHex == kotlinSinkChecksumHex &&
        other.nativeDrainedChecksumHex == nativeDrainedChecksumHex &&
        other.transportStopCalled == transportStopCalled &&
        other.transportStopAccepted == transportStopAccepted &&
        other.transportState == transportState &&
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
    audioTrackInitOk,
    mutedOutputOk,
    initialDrainOk,
    pauseCommandOk,
    sinkPausedOk,
    pauseHoldFrozenOk,
    resumeCommandOk,
    sinkResumedOk,
    activeBeforeSeekOk,
    seekCommandOk,
    sinkFlushAtSeekOk,
    postSeekDrainOk,
    transportCompletedOk,
    checksumIdentityOk,
    sinkWriteAccountingOk,
    audioTrackReleasedOk,
    lifecycleOk,
    canonical,
    sampleRate,
    channelCount,
    maxFramesPerMix,
    declaredFrameCount,
    pauseHoldMs,
    preControlFrames,
    seekTargetFrame,
    framesReadFromTransport,
    framesWrittenPreSeek,
    sinkFramesDiscardedAtSeek,
    framesWrittenPostSeek,
    totalFramesWrittenToSink,
    expectedFramesWrittenToSink,
    playbackHeadAtPause,
    playbackHeadAtSeek,
    playbackHeadFinal,
    pauseSnapshotDispatchCount,
    pauseSnapshotPushedFrames,
    pauseHoldDispatchDelta,
    pauseHoldPushedDelta,
    activeProbeAttempts,
    activeProbeDrainedFrames,
    seekGenerationBefore,
    seekGenerationAfter,
    seekReplyPositionFrame,
    seekReplyDiscardedFrames,
    finalReplyPositionFrame,
    finalReplyDiscardedFrames,
    drainIterations,
    partialWriteCount,
    zeroWriteCount,
    flushCount,
    releaseCount,
    kotlinSinkChecksumHex,
    nativeDrainedChecksumHex,
    transportStopCalled,
    transportStopAccepted,
    transportState,
    lastError,
  ]);

  @override
  String toString() =>
      'VGRealtimePlaybackInteractiveControlsSmokeReport(pass: $pass, status: $status, '
      'marker: $marker, audioTrackInitOk: $audioTrackInitOk, '
      'mutedOutputOk: $mutedOutputOk, initialDrainOk: $initialDrainOk, '
      'pauseCommandOk: $pauseCommandOk, sinkPausedOk: $sinkPausedOk, '
      'pauseHoldFrozenOk: $pauseHoldFrozenOk, resumeCommandOk: $resumeCommandOk, '
      'sinkResumedOk: $sinkResumedOk, activeBeforeSeekOk: $activeBeforeSeekOk, '
      'seekCommandOk: $seekCommandOk, sinkFlushAtSeekOk: $sinkFlushAtSeekOk, '
      'postSeekDrainOk: $postSeekDrainOk, transportCompletedOk: $transportCompletedOk, '
      'checksumIdentityOk: $checksumIdentityOk, sinkWriteAccountingOk: $sinkWriteAccountingOk, '
      'audioTrackReleasedOk: $audioTrackReleasedOk, lifecycleOk: $lifecycleOk, '
      'canonical: $canonical, releaseCount: $releaseCount, '
      'framesWrittenPreSeek: $framesWrittenPreSeek, '
      'framesWrittenPostSeek: $framesWrittenPostSeek, '
      'totalFramesWrittenToSink: $totalFramesWrittenToSink, '
      'expectedFramesWrittenToSink: $expectedFramesWrittenToSink, '
      'declaredFrameCount: $declaredFrameCount, lastError: $lastError)';
}
