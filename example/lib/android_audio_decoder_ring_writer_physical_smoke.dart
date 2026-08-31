// android_audio_decoder_ring_writer_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice E: Android True-DAG Phase 4
// native AudioDecoderRingWriter diagnostic proof physical harness.
//
// Proof lanes:
//   - Constructor, Write Success & Partial Write group: constructorValidationOk, writeSuccessOk, partialWriteOk.
//   - Backpressure, Format & Argument Defense group: ringFullOk, formatMismatchOk, invalidArgumentOk.
//   - EOS, Seek Gating & Source Ring Invariants group: eosOk, seekAwaitAckGateOk, sourceRingBoundaryOk.
//   - Memory, Lifecycle & Scope group: noSteadyStateAllocationOk, lifecycleOk, stackScoped.
//   - Metrics group: partialWriteFramesAccepted, partialWriteEvents, backpressureRejects, formatMismatches, invalidArgumentRejects, awaitingSeekAckRejects, eosEvents, seekRequests, totalFramesWritten.
//   - Proof-Boundary & Summary group: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   native_audio_decoder_ring_writer_to_spsc_source_ring_ingest_proof_only_no_mediacodec_no_mediaextractor_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_playback_no_os_callback_no_threads_no_locks_no_file_io_no_export_reroute_no_streaming_no_ios_no_product_no_source_node_wiring_no_scheduler_integration_no_resample_no_audible_output_writer_local_eos_only
//   Producer-side AudioDecoderRingWriter to SPSC source ring ingest seam native proof.
//   Pure in-memory C++ proof only; no MediaCodec, no MediaExtractor,
//   no AudioTrack, no AAudio, no OpenSL, no Oboe, no realtime playback,
//   no OS callbacks, no threads, no locks, no file IO, no export reroute,
//   no streaming, no iOS, no product/editor UI, no DecodedAudioPcmSourceNode wiring,
//   no scheduler integration, no resample, no audible output.
//   Writer-local EOS only.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioDecoderRingWriterPhysicalSmokeApp());
}

class AndroidAudioDecoderRingWriterPhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioDecoderRingWriterPhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioDecoderRingWriterPhysicalSmokeApp> createState() =>
      _AndroidAudioDecoderRingWriterPhysicalSmokeAppState();
}

class _AndroidAudioDecoderRingWriterPhysicalSmokeAppState
    extends State<AndroidAudioDecoderRingWriterPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Audio Decoder Ring Writer smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_WRITER_SMOKE_START');

    VGAudioDecoderRingWriterSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGAudioDecoderRingWriterSmokeReport.runAndroidDagPhase4AudioDecoderRingWriterSmoke(
            timeout: const Duration(seconds: 15),
          ).timeout(const Duration(seconds: 25));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_WRITER_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_WRITER_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ??
        const VGAudioDecoderRingWriterSmokeReport(
          pass: false,
          proofBoundary: '',
          raw: <String, String>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          metrics: <String, Object?>{'status': 'FAIL'},
          lastError: 'invocation_failed',
        );

    // 1. Constructor, Write Success & Partial Write group
    print(
      '  [LANE] Constructor, Write Success & Partial Write: '
      'constructorValidationOk=${activeReport.constructorValidationOk}, '
      'writeSuccessOk=${activeReport.writeSuccessOk}, '
      'partialWriteOk=${activeReport.partialWriteOk}',
    );

    // 2. Backpressure, Format & Argument Defense group
    print(
      '  [LANE] Backpressure, Format & Argument Defense: '
      'ringFullOk=${activeReport.ringFullOk}, '
      'formatMismatchOk=${activeReport.formatMismatchOk}, '
      'invalidArgumentOk=${activeReport.invalidArgumentOk}',
    );

    // 3. EOS, Seek Gating & Source Ring Invariants group
    print(
      '  [LANE] EOS, Seek Gating & Source Ring Invariants: '
      'eosOk=${activeReport.eosOk}, '
      'seekAwaitAckGateOk=${activeReport.seekAwaitAckGateOk}, '
      'sourceRingBoundaryOk=${activeReport.sourceRingBoundaryOk}',
    );

    // 4. Memory, Lifecycle & Scope group
    print(
      '  [LANE] Memory, Lifecycle & Scope: '
      'noSteadyStateAllocationOk=${activeReport.noSteadyStateAllocationOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'stackScoped=${activeReport.stackScoped}',
    );

    // 5. Metrics group
    print(
      '  [LANE] Metrics: '
      'partialWriteFramesAccepted=${activeReport.partialWriteFramesAccepted}, '
      'partialWriteEvents=${activeReport.partialWriteEvents}, '
      'backpressureRejects=${activeReport.backpressureRejects}, '
      'formatMismatches=${activeReport.formatMismatches}, '
      'invalidArgumentRejects=${activeReport.invalidArgumentRejects}, '
      'awaitingSeekAckRejects=${activeReport.awaitingSeekAckRejects}, '
      'eosEvents=${activeReport.eosEvents}, '
      'seekRequests=${activeReport.seekRequests}, '
      'totalFramesWritten=${activeReport.totalFramesWritten}',
    );

    // 6. Proof Boundary & Summary group
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
        activeReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAudioDecoderRingWriterPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-GRAPH-TRANSPORT-CLOCK',
      'target': VGAudioDecoderRingWriterSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_WRITER_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_WRITER_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_WRITER_SMOKE_FAIL',
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
