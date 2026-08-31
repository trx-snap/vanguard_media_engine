// vg_audio_graph_pipeline_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice H1: Android True-DAG Phase 4
// session-scoped closed-loop native audio graph pipeline Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'kotlin_owned_synthetic_pcm_step_driven_closed_loop_native_audio_graph_pipeline_session_proof_only_no_mediacodec_no_mediaextractor_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audio_track_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_diagnostic_graph_topology_only_no_production_source_node_wiring_no_source_node_pcm_ingest_topology_anchor_only_single_routed_track_unit_gain_only_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim';

const _kPassMarker = 'ANDROID_DAG_PHASE4_AUDIO_GRAPH_PIPELINE_SMOKE_PASS';
const _kFailMarker = 'ANDROID_DAG_PHASE4_AUDIO_GRAPH_PIPELINE_SMOKE_FAIL';
const _kChecksumHex = '0000000012345678';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'sourcePartialWriteObserved': true,
    'sourceRingFullObserved': true,
    'outputBackpressureObserved': true,
    'checksumIdentityOk': true,
    'frameAccountingOk': true,
    'seekOk': true,
    'tailFlushOk': true,
    'noUnderrunOk': true,
    'noSilenceOk': true,
    'zeroNativeSteadyStateAllocationOk': true,
    'noRingPushShortfallOk': true,
    'ownerThreadOk': true,
    'lifecycleOk': true,
    'canonical': true,
  };

  final metrics = <String, Object?>{
    'totalFramesAccepted': 16384,
    'totalOutputFramesDrained': 16384,
    'postSeekFramesAccepted': 12288,
    'providerUnderrunEvents': 0,
    'providerFramesZeroFilled': 0,
    'coordinatorSilenceCount': 0,
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeOutputDrainChecksumHex': _kChecksumHex,
    'kotlinAcceptedChecksumHex': _kChecksumHex,
    'maxFramesPerMix': 256,
    'sourceAvailableReadFrames': 0,
    'outputAvailableReadFrames': 0,
    'dispatchCount': 64,
  };

  final raw = <String, String>{
    'status': 'PASS',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'preSeekWindows=16|postSeekIdentityWindows=48|backpressureWindows=16|tailFrames=129|finalNextFrame=16384',
    'totalFramesAccepted': '16384',
    'totalOutputFramesDrained': '16384',
    'postSeekFramesAccepted': '12288',
    'providerUnderrunEvents': '0',
    'providerFramesZeroFilled': '0',
    'coordinatorSilenceCount': '0',
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeOutputDrainChecksumHex': _kChecksumHex,
    'kotlinAcceptedChecksumHex': _kChecksumHex,
    'maxFramesPerMix': '256',
    'sourceAvailableReadFrames': '0',
    'outputAvailableReadFrames': '0',
    'dispatchCount': '64',
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'preSeekWindows=16|postSeekIdentityWindows=48|backpressureWindows=16|tailFrames=129|finalNextFrame=16384',
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

VGAudioGraphPipelineSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGAudioGraphPipelineSmokeReport.fromMap(_createSampleRawMap(overrides));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGAudioGraphPipelineSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGAudioGraphPipelineSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.pass, isTrue);
        expect(report.status, equals('pass'));
        expect(report.marker, equals(_kPassMarker));
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.failureReason, isEmpty);
        expect(report.lastError, isEmpty);
        expect(report.details, contains('preSeekWindows=16'));

        // Lanes
        expect(report.sourcePartialWriteObserved, isTrue);
        expect(report.sourceRingFullObserved, isTrue);
        expect(report.outputBackpressureObserved, isTrue);
        expect(report.checksumIdentityOk, isTrue);
        expect(report.frameAccountingOk, isTrue);
        expect(report.seekOk, isTrue);
        expect(report.tailFlushOk, isTrue);
        expect(report.noUnderrunOk, isTrue);
        expect(report.noSilenceOk, isTrue);
        expect(report.zeroNativeSteadyStateAllocationOk, isTrue);
        expect(report.noRingPushShortfallOk, isTrue);
        expect(report.ownerThreadOk, isTrue);
        expect(report.lifecycleOk, isTrue);
        expect(report.canonical, isTrue);

        // Metrics
        expect(report.totalFramesAccepted, equals(16384));
        expect(report.totalOutputFramesDrained, equals(16384));
        expect(report.postSeekFramesAccepted, equals(12288));
        expect(report.providerUnderrunEvents, equals(0));
        expect(report.providerFramesZeroFilled, equals(0));
        expect(report.coordinatorSilenceCount, equals(0));
        expect(report.nativeAcceptedChecksumHex, equals(_kChecksumHex));
        expect(report.nativeOutputDrainChecksumHex, equals(_kChecksumHex));
        expect(report.kotlinAcceptedChecksumHex, equals(_kChecksumHex));
        expect(report.maxFramesPerMix, equals(256));
        expect(report.sourceAvailableReadFrames, equals(0));
        expect(report.outputAvailableReadFrames, equals(0));
        expect(report.dispatchCount, equals(64));

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

        final roundTrip = VGAudioGraphPipelineSmokeReport.fromMap(serialized);
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAudioGraphPipelineSmokeReport.fromMap(
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
        final report = VGAudioGraphPipelineSmokeReport.fromMap(invalid);
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
      final reportFromRaw = VGAudioGraphPipelineSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'marker=$_kPassMarker;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'sourcePartialWriteObserved=true;'
            'sourceRingFullObserved=true;'
            'outputBackpressureObserved=true;'
            'checksumIdentityOk=true;'
            'frameAccountingOk=true;'
            'seekOk=true;'
            'tailFlushOk=true;'
            'noUnderrunOk=true;'
            'noSilenceOk=true;'
            'zeroNativeSteadyStateAllocationOk=true;'
            'noRingPushShortfallOk=true;'
            'ownerThreadOk=true;'
            'lifecycleOk=true;'
            'canonical=true;'
            'totalFramesAccepted=16384;'
            'totalOutputFramesDrained=16384;'
            'postSeekFramesAccepted=12288;'
            'providerUnderrunEvents=0;'
            'providerFramesZeroFilled=0;'
            'coordinatorSilenceCount=0;'
            'nativeAcceptedChecksumHex=$_kChecksumHex;'
            'nativeOutputDrainChecksumHex=$_kChecksumHex;'
            'kotlinAcceptedChecksumHex=$_kChecksumHex;'
            'maxFramesPerMix=256;'
            'sourceAvailableReadFrames=0;'
            'outputAvailableReadFrames=0;'
            'dispatchCount=64',
        'lanes': const <String, Object?>{},
        'metrics': const <String, Object?>{},
      });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.sourcePartialWriteObserved, isTrue);
      expect(reportFromRaw.sourceRingFullObserved, isTrue);
      expect(reportFromRaw.outputBackpressureObserved, isTrue);
      expect(reportFromRaw.checksumIdentityOk, isTrue);
      expect(reportFromRaw.frameAccountingOk, isTrue);
      expect(reportFromRaw.seekOk, isTrue);
      expect(reportFromRaw.tailFlushOk, isTrue);
      expect(reportFromRaw.noUnderrunOk, isTrue);
      expect(reportFromRaw.noSilenceOk, isTrue);
      expect(reportFromRaw.zeroNativeSteadyStateAllocationOk, isTrue);
      expect(reportFromRaw.noRingPushShortfallOk, isTrue);
      expect(reportFromRaw.ownerThreadOk, isTrue);
      expect(reportFromRaw.lifecycleOk, isTrue);
      expect(reportFromRaw.canonical, isTrue);
      expect(reportFromRaw.totalFramesAccepted, equals(16384));
      expect(reportFromRaw.totalOutputFramesDrained, equals(16384));
      expect(reportFromRaw.postSeekFramesAccepted, equals(12288));
      expect(reportFromRaw.providerUnderrunEvents, equals(0));
      expect(reportFromRaw.providerFramesZeroFilled, equals(0));
      expect(reportFromRaw.coordinatorSilenceCount, equals(0));
      expect(reportFromRaw.nativeAcceptedChecksumHex, equals(_kChecksumHex));
      expect(reportFromRaw.nativeOutputDrainChecksumHex, equals(_kChecksumHex));
      expect(reportFromRaw.kotlinAcceptedChecksumHex, equals(_kChecksumHex));
      expect(reportFromRaw.maxFramesPerMix, equals(256));
      expect(reportFromRaw.dispatchCount, equals(64));
      expect(reportFromRaw.checksumsMatch, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in lanes and metrics', () {
      final report = VGAudioGraphPipelineSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'lanes': const <String, Object?>{
          'sourcePartialWriteObserved': 'true',
          'sourceRingFullObserved': 'pass',
          'outputBackpressureObserved': 'ok',
          'checksumIdentityOk': 'success',
          'frameAccountingOk': 'false',
        },
      });

      expect(report.sourcePartialWriteObserved, isTrue);
      expect(report.sourceRingFullObserved, isTrue);
      expect(report.outputBackpressureObserved, isTrue);
      expect(report.checksumIdentityOk, isTrue);
      expect(report.frameAccountingOk, isFalse);
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
        _createSampleReport({'kotlinAcceptedChecksumHex': ''}).checksumsMatch,
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

      // All 14 lanes
      expect(
        _createSampleReport({
          'sourcePartialWriteObserved': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'sourceRingFullObserved': false,
        }).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'outputBackpressureObserved': false,
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
        _createSampleReport({'noUnderrunOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'noSilenceOk': false}).allNativeLanesPass,
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
          'noRingPushShortfallOk': false,
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

      // Positive metrics
      expect(
        _createSampleReport({'totalFramesAccepted': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'totalOutputFramesDrained': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'postSeekFramesAccepted': 0}).allNativeLanesPass,
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
  });

  group('Value semantics: equality, hashCode, toString', () {
    test('identical instances and identical values evaluate equal', () {
      final a = _createSampleReport();
      final b = _createSampleReport();

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGAudioGraphPipelineSmokeReport('));
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
        {'sourcePartialWriteObserved': false},
        {'sourceRingFullObserved': false},
        {'outputBackpressureObserved': false},
        {'checksumIdentityOk': false},
        {'frameAccountingOk': false},
        {'seekOk': false},
        {'tailFlushOk': false},
        {'noUnderrunOk': false},
        {'noSilenceOk': false},
        {'zeroNativeSteadyStateAllocationOk': false},
        {'noRingPushShortfallOk': false},
        {'ownerThreadOk': false},
        {'lifecycleOk': false},
        {'canonical': false},
        {'totalFramesAccepted': 999},
        {'totalOutputFramesDrained': 999},
        {'postSeekFramesAccepted': 111},
        {'providerUnderrunEvents': 5},
        {'providerFramesZeroFilled': 5},
        {'coordinatorSilenceCount': 5},
        {'nativeAcceptedChecksumHex': 'diff'},
        {'nativeOutputDrainChecksumHex': 'diff'},
        {'kotlinAcceptedChecksumHex': 'diff'},
        {'maxFramesPerMix': 512},
        {'sourceAvailableReadFrames': 42},
        {'outputAvailableReadFrames': 42},
        {'dispatchCount': 100},
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

  group('MethodChannel wrapper: runAndroidDagPhase4AudioGraphPipelineSmoke', () {
    test(
      'invokes runAndroidDagPhase4AudioGraphPipelineSmoke with correct default args on default channel',
      () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGAudioGraphPipelineSmokeReport.runAndroidDagPhase4AudioGraphPipelineSmoke();

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase4AudioGraphPipelineSmoke'),
        );
        expect(
          capturedCall!.arguments,
          equals(<String, Object?>{
            'sampleRate': 48000,
            'channelCount': 2,
            'sourceRingCapacityFrames': 8192,
            'outputRingCapacityFrames': 4096,
            'maxFramesPerMix': 256,
            'windowCount': 64,
            'seekTargetFrame': 4096,
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
        'custom_audio_graph_pipeline_channel',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGAudioGraphPipelineSmokeReport.runAndroidDagPhase4AudioGraphPipelineSmoke(
            sampleRate: 44100,
            channelCount: 1,
            sourceRingCapacityFrames: 16384,
            outputRingCapacityFrames: 8192,
            maxFramesPerMix: 128,
            windowCount: 128,
            seekTargetFrame: 8192,
            timeout: const Duration(seconds: 45),
            channel: customChannel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('runAndroidDagPhase4AudioGraphPipelineSmoke'),
      );
      expect(
        capturedCall!.arguments,
        equals(<String, Object?>{
          'sampleRate': 44100,
          'channelCount': 1,
          'sourceRingCapacityFrames': 16384,
          'outputRingCapacityFrames': 8192,
          'maxFramesPerMix': 128,
          'windowCount': 128,
          'seekTargetFrame': 8192,
          'deadlineMs': 45000,
        }),
      );
      expect(report.pass, isTrue);
    });

    test('handles PlatformException by returning fallback report', () async {
      const errorChannel = MethodChannel('error_audio_graph_pipeline_channel');
      binaryMessenger.setMockMethodCallHandler(errorChannel, (call) async {
        throw PlatformException(
          code: 'P4_AUDIO_GRAPH_PIPELINE_SMOKE_BUSY',
          message: 'AudioGraphPipeline diagnostic already running',
        );
      });

      final report =
          await VGAudioGraphPipelineSmokeReport.runAndroidDagPhase4AudioGraphPipelineSmoke(
            channel: errorChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.marker, equals(_kFailMarker));
      expect(report.allNativeLanesPass, isFalse);
      expect(
        report.lastError,
        contains(
          'platform_exception:P4_AUDIO_GRAPH_PIPELINE_SMOKE_BUSY:AudioGraphPipeline diagnostic already running',
        ),
      );
    });

    test('handles TimeoutException by returning fallback report', () async {
      const slowChannel = MethodChannel('slow_audio_graph_pipeline_channel');
      binaryMessenger.setMockMethodCallHandler(slowChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });

      final report =
          await VGAudioGraphPipelineSmokeReport.runAndroidDagPhase4AudioGraphPipelineSmoke(
            timeout: const Duration(milliseconds: 20),
            channel: slowChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.marker, equals(_kFailMarker));
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('timeout'));
    });

    test('handles generic Exception by returning fallback report', () async {
      const exChannel = MethodChannel('ex_audio_graph_pipeline_channel');
      binaryMessenger.setMockMethodCallHandler(exChannel, (call) async {
        throw Exception('Native audio pipeline crashed');
      });

      final report =
          await VGAudioGraphPipelineSmokeReport.runAndroidDagPhase4AudioGraphPipelineSmoke(
            channel: exChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.marker, equals(_kFailMarker));
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('Native audio pipeline crashed'));
    });
  });
}
