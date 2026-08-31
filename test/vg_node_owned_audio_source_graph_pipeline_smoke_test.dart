// vg_node_owned_audio_source_graph_pipeline_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-DECODER-SOURCE-NODE-WIRING: Android True-DAG Phase 4
// node-owned decoded audio source closed-loop native audio graph pipeline Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'diagnostic_node_owned_decoded_audio_source_ring_provider_wiring_proof_only_source_node_owns_ring_writer_provider_by_composition_scheduler_auto_discovers_provider_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_no_hybrid_routing_no_production_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_mediacodec_no_mediaextractor_no_cpp_os_decoder_ownership_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_no_audio_focus_no_route_no_dead_object_no_audible_no_speaker_no_latency_no_glitch_claims_no_streaming_no_cache_no_ios_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_destroy_idempotent_any_thread_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_single_routed_track_unit_gain_only_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_AUDIO_DECODER_SOURCE_NODE_WIRING_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_AUDIO_DECODER_SOURCE_NODE_WIRING_SMOKE_FAIL';
const _kChecksumHex = '00000000abcdef12';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'invalidCreateRejectedOk': true,
    'routeDiscoveryOk': true,
    'nodeOwnsRingOk': true,
    'checksumIdentityOk': true,
    'frameAccountingOk': true,
    'seekOk': true,
    'underrunGateOk': true,
    'tailFlushOk': true,
    'noUnderrunOk': true,
    'noSilenceOk': true,
    'zeroNativeSteadyStateAllocationOk': true,
    'lifecycleOk': true,
  };

  final metrics = <String, Object?>{
    'routedSourceCount': 1,
    'routedSourceId0': 'node_owned_pipeline_src',
    'nodeOwnsRing': true,
    'totalFramesAccepted': 16513,
    'totalOutputFramesDrained': 16513,
    'providerUnderrunEvents': 0,
    'providerFramesZeroFilled': 0,
    'providerForwardSkipFrames': 0,
    'providerRewindRejects': 0,
    'coordinatorSilenceCount': 0,
    'dispatchCount': 66,
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeOutputDrainChecksumHex': _kChecksumHex,
    'kotlinAcceptedChecksumHex': _kChecksumHex,
    'sourceAvailableReadFrames': 0,
    'outputAvailableReadFrames': 0,
    'schedulerTrackScratchCapacitySamples': 1024,
    'schedulerTrackScratchCapacityTracks': 4,
    'sourceRingStorageCapacitySamples': 16384,
    'outputRingStorageCapacitySamples': 8192,
  };

  final raw = <String, String>{
    'status': 'PASS',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'preSeekWindows=32|postSeekWindows=32|tailFrames=129|finalNextFrame=16513',
    'invalidCreateRejectedOk': 'true',
    'routeDiscoveryOk': 'true',
    'nodeOwnsRingOk': 'true',
    'checksumIdentityOk': 'true',
    'frameAccountingOk': 'true',
    'seekOk': 'true',
    'underrunGateOk': 'true',
    'tailFlushOk': 'true',
    'noUnderrunOk': 'true',
    'noSilenceOk': 'true',
    'zeroNativeSteadyStateAllocationOk': 'true',
    'lifecycleOk': 'true',
    'routedSourceCount': '1',
    'routedSourceId0': 'node_owned_pipeline_src',
    'nodeOwnsRing': 'true',
    'totalFramesAccepted': '16513',
    'totalOutputFramesDrained': '16513',
    'providerUnderrunEvents': '0',
    'providerFramesZeroFilled': '0',
    'providerForwardSkipFrames': '0',
    'providerRewindRejects': '0',
    'coordinatorSilenceCount': '0',
    'dispatchCount': '66',
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeOutputDrainChecksumHex': _kChecksumHex,
    'kotlinAcceptedChecksumHex': _kChecksumHex,
    'sourceAvailableReadFrames': '0',
    'outputAvailableReadFrames': '0',
    'schedulerTrackScratchCapacitySamples': '1024',
    'schedulerTrackScratchCapacityTracks': '4',
    'sourceRingStorageCapacitySamples': '16384',
    'outputRingStorageCapacitySamples': '8192',
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'preSeekWindows=32|postSeekWindows=32|tailFrames=129|finalNextFrame=16513',
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

  group('VGNodeOwnedAudioSourceGraphPipelineSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.pass, isTrue);
        expect(report.status, equals('pass'));
        expect(report.marker, equals(_kPassMarker));
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.failureReason, isEmpty);
        expect(report.lastError, isEmpty);
        expect(report.details, contains('preSeekWindows=32'));

        // Lanes (12 lanes)
        expect(report.invalidCreateRejectedOk, isTrue);
        expect(report.routeDiscoveryOk, isTrue);
        expect(report.nodeOwnsRingOk, isTrue);
        expect(report.checksumIdentityOk, isTrue);
        expect(report.frameAccountingOk, isTrue);
        expect(report.seekOk, isTrue);
        expect(report.underrunGateOk, isTrue);
        expect(report.tailFlushOk, isTrue);
        expect(report.noUnderrunOk, isTrue);
        expect(report.noSilenceOk, isTrue);
        expect(report.zeroNativeSteadyStateAllocationOk, isTrue);
        expect(report.lifecycleOk, isTrue);

        // Metrics (20 metrics)
        expect(report.routedSourceCount, equals(1));
        expect(report.routedSourceId0, equals('node_owned_pipeline_src'));
        expect(report.nodeOwnsRing, isTrue);
        expect(report.totalFramesAccepted, equals(16513));
        expect(report.totalOutputFramesDrained, equals(16513));
        expect(report.providerUnderrunEvents, equals(0));
        expect(report.providerFramesZeroFilled, equals(0));
        expect(report.providerForwardSkipFrames, equals(0));
        expect(report.providerRewindRejects, equals(0));
        expect(report.coordinatorSilenceCount, equals(0));
        expect(report.dispatchCount, equals(66));
        expect(report.nativeAcceptedChecksumHex, equals(_kChecksumHex));
        expect(report.nativeOutputDrainChecksumHex, equals(_kChecksumHex));
        expect(report.kotlinAcceptedChecksumHex, equals(_kChecksumHex));
        expect(report.sourceAvailableReadFrames, equals(0));
        expect(report.outputAvailableReadFrames, equals(0));
        expect(report.schedulerTrackScratchCapacitySamples, equals(1024));
        expect(report.schedulerTrackScratchCapacityTracks, equals(4));
        expect(report.sourceRingStorageCapacitySamples, equals(16384));
        expect(report.outputRingStorageCapacitySamples, equals(8192));

        // Getters
        expect(report.checksumsMatch, isTrue);
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

        final roundTrip =
            VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(serialized);
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'status': 'checksum_identity_mismatch',
          'marker': _kFailMarker,
          'failureReason': 'checksum_identity_mismatch',
          'lastError': 'checksum_identity_mismatch',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.status, equals('checksum_identity_mismatch'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('checksum_identity_mismatch'));
      expect(report.lastError, equals('checksum_identity_mismatch'));
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
        final report = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
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
        expect(report.sourceAvailableReadFrames, equals(-1));
        expect(report.outputAvailableReadFrames, equals(-1));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw =
          VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap({
            'pass': true,
            'raw':
                'status=PASS;'
                'marker=$_kPassMarker;'
                'proofBoundary=$_kCanonicalProofBoundary;'
                'invalidCreateRejectedOk=true;'
                'routeDiscoveryOk=true;'
                'nodeOwnsRingOk=true;'
                'checksumIdentityOk=true;'
                'frameAccountingOk=true;'
                'seekOk=true;'
                'underrunGateOk=true;'
                'tailFlushOk=true;'
                'noUnderrunOk=true;'
                'noSilenceOk=true;'
                'zeroNativeSteadyStateAllocationOk=true;'
                'lifecycleOk=true;'
                'routedSourceCount=1;'
                'routedSourceId0=node_owned_pipeline_src;'
                'nodeOwnsRing=true;'
                'totalFramesAccepted=16513;'
                'totalOutputFramesDrained=16513;'
                'providerUnderrunEvents=0;'
                'providerFramesZeroFilled=0;'
                'providerForwardSkipFrames=0;'
                'providerRewindRejects=0;'
                'coordinatorSilenceCount=0;'
                'dispatchCount=66;'
                'nativeAcceptedChecksumHex=$_kChecksumHex;'
                'nativeOutputDrainChecksumHex=$_kChecksumHex;'
                'kotlinAcceptedChecksumHex=$_kChecksumHex;'
                'sourceAvailableReadFrames=0;'
                'outputAvailableReadFrames=0;'
                'schedulerTrackScratchCapacitySamples=1024;'
                'schedulerTrackScratchCapacityTracks=4;'
                'sourceRingStorageCapacitySamples=16384;'
                'outputRingStorageCapacitySamples=8192',
          });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.routeDiscoveryOk, isTrue);
      expect(reportFromRaw.nodeOwnsRingOk, isTrue);
      expect(reportFromRaw.routedSourceCount, equals(1));
      expect(reportFromRaw.routedSourceId0, equals('node_owned_pipeline_src'));
      expect(reportFromRaw.nodeOwnsRing, isTrue);
      expect(reportFromRaw.checksumsMatch, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });
  });

  group('allNativeLanesPass verification contract', () {
    test('requires proofBoundary to match canonical constant', () {
      final badBoundary =
          VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
            _createSampleRawMap({'proofBoundary': 'shortened_boundary'}),
          );
      expect(badBoundary.hasCanonicalProofBoundary, isFalse);
      expect(badBoundary.allNativeLanesPass, isFalse);
    });

    test('requires marker to match pass marker constant', () {
      final badMarker = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap({'marker': _kFailMarker}),
      );
      expect(badMarker.allNativeLanesPass, isFalse);
    });

    test('requires status to be pass', () {
      final badStatus = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap({'status': 'fail'}),
      );
      expect(badStatus.allNativeLanesPass, isFalse);
    });

    test('requires every lane boolean to be true', () {
      final laneKeys = [
        'invalidCreateRejectedOk',
        'routeDiscoveryOk',
        'nodeOwnsRingOk',
        'checksumIdentityOk',
        'frameAccountingOk',
        'seekOk',
        'underrunGateOk',
        'tailFlushOk',
        'noUnderrunOk',
        'noSilenceOk',
        'zeroNativeSteadyStateAllocationOk',
        'lifecycleOk',
      ];

      for (final lane in laneKeys) {
        final failingReport =
            VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
              _createSampleRawMap({lane: false}),
            );
        expect(
          failingReport.allNativeLanesPass,
          isFalse,
          reason: '$lane=false must cause allNativeLanesPass to be false',
        );
      }
    });

    test('requires routedSourceCount == 1', () {
      final report0 = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap({'routedSourceCount': 0}),
      );
      expect(report0.allNativeLanesPass, isFalse);

      final report2 = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap({'routedSourceCount': 2}),
      );
      expect(report2.allNativeLanesPass, isFalse);
    });

    test('requires routedSourceId0 == node_owned_pipeline_src', () {
      final report = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap({'routedSourceId0': 'wrong_source_id'}),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires nodeOwnsRing == true', () {
      final report = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap({'nodeOwnsRing': false}),
      );
      expect(report.allNativeLanesPass, isFalse);
    });

    test('requires checksumsMatch == true', () {
      final mismatchReport1 =
          VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
            _createSampleRawMap({
              'kotlinAcceptedChecksumHex': '0000000011111111',
              'nativeAcceptedChecksumHex': '0000000022222222',
            }),
          );
      expect(mismatchReport1.checksumsMatch, isFalse);
      expect(mismatchReport1.allNativeLanesPass, isFalse);

      final mismatchReport2 =
          VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
            _createSampleRawMap({
              'nativeAcceptedChecksumHex': '0000000011111111',
              'nativeOutputDrainChecksumHex': '0000000022222222',
            }),
          );
      expect(mismatchReport2.checksumsMatch, isFalse);
      expect(mismatchReport2.allNativeLanesPass, isFalse);

      final emptyChecksumReport =
          VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
            _createSampleRawMap({'kotlinAcceptedChecksumHex': ''}),
          );
      expect(emptyChecksumReport.checksumsMatch, isFalse);
      expect(emptyChecksumReport.allNativeLanesPass, isFalse);
    });

    test('requires frame accounting lockstep (accepted == drained > 0)', () {
      final reportMismatch =
          VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
            _createSampleRawMap({
              'totalFramesAccepted': 16513,
              'totalOutputFramesDrained': 16000,
            }),
          );
      expect(reportMismatch.allNativeLanesPass, isFalse);

      final reportZero = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap({
          'totalFramesAccepted': 0,
          'totalOutputFramesDrained': 0,
        }),
      );
      expect(reportZero.allNativeLanesPass, isFalse);
    });

    test('requires zero underruns, skips, rewinds, and silences', () {
      final metricChecks = {
        'providerUnderrunEvents': 1,
        'providerFramesZeroFilled': 1,
        'providerForwardSkipFrames': 1,
        'providerRewindRejects': 1,
        'coordinatorSilenceCount': 1,
      };

      for (final entry in metricChecks.entries) {
        final report = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
          _createSampleRawMap({entry.key: entry.value}),
        );
        expect(
          report.allNativeLanesPass,
          isFalse,
          reason: '${entry.key}=${entry.value} must fail allNativeLanesPass',
        );
      }
    });

    test('requires residual available read frames == 0 at snapshot', () {
      final reportSrc = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap({'sourceAvailableReadFrames': 10}),
      );
      expect(reportSrc.allNativeLanesPass, isFalse);

      final reportOut = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap({'outputAvailableReadFrames': 10}),
      );
      expect(reportOut.allNativeLanesPass, isFalse);
    });

    test('requires dispatchCount >= 50', () {
      final report49 = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap({'dispatchCount': 49}),
      );
      expect(report49.allNativeLanesPass, isFalse);

      final report50 = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap({'dispatchCount': 50}),
      );
      expect(report50.allNativeLanesPass, isTrue);
    });

    test('requires all four capacities > 0', () {
      final capacityKeys = [
        'schedulerTrackScratchCapacitySamples',
        'schedulerTrackScratchCapacityTracks',
        'sourceRingStorageCapacitySamples',
        'outputRingStorageCapacitySamples',
      ];

      for (final capKey in capacityKeys) {
        final reportZero =
            VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
              _createSampleRawMap({capKey: 0}),
            );
        expect(
          reportZero.allNativeLanesPass,
          isFalse,
          reason: '$capKey=0 must cause allNativeLanesPass to be false',
        );

        final reportNeg =
            VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
              _createSampleRawMap({capKey: -1}),
            );
        expect(
          reportNeg.allNativeLanesPass,
          isFalse,
          reason: '$capKey=-1 must cause allNativeLanesPass to be false',
        );
      }
    });
  });

  group('MethodChannel invocation wrapper', () {
    test('sends exact default arguments', () async {
      Map<String, Object?>? capturedArgs;
      String? capturedMethod;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedMethod = call.method;
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return _createSampleRawMap();
      });

      final report =
          await VGNodeOwnedAudioSourceGraphPipelineSmokeReport.runAndroidNodeOwnedAudioSourceGraphPipelineSmoke();

      expect(
        capturedMethod,
        equals('runAndroidNodeOwnedAudioSourceGraphPipelineSmoke'),
      );
      expect(
        capturedArgs,
        equals(<String, Object?>{
          'sampleRate': 48000,
          'channelCount': 2,
          'sourceRingCapacityFrames': 8192,
          'outputRingCapacityFrames': 4096,
          'maxFramesPerMix': 256,
          'preSeekWindows': 32,
          'postSeekWindows': 32,
          'deadlineMs': 30000,
        }),
      );
      expect(report.pass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('sends custom arguments and maps timeout to deadlineMs', () async {
      Map<String, Object?>? capturedArgs;
      String? capturedMethod;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedMethod = call.method;
        capturedArgs = (call.arguments as Map).cast<String, Object?>();
        return _createSampleRawMap();
      });

      final report =
          await VGNodeOwnedAudioSourceGraphPipelineSmokeReport.runAndroidNodeOwnedAudioSourceGraphPipelineSmoke(
            sampleRate: 44100,
            channelCount: 1,
            sourceRingCapacityFrames: 4096,
            outputRingCapacityFrames: 2048,
            maxFramesPerMix: 128,
            preSeekWindows: 16,
            postSeekWindows: 16,
            timeout: const Duration(seconds: 15),
          );

      expect(
        capturedMethod,
        equals('runAndroidNodeOwnedAudioSourceGraphPipelineSmoke'),
      );
      expect(
        capturedArgs,
        equals(<String, Object?>{
          'sampleRate': 44100,
          'channelCount': 1,
          'sourceRingCapacityFrames': 4096,
          'outputRingCapacityFrames': 2048,
          'maxFramesPerMix': 128,
          'preSeekWindows': 16,
          'postSeekWindows': 16,
          'deadlineMs': 15000,
        }),
      );
      expect(report.pass, isTrue);
    });

    test(
      'PlatformException produces fail report with canonical proof boundary and fail marker',
      () async {
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          throw PlatformException(
            code: 'P4_NODE_OWNED_SOURCE_PIPELINE_SMOKE_BUSY',
            message: 'runAndroidNodeOwnedAudioSourceGraphPipelineSmoke: busy',
          );
        });

        final report =
            await VGNodeOwnedAudioSourceGraphPipelineSmokeReport.runAndroidNodeOwnedAudioSourceGraphPipelineSmoke();

        expect(report.pass, isFalse);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.marker, equals(_kFailMarker));
        expect(
          report.failureReason,
          equals('platform_exception:P4_NODE_OWNED_SOURCE_PIPELINE_SMOKE_BUSY'),
        );
        expect(
          report.lastError,
          contains('P4_NODE_OWNED_SOURCE_PIPELINE_SMOKE_BUSY'),
        );
        expect(report.allNativeLanesPass, isFalse);
      },
    );

    test(
      'TimeoutException produces fail report with canonical proof boundary and fail marker',
      () async {
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return _createSampleRawMap();
        });

        final report =
            await VGNodeOwnedAudioSourceGraphPipelineSmokeReport.runAndroidNodeOwnedAudioSourceGraphPipelineSmoke(
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
            await VGNodeOwnedAudioSourceGraphPipelineSmokeReport.runAndroidNodeOwnedAudioSourceGraphPipelineSmoke(
              channel: const _ThrowingMethodChannel('test_throwing'),
            );

        expect(report.pass, isFalse);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.marker, equals(_kFailMarker));
        expect(report.failureReason, startsWith('exception:'));
        expect(report.lastError, contains('simulated non-platform exception'));
        expect(report.allNativeLanesPass, isFalse);
      },
    );
  });

  group('Equality, hashCode, and toString', () {
    test('equal reports compare equal and have identical hashCode', () {
      final reportA = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap(),
      );
      final reportB = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap(),
      );

      expect(reportA, equals(reportB));
      expect(reportA.hashCode, equals(reportB.hashCode));
      expect(reportA.toString(), equals(reportB.toString()));
      expect(
        reportA.toString(),
        contains('VGNodeOwnedAudioSourceGraphPipelineSmokeReport('),
      );
    });

    test('different reports do not compare equal', () {
      final reportA = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap({'totalFramesAccepted': 16513}),
      );
      final reportB = VGNodeOwnedAudioSourceGraphPipelineSmokeReport.fromMap(
        _createSampleRawMap({'totalFramesAccepted': 20000}),
      );

      expect(reportA, isNot(equals(reportB)));
    });
  });
}
