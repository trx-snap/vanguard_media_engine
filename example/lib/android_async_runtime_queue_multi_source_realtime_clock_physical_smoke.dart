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
//   - X11 (P4-AUDIO-ROUTE-CHANGE-EVENT-HANDOFF-RESPONSE): Real routing-listener register/remove lifecycle, synthetic route_changed handoff with routed-device telemetry, and terminal route_disconnect fail-closed pause (no recreate/restart) response.
//   - X12 (P4-AUDIO-DEAD-OBJECT-RECOVERY-RESPONSE): SYNTHETIC ERROR_DEAD_OBJECT injected once on the owner-thread write path (no real OS dead object forced), old track released once, one same-parameter AudioTrack recreated, STATE_INITIALIZED asserted, base gain 0.5 reapplied, play() asserted, same unwritten slice resumed with lossless sink accounting.
//   - X13 (P4-AUDIO-AUDIOTRACK-TIMESTAMP-STABILIZATION): AudioTrack timestamp stabilization diagnostic proof executed twice:
//     1) Standalone (muted default sink): proves pre-seek + post-seek timestamp stabilization (2 generations, 0 recreate resets), monotonic frame advancement with 0 strict regressions, no poll inside write loop, and zero feedback into native pacing.
//     2) Composed with X12 (dead-object recovery, base gain 0.5): proves timestamp stabilization across all 3 generations (pre-seek, post-seek, post-recreate), with baseline reset on recreation and X12 dead-object recovery gates intact.
//   - X14 (P4-AUDIO-AUDIBLE-SPEAKER-PLAYBACK): Audible built-in-speaker playback proof:
//     base gain 0.5, owner-thread routed-device sample after each epoch's play() asserting
//     TYPE_BUILTIN_SPEAKER (2), lossless sink accounting and reference mix checksum identity.
//     Automated pass validates OS routing report and telemetry only; manual acoustic observation
//     required for human hearing confirmation.
//   - X15 (P4-AUDIO-ASYNC-RUNTIME-QUEUE-PAUSE-RESUME): Native transport pause/resume proof:
//     worker steady_clock pause/resume commands (no caller time), AudioTrack playstate pause (2) and resume (3),
//     ~150ms hold with frozen dispatch and pushed counts, worker paused waits > 0, paused interval
//     excluded from native timing gate, 4 commands processed, muted sink, lossless sink accounting
//     and reference mix checksum identity. Muted diagnostic only: no acoustic observation needed.
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

    // ── X11 (P4-AUDIO-ROUTE-CHANGE-EVENT-HANDOFF-RESPONSE): real
    // AudioRouting.OnRoutingChangedListener added to the AudioTrack by the
    // driver owner thread and removed exactly once before release; ONE
    // synthetic route_changed drained on the owner thread with routed-device
    // telemetry sampled; ONE synthetic route_disconnect enqueued/drained at
    // the terminal EOS point (AudioTrack.pause() only, PLAYSTATE_PAUSED, no
    // recreate/restart), over the implied X7 focus/noisy handoff and 0.5
    // base gain. X8 duck/restore, X9 transient pause/resume and X10
    // permanent stop are NOT enabled. Sink-side telemetry only: no seamless
    // route recreation/hot-swap, no stream re-anchor, no dead-object
    // recovery, no OS route arbitration correctness, no acoustic
    // audibility/speaker verification, no transport/presentation pause, no
    // pause/resume SLA, no production restart policy. ─────────────────────
    final routeChangeEventHandoffPass =
        await _runRouteChangeEventHandoffSmoke();

    // ── X12 (P4-AUDIO-DEAD-OBJECT-RECOVERY-RESPONSE): ONE SYNTHETIC
    // ERROR_DEAD_OBJECT substituted for a non-blocking write result on the
    // driver owner thread in the post-seek epoch (no bytes consumed, no
    // real OS dead object forced); the old AudioTrack released exactly
    // once; ONE AudioTrack recreated with identical format/buffer/mode
    // parameters, STATE_INITIALIZED asserted, base gain 0.5 reapplied,
    // play() asserted PLAYSTATE_PLAYING; the same unwritten ByteBuffer
    // slice resumed with lossless sink accounting and checksum identity.
    // Isolated lane: X7 focus/noisy, X8 duck/restore, X9 transient
    // pause/resume, X10 permanent stop and X11 route-change handoff are NOT
    // enabled. Sink-side proof only: no acoustic audibility/speaker
    // verification, no seamless hardware hot-swap, no OS route
    // arbitration, no A/V sync, no latency/glitch/xrun/underrun freedom,
    // no production restart policy. ───────────────────────────────────────
    final deadObjectRecoveryPass = await _runDeadObjectRecoverySmoke();

    // ── X13 (P4-AUDIO-AUDIOTRACK-TIMESTAMP-STABILIZATION - standalone):
    // AudioTrack timestamp poll cadence and per-epoch frame monotonicity
    // diagnostic gate over the muted default sink. Pre-seek and post-seek
    // generations stabilize within warmup budget; framePosition advances
    // monotonically with zero strict regressions; no poll inside write loop;
    // timestamp never feeds back into native pacing or write accounting.
    // Diagnostic only: no presentation clock, latency, A/V sync, drift, or
    // HAL accuracy claims. ───────────────────────────────────────────────────
    final timestampStabilizationPass = await _runTimestampStabilizationSmoke();

    // ── X13 + X12 (P4-AUDIO-AUDIOTRACK-TIMESTAMP-STABILIZATION composed
    // with DEAD-OBJECT-RECOVERY): AudioTrack timestamp stabilization over the
    // X12 synthetic dead-object recovery response path (0.5 base gain).
    // Baseline resets on seek and after synthetic dead-object recreation;
    // all 3 generations (pre-seek, post-seek, post-recreate) stabilize with
    // positive advances, zero regressions, lossless sink accounting, and
    // X12 dead-object recovery held. ─────────────────────────────────────────
    final timestampDeadObjectPass =
        await _runTimestampStabilizationDeadObjectRecoverySmoke();

    // ── X14 (P4-AUDIO-AUDIBLE-SPEAKER-PLAYBACK): audible built-in-speaker
    // route diagnostic proof (0.5 base gain). Proves owner-thread
    // routed-device sample after each epoch's play() reports
    // TYPE_BUILTIN_SPEAKER (2), base gain 0.5, and lossless sink accounting
    // / checksum identity. Preceded by an acoustic warning / countdown for
    // manual listening observation. ─────────────────────────────────────────
    final audibleSpeakerPlaybackPass = await _runAudibleSpeakerPlaybackSmoke();

    // ── X15 (P4-AUDIO-ASYNC-RUNTIME-QUEUE-PAUSE-RESUME): native transport
    // pause/resume diagnostic proof (muted default sink). Proves worker
    // steady_clock pause/resume commands without caller-supplied time, sink
    // AudioTrack playstate pause (2) and resume (3), ~150ms bounded hold with
    // frozen dispatch/pushed counts, worker paused waits > 0, paused interval
    // excluded from native timing gate, 4 commands processed, and lossless
    // sink accounting / checksum identity. Muted diagnostic only: no audible
    // output, no speaker route, no production presentation pause, no
    // pause/resume SLA, no A/V sync. ───────────────────────────────────────
    final pauseResumePass = await _runPauseResumeSmoke();

    final allPass =
        pass &&
        envelopePass &&
        nonZeroGainPass &&
        focusNoisyPass &&
        duckRestorePass &&
        focusLossPauseResumePass &&
        permanentFocusLossPass &&
        routeChangeEventHandoffPass &&
        deadObjectRecoveryPass &&
        timestampStabilizationPass &&
        timestampDeadObjectPass &&
        audibleSpeakerPlaybackPass &&
        pauseResumePass;
    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS (X4 allNativeLanesPass=true, X5 envelope gates held, '
                  'X6 non-zero-gain gates held, X7 focus/noisy gates held, '
                  'X8 duck/restore gates held, '
                  'X9 focus-loss pause/resume gates held, '
                  'X10 permanent focus-loss stop gates held, '
                  'X11 route-change event-handoff gates held, '
                  'X12 dead-object recovery gates held, '
                  'X13 timestamp stabilization gates held, '
                  'X13+X12 timestamp dead-object recovery gates held, '
                  'X14 audible speaker playback gates held, '
                  'X15 pause/resume gates held)'
            : 'FAIL: x4Pass=$pass, envelopePass=$envelopePass, '
                  'nonZeroGainPass=$nonZeroGainPass, '
                  'focusNoisyPass=$focusNoisyPass, '
                  'duckRestorePass=$duckRestorePass, '
                  'focusLossPauseResumePass=$focusLossPauseResumePass, '
                  'permanentFocusLossPass=$permanentFocusLossPass, '
                  'routeChangeEventHandoffPass=$routeChangeEventHandoffPass, '
                  'deadObjectRecoveryPass=$deadObjectRecoveryPass, '
                  'timestampStabilizationPass=$timestampStabilizationPass, '
                  'timestampDeadObjectPass=$timestampDeadObjectPass, '
                  'audibleSpeakerPlaybackPass=$audibleSpeakerPlaybackPass, '
                  'pauseResumePass=$pauseResumePass, '
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

  Future<bool> _runRouteChangeEventHandoffSmoke() async {
    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_ROUTE_CHANGE_EVENT_HANDOFF_SMOKE_START',
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
        '${tempDir.path}/p4_async_rt_queue_route_change_handoff_source_$timestamp.mov',
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
            routeChangeEventHandoffProofEnabled: true,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_ROUTE_CHANGE_EVENT_HANDOFF_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_ROUTE_CHANGE_EVENT_HANDOFF_ERROR: $topLevelError',
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

    final rcReport =
        report ??
        VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
          <String, Object?>{
            'pass': false,
            'status': 'fail',
            'marker': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .routeChangeEventHandoffFailMarkerConstant,
            'proofBoundary': '',
            'nativeProofBoundary': '',
            'failureReason': 'invocation_failed',
            'lastError': 'invocation_failed',
          },
        );

    // Route-Change Event-Handoff Response group. Real routing listener
    // added/removed exactly once by the driver owner thread; synthetic
    // route_changed (pre-start) -> owner-thread drain -> routed-device
    // telemetry sampled; synthetic route_disconnect (terminal EOS point,
    // same owner-thread boundary) -> pause() -> PAUSED, held until release
    // (no recreate/restart). Applied-event sequence is a monotonic ordinal,
    // not a drain-pass index; real routing callbacks are telemetry only.
    print(
      '  [LANE] Route-Change Event-Handoff Response: '
      'routeChangeEventHandoffProofEnabled=${rcReport.routeChangeEventHandoffProofEnabled}, '
      'focusDuckRestoreProofEnabled=${rcReport.focusDuckRestoreProofEnabled}, '
      'focusLossPauseResumeProofEnabled=${rcReport.focusLossPauseResumeProofEnabled}, '
      'permanentFocusLossProofEnabled=${rcReport.permanentFocusLossProofEnabled}, '
      'routingListenerRegisteredOk=${rcReport.routingListenerRegisteredOk}, '
      'routingListenerUnregisteredOk=${rcReport.routingListenerUnregisteredOk}, '
      'routeChangeObservationOk=${rcReport.routeChangeObservationOk}, '
      'routeDisconnectFailClosedPauseOk=${rcReport.routeDisconnectFailClosedPauseOk}, '
      'terminalPlayStatePausedBeforeReleaseRouteChangeOk=${rcReport.terminalPlayStatePausedBeforeReleaseRouteChangeOk}, '
      'syntheticRouteChangedPosted=${rcReport.syntheticRouteChangedPosted}, '
      'syntheticRouteDisconnectPosted=${rcReport.syntheticRouteDisconnectPosted}, '
      'routeChangedEventsEnqueued=${rcReport.routeChangedEventsEnqueued}, '
      'routeDisconnectEventsEnqueued=${rcReport.routeDisconnectEventsEnqueued}, '
      'routeChangedEventsDrained=${rcReport.routeChangedEventsDrained}, '
      'routeDisconnectEventsDrained=${rcReport.routeDisconnectEventsDrained}, '
      'routeChangeEventsDropped=${rcReport.routeChangeEventsDropped}, '
      'routeChangedAppliedCount=${rcReport.routeChangedAppliedCount}, '
      'routeDisconnectAppliedCount=${rcReport.routeDisconnectAppliedCount}, '
      'routeChangedApplySeq=${rcReport.routeChangedApplySeq}, '
      'routeDisconnectApplySeq=${rcReport.routeDisconnectApplySeq}, '
      'realRoutingChangedCallbackCount=${rcReport.realRoutingChangedCallbackCount}, '
      'playStateAfterRouteDisconnectPause=${rcReport.playStateAfterRouteDisconnectPause}, '
      'playStateAtReleaseRouteChange=${rcReport.playStateAtReleaseRouteChange}, '
      'audioTrackGain=${rcReport.audioTrackGain}, '
      'routeChangeEventHandoffGatesHeld=${rcReport.routeChangeEventHandoffGatesHeld}, '
      'focusNoisyEventHandoffGatesHeld=${rcReport.focusNoisyEventHandoffGatesHeld}, '
      'hasCanonicalProofBoundary=${rcReport.hasCanonicalProofBoundary}, '
      'allNativeLanesPass=${rcReport.allNativeLanesPass}, '
      'marker=${rcReport.marker}, '
      'lastError=${rcReport.lastError}',
    );

    final lastErrorOk =
        rcReport.lastError.isEmpty ||
        rcReport.lastError == 'none' ||
        rcReport.lastError == 'null';

    final routeChangeEventHandoffPass =
        (topLevelError == null) &&
        rcReport.pass &&
        rcReport.marker ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .routeChangeEventHandoffPassMarkerConstant &&
        rcReport.routeChangeEventHandoffProofEnabled &&
        !rcReport.focusDuckRestoreProofEnabled &&
        !rcReport.focusLossPauseResumeProofEnabled &&
        !rcReport.permanentFocusLossProofEnabled &&
        rcReport.routeChangeEventHandoffGatesHeld &&
        rcReport.routingListenerRegisteredOk &&
        rcReport.routingListenerUnregisteredOk &&
        rcReport.routeChangeObservationOk &&
        rcReport.routeDisconnectFailClosedPauseOk &&
        rcReport.terminalPlayStatePausedBeforeReleaseRouteChangeOk &&
        rcReport.syntheticRouteChangedPosted == 1 &&
        rcReport.syntheticRouteDisconnectPosted == 1 &&
        rcReport.routeChangedEventsEnqueued >= 1 &&
        rcReport.routeChangedEventsDrained ==
            rcReport.routeChangedEventsEnqueued &&
        rcReport.routeDisconnectEventsEnqueued == 1 &&
        rcReport.routeDisconnectEventsDrained == 1 &&
        rcReport.routeChangeEventsDropped == 0 &&
        rcReport.routeChangedAppliedCount >= 1 &&
        rcReport.routeDisconnectAppliedCount == 1 &&
        rcReport.routeChangedApplySeq >= 0 &&
        rcReport.routeDisconnectApplySeq > rcReport.routeChangedApplySeq &&
        rcReport.focusNoisyEventHandoffGatesHeld &&
        rcReport.hasCanonicalProofBoundary &&
        rcReport.proofBoundary ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .routeChangeEventHandoffProofBoundaryConstant &&
        rcReport.nativeProofBoundaryOk &&
        rcReport.checksumsMatch &&
        rcReport.providerCountersClean &&
        rcReport.sinkAccountingBalanced &&
        rcReport.realtimeGatesHeld &&
        rcReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit':
          'AndroidAsyncRuntimeQueueRouteChangeEventHandoffPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-ROUTE-CHANGE-EVENT-HANDOFF-RESPONSE',
      'target': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .routeChangeEventHandoffProofBoundaryConstant,
      'nativeTarget': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .nativeProofBoundaryConstant,
      'pass': routeChangeEventHandoffPass,
      'report': rcReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_ROUTE_CHANGE_EVENT_HANDOFF_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      routeChangeEventHandoffPass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_ROUTE_CHANGE_EVENT_HANDOFF_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_ROUTE_CHANGE_EVENT_HANDOFF_PHYSICAL_SMOKE_FAIL',
    );
    return routeChangeEventHandoffPass;
  }

  Future<bool> _runDeadObjectRecoverySmoke() async {
    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_DEAD_OBJECT_RECOVERY_SMOKE_START',
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
        '${tempDir.path}/p4_async_rt_queue_dead_object_recovery_source_$timestamp.mov',
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
            deadObjectRecoveryProofEnabled: true,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_DEAD_OBJECT_RECOVERY_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_DEAD_OBJECT_RECOVERY_ERROR: $topLevelError',
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

    final doReport =
        report ??
        VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
          <String, Object?>{
            'pass': false,
            'status': 'fail',
            'marker': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .deadObjectRecoveryFailMarkerConstant,
            'proofBoundary': '',
            'nativeProofBoundary': '',
            'failureReason': 'invocation_failed',
            'lastError': 'invocation_failed',
          },
        );

    // Dead-Object Recovery Response group. SYNTHETIC ERROR_DEAD_OBJECT
    // observed exactly once on the owner-thread write path (post-seek
    // epoch, no bytes consumed) -> old track release() exactly once -> one
    // same-parameter AudioTrack recreated -> STATE_INITIALIZED -> setVolume
    // 0.5 -> play() -> PLAYSTATE_PLAYING -> same unwritten slice resumed;
    // frames written before + after the recovery sum to the sink total and
    // the checksum identity holds. Not a real OS dead object; playstate
    // values are sink-side telemetry only.
    print(
      '  [LANE] Dead-Object Recovery Response: '
      'deadObjectRecoveryProofEnabled=${doReport.deadObjectRecoveryProofEnabled}, '
      'focusNoisyEventHandoffProofEnabled=${doReport.focusNoisyEventHandoffProofEnabled}, '
      'focusDuckRestoreProofEnabled=${doReport.focusDuckRestoreProofEnabled}, '
      'focusLossPauseResumeProofEnabled=${doReport.focusLossPauseResumeProofEnabled}, '
      'permanentFocusLossProofEnabled=${doReport.permanentFocusLossProofEnabled}, '
      'routeChangeEventHandoffProofEnabled=${doReport.routeChangeEventHandoffProofEnabled}, '
      'deadObjectOccurredCount=${doReport.deadObjectOccurredCount}, '
      'syntheticDeadObjectInjectedCount=${doReport.syntheticDeadObjectInjectedCount}, '
      'deadObjectOldTrackReleasedOk=${doReport.deadObjectOldTrackReleasedOk}, '
      'deadObjectOldTrackReleaseCount=${doReport.deadObjectOldTrackReleaseCount}, '
      'deadObjectTrackCreateCount=${doReport.deadObjectTrackCreateCount}, '
      'deadObjectNewTrackStateInitializedOk=${doReport.deadObjectNewTrackStateInitializedOk}, '
      'deadObjectNewTrackVolumeSetOk=${doReport.deadObjectNewTrackVolumeSetOk}, '
      'deadObjectNewTrackPlayOk=${doReport.deadObjectNewTrackPlayOk}, '
      'deadObjectSliceBytesAtRecovery=${doReport.deadObjectSliceBytesAtRecovery}, '
      'deadObjectUnwrittenBytesAtRecovery=${doReport.deadObjectUnwrittenBytesAtRecovery}, '
      'deadObjectSinkFramesWrittenBeforeRecovery=${doReport.deadObjectSinkFramesWrittenBeforeRecovery}, '
      'deadObjectSinkFramesWrittenAfterRecovery=${doReport.deadObjectSinkFramesWrittenAfterRecovery}, '
      'framesWrittenToSink=${doReport.framesWrittenToSink}, '
      'playStateAfterDeadObjectRecreatePlay=${doReport.playStateAfterDeadObjectRecreatePlay}, '
      'playStateAtReleaseDeadObject=${doReport.playStateAtReleaseDeadObject}, '
      'audioTrackGain=${doReport.audioTrackGain}, '
      'deadObjectRecoveryGatesHeld=${doReport.deadObjectRecoveryGatesHeld}, '
      'sinkWriteAccountingOk=${doReport.sinkWriteAccountingOk}, '
      'frameAccountingOk=${doReport.frameAccountingOk}, '
      'checksumIdentityOk=${doReport.checksumIdentityOk}, '
      'checksumsMatch=${doReport.checksumsMatch}, '
      'realtimeGatesHeld=${doReport.realtimeGatesHeld}, '
      'hasCanonicalProofBoundary=${doReport.hasCanonicalProofBoundary}, '
      'nativeProofBoundaryOk=${doReport.nativeProofBoundaryOk}, '
      'allNativeLanesPass=${doReport.allNativeLanesPass}, '
      'marker=${doReport.marker}, '
      'lastError=${doReport.lastError}',
    );

    final lastErrorOk =
        doReport.lastError.isEmpty ||
        doReport.lastError == 'none' ||
        doReport.lastError == 'null';

    final deadObjectRecoveryPass =
        (topLevelError == null) &&
        doReport.pass &&
        doReport.marker ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .deadObjectRecoveryPassMarkerConstant &&
        doReport.deadObjectRecoveryProofEnabled &&
        !doReport.focusNoisyEventHandoffProofEnabled &&
        !doReport.focusDuckRestoreProofEnabled &&
        !doReport.focusLossPauseResumeProofEnabled &&
        !doReport.permanentFocusLossProofEnabled &&
        !doReport.routeChangeEventHandoffProofEnabled &&
        doReport.deadObjectRecoveryGatesHeld &&
        doReport.deadObjectOccurredCount == 1 &&
        doReport.syntheticDeadObjectInjectedCount == 1 &&
        doReport.deadObjectOldTrackReleasedOk &&
        doReport.deadObjectOldTrackReleaseCount == 1 &&
        doReport.deadObjectTrackCreateCount == 2 &&
        doReport.deadObjectNewTrackStateInitializedOk &&
        doReport.deadObjectNewTrackVolumeSetOk &&
        doReport.deadObjectNewTrackPlayOk &&
        doReport.deadObjectUnwrittenBytesAtRecovery > 0 &&
        doReport.deadObjectSinkFramesWrittenBeforeRecovery > 0 &&
        doReport.deadObjectSinkFramesWrittenAfterRecovery > 0 &&
        doReport.deadObjectSinkFramesWrittenBeforeRecovery +
                doReport.deadObjectSinkFramesWrittenAfterRecovery ==
            doReport.framesWrittenToSink &&
        doReport.audioTrackGain == 0.5 &&
        doReport.sinkWriteAccountingOk &&
        doReport.frameAccountingOk &&
        doReport.checksumIdentityOk &&
        doReport.hasCanonicalProofBoundary &&
        doReport.proofBoundary ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .deadObjectRecoveryProofBoundaryConstant &&
        doReport.nativeProofBoundaryOk &&
        doReport.checksumsMatch &&
        doReport.providerCountersClean &&
        doReport.sinkAccountingBalanced &&
        doReport.realtimeGatesHeld &&
        doReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAsyncRuntimeQueueDeadObjectRecoveryPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-DEAD-OBJECT-RECOVERY-RESPONSE',
      'target': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .deadObjectRecoveryProofBoundaryConstant,
      'nativeTarget': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .nativeProofBoundaryConstant,
      'pass': deadObjectRecoveryPass,
      'report': doReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_DEAD_OBJECT_RECOVERY_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      deadObjectRecoveryPass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_DEAD_OBJECT_RECOVERY_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_DEAD_OBJECT_RECOVERY_PHYSICAL_SMOKE_FAIL',
    );
    return deadObjectRecoveryPass;
  }

  Future<bool> _runTimestampStabilizationSmoke() async {
    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_TIMESTAMP_STABILIZATION_SMOKE_START',
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
        '${tempDir.path}/p4_async_rt_queue_timestamp_stab_source_$timestamp.mov',
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
            timestampStabilizationProofEnabled: true,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_TIMESTAMP_STABILIZATION_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_TIMESTAMP_STABILIZATION_ERROR: $topLevelError',
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

    final tsReport =
        report ??
        VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
          <String, Object?>{
            'pass': false,
            'status': 'fail',
            'marker': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .timestampStabilizationFailMarkerConstant,
            'proofBoundary': '',
            'nativeProofBoundary': '',
            'failureReason': 'invocation_failed',
            'lastError': 'invocation_failed',
          },
        );

    // AudioTrack Timestamp Stabilization group (standalone muted sink).
    // Pre-seek and post-seek generations stabilize within 1000ms / 4096 polls;
    // framePosition advances monotonically with 0 strict regressions; at most
    // one poll per output pass; zero polls inside write retry loop; wrap count
    // bounded; nanoTime telemetry recorded; zero feedback into native pacing.
    print(
      '  [LANE] AudioTrack Timestamp Stabilization: '
      'timestampStabilizationProofEnabled=${tsReport.timestampStabilizationProofEnabled}, '
      'timestampStabilizedOk=${tsReport.timestampStabilizedOk}, '
      'timestampAdvancingMonotonicOk=${tsReport.timestampAdvancingMonotonicOk}, '
      'timestampPostSeekRestabilizedOk=${tsReport.timestampPostSeekRestabilizedOk}, '
      'timestampNoPacingFeedbackOk=${tsReport.timestampNoPacingFeedbackOk}, '
      'timestampWarmupPollCount=${tsReport.timestampWarmupPollCount}, '
      'timestampStablePollCount=${tsReport.timestampStablePollCount}, '
      'timestampUnavailableAfterStableCount=${tsReport.timestampUnavailableAfterStableCount}, '
      'timestampPassCount=${tsReport.timestampPassCount}, '
      'timestampPassPollCount=${tsReport.timestampPassPollCount}, '
      'timestampPollInsideWriteLoopCount=${tsReport.timestampPollInsideWriteLoopCount}, '
      'timestampFrameAdvanceCount=${tsReport.timestampFrameAdvanceCount}, '
      'timestampFrameEqualCount=${tsReport.timestampFrameEqualCount}, '
      'timestampFrameRegressionCount=${tsReport.timestampFrameRegressionCount}, '
      'timestampWrapCount=${tsReport.timestampWrapCount}, '
      'timestampNanoTimeAdvanceCountTelemetryOnly=${tsReport.timestampNanoTimeAdvanceCountTelemetryOnly}, '
      'timestampNanoTimeEqualCountTelemetryOnly=${tsReport.timestampNanoTimeEqualCountTelemetryOnly}, '
      'timestampNanoTimeNonMonotonicCountTelemetryOnly=${tsReport.timestampNanoTimeNonMonotonicCountTelemetryOnly}, '
      'timestampEpochOpenCount=${tsReport.timestampEpochOpenCount}, '
      'timestampRecreateResetCount=${tsReport.timestampRecreateResetCount}, '
      'timestampGenerationCount=${tsReport.timestampGenerationCount}, '
      'timestampGenerationsStabilized=${tsReport.timestampGenerationsStabilized}, '
      'timestampPreSeekStabilized=${tsReport.timestampPreSeekStabilized}, '
      'timestampPostSeekStabilized=${tsReport.timestampPostSeekStabilized}, '
      'timestampPostRecreateStabilized=${tsReport.timestampPostRecreateStabilized}, '
      'timestampPreSeekWarmupPolls=${tsReport.timestampPreSeekWarmupPolls}, '
      'timestampPostSeekWarmupPolls=${tsReport.timestampPostSeekWarmupPolls}, '
      'timestampPreSeekStablePolls=${tsReport.timestampPreSeekStablePolls}, '
      'timestampPostSeekStablePolls=${tsReport.timestampPostSeekStablePolls}, '
      'timestampPreSeekAdvanceCount=${tsReport.timestampPreSeekAdvanceCount}, '
      'timestampPostSeekAdvanceCount=${tsReport.timestampPostSeekAdvanceCount}, '
      'timestampPreSeekFirstStableFramePosition=${tsReport.timestampPreSeekFirstStableFramePosition}, '
      'timestampPostSeekFirstStableFramePosition=${tsReport.timestampPostSeekFirstStableFramePosition}, '
      'timestampLastFramePosition=${tsReport.timestampLastFramePosition}, '
      'timestampStabilizationGatesHeld=${tsReport.timestampStabilizationGatesHeld}, '
      'mutedOutputOk=${tsReport.mutedOutputOk}, '
      'sinkWriteAccountingOk=${tsReport.sinkWriteAccountingOk}, '
      'frameAccountingOk=${tsReport.frameAccountingOk}, '
      'checksumIdentityOk=${tsReport.checksumIdentityOk}, '
      'checksumsMatch=${tsReport.checksumsMatch}, '
      'realtimeGatesHeld=${tsReport.realtimeGatesHeld}, '
      'hasCanonicalProofBoundary=${tsReport.hasCanonicalProofBoundary}, '
      'nativeProofBoundaryOk=${tsReport.nativeProofBoundaryOk}, '
      'allNativeLanesPass=${tsReport.allNativeLanesPass}, '
      'marker=${tsReport.marker}, '
      'lastError=${tsReport.lastError}',
    );

    final lastErrorOk =
        tsReport.lastError.isEmpty ||
        tsReport.lastError == 'none' ||
        tsReport.lastError == 'null';

    final timestampStabilizationPass =
        (topLevelError == null) &&
        tsReport.pass &&
        tsReport.marker ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .timestampStabilizationPassMarkerConstant &&
        tsReport.timestampStabilizationProofEnabled &&
        !tsReport.deadObjectRecoveryProofEnabled &&
        tsReport.timestampStabilizationGatesHeld &&
        tsReport.timestampStabilizedOk &&
        tsReport.timestampAdvancingMonotonicOk &&
        tsReport.timestampPostSeekRestabilizedOk &&
        tsReport.timestampNoPacingFeedbackOk &&
        tsReport.timestampPreSeekStabilized &&
        tsReport.timestampPostSeekStabilized &&
        tsReport.timestampGenerationCount == 2 &&
        tsReport.timestampEpochOpenCount == 2 &&
        tsReport.timestampRecreateResetCount == 0 &&
        tsReport.timestampPreSeekStablePolls > 0 &&
        tsReport.timestampPostSeekStablePolls > 0 &&
        tsReport.timestampStablePollCount > 0 &&
        tsReport.timestampFrameAdvanceCount >= 1 &&
        tsReport.timestampFrameRegressionCount == 0 &&
        tsReport.timestampPollInsideWriteLoopCount == 0 &&
        tsReport.timestampPassPollCount <= tsReport.timestampPassCount &&
        tsReport.mutedOutputOk &&
        tsReport.sinkWriteAccountingOk &&
        tsReport.frameAccountingOk &&
        tsReport.checksumIdentityOk &&
        tsReport.hasCanonicalProofBoundary &&
        tsReport.proofBoundary ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .timestampStabilizationProofBoundaryConstant &&
        tsReport.nativeProofBoundaryOk &&
        tsReport.checksumsMatch &&
        tsReport.providerCountersClean &&
        tsReport.sinkAccountingBalanced &&
        tsReport.realtimeGatesHeld &&
        tsReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit':
          'AndroidAsyncRuntimeQueueTimestampStabilizationPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-AUDIOTRACK-TIMESTAMP-STABILIZATION',
      'target': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .timestampStabilizationProofBoundaryConstant,
      'nativeTarget': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .nativeProofBoundaryConstant,
      'pass': timestampStabilizationPass,
      'report': tsReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_TIMESTAMP_STABILIZATION_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      timestampStabilizationPass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_TIMESTAMP_STABILIZATION_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_TIMESTAMP_STABILIZATION_PHYSICAL_SMOKE_FAIL',
    );
    return timestampStabilizationPass;
  }

  Future<bool> _runTimestampStabilizationDeadObjectRecoverySmoke() async {
    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_TIMESTAMP_STABILIZATION_DEAD_OBJECT_RECOVERY_SMOKE_START',
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
        '${tempDir.path}/p4_async_rt_queue_timestamp_dead_object_source_$timestamp.mov',
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
            timestampStabilizationProofEnabled: true,
            deadObjectRecoveryProofEnabled: true,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_TIMESTAMP_STABILIZATION_DEAD_OBJECT_RECOVERY_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_TIMESTAMP_STABILIZATION_DEAD_OBJECT_RECOVERY_ERROR: $topLevelError',
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

    final tsDoReport =
        report ??
        VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
          <String, Object?>{
            'pass': false,
            'status': 'fail',
            'marker': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .timestampStabilizationFailMarkerConstant,
            'proofBoundary': '',
            'nativeProofBoundary': '',
            'failureReason': 'invocation_failed',
            'lastError': 'invocation_failed',
          },
        );

    // AudioTrack Timestamp Stabilization with Dead-Object Recovery group.
    // Proves timestamp stabilization across all 3 generations (pre-seek,
    // post-seek, and post-recreate) with baseline reset on seek and after
    // synthetic dead-object track recreation; base gain 0.5; old track
    // released once; recreated track playing; unwritten slice resumed;
    // framePosition advancing monotonically with zero regressions; zero
    // polls inside write loop; and X12 recovery gates intact.
    print(
      '  [LANE] AudioTrack Timestamp Stabilization with Dead-Object Recovery: '
      'timestampStabilizationProofEnabled=${tsDoReport.timestampStabilizationProofEnabled}, '
      'deadObjectRecoveryProofEnabled=${tsDoReport.deadObjectRecoveryProofEnabled}, '
      'timestampStabilizedOk=${tsDoReport.timestampStabilizedOk}, '
      'timestampAdvancingMonotonicOk=${tsDoReport.timestampAdvancingMonotonicOk}, '
      'timestampPostSeekRestabilizedOk=${tsDoReport.timestampPostSeekRestabilizedOk}, '
      'timestampNoPacingFeedbackOk=${tsDoReport.timestampNoPacingFeedbackOk}, '
      'timestampWarmupPollCount=${tsDoReport.timestampWarmupPollCount}, '
      'timestampStablePollCount=${tsDoReport.timestampStablePollCount}, '
      'timestampUnavailableAfterStableCount=${tsDoReport.timestampUnavailableAfterStableCount}, '
      'timestampPassCount=${tsDoReport.timestampPassCount}, '
      'timestampPassPollCount=${tsDoReport.timestampPassPollCount}, '
      'timestampPollInsideWriteLoopCount=${tsDoReport.timestampPollInsideWriteLoopCount}, '
      'timestampFrameAdvanceCount=${tsDoReport.timestampFrameAdvanceCount}, '
      'timestampFrameEqualCount=${tsDoReport.timestampFrameEqualCount}, '
      'timestampFrameRegressionCount=${tsDoReport.timestampFrameRegressionCount}, '
      'timestampWrapCount=${tsDoReport.timestampWrapCount}, '
      'timestampNanoTimeAdvanceCountTelemetryOnly=${tsDoReport.timestampNanoTimeAdvanceCountTelemetryOnly}, '
      'timestampNanoTimeEqualCountTelemetryOnly=${tsDoReport.timestampNanoTimeEqualCountTelemetryOnly}, '
      'timestampNanoTimeNonMonotonicCountTelemetryOnly=${tsDoReport.timestampNanoTimeNonMonotonicCountTelemetryOnly}, '
      'timestampEpochOpenCount=${tsDoReport.timestampEpochOpenCount}, '
      'timestampRecreateResetCount=${tsDoReport.timestampRecreateResetCount}, '
      'timestampGenerationCount=${tsDoReport.timestampGenerationCount}, '
      'timestampGenerationsStabilized=${tsDoReport.timestampGenerationsStabilized}, '
      'timestampPreSeekStabilized=${tsDoReport.timestampPreSeekStabilized}, '
      'timestampPostSeekStabilized=${tsDoReport.timestampPostSeekStabilized}, '
      'timestampPostRecreateStabilized=${tsDoReport.timestampPostRecreateStabilized}, '
      'timestampPreSeekWarmupPolls=${tsDoReport.timestampPreSeekWarmupPolls}, '
      'timestampPostSeekWarmupPolls=${tsDoReport.timestampPostSeekWarmupPolls}, '
      'timestampPostRecreateWarmupPolls=${tsDoReport.timestampPostRecreateWarmupPolls}, '
      'timestampPreSeekStablePolls=${tsDoReport.timestampPreSeekStablePolls}, '
      'timestampPostSeekStablePolls=${tsDoReport.timestampPostSeekStablePolls}, '
      'timestampPostRecreateStablePolls=${tsDoReport.timestampPostRecreateStablePolls}, '
      'timestampPreSeekAdvanceCount=${tsDoReport.timestampPreSeekAdvanceCount}, '
      'timestampPostSeekAdvanceCount=${tsDoReport.timestampPostSeekAdvanceCount}, '
      'timestampPostRecreateAdvanceCount=${tsDoReport.timestampPostRecreateAdvanceCount}, '
      'timestampPreSeekFirstStableFramePosition=${tsDoReport.timestampPreSeekFirstStableFramePosition}, '
      'timestampPostSeekFirstStableFramePosition=${tsDoReport.timestampPostSeekFirstStableFramePosition}, '
      'timestampPostRecreateFirstStableFramePosition=${tsDoReport.timestampPostRecreateFirstStableFramePosition}, '
      'timestampLastFramePosition=${tsDoReport.timestampLastFramePosition}, '
      'deadObjectOccurredCount=${tsDoReport.deadObjectOccurredCount}, '
      'syntheticDeadObjectInjectedCount=${tsDoReport.syntheticDeadObjectInjectedCount}, '
      'deadObjectOldTrackReleasedOk=${tsDoReport.deadObjectOldTrackReleasedOk}, '
      'deadObjectOldTrackReleaseCount=${tsDoReport.deadObjectOldTrackReleaseCount}, '
      'deadObjectTrackCreateCount=${tsDoReport.deadObjectTrackCreateCount}, '
      'deadObjectNewTrackStateInitializedOk=${tsDoReport.deadObjectNewTrackStateInitializedOk}, '
      'deadObjectNewTrackVolumeSetOk=${tsDoReport.deadObjectNewTrackVolumeSetOk}, '
      'deadObjectNewTrackPlayOk=${tsDoReport.deadObjectNewTrackPlayOk}, '
      'deadObjectSliceBytesAtRecovery=${tsDoReport.deadObjectSliceBytesAtRecovery}, '
      'deadObjectUnwrittenBytesAtRecovery=${tsDoReport.deadObjectUnwrittenBytesAtRecovery}, '
      'deadObjectSinkFramesWrittenBeforeRecovery=${tsDoReport.deadObjectSinkFramesWrittenBeforeRecovery}, '
      'deadObjectSinkFramesWrittenAfterRecovery=${tsDoReport.deadObjectSinkFramesWrittenAfterRecovery}, '
      'framesWrittenToSink=${tsDoReport.framesWrittenToSink}, '
      'audioTrackGain=${tsDoReport.audioTrackGain}, '
      'deadObjectRecoveryGatesHeld=${tsDoReport.deadObjectRecoveryGatesHeld}, '
      'timestampStabilizationGatesHeld=${tsDoReport.timestampStabilizationGatesHeld}, '
      'sinkWriteAccountingOk=${tsDoReport.sinkWriteAccountingOk}, '
      'frameAccountingOk=${tsDoReport.frameAccountingOk}, '
      'checksumIdentityOk=${tsDoReport.checksumIdentityOk}, '
      'checksumsMatch=${tsDoReport.checksumsMatch}, '
      'realtimeGatesHeld=${tsDoReport.realtimeGatesHeld}, '
      'hasCanonicalProofBoundary=${tsDoReport.hasCanonicalProofBoundary}, '
      'nativeProofBoundaryOk=${tsDoReport.nativeProofBoundaryOk}, '
      'allNativeLanesPass=${tsDoReport.allNativeLanesPass}, '
      'marker=${tsDoReport.marker}, '
      'lastError=${tsDoReport.lastError}',
    );

    final lastErrorOk =
        tsDoReport.lastError.isEmpty ||
        tsDoReport.lastError == 'none' ||
        tsDoReport.lastError == 'null';

    final timestampDeadObjectPass =
        (topLevelError == null) &&
        tsDoReport.pass &&
        tsDoReport.marker ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .timestampStabilizationPassMarkerConstant &&
        tsDoReport.timestampStabilizationProofEnabled &&
        tsDoReport.deadObjectRecoveryProofEnabled &&
        tsDoReport.timestampStabilizationGatesHeld &&
        tsDoReport.deadObjectRecoveryGatesHeld &&
        tsDoReport.timestampStabilizedOk &&
        tsDoReport.timestampAdvancingMonotonicOk &&
        tsDoReport.timestampPostSeekRestabilizedOk &&
        tsDoReport.timestampNoPacingFeedbackOk &&
        tsDoReport.timestampPreSeekStabilized &&
        tsDoReport.timestampPostSeekStabilized &&
        tsDoReport.timestampPostRecreateStabilized &&
        tsDoReport.timestampGenerationCount == 3 &&
        tsDoReport.timestampEpochOpenCount == 2 &&
        tsDoReport.timestampRecreateResetCount == 1 &&
        tsDoReport.timestampPreSeekStablePolls > 0 &&
        tsDoReport.timestampPostSeekStablePolls > 0 &&
        tsDoReport.timestampPostRecreateStablePolls > 0 &&
        tsDoReport.timestampStablePollCount > 0 &&
        tsDoReport.timestampFrameAdvanceCount >= 1 &&
        tsDoReport.timestampFrameRegressionCount == 0 &&
        tsDoReport.timestampPollInsideWriteLoopCount == 0 &&
        tsDoReport.timestampPassPollCount <= tsDoReport.timestampPassCount &&
        tsDoReport.deadObjectOccurredCount == 1 &&
        tsDoReport.syntheticDeadObjectInjectedCount == 1 &&
        tsDoReport.deadObjectOldTrackReleasedOk &&
        tsDoReport.deadObjectOldTrackReleaseCount == 1 &&
        tsDoReport.deadObjectTrackCreateCount == 2 &&
        tsDoReport.deadObjectNewTrackStateInitializedOk &&
        tsDoReport.deadObjectNewTrackVolumeSetOk &&
        tsDoReport.deadObjectNewTrackPlayOk &&
        tsDoReport.deadObjectUnwrittenBytesAtRecovery > 0 &&
        tsDoReport.deadObjectSinkFramesWrittenBeforeRecovery > 0 &&
        tsDoReport.deadObjectSinkFramesWrittenAfterRecovery > 0 &&
        tsDoReport.deadObjectSinkFramesWrittenBeforeRecovery +
                tsDoReport.deadObjectSinkFramesWrittenAfterRecovery ==
            tsDoReport.framesWrittenToSink &&
        tsDoReport.audioTrackGain == 0.5 &&
        tsDoReport.sinkWriteAccountingOk &&
        tsDoReport.frameAccountingOk &&
        tsDoReport.checksumIdentityOk &&
        tsDoReport.hasCanonicalProofBoundary &&
        tsDoReport.proofBoundary ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .timestampStabilizationDeadObjectRecoveryProofBoundaryConstant &&
        tsDoReport.nativeProofBoundaryOk &&
        tsDoReport.checksumsMatch &&
        tsDoReport.providerCountersClean &&
        tsDoReport.sinkAccountingBalanced &&
        tsDoReport.realtimeGatesHeld &&
        tsDoReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit':
          'AndroidAsyncRuntimeQueueTimestampStabilizationDeadObjectRecoveryPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-AUDIOTRACK-TIMESTAMP-STABILIZATION',
      'target': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .timestampStabilizationDeadObjectRecoveryProofBoundaryConstant,
      'nativeTarget': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .nativeProofBoundaryConstant,
      'pass': timestampDeadObjectPass,
      'report': tsDoReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_TIMESTAMP_STABILIZATION_DEAD_OBJECT_RECOVERY_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      timestampDeadObjectPass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_TIMESTAMP_STABILIZATION_DEAD_OBJECT_RECOVERY_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_TIMESTAMP_STABILIZATION_DEAD_OBJECT_RECOVERY_PHYSICAL_SMOKE_FAIL',
    );
    return timestampDeadObjectPass;
  }

  Future<bool> _runAudibleSpeakerPlaybackSmoke() async {
    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIBLE_SPEAKER_PLAYBACK_SMOKE_START',
    );

    if (mounted) {
      setState(() {
        _status =
            'X14 Audible Speaker Playback Test Starting...\n'
            'MANUAL OBSERVATION REQUIRED: Please listen for audio playback through the device speaker.';
      });
    }

    print('================================================================');
    print('X14 AUDIBLE SPEAKER PLAYBACK TEST: MANUAL ACOUSTIC OBSERVATION');
    print(
      'MANUAL OBSERVATION REQUIRED: Please listen to the device built-in speaker.',
    );
    print(
      'Audio will play at gain 0.5 for ~2 seconds with a joint seek at 1.30s.',
    );
    print('Countdown: 3...');
    await Future<void>.delayed(const Duration(seconds: 1));
    print('Countdown: 2...');
    await Future<void>.delayed(const Duration(seconds: 1));
    print('Countdown: 1... PLAYING NOW');
    print('================================================================');

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
        '${tempDir.path}/p4_async_rt_queue_audible_speaker_source_$timestamp.mov',
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
            audibleSpeakerPlaybackProofEnabled: true,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIBLE_SPEAKER_PLAYBACK_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIBLE_SPEAKER_PLAYBACK_ERROR: $topLevelError',
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

    final audibleReport =
        report ??
        VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport.fromMap(
          <String, Object?>{
            'pass': false,
            'status': 'fail',
            'marker': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .audibleSpeakerPlaybackFailMarkerConstant,
            'proofBoundary': '',
            'nativeProofBoundary': '',
            'failureReason': 'invocation_failed',
            'lastError': 'invocation_failed',
          },
        );

    // Audible Speaker Playback group (diagnostic SM-A566B lane).
    // Owner-thread routed-device sample after each epoch's play() asserted
    // TYPE_BUILTIN_SPEAKER (2); base gain 0.5; lossless sink write accounting
    // and reference mix checksum identity held. Diagnostic lane under manual
    // acoustic observation: OS routing report only, not automatic acoustic
    // audibility measurement; any audibility verdict is recorded manually.
    print(
      '  [LANE] Audible Speaker Playback: '
      'audibleSpeakerPlaybackProofEnabled=${audibleReport.audibleSpeakerPlaybackProofEnabled}, '
      'audioTrackGain=${audibleReport.audioTrackGain}, '
      'audioTrackNonZeroGainSetOk=${audibleReport.audioTrackNonZeroGainSetOk}, '
      'audibleSpeakerRouteSampleCount=${audibleReport.audibleSpeakerRouteSampleCount}, '
      'audibleSpeakerRouteSampleOk=${audibleReport.audibleSpeakerRouteSampleOk}, '
      'audibleSpeakerRouteType=${audibleReport.audibleSpeakerRouteType}, '
      'audibleSpeakerBuiltInSpeakerRouteOk=${audibleReport.audibleSpeakerBuiltInSpeakerRouteOk}, '
      'audibleSpeakerPlaybackGatesHeld=${audibleReport.audibleSpeakerPlaybackGatesHeld}, '
      'sinkWriteAccountingOk=${audibleReport.sinkWriteAccountingOk}, '
      'frameAccountingOk=${audibleReport.frameAccountingOk}, '
      'checksumIdentityOk=${audibleReport.checksumIdentityOk}, '
      'checksumsMatch=${audibleReport.checksumsMatch}, '
      'realtimeGatesHeld=${audibleReport.realtimeGatesHeld}, '
      'hasCanonicalProofBoundary=${audibleReport.hasCanonicalProofBoundary}, '
      'nativeProofBoundaryOk=${audibleReport.nativeProofBoundaryOk}, '
      'allNativeLanesPass=${audibleReport.allNativeLanesPass}, '
      'marker=${audibleReport.marker}, '
      'lastError=${audibleReport.lastError}',
    );

    final lastErrorOk =
        audibleReport.lastError.isEmpty ||
        audibleReport.lastError == 'none' ||
        audibleReport.lastError == 'null';

    final audibleSpeakerPlaybackPass =
        (topLevelError == null) &&
        audibleReport.pass &&
        audibleReport.marker ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .audibleSpeakerPlaybackPassMarkerConstant &&
        audibleReport.audibleSpeakerPlaybackProofEnabled &&
        audibleReport.audioTrackGain == 0.5 &&
        audibleReport.audioTrackNonZeroGainSetOk &&
        audibleReport.audibleSpeakerRouteSampleCount >= 1 &&
        audibleReport.audibleSpeakerRouteSampleOk &&
        audibleReport.audibleSpeakerRouteType ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .builtInSpeakerTypeConstant &&
        audibleReport.audibleSpeakerBuiltInSpeakerRouteOk &&
        audibleReport.audibleSpeakerPlaybackGatesHeld &&
        audibleReport.sinkWriteAccountingOk &&
        audibleReport.frameAccountingOk &&
        audibleReport.checksumIdentityOk &&
        audibleReport.hasCanonicalProofBoundary &&
        audibleReport.proofBoundary ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .audibleSpeakerPlaybackProofBoundaryConstant &&
        audibleReport.nativeProofBoundaryOk &&
        audibleReport.checksumsMatch &&
        audibleReport.providerCountersClean &&
        audibleReport.sinkAccountingBalanced &&
        audibleReport.realtimeGatesHeld &&
        audibleReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit':
          'AndroidAsyncRuntimeQueueAudibleSpeakerPlaybackPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-AUDIBLE-SPEAKER-PLAYBACK',
      'target': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .audibleSpeakerPlaybackProofBoundaryConstant,
      'nativeTarget': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .nativeProofBoundaryConstant,
      'pass': audibleSpeakerPlaybackPass,
      'report': audibleReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIBLE_SPEAKER_PLAYBACK_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      audibleSpeakerPlaybackPass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIBLE_SPEAKER_PLAYBACK_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIBLE_SPEAKER_PLAYBACK_PHYSICAL_SMOKE_FAIL',
    );
    print(
      'MANUAL OBSERVATION REQUIRED: Automated pass confirms OS routed-device '
      'report TYPE_BUILTIN_SPEAKER (2) and telemetry only; human hearing confirmation '
      'of audible playback is required and is not encoded in the automated PASS.',
    );
    return audibleSpeakerPlaybackPass;
  }

  Future<bool> _runPauseResumeSmoke() async {
    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_TRANSPORT_PAUSE_RESUME_SMOKE_START',
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
        '${tempDir.path}/p4_async_rt_queue_pause_resume_source_$timestamp.mov',
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
            pauseResumeProofEnabled: true,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_TRANSPORT_PAUSE_RESUME_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_TRANSPORT_PAUSE_RESUME_ERROR: $topLevelError',
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
                .pauseResumeFailMarkerConstant,
            'proofBoundary': '',
            'nativeProofBoundary': '',
            'failureReason': 'invocation_failed',
            'lastError': 'invocation_failed',
          },
        );

    // Native Transport Pause/Resume group:
    // Worker steady_clock pause/resume commands (order start, pause, resume, seek),
    // AudioTrack playstate pause (2) and resume (3), ~150ms hold with frozen dispatch
    // and pushed counts, worker paused waits > 0, paused interval excluded from native
    // timing gate, 4 commands processed, muted sink, lossless sink accounting and checksum identity.
    print(
      '  [LANE] Native Transport Pause/Resume: '
      'pauseResumeProofEnabled=${prReport.pauseResumeProofEnabled}, '
      'pauseResumeExercised=${prReport.pauseResumeExercised}, '
      'pauseResumeNativePauseOk=${prReport.pauseResumeNativePauseOk}, '
      'pauseResumeSinkPausedOk=${prReport.pauseResumeSinkPausedOk}, '
      'pauseResumeHoldFrozenOk=${prReport.pauseResumeHoldFrozenOk}, '
      'pauseResumeSinkResumedOk=${prReport.pauseResumeSinkResumedOk}, '
      'pauseResumeNativeResumeOk=${prReport.pauseResumeNativeResumeOk}, '
      'pauseResumeHoldMs=${prReport.pauseResumeHoldMs}, '
      'pauseResumeFramesPendingAtPause=${prReport.pauseResumeFramesPendingAtPause}, '
      'playStateAfterNativePause=${prReport.playStateAfterNativePause}, '
      'playStateAfterNativeResume=${prReport.playStateAfterNativeResume}, '
      'pauseProofCommandSeq=${prReport.pauseProofCommandSeq}, '
      'resumeProofCommandSeq=${prReport.resumeProofCommandSeq}, '
      'pauseProofDispatchCountAtPause=${prReport.pauseProofDispatchCountAtPause}, '
      'pauseProofTotalFramesPushedAtPause=${prReport.pauseProofTotalFramesPushedAtPause}, '
      'pauseProofDispatchCountAfterHold=${prReport.pauseProofDispatchCountAfterHold}, '
      'pauseProofTotalFramesPushedAfterHold=${prReport.pauseProofTotalFramesPushedAfterHold}, '
      'nativePaused=${prReport.nativePaused}, '
      'nativePauseCommandsProcessed=${prReport.nativePauseCommandsProcessed}, '
      'nativeResumeCommandsProcessed=${prReport.nativeResumeCommandsProcessed}, '
      'nativeWorkerPausedWaits=${prReport.nativeWorkerPausedWaits}, '
      'nativeLastPausedIntervalNs=${prReport.nativeLastPausedIntervalNs}, '
      'nativeTimingPausedExcludedNs=${prReport.nativeTimingPausedExcludedNs}, '
      'nativePausedDispatchFrozenOk=${prReport.nativePausedDispatchFrozenOk}, '
      'commandsEnqueued=${prReport.commandsEnqueued}, '
      'commandsProcessed=${prReport.commandsProcessed}, '
      'mutedOutputOk=${prReport.mutedOutputOk}, '
      'pauseResumeGatesHeld=${prReport.pauseResumeGatesHeld}, '
      'sinkWriteAccountingOk=${prReport.sinkWriteAccountingOk}, '
      'frameAccountingOk=${prReport.frameAccountingOk}, '
      'checksumIdentityOk=${prReport.checksumIdentityOk}, '
      'checksumsMatch=${prReport.checksumsMatch}, '
      'realtimeGatesHeld=${prReport.realtimeGatesHeld}, '
      'hasCanonicalProofBoundary=${prReport.hasCanonicalProofBoundary}, '
      'nativeProofBoundaryOk=${prReport.nativeProofBoundaryOk}, '
      'allNativeLanesPass=${prReport.allNativeLanesPass}, '
      'marker=${prReport.marker}, '
      'lastError=${prReport.lastError}',
    );

    final lastErrorOk =
        prReport.lastError.isEmpty ||
        prReport.lastError == 'none' ||
        prReport.lastError == 'null';

    final pauseResumePass =
        (topLevelError == null) &&
        prReport.pass &&
        prReport.marker ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .pauseResumePassMarkerConstant &&
        prReport.pauseResumeProofEnabled &&
        prReport.pauseResumeExercised &&
        prReport.pauseResumeNativePauseOk &&
        prReport.pauseResumeSinkPausedOk &&
        prReport.pauseResumeHoldFrozenOk &&
        prReport.pauseResumeSinkResumedOk &&
        prReport.pauseResumeNativeResumeOk &&
        prReport.nativePauseCommandsProcessed == 1 &&
        prReport.nativeResumeCommandsProcessed == 1 &&
        prReport.nativePausedDispatchFrozenOk &&
        !prReport.nativePaused &&
        prReport.nativeLastPausedIntervalNs > 0 &&
        prReport.nativeWorkerPausedWaits > 0 &&
        prReport.pauseResumeFramesPendingAtPause > 0 &&
        prReport.playStateAfterNativePause == 2 &&
        prReport.playStateAfterNativeResume == 3 &&
        prReport.pauseProofCommandSeq >= 0 &&
        prReport.resumeProofCommandSeq > prReport.pauseProofCommandSeq &&
        prReport.pauseProofDispatchCountAfterHold ==
            prReport.pauseProofDispatchCountAtPause &&
        prReport.pauseProofTotalFramesPushedAfterHold ==
            prReport.pauseProofTotalFramesPushedAtPause &&
        prReport.commandsEnqueued == 4 &&
        prReport.commandsProcessed == 4 &&
        prReport.commandErrors == 0 &&
        prReport.mutedOutputOk &&
        prReport.pauseResumeGatesHeld &&
        prReport.sinkWriteAccountingOk &&
        prReport.frameAccountingOk &&
        prReport.checksumIdentityOk &&
        prReport.hasCanonicalProofBoundary &&
        prReport.proofBoundary ==
            VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
                .pauseResumeProofBoundaryConstant &&
        prReport.nativeProofBoundaryOk &&
        prReport.checksumsMatch &&
        prReport.providerCountersClean &&
        prReport.sinkAccountingBalanced &&
        prReport.realtimeGatesHeld &&
        prReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit':
          'AndroidAsyncRuntimeQueueTransportPauseResumePhysicalSmokeHarness',
      'slice': 'P4-AUDIO-ASYNC-RUNTIME-QUEUE-PAUSE-RESUME',
      'target': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .pauseResumeProofBoundaryConstant,
      'nativeTarget': VGAsyncRuntimeQueueMultiSourceRealtimeClockSmokeReport
          .nativeProofBoundaryConstant,
      'pass': pauseResumePass,
      'report': prReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_TRANSPORT_PAUSE_RESUME_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pauseResumePass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_TRANSPORT_PAUSE_RESUME_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_TRANSPORT_PAUSE_RESUME_PHYSICAL_SMOKE_FAIL',
    );
    return pauseResumePass;
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
