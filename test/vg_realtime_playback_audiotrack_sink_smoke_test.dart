// vg_realtime_playback_audiotrack_sink_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-AUDIOTRACK-SINK (Y2): Android True-DAG Phase 4
// realtime playback AudioTrack sink diagnostic smoke foundation
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'muted_diagnostic_audiotrack_sink_only_synthetic_pcm_input_expected_from_y1_transport_no_mediacodec_no_mediaextractor_no_audio_focus_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_SMOKE_START';
const _kJsonMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'audioTrackInitOk': true,
    'mutedOutputOk': true,
    'transportCompletedOk': true,
    'checksumIdentityOk': true,
    'sinkWriteAccountingOk': true,
    'playbackHeadAdvancedOk': true,
    'audioTrackReleasedOk': true,
    'lifecycleOk': true,
    'canonical': true,
  };

  final metrics = <String, Object?>{
    'sampleRate': 48000,
    'channelCount': 2,
    'maxFramesPerMix': 256,
    'declaredFrameCount': 12000,
    'framesReadFromTransport': 12000,
    'framesWrittenToSink': 12000,
    'partialWriteCount': 0,
    'zeroWriteCount': 0,
    'playbackHeadFinal': 12000,
    'releaseCount': 1,
    'kotlinSinkChecksumHex': '00000000abcdef12',
    'nativeDrainedChecksumHex': '00000000abcdef12',
    'transportState': 'COMPLETED',
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'nativeProofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'Y2 realtime playback AudioTrack sink harness pass=true',
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

VGRealtimePlaybackAudioTrackSinkSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGRealtimePlaybackAudioTrackSinkSmokeReport.fromMap(
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

  group('VGRealtimePlaybackAudioTrackSinkSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.methodName,
        equals('runRealtimePlaybackAudioTrackSinkSmoke'),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.startMarkerConstant,
        equals(_kStartMarker),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.jsonMarkerConstant,
        equals(_kJsonMarker),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport
            .requiredNativeLaneKeys
            .length,
        equals(9),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.requiredNativeLaneKeys,
        contains('audioTrackInitOk'),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.requiredNativeLaneKeys,
        contains('mutedOutputOk'),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.requiredNativeLaneKeys,
        contains('transportCompletedOk'),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.requiredNativeLaneKeys,
        contains('checksumIdentityOk'),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.requiredNativeLaneKeys,
        contains('sinkWriteAccountingOk'),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.requiredNativeLaneKeys,
        contains('playbackHeadAdvancedOk'),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.requiredNativeLaneKeys,
        contains('audioTrackReleasedOk'),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.requiredNativeLaneKeys,
        contains('lifecycleOk'),
      );
      expect(
        VGRealtimePlaybackAudioTrackSinkSmokeReport.requiredNativeLaneKeys,
        contains('canonical'),
      );
    });
  });

  group('VGRealtimePlaybackAudioTrackSinkSmokeReport.fromMap parsing', () {
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
      expect(report.transportCompletedOk, isTrue);
      expect(report.checksumIdentityOk, isTrue);
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.playbackHeadAdvancedOk, isTrue);
      expect(report.audioTrackReleasedOk, isTrue);
      expect(report.lifecycleOk, isTrue);
      expect(report.canonical, isTrue);

      // Verify metrics
      expect(report.sampleRate, equals(48000));
      expect(report.channelCount, equals(2));
      expect(report.maxFramesPerMix, equals(256));
      expect(report.declaredFrameCount, equals(12000));
      expect(report.framesReadFromTransport, equals(12000));
      expect(report.framesWrittenToSink, equals(12000));
      expect(report.partialWriteCount, equals(0));
      expect(report.zeroWriteCount, equals(0));
      expect(report.playbackHeadFinal, equals(12000));
      expect(report.releaseCount, equals(1));
      expect(report.kotlinSinkChecksumHex, equals('00000000abcdef12'));
      expect(report.nativeDrainedChecksumHex, equals('00000000abcdef12'));
      expect(report.transportState, equals('COMPLETED'));
    });

    test('missing required lane fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes.remove('checksumIdentityOk');
      raw['lanes'] = lanes;

      final report = VGRealtimePlaybackAudioTrackSinkSmokeReport.fromMap(raw);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('missing_lane'));
      expect(report.lastError, equals('missing_lane_checksumIdentityOk'));
    });

    test('proof boundary mismatch fails closed', () {
      final raw = _createSampleRawMap({
        'proofBoundary': 'invalid_proof_boundary_string',
      });
      final report = VGRealtimePlaybackAudioTrackSinkSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.lastError, equals('proof_boundary_mismatch'));
    });

    test('marker mismatch fails closed', () {
      final raw = _createSampleRawMap({'marker': 'INVALID_MARKER'});
      final report = VGRealtimePlaybackAudioTrackSinkSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.lastError, equals('marker_mismatch'));
    });

    test('pass true with false lane fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes['sinkWriteAccountingOk'] = false;
      raw['lanes'] = lanes;

      final report = VGRealtimePlaybackAudioTrackSinkSmokeReport.fromMap(raw);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.sinkWriteAccountingOk, isFalse);
      expect(report.status, equals('lane_failed'));
      expect(report.lastError, equals('lane_failed'));
    });

    test('frame accounting mismatch fails closed', () {
      final raw = _createSampleRawMap({
        'framesReadFromTransport': 12000,
        'framesWrittenToSink': 11000,
      });
      final report = VGRealtimePlaybackAudioTrackSinkSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('frame_accounting_mismatch'));
      expect(report.lastError, equals('frame_accounting_mismatch'));
    });

    test('release count mismatch fails closed', () {
      final raw = _createSampleRawMap({'releaseCount': 0});
      final report = VGRealtimePlaybackAudioTrackSinkSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('release_count_mismatch'));
      expect(report.lastError, equals('release_count_mismatch'));
    });

    test('native failure payload propagates failure reason', () {
      final raw = _createSampleRawMap({
        'pass': false,
        'status': 'fail',
        'marker': _kFailMarker,
        'failureReason': 'audio_track_not_initialized',
      });
      final report = VGRealtimePlaybackAudioTrackSinkSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.failureReason, equals('audio_track_not_initialized'));
      expect(report.lastError, equals('audio_track_not_initialized'));
    });

    test('malformed payload fails closed (non-map)', () {
      final report = VGRealtimePlaybackAudioTrackSinkSmokeReport.fromMap(null);
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
          'transportCompletedOk': 'true',
          'checksumIdentityOk': 'true',
          'sinkWriteAccountingOk': 'true',
          'playbackHeadAdvancedOk': 'true',
          'audioTrackReleasedOk': 'true',
          'lifecycleOk': 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{
          'sampleRate': '48000',
          'channelCount': '2',
          'maxFramesPerMix': '256',
          'declaredFrameCount': '12000',
          'framesReadFromTransport': '12000',
          'framesWrittenToSink': '12000',
          'partialWriteCount': '0',
          'zeroWriteCount': '0',
          'playbackHeadFinal': '12000',
          'releaseCount': '1',
          'kotlinSinkChecksumHex': '00000000abcdef12',
          'nativeDrainedChecksumHex': '00000000abcdef12',
          'transportState': 'COMPLETED',
        },
      };

      final report = VGRealtimePlaybackAudioTrackSinkSmokeReport.fromMap(raw);
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
      final report3 = _createSampleReport({'playbackHeadFinal': 6000});
      final report4 = _createSampleReport({'checksumIdentityOk': false});

      expect(report1, equals(report2));
      expect(report1.hashCode, equals(report2.hashCode));
      expect(report1, isNot(equals(report3)));
      expect(report1, isNot(equals(report4)));
      expect(
        report1.toString(),
        contains('VGRealtimePlaybackAudioTrackSinkSmokeReport'),
      );
      expect(report1.toString(), contains('audioTrackInitOk: true'));
    });
  });

  group('VGRealtimePlaybackAudioTrackSinkSmokeReport MethodChannel invocation', () {
    test('successful channel invocation returns report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runRealtimePlaybackAudioTrackSinkSmoke') {
          return _createSampleRawMap();
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackAudioTrackSinkSmokeReport.runRealtimePlaybackAudioTrackSinkSmoke();

      expect(report.pass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.hasPassMarker, isTrue);
    });

    test('PlatformException produces fallback error report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runRealtimePlaybackAudioTrackSinkSmoke') {
          throw PlatformException(
            code: 'P4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_SMOKE_BUSY',
            message: 'Diagnostic already running',
          );
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackAudioTrackSinkSmokeReport.runRealtimePlaybackAudioTrackSinkSmoke();

      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_SMOKE_BUSY',
        ),
      );
      expect(
        report.lastError,
        contains(
          'platform_exception:P4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_SMOKE_BUSY:Diagnostic already running',
        ),
      );
    });

    test('TimeoutException produces fallback error report', () async {
      final customChannel = const MethodChannel(
        'vanguard_media_engine_sink_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });

      final report =
          await VGRealtimePlaybackAudioTrackSinkSmokeReport.runRealtimePlaybackAudioTrackSinkSmoke(
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
