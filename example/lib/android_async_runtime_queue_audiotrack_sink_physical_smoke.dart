// android_async_runtime_queue_audiotrack_sink_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-ASYNC-RUNTIME-QUEUE-AUDIOTRACK-SINK
// (sub-slice X2): Android True-DAG Phase 4 async runtime queue output ring
// to Kotlin-owned muted AudioTrack sink diagnostic proof physical harness.
//
// Proof lanes:
//   - Codec & Format group: formatProbeOk, decoderEosReachedOk, sampleRate, channelCount, pcmEncoding.
//   - Async Ownership group: asyncWorkerOwnershipOk, noOwnerThreadDispatchOk, foreignThreadRejectedOk, ownerThreadAffinityOk, workerThreadDistinct, ownerDispatchCalls.
//   - Command Serialization group: controlCommandSerializationOk, commandsEnqueued, commandsProcessed, commandErrors.
//   - Ingest & Transport Pressure group: realDecoderIngestOk, sourceBackpressureRetryOk, outputBackpressureOk, backpressureCount, writerBackpressureRejects.
//   - Checksum Identity group: kotlinAcceptedChecksumHex, kotlinSinkChecksumHex, nativeAcceptedChecksumHex, nativeOutputReadChecksumHex, checksumIdentityOk, checksumsMatch, providerFramesZeroFilled, silenceCount.
//   - Frame Accounting group: expectedFrames, preSeekFrames, postSeekFrames, totalFramesExtracted, totalFramesAccepted, totalFramesRendered, totalFramesPushed, totalOutputFramesRead, frameAccountingOk.
//   - AudioTrack Sink group: audioTrackInitOk, mutedOutputOk, sinkWriteAccountingOk, sinkAccountingBalanced, framesReadFromRing, framesWrittenToSink, residualFramesAtEnd, playbackHeadProgressionOk, playbackHeadFinal.
//   - Seek Epoch group: seekEpochReanchorOk, seekSinkEpochResetOk, seekTargetFrame, framesWrittenBeforeSeek, playbackHeadAtSeek, framesDiscardedInSinkAtSeek.
//   - Lifecycle group: workerJoinOnDestroyOk, idempotentDestroyOk.
//   - Proof-Boundary & Summary group: canonicalProofBoundaryOk, hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   kotlin_owned_muted_audiotrack_sink_on_async_runtime_queue_diagnostic_proof_only_real_decoder_to_async_runtime_queue_scheduler_output_ring_to_muted_audiotrack_mode_stream_write_accounting_worker_owned_clock_and_coordinator_kotlin_owned_audiotrack_lifecycle_writes_reads_telemetry_deadlines_cleanup_write_non_blocking_only_playback_head_and_audio_timestamp_diagnostic_telemetry_and_bounded_sink_write_gating_only_never_native_or_product_media_clock_no_audible_output_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_realtime_rate_claim_no_fleet_claim_no_product_editor_app_wiring_no_export_route_no_streaming_cache_no_ios_no_cpp_primitive_changes

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAsyncRuntimeQueueAudioTrackSinkPhysicalSmokeApp());
}

class AndroidAsyncRuntimeQueueAudioTrackSinkPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidAsyncRuntimeQueueAudioTrackSinkPhysicalSmokeApp({super.key});

  @override
  State<AndroidAsyncRuntimeQueueAudioTrackSinkPhysicalSmokeApp> createState() =>
      _AndroidAsyncRuntimeQueueAudioTrackSinkPhysicalSmokeAppState();
}

class _AndroidAsyncRuntimeQueueAudioTrackSinkPhysicalSmokeAppState
    extends State<AndroidAsyncRuntimeQueueAudioTrackSinkPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Async Runtime Queue AudioTrack Sink smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_SINK_SMOKE_START');

    VGAsyncRuntimeQueueAudioTrackSinkSmokeReport? report;
    String? topLevelError;
    File? tempSourceFile;

    try {
      final clipBData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempSourceFile = File(
        '${tempDir.path}/p4_async_rt_queue_audiotrack_sink_source_$timestamp.mov',
      );

      await tempSourceFile.writeAsBytes(
        clipBData.buffer.asUint8List(
          clipBData.offsetInBytes,
          clipBData.lengthInBytes,
        ),
        flush: true,
      );

      report =
          await VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.runAsyncRuntimeQueueAudioTrackSinkSmoke(
            sourcePath: tempSourceFile.path,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_SINK_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_SINK_ERROR: $topLevelError',
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
        VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.fromMap(<String, Object?>{
          'pass': false,
          'status': 'fail',
          'marker':
              VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.failMarkerConstant,
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
      'ownerThreadAffinityOk=${activeReport.ownerThreadAffinityOk}, '
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
      'kotlinSinkChecksumHex=${activeReport.kotlinSinkChecksumHex}, '
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
      'frameAccountingOk=${activeReport.frameAccountingOk}',
    );

    // 7. AudioTrack Sink group
    print(
      '  [LANE] AudioTrack Sink: '
      'audioTrackInitOk=${activeReport.audioTrackInitOk}, '
      'mutedOutputOk=${activeReport.mutedOutputOk}, '
      'sinkWriteAccountingOk=${activeReport.sinkWriteAccountingOk}, '
      'sinkAccountingBalanced=${activeReport.sinkAccountingBalanced}, '
      'framesReadFromRing=${activeReport.framesReadFromRing}, '
      'framesWrittenToSink=${activeReport.framesWrittenToSink}, '
      'residualFramesAtEnd=${activeReport.residualFramesAtEnd}, '
      'playbackHeadProgressionOk=${activeReport.playbackHeadProgressionOk}, '
      'playbackHeadFinal=${activeReport.playbackHeadFinal}',
    );

    // 8. Seek Epoch group
    print(
      '  [LANE] Seek Epoch: '
      'seekEpochReanchorOk=${activeReport.seekEpochReanchorOk}, '
      'seekSinkEpochResetOk=${activeReport.seekSinkEpochResetOk}, '
      'seekTargetFrame=${activeReport.seekTargetFrame}, '
      'framesWrittenBeforeSeek=${activeReport.framesWrittenBeforeSeek}, '
      'playbackHeadAtSeek=${activeReport.playbackHeadAtSeek}, '
      'framesDiscardedInSinkAtSeek=${activeReport.framesDiscardedInSinkAtSeek}',
    );

    // 9. Lifecycle group
    print(
      '  [LANE] Lifecycle: '
      'workerJoinOnDestroyOk=${activeReport.workerJoinOnDestroyOk}, '
      'idempotentDestroyOk=${activeReport.idempotentDestroyOk}',
    );

    // 10. Proof Boundary & Summary group
    print(
      '  [LANE] Proof Boundary & Summary: '
      'canonicalProofBoundaryOk=${activeReport.canonicalProofBoundaryOk}, '
      'hasCanonicalProofBoundary=${activeReport.hasCanonicalProofBoundary}, '
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
        activeReport.sinkAccountingBalanced &&
        activeReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAsyncRuntimeQueueAudioTrackSinkPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-ASYNC-RUNTIME-QUEUE-AUDIOTRACK-SINK',
      'target':
          VGAsyncRuntimeQueueAudioTrackSinkSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_SINK_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_SINK_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_SINK_PHYSICAL_SMOKE_FAIL',
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
