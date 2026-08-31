// vg_node_owned_sink_clocked_transport_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-NODE-OWNED-SINK-CLOCKED-TRANSPORT: Android True-DAG Phase 4
// node-owned AudioTrack sink-clocked transport Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_node_owned_sink_clocked_transport_smoke.dart';

const _kCanonicalProofBoundary =
    'kotlin_owned_android_audiotrack_node_owned_source_sink_clocked_transport_diagnostic_proof_only_real_decoder_to_node_owned_decoded_audio_source_graph_pipeline_output_ring_to_audiotrack_write_accounting_sink_clocked_timebase_audio_timestamp_conditional_playback_head_fallback_system_nanotime_anchor_kotlin_only_no_cpp_wall_clock_read_no_native_audio_sink_no_aaudio_no_opensl_no_oboe_no_audible_output_claim_no_speaker_route_verification_no_audio_quality_claim_no_glitch_freedom_no_latency_budget_no_realtime_av_sync_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_dead_object_recovery_no_offload_no_low_latency_mode_no_production_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_streaming_no_cache_no_ios_single_routed_track_unit_gain_only_no_resample_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_single_kotlin_worker_thread_all_jni_and_audiotrack_calls_no_jni_reverse_callbacks_no_native_worker_threads_jni_session_registry_mutex_lifecycle_only_no_locks_in_vanguard_audio_primitives_direct_bytebuffer_reused_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_NODE_OWNED_SINK_CLOCKED_TRANSPORT_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_NODE_OWNED_SINK_CLOCKED_TRANSPORT_SMOKE_FAIL';
const _kChecksumHex = '0000000012345678';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'formatProbeOk': true,
    'audioTrackInitOk': true,
    'mutedOutputOk': true,
    'nodeOwnedRouteDiscoveryOk': true,
    'nodeOwnsRingOk': true,
    'startAckOk': true,
    'sinkClockedDispatchOk': true,
    'timestampTelemetryOk': true,
    'playbackHeadMonotonicOk': true,
    'playbackHeadAdvancedOk': true,
    'sinkWriteAccountingOk': true,
    'checksumIdentityOk': true,
    'frameAccountingOk': true,
    'seekOk': true,
    'tailFlushOk': true,
    'steadyStateUnderrunFreeOk': true,
    'noProviderUnderrunOk': true,
    'noSilenceOk': true,
    'noForwardSkipOk': true,
    'noRewindRejectOk': true,
    'finalNotTerminalOk': true,
    'finalSeekAckClearOk': true,
    'zeroNativeSteadyStateAllocationOk': true,
    'cancellationPollingOk': true,
    'lifecycleOk': true,
    'canonical': true,
  };

  final metrics = <String, Object?>{
    'sampleRate': 48000,
    'channelCount': 2,
    'pcmEncoding': 2,
    'expectedFrameCount': 480000,
    'totalFramesExtracted': 16384,
    'totalFramesAccepted': 16384,
    'totalOutputFramesDrained': 16384,
    'framesReadFromRingTotal': 16384,
    'framesWrittenTotal': 16384,
    'postSeekFramesAccepted': 12288,
    'postSeekFramesDrained': 12288,
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeOutputDrainChecksumHex': _kChecksumHex,
    'kotlinSinkChecksumHex': _kChecksumHex,
    'dispatchCount': 64,
    'maxFramesPerMix': 256,
    'sourceAvailableReadFrames': 0,
    'outputAvailableReadFrames': 0,
    'nextDispatchFrame': 16384,
    'bootstrapDispatchCount': 6,
    'sinkClockedDispatchCountEpoch0': 10,
    'sinkClockedDispatchCountEpoch1': 48,
    'prerollFrames': 1536,
    'targetLeadFrames': 2048,
    'bufferSizeInFrames': 3072,
    'bufferCapacityInFrames': 6144,
    'startThresholdFrames': 3072,
    'audioTimestampAttemptCount': 10,
    'audioTimestampSuccessCount': 10,
    'headSampleCount': 20,
    'playbackHeadFinal': 16384,
    'maxSinkLagFrames': 128,
    'maxDispatchLeadFrames': 2048,
    'minDispatchLeadFrames': 256,
    'underrunBaseline': 0,
    'underrunFinal': 0,
    'underrunDelta': 0,
    'zeroWriteCount': 0,
    'partialWriteCount': 0,
    'audioTrackReleaseCount': 1,
    'nativeDestroyCallCount': 2,
    'seekAcceptedFrame': 4096,
    'providerUnderrunEvents': 0,
    'providerFramesZeroFilled': 0,
    'providerForwardSkipFrames': 0,
    'providerRewindRejects': 0,
    'coordinatorSilenceCount': 0,
    'cancellationPollCount': 150,
  };

  final raw = <String, String>{
    'status': 'PASS',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'sampleRate=48000|channels=2|seekAcceptedFrame=4096',
    'formatProbeOk': 'true',
    'audioTrackInitOk': 'true',
    'mutedOutputOk': 'true',
    'nodeOwnedRouteDiscoveryOk': 'true',
    'nodeOwnsRingOk': 'true',
    'startAckOk': 'true',
    'sinkClockedDispatchOk': 'true',
    'timestampTelemetryOk': 'true',
    'playbackHeadMonotonicOk': 'true',
    'playbackHeadAdvancedOk': 'true',
    'sinkWriteAccountingOk': 'true',
    'checksumIdentityOk': 'true',
    'frameAccountingOk': 'true',
    'seekOk': 'true',
    'tailFlushOk': 'true',
    'steadyStateUnderrunFreeOk': 'true',
    'noProviderUnderrunOk': 'true',
    'noSilenceOk': 'true',
    'noForwardSkipOk': 'true',
    'noRewindRejectOk': 'true',
    'finalNotTerminalOk': 'true',
    'finalSeekAckClearOk': 'true',
    'zeroNativeSteadyStateAllocationOk': 'true',
    'cancellationPollingOk': 'true',
    'lifecycleOk': 'true',
    'canonical': 'true',
    'sampleRate': '48000',
    'channelCount': '2',
    'pcmEncoding': '2',
    'expectedFrameCount': '480000',
    'totalFramesExtracted': '16384',
    'totalFramesAccepted': '16384',
    'totalOutputFramesDrained': '16384',
    'framesReadFromRingTotal': '16384',
    'framesWrittenTotal': '16384',
    'postSeekFramesAccepted': '12288',
    'postSeekFramesDrained': '12288',
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeOutputDrainChecksumHex': _kChecksumHex,
    'kotlinSinkChecksumHex': _kChecksumHex,
    'dispatchCount': '64',
    'maxFramesPerMix': '256',
    'sourceAvailableReadFrames': '0',
    'outputAvailableReadFrames': '0',
    'nextDispatchFrame': '16384',
    'bootstrapDispatchCount': '6',
    'sinkClockedDispatchCountEpoch0': '10',
    'sinkClockedDispatchCountEpoch1': '48',
    'prerollFrames': '1536',
    'targetLeadFrames': '2048',
    'bufferSizeInFrames': '3072',
    'bufferCapacityInFrames': '6144',
    'startThresholdFrames': '3072',
    'audioTimestampAttemptCount': '10',
    'audioTimestampSuccessCount': '10',
    'headSampleCount': '20',
    'playbackHeadFinal': '16384',
    'maxSinkLagFrames': '128',
    'maxDispatchLeadFrames': '2048',
    'minDispatchLeadFrames': '256',
    'underrunBaseline': '0',
    'underrunFinal': '0',
    'underrunDelta': '0',
    'zeroWriteCount': '0',
    'partialWriteCount': '0',
    'audioTrackReleaseCount': '1',
    'nativeDestroyCallCount': '2',
    'seekAcceptedFrame': '4096',
    'providerUnderrunEvents': '0',
    'providerFramesZeroFilled': '0',
    'providerForwardSkipFrames': '0',
    'providerRewindRejects': '0',
    'coordinatorSilenceCount': '0',
    'cancellationPollCount': '150',
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'sampleRate=48000|channels=2|seekAcceptedFrame=4096',
    'lanes': lanes,
    'metrics': metrics,
    'raw': raw,
    'lastError': '',
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

VGNodeOwnedSinkClockedTransportSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGNodeOwnedSinkClockedTransportSmokeReport.fromMap(
  _createSampleRawMap(overrides),
);

class _ThrowingMethodChannel extends MethodChannel {
  const _ThrowingMethodChannel(super.name);

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) {
    throw const FormatException('simulated non-platform exception');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGNodeOwnedSinkClockedTransportSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGNodeOwnedSinkClockedTransportSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.pass, isTrue);
        expect(report.status, equals('pass'));
        expect(report.marker, equals(_kPassMarker));
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.failureReason, isEmpty);
        expect(report.lastError, isEmpty);
        expect(report.details, contains('sampleRate=48000'));

        // Lanes (26 hard lanes)
        expect(report.formatProbeOk, isTrue);
        expect(report.audioTrackInitOk, isTrue);
        expect(report.mutedOutputOk, isTrue);
        expect(report.nodeOwnedRouteDiscoveryOk, isTrue);
        expect(report.nodeOwnsRingOk, isTrue);
        expect(report.startAckOk, isTrue);
        expect(report.sinkClockedDispatchOk, isTrue);
        expect(report.timestampTelemetryOk, isTrue);
        expect(report.playbackHeadMonotonicOk, isTrue);
        expect(report.playbackHeadAdvancedOk, isTrue);
        expect(report.sinkWriteAccountingOk, isTrue);
        expect(report.checksumIdentityOk, isTrue);
        expect(report.frameAccountingOk, isTrue);
        expect(report.seekOk, isTrue);
        expect(report.tailFlushOk, isTrue);
        expect(report.steadyStateUnderrunFreeOk, isTrue);
        expect(report.noProviderUnderrunOk, isTrue);
        expect(report.noSilenceOk, isTrue);
        expect(report.noForwardSkipOk, isTrue);
        expect(report.noRewindRejectOk, isTrue);
        expect(report.finalNotTerminalOk, isTrue);
        expect(report.finalSeekAckClearOk, isTrue);
        expect(report.zeroNativeSteadyStateAllocationOk, isTrue);
        expect(report.cancellationPollingOk, isTrue);
        expect(report.lifecycleOk, isTrue);
        expect(report.canonical, isTrue);

        // Metrics (48 metrics)
        expect(report.sampleRate, equals(48000));
        expect(report.channelCount, equals(2));
        expect(report.pcmEncoding, equals(2));
        expect(report.expectedFrameCount, equals(480000));
        expect(report.totalFramesExtracted, equals(16384));
        expect(report.totalFramesAccepted, equals(16384));
        expect(report.totalOutputFramesDrained, equals(16384));
        expect(report.framesReadFromRingTotal, equals(16384));
        expect(report.framesWrittenTotal, equals(16384));
        expect(report.postSeekFramesAccepted, equals(12288));
        expect(report.postSeekFramesDrained, equals(12288));
        expect(report.nativeAcceptedChecksumHex, equals(_kChecksumHex));
        expect(report.nativeOutputDrainChecksumHex, equals(_kChecksumHex));
        expect(report.kotlinSinkChecksumHex, equals(_kChecksumHex));
        expect(report.dispatchCount, equals(64));
        expect(report.maxFramesPerMix, equals(256));
        expect(report.sourceAvailableReadFrames, equals(0));
        expect(report.outputAvailableReadFrames, equals(0));
        expect(report.nextDispatchFrame, equals(16384));
        expect(report.bootstrapDispatchCount, equals(6));
        expect(report.sinkClockedDispatchCountEpoch0, equals(10));
        expect(report.sinkClockedDispatchCountEpoch1, equals(48));
        expect(report.prerollFrames, equals(1536));
        expect(report.targetLeadFrames, equals(2048));
        expect(report.bufferSizeInFrames, equals(3072));
        expect(report.bufferCapacityInFrames, equals(6144));
        expect(report.startThresholdFrames, equals(3072));
        expect(report.audioTimestampAttemptCount, equals(10));
        expect(report.audioTimestampSuccessCount, equals(10));
        expect(report.headSampleCount, equals(20));
        expect(report.playbackHeadFinal, equals(16384));
        expect(report.maxSinkLagFrames, equals(128));
        expect(report.maxDispatchLeadFrames, equals(2048));
        expect(report.minDispatchLeadFrames, equals(256));
        expect(report.underrunBaseline, equals(0));
        expect(report.underrunFinal, equals(0));
        expect(report.underrunDelta, equals(0));
        expect(report.zeroWriteCount, equals(0));
        expect(report.partialWriteCount, equals(0));
        expect(report.audioTrackReleaseCount, equals(1));
        expect(report.nativeDestroyCallCount, equals(2));
        expect(report.seekAcceptedFrame, equals(4096));
        expect(report.providerUnderrunEvents, equals(0));
        expect(report.providerFramesZeroFilled, equals(0));
        expect(report.providerForwardSkipFrames, equals(0));
        expect(report.providerRewindRejects, equals(0));
        expect(report.coordinatorSilenceCount, equals(0));
        expect(report.cancellationPollCount, equals(150));

        // Getters
        expect(report.checksumsMatch, isTrue);
        expect(report.sinkFramesAccounted, isTrue);
        expect(report.allNativeLanesPass, isTrue);

        // Serialization
        final serialized = report.toMap();
        expect(serialized['pass'], isTrue);
        expect(serialized['status'], equals('pass'));
        expect(serialized['marker'], equals(_kPassMarker));
        expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
        expect(serialized['lastError'], equals(''));
        expect(serialized['lanes'], equals(report.lanes));
        expect(serialized['metrics'], equals(report.metrics));
        expect(serialized['raw'], equals(report.raw));

        final roundTrip = VGNodeOwnedSinkClockedTransportSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGNodeOwnedSinkClockedTransportSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'status': 'steady_state_underrun_observed',
          'marker': _kFailMarker,
          'failureReason': 'steady_state_underrun_observed',
          'lastError': 'steady_state_underrun_observed',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.status, equals('steady_state_underrun_observed'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('steady_state_underrun_observed'));
      expect(report.lastError, equals('steady_state_underrun_observed'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [
        null,
        'not_a_map',
        12345,
        3.14,
        <Object?>['a', 'b'],
      ]) {
        final report = VGNodeOwnedSinkClockedTransportSmokeReport.fromMap(
          invalid,
        );
        expect(report.pass, isFalse);
        expect(report.hasCanonicalProofBoundary, isFalse);
        expect(report.proofBoundary, isEmpty);
        expect(report.status, equals('fail'));
        expect(report.marker, equals(_kFailMarker));
        expect(
          report.raw,
          equals(const <String, String>{'reason': 'native_result_not_a_map'}),
        );
        expect(report.lastError, equals('native_result_not_a_map'));
        expect(report.allNativeLanesPass, isFalse);
        expect(report.totalFramesAccepted, equals(0));
        expect(report.totalOutputFramesDrained, equals(0));
        expect(report.framesReadFromRingTotal, equals(0));
        expect(report.framesWrittenTotal, equals(0));
        expect(report.sourceAvailableReadFrames, equals(-1));
        expect(report.outputAvailableReadFrames, equals(-1));
        expect(report.nextDispatchFrame, equals(-1));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw = VGNodeOwnedSinkClockedTransportSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'marker=$_kPassMarker;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'formatProbeOk=true;'
            'audioTrackInitOk=true;'
            'mutedOutputOk=true;'
            'nodeOwnedRouteDiscoveryOk=true;'
            'nodeOwnsRingOk=true;'
            'startAckOk=true;'
            'sinkClockedDispatchOk=true;'
            'timestampTelemetryOk=true;'
            'playbackHeadMonotonicOk=true;'
            'playbackHeadAdvancedOk=true;'
            'sinkWriteAccountingOk=true;'
            'checksumIdentityOk=true;'
            'frameAccountingOk=true;'
            'seekOk=true;'
            'tailFlushOk=true;'
            'steadyStateUnderrunFreeOk=true;'
            'noProviderUnderrunOk=true;'
            'noSilenceOk=true;'
            'noForwardSkipOk=true;'
            'noRewindRejectOk=true;'
            'finalNotTerminalOk=true;'
            'finalSeekAckClearOk=true;'
            'zeroNativeSteadyStateAllocationOk=true;'
            'cancellationPollingOk=true;'
            'lifecycleOk=true;'
            'canonical=true;'
            'sampleRate=48000;'
            'channelCount=2;'
            'pcmEncoding=2;'
            'expectedFrameCount=480000;'
            'totalFramesExtracted=16384;'
            'totalFramesAccepted=16384;'
            'totalOutputFramesDrained=16384;'
            'framesReadFromRingTotal=16384;'
            'framesWrittenTotal=16384;'
            'postSeekFramesAccepted=12288;'
            'postSeekFramesDrained=12288;'
            'nativeAcceptedChecksumHex=$_kChecksumHex;'
            'nativeOutputDrainChecksumHex=$_kChecksumHex;'
            'kotlinSinkChecksumHex=$_kChecksumHex;'
            'dispatchCount=64;'
            'maxFramesPerMix=256;'
            'sourceAvailableReadFrames=0;'
            'outputAvailableReadFrames=0;'
            'nextDispatchFrame=16384;'
            'bootstrapDispatchCount=6;'
            'sinkClockedDispatchCountEpoch0=10;'
            'sinkClockedDispatchCountEpoch1=48;'
            'prerollFrames=1536;'
            'targetLeadFrames=2048;'
            'bufferSizeInFrames=3072;'
            'bufferCapacityInFrames=6144;'
            'startThresholdFrames=3072;'
            'audioTimestampAttemptCount=10;'
            'audioTimestampSuccessCount=10;'
            'headSampleCount=20;'
            'playbackHeadFinal=16384;'
            'maxSinkLagFrames=128;'
            'maxDispatchLeadFrames=2048;'
            'minDispatchLeadFrames=256;'
            'underrunBaseline=0;'
            'underrunFinal=0;'
            'underrunDelta=0;'
            'zeroWriteCount=0;'
            'partialWriteCount=0;'
            'audioTrackReleaseCount=1;'
            'nativeDestroyCallCount=2;'
            'seekAcceptedFrame=4096;'
            'providerUnderrunEvents=0;'
            'providerFramesZeroFilled=0;'
            'providerForwardSkipFrames=0;'
            'providerRewindRejects=0;'
            'coordinatorSilenceCount=0;'
            'cancellationPollCount=150',
        'lanes': const <String, Object?>{},
        'metrics': const <String, Object?>{},
      });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.formatProbeOk, isTrue);
      expect(reportFromRaw.audioTrackInitOk, isTrue);
      expect(reportFromRaw.mutedOutputOk, isTrue);
      expect(reportFromRaw.nodeOwnedRouteDiscoveryOk, isTrue);
      expect(reportFromRaw.nodeOwnsRingOk, isTrue);
      expect(reportFromRaw.startAckOk, isTrue);
      expect(reportFromRaw.sinkClockedDispatchOk, isTrue);
      expect(reportFromRaw.timestampTelemetryOk, isTrue);
      expect(reportFromRaw.playbackHeadMonotonicOk, isTrue);
      expect(reportFromRaw.playbackHeadAdvancedOk, isTrue);
      expect(reportFromRaw.sinkWriteAccountingOk, isTrue);
      expect(reportFromRaw.checksumIdentityOk, isTrue);
      expect(reportFromRaw.frameAccountingOk, isTrue);
      expect(reportFromRaw.seekOk, isTrue);
      expect(reportFromRaw.tailFlushOk, isTrue);
      expect(reportFromRaw.steadyStateUnderrunFreeOk, isTrue);
      expect(reportFromRaw.noProviderUnderrunOk, isTrue);
      expect(reportFromRaw.noSilenceOk, isTrue);
      expect(reportFromRaw.noForwardSkipOk, isTrue);
      expect(reportFromRaw.noRewindRejectOk, isTrue);
      expect(reportFromRaw.finalNotTerminalOk, isTrue);
      expect(reportFromRaw.finalSeekAckClearOk, isTrue);
      expect(reportFromRaw.zeroNativeSteadyStateAllocationOk, isTrue);
      expect(reportFromRaw.cancellationPollingOk, isTrue);
      expect(reportFromRaw.lifecycleOk, isTrue);
      expect(reportFromRaw.canonical, isTrue);
      expect(reportFromRaw.sampleRate, equals(48000));
      expect(reportFromRaw.channelCount, equals(2));
      expect(reportFromRaw.pcmEncoding, equals(2));
      expect(reportFromRaw.expectedFrameCount, equals(480000));
      expect(reportFromRaw.totalFramesExtracted, equals(16384));
      expect(reportFromRaw.totalFramesAccepted, equals(16384));
      expect(reportFromRaw.totalOutputFramesDrained, equals(16384));
      expect(reportFromRaw.framesReadFromRingTotal, equals(16384));
      expect(reportFromRaw.framesWrittenTotal, equals(16384));
      expect(reportFromRaw.postSeekFramesAccepted, equals(12288));
      expect(reportFromRaw.postSeekFramesDrained, equals(12288));
      expect(reportFromRaw.bootstrapDispatchCount, equals(6));
      expect(reportFromRaw.sinkClockedDispatchCountEpoch0, equals(10));
      expect(reportFromRaw.sinkClockedDispatchCountEpoch1, equals(48));
      expect(reportFromRaw.prerollFrames, equals(1536));
      expect(reportFromRaw.targetLeadFrames, equals(2048));
      expect(reportFromRaw.bufferSizeInFrames, equals(3072));
      expect(reportFromRaw.bufferCapacityInFrames, equals(6144));
      expect(reportFromRaw.startThresholdFrames, equals(3072));
      expect(reportFromRaw.audioTimestampAttemptCount, equals(10));
      expect(reportFromRaw.audioTimestampSuccessCount, equals(10));
      expect(reportFromRaw.headSampleCount, equals(20));
      expect(reportFromRaw.playbackHeadFinal, equals(16384));
      expect(reportFromRaw.underrunDelta, equals(0));
      expect(reportFromRaw.audioTrackReleaseCount, equals(1));
      expect(reportFromRaw.nativeDestroyCallCount, equals(2));
      expect(reportFromRaw.providerUnderrunEvents, equals(0));
      expect(reportFromRaw.providerFramesZeroFilled, equals(0));
      expect(reportFromRaw.providerForwardSkipFrames, equals(0));
      expect(reportFromRaw.providerRewindRejects, equals(0));
      expect(reportFromRaw.coordinatorSilenceCount, equals(0));
      expect(reportFromRaw.cancellationPollCount, equals(150));
      expect(reportFromRaw.dispatchCount, equals(64));
      expect(reportFromRaw.nativeAcceptedChecksumHex, equals(_kChecksumHex));
      expect(reportFromRaw.nativeOutputDrainChecksumHex, equals(_kChecksumHex));
      expect(reportFromRaw.kotlinSinkChecksumHex, equals(_kChecksumHex));
      expect(reportFromRaw.maxFramesPerMix, equals(256));
      expect(reportFromRaw.sourceAvailableReadFrames, equals(0));
      expect(reportFromRaw.outputAvailableReadFrames, equals(0));
      expect(reportFromRaw.nextDispatchFrame, equals(16384));
      expect(reportFromRaw.checksumsMatch, isTrue);
      expect(reportFromRaw.sinkFramesAccounted, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in lanes and metrics', () {
      final report = VGNodeOwnedSinkClockedTransportSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'lanes': const <String, Object?>{
          'formatProbeOk': 'true',
          'audioTrackInitOk': 'pass',
          'mutedOutputOk': 'ok',
          'nodeOwnedRouteDiscoveryOk': 'success',
          'checksumIdentityOk': 'false',
        },
      });

      expect(report.formatProbeOk, isTrue);
      expect(report.audioTrackInitOk, isTrue);
      expect(report.mutedOutputOk, isTrue);
      expect(report.nodeOwnedRouteDiscoveryOk, isTrue);
      expect(report.checksumIdentityOk, isFalse);
    });

    test('nested lane and metric precedence over top-level or raw fields', () {
      final report = VGNodeOwnedSinkClockedTransportSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'formatProbeOk': false,
        'sampleRate': 22050,
        'lanes': const <String, Object?>{'formatProbeOk': true},
        'metrics': const <String, Object?>{'sampleRate': 48000},
        'raw': const <String, String>{
          'formatProbeOk': 'false',
          'sampleRate': '44100',
        },
      });

      expect(report.formatProbeOk, isTrue);
      expect(report.sampleRate, equals(48000));
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

  group('Getters and Lane Verifications', () {
    test('checksumsMatch verifies 3-way non-empty identity and lane ok', () {
      final report = _createSampleReport();
      expect(report.checksumsMatch, isTrue);

      expect(
        _createSampleReport({'kotlinSinkChecksumHex': ''}).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'nativeAcceptedChecksumHex': 'mismatch',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'nativeOutputDrainChecksumHex': 'mismatch',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({'checksumIdentityOk': false}).checksumsMatch,
        isFalse,
      );
    });

    test('sinkFramesAccounted verifies strict 4-way equality and lanes ok', () {
      final report = _createSampleReport();
      expect(report.sinkFramesAccounted, isTrue);

      expect(
        _createSampleReport({
          'totalFramesAccepted': 16384,
          'totalOutputFramesDrained': 16000,
        }).sinkFramesAccounted,
        isFalse,
      );
      expect(
        _createSampleReport({
          'totalFramesAccepted': 16384,
          'framesReadFromRingTotal': 16000,
        }).sinkFramesAccounted,
        isFalse,
      );
      expect(
        _createSampleReport({
          'totalFramesAccepted': 16384,
          'framesWrittenTotal': 16000,
        }).sinkFramesAccounted,
        isFalse,
      );
      expect(
        _createSampleReport({'totalFramesAccepted': 0}).sinkFramesAccounted,
        isFalse,
      );
      expect(
        _createSampleReport({
          'sinkWriteAccountingOk': false,
        }).sinkFramesAccounted,
        isFalse,
      );
      expect(
        _createSampleReport({'frameAccountingOk': false}).sinkFramesAccounted,
        isFalse,
      );
    });

    test('allNativeLanesPass requires all conditions to hold', () {
      expect(_createSampleReport().allNativeLanesPass, isTrue);

      // Status / marker / pass / proof boundary
      expect(_createSampleReport({'pass': false}).allNativeLanesPass, isFalse);
      expect(
        _createSampleReport({'status': 'fail'}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'marker': _kFailMarker}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'proofBoundary': 'invalid'}).allNativeLanesPass,
        isFalse,
      );

      // Hard lanes that must be true
      expect(
        _createSampleReport({'formatProbeOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'audioTrackInitOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'mutedOutputOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'nodeOwnedRouteDiscoveryOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'nodeOwnsRingOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'startAckOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'sinkClockedDispatchOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'timestampTelemetryOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'playbackHeadMonotonicOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'playbackHeadAdvancedOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'sinkWriteAccountingOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'checksumIdentityOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'frameAccountingOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'seekOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'tailFlushOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'steadyStateUnderrunFreeOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'noProviderUnderrunOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'noSilenceOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'noForwardSkipOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'noRewindRejectOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'finalNotTerminalOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'finalSeekAckClearOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'zeroNativeSteadyStateAllocationOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'cancellationPollingOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'lifecycleOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'canonical': false}).allNativeLanesPass,
        isFalse,
      );

      // Positive metrics
      expect(
        _createSampleReport({'sampleRate': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'channelCount': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'expectedFrameCount': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'totalFramesAccepted': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'totalOutputFramesDrained': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'framesReadFromRingTotal': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'framesWrittenTotal': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'postSeekFramesAccepted': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'postSeekFramesDrained': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'dispatchCount': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'maxFramesPerMix': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'playbackHeadFinal': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'sinkClockedDispatchCountEpoch0': 0,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'sinkClockedDispatchCountEpoch1': 0,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'audioTrackReleaseCount': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'audioTrackReleaseCount': 2}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'nativeDestroyCallCount': 1}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'cancellationPollCount': 0}).allNativeLanesPass,
        isFalse,
      );

      // Frame accounting lockstep
      expect(
        _createSampleReport({
          'totalFramesAccepted': 16384,
          'totalOutputFramesDrained': 16000,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'totalFramesAccepted': 16384,
          'framesReadFromRingTotal': 16000,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'totalFramesAccepted': 16384,
          'framesWrittenTotal': 16000,
        }).allNativeLanesPass,
        isFalse,
      );

      // Device AudioTrack.underrunCount delta is telemetry only and not a hard PASS gate
      expect(
        _createSampleReport({
          'underrunBaseline': 0,
          'underrunFinal': 15,
          'underrunDelta': 15,
        }).allNativeLanesPass,
        isTrue,
      );

      // Zero-count integrity metrics
      expect(
        _createSampleReport({'providerUnderrunEvents': 1}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'providerFramesZeroFilled': 1}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'providerForwardSkipFrames': 1,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'providerRewindRejects': 1}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'coordinatorSilenceCount': 1}).allNativeLanesPass,
        isFalse,
      );

      // Available read frames must be 0
      expect(
        _createSampleReport({
          'sourceAvailableReadFrames': 5,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'outputAvailableReadFrames': 5,
        }).allNativeLanesPass,
        isFalse,
      );

      // Error strings
      expect(
        _createSampleReport({'lastError': 'some_error'}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'lastError': 'none'}).allNativeLanesPass,
        isTrue,
      );
      expect(
        _createSampleReport({'lastError': 'null'}).allNativeLanesPass,
        isTrue,
      );
    });

    test(
      'Fable correction 2: underrunDelta is honest telemetry only and steadyStateUnderrunFreeOk is a hard gate',
      () {
        // Report with underrunDelta > 0 (e.g. 15 on physical SM-A566B) still passes when all hard lanes are true
        final reportWithTelemetryUnderrun = _createSampleReport({
          'underrunBaseline': 0,
          'underrunFinal': 15,
          'underrunDelta': 15,
          'steadyStateUnderrunFreeOk': true,
          'noProviderUnderrunOk': true,
          'noSilenceOk': true,
        });
        expect(reportWithTelemetryUnderrun.underrunBaseline, equals(0));
        expect(reportWithTelemetryUnderrun.underrunFinal, equals(15));
        expect(reportWithTelemetryUnderrun.underrunDelta, equals(15));
        expect(reportWithTelemetryUnderrun.steadyStateUnderrunFreeOk, isTrue);
        expect(reportWithTelemetryUnderrun.noProviderUnderrunOk, isTrue);
        expect(reportWithTelemetryUnderrun.noSilenceOk, isTrue);
        expect(reportWithTelemetryUnderrun.allNativeLanesPass, isTrue);

        // Native steady state gate failure fails allNativeLanesPass even if underrunDelta == 0
        final reportWithSteadyStateFailure = _createSampleReport({
          'underrunBaseline': 0,
          'underrunFinal': 0,
          'underrunDelta': 0,
          'steadyStateUnderrunFreeOk': false,
        });
        expect(reportWithSteadyStateFailure.steadyStateUnderrunFreeOk, isFalse);
        expect(reportWithSteadyStateFailure.allNativeLanesPass, isFalse);

        // Native provider underrun failure fails allNativeLanesPass
        final reportWithProviderUnderrunFailure = _createSampleReport({
          'noProviderUnderrunOk': false,
        });
        expect(reportWithProviderUnderrunFailure.noProviderUnderrunOk, isFalse);
        expect(reportWithProviderUnderrunFailure.allNativeLanesPass, isFalse);

        // Coordinator silence failure fails allNativeLanesPass
        final reportWithSilenceFailure = _createSampleReport({
          'noSilenceOk': false,
        });
        expect(reportWithSilenceFailure.noSilenceOk, isFalse);
        expect(reportWithSilenceFailure.allNativeLanesPass, isFalse);
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
      expect(
        a.toString(),
        contains('VGNodeOwnedSinkClockedTransportSmokeReport('),
      );
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
        {'status': 'fail'},
        {'marker': _kFailMarker},
        {'proofBoundary': 'other_boundary'},
        {'failureReason': 'diff_reason'},
        {'details': 'diff_details'},
        {'formatProbeOk': false},
        {'audioTrackInitOk': false},
        {'mutedOutputOk': false},
        {'nodeOwnedRouteDiscoveryOk': false},
        {'nodeOwnsRingOk': false},
        {'startAckOk': false},
        {'sinkClockedDispatchOk': false},
        {'timestampTelemetryOk': false},
        {'playbackHeadMonotonicOk': false},
        {'playbackHeadAdvancedOk': false},
        {'sinkWriteAccountingOk': false},
        {'checksumIdentityOk': false},
        {'frameAccountingOk': false},
        {'seekOk': false},
        {'tailFlushOk': false},
        {'steadyStateUnderrunFreeOk': false},
        {'noProviderUnderrunOk': false},
        {'noSilenceOk': false},
        {'noForwardSkipOk': false},
        {'noRewindRejectOk': false},
        {'finalNotTerminalOk': false},
        {'finalSeekAckClearOk': false},
        {'zeroNativeSteadyStateAllocationOk': false},
        {'cancellationPollingOk': false},
        {'lifecycleOk': false},
        {'canonical': false},
        {'sampleRate': 44100},
        {'channelCount': 1},
        {'pcmEncoding': 1},
        {'expectedFrameCount': 99999},
        {'totalFramesExtracted': 999},
        {'totalFramesAccepted': 999},
        {'totalOutputFramesDrained': 999},
        {'framesReadFromRingTotal': 999},
        {'framesWrittenTotal': 999},
        {'postSeekFramesAccepted': 111},
        {'postSeekFramesDrained': 111},
        {'nativeAcceptedChecksumHex': 'diff'},
        {'nativeOutputDrainChecksumHex': 'diff'},
        {'kotlinSinkChecksumHex': 'diff'},
        {'dispatchCount': 100},
        {'maxFramesPerMix': 512},
        {'sourceAvailableReadFrames': 42},
        {'outputAvailableReadFrames': 42},
        {'nextDispatchFrame': 999},
        {'bootstrapDispatchCount': 12},
        {'sinkClockedDispatchCountEpoch0': 20},
        {'sinkClockedDispatchCountEpoch1': 96},
        {'prerollFrames': 3072},
        {'targetLeadFrames': 4096},
        {'bufferSizeInFrames': 9999},
        {'bufferCapacityInFrames': 9999},
        {'startThresholdFrames': 9999},
        {'audioTimestampAttemptCount': 50},
        {'audioTimestampSuccessCount': 50},
        {'headSampleCount': 50},
        {'playbackHeadFinal': 9999},
        {'maxSinkLagFrames': 999},
        {'maxDispatchLeadFrames': 999},
        {'minDispatchLeadFrames': 999},
        {'underrunBaseline': 10},
        {'underrunFinal': 10},
        {'underrunDelta': 5},
        {'zeroWriteCount': 2},
        {'partialWriteCount': 2},
        {'audioTrackReleaseCount': 2},
        {'nativeDestroyCallCount': 3},
        {'seekAcceptedFrame': 999},
        {'providerUnderrunEvents': 5},
        {'providerFramesZeroFilled': 5},
        {'providerForwardSkipFrames': 5},
        {'providerRewindRejects': 5},
        {'coordinatorSilenceCount': 5},
        {'cancellationPollCount': 500},
        {'lastError': 'some_error'},
        {
          'raw': const <String, String>{'custom': 'diff'},
        },
        {
          'lanes': const <String, Object?>{'custom': false},
        },
        {
          'metrics': const <String, Object?>{'custom': 123},
        },
      ];

      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group(
    'MethodChannel wrapper: runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke',
    () {
      test(
        'invokes runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke with correct default args on default channel',
        () async {
          MethodCall? capturedCall;
          binaryMessenger.setMockMethodCallHandler(defaultChannel, (
            call,
          ) async {
            capturedCall = call;
            return _createSampleRawMap();
          });

          final report =
              await VGNodeOwnedSinkClockedTransportSmokeReport.runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke(
                sourcePath: '/path/to/test/clip_B.mov',
              );

          expect(capturedCall, isNotNull);
          expect(
            capturedCall!.method,
            equals('runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke'),
          );
          expect(
            capturedCall!.arguments,
            equals(<String, Object?>{
              'sourcePath': '/path/to/test/clip_B.mov',
              'durationSec': 1.0,
              'seekTargetSec': 0.35,
              'sourceRingCapacityFrames': 8192,
              'outputRingCapacityFrames': 4096,
              'maxFramesPerMix': 256,
              'deadlineMs': 30000,
            }),
          );
          expect(report.pass, isTrue);
          expect(report.hasCanonicalProofBoundary, isTrue);
          expect(report.allNativeLanesPass, isTrue);
        },
      );

      test('invokes with custom args and timeout on custom channel', () async {
        MethodCall? capturedCall;
        const customChannel = MethodChannel(
          'custom_sink_clocked_transport_channel',
        );
        binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGNodeOwnedSinkClockedTransportSmokeReport.runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke(
              sourcePath: '/path/to/custom.mov',
              durationSec: 1.5,
              seekTargetSec: 0.5,
              sourceRingCapacityFrames: 16384,
              outputRingCapacityFrames: 8192,
              maxFramesPerMix: 128,
              timeout: const Duration(seconds: 20),
              channel: customChannel,
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke'),
        );
        expect(
          capturedCall!.arguments,
          equals(<String, Object?>{
            'sourcePath': '/path/to/custom.mov',
            'durationSec': 1.5,
            'seekTargetSec': 0.5,
            'sourceRingCapacityFrames': 16384,
            'outputRingCapacityFrames': 8192,
            'maxFramesPerMix': 128,
            'deadlineMs': 20000,
          }),
        );
        expect(report.pass, isTrue);
      });

      test(
        'PlatformException produces fail report with canonical proof boundary and fail marker',
        () async {
          binaryMessenger.setMockMethodCallHandler(defaultChannel, (
            call,
          ) async {
            throw PlatformException(
              code: 'P4_NODE_OWNED_SINK_CLOCKED_TRANSPORT_SMOKE_BUSY',
              message:
                  'runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke: busy',
            );
          });

          final report =
              await VGNodeOwnedSinkClockedTransportSmokeReport.runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke(
                sourcePath: '/path/to/test.mov',
              );

          expect(report.pass, isFalse);
          expect(report.hasCanonicalProofBoundary, isTrue);
          expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
          expect(report.marker, equals(_kFailMarker));
          expect(
            report.failureReason,
            equals(
              'platform_exception:P4_NODE_OWNED_SINK_CLOCKED_TRANSPORT_SMOKE_BUSY',
            ),
          );
          expect(
            report.lastError,
            contains('P4_NODE_OWNED_SINK_CLOCKED_TRANSPORT_SMOKE_BUSY'),
          );
          expect(report.allNativeLanesPass, isFalse);
        },
      );

      test(
        'TimeoutException produces fail report with canonical proof boundary and fail marker',
        () async {
          binaryMessenger.setMockMethodCallHandler(defaultChannel, (
            call,
          ) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return _createSampleRawMap();
          });

          final report =
              await VGNodeOwnedSinkClockedTransportSmokeReport.runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke(
                sourcePath: '/path/to/test.mov',
                timeout: const Duration(milliseconds: 10),
              );

          expect(report.pass, isFalse);
          expect(report.hasCanonicalProofBoundary, isTrue);
          expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
          expect(report.marker, equals(_kFailMarker));
          expect(report.failureReason, equals('timeout'));
          expect(report.lastError, contains('timeout'));
          expect(report.allNativeLanesPass, isFalse);
        },
      );

      test(
        'generic exception produces fail report with canonical proof boundary and fail marker',
        () async {
          final report =
              await VGNodeOwnedSinkClockedTransportSmokeReport.runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke(
                sourcePath: '/path/to/test.mov',
                channel: const _ThrowingMethodChannel('test_throwing'),
              );

          expect(report.pass, isFalse);
          expect(report.hasCanonicalProofBoundary, isTrue);
          expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
          expect(report.marker, equals(_kFailMarker));
          expect(report.failureReason, startsWith('exception:'));
          expect(
            report.lastError,
            contains('simulated non-platform exception'),
          );
          expect(report.allNativeLanesPass, isFalse);
        },
      );
    },
  );
}
