// android_async_runtime_queue_realtime_clock_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-ASYNC-RUNTIME-QUEUE-REALTIME-CLOCK-PACING
// (sub-slice X3): Android True-DAG Phase 4 async runtime queue native
// worker-owned steady_clock realtime pacing diagnostic proof physical
// harness.
//
// Proof lanes:
//   - Codec & Format group: formatProbeOk, decoderEosReachedOk, sampleRate, channelCount, pcmEncoding.
//   - Realtime Clock Ownership group: realtimeWorkerClockOwnershipOk, noCallerSuppliedNativeTimeOk, noOwnerThreadDispatchOk, ownerThreadAffinityOk, workerThreadDistinct, ownerDispatchCalls.
//   - Realtime Pacing group: realtimeNativeElapsedOk, nativeRealtimeElapsedMs, nativeTimingF0, nativeTimingF1, realtimeBacklogBoundOk, maxRenderCursorBacklogUs, backlogSampleCount, workerNoFramesDueWaits, backpressureCount (telemetry).
//   - Command Serialization group: controlCommandSerializationOk, commandsEnqueued, commandsProcessed, commandErrors.
//   - Ingest group: realDecoderIngestOk, preStartFillFrames, totalFramesExtracted.
//   - Checksum Identity group: kotlinAcceptedChecksumHex, kotlinSinkChecksumHex, nativeAcceptedChecksumHex, nativeOutputReadChecksumHex, checksumIdentityOk, checksumsMatch, providerFramesZeroFilled, silenceCount.
//   - Frame Accounting group: expectedFrames, preSeekFrames, postSeekFrames, totalFramesAccepted, totalFramesRendered, totalFramesPushed, totalOutputFramesRead, frameAccountingOk.
//   - AudioTrack Sink group: audioTrackInitOk, mutedOutputOk, sinkWriteAccountingOk, sinkAccountingBalanced, framesReadFromRing, framesWrittenToSink, residualFramesAtEnd, playbackHeadTelemetryOk, playbackHeadDeltaTelemetryOnly, underrunDeltaTelemetryOnly.
//   - Seek Epoch group: seekEpochReanchorOk, seekSinkEpochResetOk, seekTargetFrame, framesDiscardedInSinkAtSeek.
//   - Lifecycle group: workerJoinOnDestroyOk, idempotentDestroyOk.
//   - Proof-Boundary & Summary group: canonicalProofBoundaryOk, hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   kotlin_owned_audiotrack_sink_on_async_runtime_queue_realtime_wall_clock_pacing_proof_only_real_decoder_to_async_runtime_queue_scheduler_output_ring_to_muted_audiotrack_mode_stream_native_worker_owned_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_kotlin_owned_mediacodec_mediaextractor_and_audiotrack_lifecycle_write_non_blocking_only_playback_head_and_audio_timestamp_telemetry_only_no_audible_output_no_speaker_route_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_zero_underrun_claim_no_realtime_priority_claim_no_fleet_claim_no_product_editor_app_wiring_no_export_route_no_streaming_cache_no_ios_no_cpp_primitive_changes

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAsyncRuntimeQueueRealtimeClockPhysicalSmokeApp());
}

class AndroidAsyncRuntimeQueueRealtimeClockPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidAsyncRuntimeQueueRealtimeClockPhysicalSmokeApp({super.key});

  @override
  State<AndroidAsyncRuntimeQueueRealtimeClockPhysicalSmokeApp> createState() =>
      _AndroidAsyncRuntimeQueueRealtimeClockPhysicalSmokeAppState();
}

class _AndroidAsyncRuntimeQueueRealtimeClockPhysicalSmokeAppState
    extends State<AndroidAsyncRuntimeQueueRealtimeClockPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Async Runtime Queue Realtime Clock smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REALTIME_CLOCK_SMOKE_START');

    VGAsyncRuntimeQueueRealtimeClockSmokeReport? report;
    String? topLevelError;
    File? tempSourceFile;

    try {
      final clipBData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempSourceFile = File(
        '${tempDir.path}/p4_async_rt_queue_realtime_clock_source_$timestamp.mov',
      );

      await tempSourceFile.writeAsBytes(
        clipBData.buffer.asUint8List(
          clipBData.offsetInBytes,
          clipBData.lengthInBytes,
        ),
        flush: true,
      );

      report =
          await VGAsyncRuntimeQueueRealtimeClockSmokeReport.runAsyncRuntimeQueueRealtimeClockSmoke(
            sourcePath: tempSourceFile.path,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REALTIME_CLOCK_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REALTIME_CLOCK_ERROR: $topLevelError',
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
        VGAsyncRuntimeQueueRealtimeClockSmokeReport.fromMap(<String, Object?>{
          'pass': false,
          'status': 'fail',
          'marker':
              VGAsyncRuntimeQueueRealtimeClockSmokeReport.failMarkerConstant,
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

    // 2. Realtime Clock Ownership group
    print(
      '  [LANE] Realtime Clock Ownership: '
      'realtimeWorkerClockOwnershipOk=${activeReport.realtimeWorkerClockOwnershipOk}, '
      'noCallerSuppliedNativeTimeOk=${activeReport.noCallerSuppliedNativeTimeOk}, '
      'noOwnerThreadDispatchOk=${activeReport.noOwnerThreadDispatchOk}, '
      'ownerThreadAffinityOk=${activeReport.ownerThreadAffinityOk}, '
      'workerThreadDistinct=${activeReport.workerThreadDistinct}, '
      'ownerDispatchCalls=${activeReport.ownerDispatchCalls}',
    );

    // 3. Realtime Pacing group (primary native gates + telemetry)
    print(
      '  [LANE] Realtime Pacing: '
      'realtimeNativeElapsedOk=${activeReport.realtimeNativeElapsedOk}, '
      'nativeRealtimeElapsedMs=${activeReport.nativeRealtimeElapsedMs}, '
      'nativeTimingF0=${activeReport.nativeTimingF0}, '
      'nativeTimingF1=${activeReport.nativeTimingF1}, '
      'realtimeBacklogBoundOk=${activeReport.realtimeBacklogBoundOk}, '
      'maxRenderCursorBacklogUs=${activeReport.maxRenderCursorBacklogUs}, '
      'backlogSampleCount=${activeReport.backlogSampleCount}, '
      'workerNoFramesDueWaits=${activeReport.workerNoFramesDueWaits}, '
      'backpressureCountTelemetry=${activeReport.backpressureCount}',
    );

    // 4. Command Serialization group
    print(
      '  [LANE] Command Serialization: '
      'controlCommandSerializationOk=${activeReport.controlCommandSerializationOk}, '
      'commandsEnqueued=${activeReport.commandsEnqueued}, '
      'commandsProcessed=${activeReport.commandsProcessed}, '
      'commandErrors=${activeReport.commandErrors}',
    );

    // 5. Ingest group
    print(
      '  [LANE] Ingest: '
      'realDecoderIngestOk=${activeReport.realDecoderIngestOk}, '
      'preStartFillFrames=${activeReport.preStartFillFrames}, '
      'totalFramesExtracted=${activeReport.totalFramesExtracted}',
    );

    // 6. Checksum Identity group
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

    // 7. Frame Accounting group
    print(
      '  [LANE] Frame Accounting: '
      'expectedFrames=${activeReport.expectedFrames}, '
      'preSeekFrames=${activeReport.preSeekFrames}, '
      'postSeekFrames=${activeReport.postSeekFrames}, '
      'totalFramesAccepted=${activeReport.totalFramesAccepted}, '
      'totalFramesRendered=${activeReport.totalFramesRendered}, '
      'totalFramesPushed=${activeReport.totalFramesPushed}, '
      'totalOutputFramesRead=${activeReport.totalOutputFramesRead}, '
      'frameAccountingOk=${activeReport.frameAccountingOk}',
    );

    // 8. AudioTrack Sink group (telemetry only, never a native timebase)
    print(
      '  [LANE] AudioTrack Sink: '
      'audioTrackInitOk=${activeReport.audioTrackInitOk}, '
      'mutedOutputOk=${activeReport.mutedOutputOk}, '
      'sinkWriteAccountingOk=${activeReport.sinkWriteAccountingOk}, '
      'sinkAccountingBalanced=${activeReport.sinkAccountingBalanced}, '
      'framesReadFromRing=${activeReport.framesReadFromRing}, '
      'framesWrittenToSink=${activeReport.framesWrittenToSink}, '
      'residualFramesAtEnd=${activeReport.residualFramesAtEnd}, '
      'playbackHeadTelemetryOk=${activeReport.playbackHeadTelemetryOk}, '
      'playbackHeadDeltaTelemetryOnly=${activeReport.playbackHeadDeltaTelemetryOnly}, '
      'underrunDeltaTelemetryOnly=${activeReport.underrunDeltaTelemetryOnly}',
    );

    // 9. Seek Epoch group
    print(
      '  [LANE] Seek Epoch: '
      'seekEpochReanchorOk=${activeReport.seekEpochReanchorOk}, '
      'seekSinkEpochResetOk=${activeReport.seekSinkEpochResetOk}, '
      'seekTargetFrame=${activeReport.seekTargetFrame}, '
      'framesDiscardedInSinkAtSeek=${activeReport.framesDiscardedInSinkAtSeek}',
    );

    // 10. Lifecycle group
    print(
      '  [LANE] Lifecycle: '
      'workerJoinOnDestroyOk=${activeReport.workerJoinOnDestroyOk}, '
      'idempotentDestroyOk=${activeReport.idempotentDestroyOk}',
    );

    // 11. Proof Boundary & Summary group
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
        activeReport.realtimeGatesHeld &&
        activeReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAsyncRuntimeQueueRealtimeClockPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-ASYNC-RUNTIME-QUEUE-REALTIME-CLOCK-PACING',
      'target':
          VGAsyncRuntimeQueueRealtimeClockSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REALTIME_CLOCK_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REALTIME_CLOCK_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REALTIME_CLOCK_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (allNativeLanesPass=true, realtimeGatesHeld=true)'
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
