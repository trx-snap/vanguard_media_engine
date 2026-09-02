// vg_realtime_playback_focus_response_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-FOCUS-RESPONSE (Y4a): Android True-DAG Phase 4
// realtime playback audio focus and becoming noisy response diagnostic smoke foundation
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'realtime_playback_focus_noisy_response_diagnostic_only_nonzero_gain_audiotrack_sink_base_gain_0_5_duck_gain_0_1_setvolume_telemetry_only_synthetic_pcm_from_y1_transport_no_mediacodec_no_mediaextractor_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_no_os_focus_arbitration_claim_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_SMOKE_START';
const _kJsonMarker = 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'focusGrantedOk': true,
    'noisyReceiverRegisteredOk': true,
    'baseGainSetOk': true,
    'duckAppliedOk': true,
    'duckRestoreOk': true,
    'transientPauseResumeOk': true,
    'becomingNoisyPauseOk': true,
    'permanentStopNoAutoResumeOk': true,
    'transportStoppedOk': true,
    'transportCompletedOk': true,
    'checksumIdentityOk': true,
    'sinkWriteAccountingOk': true,
    'audioTrackReleasedOk': true,
    'focusAbandonedOk': true,
    'receiverUnregisteredOk': true,
    'eventsDroppedZeroOk': true,
    'lifecycleOk': true,
    'eosScenarioPass': true,
    'noisyTerminalScenarioPass': true,
    'permanentTerminalScenarioPass': true,
    'allNativeLanesPass': true,
    'canonical': true,
  };

  final metrics = <String, Object?>{
    'sampleRate': 48000,
    'channelCount': 2,
    'maxFramesPerMix': 256,
    'trackCount': 2,
    'declaredFrameCount': 12000,
    'phaseFrames': 2048,
    'pauseHoldMs': 150,
    'eventAwaitMs': 2000,
    'baseGain': 0.5,
    'duckGain': 0.1,
    'scenarioOrder': <String>[
      'EOS_COMPLETION',
      'BECOMING_NOISY_TERMINAL',
      'PERMANENT_LOSS_TERMINAL',
    ],
    'eosAutoResumeAllowed': true,
    'noisyAutoResumeAllowed': false,
    'permanentAutoResumeAllowed': false,
    'noisyDuckApplySeq': 1,
    'noisyRestoreApplySeq': 2,
    'noisyTransientPauseApplySeq': 3,
    'noisyDuplicateTransientApplySeq': 4,
    'noisyFocusGainResumeApplySeq': 5,
    'noisyPauseApplySeq': 6,
    'noisyPauseApplyOrder': 5,
    'noisyPauseAppliedCount': 1,
    'noisyDuplicateNoOpCount': 0,
    'noisyHoldDispatchDelta': 0,
    'noisyHoldPushedDelta': 0,
    'noisyPlaybackHeadAtNoisyPause': 8192,
    'noisyTransportStateAtTailEnd': 'PAUSED',
    'noisyNativeStateAtTailEnd': 'PAUSED',
    'noisySinkPlayStateAtTailEnd': 2,
    'noisyTransportStopCalled': true,
    'noisyTransportStopAccepted': true,
    'noisyTransportState': 'STOPPED',
    'noisyFramesReadFromTransport': 8192,
    'noisyFramesWrittenToSink': 8192,
    'noisyKotlinSinkChecksumHex': '00000000abcdef12',
    'noisyNativeChecksumHex': '00000000abcdef12',
    'noisyEventsEnqueued': 6,
    'noisyEventsDrained': 6,
    'noisyEventsDropped': 0,
    'noisyRealFocusCallbackCount': 0,
    'noisyRealNoisyBroadcastCount': 0,
    'noisyReleaseCount': 1,
    'noisyFocusAbandonCount': 1,
    'noisyReceiverUnregisterCount': 1,
    'permanentDuckApplySeq': 1,
    'permanentRestoreApplySeq': 2,
    'permanentTransientPauseApplySeq': 3,
    'permanentDuplicateTransientApplySeq': 4,
    'permanentFocusGainResumeApplySeq': 5,
    'permanentStopApplySeq': 6,
    'permanentStopApplyOrder': 5,
    'permanentGainAttemptApplySeq': 7,
    'permanentGainAttemptApplyOrder': 6,
    'permanentStopAppliedCount': 1,
    'permanentGainAttemptRejectedCount': 1,
    'permanentFocusGainResumeAppliedCount': 1,
    'permanentTransportCommandAttempts': 4,
    'permanentPlaybackHeadAtPermanentStop': 8192,
    'permanentTransportStateAtTailEnd': 'STOPPED',
    'permanentNativeStateAtTailEnd': 'STOPPED',
    'permanentSinkPlayStateAtTailEnd': 2,
    'permanentTransportStopCalled': true,
    'permanentTransportStopAccepted': true,
    'permanentTransportState': 'STOPPED',
    'permanentFramesReadFromTransport': 8192,
    'permanentFramesWrittenToSink': 8192,
    'permanentKotlinSinkChecksumHex': '00000000abcdef34',
    'permanentNativeChecksumHex': '00000000abcdef34',
    'permanentEventsEnqueued': 7,
    'permanentEventsDrained': 7,
    'permanentEventsDropped': 0,
    'permanentRealFocusCallbackCount': 0,
    'permanentRealNoisyBroadcastCount': 0,
    'permanentReleaseCount': 1,
    'permanentFocusAbandonCount': 1,
    'permanentReceiverUnregisterCount': 1,
    'eosTransportStateAtTailEnd': 'COMPLETED',
    'eosTransportState': 'COMPLETED',
    'eosFramesReadFromTransport': 12000,
    'eosFramesWrittenToSink': 12000,
    'eosKotlinSinkChecksumHex': '00000000abcdef56',
    'eosNativeChecksumHex': '00000000abcdef56',
    'eosEventsEnqueued': 5,
    'eosEventsDrained': 5,
    'eosEventsDropped': 0,
    'eosRealFocusCallbackCount': 0,
    'eosRealNoisyBroadcastCount': 0,
    'eosReleaseCount': 1,
    'eosFocusAbandonCount': 1,
    'eosReceiverUnregisterCount': 1,
    'eosFailureReason': '',
    'noisyFailureReason': '',
    'permanentFailureReason': '',
    'eosLanes': <String, Object?>{'lifecycleOk': true},
    'noisyLanes': <String, Object?>{'lifecycleOk': true},
    'permanentLanes': <String, Object?>{'lifecycleOk': true},
    'eosMetrics': <String, Object?>{'framesReadFromTransport': 12000},
    'noisyMetrics': <String, Object?>{'framesReadFromTransport': 8192},
    'permanentMetrics': <String, Object?>{'framesReadFromTransport': 8192},
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'nativeProofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'Y4a realtime playback focus response harness pass=true',
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

VGRealtimePlaybackFocusResponseSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGRealtimePlaybackFocusResponseSmokeReport.fromMap(
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

  group('VGRealtimePlaybackFocusResponseSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.methodName,
        equals('runRealtimePlaybackFocusResponseSmoke'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.startMarkerConstant,
        equals(_kStartMarker),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.jsonMarkerConstant,
        equals(_kJsonMarker),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys.length,
        equals(21),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('focusGrantedOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('noisyReceiverRegisteredOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('baseGainSetOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('duckAppliedOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('duckRestoreOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('transientPauseResumeOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('becomingNoisyPauseOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('permanentStopNoAutoResumeOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('transportStoppedOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('transportCompletedOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('checksumIdentityOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('sinkWriteAccountingOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('audioTrackReleasedOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('focusAbandonedOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('receiverUnregisteredOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('eventsDroppedZeroOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('lifecycleOk'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('eosScenarioPass'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('noisyTerminalScenarioPass'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('permanentTerminalScenarioPass'),
      );
      expect(
        VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys,
        contains('allNativeLanesPass'),
      );
    });
  });

  group('VGRealtimePlaybackFocusResponseSmokeReport.fromMap parsing', () {
    test('pass payload parses true with all gates and metrics', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.status, equals('pass'));
      expect(report.marker, equals(_kPassMarker));
      expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.nativeProofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.isVerifiedPass, isTrue);
      expect(report.lastError, isEmpty);
      expect(report.failureReason, isEmpty);

      // Verify gates
      expect(report.focusGrantedOk, isTrue);
      expect(report.noisyReceiverRegisteredOk, isTrue);
      expect(report.baseGainSetOk, isTrue);
      expect(report.duckAppliedOk, isTrue);
      expect(report.duckRestoreOk, isTrue);
      expect(report.transientPauseResumeOk, isTrue);
      expect(report.becomingNoisyPauseOk, isTrue);
      expect(report.permanentStopNoAutoResumeOk, isTrue);
      expect(report.transportStoppedOk, isTrue);
      expect(report.transportCompletedOk, isTrue);
      expect(report.checksumIdentityOk, isTrue);
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.audioTrackReleasedOk, isTrue);
      expect(report.focusAbandonedOk, isTrue);
      expect(report.receiverUnregisteredOk, isTrue);
      expect(report.eventsDroppedZeroOk, isTrue);
      expect(report.lifecycleOk, isTrue);
      expect(report.eosScenarioPass, isTrue);
      expect(report.noisyTerminalScenarioPass, isTrue);
      expect(report.permanentTerminalScenarioPass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.canonical, isTrue);

      // Verify metrics in metrics map
      expect(report.metrics['sampleRate'], equals(48000));
      expect(report.metrics['channelCount'], equals(2));
      expect(report.metrics['maxFramesPerMix'], equals(256));
      expect(report.metrics['trackCount'], equals(2));
      expect(report.metrics['declaredFrameCount'], equals(12000));
      expect(report.metrics['phaseFrames'], equals(2048));
      expect(report.metrics['pauseHoldMs'], equals(150));
      expect(report.metrics['eventAwaitMs'], equals(2000));
      expect(report.metrics['baseGain'], equals(0.5));
      expect(report.metrics['duckGain'], equals(0.1));
      expect(report.metrics['scenarioOrder'], hasLength(3));
      expect(report.metrics['eosAutoResumeAllowed'], isTrue);
      expect(report.metrics['noisyAutoResumeAllowed'], isFalse);
      expect(report.metrics['permanentAutoResumeAllowed'], isFalse);
      expect(report.metrics['noisyHoldDispatchDelta'], equals(0));
      expect(report.metrics['noisyHoldPushedDelta'], equals(0));
      expect(report.metrics['noisyTransportState'], equals('STOPPED'));
      expect(report.metrics['permanentTransportState'], equals('STOPPED'));
      expect(report.metrics['eosTransportState'], equals('COMPLETED'));
      expect(report.metrics['noisyReleaseCount'], equals(1));
      expect(report.metrics['permanentReleaseCount'], equals(1));
      expect(report.metrics['eosReleaseCount'], equals(1));
    });

    test('every required gate false causes isVerifiedPass to fail', () {
      for (final gateKey
          in VGRealtimePlaybackFocusResponseSmokeReport.requiredGateKeys) {
        final raw = _createSampleRawMap();
        final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
        lanes[gateKey] = false;
        raw['lanes'] = lanes;

        final report = VGRealtimePlaybackFocusResponseSmokeReport.fromMap(raw);
        expect(
          report.isVerifiedPass,
          isFalse,
          reason: 'Gate $gateKey set to false should fail isVerifiedPass',
        );
        expect(
          report.pass,
          isFalse,
          reason: 'Gate $gateKey set to false should fail pass',
        );
        expect(report.marker, equals(_kFailMarker));
      }
    });

    test('missing required gate fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes.remove('becomingNoisyPauseOk');
      raw['lanes'] = lanes;

      final report = VGRealtimePlaybackFocusResponseSmokeReport.fromMap(raw);
      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('missing_gate'));
      expect(report.lastError, equals('missing_gate_becomingNoisyPauseOk'));
    });

    test('bad proof boundary fails closed', () {
      final raw = _createSampleRawMap({
        'proofBoundary': 'invalid_proof_boundary_string',
      });
      final report = VGRealtimePlaybackFocusResponseSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.lastError, equals('proof_boundary_mismatch'));
    });

    test('bad marker fails closed', () {
      final raw = _createSampleRawMap({'marker': 'INVALID_MARKER'});
      final report = VGRealtimePlaybackFocusResponseSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.lastError, equals('marker_mismatch'));
    });

    test('bad status fails closed', () {
      final raw = _createSampleRawMap({'status': 'fail'});
      final report = VGRealtimePlaybackFocusResponseSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
    });

    test('non-empty failureReason fails closed', () {
      final raw = _createSampleRawMap({
        'failureReason': 'noisy_terminal_scenario_gates_not_held',
      });
      final report = VGRealtimePlaybackFocusResponseSmokeReport.fromMap(raw);

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals('noisy_terminal_scenario_gates_not_held'),
      );
      expect(
        report.lastError,
        equals('noisy_terminal_scenario_gates_not_held'),
      );
    });

    test(
      'malformed/non-map MethodChannel payload produces fail-shaped report',
      () {
        final reportNull = VGRealtimePlaybackFocusResponseSmokeReport.fromMap(
          null,
        );
        expect(reportNull.pass, isFalse);
        expect(reportNull.isVerifiedPass, isFalse);
        expect(reportNull.marker, equals(_kFailMarker));
        expect(reportNull.failureReason, equals('native_result_not_a_map'));
        expect(reportNull.lastError, equals('native_result_not_a_map'));
        expect(reportNull.focusGrantedOk, isFalse);
        expect(reportNull.eosScenarioPass, isFalse);

        final reportString = VGRealtimePlaybackFocusResponseSmokeReport.fromMap(
          'string_error',
        );
        expect(reportString.pass, isFalse);
        expect(reportString.isVerifiedPass, isFalse);
        expect(reportString.marker, equals(_kFailMarker));
        expect(reportString.failureReason, equals('native_result_not_a_map'));
      },
    );

    test('defensive parsing handles string-encoded booleans', () {
      final raw = <String, Object?>{
        'pass': 'true',
        'status': 'PASS',
        'marker': _kPassMarker,
        'proofBoundary': _kCanonicalProofBoundary,
        'failureReason': '',
        'lanes': <String, Object?>{
          'focusGrantedOk': 'true',
          'noisyReceiverRegisteredOk': 'ok',
          'baseGainSetOk': 'true',
          'duckAppliedOk': 'true',
          'duckRestoreOk': 'true',
          'transientPauseResumeOk': 'true',
          'becomingNoisyPauseOk': 'true',
          'permanentStopNoAutoResumeOk': 'true',
          'transportStoppedOk': 'true',
          'transportCompletedOk': 'true',
          'checksumIdentityOk': 'true',
          'sinkWriteAccountingOk': 'true',
          'audioTrackReleasedOk': 'true',
          'focusAbandonedOk': 'true',
          'receiverUnregisteredOk': 'true',
          'eventsDroppedZeroOk': 'true',
          'lifecycleOk': 'true',
          'eosScenarioPass': 'true',
          'noisyTerminalScenarioPass': 'true',
          'permanentTerminalScenarioPass': 'true',
          'allNativeLanesPass': 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{
          'sampleRate': 48000,
          'baseGain': 0.5,
          'duckGain': 0.1,
        },
      };

      final report = VGRealtimePlaybackFocusResponseSmokeReport.fromMap(raw);
      expect(report.pass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.focusGrantedOk, isTrue);
      expect(report.noisyReceiverRegisteredOk, isTrue);
      expect(report.metrics['sampleRate'], equals(48000));
      expect(report.metrics['baseGain'], equals(0.5));
    });

    test('nested lane and metric maps are preserved', () {
      final sample = _createSampleRawMap();
      final report = VGRealtimePlaybackFocusResponseSmokeReport.fromMap(sample);

      expect(report.metrics['eosLanes'], isA<Map>());
      expect(report.metrics['noisyMetrics'], isA<Map>());
      expect(report.lanes['focusGrantedOk'], isTrue);

      final map = report.toMap();
      expect(map['lanes'], isA<Map>());
      expect(map['metrics'], isA<Map>());
      expect(report.toJson(), equals(map));
    });

    test('toString produces diagnostic representation', () {
      final report = _createSampleReport();
      expect(
        report.toString(),
        contains('VGRealtimePlaybackFocusResponseSmokeReport'),
      );
      expect(report.toString(), contains('focusGrantedOk: true'));
      expect(report.toString(), contains('isVerifiedPass: true'));
    });
  });

  group('VGRealtimePlaybackFocusResponseSmokeReport MethodChannel invocation', () {
    test('method route invoked exactly and returns pass report', () async {
      String? invokedMethod;
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        invokedMethod = call.method;
        if (call.method == 'runRealtimePlaybackFocusResponseSmoke') {
          return _createSampleRawMap();
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackFocusResponseSmokeReport.runRealtimePlaybackFocusResponseSmoke();

      expect(invokedMethod, equals('runRealtimePlaybackFocusResponseSmoke'));
      expect(report.pass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.hasPassMarker, isTrue);
    });

    test('PlatformException produces harness exception report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runRealtimePlaybackFocusResponseSmoke') {
          throw PlatformException(
            code: 'P4_REALTIME_PLAYBACK_FOCUS_RESPONSE_BUSY',
            message: 'Diagnostic already running',
          );
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackFocusResponseSmokeReport.runRealtimePlaybackFocusResponseSmoke();

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals('platform_exception:P4_REALTIME_PLAYBACK_FOCUS_RESPONSE_BUSY'),
      );
      expect(
        report.lastError,
        contains(
          'platform_exception:P4_REALTIME_PLAYBACK_FOCUS_RESPONSE_BUSY:Diagnostic already running',
        ),
      );
    });

    test('TimeoutException produces fallback error report', () async {
      final customChannel = const MethodChannel(
        'vanguard_media_engine_focus_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });

      final report =
          await VGRealtimePlaybackFocusResponseSmokeReport.runRealtimePlaybackFocusResponseSmoke(
            timeout: const Duration(milliseconds: 10),
            channel: customChannel,
          );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('timeout'));
      expect(report.lastError, contains('timeout:'));
    });
  });
}
