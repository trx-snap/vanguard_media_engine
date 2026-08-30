// vg_audio_graph_topology_smoke_test.dart
// vanguard_media_engine — P4-AUDIO-GRAPH-TOPOLOGY: Android True-DAG Phase 4
// AudioMixBusNode DAG topology & graph-gated diagnostic mix Dart model & MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'native_audio_mix_bus_graph_topology_and_graph_gated_diagnostic_mix_only_no_realtime_no_playback_no_audio_track_no_graph_buffer_transport_no_product';

const _kAllLanes = <String>[
  'topologyOk',
  'topoOrderOk',
  'portTypeOk',
  'capacityOk',
  'cycleRejectOk',
  'inputFanInRejectOk',
  'staleGenerationOk',
  'mediaFlagsOk',
  'graphGatedMixOk',
  'invalidGainOk',
  'audioTimelineGatingOk',
  'audioPtsMappingOk',
  'lifecycleOk',
  'stackScoped',
  'hasAudio',
  'hasVideo',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final metrics = <String, Object?>{
    'topologyOk': true,
    'topoOrderOk': true,
    'portTypeOk': true,
    'capacityOk': true,
    'cycleRejectOk': true,
    'inputFanInRejectOk': true,
    'staleGenerationOk': true,
    'mediaFlagsOk': true,
    'graphGatedMixOk': true,
    'invalidGainOk': true,
    'audioTimelineGatingOk': true,
    'audioPtsMappingOk': true,
    'lifecycleOk': true,
    'stackScoped': true,
    'hasAudio': true,
    'hasVideo': false,
    'clipped': false,
    'nodeCount': 5,
    'edgeCount': 4,
    'activeNodeCount': 5,
    'mixCallCount': 1,
    'staleMixCallCount': 0,
    'framesMixed': 4,
    'mixChecksum': 123456789,
    'expectedChecksum': 123456789,
    'maxAccumulatorAbs': 1052,
  };

  final raw = <String, String>{
    'status': 'PASS',
    'proofBoundary': _kCanonicalProofBoundary,
    'topologyOk': 'true',
    'topoOrderOk': 'true',
    'portTypeOk': 'true',
    'capacityOk': 'true',
    'cycleRejectOk': 'true',
    'inputFanInRejectOk': 'true',
    'staleGenerationOk': 'true',
    'mediaFlagsOk': 'true',
    'graphGatedMixOk': 'true',
    'invalidGainOk': 'true',
    'audioTimelineGatingOk': 'true',
    'audioPtsMappingOk': 'true',
    'lifecycleOk': 'true',
    'stackScoped': 'true',
    'nodeCount': '5',
    'edgeCount': '4',
    'activeNodeCount': '5',
    'hasAudio': 'true',
    'hasVideo': 'false',
    'mixCallCount': '1',
    'staleMixCallCount': '0',
    'framesMixed': '4',
    'mixChecksum': '123456789',
    'expectedChecksum': '123456789',
    'maxAccumulatorAbs': '1052',
    'clipped': 'false',
  };

  return <String, Object?>{
    'pass': true,
    'proofBoundary': _kCanonicalProofBoundary,
    'raw': raw,
    'metrics': metrics,
    'lastError': '',
    if (overrides != null) ...overrides,
  };
}

VGAudioGraphTopologySmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGAudioGraphTopologySmokeReport.fromMap(_createSampleRawMap(overrides));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGAudioGraphTopologySmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGAudioGraphTopologySmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.lastError, isEmpty);

        // Boolean lane getters
        expect(report.topologyOk, isTrue);
        expect(report.topoOrderOk, isTrue);
        expect(report.portTypeOk, isTrue);
        expect(report.capacityOk, isTrue);
        expect(report.cycleRejectOk, isTrue);
        expect(report.inputFanInRejectOk, isTrue);
        expect(report.staleGenerationOk, isTrue);
        expect(report.mediaFlagsOk, isTrue);
        expect(report.graphGatedMixOk, isTrue);
        expect(report.invalidGainOk, isTrue);
        expect(report.audioTimelineGatingOk, isTrue);
        expect(report.audioPtsMappingOk, isTrue);
        expect(report.lifecycleOk, isTrue);
        expect(report.stackScoped, isTrue);
        expect(report.hasAudio, isTrue);
        expect(report.hasVideo, isFalse);
        expect(report.clipped, isFalse);

        // Numeric getters
        expect(report.nodeCount, equals(5));
        expect(report.edgeCount, equals(4));
        expect(report.activeNodeCount, equals(5));
        expect(report.mixCallCount, equals(1));
        expect(report.staleMixCallCount, equals(0));
        expect(report.framesMixed, equals(4));
        expect(report.mixChecksum, equals(123456789));
        expect(report.expectedChecksum, equals(123456789));
        expect(report.maxAccumulatorAbs, equals(1052));

        // Aggregate
        expect(report.allNativeLanesPass, isTrue);

        // Serialization
        final serialized = report.toMap();
        expect(serialized['pass'], isTrue);
        expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
        expect(serialized['lastError'], equals(''));
        expect(serialized['raw'], equals(report.raw));
        expect(serialized['metrics'], equals(report.metrics));

        final roundTrip = VGAudioGraphTopologySmokeReport.fromMap(serialized);
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAudioGraphTopologySmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'metrics': const <String, Object?>{
            'topologyOk': true,
            'topoOrderOk': false,
            'portTypeOk': true,
            'capacityOk': true,
            'cycleRejectOk': true,
            'inputFanInRejectOk': true,
            'staleGenerationOk': true,
            'mediaFlagsOk': true,
            'graphGatedMixOk': true,
            'invalidGainOk': true,
            'audioTimelineGatingOk': true,
            'audioPtsMappingOk': true,
            'lifecycleOk': true,
            'stackScoped': true,
            'hasAudio': true,
            'hasVideo': false,
          },
          'lastError': 'topo_order_invalid',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.topoOrderOk, isFalse);
      expect(report.topologyOk, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, equals('topo_order_invalid'));
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [
        null,
        'not_a_map',
        12345,
        3.14,
        <Object?>['a', 'b'],
      ]) {
        final report = VGAudioGraphTopologySmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(report.hasCanonicalProofBoundary, isFalse);
        expect(report.proofBoundary, isEmpty);
        expect(
          report.raw,
          equals(const <String, String>{'reason': 'native_result_not_a_map'}),
        );
        expect(report.lastError, equals('native_result_not_a_map'));
        expect(report.allNativeLanesPass, isFalse);
        expect(report.nodeCount, equals(0));
        expect(report.edgeCount, equals(0));
        expect(report.activeNodeCount, equals(0));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw = VGAudioGraphTopologySmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'topologyOk=true;'
            'topoOrderOk=true;'
            'portTypeOk=true;'
            'capacityOk=true;'
            'cycleRejectOk=true;'
            'inputFanInRejectOk=true;'
            'staleGenerationOk=true;'
            'mediaFlagsOk=true;'
            'graphGatedMixOk=true;'
            'invalidGainOk=true;'
            'audioTimelineGatingOk=true;'
            'audioPtsMappingOk=true;'
            'lifecycleOk=true;'
            'stackScoped=true;'
            'hasAudio=true;'
            'hasVideo=false;'
            'nodeCount=5;'
            'edgeCount=4;'
            'activeNodeCount=5;'
            'mixCallCount=1;'
            'staleMixCallCount=0;'
            'framesMixed=4;'
            'mixChecksum=99999;'
            'expectedChecksum=99999;'
            'maxAccumulatorAbs=750;'
            'clipped=false',
        'proofBoundary': _kCanonicalProofBoundary,
        'metrics': const <String, Object?>{},
      });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.raw['status'], equals('PASS'));
      expect(reportFromRaw.raw['nodeCount'], equals('5'));
      expect(reportFromRaw.nodeCount, equals(5));
      expect(reportFromRaw.edgeCount, equals(4));
      expect(reportFromRaw.activeNodeCount, equals(5));
      expect(reportFromRaw.mixChecksum, equals(99999));
      expect(reportFromRaw.topologyOk, isTrue);
      expect(reportFromRaw.audioTimelineGatingOk, isTrue);
      expect(reportFromRaw.audioPtsMappingOk, isTrue);
      expect(reportFromRaw.hasAudio, isTrue);
      expect(reportFromRaw.hasVideo, isFalse);
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in metrics', () {
      final report = VGAudioGraphTopologySmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'metrics': const <String, Object?>{
          'topologyOk': 'true',
          'topoOrderOk': 'PASS',
          'portTypeOk': 'success',
          'hasVideo': 'false',
        },
      });

      expect(report.topologyOk, isTrue);
      expect(report.topoOrderOk, isTrue);
      expect(report.portTypeOk, isTrue);
      expect(report.hasVideo, isFalse);
    });
  });

  group('Proof boundary validation', () {
    test('proof boundary validation strictly checks canonical string', () {
      final reportValid = _createSampleReport();
      expect(reportValid.hasCanonicalProofBoundary, isTrue);

      final reportInvalid = _createSampleReport({
        'proofBoundary': 'wrong_proof_boundary_string',
      });
      expect(reportInvalid.hasCanonicalProofBoundary, isFalse);

      final reportEmpty = _createSampleReport({'proofBoundary': ''});
      expect(reportEmpty.hasCanonicalProofBoundary, isFalse);
    });
  });

  group('Individual lane failures and allNativeLanesPass coverage', () {
    test(
      'every single lane failing falsifies allNativeLanesPass and specific getter',
      () {
        final base = _createSampleRawMap();
        final baseMetrics = Map<String, Object?>.from(base['metrics'] as Map);

        for (final lane in _kAllLanes) {
          final modifiedMetrics = Map<String, Object?>.from(baseMetrics);
          if (lane == 'hasVideo') {
            // For hasVideo, passing means false, failing means true
            modifiedMetrics['hasVideo'] = true;
          } else {
            modifiedMetrics[lane] = false;
          }

          final report = VGAudioGraphTopologySmokeReport.fromMap({
            ...base,
            'metrics': modifiedMetrics,
          });

          expect(
            report.allNativeLanesPass,
            isFalse,
            reason:
                'Failing lane $lane must cause allNativeLanesPass to be false',
          );

          switch (lane) {
            case 'topologyOk':
              expect(report.topologyOk, isFalse);
              break;
            case 'topoOrderOk':
              expect(report.topoOrderOk, isFalse);
              break;
            case 'portTypeOk':
              expect(report.portTypeOk, isFalse);
              break;
            case 'capacityOk':
              expect(report.capacityOk, isFalse);
              break;
            case 'cycleRejectOk':
              expect(report.cycleRejectOk, isFalse);
              break;
            case 'inputFanInRejectOk':
              expect(report.inputFanInRejectOk, isFalse);
              break;
            case 'staleGenerationOk':
              expect(report.staleGenerationOk, isFalse);
              break;
            case 'mediaFlagsOk':
              expect(report.mediaFlagsOk, isFalse);
              break;
            case 'graphGatedMixOk':
              expect(report.graphGatedMixOk, isFalse);
              break;
            case 'invalidGainOk':
              expect(report.invalidGainOk, isFalse);
              break;
            case 'audioTimelineGatingOk':
              expect(report.audioTimelineGatingOk, isFalse);
              break;
            case 'audioPtsMappingOk':
              expect(report.audioPtsMappingOk, isFalse);
              break;
            case 'lifecycleOk':
              expect(report.lifecycleOk, isFalse);
              break;
            case 'stackScoped':
              expect(report.stackScoped, isFalse);
              break;
            case 'hasAudio':
              expect(report.hasAudio, isFalse);
              break;
            case 'hasVideo':
              expect(report.hasVideo, isTrue);
              break;
            default:
              fail('Unknown lane: $lane');
          }
        }
      },
    );
  });

  group('Value semantics: equality, hashCode, toString', () {
    test('identical instances and identical values evaluate equal', () {
      final a = _createSampleReport();
      final b = _createSampleReport();

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGAudioGraphTopologySmokeReport('));
      expect(a.toString(), contains('pass: true'));
      expect(
        a.toString(),
        contains('proofBoundary: $_kCanonicalProofBoundary'),
      );
    });

    test('inequality when any single field differs', () {
      final base = _createSampleReport();
      final diffs = <Map<String, Object?>>[
        {'pass': false},
        {'proofBoundary': 'other_boundary'},
        {'lastError': 'some_error'},
        {
          'raw': const <String, String>{'custom': 'diff'},
        },
        {
          'metrics': const <String, Object?>{'topologyOk': false},
        },
      ];

      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group('MethodChannel wrapper: runAndroidDagPhase4AudioGraphTopologySmoke', () {
    test(
      'invokes runAndroidDagPhase4AudioGraphTopologySmoke on default channel',
      () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGAudioGraphTopologySmokeReport.runAndroidDagPhase4AudioGraphTopologySmoke();

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase4AudioGraphTopologySmoke'),
        );
        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test('invokes on custom injected channel', () async {
      MethodCall? capturedCall;
      const customChannel = MethodChannel(
        'custom_audio_graph_topology_channel',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGAudioGraphTopologySmokeReport.runAndroidDagPhase4AudioGraphTopologySmoke(
            channel: customChannel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('runAndroidDagPhase4AudioGraphTopologySmoke'),
      );
      expect(report.pass, isTrue);
    });

    test('handles PlatformException by returning fallback report', () async {
      const errorChannel = MethodChannel('error_audio_graph_topology_channel');
      binaryMessenger.setMockMethodCallHandler(errorChannel, (call) async {
        throw PlatformException(
          code: 'NATIVE_ERROR',
          message: 'AudioGraphTopology initialization failed',
        );
      });

      final report =
          await VGAudioGraphTopologySmokeReport.runAndroidDagPhase4AudioGraphTopologySmoke(
            channel: errorChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(
        report.lastError,
        contains(
          'platform_exception:NATIVE_ERROR:AudioGraphTopology initialization failed',
        ),
      );
    });

    test('handles TimeoutException by returning fallback report', () async {
      const slowChannel = MethodChannel('slow_audio_graph_topology_channel');
      binaryMessenger.setMockMethodCallHandler(slowChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });

      final report =
          await VGAudioGraphTopologySmokeReport.runAndroidDagPhase4AudioGraphTopologySmoke(
            timeout: const Duration(milliseconds: 20),
            channel: slowChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('timeout'));
    });

    test('handles generic Exception by returning fallback report', () async {
      const exChannel = MethodChannel('ex_audio_graph_topology_channel');
      binaryMessenger.setMockMethodCallHandler(exChannel, (call) async {
        throw Exception('Native crash simulated');
      });

      final report =
          await VGAudioGraphTopologySmokeReport.runAndroidDagPhase4AudioGraphTopologySmoke(
            channel: exChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('Native crash simulated'));
    });
  });
}
