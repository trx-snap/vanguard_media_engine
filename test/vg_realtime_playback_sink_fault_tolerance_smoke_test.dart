// vg_realtime_playback_sink_fault_tolerance_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-SINK-FAULT-TOLERANCE (Y4b): Android True-DAG Phase 4
// realtime playback AudioTrack sink fault tolerance diagnostic smoke foundation
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'realtime_playback_sink_fault_tolerance_diagnostic_only_nonzero_gain_audiotrack_sink_base_gain_0_5_synthetic_pcm_from_y1_transport_synthetic_dead_object_recovery_only_route_change_listener_handoff_and_fail_closed_pause_only_no_mediacodec_no_mediaextractor_no_presentation_clock_no_av_sync_no_os_route_arbitration_claim_no_real_os_dead_object_forcing_claim_no_seamless_hot_swap_claim_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_SMOKE_START';
const _kJsonMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'audioTrackInitOk': true,
    'baseGainSetOk': true,
    'routingListenerRegisteredOk': true,
    'routingListenerUnregisteredOk': true,
    'routeChangeObservationOk': true,
    'routeDisconnectFailClosedPauseOk': true,
    'deadObjectInjectedOnceOk': true,
    'deadObjectOldTrackReleasedOk': true,
    'deadObjectNewTrackStateInitializedOk': true,
    'deadObjectNewTrackVolumeSetOk': true,
    'deadObjectNewTrackPlayOk': true,
    'deadObjectRemainderResumedOk': true,
    'deadObjectNoDoubleCountOk': true,
    'transportCompletedOk': true,
    'transportStoppedOk': true,
    'checksumIdentityOk': true,
    'sinkWriteAccountingOk': true,
    'audioTrackReleasedOk': true,
    'eventsDroppedZeroOk': true,
    'lifecycleOk': true,
    'eosScenarioPass': true,
    'routeDisconnectTerminalScenarioPass': true,
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
    'scenarioOrder': <String>[
      'EOS_WITH_DEAD_OBJECT_RECOVERY',
      'ROUTE_DISCONNECT_TERMINAL',
    ],
    'eosAutoResumeAllowed': true,
    'disconnectAutoResumeAllowed': false,
    'eosRouteChangedApplySeq': 1,
    'eosRouteChangedAppliedCount': 1,
    'eosRoutedDeviceTypeAtRouteChanged': 2,
    'eosSyntheticDeadObjectInjectedCount': 1,
    'eosDeadObjectObservedCount': 1,
    'eosDeadObjectInjectAfterFrames': 4096,
    'eosDeadObjectOldTrackReleaseCount': 1,
    'eosDeadObjectOldTrackListenerDetachOk': true,
    'eosDeadObjectSliceBytesAtRecovery': 1024,
    'eosDeadObjectUnwrittenBytesAtRecovery': 1024,
    'eosDeadObjectBufferPositionAtRecovery': 0,
    'eosDeadObjectSinkFramesWrittenBeforeRecovery': 4096,
    'eosDeadObjectSinkFramesWrittenAfterRecoveryCall': 4096,
    'eosDeadObjectRemainderFramesWrittenOnNewTrack': 256,
    'eosDeadObjectFramesReadAtRecovery': 4352,
    'eosPlayStateAfterRecreatePlay': 3,
    'eosFrozenBufferSizeInFrames': 4096,
    'eosNewTrackBufferSizeInFrames': 4096,
    'eosAudioTracksCreated': 2,
    'eosAudioTracksReleased': 2,
    'eosFinalReleaseCount': 1,
    'eosListenerAttachCount': 2,
    'eosListenerDetachCount': 2,
    'eosPlaybackHeadFinal': 12000,
    'eosTransportStateAtTailEnd': 'COMPLETED',
    'eosNativeStateAtTailEnd': 'COMPLETED',
    'eosSinkPlayStateAtTailEnd': 3,
    'eosTransportState': 'COMPLETED',
    'eosFramesReadFromTransport': 12000,
    'eosFramesWrittenToSink': 12000,
    'eosPartialWriteCount': 0,
    'eosKotlinSinkChecksumHex': '00000000abcdef12',
    'eosNativeChecksumHex': '00000000abcdef12',
    'eosEventsEnqueued': 3,
    'eosEventsDrained': 3,
    'eosEventsDropped': 0,
    'eosRealRoutingCallbackCount': 0,
    'disconnectRouteChangedApplySeq': 1,
    'disconnectRouteChangedAppliedCount': 1,
    'disconnectRoutedDeviceTypeAtRouteChanged': 2,
    'disconnectRouteDisconnectApplySeq': 2,
    'disconnectRouteDisconnectApplyOrder': 2,
    'disconnectRouteDisconnectAppliedCount': 1,
    'disconnectRouteChangedAfterDisconnectCount': 0,
    'disconnectTransportCommandAttempts': 2,
    'disconnectHoldDispatchDelta': 0,
    'disconnectHoldPushedDelta': 0,
    'disconnectPlaybackHeadAtRouteDisconnect': 8192,
    'disconnectTransportStateAtTailEnd': 'PAUSED',
    'disconnectNativeStateAtTailEnd': 'PAUSED',
    'disconnectSinkPlayStateAtTailEnd': 2,
    'disconnectTransportStopCalled': true,
    'disconnectTransportStopAccepted': true,
    'disconnectTransportState': 'STOPPED',
    'disconnectAudioTracksCreated': 1,
    'disconnectAudioTracksReleased': 1,
    'disconnectFinalReleaseCount': 1,
    'disconnectListenerAttachCount': 1,
    'disconnectListenerDetachCount': 1,
    'disconnectFramesReadFromTransport': 8192,
    'disconnectFramesWrittenToSink': 8192,
    'disconnectPartialWriteCount': 0,
    'disconnectKotlinSinkChecksumHex': '00000000abcdef34',
    'disconnectNativeChecksumHex': '00000000abcdef34',
    'disconnectEventsEnqueued': 2,
    'disconnectEventsDrained': 2,
    'disconnectEventsDropped': 0,
    'disconnectRealRoutingCallbackCount': 0,
    'eosFailureReason': '',
    'disconnectFailureReason': '',
    'eosLanes': <String, Object?>{'lifecycleOk': true},
    'disconnectLanes': <String, Object?>{'lifecycleOk': true},
    'eosMetrics': <String, Object?>{'framesReadFromTransport': 12000},
    'disconnectMetrics': <String, Object?>{'framesReadFromTransport': 8192},
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'nativeProofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'Y4b realtime playback sink fault tolerance harness pass=true',
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

VGRealtimePlaybackSinkFaultToleranceSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGRealtimePlaybackSinkFaultToleranceSmokeReport.fromMap(
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

  group('VGRealtimePlaybackSinkFaultToleranceSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.methodName,
        equals('runRealtimePlaybackSinkFaultToleranceSmoke'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.startMarkerConstant,
        equals(_kStartMarker),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.jsonMarkerConstant,
        equals(_kJsonMarker),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys.length,
        equals(23),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('audioTrackInitOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('baseGainSetOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('routingListenerRegisteredOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('routingListenerUnregisteredOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('routeChangeObservationOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('routeDisconnectFailClosedPauseOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('deadObjectInjectedOnceOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('deadObjectOldTrackReleasedOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('deadObjectNewTrackStateInitializedOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('deadObjectNewTrackVolumeSetOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('deadObjectNewTrackPlayOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('deadObjectRemainderResumedOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('deadObjectNoDoubleCountOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('transportCompletedOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('transportStoppedOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('checksumIdentityOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('sinkWriteAccountingOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('audioTrackReleasedOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('eventsDroppedZeroOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('lifecycleOk'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('eosScenarioPass'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('routeDisconnectTerminalScenarioPass'),
      );
      expect(
        VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys,
        contains('allNativeLanesPass'),
      );
    });
  });

  group('VGRealtimePlaybackSinkFaultToleranceSmokeReport.fromMap parsing', () {
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
      expect(report.audioTrackInitOk, isTrue);
      expect(report.baseGainSetOk, isTrue);
      expect(report.routingListenerRegisteredOk, isTrue);
      expect(report.routingListenerUnregisteredOk, isTrue);
      expect(report.routeChangeObservationOk, isTrue);
      expect(report.routeDisconnectFailClosedPauseOk, isTrue);
      expect(report.deadObjectInjectedOnceOk, isTrue);
      expect(report.deadObjectOldTrackReleasedOk, isTrue);
      expect(report.deadObjectNewTrackStateInitializedOk, isTrue);
      expect(report.deadObjectNewTrackVolumeSetOk, isTrue);
      expect(report.deadObjectNewTrackPlayOk, isTrue);
      expect(report.deadObjectRemainderResumedOk, isTrue);
      expect(report.deadObjectNoDoubleCountOk, isTrue);
      expect(report.transportCompletedOk, isTrue);
      expect(report.transportStoppedOk, isTrue);
      expect(report.checksumIdentityOk, isTrue);
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.audioTrackReleasedOk, isTrue);
      expect(report.eventsDroppedZeroOk, isTrue);
      expect(report.lifecycleOk, isTrue);
      expect(report.eosScenarioPass, isTrue);
      expect(report.routeDisconnectTerminalScenarioPass, isTrue);
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
      expect(report.metrics['scenarioOrder'], hasLength(2));
      expect(report.metrics['eosAutoResumeAllowed'], isTrue);
      expect(report.metrics['disconnectAutoResumeAllowed'], isFalse);
      expect(report.metrics['eosSyntheticDeadObjectInjectedCount'], equals(1));
      expect(report.metrics['eosDeadObjectObservedCount'], equals(1));
      expect(report.metrics['eosAudioTracksCreated'], equals(2));
      expect(report.metrics['eosAudioTracksReleased'], equals(2));
      expect(report.metrics['eosFinalReleaseCount'], equals(1));
      expect(report.metrics['eosListenerAttachCount'], equals(2));
      expect(report.metrics['eosListenerDetachCount'], equals(2));
      expect(report.metrics['eosTransportState'], equals('COMPLETED'));
      expect(
        report.metrics['disconnectRouteDisconnectAppliedCount'],
        equals(1),
      );
      expect(report.metrics['disconnectHoldDispatchDelta'], equals(0));
      expect(report.metrics['disconnectHoldPushedDelta'], equals(0));
      expect(report.metrics['disconnectTransportState'], equals('STOPPED'));
      expect(report.metrics['disconnectAudioTracksCreated'], equals(1));
      expect(report.metrics['disconnectAudioTracksReleased'], equals(1));
      expect(report.metrics['disconnectFinalReleaseCount'], equals(1));
      expect(report.metrics['disconnectListenerAttachCount'], equals(1));
      expect(report.metrics['disconnectListenerDetachCount'], equals(1));
    });

    test('every required gate false causes isVerifiedPass to fail', () {
      for (final gateKey
          in VGRealtimePlaybackSinkFaultToleranceSmokeReport.requiredGateKeys) {
        final raw = _createSampleRawMap();
        final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
        lanes[gateKey] = false;
        raw['lanes'] = lanes;

        final report = VGRealtimePlaybackSinkFaultToleranceSmokeReport.fromMap(
          raw,
        );
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
      lanes.remove('deadObjectRemainderResumedOk');
      raw['lanes'] = lanes;

      final report = VGRealtimePlaybackSinkFaultToleranceSmokeReport.fromMap(
        raw,
      );
      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('missing_gate'));
      expect(
        report.lastError,
        equals('missing_gate_deadObjectRemainderResumedOk'),
      );
    });

    test('bad proof boundary fails closed', () {
      final raw = _createSampleRawMap({
        'proofBoundary': 'invalid_proof_boundary_string',
      });
      final report = VGRealtimePlaybackSinkFaultToleranceSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.lastError, equals('proof_boundary_mismatch'));
    });

    test('bad marker fails closed', () {
      final raw = _createSampleRawMap({'marker': 'INVALID_MARKER'});
      final report = VGRealtimePlaybackSinkFaultToleranceSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.lastError, equals('marker_mismatch'));
    });

    test('bad status fails closed', () {
      final raw = _createSampleRawMap({'status': 'fail'});
      final report = VGRealtimePlaybackSinkFaultToleranceSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
    });

    test('non-empty failureReason fails closed', () {
      final raw = _createSampleRawMap({
        'failureReason': 'route_disconnect_terminal_scenario_gates_not_held',
      });
      final report = VGRealtimePlaybackSinkFaultToleranceSmokeReport.fromMap(
        raw,
      );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals('route_disconnect_terminal_scenario_gates_not_held'),
      );
      expect(
        report.lastError,
        equals('route_disconnect_terminal_scenario_gates_not_held'),
      );
    });

    test(
      'malformed/non-map MethodChannel payload produces fail-shaped report',
      () {
        final reportNull =
            VGRealtimePlaybackSinkFaultToleranceSmokeReport.fromMap(null);
        expect(reportNull.pass, isFalse);
        expect(reportNull.isVerifiedPass, isFalse);
        expect(reportNull.marker, equals(_kFailMarker));
        expect(reportNull.failureReason, equals('native_result_not_a_map'));
        expect(reportNull.lastError, equals('native_result_not_a_map'));
        expect(reportNull.audioTrackInitOk, isFalse);
        expect(reportNull.eosScenarioPass, isFalse);

        final reportString =
            VGRealtimePlaybackSinkFaultToleranceSmokeReport.fromMap(
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
          'audioTrackInitOk': 'true',
          'baseGainSetOk': 'ok',
          'routingListenerRegisteredOk': 'true',
          'routingListenerUnregisteredOk': 'true',
          'routeChangeObservationOk': 'true',
          'routeDisconnectFailClosedPauseOk': 'true',
          'deadObjectInjectedOnceOk': 'true',
          'deadObjectOldTrackReleasedOk': 'true',
          'deadObjectNewTrackStateInitializedOk': 'true',
          'deadObjectNewTrackVolumeSetOk': 'true',
          'deadObjectNewTrackPlayOk': 'true',
          'deadObjectRemainderResumedOk': 'true',
          'deadObjectNoDoubleCountOk': 'true',
          'transportCompletedOk': 'true',
          'transportStoppedOk': 'true',
          'checksumIdentityOk': 'true',
          'sinkWriteAccountingOk': 'true',
          'audioTrackReleasedOk': 'true',
          'eventsDroppedZeroOk': 'true',
          'lifecycleOk': 'true',
          'eosScenarioPass': 'true',
          'routeDisconnectTerminalScenarioPass': 'true',
          'allNativeLanesPass': 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{'sampleRate': 48000, 'baseGain': 0.5},
      };

      final report = VGRealtimePlaybackSinkFaultToleranceSmokeReport.fromMap(
        raw,
      );
      expect(report.pass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.audioTrackInitOk, isTrue);
      expect(report.baseGainSetOk, isTrue);
      expect(report.metrics['sampleRate'], equals(48000));
      expect(report.metrics['baseGain'], equals(0.5));
    });

    test('nested lane and metric maps are preserved', () {
      final sample = _createSampleRawMap();
      final report = VGRealtimePlaybackSinkFaultToleranceSmokeReport.fromMap(
        sample,
      );

      expect(report.metrics['eosLanes'], isA<Map>());
      expect(report.metrics['disconnectMetrics'], isA<Map>());
      expect(report.lanes['audioTrackInitOk'], isTrue);

      final map = report.toMap();
      expect(map['lanes'], isA<Map>());
      expect(map['metrics'], isA<Map>());
      expect(report.toJson(), equals(map));
    });

    test('toString produces diagnostic representation', () {
      final report = _createSampleReport();
      expect(
        report.toString(),
        contains('VGRealtimePlaybackSinkFaultToleranceSmokeReport'),
      );
      expect(report.toString(), contains('audioTrackInitOk: true'));
      expect(report.toString(), contains('isVerifiedPass: true'));
    });
  });

  group('VGRealtimePlaybackSinkFaultToleranceSmokeReport MethodChannel invocation', () {
    test('method route invoked exactly and returns pass report', () async {
      String? invokedMethod;
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        invokedMethod = call.method;
        if (call.method == 'runRealtimePlaybackSinkFaultToleranceSmoke') {
          return _createSampleRawMap();
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackSinkFaultToleranceSmokeReport.runRealtimePlaybackSinkFaultToleranceSmoke();

      expect(
        invokedMethod,
        equals('runRealtimePlaybackSinkFaultToleranceSmoke'),
      );
      expect(report.pass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.hasPassMarker, isTrue);
    });

    test('PlatformException produces harness exception report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'runRealtimePlaybackSinkFaultToleranceSmoke') {
          throw PlatformException(
            code: 'P4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_BUSY',
            message: 'Diagnostic already running',
          );
        }
        return null;
      });

      final report =
          await VGRealtimePlaybackSinkFaultToleranceSmokeReport.runRealtimePlaybackSinkFaultToleranceSmoke();

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_BUSY',
        ),
      );
      expect(
        report.lastError,
        contains(
          'platform_exception:P4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_BUSY:Diagnostic already running',
        ),
      );
    });

    test('TimeoutException produces fallback error report', () async {
      final customChannel = const MethodChannel(
        'vanguard_media_engine_sink_fault_tolerance_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });

      final report =
          await VGRealtimePlaybackSinkFaultToleranceSmokeReport.runRealtimePlaybackSinkFaultToleranceSmoke(
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
