// vg_realtime_playback_pipeline_focus_response_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-FOCUS-RESPONSE (Y6d):
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kProofBoundary =
    VGRealtimePlaybackPipelineFocusResponseSmokeReport.proofBoundaryConstant;
const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_FOCUS_RESPONSE_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_FOCUS_RESPONSE_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_FOCUS_RESPONSE_SMOKE_START';
const _kJsonMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_FOCUS_RESPONSE_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    for (final k
        in VGRealtimePlaybackPipelineFocusResponseSmokeReport.requiredGateKeys)
      k: true,
    'canonical': true,
  };
  final metrics = <String, Object?>{
    'maxDurationSec': 3.0,
    'maxFramesPerMix': 256,
    'baseVolume': 0.5,
    'duckVolume': 0.1,
    'pauseHoldMs': 150,
    'phaseFrames': 2048,
    'scenarioOrder': <String>[
      'EOS_COMPLETION',
      'BECOMING_NOISY_TERMINAL',
      'PERMANENT_LOSS_TERMINAL',
    ],
    'eos_completionScenarioPass': true,
    'becoming_noisy_terminalScenarioPass': true,
    'permanent_loss_terminalScenarioPass': true,
    'eos_completion': <String, Object?>{
      'scenario': 'EOS_COMPLETION',
      'sampleRate': 48000,
      'channelCount': 2,
      'declaredFrameCount': 144000,
      'framesWrittenToSink': 144000,
      'transportStateFinal': 'DISPOSED',
      'sinkExitReason': 'eos',
    },
    'becoming_noisy_terminal': <String, Object?>{
      'scenario': 'BECOMING_NOISY_TERMINAL',
      'sinkExitReason': 'terminal_exit',
      'autoResumeAllowed': false,
    },
    'permanent_loss_terminal': <String, Object?>{
      'scenario': 'PERMANENT_LOSS_TERMINAL',
      'sinkExitReason': 'terminal_exit',
      'stopState': 'STOPPED',
      'gainAttemptRejectedCount': 1,
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
        'Y6d realtime playback pipeline focus response harness pass=true',
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

  group('VGRealtimePlaybackPipelineFocusResponseSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGRealtimePlaybackPipelineFocusResponseSmokeReport.methodName,
        equals('runRealtimePlaybackPipelineFocusResponseSmoke'),
      );
      expect(
        VGRealtimePlaybackPipelineFocusResponseSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGRealtimePlaybackPipelineFocusResponseSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGRealtimePlaybackPipelineFocusResponseSmokeReport.startMarkerConstant,
        equals(_kStartMarker),
      );
      expect(
        VGRealtimePlaybackPipelineFocusResponseSmokeReport.jsonMarkerConstant,
        equals(_kJsonMarker),
      );
      expect(
        VGRealtimePlaybackPipelineFocusResponseSmokeReport
            .proofBoundaryConstant,
        contains('no_seek_no_route_change_no_dead_object_recovery'),
      );
      expect(
        VGRealtimePlaybackPipelineFocusResponseSmokeReport
            .requiredGateKeys
            .length,
        equals(18),
      );
      for (final key in <String>[
        'formatProbeOk',
        'preRollOk',
        'focusGrantedOk',
        'noisyReceiverRegisteredOk',
        'preStartDrainEmptyOk',
        'duckAppliedOk',
        'duckRestoreOk',
        'transientPauseResumeOk',
        'becomingNoisyPauseOk',
        'permanentStopNoAutoResumeOk',
        'sinkWriteAccountingOk',
        'checksumIdentityOk',
        'transportCompletedOk',
        'transportStoppedOk',
        'focusLifecycleOk',
        'audioTrackLifecycleOk',
        'threadOwnershipOk',
        'proofBoundaryOk',
      ]) {
        expect(
          VGRealtimePlaybackPipelineFocusResponseSmokeReport.requiredGateKeys,
          contains(key),
        );
      }
    });
  });

  group('VGRealtimePlaybackPipelineFocusResponseSmokeReport.fromMap', () {
    test('pass payload parses true with all gates and metrics', () {
      final report = VGRealtimePlaybackPipelineFocusResponseSmokeReport.fromMap(
        _createSampleRawMap(),
      );
      expect(report.pass, isTrue);
      expect(report.status, equals('pass'));
      expect(report.hasPassMarker, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.allRequiredGatesTrue, isTrue);
      expect(report.becomingNoisyPauseOk, isTrue);
      expect(report.permanentStopNoAutoResumeOk, isTrue);
      expect(report.transportStoppedOk, isTrue);
      expect(report.focusLifecycleOk, isTrue);
      expect(report.canonical, isTrue);
      expect(report.lastError, isEmpty);
      expect(report.metrics['scenarioOrder'], hasLength(3));
      expect(report.metrics['eos_completion'], isA<Map>());
    });

    test('every required gate false causes isVerifiedPass to fail', () {
      for (final gateKey
          in VGRealtimePlaybackPipelineFocusResponseSmokeReport
              .requiredGateKeys) {
        final raw = _createSampleRawMap();
        final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
        lanes[gateKey] = false;
        raw['lanes'] = lanes;
        final report =
            VGRealtimePlaybackPipelineFocusResponseSmokeReport.fromMap(raw);
        expect(report.isVerifiedPass, isFalse, reason: gateKey);
        expect(report.pass, isFalse, reason: gateKey);
        expect(report.marker, equals(_kFailMarker));
        expect(report.lastError, equals('gate_failed'));
      }
    });

    test('missing required gate fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes.remove('becomingNoisyPauseOk');
      raw['lanes'] = lanes;
      final report = VGRealtimePlaybackPipelineFocusResponseSmokeReport.fromMap(
        raw,
      );
      expect(report.pass, isFalse);
      expect(report.status, equals('missing_gate'));
      expect(report.lastError, equals('missing_gate_becomingNoisyPauseOk'));
    });

    test(
      'bad proof boundary / marker / status / failureReason fail closed',
      () {
        final badBoundary =
            VGRealtimePlaybackPipelineFocusResponseSmokeReport.fromMap(
              _createSampleRawMap({'proofBoundary': 'invalid'}),
            );
        expect(badBoundary.pass, isFalse);
        expect(badBoundary.lastError, equals('proof_boundary_mismatch'));

        final badMarker =
            VGRealtimePlaybackPipelineFocusResponseSmokeReport.fromMap(
              _createSampleRawMap({'marker': 'INVALID_MARKER'}),
            );
        expect(badMarker.pass, isFalse);
        expect(badMarker.lastError, equals('marker_mismatch'));

        final badStatus =
            VGRealtimePlaybackPipelineFocusResponseSmokeReport.fromMap(
              _createSampleRawMap({'status': 'fail'}),
            );
        expect(badStatus.pass, isFalse);
        expect(badStatus.marker, equals(_kFailMarker));

        final withReason =
            VGRealtimePlaybackPipelineFocusResponseSmokeReport.fromMap(
              _createSampleRawMap({
                'failureReason':
                    'permanent_loss_terminal:gain_attempt_not_rejected',
              }),
            );
        expect(withReason.pass, isFalse);
        expect(
          withReason.lastError,
          equals('permanent_loss_terminal:gain_attempt_not_rejected'),
        );
      },
    );

    test('non-map payload produces fail-shaped report', () {
      final report = VGRealtimePlaybackPipelineFocusResponseSmokeReport.fromMap(
        null,
      );
      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('native_result_not_a_map'));
      expect(report.duckAppliedOk, isFalse);
      final asString =
          VGRealtimePlaybackPipelineFocusResponseSmokeReport.fromMap('x');
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
              in VGRealtimePlaybackPipelineFocusResponseSmokeReport
                  .requiredGateKeys)
            k: 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{'phaseFrames': 2048},
      };
      final report = VGRealtimePlaybackPipelineFocusResponseSmokeReport.fromMap(
        raw,
      );
      expect(report.isVerifiedPass, isTrue);
      expect(report.metrics['phaseFrames'], equals(2048));
      final map = report.toMap();
      expect(map['lanes'], isA<Map>());
      expect(report.toJson(), equals(map));
      expect(
        report.toString(),
        contains('VGRealtimePlaybackPipelineFocusResponseSmokeReport'),
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
          if (call.method == 'runRealtimePlaybackPipelineFocusResponseSmoke') {
            return _createSampleRawMap();
          }
          return null;
        });

        final report =
            await VGRealtimePlaybackPipelineFocusResponseSmokeReport.runRealtimePlaybackPipelineFocusResponseSmoke(
              sourcePath: '/tmp/test_clip.mov',
              maxDurationSec: 3.0,
              maxFramesPerMix: 512,
              baseVolume: 0.5,
              duckVolume: 0.1,
              deadlineMs: 45000,
              pauseHoldMs: 150,
              phaseFrames: 2048,
            );

        expect(
          invokedMethod,
          equals('runRealtimePlaybackPipelineFocusResponseSmoke'),
        );
        expect(invokedArguments?['sourcePath'], equals('/tmp/test_clip.mov'));
        expect(invokedArguments?['maxFramesPerMix'], equals(512));
        expect(invokedArguments?['duckVolume'], equals(0.1));
        expect(invokedArguments?['deadlineMs'], equals(45000));
        expect(invokedArguments?['pauseHoldMs'], equals(150));
        expect(invokedArguments?['phaseFrames'], equals(2048));
        expect(report.isVerifiedPass, isTrue);
      },
    );

    test('PlatformException produces fallback report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        throw PlatformException(
          code: 'P4_REALTIME_PLAYBACK_PIPELINE_FOCUS_RESPONSE_SMOKE_BUSY',
          message: 'Diagnostic already running',
        );
      });
      final report =
          await VGRealtimePlaybackPipelineFocusResponseSmokeReport.runRealtimePlaybackPipelineFocusResponseSmoke(
            sourcePath: '/tmp/test_clip.mov',
          );
      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_REALTIME_PLAYBACK_PIPELINE_FOCUS_RESPONSE_SMOKE_BUSY',
        ),
      );
    });

    test('TimeoutException produces fallback report', () async {
      const customChannel = MethodChannel(
        'vanguard_media_engine_pipeline_focus_response_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });
      final report =
          await VGRealtimePlaybackPipelineFocusResponseSmokeReport.runRealtimePlaybackPipelineFocusResponseSmoke(
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
