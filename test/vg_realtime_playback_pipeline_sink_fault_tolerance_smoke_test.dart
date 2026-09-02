// vg_realtime_playback_pipeline_sink_fault_tolerance_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SINK-FAULT-TOLERANCE (Y6e):
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kProofBoundary = VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
    .proofBoundaryConstant;
const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SINK_FAULT_TOLERANCE_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SINK_FAULT_TOLERANCE_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SINK_FAULT_TOLERANCE_SMOKE_START';
const _kJsonMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SINK_FAULT_TOLERANCE_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    for (final k
        in VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
            .requiredGateKeys)
      k: true,
    'canonical': true,
  };
  final metrics = <String, Object?>{
    'maxDurationSec': 3.0,
    'maxFramesPerMix': 256,
    'baseVolume': 0.5,
    'pauseHoldMs': 150,
    'phaseFrames': 2048,
    'scenarioOrder': <String>[
      'EOS_WITH_DEAD_OBJECT_RECOVERY',
      'ROUTE_DISCONNECT_TERMINAL',
    ],
    'eos_with_dead_object_recoveryScenarioPass': true,
    'route_disconnect_terminalScenarioPass': true,
    'eos_with_dead_object_recovery': <String, Object?>{
      'scenario': 'EOS_WITH_DEAD_OBJECT_RECOVERY',
      'sampleRate': 48000,
      'channelCount': 2,
      'declaredFrameCount': 144000,
      'framesWrittenToSink': 144000,
      'audioTracksCreated': 2,
      'audioTracksReleased': 2,
      'syntheticDeadObjectInjectedCount': 1,
      'deadObjectObservedCount': 1,
      'transportStateFinal': 'DISPOSED',
      'sinkExitReason': 'eos',
    },
    'route_disconnect_terminal': <String, Object?>{
      'scenario': 'ROUTE_DISCONNECT_TERMINAL',
      'sinkExitReason': 'terminal_exit',
      'autoResumeAllowed': false,
      'routeDisconnectAppliedCount': 1,
      'stopState': 'STOPPED',
    },
    'failureReason': '',
  };
  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kProofBoundary,
    'nativeProofBoundary': _kProofBoundary,
    'failureReason': '',
    'details':
        'Y6e realtime playback pipeline sink fault tolerance harness pass=true',
    'lanes': lanes,
    'metrics': metrics,
    'lastError': null,
    'raw': 'pass=true;status=pass;marker=$_kPassMarker',
  };
  if (overrides != null) {
    for (final entry in overrides.entries) {
      if (lanes.containsKey(entry.key)) lanes[entry.key] = entry.value;
      if (metrics.containsKey(entry.key)) metrics[entry.key] = entry.value;
      result[entry.key] = entry.value;
    }
  }
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group(
    'VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport constants',
    () {
      test('static constants match expected native contracts', () {
        expect(
          VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.methodName,
          equals('runRealtimePlaybackPipelineSinkFaultToleranceSmoke'),
        );
        expect(
          VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
              .passMarkerConstant,
          equals(_kPassMarker),
        );
        expect(
          VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
              .failMarkerConstant,
          equals(_kFailMarker),
        );
        expect(
          VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
              .startMarkerConstant,
          equals(_kStartMarker),
        );
        expect(
          VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
              .jsonMarkerConstant,
          equals(_kJsonMarker),
        );
        expect(
          VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
              .proofBoundaryConstant,
          contains('synthetic_dead_object_injection_only'),
        );
        expect(
          VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
              .proofBoundaryConstant,
          contains('no_real_os_fault_forcing_no_seamless_hot_swap'),
        );
        expect(
          VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
              .requiredGateKeys
              .length,
          equals(22),
        );
        for (final key in <String>[
          'formatProbeOk',
          'preRollOk',
          'routingListenerRegisteredOk',
          'preStartDrainEmptyOk',
          'routeChangeObservationOk',
          'deadObjectInjectedOnceOk',
          'deadObjectOldTrackReleasedOk',
          'deadObjectNewTrackStateInitializedOk',
          'deadObjectNewTrackVolumeSetOk',
          'deadObjectNewTrackPlayOk',
          'deadObjectRemainderResumedOk',
          'deadObjectNoDoubleCountOk',
          'routeDisconnectFailClosedPauseOk',
          'routeDisconnectHoldFrozenOk',
          'sinkWriteAccountingOk',
          'checksumIdentityOk',
          'transportCompletedOk',
          'transportStoppedOk',
          'routingLifecycleOk',
          'audioTrackLifecycleOk',
          'threadOwnershipOk',
          'proofBoundaryOk',
        ]) {
          expect(
            VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
                .requiredGateKeys,
            contains(key),
          );
        }
      });
    },
  );

  group('VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.fromMap', () {
    test('pass payload parses true with all gates and metrics', () {
      final report =
          VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.fromMap(
            _createSampleRawMap(),
          );
      expect(report.pass, isTrue);
      expect(report.status, equals('pass'));
      expect(report.hasPassMarker, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.allRequiredGatesTrue, isTrue);
      expect(report.deadObjectInjectedOnceOk, isTrue);
      expect(report.deadObjectNoDoubleCountOk, isTrue);
      expect(report.routeDisconnectFailClosedPauseOk, isTrue);
      expect(report.routeDisconnectHoldFrozenOk, isTrue);
      expect(report.transportCompletedOk, isTrue);
      expect(report.transportStoppedOk, isTrue);
      expect(report.routingLifecycleOk, isTrue);
      expect(report.canonical, isTrue);
      expect(report.lastError, isEmpty);
      expect(report.metrics['scenarioOrder'], hasLength(2));
      expect(report.metrics['eos_with_dead_object_recovery'], isA<Map>());
      expect(report.metrics['route_disconnect_terminal'], isA<Map>());
    });

    test('every required gate false causes isVerifiedPass to fail', () {
      for (final gateKey
          in VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
              .requiredGateKeys) {
        final raw = _createSampleRawMap();
        final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
        lanes[gateKey] = false;
        raw['lanes'] = lanes;
        final report =
            VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.fromMap(
              raw,
            );
        expect(report.isVerifiedPass, isFalse, reason: gateKey);
        expect(report.pass, isFalse, reason: gateKey);
        expect(report.marker, equals(_kFailMarker));
        expect(report.lastError, equals('gate_failed'));
      }
    });

    test('missing required gate fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes.remove('deadObjectRemainderResumedOk');
      raw['lanes'] = lanes;
      final report =
          VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.fromMap(raw);
      expect(report.pass, isFalse);
      expect(report.status, equals('missing_gate'));
      expect(
        report.lastError,
        equals('missing_gate_deadObjectRemainderResumedOk'),
      );
    });

    test(
      'bad proof boundary / marker / status / failureReason fail closed',
      () {
        final badBoundary =
            VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.fromMap(
              _createSampleRawMap({'proofBoundary': 'invalid'}),
            );
        expect(badBoundary.pass, isFalse);
        expect(badBoundary.lastError, equals('proof_boundary_mismatch'));

        final badMarker =
            VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.fromMap(
              _createSampleRawMap({'marker': 'INVALID_MARKER'}),
            );
        expect(badMarker.pass, isFalse);
        expect(badMarker.lastError, equals('marker_mismatch'));

        final badStatus =
            VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.fromMap(
              _createSampleRawMap({'status': 'fail'}),
            );
        expect(badStatus.pass, isFalse);
        expect(badStatus.marker, equals(_kFailMarker));

        final withReason =
            VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.fromMap(
              _createSampleRawMap({
                'failureReason':
                    'eos_with_dead_object_recovery:dead_object_never_injected',
              }),
            );
        expect(withReason.pass, isFalse);
        expect(
          withReason.lastError,
          equals('eos_with_dead_object_recovery:dead_object_never_injected'),
        );
      },
    );

    test('non-map payload produces fail-shaped report', () {
      final report =
          VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.fromMap(null);
      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('native_result_not_a_map'));
      expect(report.deadObjectInjectedOnceOk, isFalse);
      final asString =
          VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.fromMap('x');
      expect(asString.isVerifiedPass, isFalse);
    });

    test('string-encoded booleans and round trip', () {
      final raw = <String, Object?>{
        'pass': 'true',
        'status': 'PASS',
        'marker': _kPassMarker,
        'proofBoundary': _kProofBoundary,
        'failureReason': '',
        'lanes': <String, Object?>{
          for (final k
              in VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
                  .requiredGateKeys)
            k: 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{'phaseFrames': 2048},
      };
      final report =
          VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.fromMap(raw);
      expect(report.isVerifiedPass, isTrue);
      expect(report.metrics['phaseFrames'], equals(2048));
      final map = report.toMap();
      expect(map['lanes'], isA<Map>());
      expect(report.toJson(), equals(map));
      expect(
        report.toString(),
        contains('VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport'),
      );
    });
  });

  group('MethodChannel invocation', () {
    test(
      'method route invoked with parameters and returns pass report',
      () async {
        String? invokedMethod;
        Map<Object?, Object?>? invokedArguments;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (
          MethodCall call,
        ) async {
          invokedMethod = call.method;
          invokedArguments = call.arguments as Map<Object?, Object?>?;
          if (call.method ==
              'runRealtimePlaybackPipelineSinkFaultToleranceSmoke') {
            return _createSampleRawMap();
          }
          return null;
        });

        final report =
            await VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.runRealtimePlaybackPipelineSinkFaultToleranceSmoke(
              sourcePath: '/tmp/test_clip.mov',
              maxDurationSec: 3.0,
              maxFramesPerMix: 512,
              baseVolume: 0.5,
              deadlineMs: 45000,
              pauseHoldMs: 150,
              phaseFrames: 2048,
            );

        expect(
          invokedMethod,
          equals('runRealtimePlaybackPipelineSinkFaultToleranceSmoke'),
        );
        expect(invokedArguments?['sourcePath'], equals('/tmp/test_clip.mov'));
        expect(invokedArguments?['maxFramesPerMix'], equals(512));
        expect(invokedArguments?['baseVolume'], equals(0.5));
        expect(invokedArguments?['deadlineMs'], equals(45000));
        expect(invokedArguments?['pauseHoldMs'], equals(150));
        expect(invokedArguments?['phaseFrames'], equals(2048));
        expect(invokedArguments?.containsKey('duckVolume'), isFalse);
        expect(report.isVerifiedPass, isTrue);
      },
    );

    test('PlatformException produces fallback report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        throw PlatformException(
          code: 'P4_REALTIME_PLAYBACK_PIPELINE_SINK_FAULT_TOLERANCE_SMOKE_BUSY',
          message: 'Diagnostic already running',
        );
      });
      final report =
          await VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.runRealtimePlaybackPipelineSinkFaultToleranceSmoke(
            sourcePath: '/tmp/test_clip.mov',
          );
      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_REALTIME_PLAYBACK_PIPELINE_SINK_FAULT_TOLERANCE_SMOKE_BUSY',
        ),
      );
    });

    test('TimeoutException produces fallback report', () async {
      const customChannel = MethodChannel(
        'vanguard_media_engine_pipeline_sink_fault_tolerance_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });
      final report =
          await VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.runRealtimePlaybackPipelineSinkFaultToleranceSmoke(
            sourcePath: '/tmp/test_clip.mov',
            timeout: const Duration(milliseconds: 10),
            channel: customChannel,
          );
      expect(report.pass, isFalse);
      expect(report.failureReason, equals('timeout'));
      expect(report.lastError, contains('timeout:'));
    });
  });
}
