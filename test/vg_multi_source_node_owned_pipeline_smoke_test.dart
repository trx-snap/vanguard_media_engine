// vg_multi_source_node_owned_pipeline_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-MULTI-SOURCE-NODE-OWNED-PIPELINE: Android True-DAG Phase 4
// two-source node-owned closed-loop native audio graph pipeline Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'kotlin_owned_real_decoder_plus_synthetic_second_track_step_driven_multi_source_node_owned_closed_loop_native_audio_graph_pipeline_session_proof_only_source_nodes_own_ring_writer_provider_by_composition_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_no_hybrid_routing_no_second_os_decoder_no_cpp_os_decoder_no_mediacodec_no_mediaextractor_ownership_in_cpp_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_destroy_idempotent_any_thread_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_sink_clocked_transport_no_audible_or_realtime_playback_no_audio_focus_no_route_no_dead_object_no_speaker_no_latency_no_glitch_claims_diagnostic_graph_topology_only_two_routed_tracks_unit_gain_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_joint_tail_flush_diagnostic_only_no_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_streaming_no_cache_no_ios_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_MULTI_SOURCE_NODE_OWNED_PIPELINE_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_MULTI_SOURCE_NODE_OWNED_PIPELINE_SMOKE_FAIL';
const _kSource0Id = 'multi_source_node_owned_src0';
const _kSource1Id = 'multi_source_node_owned_src1';
const _kChecksum0Hex = '0000000011111111';
const _kChecksum1Hex = '0000000022222222';
const _kChecksumMixHex = '0000000033333333';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'formatProbeOk': true,
    'topologyRoutedSourcesOk': true,
    'nodeOwnedRouteDiscoveryOk': true,
    'nodeOwnsRingTrack0Ok': true,
    'nodeOwnsRingTrack1Ok': true,
    'track0IngestOk': true,
    'track1SyntheticIngestOk': true,
    'trackFrameAxisLockstepOk': true,
    'jointDispatchGateOk': true,
    'referenceMixChecksumOk': true,
    'mixedOutputFrameAccountingOk': true,
    'twoTrackContributionOk': true,
    'seekOk': true,
    'jointTailFlushOk': true,
    'noProviderUnderrunOk': true,
    'noZeroFillOk': true,
    'noForwardSkipOk': true,
    'noRewindRejectOk': true,
    'noSilenceOk': true,
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
    'commonBudgetFrames': 48000,
    'expectedFrameCount': 48000,
    'routedSourceId0': _kSource0Id,
    'routedSourceId1': _kSource1Id,
    'framesTruncatedBeyondBudget': 0,
    'totalFramesExtracted': 48000,
    'totalFramesAcceptedTrack0': 48000,
    'totalFramesAcceptedTrack1': 48000,
    'totalOutputFramesDrained': 48000,
    'postSeekFramesAccepted': 31200,
    'postSeekFramesDrained': 31200,
    'seekAcceptedFrame': 16800,
    'track1NonZeroSampleCount': 96000,
    'mixedChecksumDiffersFromTrack0': true,
    'mixedChecksumDiffersFromTrack1': true,
    'decoderBenignFormatChangeCount': 1,
    'providerUnderrunEventsTrack0': 0,
    'providerUnderrunEventsTrack1': 0,
    'providerFramesZeroFilledTrack0': 0,
    'providerFramesZeroFilledTrack1': 0,
    'providerForwardSkipFramesTrack0': 0,
    'providerForwardSkipFramesTrack1': 0,
    'providerRewindRejectsTrack0': 0,
    'providerRewindRejectsTrack1': 0,
    'coordinatorSilenceCount': 0,
    'nativeAcceptedChecksumHexTrack0': _kChecksum0Hex,
    'nativeAcceptedChecksumHexTrack1': _kChecksum1Hex,
    'nativeOutputDrainChecksumHex': _kChecksumMixHex,
    'kotlinAcceptedChecksumHexTrack0': _kChecksum0Hex,
    'kotlinAcceptedChecksumHexTrack1': _kChecksum1Hex,
    'kotlinReferenceMixChecksumHex': _kChecksumMixHex,
    'maxFramesPerMix': 256,
    'sourceAvailableReadFramesTrack0': 0,
    'sourceAvailableReadFramesTrack1': 0,
    'outputAvailableReadFrames': 0,
    'dispatchCount': 188,
    'nextDispatchFrame': 48000,
    'nativeLastStatus': 'drained',
  };

  final raw = <String, String>{
    'status': 'PASS',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'seekAcceptedFrame=16800|commonBudgetFrames=48000',
    'formatProbeOk': 'true',
    'topologyRoutedSourcesOk': 'true',
    'nodeOwnedRouteDiscoveryOk': 'true',
    'nodeOwnsRingTrack0Ok': 'true',
    'nodeOwnsRingTrack1Ok': 'true',
    'track0IngestOk': 'true',
    'track1SyntheticIngestOk': 'true',
    'trackFrameAxisLockstepOk': 'true',
    'jointDispatchGateOk': 'true',
    'referenceMixChecksumOk': 'true',
    'mixedOutputFrameAccountingOk': 'true',
    'twoTrackContributionOk': 'true',
    'seekOk': 'true',
    'jointTailFlushOk': 'true',
    'noProviderUnderrunOk': 'true',
    'noZeroFillOk': 'true',
    'noForwardSkipOk': 'true',
    'noRewindRejectOk': 'true',
    'noSilenceOk': 'true',
    'noRingPushShortfallOk': 'true',
    'zeroNativeSteadyStateAllocationOk': 'true',
    'ownerThreadOk': 'true',
    'lifecycleOk': 'true',
    'canonical': 'true',
    'sampleRate': '48000',
    'channelCount': '2',
    'pcmEncoding': '2',
    'commonBudgetFrames': '48000',
    'expectedFrameCount': '48000',
    'routedSourceId0': _kSource0Id,
    'routedSourceId1': _kSource1Id,
    'framesTruncatedBeyondBudget': '0',
    'totalFramesExtracted': '48000',
    'totalFramesAcceptedTrack0': '48000',
    'totalFramesAcceptedTrack1': '48000',
    'totalOutputFramesDrained': '48000',
    'postSeekFramesAccepted': '31200',
    'postSeekFramesDrained': '31200',
    'seekAcceptedFrame': '16800',
    'track1NonZeroSampleCount': '96000',
    'mixedChecksumDiffersFromTrack0': 'true',
    'mixedChecksumDiffersFromTrack1': 'true',
    'decoderBenignFormatChangeCount': '1',
    'providerUnderrunEventsTrack0': '0',
    'providerUnderrunEventsTrack1': '0',
    'providerFramesZeroFilledTrack0': '0',
    'providerFramesZeroFilledTrack1': '0',
    'providerForwardSkipFramesTrack0': '0',
    'providerForwardSkipFramesTrack1': '0',
    'providerRewindRejectsTrack0': '0',
    'providerRewindRejectsTrack1': '0',
    'coordinatorSilenceCount': '0',
    'nativeAcceptedChecksumHexTrack0': _kChecksum0Hex,
    'nativeAcceptedChecksumHexTrack1': _kChecksum1Hex,
    'nativeOutputDrainChecksumHex': _kChecksumMixHex,
    'kotlinAcceptedChecksumHexTrack0': _kChecksum0Hex,
    'kotlinAcceptedChecksumHexTrack1': _kChecksum1Hex,
    'kotlinReferenceMixChecksumHex': _kChecksumMixHex,
    'maxFramesPerMix': '256',
    'sourceAvailableReadFramesTrack0': '0',
    'sourceAvailableReadFramesTrack1': '0',
    'outputAvailableReadFrames': '0',
    'dispatchCount': '188',
    'nextDispatchFrame': '48000',
    'nativeLastStatus': 'drained',
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details': 'seekAcceptedFrame=16800|commonBudgetFrames=48000',
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

VGMultiSourceNodeOwnedPipelineSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGMultiSourceNodeOwnedPipelineSmokeReport.fromMap(
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

  group('VGMultiSourceNodeOwnedPipelineSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGMultiSourceNodeOwnedPipelineSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.pass, isTrue);
        expect(report.status, equals('pass'));
        expect(report.marker, equals(_kPassMarker));
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.failureReason, isEmpty);
        expect(report.lastError, isEmpty);
        expect(report.details, contains('seekAcceptedFrame=16800'));

        // Lanes (24 lanes)
        expect(report.formatProbeOk, isTrue);
        expect(report.topologyRoutedSourcesOk, isTrue);
        expect(report.nodeOwnedRouteDiscoveryOk, isTrue);
        expect(report.nodeOwnsRingTrack0Ok, isTrue);
        expect(report.nodeOwnsRingTrack1Ok, isTrue);
        expect(report.track0IngestOk, isTrue);
        expect(report.track1SyntheticIngestOk, isTrue);
        expect(report.trackFrameAxisLockstepOk, isTrue);
        expect(report.jointDispatchGateOk, isTrue);
        expect(report.referenceMixChecksumOk, isTrue);
        expect(report.mixedOutputFrameAccountingOk, isTrue);
        expect(report.twoTrackContributionOk, isTrue);
        expect(report.seekOk, isTrue);
        expect(report.jointTailFlushOk, isTrue);
        expect(report.noProviderUnderrunOk, isTrue);
        expect(report.noZeroFillOk, isTrue);
        expect(report.noForwardSkipOk, isTrue);
        expect(report.noRewindRejectOk, isTrue);
        expect(report.noSilenceOk, isTrue);
        expect(report.noRingPushShortfallOk, isTrue);
        expect(report.zeroNativeSteadyStateAllocationOk, isTrue);
        expect(report.ownerThreadOk, isTrue);
        expect(report.lifecycleOk, isTrue);
        expect(report.canonical, isTrue);

        // Metrics (41 metrics)
        expect(report.sampleRate, equals(48000));
        expect(report.channelCount, equals(2));
        expect(report.pcmEncoding, equals(2));
        expect(report.commonBudgetFrames, equals(48000));
        expect(report.expectedFrameCount, equals(48000));
        expect(report.routedSourceId0, equals(_kSource0Id));
        expect(report.routedSourceId1, equals(_kSource1Id));
        expect(report.framesTruncatedBeyondBudget, equals(0));
        expect(report.totalFramesExtracted, equals(48000));
        expect(report.totalFramesAcceptedTrack0, equals(48000));
        expect(report.totalFramesAcceptedTrack1, equals(48000));
        expect(report.totalOutputFramesDrained, equals(48000));
        expect(report.postSeekFramesAccepted, equals(31200));
        expect(report.postSeekFramesDrained, equals(31200));
        expect(report.seekAcceptedFrame, equals(16800));
        expect(report.track1NonZeroSampleCount, equals(96000));
        expect(report.mixedChecksumDiffersFromTrack0, isTrue);
        expect(report.mixedChecksumDiffersFromTrack1, isTrue);
        expect(report.decoderBenignFormatChangeCount, equals(1));
        expect(report.providerUnderrunEventsTrack0, equals(0));
        expect(report.providerUnderrunEventsTrack1, equals(0));
        expect(report.providerFramesZeroFilledTrack0, equals(0));
        expect(report.providerFramesZeroFilledTrack1, equals(0));
        expect(report.providerForwardSkipFramesTrack0, equals(0));
        expect(report.providerForwardSkipFramesTrack1, equals(0));
        expect(report.providerRewindRejectsTrack0, equals(0));
        expect(report.providerRewindRejectsTrack1, equals(0));
        expect(report.coordinatorSilenceCount, equals(0));
        expect(report.nativeAcceptedChecksumHexTrack0, equals(_kChecksum0Hex));
        expect(report.nativeAcceptedChecksumHexTrack1, equals(_kChecksum1Hex));
        expect(report.nativeOutputDrainChecksumHex, equals(_kChecksumMixHex));
        expect(report.kotlinAcceptedChecksumHexTrack0, equals(_kChecksum0Hex));
        expect(report.kotlinAcceptedChecksumHexTrack1, equals(_kChecksum1Hex));
        expect(report.kotlinReferenceMixChecksumHex, equals(_kChecksumMixHex));
        expect(report.maxFramesPerMix, equals(256));
        expect(report.sourceAvailableReadFramesTrack0, equals(0));
        expect(report.sourceAvailableReadFramesTrack1, equals(0));
        expect(report.outputAvailableReadFrames, equals(0));
        expect(report.dispatchCount, equals(188));
        expect(report.nextDispatchFrame, equals(48000));
        expect(report.nativeLastStatus, equals('drained'));

        // Getters
        expect(report.checksumsMatch, isTrue);
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

        final roundTrip = VGMultiSourceNodeOwnedPipelineSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGMultiSourceNodeOwnedPipelineSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'status': 'track_frame_axis_divergence',
          'marker': _kFailMarker,
          'failureReason': 'track_frame_axis_divergence',
          'lastError': 'track_frame_axis_divergence',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.status, equals('track_frame_axis_divergence'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('track_frame_axis_divergence'));
      expect(report.lastError, equals('track_frame_axis_divergence'));
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
        final report = VGMultiSourceNodeOwnedPipelineSmokeReport.fromMap(
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
        expect(report.totalFramesAcceptedTrack0, equals(0));
        expect(report.totalFramesAcceptedTrack1, equals(0));
        expect(report.totalOutputFramesDrained, equals(0));
        expect(report.seekAcceptedFrame, equals(-1));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw = VGMultiSourceNodeOwnedPipelineSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'marker=$_kPassMarker;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'formatProbeOk=true;'
            'topologyRoutedSourcesOk=true;'
            'nodeOwnedRouteDiscoveryOk=true;'
            'nodeOwnsRingTrack0Ok=true;'
            'nodeOwnsRingTrack1Ok=true;'
            'track0IngestOk=true;'
            'track1SyntheticIngestOk=true;'
            'trackFrameAxisLockstepOk=true;'
            'jointDispatchGateOk=true;'
            'referenceMixChecksumOk=true;'
            'mixedOutputFrameAccountingOk=true;'
            'twoTrackContributionOk=true;'
            'seekOk=true;'
            'jointTailFlushOk=true;'
            'noProviderUnderrunOk=true;'
            'noZeroFillOk=true;'
            'noForwardSkipOk=true;'
            'noRewindRejectOk=true;'
            'noSilenceOk=true;'
            'noRingPushShortfallOk=true;'
            'zeroNativeSteadyStateAllocationOk=true;'
            'ownerThreadOk=true;'
            'lifecycleOk=true;'
            'canonical=true;'
            'sampleRate=48000;'
            'channelCount=2;'
            'pcmEncoding=2;'
            'commonBudgetFrames=48000;'
            'expectedFrameCount=48000;'
            'routedSourceId0=$_kSource0Id;'
            'routedSourceId1=$_kSource1Id;'
            'framesTruncatedBeyondBudget=0;'
            'totalFramesExtracted=48000;'
            'totalFramesAcceptedTrack0=48000;'
            'totalFramesAcceptedTrack1=48000;'
            'totalOutputFramesDrained=48000;'
            'postSeekFramesAccepted=31200;'
            'postSeekFramesDrained=31200;'
            'seekAcceptedFrame=16800;'
            'track1NonZeroSampleCount=96000;'
            'mixedChecksumDiffersFromTrack0=true;'
            'mixedChecksumDiffersFromTrack1=true;'
            'decoderBenignFormatChangeCount=1;'
            'providerUnderrunEventsTrack0=0;'
            'providerUnderrunEventsTrack1=0;'
            'providerFramesZeroFilledTrack0=0;'
            'providerFramesZeroFilledTrack1=0;'
            'providerForwardSkipFramesTrack0=0;'
            'providerForwardSkipFramesTrack1=0;'
            'providerRewindRejectsTrack0=0;'
            'providerRewindRejectsTrack1=0;'
            'coordinatorSilenceCount=0;'
            'nativeAcceptedChecksumHexTrack0=$_kChecksum0Hex;'
            'nativeAcceptedChecksumHexTrack1=$_kChecksum1Hex;'
            'nativeOutputDrainChecksumHex=$_kChecksumMixHex;'
            'kotlinAcceptedChecksumHexTrack0=$_kChecksum0Hex;'
            'kotlinAcceptedChecksumHexTrack1=$_kChecksum1Hex;'
            'kotlinReferenceMixChecksumHex=$_kChecksumMixHex;'
            'maxFramesPerMix=256;'
            'sourceAvailableReadFramesTrack0=0;'
            'sourceAvailableReadFramesTrack1=0;'
            'outputAvailableReadFrames=0;'
            'dispatchCount=188;'
            'nextDispatchFrame=48000;'
            'nativeLastStatus=drained',
        'lanes': const <String, Object?>{},
        'metrics': const <String, Object?>{},
      });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.formatProbeOk, isTrue);
      expect(reportFromRaw.topologyRoutedSourcesOk, isTrue);
      expect(reportFromRaw.nodeOwnedRouteDiscoveryOk, isTrue);
      expect(reportFromRaw.nodeOwnsRingTrack0Ok, isTrue);
      expect(reportFromRaw.nodeOwnsRingTrack1Ok, isTrue);
      expect(reportFromRaw.track0IngestOk, isTrue);
      expect(reportFromRaw.track1SyntheticIngestOk, isTrue);
      expect(reportFromRaw.trackFrameAxisLockstepOk, isTrue);
      expect(reportFromRaw.jointDispatchGateOk, isTrue);
      expect(reportFromRaw.referenceMixChecksumOk, isTrue);
      expect(reportFromRaw.mixedOutputFrameAccountingOk, isTrue);
      expect(reportFromRaw.twoTrackContributionOk, isTrue);
      expect(reportFromRaw.seekOk, isTrue);
      expect(reportFromRaw.jointTailFlushOk, isTrue);
      expect(reportFromRaw.noProviderUnderrunOk, isTrue);
      expect(reportFromRaw.noZeroFillOk, isTrue);
      expect(reportFromRaw.noForwardSkipOk, isTrue);
      expect(reportFromRaw.noRewindRejectOk, isTrue);
      expect(reportFromRaw.noSilenceOk, isTrue);
      expect(reportFromRaw.noRingPushShortfallOk, isTrue);
      expect(reportFromRaw.zeroNativeSteadyStateAllocationOk, isTrue);
      expect(reportFromRaw.ownerThreadOk, isTrue);
      expect(reportFromRaw.lifecycleOk, isTrue);
      expect(reportFromRaw.canonical, isTrue);
      expect(reportFromRaw.sampleRate, equals(48000));
      expect(reportFromRaw.channelCount, equals(2));
      expect(reportFromRaw.expectedFrameCount, equals(48000));
      expect(reportFromRaw.routedSourceId0, equals(_kSource0Id));
      expect(reportFromRaw.routedSourceId1, equals(_kSource1Id));
      expect(reportFromRaw.totalFramesAcceptedTrack0, equals(48000));
      expect(reportFromRaw.totalFramesAcceptedTrack1, equals(48000));
      expect(reportFromRaw.totalOutputFramesDrained, equals(48000));
      expect(reportFromRaw.checksumsMatch, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in lanes and metrics', () {
      final report = VGMultiSourceNodeOwnedPipelineSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'lanes': const <String, Object?>{
          'formatProbeOk': 'true',
          'topologyRoutedSourcesOk': 'pass',
          'nodeOwnedRouteDiscoveryOk': 'true',
          'nodeOwnsRingTrack0Ok': 'ok',
          'nodeOwnsRingTrack1Ok': 'success',
          'track0IngestOk': 'ok',
          'track1SyntheticIngestOk': 'success',
          'twoTrackContributionOk': 'false',
        },
      });

      expect(report.formatProbeOk, isTrue);
      expect(report.topologyRoutedSourcesOk, isTrue);
      expect(report.nodeOwnedRouteDiscoveryOk, isTrue);
      expect(report.nodeOwnsRingTrack0Ok, isTrue);
      expect(report.nodeOwnsRingTrack1Ok, isTrue);
      expect(report.track0IngestOk, isTrue);
      expect(report.track1SyntheticIngestOk, isTrue);
      expect(report.twoTrackContributionOk, isFalse);
    });

    test('nested lane and metric precedence over top-level or raw fields', () {
      final report = VGMultiSourceNodeOwnedPipelineSmokeReport.fromMap({
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

  group('Checksum matching and lane verification', () {
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
        _createSampleReport({'track0IngestOk': false}).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({'track1SyntheticIngestOk': false}).checksumsMatch,
        isFalse,
      );
      expect(
        _createSampleReport({'referenceMixChecksumOk': false}).checksumsMatch,
        isFalse,
      );
    });

    test('checksum mismatch causes allNativeLanesPass to fail', () {
      final reportMismatch = _createSampleReport({
        'kotlinReferenceMixChecksumHex': 'mismatched_hex_1234',
      });
      expect(reportMismatch.checksumsMatch, isFalse);
      expect(reportMismatch.allNativeLanesPass, isFalse);
    });

    test(
      'twoTrackContributionOk failure causes allNativeLanesPass to fail',
      () {
        expect(
          _createSampleReport({
            'twoTrackContributionOk': false,
          }).allNativeLanesPass,
          isFalse,
        );
        expect(
          _createSampleReport({
            'mixedChecksumDiffersFromTrack0': false,
          }).allNativeLanesPass,
          isFalse,
        );
        expect(
          _createSampleReport({
            'mixedChecksumDiffersFromTrack1': false,
          }).allNativeLanesPass,
          isFalse,
        );
      },
    );

    test(
      'trackFrameAxisLockstepOk failure causes allNativeLanesPass to fail',
      () {
        expect(
          _createSampleReport({
            'trackFrameAxisLockstepOk': false,
          }).allNativeLanesPass,
          isFalse,
        );
        expect(
          _createSampleReport({
            'totalFramesAcceptedTrack0': 48000,
            'totalFramesAcceptedTrack1': 47000,
          }).allNativeLanesPass,
          isFalse,
        );
      },
    );

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

      // Lanes (24 lanes)
      expect(
        _createSampleReport({'formatProbeOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'topologyRoutedSourcesOk': false,
        }).allNativeLanesPass,
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
          'referenceMixChecksumOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'mixedOutputFrameAccountingOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'twoTrackContributionOk': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'seekOk': false}).allNativeLanesPass,
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
        _createSampleReport({'noZeroFillOk': false}).allNativeLanesPass,
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
        _createSampleReport({'noSilenceOk': false}).allNativeLanesPass,
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
        _createSampleReport({'commonBudgetFrames': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'expectedFrameCount': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'expectedFrameCount': 40000,
          'commonBudgetFrames': 48000,
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
        _createSampleReport({'totalOutputFramesDrained': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'totalOutputFramesDrained': 48000,
          'totalFramesAcceptedTrack0': 47000,
          'totalFramesAcceptedTrack1': 47000,
        }).allNativeLanesPass,
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
        _createSampleReport({'maxFramesPerMix': 0}).allNativeLanesPass,
        isFalse,
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

      // Residual frames must be zero
      expect(
        _createSampleReport({
          'sourceAvailableReadFramesTrack0': 1,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'sourceAvailableReadFramesTrack1': 1,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'outputAvailableReadFrames': 1,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'sourceAvailableReadFramesTrack0': 0,
          'sourceAvailableReadFramesTrack1': 0,
          'outputAvailableReadFrames': 0,
        }).allNativeLanesPass,
        isTrue,
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
        contains('VGMultiSourceNodeOwnedPipelineSmokeReport('),
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
        {'failureReason': 'other_reason'},
        {'details': 'other_details'},
        {'formatProbeOk': false},
        {'topologyRoutedSourcesOk': false},
        {'nodeOwnedRouteDiscoveryOk': false},
        {'nodeOwnsRingTrack0Ok': false},
        {'nodeOwnsRingTrack1Ok': false},
        {'track0IngestOk': false},
        {'track1SyntheticIngestOk': false},
        {'trackFrameAxisLockstepOk': false},
        {'jointDispatchGateOk': false},
        {'referenceMixChecksumOk': false},
        {'mixedOutputFrameAccountingOk': false},
        {'twoTrackContributionOk': false},
        {'seekOk': false},
        {'jointTailFlushOk': false},
        {'noProviderUnderrunOk': false},
        {'noZeroFillOk': false},
        {'noForwardSkipOk': false},
        {'noRewindRejectOk': false},
        {'noSilenceOk': false},
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
        {'routedSourceId0': 'other_src0'},
        {'routedSourceId1': 'other_src1'},
        {'framesTruncatedBeyondBudget': 500},
        {'totalFramesExtracted': 9999},
        {'totalFramesAcceptedTrack0': 9999},
        {'totalFramesAcceptedTrack1': 9999},
        {'totalOutputFramesDrained': 9999},
        {'postSeekFramesAccepted': 5000},
        {'postSeekFramesDrained': 5000},
        {'seekAcceptedFrame': 5000},
        {'track1NonZeroSampleCount': 5000},
        {'mixedChecksumDiffersFromTrack0': false},
        {'mixedChecksumDiffersFromTrack1': false},
        {'decoderBenignFormatChangeCount': 5},
        {'providerUnderrunEventsTrack0': 1},
        {'providerUnderrunEventsTrack1': 1},
        {'providerFramesZeroFilledTrack0': 1},
        {'providerFramesZeroFilledTrack1': 1},
        {'providerForwardSkipFramesTrack0': 1},
        {'providerForwardSkipFramesTrack1': 1},
        {'providerRewindRejectsTrack0': 1},
        {'providerRewindRejectsTrack1': 1},
        {'coordinatorSilenceCount': 1},
        {'nativeAcceptedChecksumHexTrack0': 'diff0'},
        {'nativeAcceptedChecksumHexTrack1': 'diff1'},
        {'nativeOutputDrainChecksumHex': 'diffMix'},
        {'kotlinAcceptedChecksumHexTrack0': 'diff0'},
        {'kotlinAcceptedChecksumHexTrack1': 'diff1'},
        {'kotlinReferenceMixChecksumHex': 'diffMix'},
        {'maxFramesPerMix': 512},
        {'sourceAvailableReadFramesTrack0': 10},
        {'sourceAvailableReadFramesTrack1': 10},
        {'outputAvailableReadFrames': 10},
        {'dispatchCount': 100},
        {'nextDispatchFrame': 1000},
        {'nativeLastStatus': 'other'},
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
    'MethodChannel wrapper: runAndroidDagPhase4MultiSourceNodeOwnedPipelineSmoke',
    () {
      test(
        'invokes runAndroidDagPhase4MultiSourceNodeOwnedPipelineSmoke with correct default args on default channel',
        () async {
          MethodCall? capturedCall;
          binaryMessenger.setMockMethodCallHandler(defaultChannel, (
            call,
          ) async {
            capturedCall = call;
            return _createSampleRawMap();
          });

          final report =
              await VGMultiSourceNodeOwnedPipelineSmokeReport.runAndroidDagPhase4MultiSourceNodeOwnedPipelineSmoke(
                sourcePath: '/path/to/test/clip_A.mov',
              );

          expect(capturedCall, isNotNull);
          expect(
            capturedCall!.method,
            equals('runAndroidDagPhase4MultiSourceNodeOwnedPipelineSmoke'),
          );
          expect(
            capturedCall!.arguments,
            equals(<String, Object?>{
              'sourcePath': '/path/to/test/clip_A.mov',
              'durationSec': 1.0,
              'seekTargetSec': 0.35,
              'sourceRingCapacityFrames': 8192,
              'outputRingCapacityFrames': 4096,
              'maxFramesPerMix': 256,
              'deadlineMs': 30000,
            }),
          );
          expect(report.pass, isTrue);
          expect(report.allNativeLanesPass, isTrue);
        },
      );

      test('invokes method with custom arguments', () async {
        MethodCall? capturedCall;
        final customChannel = const MethodChannel('custom_vanguard_channel');
        binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGMultiSourceNodeOwnedPipelineSmokeReport.runAndroidDagPhase4MultiSourceNodeOwnedPipelineSmoke(
              sourcePath: '/custom/path.mp4',
              durationSec: 1.5,
              seekTargetSec: 0.5,
              sourceRingCapacityFrames: 16384,
              outputRingCapacityFrames: 8192,
              maxFramesPerMix: 128,
              timeout: const Duration(seconds: 15),
              channel: customChannel,
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase4MultiSourceNodeOwnedPipelineSmoke'),
        );
        expect(
          capturedCall!.arguments,
          equals(<String, Object?>{
            'sourcePath': '/custom/path.mp4',
            'durationSec': 1.5,
            'seekTargetSec': 0.5,
            'sourceRingCapacityFrames': 16384,
            'outputRingCapacityFrames': 8192,
            'maxFramesPerMix': 128,
            'deadlineMs': 15000,
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
            await VGMultiSourceNodeOwnedPipelineSmokeReport.runAndroidDagPhase4MultiSourceNodeOwnedPipelineSmoke(
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
          binaryMessenger.setMockMethodCallHandler(defaultChannel, (
            call,
          ) async {
            throw PlatformException(
              code: 'P4_MULTI_SOURCE_NODE_OWNED_PIPELINE_SMOKE_BUSY',
              message: 'diagnostic already running',
            );
          });

          final report =
              await VGMultiSourceNodeOwnedPipelineSmokeReport.runAndroidDagPhase4MultiSourceNodeOwnedPipelineSmoke(
                sourcePath: '/path/to/clip.mov',
              );

          expect(report.pass, isFalse);
          expect(report.status, equals('fail'));
          expect(report.marker, equals(_kFailMarker));
          expect(report.hasCanonicalProofBoundary, isTrue);
          expect(
            report.failureReason,
            equals(
              'platform_exception:P4_MULTI_SOURCE_NODE_OWNED_PIPELINE_SMOKE_BUSY',
            ),
          );
          expect(report.details, equals('diagnostic already running'));
          expect(
            report.lastError,
            equals(
              'platform_exception:P4_MULTI_SOURCE_NODE_OWNED_PIPELINE_SMOKE_BUSY:diagnostic already running',
            ),
          );
          expect(report.allNativeLanesPass, isFalse);
        },
      );

      test('handles generic Exception by returning fallback report', () async {
        const exChannel = MethodChannel(
          'ex_multi_source_node_owned_pipeline_channel',
        );
        binaryMessenger.setMockMethodCallHandler(exChannel, (call) async {
          throw Exception('Native multi-source node-owned pipeline crashed');
        });

        final report =
            await VGMultiSourceNodeOwnedPipelineSmokeReport.runAndroidDagPhase4MultiSourceNodeOwnedPipelineSmoke(
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
          contains('Native multi-source node-owned pipeline crashed'),
        );
      });
    },
  );
}
