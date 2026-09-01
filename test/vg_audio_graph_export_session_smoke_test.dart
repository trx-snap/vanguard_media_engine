// vg_audio_graph_export_session_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-PASS2-GRAPH-NATIVE-SESSION: Android True-DAG Phase 4
// N-source node-owned ring audio graph export session diagnostic smoke foundation
// Dart model and MethodChannel unit tests (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'native_true_dag_pass2_graph_export_session_diagnostic_only_n_source_node_owned_ring_graph_scheduler_mixbus_unit_gain_no_production_route_swap_no_android_mixdown_engine_change_no_legacy_chunk_mixer_change_no_runtime_realtime_sink_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_mediacodec_no_mediaextractor_no_file_io_no_native_worker_threads_no_app_no_editor_no_product_no_streaming_no_cache_no_ios';

const _kPassMarker = 'ANDROID_DAG_PHASE4_AUDIO_GRAPH_EXPORT_SESSION_SMOKE_PASS';
const _kFailMarker = 'ANDROID_DAG_PHASE4_AUDIO_GRAPH_EXPORT_SESSION_SMOKE_FAIL';

const _kChecksumWindow0Hex = '00000000abcdef12';
const _kChecksumWindow1Hex = '0000000034567890';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'sessionCreateOk': true,
    'longTimelineAdmissionOk': true,
    'addEightTracksOk': true,
    'totalTrackLimitRejectOk': true,
    'prepareBarrierOk': true,
    'routedSourceCountOk': true,
    'contiguousWindowOk': true,
    'renderTwoWindowsOk': true,
    'checksumNonZeroOk': true,
    'underrunFailClosedOk': true,
    'lifecycleDestroyIdempotentOk': true,
    'proofBoundaryOk': true,
    'noProductionRouteSwapOk': true,
    'canonical': true,
  };

  final metrics = <String, Object?>{
    'requestedTrackCount': 8,
    'routedSourceCount': 8,
    'windowCount': 2,
    'silentWindowCount': 0,
    'framesRendered': 2048,
    'longTimelineFrames': 28800000,
    'totalTrackLimitReason': 'total_track_count_exceeded:9',
    'nonContiguousReason': 'non_contiguous_window:1024/0',
    'underrunReason': 'source_underrun:underrun_track',
    'checksumWindow0Hex': _kChecksumWindow0Hex,
    'checksumWindow1Hex': _kChecksumWindow1Hex,
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'nodeOwnedRingSourceNodesLockstepTimeline=true|static_unit_gain_null_envelope_only|no_production_route_swap_no_mixdown_engine_change',
    'lanes': lanes,
    'metrics': metrics,
    'lastError': null,
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

VGAudioGraphExportSessionSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGAudioGraphExportSessionSmokeReport.fromMap(
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

  group('VGAudioGraphExportSessionSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGAudioGraphExportSessionSmokeReport.methodName,
        equals('runAndroidDagPhase4AudioGraphExportSessionSmoke'),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.requiredNativeLaneKeys.length,
        equals(13),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.requiredNativeLaneKeys,
        contains('sessionCreateOk'),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.requiredNativeLaneKeys,
        contains('longTimelineAdmissionOk'),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.requiredNativeLaneKeys,
        contains('addEightTracksOk'),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.requiredNativeLaneKeys,
        contains('totalTrackLimitRejectOk'),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.requiredNativeLaneKeys,
        contains('prepareBarrierOk'),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.requiredNativeLaneKeys,
        contains('routedSourceCountOk'),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.requiredNativeLaneKeys,
        contains('contiguousWindowOk'),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.requiredNativeLaneKeys,
        contains('renderTwoWindowsOk'),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.requiredNativeLaneKeys,
        contains('checksumNonZeroOk'),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.requiredNativeLaneKeys,
        contains('underrunFailClosedOk'),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.requiredNativeLaneKeys,
        contains('lifecycleDestroyIdempotentOk'),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.requiredNativeLaneKeys,
        contains('proofBoundaryOk'),
      );
      expect(
        VGAudioGraphExportSessionSmokeReport.requiredNativeLaneKeys,
        contains('noProductionRouteSwapOk'),
      );
    });
  });

  group('VGAudioGraphExportSessionSmokeReport.fromMap parsing', () {
    test('pass payload parses true with all lanes and metrics', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.status, equals('pass'));
      expect(report.marker, equals(_kPassMarker));
      expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.lastError, isEmpty);
      expect(report.failureReason, isEmpty);

      // Verify all 14 lanes
      expect(report.sessionCreateOk, isTrue);
      expect(report.longTimelineAdmissionOk, isTrue);
      expect(report.addEightTracksOk, isTrue);
      expect(report.totalTrackLimitRejectOk, isTrue);
      expect(report.prepareBarrierOk, isTrue);
      expect(report.routedSourceCountOk, isTrue);
      expect(report.contiguousWindowOk, isTrue);
      expect(report.renderTwoWindowsOk, isTrue);
      expect(report.checksumNonZeroOk, isTrue);
      expect(report.underrunFailClosedOk, isTrue);
      expect(report.lifecycleDestroyIdempotentOk, isTrue);
      expect(report.proofBoundaryOk, isTrue);
      expect(report.noProductionRouteSwapOk, isTrue);
      expect(report.canonical, isTrue);

      // Verify metrics
      expect(report.requestedTrackCount, equals(8));
      expect(report.routedSourceCount, equals(8));
      expect(report.windowCount, equals(2));
      expect(report.silentWindowCount, equals(0));
      expect(report.framesRendered, equals(2048));
      expect(report.longTimelineFrames, equals(28800000));
      expect(
        report.totalTrackLimitReason,
        equals('total_track_count_exceeded:9'),
      );
      expect(
        report.nonContiguousReason,
        equals('non_contiguous_window:1024/0'),
      );
      expect(report.underrunReason, equals('source_underrun:underrun_track'));
      expect(report.checksumWindow0Hex, equals(_kChecksumWindow0Hex));
      expect(report.checksumWindow1Hex, equals(_kChecksumWindow1Hex));
    });

    test('missing required lane fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes.remove('renderTwoWindowsOk');
      raw['lanes'] = lanes;

      final report = VGAudioGraphExportSessionSmokeReport.fromMap(raw);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('missing_lane'));
      expect(report.lastError, equals('missing_lane_renderTwoWindowsOk'));
    });

    test('proof boundary mismatch fails closed', () {
      final raw = _createSampleRawMap({
        'proofBoundary': 'invalid_proof_boundary_string',
      });
      final report = VGAudioGraphExportSessionSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.lastError, equals('proof_boundary_mismatch'));
    });

    test('marker mismatch fails closed', () {
      final raw = _createSampleRawMap({'marker': 'INVALID_MARKER'});
      final report = VGAudioGraphExportSessionSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.lastError, equals('marker_mismatch'));
    });

    test('pass true with false lane fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes['underrunFailClosedOk'] = false;
      raw['lanes'] = lanes;

      final report = VGAudioGraphExportSessionSmokeReport.fromMap(raw);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.underrunFailClosedOk, isFalse);
      expect(report.status, equals('lane_failed'));
      expect(report.lastError, equals('lane_failed'));
    });

    test('native failure payload propagates failure reason', () {
      final raw = _createSampleRawMap({
        'pass': false,
        'status': 'fail',
        'marker': _kFailMarker,
        'failureReason': 'source_underrun:track_0',
      });
      final report = VGAudioGraphExportSessionSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.failureReason, equals('source_underrun:track_0'));
      expect(report.lastError, equals('source_underrun:track_0'));
    });

    test('malformed payload fails closed (non-map)', () {
      final report = VGAudioGraphExportSessionSmokeReport.fromMap(null);
      expect(report.pass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('native_result_not_a_map'));
      expect(report.lastError, equals('native_result_not_a_map'));
      expect(report.sessionCreateOk, isFalse);
      expect(report.renderTwoWindowsOk, isFalse);
    });

    test('string-encoded and numeric values parse defensively', () {
      final raw = <String, Object?>{
        'pass': 'true',
        'status': 'PASS',
        'marker': _kPassMarker,
        'proofBoundary': _kCanonicalProofBoundary,
        'lanes': <String, Object?>{
          'sessionCreateOk': 'true',
          'longTimelineAdmissionOk': 'true',
          'addEightTracksOk': 'true',
          'totalTrackLimitRejectOk': 'true',
          'prepareBarrierOk': 'true',
          'routedSourceCountOk': 'true',
          'contiguousWindowOk': 'true',
          'renderTwoWindowsOk': 'true',
          'checksumNonZeroOk': 'true',
          'underrunFailClosedOk': 'true',
          'lifecycleDestroyIdempotentOk': 'true',
          'proofBoundaryOk': 'true',
          'noProductionRouteSwapOk': 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{
          'requestedTrackCount': '8',
          'routedSourceCount': '8',
          'windowCount': '2',
          'silentWindowCount': '0',
          'framesRendered': '2048',
          'longTimelineFrames': '28800000',
          'totalTrackLimitReason': 'total_track_count_exceeded:9',
          'nonContiguousReason': 'non_contiguous_window:1024/0',
          'underrunReason': 'source_underrun:underrun_track',
          'checksumWindow0Hex': _kChecksumWindow0Hex,
          'checksumWindow1Hex': _kChecksumWindow1Hex,
        },
      };

      final report = VGAudioGraphExportSessionSmokeReport.fromMap(raw);
      expect(report.pass, isTrue);
      expect(report.requestedTrackCount, equals(8));
      expect(report.routedSourceCount, equals(8));
      expect(report.windowCount, equals(2));
      expect(report.silentWindowCount, equals(0));
      expect(report.framesRendered, equals(2048));
      expect(report.longTimelineFrames, equals(28800000));
      expect(
        report.totalTrackLimitReason,
        equals('total_track_count_exceeded:9'),
      );
      expect(report.checksumWindow0Hex, equals(_kChecksumWindow0Hex));
    });

    test('toMap serialization preserves structure', () {
      final report = _createSampleReport();
      final map = report.toMap();

      expect(map['pass'], isTrue);
      expect(map['status'], equals('pass'));
      expect(map['marker'], equals(_kPassMarker));
      expect(map['proofBoundary'], equals(_kCanonicalProofBoundary));
      expect(map['lanes'], isA<Map>());
      expect(map['metrics'], isA<Map>());
    });

    test('equality, hashCode, and toString work correctly', () {
      final report1 = _createSampleReport();
      final report2 = _createSampleReport();
      final report3 = _createSampleReport({'requestedTrackCount': 4});

      expect(report1, equals(report2));
      expect(report1.hashCode, equals(report2.hashCode));
      expect(report1, isNot(equals(report3)));
      expect(
        report1.toString(),
        contains('VGAudioGraphExportSessionSmokeReport'),
      );
      expect(report1.toString(), contains('sessionCreateOk: true'));
    });
  });

  group('VGAudioGraphExportSessionSmokeReport MethodChannel invocation', () {
    test('successful channel invocation returns report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runAndroidDagPhase4AudioGraphExportSessionSmoke') {
          return _createSampleRawMap();
        }
        return null;
      });

      final report =
          await VGAudioGraphExportSessionSmokeReport.runAndroidDagPhase4AudioGraphExportSessionSmoke();

      expect(report.pass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.hasPassMarker, isTrue);
    });

    test('PlatformException produces fallback error report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runAndroidDagPhase4AudioGraphExportSessionSmoke') {
          throw PlatformException(
            code: 'UNAVAILABLE',
            message: 'Native method not registered',
          );
        }
        return null;
      });

      final report =
          await VGAudioGraphExportSessionSmokeReport.runAndroidDagPhase4AudioGraphExportSessionSmoke();

      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('platform_exception:UNAVAILABLE'));
      expect(
        report.lastError,
        contains('platform_exception:UNAVAILABLE:Native method not registered'),
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
          await VGAudioGraphExportSessionSmokeReport.runAndroidDagPhase4AudioGraphExportSessionSmoke(
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
