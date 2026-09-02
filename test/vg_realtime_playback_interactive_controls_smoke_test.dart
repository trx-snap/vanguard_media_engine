// vg_realtime_playback_interactive_controls_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-INTERACTIVE-CONTROLS (Y3): Android True-DAG Phase 4
// realtime playback interactive transport controls diagnostic smoke foundation
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'muted_diagnostic_audiotrack_interactive_controls_only_synthetic_pcm_from_y1_transport_no_mediacodec_no_mediaextractor_no_audio_focus_no_route_change_no_dead_object_recovery_no_production_presentation_clock_no_av_sync_no_audible_output_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_native_cpp_changes';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_SMOKE_START';
const _kJsonMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'audioTrackInitOk': true,
    'mutedOutputOk': true,
    'initialDrainOk': true,
    'pauseCommandOk': true,
    'sinkPausedOk': true,
    'pauseHoldFrozenOk': true,
    'resumeCommandOk': true,
    'sinkResumedOk': true,
    'activeBeforeSeekOk': true,
    'seekCommandOk': true,
    'sinkFlushAtSeekOk': true,
    'postSeekDrainOk': true,
    'transportCompletedOk': true,
    'checksumIdentityOk': true,
    'sinkWriteAccountingOk': true,
    'audioTrackReleasedOk': true,
    'lifecycleOk': true,
    'canonical': true,
  };

  final metrics = <String, Object?>{
    'sampleRate': 48000,
    'channelCount': 2,
    'maxFramesPerMix': 256,
    'declaredFrameCount': 12000,
    'pauseHoldMs': 150,
    'preControlFrames': 4096,
    'seekTargetFrame': 6000,
    'framesReadFromTransport': 10096,
    'framesWrittenPreSeek': 4096,
    'sinkFramesDiscardedAtSeek': 4096,
    'framesWrittenPostSeek': 6000,
    'totalFramesWrittenToSink': 10096,
    'expectedFramesWrittenToSink': 10096,
    'playbackHeadAtPause': 4096,
    'playbackHeadAtSeek': 4096,
    'playbackHeadFinal': 6000,
    'pauseSnapshotDispatchCount': 16,
    'pauseSnapshotPushedFrames': 4096,
    'pauseHoldDispatchDelta': 0,
    'pauseHoldPushedDelta': 0,
    'activeProbeAttempts': 1,
    'activeProbeDrainedFrames': 0,
    'seekGenerationBefore': 0,
    'seekGenerationAfter': 1,
    'seekReplyPositionFrame': 6000,
    'seekReplyDiscardedFrames': 0,
    'finalReplyPositionFrame': 12000,
    'finalReplyDiscardedFrames': 0,
    'drainIterations': 40,
    'partialWriteCount': 0,
    'zeroWriteCount': 0,
    'flushCount': 1,
    'releaseCount': 1,
    'kotlinSinkChecksumHex': '00000000abcdef12',
    'nativeDrainedChecksumHex': '00000000abcdef12',
    'transportStopCalled': false,
    'transportStopAccepted': false,
    'transportState': 'COMPLETED',
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'nativeProofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'Y3 realtime playback interactive controls harness pass=true',
    'lanes': lanes,
    'metrics': metrics,
    'lastError': null,
    'raw': 'pass=true;status=pass;marker=$_kPassMarker',
  };

  if (overrides != null) {
    for (final entry in overrides.entries) {
      if (lanes.containsKey(entry.key)) {
        lanes[entry.key] = entry.value;
      }
      if (metrics.containsKey(entry.key)) {
        metrics[entry.key] = entry.value;
      }
      result[entry.key] = entry.value;
    }
  }

  return result;
}

VGRealtimePlaybackInteractiveControlsSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(
  _createSampleRawMap(overrides),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGRealtimePlaybackInteractiveControlsSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.methodName,
        equals('runRealtimePlaybackInteractiveControlsSmoke'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.startMarkerConstant,
        equals(_kStartMarker),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.jsonMarkerConstant,
        equals(_kJsonMarker),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport
            .requiredNativeLaneKeys
            .length,
        equals(18),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('audioTrackInitOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('mutedOutputOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('initialDrainOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('pauseCommandOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('sinkPausedOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('pauseHoldFrozenOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('resumeCommandOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('sinkResumedOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('activeBeforeSeekOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('seekCommandOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('sinkFlushAtSeekOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('postSeekDrainOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('transportCompletedOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('checksumIdentityOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('sinkWriteAccountingOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('audioTrackReleasedOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('lifecycleOk'),
      );
      expect(
        VGRealtimePlaybackInteractiveControlsSmokeReport.requiredNativeLaneKeys,
        contains('canonical'),
      );
    });
  });

  group('VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap parsing', () {
    test('pass payload parses true with all lanes and metrics', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.status, equals('pass'));
      expect(report.marker, equals(_kPassMarker));
      expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.nativeProofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.lastError, isEmpty);
      expect(report.failureReason, isEmpty);

      // Verify lanes
      expect(report.audioTrackInitOk, isTrue);
      expect(report.mutedOutputOk, isTrue);
      expect(report.initialDrainOk, isTrue);
      expect(report.pauseCommandOk, isTrue);
      expect(report.sinkPausedOk, isTrue);
      expect(report.pauseHoldFrozenOk, isTrue);
      expect(report.resumeCommandOk, isTrue);
      expect(report.sinkResumedOk, isTrue);
      expect(report.activeBeforeSeekOk, isTrue);
      expect(report.seekCommandOk, isTrue);
      expect(report.sinkFlushAtSeekOk, isTrue);
      expect(report.postSeekDrainOk, isTrue);
      expect(report.transportCompletedOk, isTrue);
      expect(report.checksumIdentityOk, isTrue);
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.audioTrackReleasedOk, isTrue);
      expect(report.lifecycleOk, isTrue);
      expect(report.canonical, isTrue);

      // Verify metrics
      expect(report.sampleRate, equals(48000));
      expect(report.channelCount, equals(2));
      expect(report.maxFramesPerMix, equals(256));
      expect(report.declaredFrameCount, equals(12000));
      expect(report.pauseHoldMs, equals(150));
      expect(report.preControlFrames, equals(4096));
      expect(report.seekTargetFrame, equals(6000));
      expect(report.framesReadFromTransport, equals(10096));
      expect(report.framesWrittenPreSeek, equals(4096));
      expect(report.sinkFramesDiscardedAtSeek, equals(4096));
      expect(report.framesWrittenPostSeek, equals(6000));
      expect(report.totalFramesWrittenToSink, equals(10096));
      expect(report.expectedFramesWrittenToSink, equals(10096));
      expect(report.playbackHeadAtPause, equals(4096));
      expect(report.playbackHeadAtSeek, equals(4096));
      expect(report.playbackHeadFinal, equals(6000));
      expect(report.pauseSnapshotDispatchCount, equals(16));
      expect(report.pauseSnapshotPushedFrames, equals(4096));
      expect(report.pauseHoldDispatchDelta, equals(0));
      expect(report.pauseHoldPushedDelta, equals(0));
      expect(report.activeProbeAttempts, equals(1));
      expect(report.activeProbeDrainedFrames, equals(0));
      expect(report.seekGenerationBefore, equals(0));
      expect(report.seekGenerationAfter, equals(1));
      expect(report.seekReplyPositionFrame, equals(6000));
      expect(report.seekReplyDiscardedFrames, equals(0));
      expect(report.finalReplyPositionFrame, equals(12000));
      expect(report.finalReplyDiscardedFrames, equals(0));
      expect(report.drainIterations, equals(40));
      expect(report.partialWriteCount, equals(0));
      expect(report.zeroWriteCount, equals(0));
      expect(report.flushCount, equals(1));
      expect(report.releaseCount, equals(1));
      expect(report.kotlinSinkChecksumHex, equals('00000000abcdef12'));
      expect(report.nativeDrainedChecksumHex, equals('00000000abcdef12'));
      expect(report.transportState, equals('COMPLETED'));
    });

    test('missing required lane fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes.remove('pauseHoldFrozenOk');
      raw['lanes'] = lanes;

      final report = VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(
        raw,
      );
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('missing_lane'));
      expect(report.lastError, equals('missing_lane_pauseHoldFrozenOk'));
    });

    test('proof boundary mismatch fails closed', () {
      final raw = _createSampleRawMap({
        'proofBoundary': 'invalid_proof_boundary_string',
      });
      final report = VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.lastError, equals('proof_boundary_mismatch'));
    });

    test('marker mismatch fails closed', () {
      final raw = _createSampleRawMap({'marker': 'INVALID_MARKER'});
      final report = VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.lastError, equals('marker_mismatch'));
    });

    test('pass true with false lane fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes['sinkFlushAtSeekOk'] = false;
      raw['lanes'] = lanes;

      final report = VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(
        raw,
      );
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.sinkFlushAtSeekOk, isFalse);
      expect(report.status, equals('lane_failed'));
      expect(report.lastError, equals('lane_failed'));
    });

    test('frame accounting mismatch fails closed', () {
      final raw = _createSampleRawMap({
        'totalFramesWrittenToSink': 9000,
        'expectedFramesWrittenToSink': 10096,
      });
      final report = VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('frame_accounting_mismatch'));
      expect(report.lastError, equals('frame_accounting_mismatch'));
    });

    test('post seek mismatch fails closed', () {
      final raw = _createSampleRawMap({'framesWrittenPostSeek': 5000});
      final report = VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.lastError, equals('frame_accounting_mismatch'));
    });

    test('release count mismatch fails closed', () {
      final raw = _createSampleRawMap({'releaseCount': 0});
      final report = VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('release_count_mismatch'));
      expect(report.lastError, equals('release_count_mismatch'));
    });

    test('checksum mismatch fails closed', () {
      final raw = _createSampleRawMap({
        'kotlinSinkChecksumHex': '0000000011111111',
        'nativeDrainedChecksumHex': '0000000022222222',
      });
      final report = VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('checksum_hex_mismatch'));
      expect(report.lastError, equals('checksum_hex_mismatch'));
    });

    test('transport state mismatch fails closed', () {
      final raw = _createSampleRawMap({'transportState': 'PLAYING'});
      final report = VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('transport_state_mismatch'));
      expect(report.lastError, equals('transport_state_mismatch'));
    });

    test('pause / seek metrics mismatch fails closed', () {
      final raw = _createSampleRawMap({'pauseHoldDispatchDelta': 1});
      final report = VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('pause_seek_metrics_mismatch'));
      expect(report.lastError, equals('pause_seek_metrics_mismatch'));
    });

    test('native failure payload propagates failure reason', () {
      final raw = _createSampleRawMap({
        'pass': false,
        'status': 'fail',
        'marker': _kFailMarker,
        'failureReason': 'pause_hold_not_frozen',
      });
      final report = VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.failureReason, equals('pause_hold_not_frozen'));
      expect(report.lastError, equals('pause_hold_not_frozen'));
    });

    test('malformed payload fails closed (non-map)', () {
      final report = VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(
        null,
      );
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('native_result_not_a_map'));
      expect(report.lastError, equals('native_result_not_a_map'));
      expect(report.audioTrackInitOk, isFalse);
      expect(report.transportCompletedOk, isFalse);
    });

    test('string-encoded and numeric values parse defensively', () {
      final raw = <String, Object?>{
        'pass': 'true',
        'status': 'PASS',
        'marker': _kPassMarker,
        'proofBoundary': _kCanonicalProofBoundary,
        'lanes': <String, Object?>{
          'audioTrackInitOk': 'true',
          'mutedOutputOk': 'true',
          'initialDrainOk': 'true',
          'pauseCommandOk': 'true',
          'sinkPausedOk': 'true',
          'pauseHoldFrozenOk': 'true',
          'resumeCommandOk': 'true',
          'sinkResumedOk': 'true',
          'activeBeforeSeekOk': 'true',
          'seekCommandOk': 'true',
          'sinkFlushAtSeekOk': 'true',
          'postSeekDrainOk': 'true',
          'transportCompletedOk': 'true',
          'checksumIdentityOk': 'true',
          'sinkWriteAccountingOk': 'true',
          'audioTrackReleasedOk': 'true',
          'lifecycleOk': 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{
          'sampleRate': '48000',
          'channelCount': '2',
          'maxFramesPerMix': '256',
          'declaredFrameCount': '12000',
          'pauseHoldMs': '150',
          'preControlFrames': '4096',
          'seekTargetFrame': '6000',
          'framesReadFromTransport': '10096',
          'framesWrittenPreSeek': '4096',
          'sinkFramesDiscardedAtSeek': '4096',
          'framesWrittenPostSeek': '6000',
          'totalFramesWrittenToSink': '10096',
          'expectedFramesWrittenToSink': '10096',
          'playbackHeadAtPause': '4096',
          'playbackHeadAtSeek': '4096',
          'playbackHeadFinal': '6000',
          'pauseSnapshotDispatchCount': '16',
          'pauseSnapshotPushedFrames': '4096',
          'pauseHoldDispatchDelta': '0',
          'pauseHoldPushedDelta': '0',
          'activeProbeAttempts': '1',
          'activeProbeDrainedFrames': '0',
          'seekGenerationBefore': '0',
          'seekGenerationAfter': '1',
          'seekReplyPositionFrame': '6000',
          'seekReplyDiscardedFrames': '0',
          'finalReplyPositionFrame': '12000',
          'finalReplyDiscardedFrames': '0',
          'drainIterations': '40',
          'partialWriteCount': '0',
          'zeroWriteCount': '0',
          'flushCount': '1',
          'releaseCount': '1',
          'kotlinSinkChecksumHex': '00000000abcdef12',
          'nativeDrainedChecksumHex': '00000000abcdef12',
          'transportStopCalled': 'false',
          'transportStopAccepted': 'false',
          'transportState': 'COMPLETED',
        },
      };

      final report = VGRealtimePlaybackInteractiveControlsSmokeReport.fromMap(
        raw,
      );
      expect(report.pass, isTrue);
      expect(report.audioTrackInitOk, isTrue);
      expect(report.declaredFrameCount, equals(12000));
      expect(report.releaseCount, equals(1));
      expect(report.transportCompletedOk, isTrue);
      expect(report.checksumIdentityOk, isTrue);
    });

    test('toMap and toJson serialization preserves structure', () {
      final report = _createSampleReport();
      final map = report.toMap();

      expect(map['pass'], isTrue);
      expect(map['status'], equals('pass'));
      expect(map['marker'], equals(_kPassMarker));
      expect(map['proofBoundary'], equals(_kCanonicalProofBoundary));
      expect(map['lanes'], isA<Map>());
      expect(map['metrics'], isA<Map>());

      final jsonMap = report.toJson();
      expect(jsonMap, equals(map));
    });

    test('equality, hashCode, and toString work correctly', () {
      final report1 = _createSampleReport();
      final report2 = _createSampleReport();
      final report3 = _createSampleReport({'playbackHeadFinal': 5000});
      final report4 = _createSampleReport({'checksumIdentityOk': false});

      expect(report1, equals(report2));
      expect(report1.hashCode, equals(report2.hashCode));
      expect(report1, isNot(equals(report3)));
      expect(report1, isNot(equals(report4)));
      expect(
        report1.toString(),
        contains('VGRealtimePlaybackInteractiveControlsSmokeReport'),
      );
      expect(report1.toString(), contains('audioTrackInitOk: true'));
    });
  });

  group('VGRealtimePlaybackInteractiveControlsSmokeReport MethodChannel invocation', () {
    test('successful channel invocation returns report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runRealtimePlaybackInteractiveControlsSmoke') {
          return _createSampleRawMap();
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackInteractiveControlsSmokeReport.runRealtimePlaybackInteractiveControlsSmoke();

      expect(report.pass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.hasPassMarker, isTrue);
    });

    test('PlatformException produces fallback error report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runRealtimePlaybackInteractiveControlsSmoke') {
          throw PlatformException(
            code: 'P4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_SMOKE_BUSY',
            message: 'Diagnostic already running',
          );
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackInteractiveControlsSmokeReport.runRealtimePlaybackInteractiveControlsSmoke();

      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_SMOKE_BUSY',
        ),
      );
      expect(
        report.lastError,
        contains(
          'platform_exception:P4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_SMOKE_BUSY:Diagnostic already running',
        ),
      );
    });

    test('TimeoutException produces fallback error report', () async {
      final customChannel = const MethodChannel(
        'vanguard_media_engine_controls_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });

      final report =
          await VGRealtimePlaybackInteractiveControlsSmokeReport.runRealtimePlaybackInteractiveControlsSmoke(
            timeout: const Duration(milliseconds: 10),
            channel: customChannel,
          );

      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('timeout'));
      expect(report.lastError, contains('timeout:'));
    });
  });
}
