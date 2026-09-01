// android_async_runtime_queue_real_decoder_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-ASYNC-RUNTIME-QUEUE-REAL-DECODER (sub-slice X1):
// Android True-DAG Phase 4 real MediaExtractor/MediaCodec decoder to async
// runtime queue scheduler diagnostic proof physical harness.
//
// Proof lanes:
//   - Codec & Format group: formatProbeOk, decoderEosReachedOk, sampleRate, channelCount, pcmEncoding.
//   - Async Ownership group: asyncWorkerOwnershipOk, noOwnerThreadDispatchOk, foreignThreadRejectedOk, workerThreadDistinct, ownerDispatchCalls.
//   - Command Serialization group: controlCommandSerializationOk, commandsEnqueued, commandsProcessed, commandErrors.
//   - Ingest & Transport Pressure group: realDecoderIngestOk, sourceBackpressureRetryOk, outputBackpressureOk, backpressureCount, writerBackpressureRejects.
//   - Checksum Identity group: kotlinAcceptedChecksumHex, nativeAcceptedChecksumHex, nativeOutputReadChecksumHex, checksumIdentityOk, checksumsMatch, providerFramesZeroFilled, silenceCount.
//   - Frame Accounting group: expectedFrames, preSeekFrames, postSeekFrames, totalFramesExtracted, totalFramesAccepted, totalFramesRendered, totalFramesPushed, totalOutputFramesRead, framesTruncatedAtSeekBoundary, framesDiscardedAfterBudget, frameAccountingOk.
//   - Seek Epoch group: seekEpochReanchorOk, seekTargetFrame.
//   - Lifecycle group: workerJoinOnDestroyOk, idempotentDestroyOk.
//   - Proof-Boundary & Summary group: canonicalProofBoundaryOk, hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   kotlin_owned_real_decoder_to_async_runtime_queue_scheduler_proof_only_mediaextractor_mediacodec_sync_decode_owner_thread_to_native_async_worker_queue_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_media_time_worker_owned_clock_coordinator_output_ring_source_ring_spsc_caller_derived_accepted_frame_axis_ticks_only_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_audible_output_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_product_editor_app_wiring_no_export_route_changes_no_streaming_cache_no_ios_writer_local_eos_only_zero_fill_not_in_identity

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAsyncRuntimeQueueRealDecoderPhysicalSmokeApp());
}

class AndroidAsyncRuntimeQueueRealDecoderPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidAsyncRuntimeQueueRealDecoderPhysicalSmokeApp({super.key});

  @override
  State<AndroidAsyncRuntimeQueueRealDecoderPhysicalSmokeApp> createState() =>
      _AndroidAsyncRuntimeQueueRealDecoderPhysicalSmokeAppState();
}

class _AndroidAsyncRuntimeQueueRealDecoderPhysicalSmokeAppState
    extends State<AndroidAsyncRuntimeQueueRealDecoderPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Async Runtime Queue Real Decoder smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_SMOKE_START');

    VGAsyncRuntimeQueueRealDecoderSmokeReport? report;
    String? topLevelError;
    File? tempSourceFile;

    try {
      final clipBData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempSourceFile = File(
        '${tempDir.path}/p4_async_rt_queue_real_decoder_source_$timestamp.mov',
      );

      await tempSourceFile.writeAsBytes(
        clipBData.buffer.asUint8List(
          clipBData.offsetInBytes,
          clipBData.lengthInBytes,
        ),
        flush: true,
      );

      report = await VGAsyncRuntimeQueueRealDecoderSmokeReport
          .runAsyncRuntimeQueueRealDecoderSmoke(
        sourcePath: tempSourceFile.path,
        timeout: const Duration(seconds: 45),
      ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_ERROR: $topLevelError',
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

    final activeReport = report ??
        VGAsyncRuntimeQueueRealDecoderSmokeReport.fromMap(<String, Object?>{
          'pass': false,
          'status': 'fail',
          'marker':
              VGAsyncRuntimeQueueRealDecoderSmokeReport.failMarkerConstant,
          'proofBoundary': '',
          'failureReason': 'invocation_failed',
          'lastError': 'invocation_failed',
        });

    // 1. Codec & Format group
    print(
      '  [LANE] Codec & Format: '
      'formatProbeOk=${activeReport.formatProbeOk}, '
      'decoderEosReachedOk=${activeReport.decoderEosReachedOk}, '
      'sampleRate=${activeReport.sampleRate}, '
      'channelCount=${activeReport.channelCount}, '
      'pcmEncoding=${activeReport.pcmEncoding}',
    );

    // 2. Async Ownership group
    print(
      '  [LANE] Async Ownership: '
      'asyncWorkerOwnershipOk=${activeReport.asyncWorkerOwnershipOk}, '
      'noOwnerThreadDispatchOk=${activeReport.noOwnerThreadDispatchOk}, '
      'foreignThreadRejectedOk=${activeReport.foreignThreadRejectedOk}, '
      'workerThreadDistinct=${activeReport.workerThreadDistinct}, '
      'ownerDispatchCalls=${activeReport.ownerDispatchCalls}',
    );

    // 3. Command Serialization group
    print(
      '  [LANE] Command Serialization: '
      'controlCommandSerializationOk=${activeReport.controlCommandSerializationOk}, '
      'commandsEnqueued=${activeReport.commandsEnqueued}, '
      'commandsProcessed=${activeReport.commandsProcessed}, '
      'commandErrors=${activeReport.commandErrors}',
    );

    // 4. Ingest & Transport Pressure group
    print(
      '  [LANE] Ingest & Transport Pressure: '
      'realDecoderIngestOk=${activeReport.realDecoderIngestOk}, '
      'sourceBackpressureRetryOk=${activeReport.sourceBackpressureRetryOk}, '
      'outputBackpressureOk=${activeReport.outputBackpressureOk}, '
      'backpressureCount=${activeReport.backpressureCount}, '
      'writerBackpressureRejects=${activeReport.writerBackpressureRejects}',
    );

    // 5. Checksum Identity group
    print(
      '  [LANE] Checksum Identity: '
      'kotlinAcceptedChecksumHex=${activeReport.kotlinAcceptedChecksumHex}, '
      'nativeAcceptedChecksumHex=${activeReport.nativeAcceptedChecksumHex}, '
      'nativeOutputReadChecksumHex=${activeReport.nativeOutputReadChecksumHex}, '
      'checksumIdentityOk=${activeReport.checksumIdentityOk}, '
      'checksumsMatch=${activeReport.checksumsMatch}, '
      'providerFramesZeroFilled=${activeReport.providerFramesZeroFilled}, '
      'silenceCount=${activeReport.silenceCount}',
    );

    // 6. Frame Accounting group
    print(
      '  [LANE] Frame Accounting: '
      'expectedFrames=${activeReport.expectedFrames}, '
      'preSeekFrames=${activeReport.preSeekFrames}, '
      'postSeekFrames=${activeReport.postSeekFrames}, '
      'totalFramesExtracted=${activeReport.totalFramesExtracted}, '
      'totalFramesAccepted=${activeReport.totalFramesAccepted}, '
      'totalFramesRendered=${activeReport.totalFramesRendered}, '
      'totalFramesPushed=${activeReport.totalFramesPushed}, '
      'totalOutputFramesRead=${activeReport.totalOutputFramesRead}, '
      'framesTruncatedAtSeekBoundary=${activeReport.framesTruncatedAtSeekBoundary}, '
      'framesDiscardedAfterBudget=${activeReport.framesDiscardedAfterBudget}, '
      'frameAccountingOk=${activeReport.frameAccountingOk}',
    );

    // 7. Seek Epoch group
    print(
      '  [LANE] Seek Epoch: '
      'seekEpochReanchorOk=${activeReport.seekEpochReanchorOk}, '
      'seekTargetFrame=${activeReport.seekTargetFrame}',
    );

    // 8. Lifecycle group
    print(
      '  [LANE] Lifecycle: '
      'workerJoinOnDestroyOk=${activeReport.workerJoinOnDestroyOk}, '
      'idempotentDestroyOk=${activeReport.idempotentDestroyOk}',
    );

    // 9. Proof Boundary & Summary group
    print(
      '  [LANE] Proof Boundary & Summary: '
      'canonicalProofBoundaryOk=${activeReport.canonicalProofBoundaryOk}, '
      'hasCanonicalProofBoundary=${activeReport.hasCanonicalProofBoundary}, '
      'allNativeLanesPass=${activeReport.allNativeLanesPass}, '
      'lastError=${activeReport.lastError}',
    );

    final lastErrorOk = activeReport.lastError.isEmpty ||
        activeReport.lastError == 'none' ||
        activeReport.lastError == 'null';

    final pass = (topLevelError == null) &&
        activeReport.pass &&
        activeReport.hasCanonicalProofBoundary &&
        activeReport.checksumsMatch &&
        activeReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAsyncRuntimeQueueRealDecoderPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-ASYNC-RUNTIME-QUEUE-REAL-DECODER',
      'target': VGAsyncRuntimeQueueRealDecoderSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_PHYSICAL_SMOKE_FAIL',
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
