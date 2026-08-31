// vg_aaudio_node_owned_sink_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-AAUDIO-NODE-OWNED-SINK-DIAGNOSTIC: Android True-DAG Phase 4
// two-source node-owned closed-loop native audio graph pipeline muted native AAudio callback sink
// Dart model and MethodChannel tests (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'native_android_aaudio_callback_sink_diagnostic_only_runtime_dlopen_no_direct_libaaudio_link_min_sdk24_safe_real_decoder_plus_synthetic_second_track_two_decoded_audio_source_nodes_own_ring_writer_provider_by_composition_scheduler_auto_discovery_from_graph_topology_muted_owner_thread_zero_scale_before_callback_ring_callback_pop_or_silence_only_no_product_no_editor_no_connects_app_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_audible_output_claim_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_low_latency_mmap_exclusive_no_xrun_freedom_no_latency_glitch_claim';

const _kPassMarker = 'ANDROID_DAG_PHASE4_AAUDIO_NODE_OWNED_SINK_SMOKE_PASS';
const _kFailMarker = 'ANDROID_DAG_PHASE4_AAUDIO_NODE_OWNED_SINK_SMOKE_FAIL';
const _kSource0Id = 'aaudio_node_owned_sink_src0';
const _kSource1Id = 'aaudio_node_owned_sink_src1';
const _kChecksum0Hex = '0000000011111111';
const _kChecksum1Hex = '0000000022222222';
const _kChecksumMixHex = '0000000033333333';
const _kMutedSinkChecksumHex = '0000000000000000';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'formatProbeOk': true,
    'aaudioRuntimeAvailableOk': true,
    'aaudioSymbolsResolvedOk': true,
    'aaudioStreamOpenOk': true,
    'aaudioConfigOk': true,
    'aaudioStartOk': true,
    'callbackObservedOk': true,
    'mutedOutputOk': true,
    'nodeOwnedRouteDiscoveryOk': true,
    'nodeOwnsRingTrack0Ok': true,
    'nodeOwnsRingTrack1Ok': true,
    'track0IngestOk': true,
    'track1SyntheticIngestOk': true,
    'trackFrameAxisLockstepOk': true,
    'jointDispatchGateOk': true,
    'graphOutputChecksumOk': true,
    'aaudioCallbackAccountingOk': true,
    'seekOk': true,
    'jointTailFlushOk': true,
    'noProviderUnderrunOk': true,
    'noGraphSilenceOk': true,
    'noRingPushShortfallOk': true,
    'zeroNativeSteadyStateAllocationOk': true,
    'ownerThreadOk': true,
    'lifecycleOk': true,
    'canonical': true,
  };

  final metrics = <String, Object?>{
    'sampleRate': 48000,
    'channelCount': 2,
    'pcmEncoding': 2,
    'commonBudgetFrames': 28800,
    'expectedFrameCount': 28800,
    'totalFramesExtracted': 28800,
    'framesTruncatedBeyondBudget': 0,
    'totalFramesAcceptedTrack0': 28800,
    'totalFramesAcceptedTrack1': 28800,
    'totalOutputFramesPumped': 28800,
    'totalMutedFramesPushed': 28800,
    'postSeekFramesAccepted': 16800,
    'seekAcceptedFrame': 12000,
    'seekSkippedDeadline': false,
    'track1NonZeroSampleCount': 57600,
    'decoderBenignFormatChangeCount': 1,
    'nativeAcceptedChecksumHexTrack0': _kChecksum0Hex,
    'nativeAcceptedChecksumHexTrack1': _kChecksum1Hex,
    'nativeOutputDrainChecksumHex': _kChecksumMixHex,
    'mutedSinkChecksumHex': _kMutedSinkChecksumHex,
    'kotlinAcceptedChecksumHexTrack0': _kChecksum0Hex,
    'kotlinAcceptedChecksumHexTrack1': _kChecksum1Hex,
    'kotlinReferenceMixChecksumHex': _kChecksumMixHex,
    'routedSourceId0': _kSource0Id,
    'routedSourceId1': _kSource1Id,
    'dispatchCount': 113,
    'nextDispatchFrame': 28800,
    'coordinatorSilenceCount': 0,
    'providerUnderrunEventsTrack0': 0,
    'providerUnderrunEventsTrack1': 0,
    'providerFramesZeroFilledTrack0': 0,
    'providerFramesZeroFilledTrack1': 0,
    'providerForwardSkipFramesTrack0': 0,
    'providerForwardSkipFramesTrack1': 0,
    'providerRewindRejectsTrack0': 0,
    'providerRewindRejectsTrack1': 0,
    'deviceApiLevel': 34,
    'streamSampleRate': 48000,
    'streamChannelCount': 2,
    'streamFormat': 1,
    'aaudioChannelCountSymbolFallback': false,
    'callbackInvocationCount': 120,
    'callbackFramesRequested': 28800,
    'callbackFramesServed': 28800,
    'callbackSilenceFrames': 0,
    'callbackShortReads': 0,
    'errorCallbackCount': 0,
    'finalCallbackCountersCoherent': true,
    'sinkFullWaitCount': 0,
    'sinkAvailableReadFramesFinal': 0,
    'cancellationPollCount': 250,
    'nativeLastStatus': 'ok',
    'maxFramesPerMix': 256,
  };

  final raw = <String, String>{
    'status': 'PASS',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'seekAcceptedFrame=12000|commonBudgetFrames=28800',
    'formatProbeOk': 'true',
    'aaudioRuntimeAvailableOk': 'true',
    'aaudioSymbolsResolvedOk': 'true',
    'aaudioStreamOpenOk': 'true',
    'aaudioConfigOk': 'true',
    'aaudioStartOk': 'true',
    'callbackObservedOk': 'true',
    'mutedOutputOk': 'true',
    'nodeOwnedRouteDiscoveryOk': 'true',
    'nodeOwnsRingTrack0Ok': 'true',
    'nodeOwnsRingTrack1Ok': 'true',
    'track0IngestOk': 'true',
    'track1SyntheticIngestOk': 'true',
    'trackFrameAxisLockstepOk': 'true',
    'jointDispatchGateOk': 'true',
    'graphOutputChecksumOk': 'true',
    'aaudioCallbackAccountingOk': 'true',
    'seekOk': 'true',
    'jointTailFlushOk': 'true',
    'noProviderUnderrunOk': 'true',
    'noGraphSilenceOk': 'true',
    'noRingPushShortfallOk': 'true',
    'zeroNativeSteadyStateAllocationOk': 'true',
    'ownerThreadOk': 'true',
    'lifecycleOk': 'true',
    'canonical': 'true',
    'sampleRate': '48000',
    'channelCount': '2',
    'pcmEncoding': '2',
    'commonBudgetFrames': '28800',
    'expectedFrameCount': '28800',
    'totalFramesExtracted': '28800',
    'framesTruncatedBeyondBudget': '0',
    'totalFramesAcceptedTrack0': '28800',
    'totalFramesAcceptedTrack1': '28800',
    'totalOutputFramesPumped': '28800',
    'totalMutedFramesPushed': '28800',
    'postSeekFramesAccepted': '16800',
    'seekAcceptedFrame': '12000',
    'seekSkippedDeadline': 'false',
    'track1NonZeroSampleCount': '57600',
    'decoderBenignFormatChangeCount': '1',
    'nativeAcceptedChecksumHexTrack0': _kChecksum0Hex,
    'nativeAcceptedChecksumHexTrack1': _kChecksum1Hex,
    'nativeOutputDrainChecksumHex': _kChecksumMixHex,
    'mutedSinkChecksumHex': _kMutedSinkChecksumHex,
    'kotlinAcceptedChecksumHexTrack0': _kChecksum0Hex,
    'kotlinAcceptedChecksumHexTrack1': _kChecksum1Hex,
    'kotlinReferenceMixChecksumHex': _kChecksumMixHex,
    'routedSourceId0': _kSource0Id,
    'routedSourceId1': _kSource1Id,
    'dispatchCount': '113',
    'nextDispatchFrame': '28800',
    'coordinatorSilenceCount': '0',
    'providerUnderrunEventsTrack0': '0',
    'providerUnderrunEventsTrack1': '0',
    'providerFramesZeroFilledTrack0': '0',
    'providerFramesZeroFilledTrack1': '0',
    'providerForwardSkipFramesTrack0': '0',
    'providerForwardSkipFramesTrack1': '0',
    'providerRewindRejectsTrack0': '0',
    'providerRewindRejectsTrack1': '0',
    'deviceApiLevel': '34',
    'streamSampleRate': '48000',
    'streamChannelCount': '2',
    'streamFormat': '1',
    'aaudioChannelCountSymbolFallback': 'false',
    'callbackInvocationCount': '120',
    'callbackFramesRequested': '28800',
    'callbackFramesServed': '28800',
    'callbackSilenceFrames': '0',
    'callbackShortReads': '0',
    'errorCallbackCount': '0',
    'finalCallbackCountersCoherent': 'true',
    'sinkFullWaitCount': '0',
    'sinkAvailableReadFramesFinal': '0',
    'cancellationPollCount': '250',
    'nativeLastStatus': 'ok',
    'maxFramesPerMix': '256',
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'seekAcceptedFrame=12000|commonBudgetFrames=28800',
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

VGAaudioNodeOwnedSinkSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGAaudioNodeOwnedSinkSmokeReport.fromMap(_createSampleRawMap(overrides));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGAaudioNodeOwnedSinkSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGAaudioNodeOwnedSinkSmokeReport.methodName,
        equals('runAndroidDagPhase4AaudioNodeOwnedSinkSmoke'),
      );
      expect(
        VGAaudioNodeOwnedSinkSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGAaudioNodeOwnedSinkSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGAaudioNodeOwnedSinkSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGAaudioNodeOwnedSinkSmokeReport.expectedSource0NodeId,
        equals(_kSource0Id),
      );
      expect(
        VGAaudioNodeOwnedSinkSmokeReport.expectedSource1NodeId,
        equals(_kSource1Id),
      );
    });
  });

  group('VGAaudioNodeOwnedSinkSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGAaudioNodeOwnedSinkSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.pass, isTrue);
        expect(report.status, equals('pass'));
        expect(report.marker, equals(_kPassMarker));
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.hasPassMarker, isTrue);
        expect(report.hasFailMarker, isFalse);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.failureReason, isEmpty);
        expect(report.lastError, isEmpty);
        expect(report.details, contains('seekAcceptedFrame=12000'));

        // Lanes (26 lanes)
        expect(report.formatProbeOk, isTrue);
        expect(report.aaudioRuntimeAvailableOk, isTrue);
        expect(report.aaudioSymbolsResolvedOk, isTrue);
        expect(report.aaudioStreamOpenOk, isTrue);
        expect(report.aaudioConfigOk, isTrue);
        expect(report.aaudioStartOk, isTrue);
        expect(report.callbackObservedOk, isTrue);
        expect(report.mutedOutputOk, isTrue);
        expect(report.nodeOwnedRouteDiscoveryOk, isTrue);
        expect(report.nodeOwnsRingTrack0Ok, isTrue);
        expect(report.nodeOwnsRingTrack1Ok, isTrue);
        expect(report.track0IngestOk, isTrue);
        expect(report.track1SyntheticIngestOk, isTrue);
        expect(report.trackFrameAxisLockstepOk, isTrue);
        expect(report.jointDispatchGateOk, isTrue);
        expect(report.graphOutputChecksumOk, isTrue);
        expect(report.aaudioCallbackAccountingOk, isTrue);
        expect(report.seekOk, isTrue);
        expect(report.jointTailFlushOk, isTrue);
        expect(report.noProviderUnderrunOk, isTrue);
        expect(report.noGraphSilenceOk, isTrue);
        expect(report.noRingPushShortfallOk, isTrue);
        expect(report.zeroNativeSteadyStateAllocationOk, isTrue);
        expect(report.ownerThreadOk, isTrue);
        expect(report.lifecycleOk, isTrue);
        expect(report.canonical, isTrue);

        // Metrics (46 metrics)
        expect(report.sampleRate, equals(48000));
        expect(report.channelCount, equals(2));
        expect(report.pcmEncoding, equals(2));
        expect(report.commonBudgetFrames, equals(28800));
        expect(report.expectedFrameCount, equals(28800));
        expect(report.totalFramesExtracted, equals(28800));
        expect(report.framesTruncatedBeyondBudget, equals(0));
        expect(report.totalFramesAcceptedTrack0, equals(28800));
        expect(report.totalFramesAcceptedTrack1, equals(28800));
        expect(report.totalOutputFramesPumped, equals(28800));
        expect(report.totalMutedFramesPushed, equals(28800));
        expect(report.postSeekFramesAccepted, equals(16800));
        expect(report.seekAcceptedFrame, equals(12000));
        expect(report.seekSkippedDeadline, isFalse);
        expect(report.track1NonZeroSampleCount, equals(57600));
        expect(report.decoderBenignFormatChangeCount, equals(1));
        expect(report.nativeAcceptedChecksumHexTrack0, equals(_kChecksum0Hex));
        expect(report.nativeAcceptedChecksumHexTrack1, equals(_kChecksum1Hex));
        expect(report.nativeOutputDrainChecksumHex, equals(_kChecksumMixHex));
        expect(report.mutedSinkChecksumHex, equals(_kMutedSinkChecksumHex));
        expect(report.kotlinAcceptedChecksumHexTrack0, equals(_kChecksum0Hex));
        expect(report.kotlinAcceptedChecksumHexTrack1, equals(_kChecksum1Hex));
        expect(report.kotlinReferenceMixChecksumHex, equals(_kChecksumMixHex));
        expect(report.routedSourceId0, equals(_kSource0Id));
        expect(report.routedSourceId1, equals(_kSource1Id));
        expect(report.dispatchCount, equals(113));
        expect(report.nextDispatchFrame, equals(28800));
        expect(report.coordinatorSilenceCount, equals(0));
        expect(report.providerUnderrunEventsTrack0, equals(0));
        expect(report.providerUnderrunEventsTrack1, equals(0));
        expect(report.providerFramesZeroFilledTrack0, equals(0));
        expect(report.providerFramesZeroFilledTrack1, equals(0));
        expect(report.providerForwardSkipFramesTrack0, equals(0));
        expect(report.providerForwardSkipFramesTrack1, equals(0));
        expect(report.providerRewindRejectsTrack0, equals(0));
        expect(report.providerRewindRejectsTrack1, equals(0));
        expect(report.deviceApiLevel, equals(34));
        expect(report.streamSampleRate, equals(48000));
        expect(report.streamChannelCount, equals(2));
        expect(report.streamFormat, equals(1));
        expect(report.aaudioChannelCountSymbolFallback, isFalse);
        expect(report.callbackInvocationCount, equals(120));
        expect(report.callbackFramesRequested, equals(28800));
        expect(report.callbackFramesServed, equals(28800));
        expect(report.callbackSilenceFrames, equals(0));
        expect(report.callbackShortReads, equals(0));
        expect(report.errorCallbackCount, equals(0));
        expect(report.finalCallbackCountersCoherent, isTrue);
        expect(report.sinkFullWaitCount, equals(0));
        expect(report.sinkAvailableReadFramesFinal, equals(0));
        expect(report.cancellationPollCount, equals(250));
        expect(report.nativeLastStatus, equals('ok'));
        expect(report.maxFramesPerMix, equals(256));

        // Getters
        expect(report.checksumsMatch, isTrue);
        expect(report.mutedSinkIsZero, isTrue);
        expect(report.callbackAccountingCoherent, isTrue);
        expect(report.allNativeLanesPass, isTrue);

        // Serialization & round trip
        final serialized = report.toMap();
        expect(serialized['pass'], isTrue);
        expect(serialized['status'], equals('pass'));
        expect(serialized['marker'], equals(_kPassMarker));
        expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
        expect(serialized['lastError'], equals(''));
        expect(serialized['lanes'], equals(report.lanes));
        expect(serialized['metrics'], equals(report.metrics));
        expect(serialized['raw'], equals(report.raw));

        final roundTrip = VGAaudioNodeOwnedSinkSmokeReport.fromMap(serialized);
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAaudioNodeOwnedSinkSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'status': 'aaudio_unavailable',
          'marker': _kFailMarker,
          'failureReason': 'aaudio_unavailable',
          'lastError': 'aaudio_unavailable',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.status, equals('aaudio_unavailable'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.hasPassMarker, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.failureReason, equals('aaudio_unavailable'));
      expect(report.lastError, equals('aaudio_unavailable'));
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
        final report = VGAaudioNodeOwnedSinkSmokeReport.fromMap(invalid);
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
        expect(report.totalFramesAcceptedTrack0, equals(0));
        expect(report.totalFramesAcceptedTrack1, equals(0));
        expect(report.totalOutputFramesPumped, equals(0));
        expect(report.seekAcceptedFrame, equals(-1));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw = VGAaudioNodeOwnedSinkSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'marker=$_kPassMarker;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'formatProbeOk=true;'
            'aaudioRuntimeAvailableOk=true;'
            'aaudioSymbolsResolvedOk=true;'
            'aaudioStreamOpenOk=true;'
            'aaudioConfigOk=true;'
            'aaudioStartOk=true;'
            'callbackObservedOk=true;'
            'mutedOutputOk=true;'
            'nodeOwnedRouteDiscoveryOk=true;'
            'nodeOwnsRingTrack0Ok=true;'
            'nodeOwnsRingTrack1Ok=true;'
            'track0IngestOk=true;'
            'track1SyntheticIngestOk=true;'
            'trackFrameAxisLockstepOk=true;'
            'jointDispatchGateOk=true;'
            'graphOutputChecksumOk=true;'
            'aaudioCallbackAccountingOk=true;'
            'seekOk=true;'
            'jointTailFlushOk=true;'
            'noProviderUnderrunOk=true;'
            'noGraphSilenceOk=true;'
            'noRingPushShortfallOk=true;'
            'zeroNativeSteadyStateAllocationOk=true;'
            'ownerThreadOk=true;'
            'lifecycleOk=true;'
            'canonical=true;'
            'sampleRate=48000;'
            'channelCount=2;'
            'pcmEncoding=2;'
            'commonBudgetFrames=28800;'
            'expectedFrameCount=28800;'
            'totalFramesExtracted=28800;'
            'framesTruncatedBeyondBudget=0;'
            'totalFramesAcceptedTrack0=28800;'
            'totalFramesAcceptedTrack1=28800;'
            'totalOutputFramesPumped=28800;'
            'totalMutedFramesPushed=28800;'
            'postSeekFramesAccepted=16800;'
            'seekAcceptedFrame=12000;'
            'seekSkippedDeadline=false;'
            'track1NonZeroSampleCount=57600;'
            'decoderBenignFormatChangeCount=1;'
            'nativeAcceptedChecksumHexTrack0=$_kChecksum0Hex;'
            'nativeAcceptedChecksumHexTrack1=$_kChecksum1Hex;'
            'nativeOutputDrainChecksumHex=$_kChecksumMixHex;'
            'mutedSinkChecksumHex=$_kMutedSinkChecksumHex;'
            'kotlinAcceptedChecksumHexTrack0=$_kChecksum0Hex;'
            'kotlinAcceptedChecksumHexTrack1=$_kChecksum1Hex;'
            'kotlinReferenceMixChecksumHex=$_kChecksumMixHex;'
            'routedSourceId0=$_kSource0Id;'
            'routedSourceId1=$_kSource1Id;'
            'dispatchCount=113;'
            'nextDispatchFrame=28800;'
            'coordinatorSilenceCount=0;'
            'providerUnderrunEventsTrack0=0;'
            'providerUnderrunEventsTrack1=0;'
            'providerFramesZeroFilledTrack0=0;'
            'providerFramesZeroFilledTrack1=0;'
            'providerForwardSkipFramesTrack0=0;'
            'providerForwardSkipFramesTrack1=0;'
            'providerRewindRejectsTrack0=0;'
            'providerRewindRejectsTrack1=0;'
            'deviceApiLevel=34;'
            'streamSampleRate=48000;'
            'streamChannelCount=2;'
            'streamFormat=1;'
            'aaudioChannelCountSymbolFallback=false;'
            'callbackInvocationCount=120;'
            'callbackFramesRequested=28800;'
            'callbackFramesServed=28800;'
            'callbackSilenceFrames=0;'
            'callbackShortReads=0;'
            'errorCallbackCount=0;'
            'finalCallbackCountersCoherent=true;'
            'sinkFullWaitCount=0;'
            'sinkAvailableReadFramesFinal=0;'
            'cancellationPollCount=250;'
            'nativeLastStatus=ok;'
            'maxFramesPerMix=256',
        'lanes': const <String, Object?>{},
        'metrics': const <String, Object?>{},
      });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.formatProbeOk, isTrue);
      expect(reportFromRaw.aaudioRuntimeAvailableOk, isTrue);
      expect(reportFromRaw.aaudioSymbolsResolvedOk, isTrue);
      expect(reportFromRaw.aaudioStreamOpenOk, isTrue);
      expect(reportFromRaw.aaudioConfigOk, isTrue);
      expect(reportFromRaw.aaudioStartOk, isTrue);
      expect(reportFromRaw.callbackObservedOk, isTrue);
      expect(reportFromRaw.mutedOutputOk, isTrue);
      expect(reportFromRaw.nodeOwnedRouteDiscoveryOk, isTrue);
      expect(reportFromRaw.nodeOwnsRingTrack0Ok, isTrue);
      expect(reportFromRaw.nodeOwnsRingTrack1Ok, isTrue);
      expect(reportFromRaw.track0IngestOk, isTrue);
      expect(reportFromRaw.track1SyntheticIngestOk, isTrue);
      expect(reportFromRaw.trackFrameAxisLockstepOk, isTrue);
      expect(reportFromRaw.jointDispatchGateOk, isTrue);
      expect(reportFromRaw.graphOutputChecksumOk, isTrue);
      expect(reportFromRaw.aaudioCallbackAccountingOk, isTrue);
      expect(reportFromRaw.seekOk, isTrue);
      expect(reportFromRaw.jointTailFlushOk, isTrue);
      expect(reportFromRaw.noProviderUnderrunOk, isTrue);
      expect(reportFromRaw.noGraphSilenceOk, isTrue);
      expect(reportFromRaw.noRingPushShortfallOk, isTrue);
      expect(reportFromRaw.zeroNativeSteadyStateAllocationOk, isTrue);
      expect(reportFromRaw.ownerThreadOk, isTrue);
      expect(reportFromRaw.lifecycleOk, isTrue);
      expect(reportFromRaw.canonical, isTrue);
      expect(reportFromRaw.sampleRate, equals(48000));
      expect(reportFromRaw.channelCount, equals(2));
      expect(reportFromRaw.expectedFrameCount, equals(28800));
      expect(reportFromRaw.routedSourceId0, equals(_kSource0Id));
      expect(reportFromRaw.routedSourceId1, equals(_kSource1Id));
      expect(reportFromRaw.totalFramesAcceptedTrack0, equals(28800));
      expect(reportFromRaw.totalFramesAcceptedTrack1, equals(28800));
      expect(reportFromRaw.totalOutputFramesPumped, equals(28800));
      expect(reportFromRaw.checksumsMatch, isTrue);
      expect(reportFromRaw.mutedSinkIsZero, isTrue);
      expect(reportFromRaw.callbackAccountingCoherent, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in lanes and metrics', () {
      final report = VGAaudioNodeOwnedSinkSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'lanes': const <String, Object?>{
          'formatProbeOk': 'true',
          'aaudioRuntimeAvailableOk': 'pass',
          'aaudioSymbolsResolvedOk': 'true',
          'aaudioStreamOpenOk': 'ok',
          'aaudioConfigOk': 'success',
          'aaudioStartOk': 'true',
          'callbackObservedOk': 'ok',
          'mutedOutputOk': 'success',
          'noProviderUnderrunOk': 'false',
        },
      });

      expect(report.formatProbeOk, isTrue);
      expect(report.aaudioRuntimeAvailableOk, isTrue);
      expect(report.aaudioSymbolsResolvedOk, isTrue);
      expect(report.aaudioStreamOpenOk, isTrue);
      expect(report.aaudioConfigOk, isTrue);
      expect(report.aaudioStartOk, isTrue);
      expect(report.callbackObservedOk, isTrue);
      expect(report.mutedOutputOk, isTrue);
      expect(report.noProviderUnderrunOk, isFalse);
    });

    test('nested lane and metric precedence over top-level or raw fields', () {
      final report = VGAaudioNodeOwnedSinkSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'formatProbeOk': false,
        'sampleRate': 22050,
        'expectedFrameCount': 1000,
        'lanes': const <String, Object?>{'formatProbeOk': true},
        'metrics': const <String, Object?>{
          'sampleRate': 48000,
          'expectedFrameCount': 48000,
        },
        'raw': const <String, String>{
          'formatProbeOk': 'false',
          'sampleRate': '44100',
          'expectedFrameCount': '2000',
        },
      });

      expect(report.formatProbeOk, isTrue);
      expect(report.sampleRate, equals(48000));
      expect(report.expectedFrameCount, equals(48000));
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
      expect(reportInvalid.allNativeLanesPass, isFalse);

      final reportEmpty = _createSampleReport({'proofBoundary': ''});
      expect(reportEmpty.hasCanonicalProofBoundary, isFalse);
      expect(reportEmpty.allNativeLanesPass, isFalse);
    });
  });

  group('Checksum, muted sink, and callback derived getters', () {
    test('checksumsMatch verifies 3-way non-empty identity and lane ok', () {
      final report = _createSampleReport();
      expect(report.checksumsMatch, isTrue);

      expect(
        _createSampleReport({
          'kotlinAcceptedChecksumHexTrack0': '',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'nativeAcceptedChecksumHexTrack0': '',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'kotlinAcceptedChecksumHexTrack1': '',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'nativeAcceptedChecksumHexTrack1': '',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'kotlinReferenceMixChecksumHex': '',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'nativeOutputDrainChecksumHex': '',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'kotlinAcceptedChecksumHexTrack0': 'mismatch0',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'kotlinAcceptedChecksumHexTrack1': 'mismatch1',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'kotlinReferenceMixChecksumHex': 'mismatchMix',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({
          'kotlinReferenceMixChecksumHex': '0000000000000000',
          'nativeOutputDrainChecksumHex': '0000000000000000',
        }).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({'track0IngestOk': false}).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({'track1SyntheticIngestOk': false}).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({'graphOutputChecksumOk': false}).checksumsMatch,
        isFalse,
      );
    });

    test('mutedSinkIsZero requires zero hex and mutedOutputOk', () {
      expect(_createSampleReport().mutedSinkIsZero, isTrue);
      expect(
        _createSampleReport({
          'mutedSinkChecksumHex': '0000000000000001',
        }).mutedSinkIsZero,
        isFalse,
      );
      expect(
        _createSampleReport({'mutedOutputOk': false}).mutedSinkIsZero,
        isFalse,
      );
    });

    test(
      'callbackAccountingCoherent requires coherence and non-zero counts',
      () {
        expect(_createSampleReport().callbackAccountingCoherent, isTrue);
        expect(
          _createSampleReport({
            'finalCallbackCountersCoherent': false,
          }).callbackAccountingCoherent,
          isFalse,
        );
        expect(
          _createSampleReport({
            'callbackInvocationCount': 0,
          }).callbackAccountingCoherent,
          isFalse,
        );
        expect(
          _createSampleReport({
            'callbackFramesServed': 0,
          }).callbackAccountingCoherent,
          isFalse,
        );
        expect(
          _createSampleReport({
            'callbackFramesRequested': 30000,
            'callbackFramesServed': 28800,
            'callbackSilenceFrames': 0,
          }).callbackAccountingCoherent,
          isFalse,
        );
        expect(
          _createSampleReport({
            'aaudioCallbackAccountingOk': false,
          }).callbackAccountingCoherent,
          isFalse,
        );
      },
    );
  });

  group('allNativeLanesPass comprehensive validation', () {
    test('allNativeLanesPass requires all conditions to hold', () {
      expect(_createSampleReport().allNativeLanesPass, isTrue);

      // Top-level status / marker / pass / proof boundary
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

      // Lanes (26 lanes)
      expect(
        _createSampleReport({'formatProbeOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'aaudioRuntimeAvailableOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'aaudioSymbolsResolvedOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'aaudioStreamOpenOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'aaudioConfigOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'aaudioStartOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'callbackObservedOk': false}).allNativeLanesPass,
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
        _createSampleReport({'nodeOwnsRingTrack0Ok': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'nodeOwnsRingTrack1Ok': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'track0IngestOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'track1SyntheticIngestOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'trackFrameAxisLockstepOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'jointDispatchGateOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'graphOutputChecksumOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'aaudioCallbackAccountingOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'jointTailFlushOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'noProviderUnderrunOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'noGraphSilenceOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'noRingPushShortfallOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'zeroNativeSteadyStateAllocationOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'ownerThreadOk': false}).allNativeLanesPass,
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

      // Metrics integrity
      expect(
        _createSampleReport({'sampleRate': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'channelCount': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'channelCount': 3}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'pcmEncoding': 1}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'commonBudgetFrames': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'expectedFrameCount': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'expectedFrameCount': 20000,
          'commonBudgetFrames': 28800,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'routedSourceId0': 'wrong_id_0',
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'routedSourceId1': 'wrong_id_1',
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'totalFramesAcceptedTrack0': 0,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'totalFramesAcceptedTrack1': 0,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'totalFramesAcceptedTrack0': 28800,
          'totalFramesAcceptedTrack1': 27000,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'totalOutputFramesPumped': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'totalOutputFramesPumped': 28800,
          'totalFramesAcceptedTrack0': 27000,
          'totalFramesAcceptedTrack1': 27000,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'totalMutedFramesPushed': 27000,
          'totalOutputFramesPumped': 28800,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'track1NonZeroSampleCount': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'dispatchCount': 49}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'dispatchCount': 50}).allNativeLanesPass,
        isTrue,
      );
      expect(
        _createSampleReport({
          'providerUnderrunEventsTrack0': 1,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'providerUnderrunEventsTrack1': 1,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'providerFramesZeroFilledTrack0': 1,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'providerFramesZeroFilledTrack1': 1,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'providerForwardSkipFramesTrack0': 1,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'providerForwardSkipFramesTrack1': 1,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'providerRewindRejectsTrack0': 1,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'providerRewindRejectsTrack1': 1,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'coordinatorSilenceCount': 1}).allNativeLanesPass,
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

    test('seekOk=false is allowed ONLY when seekSkippedDeadline=true', () {
      // Normal pass: seekOk=true, seekSkippedDeadline=false
      expect(
        _createSampleReport({
          'seekOk': true,
          'seekSkippedDeadline': false,
          'postSeekFramesAccepted': 16800,
          'seekAcceptedFrame': 12000,
        }).allNativeLanesPass,
        isTrue,
      );

      // seekOk=false and seekSkippedDeadline=false -> MUST FAIL
      expect(
        _createSampleReport({
          'seekOk': false,
          'seekSkippedDeadline': false,
        }).allNativeLanesPass,
        isFalse,
      );

      // seekOk=false and seekSkippedDeadline=true -> PASSES (deadline skip accepted)
      expect(
        _createSampleReport({
          'seekOk': false,
          'seekSkippedDeadline': true,
          'postSeekFramesAccepted': 0,
          'seekAcceptedFrame': -1,
        }).allNativeLanesPass,
        isTrue,
      );
    });
  });

  group('Value semantics: equality, hashCode, toString', () {
    test('identical instances and identical values evaluate equal', () {
      final a = _createSampleReport();
      final b = _createSampleReport();

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGAaudioNodeOwnedSinkSmokeReport('));
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
        {'failureReason': 'other_reason'},
        {'details': 'other_details'},
        {'formatProbeOk': false},
        {'aaudioRuntimeAvailableOk': false},
        {'aaudioSymbolsResolvedOk': false},
        {'aaudioStreamOpenOk': false},
        {'aaudioConfigOk': false},
        {'aaudioStartOk': false},
        {'callbackObservedOk': false},
        {'mutedOutputOk': false},
        {'nodeOwnedRouteDiscoveryOk': false},
        {'nodeOwnsRingTrack0Ok': false},
        {'nodeOwnsRingTrack1Ok': false},
        {'track0IngestOk': false},
        {'track1SyntheticIngestOk': false},
        {'trackFrameAxisLockstepOk': false},
        {'jointDispatchGateOk': false},
        {'graphOutputChecksumOk': false},
        {'aaudioCallbackAccountingOk': false},
        {'seekOk': false},
        {'jointTailFlushOk': false},
        {'noProviderUnderrunOk': false},
        {'noGraphSilenceOk': false},
        {'noRingPushShortfallOk': false},
        {'zeroNativeSteadyStateAllocationOk': false},
        {'ownerThreadOk': false},
        {'lifecycleOk': false},
        {'canonical': false},
        {'sampleRate': 44100},
        {'channelCount': 1},
        {'pcmEncoding': 1},
        {'commonBudgetFrames': 44100},
        {'expectedFrameCount': 44100},
        {'totalFramesExtracted': 9999},
        {'framesTruncatedBeyondBudget': 500},
        {'totalFramesAcceptedTrack0': 9999},
        {'totalFramesAcceptedTrack1': 9999},
        {'totalOutputFramesPumped': 9999},
        {'totalMutedFramesPushed': 9999},
        {'postSeekFramesAccepted': 5000},
        {'seekAcceptedFrame': 5000},
        {'seekSkippedDeadline': true},
        {'track1NonZeroSampleCount': 5000},
        {'decoderBenignFormatChangeCount': 5},
        {'nativeAcceptedChecksumHexTrack0': 'diff0'},
        {'nativeAcceptedChecksumHexTrack1': 'diff1'},
        {'nativeOutputDrainChecksumHex': 'diffMix'},
        {'mutedSinkChecksumHex': 'diffMuted'},
        {'kotlinAcceptedChecksumHexTrack0': 'diff0'},
        {'kotlinAcceptedChecksumHexTrack1': 'diff1'},
        {'kotlinReferenceMixChecksumHex': 'diffMix'},
        {'routedSourceId0': 'other_src0'},
        {'routedSourceId1': 'other_src1'},
        {'dispatchCount': 100},
        {'nextDispatchFrame': 1000},
        {'coordinatorSilenceCount': 1},
        {'providerUnderrunEventsTrack0': 1},
        {'providerUnderrunEventsTrack1': 1},
        {'providerFramesZeroFilledTrack0': 1},
        {'providerFramesZeroFilledTrack1': 1},
        {'providerForwardSkipFramesTrack0': 1},
        {'providerForwardSkipFramesTrack1': 1},
        {'providerRewindRejectsTrack0': 1},
        {'providerRewindRejectsTrack1': 1},
        {'deviceApiLevel': 28},
        {'streamSampleRate': 44100},
        {'streamChannelCount': 1},
        {'streamFormat': 2},
        {'aaudioChannelCountSymbolFallback': true},
        {'callbackInvocationCount': 50},
        {'callbackFramesRequested': 10000},
        {'callbackFramesServed': 9000},
        {'callbackSilenceFrames': 1000},
        {'callbackShortReads': 2},
        {'errorCallbackCount': 1},
        {'finalCallbackCountersCoherent': false},
        {'sinkFullWaitCount': 5},
        {'sinkAvailableReadFramesFinal': 10},
        {'cancellationPollCount': 10},
        {'nativeLastStatus': 'other'},
        {'maxFramesPerMix': 512},
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

  group('MethodChannel wrapper: runAndroidDagPhase4AaudioNodeOwnedSinkSmoke', () {
    test(
      'invokes runAndroidDagPhase4AaudioNodeOwnedSinkSmoke with correct default args on default channel',
      () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGAaudioNodeOwnedSinkSmokeReport.runAndroidDagPhase4AaudioNodeOwnedSinkSmoke(
              sourcePath: '/path/to/test/clip_A.mov',
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase4AaudioNodeOwnedSinkSmoke'),
        );
        expect(
          capturedCall!.arguments,
          equals(<String, Object?>{
            'sourcePath': '/path/to/test/clip_A.mov',
            'durationSec': 0.6,
            'seekTargetSec': 0.25,
            'sourceRingCapacityFrames': 8192,
            'outputRingCapacityFrames': 4096,
            'sinkRingCapacityFrames': 65536,
            'maxFramesPerMix': 256,
            'deadlineMs': 45000,
          }),
        );
        expect(report.pass, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test('invokes method with custom arguments', () async {
      MethodCall? capturedCall;
      const customChannel = MethodChannel('custom_vanguard_channel');
      binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGAaudioNodeOwnedSinkSmokeReport.runAndroidDagPhase4AaudioNodeOwnedSinkSmoke(
            sourcePath: '/custom/path.mp4',
            durationSec: 0.8,
            seekTargetSec: 0.3,
            sourceRingCapacityFrames: 16384,
            outputRingCapacityFrames: 8192,
            sinkRingCapacityFrames: 32768,
            maxFramesPerMix: 128,
            timeout: const Duration(seconds: 20),
            channel: customChannel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('runAndroidDagPhase4AaudioNodeOwnedSinkSmoke'),
      );
      expect(
        capturedCall!.arguments,
        equals(<String, Object?>{
          'sourcePath': '/custom/path.mp4',
          'durationSec': 0.8,
          'seekTargetSec': 0.3,
          'sourceRingCapacityFrames': 16384,
          'outputRingCapacityFrames': 8192,
          'sinkRingCapacityFrames': 32768,
          'maxFramesPerMix': 128,
          'deadlineMs': 20000,
        }),
      );
      expect(report.pass, isTrue);
    });

    test('timeout fallback creates structured failed report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return _createSampleRawMap();
      });

      final report =
          await VGAaudioNodeOwnedSinkSmokeReport.runAndroidDagPhase4AaudioNodeOwnedSinkSmoke(
            sourcePath: '/path/to/clip.mov',
            timeout: const Duration(milliseconds: 10),
          );

      expect(report.pass, isFalse);
      expect(report.status, equals('fail'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.failureReason, equals('timeout'));
      expect(report.lastError, contains('timeout'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test(
      'PlatformException fallback creates structured failed report with code/message',
      () async {
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          throw PlatformException(
            code: 'P4_AAUDIO_NODE_OWNED_SINK_SMOKE_BUSY',
            message: 'diagnostic already running',
          );
        });

        final report =
            await VGAaudioNodeOwnedSinkSmokeReport.runAndroidDagPhase4AaudioNodeOwnedSinkSmoke(
              sourcePath: '/path/to/clip.mov',
            );

        expect(report.pass, isFalse);
        expect(report.status, equals('fail'));
        expect(report.marker, equals(_kFailMarker));
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(
          report.failureReason,
          equals('platform_exception:P4_AAUDIO_NODE_OWNED_SINK_SMOKE_BUSY'),
        );
        expect(report.details, equals('diagnostic already running'));
        expect(
          report.lastError,
          equals(
            'platform_exception:P4_AAUDIO_NODE_OWNED_SINK_SMOKE_BUSY:diagnostic already running',
          ),
        );
        expect(report.allNativeLanesPass, isFalse);
      },
    );

    test('handles generic Exception by returning fallback report', () async {
      const exChannel = MethodChannel('ex_aaudio_node_owned_sink_channel');
      binaryMessenger.setMockMethodCallHandler(exChannel, (call) async {
        throw Exception('Native AAudio node-owned sink crashed');
      });

      final report =
          await VGAaudioNodeOwnedSinkSmokeReport.runAndroidDagPhase4AaudioNodeOwnedSinkSmoke(
            sourcePath: '/dummy/path',
            channel: exChannel,
          );

      expect(report.pass, isFalse);
      expect(report.status, equals('fail'));
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.marker, equals(_kFailMarker));
      expect(report.allNativeLanesPass, isFalse);
      expect(
        report.lastError,
        contains('Native AAudio node-owned sink crashed'),
      );
    });
  });
}
