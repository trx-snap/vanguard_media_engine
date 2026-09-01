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
// Additional sub-slices executed in sequence:
//   - X5 (P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-DYNAMIC-GAIN-ENVELOPE):
//     Dynamic Gain Envelope group (envelopeProofEnabled, envelopeApplied, envelopeEvaluations, minEffectiveGain, maxEffectiveGain, dynamicGainEnvelopeGatesHeld).
//   - X6 (P4-AUDIO-REALTIME-PLAYBACK-SINK-BRIDGE): Non-zero AudioTrack output gain set path.
//   - X7 (P4-AUDIO-FOCUS-NOISY-EVENT-HANDOFF): Focus request/abandon and becoming-noisy receiver registration/unregistration plus event-plane handoff.
//   - X8 (P4-AUDIO-FOCUS-DUCK-RESTORE-RESPONSE): Transient duck (0.1) and restore (0.5) volume response.
//   - X9 (P4-AUDIO-FOCUS-LOSS-PAUSE-RESUME-RESPONSE): Transient focus-loss pause, same-boundary gain resume, and terminal becoming-noisy pause response.
//   - X10 (P4-AUDIO-FOCUS-LOSS-PERMANENT-STOP-RESPONSE): Terminal permanent focus-loss pause and rejected same-boundary focus-gain attempt (no play, no auto-resume) response.
// Overall exit is PASS only when ALL runs pass; each phase prints its own
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

    // ── X6 (P4-AUDIO-REALTIME-PLAYBACK-SINK-BRIDGE): non-zero-gain
    // AudioTrack sink proof. Same X4/X5 path with a constant gain > 0
    // set via AudioTrack.setVolume(). PCM bytes and checksums are
    // unchanged; this proves the gain-set path only. No acoustic/audibility
    // claim; no audio focus, route-change, or dead-object recovery. ────────
    final nonZeroGainPass = await _runNonZeroGainSmoke();

    // ── X7 (P4-AUDIO-FOCUS-NOISY-EVENT-HANDOFF): focus request/abandon
    // and ACTION_AUDIO_BECOMING_NOISY receiver register/unregister plus
    // synthetic event enqueue-to-owner-thread-drain proof. No playback
    // mutation; no duck/pause/resume/restart; no acoustic claim. ─────────
    final focusNoisyPass = await _runFocusNoisySmoke();

    // ── X8 (P4-AUDIO-FOCUS-DUCK-RESTORE-RESPONSE): transient duck
    // (setVolume 0.1) and gain restore (setVolume 0.5) applied by the
    // driver owner thread from coordinator-enqueued synthetic events, over
    // the implied X7 focus/noisy handoff and 0.5 base gain. Set-value
    // telemetry only: no measured volume/dB/perceptual depth, no
    // fade/ramp, no pause/resume, no OS arbitration correctness. ─────────
    final duckRestorePass = await _runFocusDuckRestoreSmoke();

    // ── X9 (P4-AUDIO-FOCUS-LOSS-PAUSE-RESUME-RESPONSE): transient
    // focus-loss pause (AudioTrack.pause() only, PLAYSTATE_PAUSED), same
    // owner-thread-boundary focus-gain resume (play(), PLAYSTATE_PLAYING),
    // and terminal becoming-noisy pause (pause() only, no auto-resume before
    // release), applied by the driver owner thread from coordinator-enqueued
    // synthetic events over the implied X7 focus/noisy handoff and 0.5 base
    // gain. X8 duck/restore is NOT enabled. Sink-side playstate telemetry
    // only: no acoustic audibility/speaker verification, no OS focus
    // arbitration correctness, no transport/presentation pause, no
    // pause/resume SLA, no route-change/dead-object recovery, no production
    // restart policy. ───────────────────────────────────────────────────────
    final focusLossPauseResumePass = await _runFocusLossPauseResumeSmoke();

    // ── X10 (P4-AUDIO-FOCUS-LOSS-PERMANENT-STOP-RESPONSE): permanent
    // focus-loss pause (AudioTrack.pause() only, PLAYSTATE_PAUSED) at the
    // terminal EOS point, with same owner-thread-boundary rejection of the
    // synthetic focus-gain attempt (no play(), no auto-resume, autoResumeAllowed
    // remains false), applied by the driver owner thread from
    // coordinator-enqueued synthetic events over the implied X7 focus/noisy
    // handoff and 0.5 base gain. X8 duck/restore and X9 transient pause/resume
    // are NOT enabled. Sink-side playstate telemetry only: no acoustic
    // audibility/speaker verification, no OS focus arbitration correctness,
    // no transport/presentation pause, no pause/resume SLA, no route-change/
    // dead-object recovery, no production restart policy. ───────────────────
    final permanentFocusLossPass = await _runPermanentFocusLossSmoke();

    final allPass =
        pass &&
        envelopePass &&
        nonZeroGainPass &&
        focusNoisyPass &&
        duckRestorePass &&
        focusLossPauseResumePass &&
        permanentFocusLossPass;
    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS (X4 allNativeLanesPass=true, X5 envelope gates held, '
                  'X6 non-zero-gain gates held, X7 focus/noisy gates held, '
                  'X8 duck/restore gates held, '
                  'X9 focus-loss pause/resume gates held, '
                  'X10 permanent focus-loss stop gates held)'
            : 'FAIL: x4Pass=$pass, envelopePass=$envelopePass, '
                  'nonZeroGainPass=$nonZeroGainPass, '
                  'focusNoisyPass=$focusNoisyPass, '
                  'duckRestorePass=$duckRestorePass, '
                  'focusLossPauseResumePass=$focusLossPauseResumePass, '
                  'permanentFocusLossPass=$permanentFocusLossPass, '
                  'lastError=${activeReport.lastError}, error=$topLevelError';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 1500));
    exit(allPass ? 0 : 1);
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

  Future<bool> _runNonZeroGainSmoke() async {
    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_NONZERO_GAIN_SINK_SMOKE_START',
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
        '${tempDir.path}/p4_async_rt_queue_nonzero_gain_source_$timestamp.mov',
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
            nonZeroGainSinkProofEnabled: true,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_NONZERO_GAIN_SINK_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_NONZERO_GAIN_SINK_ERROR: $topLevelError',
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

    final ngReport =
        report ??
        VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
          <String, Object?>{
            'pass': false,
            'status': 'fail',
            'marker': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .nonZeroGainSinkFailMarkerConstant,
            'proofBoundary': '',
            'nativeProofBoundary': '',
            'failureReason': 'invocation_failed',
            'lastError': 'invocation_failed',
          },
        );

    // Non-Zero-Gain Sink group: gain-set fact plus existing identity/accounting
    // gates. No acoustic/audibility claim; PCM bytes and checksums unchanged.
    // Deferred: no loudness/SNR, no latency/glitch/xrun, no A/V sync, no
    // audio focus/duck/noisy, no route-change, no dead-object recovery.
    print(
      '  [LANE] Non-Zero-Gain Sink: '
      'nonZeroGainSinkProofEnabled=${ngReport.nonZeroGainSinkProofEnabled}, '
      'audioTrackGain=${ngReport.audioTrackGain}, '
      'audioTrackNonZeroGainSetOk=${ngReport.audioTrackNonZeroGainSetOk}, '
      'nonZeroGainSinkGatesHeld=${ngReport.nonZeroGainSinkGatesHeld}, '
      'checksumIdentityOk=${ngReport.checksumIdentityOk}, '
      'sinkWriteAccountingOk=${ngReport.sinkWriteAccountingOk}, '
      'frameAccountingOk=${ngReport.frameAccountingOk}, '
      'realtimeGatesHeld=${ngReport.realtimeGatesHeld}, '
      'allNativeLanesPass=${ngReport.allNativeLanesPass}, '
      'marker=${ngReport.marker}, '
      'lastError=${ngReport.lastError}',
    );

    final lastErrorOk =
        ngReport.lastError.isEmpty ||
        ngReport.lastError == 'none' ||
        ngReport.lastError == 'null';

    final nonZeroGainPass =
        (topLevelError == null) &&
        ngReport.pass &&
        ngReport.marker ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .nonZeroGainSinkPassMarkerConstant &&
        ngReport.nonZeroGainSinkProofEnabled &&
        ngReport.nonZeroGainSinkGatesHeld &&
        ngReport.audioTrackNonZeroGainSetOk &&
        ngReport.audioTrackGain > 0.0 &&
        ngReport.audioTrackGain <= 1.0 &&
        ngReport.hasCanonicalProofBoundary &&
        ngReport.nativeProofBoundaryOk &&
        ngReport.checksumsMatch &&
        ngReport.providerCountersClean &&
        ngReport.sinkAccountingBalanced &&
        ngReport.realtimeGatesHeld &&
        ngReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAsyncRuntimeQueueNonZeroGainSinkPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-SINK-BRIDGE',
      'target': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .proofBoundaryConstant,
      'nativeTarget': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .nativeProofBoundaryConstant,
      'pass': nonZeroGainPass,
      'report': ngReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_NONZERO_GAIN_SINK_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      nonZeroGainPass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_NONZERO_GAIN_SINK_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_NONZERO_GAIN_SINK_PHYSICAL_SMOKE_FAIL',
    );
    return nonZeroGainPass;
  }

  Future<bool> _runFocusNoisySmoke() async {
    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_NOISY_EVENT_HANDOFF_SMOKE_START',
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
        '${tempDir.path}/p4_async_rt_queue_focus_noisy_source_$timestamp.mov',
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
            focusNoisyEventHandoffProofEnabled: true,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_NOISY_EVENT_HANDOFF_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_NOISY_EVENT_HANDOFF_ERROR: $topLevelError',
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

    final fnReport =
        report ??
        VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
          <String, Object?>{
            'pass': false,
            'status': 'fail',
            'marker': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .focusNoisyEventHandoffFailMarkerConstant,
            'proofBoundary': '',
            'nativeProofBoundary': '',
            'failureReason': 'invocation_failed',
            'lastError': 'invocation_failed',
          },
        );

    // Focus / Noisy Event-Plane group.
    print(
      '  [LANE] Focus/Noisy Event-Plane: '
      'focusNoisyEventHandoffProofEnabled=${fnReport.focusNoisyEventHandoffProofEnabled}, '
      'audioFocusRequestGrantedOk=${fnReport.audioFocusRequestGrantedOk}, '
      'audioFocusAbandonedOk=${fnReport.audioFocusAbandonedOk}, '
      'noisyReceiverRegisteredOk=${fnReport.noisyReceiverRegisteredOk}, '
      'noisyReceiverUnregisteredOk=${fnReport.noisyReceiverUnregisteredOk}, '
      'focusNoisySyntheticEventsPosted=${fnReport.focusNoisySyntheticEventsPosted}, '
      'focusNoisyEventsEnqueued=${fnReport.focusNoisyEventsEnqueued}, '
      'focusNoisyEventsDrained=${fnReport.focusNoisyEventsDrained}, '
      'focusNoisyEventsDropped=${fnReport.focusNoisyEventsDropped}, '
      'focusNoisyOwnerThreadDrainOk=${fnReport.focusNoisyOwnerThreadDrainOk}, '
      'focusNoisyEventHandoffGatesHeld=${fnReport.focusNoisyEventHandoffGatesHeld}, '
      'allNativeLanesPass=${fnReport.allNativeLanesPass}, '
      'marker=${fnReport.marker}, '
      'lastError=${fnReport.lastError}',
    );

    final lastErrorOk =
        fnReport.lastError.isEmpty ||
        fnReport.lastError == 'none' ||
        fnReport.lastError == 'null';

    final focusNoisyPass =
        (topLevelError == null) &&
        fnReport.pass &&
        fnReport.marker ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .focusNoisyEventHandoffPassMarkerConstant &&
        fnReport.focusNoisyEventHandoffProofEnabled &&
        fnReport.focusNoisyEventHandoffGatesHeld &&
        fnReport.audioFocusRequestGrantedOk &&
        fnReport.audioFocusAbandonedOk &&
        fnReport.noisyReceiverRegisteredOk &&
        fnReport.noisyReceiverUnregisteredOk &&
        fnReport.focusNoisySyntheticEventsPosted > 0 &&
        fnReport.focusNoisyEventsEnqueued > 0 &&
        fnReport.focusNoisyEventsDropped == 0 &&
        fnReport.focusNoisyEventsDrained == fnReport.focusNoisyEventsEnqueued &&
        fnReport.focusNoisyOwnerThreadDrainOk &&
        fnReport.hasCanonicalProofBoundary &&
        fnReport.nativeProofBoundaryOk &&
        fnReport.checksumsMatch &&
        fnReport.providerCountersClean &&
        fnReport.sinkAccountingBalanced &&
        fnReport.realtimeGatesHeld &&
        fnReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit':
          'AndroidAsyncRuntimeQueueFocusNoisyEventHandoffPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-FOCUS-NOISY-EVENT-HANDOFF',
      'target': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .proofBoundaryConstant,
      'nativeTarget': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .nativeProofBoundaryConstant,
      'pass': focusNoisyPass,
      'report': fnReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_NOISY_EVENT_HANDOFF_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      focusNoisyPass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_NOISY_EVENT_HANDOFF_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_NOISY_EVENT_HANDOFF_PHYSICAL_SMOKE_FAIL',
    );
    return focusNoisyPass;
  }

  Future<bool> _runFocusDuckRestoreSmoke() async {
    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_DUCK_RESTORE_SMOKE_START',
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
        '${tempDir.path}/p4_async_rt_queue_focus_duck_restore_source_$timestamp.mov',
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
            focusDuckRestoreProofEnabled: true,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_DUCK_RESTORE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_DUCK_RESTORE_ERROR: $topLevelError',
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

    final drReport =
        report ??
        VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
          <String, Object?>{
            'pass': false,
            'status': 'fail',
            'marker': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .focusDuckRestoreFailMarkerConstant,
            'proofBoundary': '',
            'nativeProofBoundary': '',
            'failureReason': 'invocation_failed',
            'lastError': 'invocation_failed',
          },
        );

    // Focus-Duck/Restore Response group. Set-value telemetry only: base
    // 0.5 -> ducked 0.1 -> restored 0.5, each via one owner-thread
    // setVolume SUCCESS on strictly ordered drain passes.
    print(
      '  [LANE] Focus-Duck/Restore Response: '
      'focusDuckRestoreProofEnabled=${drReport.focusDuckRestoreProofEnabled}, '
      'focusListenerRegisteredOk=${drReport.focusListenerRegisteredOk}, '
      'syntheticDuckPosted=${drReport.syntheticDuckPosted}, '
      'syntheticGainPosted=${drReport.syntheticGainPosted}, '
      'duckAppliedCount=${drReport.duckAppliedCount}, '
      'restoreAppliedCount=${drReport.restoreAppliedCount}, '
      'duckSetVolumeOk=${drReport.duckSetVolumeOk}, '
      'restoreSetVolumeOk=${drReport.restoreSetVolumeOk}, '
      'duckDrainSeq=${drReport.duckDrainSeq}, '
      'restoreDrainSeq=${drReport.restoreDrainSeq}, '
      'baseVolume=${drReport.baseVolume}, '
      'duckedVolume=${drReport.duckedVolume}, '
      'restoredVolume=${drReport.restoredVolume}, '
      'finalVolume=${drReport.finalVolume}, '
      'focusEventsDropped=${drReport.focusEventsDropped}, '
      'duckEventsEnqueued=${drReport.duckEventsEnqueued}, '
      'duckEventsDrained=${drReport.duckEventsDrained}, '
      'gainEventsEnqueued=${drReport.gainEventsEnqueued}, '
      'gainEventsDrained=${drReport.gainEventsDrained}, '
      'realFocusChangeCallbackCount=${drReport.realFocusChangeCallbackCount}, '
      'focusDuckRestoreGatesHeld=${drReport.focusDuckRestoreGatesHeld}, '
      'focusNoisyEventHandoffGatesHeld=${drReport.focusNoisyEventHandoffGatesHeld}, '
      'allNativeLanesPass=${drReport.allNativeLanesPass}, '
      'marker=${drReport.marker}, '
      'lastError=${drReport.lastError}',
    );

    final lastErrorOk =
        drReport.lastError.isEmpty ||
        drReport.lastError == 'none' ||
        drReport.lastError == 'null';

    final duckRestorePass =
        (topLevelError == null) &&
        drReport.pass &&
        drReport.marker ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .focusDuckRestorePassMarkerConstant &&
        drReport.focusDuckRestoreProofEnabled &&
        drReport.focusDuckRestoreGatesHeld &&
        drReport.focusListenerRegisteredOk &&
        drReport.syntheticDuckPosted == 1 &&
        drReport.syntheticGainPosted == 1 &&
        drReport.duckAppliedCount == 1 &&
        drReport.restoreAppliedCount == 1 &&
        drReport.duckSetVolumeOk &&
        drReport.restoreSetVolumeOk &&
        drReport.duckDrainSeq >= 0 &&
        drReport.restoreDrainSeq > drReport.duckDrainSeq &&
        drReport.focusEventsDropped == 0 &&
        drReport.focusNoisyEventHandoffGatesHeld &&
        drReport.hasCanonicalProofBoundary &&
        drReport.nativeProofBoundaryOk &&
        drReport.checksumsMatch &&
        drReport.providerCountersClean &&
        drReport.sinkAccountingBalanced &&
        drReport.realtimeGatesHeld &&
        drReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAsyncRuntimeQueueFocusDuckRestorePhysicalSmokeHarness',
      'slice': 'P4-AUDIO-FOCUS-DUCK-RESTORE-RESPONSE',
      'target': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .focusDuckRestoreProofBoundaryConstant,
      'nativeTarget': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .nativeProofBoundaryConstant,
      'pass': duckRestorePass,
      'report': drReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_DUCK_RESTORE_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      duckRestorePass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_DUCK_RESTORE_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_DUCK_RESTORE_PHYSICAL_SMOKE_FAIL',
    );
    return duckRestorePass;
  }

  Future<bool> _runFocusLossPauseResumeSmoke() async {
    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_LOSS_PAUSE_RESUME_SMOKE_START',
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
        '${tempDir.path}/p4_async_rt_queue_focus_loss_pause_resume_source_$timestamp.mov',
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
            focusLossPauseResumeProofEnabled: true,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_LOSS_PAUSE_RESUME_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_LOSS_PAUSE_RESUME_ERROR: $topLevelError',
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

    final prReport =
        report ??
        VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
          <String, Object?>{
            'pass': false,
            'status': 'fail',
            'marker': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .focusLossPauseResumeFailMarkerConstant,
            'proofBoundary': '',
            'nativeProofBoundary': '',
            'failureReason': 'invocation_failed',
            'lastError': 'invocation_failed',
          },
        );

    // Focus-Loss Pause/Resume Response group. Sink-side AudioTrack playstate
    // telemetry only: transient loss -> pause() -> PAUSED; focus gain (same
    // owner-thread boundary) -> play() -> PLAYING; becoming-noisy (terminal
    // EOS point) -> pause() -> PAUSED, held until release. Applied-event
    // sequence is a monotonic ordinal, not a drain-pass index.
    print(
      '  [LANE] Focus-Loss Pause/Resume Response: '
      'focusLossPauseResumeProofEnabled=${prReport.focusLossPauseResumeProofEnabled}, '
      'focusDuckRestoreProofEnabled=${prReport.focusDuckRestoreProofEnabled}, '
      'focusLossPauseOk=${prReport.focusLossPauseOk}, '
      'focusGainResumeOk=${prReport.focusGainResumeOk}, '
      'becomingNoisyPauseOk=${prReport.becomingNoisyPauseOk}, '
      'terminalPlayStatePausedBeforeReleaseOk=${prReport.terminalPlayStatePausedBeforeReleaseOk}, '
      'syntheticTransientLossPosted=${prReport.syntheticTransientLossPosted}, '
      'syntheticFocusGainPosted=${prReport.syntheticFocusGainPosted}, '
      'syntheticBecomingNoisyPosted=${prReport.syntheticBecomingNoisyPosted}, '
      'transientLossEventsEnqueued=${prReport.transientLossEventsEnqueued}, '
      'focusGainEventsEnqueued=${prReport.focusGainEventsEnqueued}, '
      'becomingNoisyEventsEnqueued=${prReport.becomingNoisyEventsEnqueued}, '
      'transientLossEventsDrained=${prReport.transientLossEventsDrained}, '
      'focusGainEventsDrained=${prReport.focusGainEventsDrained}, '
      'becomingNoisyEventsDrained=${prReport.becomingNoisyEventsDrained}, '
      'focusLossPauseResumeEventsDropped=${prReport.focusLossPauseResumeEventsDropped}, '
      'transientLossAppliedCount=${prReport.transientLossAppliedCount}, '
      'focusGainAppliedCount=${prReport.focusGainAppliedCount}, '
      'becomingNoisyAppliedCount=${prReport.becomingNoisyAppliedCount}, '
      'transientPauseApplySeq=${prReport.transientPauseApplySeq}, '
      'focusGainResumeApplySeq=${prReport.focusGainResumeApplySeq}, '
      'noisyPauseApplySeq=${prReport.noisyPauseApplySeq}, '
      'audioTrackGain=${prReport.audioTrackGain}, '
      'focusLossPauseResumeGatesHeld=${prReport.focusLossPauseResumeGatesHeld}, '
      'focusNoisyEventHandoffGatesHeld=${prReport.focusNoisyEventHandoffGatesHeld}, '
      'hasCanonicalProofBoundary=${prReport.hasCanonicalProofBoundary}, '
      'allNativeLanesPass=${prReport.allNativeLanesPass}, '
      'marker=${prReport.marker}, '
      'lastError=${prReport.lastError}',
    );

    final lastErrorOk =
        prReport.lastError.isEmpty ||
        prReport.lastError == 'none' ||
        prReport.lastError == 'null';

    final focusLossPauseResumePass =
        (topLevelError == null) &&
        prReport.pass &&
        prReport.marker ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .focusLossPauseResumePassMarkerConstant &&
        prReport.focusLossPauseResumeProofEnabled &&
        !prReport.focusDuckRestoreProofEnabled &&
        prReport.focusLossPauseResumeGatesHeld &&
        prReport.focusLossPauseOk &&
        prReport.focusGainResumeOk &&
        prReport.becomingNoisyPauseOk &&
        prReport.terminalPlayStatePausedBeforeReleaseOk &&
        prReport.syntheticTransientLossPosted == 1 &&
        prReport.syntheticFocusGainPosted == 1 &&
        prReport.syntheticBecomingNoisyPosted == 1 &&
        prReport.transientLossEventsEnqueued == 1 &&
        prReport.focusGainEventsEnqueued == 1 &&
        prReport.becomingNoisyEventsEnqueued == 1 &&
        prReport.transientLossEventsDrained == 1 &&
        prReport.focusGainEventsDrained == 1 &&
        prReport.becomingNoisyEventsDrained == 1 &&
        prReport.focusLossPauseResumeEventsDropped == 0 &&
        prReport.transientLossAppliedCount == 1 &&
        prReport.focusGainAppliedCount == 1 &&
        prReport.becomingNoisyAppliedCount == 1 &&
        prReport.transientPauseApplySeq >= 0 &&
        prReport.focusGainResumeApplySeq > prReport.transientPauseApplySeq &&
        prReport.noisyPauseApplySeq > prReport.focusGainResumeApplySeq &&
        prReport.focusNoisyEventHandoffGatesHeld &&
        prReport.hasCanonicalProofBoundary &&
        prReport.proofBoundary ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .focusLossPauseResumeProofBoundaryConstant &&
        prReport.nativeProofBoundaryOk &&
        prReport.checksumsMatch &&
        prReport.providerCountersClean &&
        prReport.sinkAccountingBalanced &&
        prReport.realtimeGatesHeld &&
        prReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit':
          'AndroidAsyncRuntimeQueueFocusLossPauseResumePhysicalSmokeHarness',
      'slice': 'P4-AUDIO-FOCUS-LOSS-PAUSE-RESUME-RESPONSE',
      'target': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .focusLossPauseResumeProofBoundaryConstant,
      'nativeTarget': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .nativeProofBoundaryConstant,
      'pass': focusLossPauseResumePass,
      'report': prReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_LOSS_PAUSE_RESUME_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      focusLossPauseResumePass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_LOSS_PAUSE_RESUME_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_FOCUS_LOSS_PAUSE_RESUME_PHYSICAL_SMOKE_FAIL',
    );
    return focusLossPauseResumePass;
  }

  Future<bool> _runPermanentFocusLossSmoke() async {
    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_PERMANENT_FOCUS_LOSS_SMOKE_START',
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
        '${tempDir.path}/p4_async_rt_queue_perm_focus_loss_source_$timestamp.mov',
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
            permanentFocusLossProofEnabled: true,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_PERMANENT_FOCUS_LOSS_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_PERMANENT_FOCUS_LOSS_ERROR: $topLevelError',
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

    final pflReport =
        report ??
        VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
          <String, Object?>{
            'pass': false,
            'status': 'fail',
            'marker': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .permanentFocusLossFailMarkerConstant,
            'proofBoundary': '',
            'nativeProofBoundary': '',
            'failureReason': 'invocation_failed',
            'lastError': 'invocation_failed',
          },
        );

    // Permanent Focus-Loss Stop Response group. Sink-side AudioTrack
    // playstate telemetry only: permanent loss (terminal EOS point) ->
    // pause() -> PAUSED; synthetic focus-gain attempt (same owner-thread
    // boundary) -> rejected (no play(), autoResumeAllowed=false), held until
    // release. Applied-event sequence is a monotonic ordinal, not a
    // drain-pass index.
    print(
      '  [LANE] Permanent Focus-Loss Stop Response: '
      'permanentFocusLossProofEnabled=${pflReport.permanentFocusLossProofEnabled}, '
      'focusDuckRestoreProofEnabled=${pflReport.focusDuckRestoreProofEnabled}, '
      'focusLossPauseResumeProofEnabled=${pflReport.focusLossPauseResumeProofEnabled}, '
      'permanentFocusLossPauseOk=${pflReport.permanentFocusLossPauseOk}, '
      'focusGainAutoResumeRejectedOk=${pflReport.focusGainAutoResumeRejectedOk}, '
      'autoResumeAllowed=${pflReport.autoResumeAllowed}, '
      'terminalPlayStatePausedBeforeReleasePermanentOk=${pflReport.terminalPlayStatePausedBeforeReleasePermanentOk}, '
      'syntheticPermanentLossPosted=${pflReport.syntheticPermanentLossPosted}, '
      'syntheticFocusGainAttemptPosted=${pflReport.syntheticFocusGainAttemptPosted}, '
      'permanentLossEventsEnqueued=${pflReport.permanentLossEventsEnqueued}, '
      'focusGainAttemptEventsEnqueued=${pflReport.focusGainAttemptEventsEnqueued}, '
      'permanentLossEventsDrained=${pflReport.permanentLossEventsDrained}, '
      'focusGainAttemptEventsDrained=${pflReport.focusGainAttemptEventsDrained}, '
      'permanentFocusLossEventsDropped=${pflReport.permanentFocusLossEventsDropped}, '
      'permanentLossAppliedCount=${pflReport.permanentLossAppliedCount}, '
      'focusGainAttemptRejectedCount=${pflReport.focusGainAttemptRejectedCount}, '
      'permanentLossApplySeq=${pflReport.permanentLossApplySeq}, '
      'focusGainAttemptApplySeq=${pflReport.focusGainAttemptApplySeq}, '
      'audioTrackGain=${pflReport.audioTrackGain}, '
      'permanentFocusLossGatesHeld=${pflReport.permanentFocusLossGatesHeld}, '
      'focusNoisyEventHandoffGatesHeld=${pflReport.focusNoisyEventHandoffGatesHeld}, '
      'hasCanonicalProofBoundary=${pflReport.hasCanonicalProofBoundary}, '
      'allNativeLanesPass=${pflReport.allNativeLanesPass}, '
      'marker=${pflReport.marker}, '
      'lastError=${pflReport.lastError}',
    );

    final lastErrorOk =
        pflReport.lastError.isEmpty ||
        pflReport.lastError == 'none' ||
        pflReport.lastError == 'null';

    final permanentFocusLossPass =
        (topLevelError == null) &&
        pflReport.pass &&
        pflReport.marker ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .permanentFocusLossPassMarkerConstant &&
        pflReport.permanentFocusLossProofEnabled &&
        !pflReport.focusDuckRestoreProofEnabled &&
        !pflReport.focusLossPauseResumeProofEnabled &&
        pflReport.permanentFocusLossGatesHeld &&
        pflReport.permanentFocusLossPauseOk &&
        pflReport.focusGainAutoResumeRejectedOk &&
        !pflReport.autoResumeAllowed &&
        pflReport.terminalPlayStatePausedBeforeReleasePermanentOk &&
        pflReport.syntheticPermanentLossPosted == 1 &&
        pflReport.syntheticFocusGainAttemptPosted == 1 &&
        pflReport.permanentLossEventsEnqueued == 1 &&
        pflReport.focusGainAttemptEventsEnqueued == 1 &&
        pflReport.permanentLossEventsDrained == 1 &&
        pflReport.focusGainAttemptEventsDrained == 1 &&
        pflReport.permanentFocusLossEventsDropped == 0 &&
        pflReport.permanentLossAppliedCount == 1 &&
        pflReport.focusGainAttemptRejectedCount == 1 &&
        pflReport.permanentLossApplySeq >= 0 &&
        pflReport.focusGainAttemptApplySeq > pflReport.permanentLossApplySeq &&
        pflReport.focusNoisyEventHandoffGatesHeld &&
        pflReport.hasCanonicalProofBoundary &&
        pflReport.proofBoundary ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .permanentFocusLossProofBoundaryConstant &&
        pflReport.nativeProofBoundaryOk &&
        pflReport.checksumsMatch &&
        pflReport.providerCountersClean &&
        pflReport.sinkAccountingBalanced &&
        pflReport.realtimeGatesHeld &&
        pflReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAsyncRuntimeQueuePermanentFocusLossPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-FOCUS-LOSS-PERMANENT-STOP-RESPONSE',
      'target': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .permanentFocusLossProofBoundaryConstant,
      'nativeTarget': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .nativeProofBoundaryConstant,
      'pass': permanentFocusLossPass,
      'report': pflReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_PERMANENT_FOCUS_LOSS_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      permanentFocusLossPass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_PERMANENT_FOCUS_LOSS_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_PERMANENT_FOCUS_LOSS_PHYSICAL_SMOKE_FAIL',
    );
    return permanentFocusLossPass;
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
