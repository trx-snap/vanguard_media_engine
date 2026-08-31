// vg_audio_decoder_ring_ingest_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice G3: Android True-DAG Phase 4
// native audio decoder ring ingest Dart model and MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'kotlin_owned_mediacodec_mediaextractor_streaming_decode_to_jni_decoder_ring_ingest_proof_only_no_cpp_os_decoder_no_mediacodec_or_mediaextractor_ownership_in_cpp_no_cpp_file_io_no_wall_clock_read_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audio_track_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_no_graph_scheduler_no_mix_bus_no_coordinator_no_closed_loop_sink_no_source_node_wiring_no_resample_no_downmix_channels_1_or_2_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_writer_local_eos_only_native_zero_steady_state_allocation_only_jvm_heap_non_claim';

const _kPassMarker = 'ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_INGEST_SMOKE_PASS';
const _kFailMarker = 'ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_INGEST_SMOKE_FAIL';
const _kChecksumHex = '0000000012345678';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final metrics = <String, Object?>{
    'sampleRate': 48000,
    'channelCount': 2,
    'pcmEncoding': 2,
    'totalFramesAccepted': 48000,
    'totalFramesDrained': 48000,
    'postSeekFramesAccepted': 24000,
    'postSeekFramesDrained': 24000,
    'kotlinAcceptedChecksumHex': _kChecksumHex,
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeDrainedChecksumHex': _kChecksumHex,
    'observedPartialWrite': true,
    'observedRingFull': true,
    'syntheticProbeChunk': true,
    'midStreamFormatChangeRejected': true,
    'seekAckObserved': true,
    'discardedFramesOnSeek': 0,
    'newStartFrame': 16800,
  };

  final raw = <String, String>{
    'status': 'PASS',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'preSeekDrainIterations=2|seekTargetFrame=16800|finalDrainIterations=2|probePreEos=ok',
    'sampleRate': '48000',
    'channelCount': '2',
    'pcmEncoding': '2',
    'totalFramesAccepted': '48000',
    'totalFramesDrained': '48000',
    'postSeekFramesAccepted': '24000',
    'postSeekFramesDrained': '24000',
    'kotlinAcceptedChecksumHex': _kChecksumHex,
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeDrainedChecksumHex': _kChecksumHex,
    'observedPartialWrite': 'true',
    'observedRingFull': 'true',
    'syntheticProbeChunk': 'true',
    'eosAlreadyEosStatus': 'already_eos',
    'eosAwaitingSeekAckStatus': 'awaiting_seek_ack',
    'eosPostAckStatus': 'ok',
    'midStreamFormatChangeRejected': 'true',
    'seekAckObserved': 'true',
    'discardedFramesOnSeek': '0',
    'newStartFrame': '16800',
  };

  return <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'preSeekDrainIterations=2|seekTargetFrame=16800|finalDrainIterations=2|probePreEos=ok',
    'sampleRate': 48000,
    'channelCount': 2,
    'pcmEncoding': 2,
    'totalFramesAccepted': 48000,
    'totalFramesDrained': 48000,
    'postSeekFramesAccepted': 24000,
    'postSeekFramesDrained': 24000,
    'kotlinAcceptedChecksumHex': _kChecksumHex,
    'nativeAcceptedChecksumHex': _kChecksumHex,
    'nativeDrainedChecksumHex': _kChecksumHex,
    'observedPartialWrite': true,
    'observedRingFull': true,
    'syntheticProbeChunk': true,
    'eosAlreadyEosStatus': 'already_eos',
    'eosAwaitingSeekAckStatus': 'awaiting_seek_ack',
    'eosPostAckStatus': 'ok',
    'midStreamFormatChangeRejected': true,
    'seekAckObserved': true,
    'discardedFramesOnSeek': 0,
    'newStartFrame': 16800,
    'raw': raw,
    'metrics': metrics,
    'lastError': '',
    if (overrides != null) ...overrides,
  };
}

VGAudioDecoderRingIngestSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) =>
    VGAudioDecoderRingIngestSmokeReport.fromMap(_createSampleRawMap(overrides));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGAudioDecoderRingIngestSmokeReport fromMap and toMap', () {
    test(
      'pass report parses and round-trips all lanes, metrics, and fields cleanly',
      () {
        final report = VGAudioDecoderRingIngestSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.pass, isTrue);
        expect(report.status, equals('pass'));
        expect(report.marker, equals(_kPassMarker));
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.failureReason, isEmpty);
        expect(report.lastError, isEmpty);
        expect(report.details, contains('seekTargetFrame=16800'));

        // Format fields
        expect(report.sampleRate, equals(48000));
        expect(report.channelCount, equals(2));
        expect(report.pcmEncoding, equals(2));

        // Frame accounting
        expect(report.totalFramesAccepted, equals(48000));
        expect(report.totalFramesDrained, equals(48000));
        expect(report.postSeekFramesAccepted, equals(24000));
        expect(report.postSeekFramesDrained, equals(24000));
        expect(report.discardedFramesOnSeek, equals(0));
        expect(report.newStartFrame, equals(16800));

        // Checksums
        expect(report.kotlinAcceptedChecksumHex, equals(_kChecksumHex));
        expect(report.nativeAcceptedChecksumHex, equals(_kChecksumHex));
        expect(report.nativeDrainedChecksumHex, equals(_kChecksumHex));

        // Backpressure and state flags
        expect(report.observedPartialWrite, isTrue);
        expect(report.observedRingFull, isTrue);
        expect(report.syntheticProbeChunk, isTrue);
        expect(report.eosAlreadyEosStatus, equals('already_eos'));
        expect(report.eosAwaitingSeekAckStatus, equals('awaiting_seek_ack'));
        expect(report.eosPostAckStatus, equals('ok'));
        expect(report.midStreamFormatChangeRejected, isTrue);
        expect(report.seekAckObserved, isTrue);

        // Getters
        expect(report.checksumsMatch, isTrue);
        expect(report.frameAccountingOk, isTrue);
        expect(report.backpressureObserved, isTrue);
        expect(report.syntheticProbeOk, isTrue);
        expect(report.seekAckOk, isTrue);
        expect(report.allNativeLanesPass, isTrue);

        // Serialization
        final serialized = report.toMap();
        expect(serialized['pass'], isTrue);
        expect(serialized['status'], equals('pass'));
        expect(serialized['marker'], equals(_kPassMarker));
        expect(serialized['proofBoundary'], equals(_kCanonicalProofBoundary));
        expect(serialized['sampleRate'], equals(48000));
        expect(serialized['channelCount'], equals(2));
        expect(serialized['pcmEncoding'], equals(2));
        expect(serialized['lastError'], equals(''));
        expect(serialized['raw'], equals(report.raw));
        expect(serialized['metrics'], equals(report.metrics));

        final roundTrip = VGAudioDecoderRingIngestSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test('fail report parses failure flags and lastError correctly', () {
      final report = VGAudioDecoderRingIngestSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'status': 'accepted_checksum_mismatch',
          'marker': _kFailMarker,
          'failureReason': 'accepted_checksum_mismatch',
          'lastError': 'accepted_checksum_mismatch',
        }),
      );

      expect(report.pass, isFalse);
      expect(report.status, equals('accepted_checksum_mismatch'));
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('accepted_checksum_mismatch'));
      expect(report.lastError, equals('accepted_checksum_mismatch'));
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
        final report = VGAudioDecoderRingIngestSmokeReport.fromMap(invalid);
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
        expect(report.sampleRate, equals(0));
        expect(report.totalFramesAccepted, equals(0));
      }
    });

    test('fromMap handles semicolon-delimited string raw fallback', () {
      final reportFromRaw = VGAudioDecoderRingIngestSmokeReport.fromMap({
        'pass': true,
        'raw':
            'status=PASS;'
            'marker=$_kPassMarker;'
            'proofBoundary=$_kCanonicalProofBoundary;'
            'sampleRate=44100;'
            'channelCount=2;'
            'pcmEncoding=2;'
            'totalFramesAccepted=44100;'
            'totalFramesDrained=44100;'
            'postSeekFramesAccepted=22050;'
            'postSeekFramesDrained=22050;'
            'kotlinAcceptedChecksumHex=$_kChecksumHex;'
            'nativeAcceptedChecksumHex=$_kChecksumHex;'
            'nativeDrainedChecksumHex=$_kChecksumHex;'
            'observedPartialWrite=true;'
            'observedRingFull=true;'
            'syntheticProbeChunk=true;'
            'eosAlreadyEosStatus=already_eos;'
            'eosAwaitingSeekAckStatus=awaiting_seek_ack;'
            'eosPostAckStatus=ok;'
            'midStreamFormatChangeRejected=true;'
            'seekAckObserved=true;'
            'discardedFramesOnSeek=0;'
            'newStartFrame=15435',
        'metrics': const <String, Object?>{},
      });

      expect(reportFromRaw.pass, isTrue);
      expect(reportFromRaw.sampleRate, equals(44100));
      expect(reportFromRaw.channelCount, equals(2));
      expect(reportFromRaw.pcmEncoding, equals(2));
      expect(reportFromRaw.totalFramesAccepted, equals(44100));
      expect(reportFromRaw.totalFramesDrained, equals(44100));
      expect(reportFromRaw.postSeekFramesAccepted, equals(22050));
      expect(reportFromRaw.postSeekFramesDrained, equals(22050));
      expect(reportFromRaw.observedPartialWrite, isTrue);
      expect(reportFromRaw.observedRingFull, isTrue);
      expect(reportFromRaw.syntheticProbeChunk, isTrue);
      expect(reportFromRaw.eosAlreadyEosStatus, equals('already_eos'));
      expect(
        reportFromRaw.eosAwaitingSeekAckStatus,
        equals('awaiting_seek_ack'),
      );
      expect(reportFromRaw.eosPostAckStatus, equals('ok'));
      expect(reportFromRaw.midStreamFormatChangeRejected, isTrue);
      expect(reportFromRaw.seekAckObserved, isTrue);
      expect(reportFromRaw.discardedFramesOnSeek, equals(0));
      expect(reportFromRaw.newStartFrame, equals(15435));
      expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
      expect(reportFromRaw.checksumsMatch, isTrue);
      expect(reportFromRaw.frameAccountingOk, isTrue);
      expect(reportFromRaw.backpressureObserved, isTrue);
      expect(reportFromRaw.syntheticProbeOk, isTrue);
      expect(reportFromRaw.seekAckOk, isTrue);
      expect(reportFromRaw.allNativeLanesPass, isTrue);
    });

    test('fromMap parses string-based boolean values in metrics', () {
      final report = VGAudioDecoderRingIngestSmokeReport.fromMap({
        'pass': true,
        'proofBoundary': _kCanonicalProofBoundary,
        'metrics': const <String, Object?>{
          'observedPartialWrite': 'true',
          'observedRingFull': 'pass',
          'syntheticProbeChunk': 'ok',
          'midStreamFormatChangeRejected': 'false',
        },
      });

      expect(report.observedPartialWrite, isTrue);
      expect(report.observedRingFull, isTrue);
      expect(report.syntheticProbeChunk, isTrue);
      expect(report.midStreamFormatChangeRejected, isFalse);
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
    test('checksumsMatch verifies 3-way non-empty identity', () {
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
          'nativeDrainedChecksumHex': 'mismatch',
        }).checksumsMatch,
        isFalse,
      );
    });

    test(
      'frameAccountingOk verifies totalFramesDrained + discarded == accepted',
      () {
        final report = _createSampleReport();
        expect(report.frameAccountingOk, isTrue);

        expect(
          _createSampleReport({'totalFramesDrained': 47000}).frameAccountingOk,
          isFalse,
        );
        expect(
          _createSampleReport({
            'totalFramesAccepted': 48000,
            'totalFramesDrained': 47500,
            'discardedFramesOnSeek': 500,
          }).frameAccountingOk,
          isTrue,
        );
      },
    );

    test('backpressureObserved requires both partial write and ring full', () {
      expect(_createSampleReport().backpressureObserved, isTrue);
      expect(
        _createSampleReport({
          'observedPartialWrite': false,
        }).backpressureObserved,
        isFalse,
      );
      expect(
        _createSampleReport({'observedRingFull': false}).backpressureObserved,
        isFalse,
      );
    });

    test('syntheticProbeOk verifies all 4 synthetic probe states', () {
      expect(_createSampleReport().syntheticProbeOk, isTrue);
      expect(
        _createSampleReport({'syntheticProbeChunk': false}).syntheticProbeOk,
        isFalse,
      );
      expect(
        _createSampleReport({'eosAlreadyEosStatus': 'bad'}).syntheticProbeOk,
        isFalse,
      );
      expect(
        _createSampleReport({
          'eosAwaitingSeekAckStatus': 'bad',
        }).syntheticProbeOk,
        isFalse,
      );
      expect(
        _createSampleReport({'eosPostAckStatus': 'bad'}).syntheticProbeOk,
        isFalse,
      );
    });

    test(
      'seekAckOk requires observed ack, 0 discarded, and valid start frame',
      () {
        expect(_createSampleReport().seekAckOk, isTrue);
        expect(
          _createSampleReport({'seekAckObserved': false}).seekAckOk,
          isFalse,
        );
        expect(
          _createSampleReport({'discardedFramesOnSeek': 100}).seekAckOk,
          isFalse,
        );
        expect(_createSampleReport({'newStartFrame': -1}).seekAckOk, isFalse);
      },
    );

    test('allNativeLanesPass requires all conditions to hold', () {
      expect(_createSampleReport().allNativeLanesPass, isTrue);

      // Status / marker / pass
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

      // Sample rate and channel count
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

      // Frames accepted / drained
      expect(
        _createSampleReport({'totalFramesAccepted': 0}).allNativeLanesPass,
        isFalse,
      );
      expect(
        _createSampleReport({'totalFramesDrained': 0}).allNativeLanesPass,
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
      expect(a.toString(), contains('VGAudioDecoderRingIngestSmokeReport('));
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
        {'sampleRate': 44100},
        {'channelCount': 1},
        {'pcmEncoding': 4},
        {'totalFramesAccepted': 999},
        {'totalFramesDrained': 999},
        {'postSeekFramesAccepted': 111},
        {'postSeekFramesDrained': 111},
        {'kotlinAcceptedChecksumHex': 'diff'},
        {'nativeAcceptedChecksumHex': 'diff'},
        {'nativeDrainedChecksumHex': 'diff'},
        {'observedPartialWrite': false},
        {'observedRingFull': false},
        {'syntheticProbeChunk': false},
        {'eosAlreadyEosStatus': 'bad'},
        {'eosAwaitingSeekAckStatus': 'bad'},
        {'eosPostAckStatus': 'bad'},
        {'midStreamFormatChangeRejected': false},
        {'seekAckObserved': false},
        {'discardedFramesOnSeek': 42},
        {'newStartFrame': 99},
        {'lastError': 'some_error'},
        {
          'raw': const <String, String>{'custom': 'diff'},
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

  group('MethodChannel wrapper: runAndroidDagPhase4AudioDecoderRingIngestSmoke', () {
    test(
      'invokes runAndroidDagPhase4AudioDecoderRingIngestSmoke with correct args on default channel',
      () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGAudioDecoderRingIngestSmokeReport.runAndroidDagPhase4AudioDecoderRingIngestSmoke(
              sourcePath: '/path/to/test.mov',
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase4AudioDecoderRingIngestSmoke'),
        );
        expect(
          capturedCall!.arguments,
          equals(<String, Object?>{
            'sourcePath': '/path/to/test.mov',
            'durationSec': 1.0,
            'seekTargetSec': 0.35,
          }),
        );
        expect(report.pass, isTrue);
        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test(
      'invokes with custom durationSec and seekTargetSec on custom channel',
      () async {
        MethodCall? capturedCall;
        const customChannel = MethodChannel(
          'custom_audio_decoder_ring_ingest_channel',
        );
        binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGAudioDecoderRingIngestSmokeReport.runAndroidDagPhase4AudioDecoderRingIngestSmoke(
              sourcePath: '/custom/path.mov',
              durationSec: 1.5,
              seekTargetSec: 0.5,
              channel: customChannel,
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase4AudioDecoderRingIngestSmoke'),
        );
        expect(
          capturedCall!.arguments,
          equals(<String, Object?>{
            'sourcePath': '/custom/path.mov',
            'durationSec': 1.5,
            'seekTargetSec': 0.5,
          }),
        );
        expect(report.pass, isTrue);
      },
    );

    test('handles PlatformException by returning fallback report', () async {
      const errorChannel = MethodChannel(
        'error_audio_decoder_ring_ingest_channel',
      );
      binaryMessenger.setMockMethodCallHandler(errorChannel, (call) async {
        throw PlatformException(
          code: 'P4_AUDIO_DECODER_RING_INGEST_SMOKE_FAILED',
          message: 'AudioDecoderRingIngest initialization failed',
        );
      });

      final report =
          await VGAudioDecoderRingIngestSmokeReport.runAndroidDagPhase4AudioDecoderRingIngestSmoke(
            sourcePath: '/test/error.mov',
            channel: errorChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.marker, equals(_kFailMarker));
      expect(report.allNativeLanesPass, isFalse);
      expect(
        report.lastError,
        contains(
          'platform_exception:P4_AUDIO_DECODER_RING_INGEST_SMOKE_FAILED:AudioDecoderRingIngest initialization failed',
        ),
      );
    });

    test('handles TimeoutException by returning fallback report', () async {
      const slowChannel = MethodChannel(
        'slow_audio_decoder_ring_ingest_channel',
      );
      binaryMessenger.setMockMethodCallHandler(slowChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });

      final report =
          await VGAudioDecoderRingIngestSmokeReport.runAndroidDagPhase4AudioDecoderRingIngestSmoke(
            sourcePath: '/test/slow.mov',
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
      const exChannel = MethodChannel('ex_audio_decoder_ring_ingest_channel');
      binaryMessenger.setMockMethodCallHandler(exChannel, (call) async {
        throw Exception('Native crash simulated');
      });

      final report =
          await VGAudioDecoderRingIngestSmokeReport.runAndroidDagPhase4AudioDecoderRingIngestSmoke(
            sourcePath: '/test/ex.mov',
            channel: exChannel,
          );

      expect(report.pass, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.marker, equals(_kFailMarker));
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, contains('Native crash simulated'));
    });
  });
}
