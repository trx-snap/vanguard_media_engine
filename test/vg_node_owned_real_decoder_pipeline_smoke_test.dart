// vg_node_owned_real_decoder_pipeline_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REAL-DECODER-NODE-OWNED-PIPELINE: Android True-DAG Phase 4
// real MediaExtractor/MediaCodec decoder node-owned audio source closed-loop native audio graph pipeline Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'kotlin_owned_real_decoder_to_node_owned_decoded_audio_source_graph_pipeline_proof_only_source_node_owns_ring_writer_provider_by_composition_scheduler_auto_discovers_provider_from_graph_topology_kotlin_owns_mediaextractor_mediacodec_and_temp_media_path_only_no_cpp_os_decoder_ownership_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_no_native_worker_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_destroy_idempotent_any_thread_native_frame_axis_is_accepted_frame_count_not_media_pts_seek_reanchors_at_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_no_audio_track_no_aaudio_no_opensl_no_oboe_no_audible_no_speaker_no_latency_no_glitch_no_realtime_av_sync_no_audio_focus_no_route_no_dead_object_recovery_claims_no_production_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_streaming_no_cache_no_ios_single_routed_track_unit_gain_only_no_resample_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_NODE_OWNED_REAL_DECODER_PIPELINE_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_NODE_OWNED_REAL_DECODER_PIPELINE_SMOKE_FAIL';
const _kChecksumHex = '0000000012345678';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'formatProbeOk': true,
    'decoderBenignFormatChangeObserved': true,
    'decoderEosReachedOk': true,
    'routeDiscoveryOk': true,
    'nodeOwnsRingOk': true,
    'checksumIdentityOk': true,
    'frameAccountingOk': true,
    'seekOk': true,
    'tailFlushOk': true,
    'noUnderrunOk': true,
    'noSilenceOk': true,
    'noForwardSkipOk': true,
    'noRewindRejectOk': true,
    'finalNotTerminalOk': true,
    'finalSeekAckClearOk': true,
    'zeroNativeSteadyStateAllocationOk': true,
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
    'postSeekFramesAccepted': 12288,
    'postSeekFramesDrained': 12288,
    'decoderBenignFormatChangeCount': 1,
    'providerUnderrunEvents': 0,
    'providerFramesZeroFilled': 0,
    'providerForwardSkipFrames': 0,
    'providerRewindRejects': 0,
    'coordinatorSilenceCount': 0,
    'dispatchCount': 64,
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeOutputDrainChecksumHex': _kChecksumHex,
    'kotlinAcceptedChecksumHex': _kChecksumHex,
    'maxFramesPerMix': 256,
    'sourceAvailableReadFrames': 0,
    'outputAvailableReadFrames': 0,
    'nextDispatchFrame': 16384,
  };

  final raw = <String, String>{
    'status': 'PASS',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'sampleRate=48000|channels=2|preSeekAccepted=4096|postSeekAccepted=12288|tailFrames=129',
    'formatProbeOk': 'true',
    'decoderBenignFormatChangeObserved': 'true',
    'decoderEosReachedOk': 'true',
    'routeDiscoveryOk': 'true',
    'nodeOwnsRingOk': 'true',
    'checksumIdentityOk': 'true',
    'frameAccountingOk': 'true',
    'seekOk': 'true',
    'tailFlushOk': 'true',
    'noUnderrunOk': 'true',
    'noSilenceOk': 'true',
    'noForwardSkipOk': 'true',
    'noRewindRejectOk': 'true',
    'finalNotTerminalOk': 'true',
    'finalSeekAckClearOk': 'true',
    'zeroNativeSteadyStateAllocationOk': 'true',
    'lifecycleOk': 'true',
    'canonical': 'true',
    'sampleRate': '48000',
    'channelCount': '2',
    'pcmEncoding': '2',
    'expectedFrameCount': '480000',
    'totalFramesExtracted': '16384',
    'totalFramesAccepted': '16384',
    'totalOutputFramesDrained': '16384',
    'postSeekFramesAccepted': '12288',
    'postSeekFramesDrained': '12288',
    'decoderBenignFormatChangeCount': '1',
    'providerUnderrunEvents': '0',
    'providerFramesZeroFilled': '0',
    'providerForwardSkipFrames': '0',
    'providerRewindRejects': '0',
    'coordinatorSilenceCount': '0',
    'dispatchCount': '64',
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeOutputDrainChecksumHex': _kChecksumHex,
    'kotlinAcceptedChecksumHex': _kChecksumHex,
    'maxFramesPerMix': '256',
    'sourceAvailableReadFrames': '0',
    'outputAvailableReadFrames': '0',
    'nextDispatchFrame': '16384',
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'sampleRate=48000|channels=2|preSeekAccepted=4096|postSeekAccepted=12288|tailFrames=129',
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

VGNodeOwnedRealDecoderPipelineSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGNodeOwnedRealDecoderPipelineSmokeReport.fromMap(
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

  group('VGNodeOwnedRealDecoderPipelineSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGNodeOwnedRealDecoderPipelineSmokeReport.fromMap(
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

        // Lanes (18 lanes: 17 hard + 1 benign)
        expect(report.formatProbeOk, isTrue);
        expect(report.decoderBenignFormatChangeObserved, isTrue);
        expect(report.decoderEosReachedOk, isTrue);
        expect(report.routeDiscoveryOk, isTrue);
        expect(report.nodeOwnsRingOk, isTrue);
        expect(report.checksumIdentityOk, isTrue);
        expect(report.frameAccountingOk, isTrue);
        expect(report.seekOk, isTrue);
        expect(report.tailFlushOk, isTrue);
        expect(report.noUnderrunOk, isTrue);
        expect(report.noSilenceOk, isTrue);
        expect(report.noForwardSkipOk, isTrue);
        expect(report.noRewindRejectOk, isTrue);
        expect(report.finalNotTerminalOk, isTrue);
        expect(report.finalSeekAckClearOk, isTrue);
        expect(report.zeroNativeSteadyStateAllocationOk, isTrue);
        expect(report.lifecycleOk, isTrue);
        expect(report.canonical, isTrue);

        // Metrics (23 metrics)
        expect(report.sampleRate, equals(48000));
        expect(report.channelCount, equals(2));
        expect(report.pcmEncoding, equals(2));
        expect(report.expectedFrameCount, equals(480000));
        expect(report.totalFramesExtracted, equals(16384));
        expect(report.totalFramesAccepted, equals(16384));
        expect(report.totalOutputFramesDrained, equals(16384));
        expect(report.postSeekFramesAccepted, equals(12288));
        expect(report.postSeekFramesDrained, equals(12288));
        expect(report.decoderBenignFormatChangeCount, equals(1));
        expect(report.providerUnderrunEvents, equals(0));
        expect(report.providerFramesZeroFilled, equals(0));
        expect(report.providerForwardSkipFrames, equals(0));
        expect(report.providerRewindRejects, equals(0));
        expect(report.coordinatorSilenceCount, equals(0));
        expect(report.dispatchCount, equals(64));
        expect(report.nativeAcceptedChecksumHex, equals(_kChecksumHex));
        expect(report.nativeOutputDrainChecksumHex, equals(_kChecksumHex));
        expect(report.kotlinAcceptedChecksumHex, equals(_kChecksumHex));
        expect(report.maxFramesPerMix, equals(256));
        expect(report.sourceAvailableReadFrames, equals(0));
        expect(report.outputAvailableReadFrames, equals(0));
        expect(report.nextDispatchFrame, equals(16384));

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

        final roundTrip = VGNodeOwnedRealDecoderPipelineSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGNodeOwnedRealDecoderPipelineSmokeReport.fromMap(
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
        final report = VGNodeOwnedRealDecoderPipelineSmokeReport.fromMap(
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
        expect(report.nextDispatchFrame, equals(-1));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw = VGNodeOwnedRealDecoderPipelineSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'marker=$_kPassMarker;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'formatProbeOk=true;'
            'decoderBenignFormatChangeObserved=false;'
            'decoderEosReachedOk=true;'
            'routeDiscoveryOk=true;'
            'nodeOwnsRingOk=true;'
            'checksumIdentityOk=true;'
            'frameAccountingOk=true;'
            'seekOk=true;'
            'tailFlushOk=true;'
            'noUnderrunOk=true;'
            'noSilenceOk=true;'
            'noForwardSkipOk=true;'
            'noRewindRejectOk=true;'
            'finalNotTerminalOk=true;'
            'finalSeekAckClearOk=true;'
            'zeroNativeSteadyStateAllocationOk=true;'
            'lifecycleOk=true;'
            'canonical=true;'
            'sampleRate=48000;'
            'channelCount=2;'
            'pcmEncoding=2;'
            'expectedFrameCount=480000;'
            'totalFramesExtracted=16384;'
            'totalFramesAccepted=16384;'
            'totalOutputFramesDrained=16384;'
            'postSeekFramesAccepted=12288;'
            'postSeekFramesDrained=12288;'
            'decoderBenignFormatChangeCount=0;'
            'providerUnderrunEvents=0;'
            'providerFramesZeroFilled=0;'
            'providerForwardSkipFrames=0;'
            'providerRewindRejects=0;'
            'coordinatorSilenceCount=0;'
            'dispatchCount=64;'
            'nativeAcceptedChecksumHex=$_kChecksumHex;'
            'nativeOutputDrainChecksumHex=$_kChecksumHex;'
            'kotlinAcceptedChecksumHex=$_kChecksumHex;'
            'maxFramesPerMix=256;'
            'sourceAvailableReadFrames=0;'
            'outputAvailableReadFrames=0;'
            'nextDispatchFrame=16384',
        'lanes': const <String, Object?>{},
        'metrics': const <String, Object?>{},
      });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.formatProbeOk, isTrue);
      expect(reportFromRaw.decoderBenignFormatChangeObserved, isFalse);
      expect(reportFromRaw.decoderEosReachedOk, isTrue);
      expect(reportFromRaw.routeDiscoveryOk, isTrue);
      expect(reportFromRaw.nodeOwnsRingOk, isTrue);
      expect(reportFromRaw.checksumIdentityOk, isTrue);
      expect(reportFromRaw.frameAccountingOk, isTrue);
      expect(reportFromRaw.seekOk, isTrue);
      expect(reportFromRaw.tailFlushOk, isTrue);
      expect(reportFromRaw.noUnderrunOk, isTrue);
      expect(reportFromRaw.noSilenceOk, isTrue);
      expect(reportFromRaw.noForwardSkipOk, isTrue);
      expect(reportFromRaw.noRewindRejectOk, isTrue);
      expect(reportFromRaw.finalNotTerminalOk, isTrue);
      expect(reportFromRaw.finalSeekAckClearOk, isTrue);
      expect(reportFromRaw.zeroNativeSteadyStateAllocationOk, isTrue);
      expect(reportFromRaw.lifecycleOk, isTrue);
      expect(reportFromRaw.canonical, isTrue);
      expect(reportFromRaw.sampleRate, equals(48000));
      expect(reportFromRaw.channelCount, equals(2));
      expect(reportFromRaw.pcmEncoding, equals(2));
      expect(reportFromRaw.expectedFrameCount, equals(480000));
      expect(reportFromRaw.totalFramesExtracted, equals(16384));
      expect(reportFromRaw.totalFramesAccepted, equals(16384));
      expect(reportFromRaw.totalOutputFramesDrained, equals(16384));
      expect(reportFromRaw.postSeekFramesAccepted, equals(12288));
      expect(reportFromRaw.postSeekFramesDrained, equals(12288));
      expect(reportFromRaw.providerUnderrunEvents, equals(0));
      expect(reportFromRaw.providerFramesZeroFilled, equals(0));
      expect(reportFromRaw.providerForwardSkipFrames, equals(0));
      expect(reportFromRaw.providerRewindRejects, equals(0));
      expect(reportFromRaw.coordinatorSilenceCount, equals(0));
      expect(reportFromRaw.dispatchCount, equals(64));
      expect(reportFromRaw.nativeAcceptedChecksumHex, equals(_kChecksumHex));
      expect(reportFromRaw.nativeOutputDrainChecksumHex, equals(_kChecksumHex));
      expect(reportFromRaw.kotlinAcceptedChecksumHex, equals(_kChecksumHex));
      expect(reportFromRaw.maxFramesPerMix, equals(256));
      expect(reportFromRaw.sourceAvailableReadFrames, equals(0));
      expect(reportFromRaw.outputAvailableReadFrames, equals(0));
      expect(reportFromRaw.nextDispatchFrame, equals(16384));
      expect(reportFromRaw.checksumsMatch, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in lanes and metrics', () {
      final report = VGNodeOwnedRealDecoderPipelineSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'lanes': const <String, Object?>{
          'formatProbeOk': 'true',
          'decoderEosReachedOk': 'pass',
          'routeDiscoveryOk': 'ok',
          'nodeOwnsRingOk': 'success',
          'checksumIdentityOk': 'false',
        },
      });

      expect(report.formatProbeOk, isTrue);
      expect(report.decoderEosReachedOk, isTrue);
      expect(report.routeDiscoveryOk, isTrue);
      expect(report.nodeOwnsRingOk, isTrue);
      expect(report.checksumIdentityOk, isFalse);
    });

    test('nested lane and metric precedence over top-level or raw fields', () {
      final report = VGNodeOwnedRealDecoderPipelineSmokeReport.fromMap({
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

    test(
      'missing optional decoderBenignFormatChangeObserved remains pass-capable',
      () {
        final reportWithoutFormatChange = _createSampleReport({
          'decoderBenignFormatChangeObserved': false,
          'decoderBenignFormatChangeCount': 0,
        });

        expect(
          reportWithoutFormatChange.decoderBenignFormatChangeObserved,
          isFalse,
        );
        expect(
          reportWithoutFormatChange.decoderBenignFormatChangeCount,
          equals(0),
        );
        expect(reportWithoutFormatChange.allNativeLanesPass, isTrue);
      },
    );
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

      // Hard lanes that must be true
      expect(
        _createSampleReport({'formatProbeOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'decoderEosReachedOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'routeDiscoveryOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'nodeOwnsRingOk': false}).allNativeLanesPass,
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
        _createSampleReport({'lifecycleOk': false}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'canonical': false}).allNativeLanesPass,
        isFalse,
      );

      // Note: decoderBenignFormatChangeObserved being false does NOT fail allNativeLanesPass
      expect(
        _createSampleReport({
          'decoderBenignFormatChangeObserved': false,
        }).allNativeLanesPass,
        isTrue,
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

      // Total accepted == drained lockstep
      expect(
        _createSampleReport({
          'totalFramesAccepted': 16384,
          'totalOutputFramesDrained': 16000,
        }).allNativeLanesPass,
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
        contains('VGNodeOwnedRealDecoderPipelineSmokeReport('),
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
        {'decoderBenignFormatChangeObserved': false},
        {'decoderEosReachedOk': false},
        {'routeDiscoveryOk': false},
        {'nodeOwnsRingOk': false},
        {'checksumIdentityOk': false},
        {'frameAccountingOk': false},
        {'seekOk': false},
        {'tailFlushOk': false},
        {'noUnderrunOk': false},
        {'noSilenceOk': false},
        {'noForwardSkipOk': false},
        {'noRewindRejectOk': false},
        {'finalNotTerminalOk': false},
        {'finalSeekAckClearOk': false},
        {'zeroNativeSteadyStateAllocationOk': false},
        {'lifecycleOk': false},
        {'canonical': false},
        {'sampleRate': 44100},
        {'channelCount': 1},
        {'pcmEncoding': 1},
        {'expectedFrameCount': 99999},
        {'totalFramesExtracted': 999},
        {'totalFramesAccepted': 999},
        {'totalOutputFramesDrained': 999},
        {'postSeekFramesAccepted': 111},
        {'postSeekFramesDrained': 111},
        {'decoderBenignFormatChangeCount': 9},
        {'providerUnderrunEvents': 5},
        {'providerFramesZeroFilled': 5},
        {'providerForwardSkipFrames': 5},
        {'providerRewindRejects': 5},
        {'coordinatorSilenceCount': 5},
        {'dispatchCount': 100},
        {'nativeAcceptedChecksumHex': 'diff'},
        {'nativeOutputDrainChecksumHex': 'diff'},
        {'kotlinAcceptedChecksumHex': 'diff'},
        {'maxFramesPerMix': 512},
        {'sourceAvailableReadFrames': 42},
        {'outputAvailableReadFrames': 42},
        {'nextDispatchFrame': 999},
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
    'MethodChannel wrapper: runAndroidNodeOwnedAudioSourceRealDecoderPipelineSmoke',
    () {
      test(
        'invokes runAndroidNodeOwnedAudioSourceRealDecoderPipelineSmoke with correct default args on default channel',
        () async {
          MethodCall? capturedCall;
          binaryMessenger.setMockMethodCallHandler(defaultChannel, (
            call,
          ) async {
            capturedCall = call;
            return _createSampleRawMap();
          });

          final report =
              await VGNodeOwnedRealDecoderPipelineSmokeReport.runAndroidNodeOwnedAudioSourceRealDecoderPipelineSmoke(
                sourcePath: '/path/to/test/clip_B.mov',
              );

          expect(capturedCall, isNotNull);
          expect(
            capturedCall!.method,
            equals('runAndroidNodeOwnedAudioSourceRealDecoderPipelineSmoke'),
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
          'custom_node_owned_real_decoder_pipeline_channel',
        );
        binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGNodeOwnedRealDecoderPipelineSmokeReport.runAndroidNodeOwnedAudioSourceRealDecoderPipelineSmoke(
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
          equals('runAndroidNodeOwnedAudioSourceRealDecoderPipelineSmoke'),
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
              code: 'P4_NODE_OWNED_REAL_DECODER_PIPELINE_SMOKE_BUSY',
              message:
                  'runAndroidNodeOwnedAudioSourceRealDecoderPipelineSmoke: busy',
            );
          });

          final report =
              await VGNodeOwnedRealDecoderPipelineSmokeReport.runAndroidNodeOwnedAudioSourceRealDecoderPipelineSmoke(
                sourcePath: '/path/to/test.mov',
              );

          expect(report.pass, isFalse);
          expect(report.hasCanonicalProofBoundary, isTrue);
          expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
          expect(report.marker, equals(_kFailMarker));
          expect(
            report.failureReason,
            equals(
              'platform_exception:P4_NODE_OWNED_REAL_DECODER_PIPELINE_SMOKE_BUSY',
            ),
          );
          expect(
            report.lastError,
            contains('P4_NODE_OWNED_REAL_DECODER_PIPELINE_SMOKE_BUSY'),
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
              await VGNodeOwnedRealDecoderPipelineSmokeReport.runAndroidNodeOwnedAudioSourceRealDecoderPipelineSmoke(
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
              await VGNodeOwnedRealDecoderPipelineSmokeReport.runAndroidNodeOwnedAudioSourceRealDecoderPipelineSmoke(
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
