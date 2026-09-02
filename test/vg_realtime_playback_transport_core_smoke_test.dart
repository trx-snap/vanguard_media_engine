// vg_realtime_playback_transport_core_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-TRANSPORT-CORE (Y1): Android True-DAG Phase 4
// realtime playback transport core diagnostic smoke foundation
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'synthetic_pcm_only, no_audiotrack, no_mediacodec, no_mediaextractor, '
    'no_audiomanager, no_audible_output, no_product_editor_app_wiring, no_ios';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_SMOKE_START';
const _kJsonMarker = 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'trackAdmissionOk': true,
    'partialEosTailOk': true,
    'reentrantSequenceOk': true,
    'pausedSeekStaysPausedOk': true,
    'wrongOwnerDirectProbeOk': true,
    'registryCapacityOk': true,
    'destroyIdempotenceOk': true,
    'proofBoundaryOk': true,
    'reentrantForwardSeekNonQuiescentOk': true,
    'canonical': true,
  };

  final metrics = <String, Object?>{
    'trackAdmission1Ok': true,
    'trackAdmission2Ok': true,
    'trackAdmission8Ok': true,
    'trackAdmission9RejectedOk': true,
    'partialEosTailRenderedFrames': 1000,
    'partialEosTailPushedFrames': 1000,
    'partialEosTailDrainedFrames': 1000,
    'partialEosTailPushedChecksumHex': '0000000012345678',
    'partialEosTailDrainedChecksumHex': '0000000012345678',
    'reentrantHoldDispatchUnchangedOk': true,
    'reentrantHoldPushedUnchangedOk': true,
    'reentrantForwardSeekNonQuiescentOk': true,
    'reentrantSeekForwardOk': true,
    'reentrantSeekBackwardOk': true,
    'reentrantRestartAndEosOk': true,
    'pausedSeekStayedPaused': true,
    'wrongOwnerStatus': 'wrong_owner_thread',
    'wrongOwnerFlag': true,
    'registryCapacityCount': 4,
    'registryFifthFailedOk': true,
    'firstDestroyStatus': 'ok',
    'firstDestroyWorkerJoined': true,
    'firstDestroyWorkerExited': true,
    'nativeSecondDestroyStatus': 'not_found',
    'wrapperSecondDestroyStatus': 'session_closed',
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'nativeProofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'Y1 realtime playback transport core harness pass=true',
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

VGRealtimePlaybackTransportCoreSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGRealtimePlaybackTransportCoreSmokeReport.fromMap(
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

  group('VGRealtimePlaybackTransportCoreSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.methodName,
        equals('runRealtimePlaybackTransportCoreSmoke'),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.startMarkerConstant,
        equals(_kStartMarker),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.jsonMarkerConstant,
        equals(_kJsonMarker),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport
            .requiredNativeLaneKeys
            .length,
        equals(9),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.requiredNativeLaneKeys,
        contains('trackAdmissionOk'),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.requiredNativeLaneKeys,
        contains('partialEosTailOk'),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.requiredNativeLaneKeys,
        contains('reentrantSequenceOk'),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.requiredNativeLaneKeys,
        contains('pausedSeekStaysPausedOk'),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.requiredNativeLaneKeys,
        contains('wrongOwnerDirectProbeOk'),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.requiredNativeLaneKeys,
        contains('registryCapacityOk'),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.requiredNativeLaneKeys,
        contains('destroyIdempotenceOk'),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.requiredNativeLaneKeys,
        contains('proofBoundaryOk'),
      );
      expect(
        VGRealtimePlaybackTransportCoreSmokeReport.requiredNativeLaneKeys,
        contains('reentrantForwardSeekNonQuiescentOk'),
      );
    });
  });

  group('VGRealtimePlaybackTransportCoreSmokeReport.fromMap parsing', () {
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

      // Verify all 8 lanes + canonical
      expect(report.trackAdmissionOk, isTrue);
      expect(report.partialEosTailOk, isTrue);
      expect(report.reentrantSequenceOk, isTrue);
      expect(report.pausedSeekStaysPausedOk, isTrue);
      expect(report.wrongOwnerDirectProbeOk, isTrue);
      expect(report.registryCapacityOk, isTrue);
      expect(report.destroyIdempotenceOk, isTrue);
      expect(report.proofBoundaryOk, isTrue);
      expect(report.canonical, isTrue);

      // Verify metrics
      expect(report.trackAdmission1Ok, isTrue);
      expect(report.trackAdmission2Ok, isTrue);
      expect(report.trackAdmission8Ok, isTrue);
      expect(report.trackAdmission9RejectedOk, isTrue);
      expect(report.partialEosTailRenderedFrames, equals(1000));
      expect(report.partialEosTailPushedFrames, equals(1000));
      expect(report.partialEosTailDrainedFrames, equals(1000));
      expect(
        report.partialEosTailPushedChecksumHex,
        equals('0000000012345678'),
      );
      expect(
        report.partialEosTailDrainedChecksumHex,
        equals('0000000012345678'),
      );
      expect(report.reentrantHoldDispatchUnchangedOk, isTrue);
      expect(report.reentrantHoldPushedUnchangedOk, isTrue);
      expect(report.reentrantForwardSeekNonQuiescentOk, isTrue);
      expect(report.reentrantSeekForwardOk, isTrue);
      expect(report.reentrantSeekBackwardOk, isTrue);
      expect(report.reentrantRestartAndEosOk, isTrue);
      expect(report.pausedSeekStayedPaused, isTrue);
      expect(report.wrongOwnerStatus, equals('wrong_owner_thread'));
      expect(report.wrongOwnerFlag, isTrue);
      expect(report.registryCapacityCount, equals(4));
      expect(report.registryFifthFailedOk, isTrue);
      expect(report.firstDestroyStatus, equals('ok'));
      expect(report.firstDestroyWorkerJoined, isTrue);
      expect(report.firstDestroyWorkerExited, isTrue);
      expect(report.nativeSecondDestroyStatus, equals('not_found'));
      expect(report.wrapperSecondDestroyStatus, equals('session_closed'));
    });

    test('missing required lane fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes.remove('partialEosTailOk');
      raw['lanes'] = lanes;

      final report = VGRealtimePlaybackTransportCoreSmokeReport.fromMap(raw);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('missing_lane'));
      expect(report.lastError, equals('missing_lane_partialEosTailOk'));
    });

    test('proof boundary mismatch fails closed', () {
      final raw = _createSampleRawMap({
        'proofBoundary': 'invalid_proof_boundary_string',
      });
      final report = VGRealtimePlaybackTransportCoreSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.lastError, equals('proof_boundary_mismatch'));
    });

    test('marker mismatch fails closed', () {
      final raw = _createSampleRawMap({'marker': 'INVALID_MARKER'});
      final report = VGRealtimePlaybackTransportCoreSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.lastError, equals('marker_mismatch'));
    });

    test('pass true with false lane fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes['pausedSeekStaysPausedOk'] = false;
      raw['lanes'] = lanes;

      final report = VGRealtimePlaybackTransportCoreSmokeReport.fromMap(raw);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.pausedSeekStaysPausedOk, isFalse);
      expect(report.status, equals('lane_failed'));
      expect(report.lastError, equals('lane_failed'));
    });

    test(
      'false reentrantForwardSeekNonQuiescentOk independently fails pass and allNativeLanesPass when parent lanes claim true',
      () {
        final raw = _createSampleRawMap({
          'pass': true,
          'status': 'pass',
          'marker': _kPassMarker,
          'proofBoundary': _kCanonicalProofBoundary,
          'reentrantSequenceOk': true,
          'reentrantSeekForwardOk': true,
          'reentrantForwardSeekNonQuiescentOk': false,
        });
        final report = VGRealtimePlaybackTransportCoreSmokeReport.fromMap(raw);
        expect(report.pass, isFalse);
        expect(report.allNativeLanesPass, isFalse);
        expect(report.reentrantForwardSeekNonQuiescentOk, isFalse);
        expect(report.reentrantSeekForwardOk, isTrue);
        expect(report.reentrantSequenceOk, isTrue);
        expect(report.marker, equals(_kFailMarker));
        expect(report.status, equals('lane_failed'));
        expect(report.lastError, equals('lane_failed'));
      },
    );

    test('missing reentrantForwardSeekNonQuiescentOk fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      final metrics = Map<String, Object?>.from(raw['metrics'] as Map);
      lanes.remove('reentrantForwardSeekNonQuiescentOk');
      metrics.remove('reentrantForwardSeekNonQuiescentOk');
      raw['lanes'] = lanes;
      raw['metrics'] = metrics;
      raw.remove('reentrantForwardSeekNonQuiescentOk');

      final report = VGRealtimePlaybackTransportCoreSmokeReport.fromMap(raw);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('missing_lane'));
      expect(
        report.lastError,
        equals('missing_lane_reentrantForwardSeekNonQuiescentOk'),
      );
    });

    test('native failure payload propagates failure reason', () {
      final raw = _createSampleRawMap({
        'pass': false,
        'status': 'fail',
        'marker': _kFailMarker,
        'failureReason': 'track_admission_failed',
      });
      final report = VGRealtimePlaybackTransportCoreSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.failureReason, equals('track_admission_failed'));
      expect(report.lastError, equals('track_admission_failed'));
    });

    test('malformed payload fails closed (non-map)', () {
      final report = VGRealtimePlaybackTransportCoreSmokeReport.fromMap(null);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('native_result_not_a_map'));
      expect(report.lastError, equals('native_result_not_a_map'));
      expect(report.trackAdmissionOk, isFalse);
      expect(report.reentrantSequenceOk, isFalse);
    });

    test('string-encoded and numeric values parse defensively', () {
      final raw = <String, Object?>{
        'pass': 'true',
        'status': 'PASS',
        'marker': _kPassMarker,
        'proofBoundary': _kCanonicalProofBoundary,
        'lanes': <String, Object?>{
          'trackAdmissionOk': 'true',
          'partialEosTailOk': 'true',
          'reentrantSequenceOk': 'true',
          'pausedSeekStaysPausedOk': 'true',
          'wrongOwnerDirectProbeOk': 'true',
          'registryCapacityOk': 'true',
          'destroyIdempotenceOk': 'true',
          'proofBoundaryOk': 'true',
          'reentrantForwardSeekNonQuiescentOk': 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{
          'trackAdmission1Ok': 'true',
          'trackAdmission2Ok': 'true',
          'trackAdmission8Ok': 'true',
          'trackAdmission9RejectedOk': 'true',
          'partialEosTailRenderedFrames': '1000',
          'partialEosTailPushedFrames': '1000',
          'partialEosTailDrainedFrames': '1000',
          'partialEosTailPushedChecksumHex': '0000000012345678',
          'partialEosTailDrainedChecksumHex': '0000000012345678',
          'reentrantHoldDispatchUnchangedOk': 'true',
          'reentrantHoldPushedUnchangedOk': 'true',
          'reentrantForwardSeekNonQuiescentOk': 'true',
          'reentrantSeekForwardOk': 'true',
          'reentrantSeekBackwardOk': 'true',
          'reentrantRestartAndEosOk': 'true',
          'pausedSeekStayedPaused': 'true',
          'wrongOwnerStatus': 'wrong_owner_thread',
          'wrongOwnerFlag': 'true',
          'registryCapacityCount': '4',
          'registryFifthFailedOk': 'true',
          'firstDestroyStatus': 'ok',
          'firstDestroyWorkerJoined': 'true',
          'firstDestroyWorkerExited': 'true',
          'nativeSecondDestroyStatus': 'not_found',
          'wrapperSecondDestroyStatus': 'session_closed',
        },
      };

      final report = VGRealtimePlaybackTransportCoreSmokeReport.fromMap(raw);
      expect(report.pass, isTrue);
      expect(report.trackAdmissionOk, isTrue);
      expect(report.partialEosTailRenderedFrames, equals(1000));
      expect(report.registryCapacityCount, equals(4));
      expect(report.reentrantForwardSeekNonQuiescentOk, isTrue);
      expect(report.wrongOwnerStatus, equals('wrong_owner_thread'));
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
      final report3 = _createSampleReport({
        'partialEosTailRenderedFrames': 500,
      });
      final report4 = _createSampleReport({
        'reentrantForwardSeekNonQuiescentOk': false,
      });

      expect(report1, equals(report2));
      expect(report1.hashCode, equals(report2.hashCode));
      expect(report1, isNot(equals(report3)));
      expect(report1, isNot(equals(report4)));
      expect(
        report1.toString(),
        contains('VGRealtimePlaybackTransportCoreSmokeReport'),
      );
      expect(report1.toString(), contains('trackAdmissionOk: true'));
    });
  });

  group('VGRealtimePlaybackTransportCoreSmokeReport MethodChannel invocation', () {
    test('successful channel invocation returns report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runRealtimePlaybackTransportCoreSmoke') {
          return _createSampleRawMap();
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackTransportCoreSmokeReport.runRealtimePlaybackTransportCoreSmoke();

      expect(report.pass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.hasPassMarker, isTrue);
    });

    test('PlatformException produces fallback error report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runRealtimePlaybackTransportCoreSmoke') {
          throw PlatformException(
            code: 'P4_REALTIME_PLAYBACK_TRANSPORT_CORE_SMOKE_BUSY',
            message: 'Diagnostic already running',
          );
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackTransportCoreSmokeReport.runRealtimePlaybackTransportCoreSmoke();

      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_REALTIME_PLAYBACK_TRANSPORT_CORE_SMOKE_BUSY',
        ),
      );
      expect(
        report.lastError,
        contains(
          'platform_exception:P4_REALTIME_PLAYBACK_TRANSPORT_CORE_SMOKE_BUSY:Diagnostic already running',
        ),
      );
    });

    test('TimeoutException produces fallback error report', () async {
      final customChannel = const MethodChannel(
        'vanguard_media_engine_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });

      final report =
          await VGRealtimePlaybackTransportCoreSmokeReport.runRealtimePlaybackTransportCoreSmoke(
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
