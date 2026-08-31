// vg_audio_pipeline_integration_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice F: Android True-DAG Phase 4
// native closed-loop ingest-to-transport audio graph pipeline integration Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'native_closed_loop_audio_pipeline_integration_proof_only_no_mediacodec_no_mediaextractor_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_playback_no_audible_output_no_os_callback_no_threads_no_locks_no_file_io_no_wall_clock_read_no_resample_no_speed_change_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_no_source_node_pcm_ingest_topology_anchor_only_writer_local_eos_only_caller_supplied_systime_only_single_threaded';

const _kAllLanes = <String>[
  'routeSelectivityOk',
  'startAwaitAckGateOk',
  'closedLoopIdentityOk',
  'sourceSeekAckBoundaryOk',
  'coordinatorSeekIdentityOk',
  'firstPostSeekSilenceOk',
  'noSteadyStateAllocationOk',
  'noRingPushShortfallOk',
  'lifecycleOk',
  'stackScoped',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final metrics = <String, Object?>{
    'routeSelectivityOk': true,
    'startAwaitAckGateOk': true,
    'closedLoopIdentityOk': true,
    'sourceSeekAckBoundaryOk': true,
    'coordinatorSeekIdentityOk': true,
    'firstPostSeekSilenceOk': true,
    'noSteadyStateAllocationOk': true,
    'noRingPushShortfallOk': true,
    'lifecycleOk': true,
    'stackScoped': true,
    'closedLoopFramesVerified': 160,
    'closedLoopChecksum': 1234567890123,
    'closedLoopExpectedChecksum': 1234567890123,
    'closedLoopClippedSamples': 8,
    'seekTargetFrame': 800,
    'sourceSeekTargetFrame': 400,
    'firstPostSeekUnderrunEvents': 1,
    'firstPostSeekFramesZeroFilled': 80,
    'steadyStateDispatches': 50,
    'steadyStateFramesPushed': 4000,
  };

  final raw = <String, String>{
    'status': 'PASS',
    'proofBoundary': _kCanonicalProofBoundary,
    'routeSelectivityOk': 'true',
    'startAwaitAckGateOk': 'true',
    'closedLoopIdentityOk': 'true',
    'sourceSeekAckBoundaryOk': 'true',
    'coordinatorSeekIdentityOk': 'true',
    'firstPostSeekSilenceOk': 'true',
    'noSteadyStateAllocationOk': 'true',
    'noRingPushShortfallOk': 'true',
    'lifecycleOk': 'true',
    'stackScoped': 'true',
    'closedLoopFramesVerified': '160',
    'closedLoopChecksum': '1234567890123',
    'closedLoopExpectedChecksum': '1234567890123',
    'closedLoopClippedSamples': '8',
    'seekTargetFrame': '800',
    'sourceSeekTargetFrame': '400',
    'firstPostSeekUnderrunEvents': '1',
    'firstPostSeekFramesZeroFilled': '80',
    'steadyStateDispatches': '50',
    'steadyStateFramesPushed': '4000',
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

VGAudioPipelineIntegrationSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGAudioPipelineIntegrationSmokeReport.fromMap(
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

  group('VGAudioPipelineIntegrationSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGAudioPipelineIntegrationSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.lastError, isEmpty);

        // Boolean lane getters
        expect(report.routeSelectivityOk, isTrue);
        expect(report.startAwaitAckGateOk, isTrue);
        expect(report.closedLoopIdentityOk, isTrue);
        expect(report.sourceSeekAckBoundaryOk, isTrue);
        expect(report.coordinatorSeekIdentityOk, isTrue);
        expect(report.firstPostSeekSilenceOk, isTrue);
        expect(report.noSteadyStateAllocationOk, isTrue);
        expect(report.noRingPushShortfallOk, isTrue);
        expect(report.lifecycleOk, isTrue);
        expect(report.stackScoped, isTrue);

        // Numeric getters
        expect(report.closedLoopFramesVerified, equals(160));
        expect(report.closedLoopChecksum, equals(1234567890123));
        expect(report.closedLoopExpectedChecksum, equals(1234567890123));
        expect(report.closedLoopClippedSamples, equals(8));
        expect(report.seekTargetFrame, equals(800));
        expect(report.sourceSeekTargetFrame, equals(400));
        expect(report.firstPostSeekUnderrunEvents, equals(1));
        expect(report.firstPostSeekFramesZeroFilled, equals(80));
        expect(report.steadyStateDispatches, equals(50));
        expect(report.steadyStateFramesPushed, equals(4000));

        // Aggregate
        expect(report.allNativeLanesPass, isTrue);

        // Serialization
        final serialized = report.toMap();
        expect(serialized['pass'], isTrue);
        expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
        expect(serialized['lastError'], equals(''));
        expect(serialized['raw'], equals(report.raw));
        expect(serialized['metrics'], equals(report.metrics));

        final roundTrip = VGAudioPipelineIntegrationSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAudioPipelineIntegrationSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'metrics': const <String, Object?>{
            'routeSelectivityOk': true,
            'startAwaitAckGateOk': false,
            'closedLoopIdentityOk': true,
            'sourceSeekAckBoundaryOk': true,
            'coordinatorSeekIdentityOk': true,
            'firstPostSeekSilenceOk': true,
            'noSteadyStateAllocationOk': true,
            'noRingPushShortfallOk': true,
            'lifecycleOk': true,
            'stackScoped': true,
          },
          'lastError': 'start_await_ack_gate_failed',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.startAwaitAckGateOk, isFalse);
      expect(report.routeSelectivityOk, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, equals('start_await_ack_gate_failed'));
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [
        null,
        'not_a_map',
        12345,
        3.14,
        <Object?>['a', 'b'],
      ]) {
        final report = VGAudioPipelineIntegrationSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(report.hasCanonicalProofBoundary, isFalse);
        expect(report.proofBoundary, isEmpty);
        expect(
          report.raw,
          equals(const <String, String>{'reason': 'native_result_not_a_map'}),
        );
        expect(report.lastError, equals('native_result_not_a_map'));
        expect(report.allNativeLanesPass, isFalse);
        expect(report.closedLoopFramesVerified, equals(0));
        expect(report.steadyStateFramesPushed, equals(0));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw = VGAudioPipelineIntegrationSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'routeSelectivityOk=true;'
            'startAwaitAckGateOk=true;'
            'closedLoopIdentityOk=true;'
            'sourceSeekAckBoundaryOk=true;'
            'coordinatorSeekIdentityOk=true;'
            'firstPostSeekSilenceOk=true;'
            'noSteadyStateAllocationOk=true;'
            'noRingPushShortfallOk=true;'
            'lifecycleOk=true;'
            'stackScoped=true;'
            'closedLoopFramesVerified=160;'
            'closedLoopChecksum=1234567890123;'
            'closedLoopExpectedChecksum=1234567890123;'
            'closedLoopClippedSamples=8;'
            'seekTargetFrame=800;'
            'sourceSeekTargetFrame=400;'
            'firstPostSeekUnderrunEvents=1;'
            'firstPostSeekFramesZeroFilled=80;'
            'steadyStateDispatches=50;'
            'steadyStateFramesPushed=4000',
        'proofBoundary': _kCanonicalProofBoundary,
        'metrics': const <String, Object?>{},
      });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.raw['status'], equals('PASS'));
      expect(reportFromRaw.raw['steadyStateFramesPushed'], equals('4000'));
      expect(reportFromRaw.closedLoopFramesVerified, equals(160));
      expect(reportFromRaw.closedLoopChecksum, equals(1234567890123));
      expect(reportFromRaw.closedLoopExpectedChecksum, equals(1234567890123));
      expect(reportFromRaw.closedLoopClippedSamples, equals(8));
      expect(reportFromRaw.seekTargetFrame, equals(800));
      expect(reportFromRaw.sourceSeekTargetFrame, equals(400));
      expect(reportFromRaw.firstPostSeekUnderrunEvents, equals(1));
      expect(reportFromRaw.firstPostSeekFramesZeroFilled, equals(80));
      expect(reportFromRaw.steadyStateDispatches, equals(50));
      expect(reportFromRaw.steadyStateFramesPushed, equals(4000));
      expect(reportFromRaw.routeSelectivityOk, isTrue);
      expect(reportFromRaw.startAwaitAckGateOk, isTrue);
      expect(reportFromRaw.closedLoopIdentityOk, isTrue);
      expect(reportFromRaw.sourceSeekAckBoundaryOk, isTrue);
      expect(reportFromRaw.coordinatorSeekIdentityOk, isTrue);
      expect(reportFromRaw.firstPostSeekSilenceOk, isTrue);
      expect(reportFromRaw.noSteadyStateAllocationOk, isTrue);
      expect(reportFromRaw.noRingPushShortfallOk, isTrue);
      expect(reportFromRaw.lifecycleOk, isTrue);
      expect(reportFromRaw.stackScoped, isTrue);
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in metrics', () {
      final report = VGAudioPipelineIntegrationSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'metrics': const <String, Object?>{
          'routeSelectivityOk': 'true',
          'startAwaitAckGateOk': 'PASS',
          'closedLoopIdentityOk': 'success',
          'sourceSeekAckBoundaryOk': 'false',
        },
      });

      expect(report.routeSelectivityOk, isTrue);
      expect(report.startAwaitAckGateOk, isTrue);
      expect(report.closedLoopIdentityOk, isTrue);
      expect(report.sourceSeekAckBoundaryOk, isFalse);
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
          modifiedMetrics[lane] = false;

          final report = VGAudioPipelineIntegrationSmokeReport.fromMap({
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
            case 'routeSelectivityOk':
              expect(report.routeSelectivityOk, isFalse);
              break;
            case 'startAwaitAckGateOk':
              expect(report.startAwaitAckGateOk, isFalse);
              break;
            case 'closedLoopIdentityOk':
              expect(report.closedLoopIdentityOk, isFalse);
              break;
            case 'sourceSeekAckBoundaryOk':
              expect(report.sourceSeekAckBoundaryOk, isFalse);
              break;
            case 'coordinatorSeekIdentityOk':
              expect(report.coordinatorSeekIdentityOk, isFalse);
              break;
            case 'firstPostSeekSilenceOk':
              expect(report.firstPostSeekSilenceOk, isFalse);
              break;
            case 'noSteadyStateAllocationOk':
              expect(report.noSteadyStateAllocationOk, isFalse);
              break;
            case 'noRingPushShortfallOk':
              expect(report.noRingPushShortfallOk, isFalse);
              break;
            case 'lifecycleOk':
              expect(report.lifecycleOk, isFalse);
              break;
            case 'stackScoped':
              expect(report.stackScoped, isFalse);
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
      expect(a.toString(), contains('VGAudioPipelineIntegrationSmokeReport('));
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
          'metrics': const <String, Object?>{'routeSelectivityOk': false},
        },
      ];

      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group('MethodChannel wrapper: runAndroidDagPhase4AudioPipelineIntegrationSmoke', () {
    test(
      'invokes runAndroidDagPhase4AudioPipelineIntegrationSmoke on default channel',
      () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGAudioPipelineIntegrationSmokeReport.runAndroidDagPhase4AudioPipelineIntegrationSmoke();

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase4AudioPipelineIntegrationSmoke'),
        );
        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test('invokes on custom injected channel', () async {
      MethodCall? capturedCall;
      const customChannel = MethodChannel(
        'custom_audio_pipeline_integration_channel',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGAudioPipelineIntegrationSmokeReport.runAndroidDagPhase4AudioPipelineIntegrationSmoke(
            channel: customChannel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('runAndroidDagPhase4AudioPipelineIntegrationSmoke'),
      );
      expect(report.pass, isTrue);
    });

    test('handles PlatformException by returning fallback report', () async {
      const errorChannel = MethodChannel(
        'error_audio_pipeline_integration_channel',
      );
      binaryMessenger.setMockMethodCallHandler(errorChannel, (call) async {
        throw PlatformException(
          code: 'NATIVE_ERROR',
          message: 'AudioPipelineIntegration initialization failed',
        );
      });

      final report =
          await VGAudioPipelineIntegrationSmokeReport.runAndroidDagPhase4AudioPipelineIntegrationSmoke(
            channel: errorChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(
        report.lastError,
        contains(
          'platform_exception:NATIVE_ERROR:AudioPipelineIntegration initialization failed',
        ),
      );
    });

    test('handles TimeoutException by returning fallback report', () async {
      const slowChannel = MethodChannel(
        'slow_audio_pipeline_integration_channel',
      );
      binaryMessenger.setMockMethodCallHandler(slowChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });

      final report =
          await VGAudioPipelineIntegrationSmokeReport.runAndroidDagPhase4AudioPipelineIntegrationSmoke(
            timeout: const Duration(milliseconds: 20),
            channel: slowChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('timeout'));
    });

    test('handles generic Exception by returning fallback report', () async {
      const exChannel = MethodChannel('ex_audio_pipeline_integration_channel');
      binaryMessenger.setMockMethodCallHandler(exChannel, (call) async {
        throw Exception('Native crash simulated');
      });

      final report =
          await VGAudioPipelineIntegrationSmokeReport.runAndroidDagPhase4AudioPipelineIntegrationSmoke(
            channel: exChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('Native crash simulated'));
    });
  });
}
