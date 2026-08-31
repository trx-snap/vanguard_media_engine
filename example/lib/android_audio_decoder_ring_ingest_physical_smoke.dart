// android_audio_decoder_ring_ingest_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice G3: Android True-DAG Phase 4
// native audio decoder ring ingest diagnostic proof physical harness.
//
// Proof lanes:
//   - Codec & Format group: sampleRate, channelCount, pcmEncoding.
//   - Frame Accounting group: totalFramesAccepted, totalFramesDrained, postSeekFramesAccepted, postSeekFramesDrained, discardedFramesOnSeek, frameAccountingOk.
//   - Checksum Identity group: kotlinAcceptedChecksumHex, nativeAcceptedChecksumHex, nativeDrainedChecksumHex, checksumsMatch.
//   - Backpressure group: observedPartialWrite, observedRingFull, backpressureObserved.
//   - Seek & ACK group: seekAckObserved, newStartFrame, discardedFramesOnSeek, seekAckOk.
//   - Synthetic Probe group: syntheticProbeChunk, eosAlreadyEosStatus, eosAwaitingSeekAckStatus, eosPostAckStatus, syntheticProbeOk.
//   - Proof-Boundary & Summary group: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   kotlin_owned_mediacodec_mediaextractor_streaming_decode_to_jni_decoder_ring_ingest_proof_only_no_cpp_os_decoder_no_mediacodec_or_mediaextractor_ownership_in_cpp_no_cpp_file_io_no_wall_clock_read_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audio_track_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_no_graph_scheduler_no_mix_bus_no_coordinator_no_closed_loop_sink_no_source_node_wiring_no_resample_no_downmix_channels_1_or_2_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_writer_local_eos_only_native_zero_steady_state_allocation_only_jvm_heap_non_claim

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioDecoderRingIngestPhysicalSmokeApp());
}

class AndroidAudioDecoderRingIngestPhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioDecoderRingIngestPhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioDecoderRingIngestPhysicalSmokeApp> createState() =>
      _AndroidAudioDecoderRingIngestPhysicalSmokeAppState();
}

class _AndroidAudioDecoderRingIngestPhysicalSmokeAppState
    extends State<AndroidAudioDecoderRingIngestPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Audio Decoder Ring Ingest smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_INGEST_SMOKE_START');

    VGAudioDecoderRingIngestSmokeReport? report;
    String? topLevelError;
    File? tempSourceFile;

    try {
      final clipBData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempSourceFile = File(
        '${tempDir.path}/p4_audio_decoder_ring_ingest_source_$timestamp.mov',
      );

      await tempSourceFile.writeAsBytes(
        clipBData.buffer.asUint8List(
          clipBData.offsetInBytes,
          clipBData.lengthInBytes,
        ),
        flush: true,
      );

      report =
          await VGAudioDecoderRingIngestSmokeReport.runAndroidDagPhase4AudioDecoderRingIngestSmoke(
            sourcePath: tempSourceFile.path,
            durationSec: 1.0,
            seekTargetSec: 0.35,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_INGEST_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_INGEST_ERROR: $topLevelError',
      );
    } finally {
      if (tempSourceFile != null) {
        try {
          if (await tempSourceFile.exists()) {
            await tempSourceFile.delete();
          }
        } catch (_) {}
      }
    }

    final activeReport =
        report ??
        const VGAudioDecoderRingIngestSmokeReport(
          pass: false,
          status: 'fail',
          marker: VGAudioDecoderRingIngestSmokeReport.failMarkerConstant,
          proofBoundary: '',
          failureReason: 'invocation_failed',
          details: '',
          sampleRate: 0,
          channelCount: 0,
          pcmEncoding: 0,
          totalFramesAccepted: 0,
          totalFramesDrained: 0,
          postSeekFramesAccepted: 0,
          postSeekFramesDrained: 0,
          kotlinAcceptedChecksumHex: '',
          nativeAcceptedChecksumHex: '',
          nativeDrainedChecksumHex: '',
          observedPartialWrite: false,
          observedRingFull: false,
          syntheticProbeChunk: false,
          eosAlreadyEosStatus: '',
          eosAwaitingSeekAckStatus: '',
          eosPostAckStatus: '',
          midStreamFormatChangeRejected: false,
          seekAckObserved: false,
          discardedFramesOnSeek: 0,
          newStartFrame: -1,
          raw: <String, String>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          metrics: <String, Object?>{'status': 'FAIL'},
          lastError: 'invocation_failed',
        );

    // 1. Codec & Format group
    print(
      '  [LANE] Codec & Format: '
      'sampleRate=${activeReport.sampleRate}, '
      'channelCount=${activeReport.channelCount}, '
      'pcmEncoding=${activeReport.pcmEncoding}',
    );

    // 2. Frame Accounting group
    print(
      '  [LANE] Frame Accounting: '
      'totalFramesAccepted=${activeReport.totalFramesAccepted}, '
      'totalFramesDrained=${activeReport.totalFramesDrained}, '
      'postSeekFramesAccepted=${activeReport.postSeekFramesAccepted}, '
      'postSeekFramesDrained=${activeReport.postSeekFramesDrained}, '
      'discardedFramesOnSeek=${activeReport.discardedFramesOnSeek}, '
      'frameAccountingOk=${activeReport.frameAccountingOk}',
    );

    // 3. Checksum Identity group
    print(
      '  [LANE] Checksum Identity: '
      'kotlinAcceptedChecksumHex=${activeReport.kotlinAcceptedChecksumHex}, '
      'nativeAcceptedChecksumHex=${activeReport.nativeAcceptedChecksumHex}, '
      'nativeDrainedChecksumHex=${activeReport.nativeDrainedChecksumHex}, '
      'checksumsMatch=${activeReport.checksumsMatch}',
    );

    // 4. Backpressure group
    print(
      '  [LANE] Backpressure: '
      'observedPartialWrite=${activeReport.observedPartialWrite}, '
      'observedRingFull=${activeReport.observedRingFull}, '
      'backpressureObserved=${activeReport.backpressureObserved}',
    );

    // 5. Seek & ACK group
    print(
      '  [LANE] Seek & ACK: '
      'seekAckObserved=${activeReport.seekAckObserved}, '
      'newStartFrame=${activeReport.newStartFrame}, '
      'discardedFramesOnSeek=${activeReport.discardedFramesOnSeek}, '
      'seekAckOk=${activeReport.seekAckOk}',
    );

    // 6. Synthetic Probe group
    print(
      '  [LANE] Synthetic Probe: '
      'syntheticProbeChunk=${activeReport.syntheticProbeChunk}, '
      'eosAlreadyEosStatus=${activeReport.eosAlreadyEosStatus}, '
      'eosAwaitingSeekAckStatus=${activeReport.eosAwaitingSeekAckStatus}, '
      'eosPostAckStatus=${activeReport.eosPostAckStatus}, '
      'syntheticProbeOk=${activeReport.syntheticProbeOk}',
    );

    // 7. Proof Boundary & Summary group
    print(
      '  [LANE] Proof Boundary & Summary: '
      'canonical=${activeReport.hasCanonicalProofBoundary}, '
      'allNativeLanesPass=${activeReport.allNativeLanesPass}, '
      'lastError=${activeReport.lastError}',
    );

    final lastErrorOk =
        activeReport.lastError.isEmpty ||
        activeReport.lastError == 'none' ||
        activeReport.lastError == 'null';

    final pass =
        (topLevelError == null) &&
        activeReport.pass &&
        activeReport.hasCanonicalProofBoundary &&
        activeReport.checksumsMatch &&
        activeReport.frameAccountingOk &&
        activeReport.backpressureObserved &&
        activeReport.syntheticProbeOk &&
        activeReport.seekAckOk &&
        activeReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAudioDecoderRingIngestPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-GRAPH-TRANSPORT-CLOCK',
      'target': VGAudioDecoderRingIngestSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_INGEST_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_INGEST_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_INGEST_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (allNativeLanesPass=true, hasCanonicalProofBoundary=true)'
            : 'FAIL: lastError=${activeReport.lastError}, error=$topLevelError';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 1500));
    exit(pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
