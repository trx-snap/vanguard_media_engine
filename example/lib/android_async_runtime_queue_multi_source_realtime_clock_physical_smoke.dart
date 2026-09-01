// android_async_runtime_queue_multi_source_realtime_clock_physical_smoke.dart
// vanguard_media_engine -
// P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-REALTIME-CLOCK (sub-slice X4):
// Android True-DAG Phase 4 async runtime queue native worker-owned
// steady_clock realtime pacing over the two-source node-owned topology
// diagnostic proof physical harness.
//
// Proof lanes:
//   - Codec & Format group: formatProbeOk, decoderEosReachedOk, sampleRate, channelCount, pcmEncoding.
//   - Realtime Clock Ownership group: realtimeWorkerClockOwnershipOk, noCallerSuppliedNativeTimeOk, noOwnerThreadDispatchOk, ownerThreadAffinityOk, workerThreadDistinct, ownerDispatchCalls.
//   - Realtime Pacing group: realtimeNativeElapsedOk, nativeRealtimeElapsedMs, nativeTimingF0, nativeTimingF1, realtimeBacklogBoundOk, maxRenderCursorBacklogUs, backlogSampleCount, workerNoFramesDueWaits, backpressureCountTelemetry.
//   - Command Serialization group: controlCommandSerializationOk, commandsEnqueued, commandsProcessed, commandErrors.
//   - Multi-Source Ingest group: multiSourceRealDecoderIngestOk, trackFrameAxisLockstepOk, preStartFillFrames, totalFramesExtracted.
//   - Checksum Identity group: kotlinTrack0AcceptedChecksumHex, nativeAcceptedChecksumTrack0Hex, kotlinTrack1AcceptedChecksumHex, nativeAcceptedChecksumTrack1Hex, kotlinReferenceMixChecksumHex, nativeOutputReadChecksumHex, kotlinSinkWriteChecksumHex, referenceMixChecksumOk, twoTrackContributionOk, checksumIdentityOk, checksumsMatch.
//   - Provider Poisoning group: providerPoisoningOk plus all eight per-track counters, silenceCount.
//   - Frame Accounting group: expectedFrames, preSeekFrames, postSeekFrames, totalFramesAcceptedTrack0/1, totalFramesRendered, totalFramesPushed, totalOutputFramesRead, frameAccountingOk.
//   - AudioTrack Sink group: audioTrackInitOk, mutedOutputOk, sinkWriteAccountingOk, sinkAccountingBalanced, framesReadFromRing, framesWrittenToSink, residualFramesAtEnd, playbackHeadTelemetryOk, playbackHeadDeltaTelemetryOnly, underrunDeltaTelemetryOnly.
//   - Seek Epoch group: seekEpochReanchorOk, seekSinkEpochResetOk, syntheticGeneratorReanchorOk, generatorReanchorCount, seekTargetFrame, framesDiscardedInSinkAtSeek.
//   - Lifecycle group: workerJoinOnDestroyOk, idempotentDestroyOk.
//   - Proof-Boundary & Summary group: canonicalProofBoundaryOk, hasCanonicalProofBoundary, nativeProofBoundaryOk, allNativeLanesPass, lastError.
//
// After the X4 run, a second envelope-enabled run (sub-slice X5,
// P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-DYNAMIC-GAIN-ENVELOPE) proves
// the dynamic-gain-envelope reference mix identity and telemetry gates:
//   - Dynamic Gain Envelope group: envelopeProofEnabled, envelopeApplied, envelopeEvaluations, minEffectiveGain, maxEffectiveGain, dynamicGainEnvelopeGatesHeld.
// Overall exit is PASS only when BOTH runs pass; each phase prints its own
// PHYSICAL_SMOKE_PASS/FAIL marker.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAsyncRuntimeQueueMultiSourceRealtimeClockSmokeApp());
}

class AndroidAsyncRuntimeQueueMultiSourceRealtimeClockSmokeApp
    extends StatefulWidget {
  const AndroidAsyncRuntimeQueueMultiSourceRealtimeClockSmokeApp({super.key});

  @override
  State<AndroidAsyncRuntimeQueueMultiSourceRealtimeClockSmokeApp>
  createState() =>
      _AndroidAsyncRuntimeQueueMultiSourceRealtimeClockSmokeAppState();
}

class _AndroidAsyncRuntimeQueueMultiSourceRealtimeClockSmokeAppState
    extends State<AndroidAsyncRuntimeQueueMultiSourceRealtimeClockSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Async Runtime Queue Multi-Source '
      'Realtime Clock smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_REALTIME_CLOCK_SMOKE_START',
    );

    VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport? report;
    String? topLevelError;
    File? tempSourceFile;

    try {
      final clipBData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempSourceFile = File(
        '${tempDir.path}/p4_async_rt_queue_ms_realtime_clock_source_$timestamp.mov',
      );

      await tempSourceFile.writeAsBytes(
        clipBData.buffer.asUint8List(
          clipBData.offsetInBytes,
          clipBData.lengthInBytes,
        ),
        flush: true,
      );

      report =
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
            sourcePath: tempSourceFile.path,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_REALTIME_CLOCK_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_REALTIME_CLOCK_ERROR: $topLevelError',
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
        VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
          <String, Object?>{
            'pass': false,
            'status': 'fail',
            'marker': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .failMarkerConstant,
            'proofBoundary': '',
            'nativeProofBoundary': '',
            'failureReason': 'invocation_failed',
            'lastError': 'invocation_failed',
          },
        );

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
      'backpressureCountTelemetry=${activeReport.backpressureCountTelemetry}',
    );

    // 4. Command Serialization group
    print(
      '  [LANE] Command Serialization: '
      'controlCommandSerializationOk=${activeReport.controlCommandSerializationOk}, '
      'commandsEnqueued=${activeReport.commandsEnqueued}, '
      'commandsProcessed=${activeReport.commandsProcessed}, '
      'commandErrors=${activeReport.commandErrors}',
    );

    // 5. Multi-Source Ingest group
    print(
      '  [LANE] Multi-Source Ingest: '
      'multiSourceRealDecoderIngestOk=${activeReport.multiSourceRealDecoderIngestOk}, '
      'trackFrameAxisLockstepOk=${activeReport.trackFrameAxisLockstepOk}, '
      'preStartFillFrames=${activeReport.preStartFillFrames}, '
      'totalFramesExtracted=${activeReport.totalFramesExtracted}',
    );

    // 6. Checksum Identity group
    print(
      '  [LANE] Checksum Identity: '
      'kotlinTrack0AcceptedChecksumHex=${activeReport.kotlinTrack0AcceptedChecksumHex}, '
      'nativeAcceptedChecksumTrack0Hex=${activeReport.nativeAcceptedChecksumTrack0Hex}, '
      'kotlinTrack1AcceptedChecksumHex=${activeReport.kotlinTrack1AcceptedChecksumHex}, '
      'nativeAcceptedChecksumTrack1Hex=${activeReport.nativeAcceptedChecksumTrack1Hex}, '
      'kotlinReferenceMixChecksumHex=${activeReport.kotlinReferenceMixChecksumHex}, '
      'nativeOutputReadChecksumHex=${activeReport.nativeOutputReadChecksumHex}, '
      'kotlinSinkWriteChecksumHex=${activeReport.kotlinSinkWriteChecksumHex}, '
      'referenceMixChecksumOk=${activeReport.referenceMixChecksumOk}, '
      'twoTrackContributionOk=${activeReport.twoTrackContributionOk}, '
      'checksumIdentityOk=${activeReport.checksumIdentityOk}, '
      'checksumsMatch=${activeReport.checksumsMatch}',
    );

    // 7. Provider Poisoning group
    print(
      '  [LANE] Provider Poisoning: '
      'providerPoisoningOk=${activeReport.providerPoisoningOk}, '
      'providerTrack0ZeroFilledFrames=${activeReport.providerTrack0ZeroFilledFrames}, '
      'providerTrack1ZeroFilledFrames=${activeReport.providerTrack1ZeroFilledFrames}, '
      'providerTrack0UnderrunEvents=${activeReport.providerTrack0UnderrunEvents}, '
      'providerTrack1UnderrunEvents=${activeReport.providerTrack1UnderrunEvents}, '
      'providerTrack0ForwardSkipFrames=${activeReport.providerTrack0ForwardSkipFrames}, '
      'providerTrack1ForwardSkipFrames=${activeReport.providerTrack1ForwardSkipFrames}, '
      'providerTrack0RewindRejects=${activeReport.providerTrack0RewindRejects}, '
      'providerTrack1RewindRejects=${activeReport.providerTrack1RewindRejects}, '
      'silenceCount=${activeReport.silenceCount}',
    );

    // 8. Frame Accounting group
    print(
      '  [LANE] Frame Accounting: '
      'expectedFrames=${activeReport.expectedFrames}, '
      'preSeekFrames=${activeReport.preSeekFrames}, '
      'postSeekFrames=${activeReport.postSeekFrames}, '
      'totalFramesAcceptedTrack0=${activeReport.totalFramesAcceptedTrack0}, '
      'totalFramesAcceptedTrack1=${activeReport.totalFramesAcceptedTrack1}, '
      'totalFramesRendered=${activeReport.totalFramesRendered}, '
      'totalFramesPushed=${activeReport.totalFramesPushed}, '
      'totalOutputFramesRead=${activeReport.totalOutputFramesRead}, '
      'frameAccountingOk=${activeReport.frameAccountingOk}',
    );

    // 9. AudioTrack Sink group (telemetry only, never a native timebase)
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

    // 10. Seek Epoch group
    print(
      '  [LANE] Seek Epoch: '
      'seekEpochReanchorOk=${activeReport.seekEpochReanchorOk}, '
      'seekSinkEpochResetOk=${activeReport.seekSinkEpochResetOk}, '
      'syntheticGeneratorReanchorOk=${activeReport.syntheticGeneratorReanchorOk}, '
      'generatorReanchorCount=${activeReport.generatorReanchorCount}, '
      'seekTargetFrame=${activeReport.seekTargetFrame}, '
      'framesDiscardedInSinkAtSeek=${activeReport.framesDiscardedInSinkAtSeek}',
    );

    // 11. Lifecycle group
    print(
      '  [LANE] Lifecycle: '
      'workerJoinOnDestroyOk=${activeReport.workerJoinOnDestroyOk}, '
      'idempotentDestroyOk=${activeReport.idempotentDestroyOk}',
    );

    // 12. Proof Boundary & Summary group
    print(
      '  [LANE] Proof Boundary & Summary: '
      'canonicalProofBoundaryOk=${activeReport.canonicalProofBoundaryOk}, '
      'hasCanonicalProofBoundary=${activeReport.hasCanonicalProofBoundary}, '
      'nativeProofBoundaryOk=${activeReport.nativeProofBoundaryOk}, '
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
        activeReport.nativeProofBoundaryOk &&
        activeReport.checksumsMatch &&
        activeReport.providerCountersClean &&
        activeReport.sinkAccountingBalanced &&
        activeReport.realtimeGatesHeld &&
        activeReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit':
          'AndroidAsyncRuntimeQueueMultiSourceRealtimeClockPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-REALTIME-CLOCK',
      'target': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .proofBoundaryConstant,
      'nativeTarget': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .nativeProofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_REALTIME_CLOCK_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_REALTIME_CLOCK_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_REALTIME_CLOCK_PHYSICAL_SMOKE_FAIL',
    );

    // ── X5 (P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-DYNAMIC-GAIN-
    // ENVELOPE): the same run with the deterministic dynamic per-track
    // envelope mix params enabled. The X4 run above stays authoritative
    // for the unit-gain proof; this phase additionally proves the
    // envelope-shaped reference mix identity and telemetry gates. ─────────
    final envelopePass = await _runEnvelopeSmoke();

    final bothPass = pass && envelopePass;
    if (mounted) {
      setState(() {
        _status = bothPass
            ? 'PASS (X4 allNativeLanesPass=true, X5 envelope gates held)'
            : 'FAIL: x4Pass=$pass, envelopePass=$envelopePass, '
                  'lastError=${activeReport.lastError}, error=$topLevelError';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 1500));
    exit(bothPass ? 0 : 1);
  }

  Future<bool> _runEnvelopeSmoke() async {
    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_DYNAMIC_GAIN_ENVELOPE_SMOKE_START',
    );

    VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport? report;
    String? topLevelError;
    File? tempSourceFile;

    try {
      final clipBData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempSourceFile = File(
        '${tempDir.path}/p4_async_rt_queue_ms_dyn_gain_env_source_$timestamp.mov',
      );

      await tempSourceFile.writeAsBytes(
        clipBData.buffer.asUint8List(
          clipBData.offsetInBytes,
          clipBData.lengthInBytes,
        ),
        flush: true,
      );

      report =
          await VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke(
            sourcePath: tempSourceFile.path,
            envelopeProofEnabled: true,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_DYNAMIC_GAIN_ENVELOPE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_DYNAMIC_GAIN_ENVELOPE_ERROR: $topLevelError',
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

    final envReport =
        report ??
        VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
          <String, Object?>{
            'pass': false,
            'status': 'fail',
            'marker': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .dynamicGainEnvelopeFailMarkerConstant,
            'proofBoundary': '',
            'nativeProofBoundary': '',
            'failureReason': 'invocation_failed',
            'lastError': 'invocation_failed',
          },
        );

    // Dynamic Gain Envelope group: mode + worker-folded telemetry gates on
    // top of the full X4 lane/identity/timing contract (allNativeLanesPass
    // consumes the envelope marker and gates in envelope mode).
    print(
      '  [LANE] Dynamic Gain Envelope: '
      'envelopeProofEnabled=${envReport.envelopeProofEnabled}, '
      'envelopeApplied=${envReport.envelopeApplied}, '
      'envelopeEvaluations=${envReport.envelopeEvaluations}, '
      'minEffectiveGain=${envReport.minEffectiveGain}, '
      'maxEffectiveGain=${envReport.maxEffectiveGain}, '
      'dynamicGainEnvelopeGatesHeld=${envReport.dynamicGainEnvelopeGatesHeld}, '
      'referenceMixChecksumOk=${envReport.referenceMixChecksumOk}, '
      'checksumsMatch=${envReport.checksumsMatch}, '
      'commandErrors=${envReport.commandErrors}, '
      'residualFramesAtEnd=${envReport.residualFramesAtEnd}, '
      'realtimeGatesHeld=${envReport.realtimeGatesHeld}, '
      'allNativeLanesPass=${envReport.allNativeLanesPass}, '
      'marker=${envReport.marker}, '
      'lastError=${envReport.lastError}',
    );

    final lastErrorOk =
        envReport.lastError.isEmpty ||
        envReport.lastError == 'none' ||
        envReport.lastError == 'null';

    final envelopePass =
        (topLevelError == null) &&
        envReport.pass &&
        envReport.marker ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .dynamicGainEnvelopePassMarkerConstant &&
        envReport.envelopeProofEnabled &&
        envReport.dynamicGainEnvelopeGatesHeld &&
        envReport.hasCanonicalProofBoundary &&
        envReport.nativeProofBoundaryOk &&
        envReport.checksumsMatch &&
        envReport.providerCountersClean &&
        envReport.sinkAccountingBalanced &&
        envReport.realtimeGatesHeld &&
        envReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit':
          'AndroidAsyncRuntimeQueueMultiSourceDynamicGainEnvelopePhysicalSmokeHarness',
      'slice':
          'P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-DYNAMIC-GAIN-ENVELOPE',
      'target': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .proofBoundaryConstant,
      'nativeTarget': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .nativeProofBoundaryConstant,
      'pass': envelopePass,
      'report': envReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_DYNAMIC_GAIN_ENVELOPE_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      envelopePass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_DYNAMIC_GAIN_ENVELOPE_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_DYNAMIC_GAIN_ENVELOPE_PHYSICAL_SMOKE_FAIL',
    );
    return envelopePass;
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
