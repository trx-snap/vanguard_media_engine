// android_aaudio_node_owned_sink_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-AAUDIO-NODE-OWNED-SINK-DIAGNOSTIC: Android True-DAG Phase 4
// two-source node-owned closed-loop native audio graph pipeline muted native AAudio callback
// sink diagnostic proof physical harness (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS).
//
// Proof lanes:
//   - Multi-Source Ingest & Format group: formatProbeOk, nodeOwnedRouteDiscoveryOk, nodeOwnsRingTrack0Ok, nodeOwnsRingTrack1Ok, track0IngestOk, track1SyntheticIngestOk, trackFrameAxisLockstepOk, sampleRate, channelCount, pcmEncoding, commonBudgetFrames, expectedFrameCount, routedSourceId0, routedSourceId1, framesTruncatedBeyondBudget, totalFramesExtracted, track1NonZeroSampleCount, decoderBenignFormatChangeCount.
//   - AAudio Runtime & Config group: aaudioRuntimeAvailableOk, aaudioSymbolsResolvedOk, aaudioStreamOpenOk, aaudioConfigOk, aaudioStartOk, deviceApiLevel, streamSampleRate, streamChannelCount, streamFormat, aaudioChannelCountSymbolFallback.
//   - Callback Accounting & Telemetry group: callbackObservedOk, aaudioCallbackAccountingOk, callbackAccountingCoherent, finalCallbackCountersCoherent, callbackInvocationCount, callbackFramesRequested, callbackFramesServed, callbackSilenceFrames, callbackShortReads, errorCallbackCount.
//   - Muted Sink & Checksums group: mutedOutputOk, mutedSinkIsZero, mutedSinkChecksumHex, nativeAcceptedChecksumHexTrack0, nativeAcceptedChecksumHexTrack1, nativeOutputDrainChecksumHex, kotlinAcceptedChecksumHexTrack0, kotlinAcceptedChecksumHexTrack1, kotlinReferenceMixChecksumHex, graphOutputChecksumOk, checksumsMatch.
//   - Frame Accounting & Lockstep group: totalFramesAcceptedTrack0, totalFramesAcceptedTrack1, totalOutputFramesPumped, totalMutedFramesPushed, postSeekFramesAccepted, jointDispatchGateOk, dispatchCount, nextDispatchFrame, maxFramesPerMix.
//   - Seek & Joint Tail Flush group: seekOk, jointTailFlushOk, seekAcceptedFrame, seekSkippedDeadline.
//   - Transport Health & Residuals group: noProviderUnderrunOk, noGraphSilenceOk, noRingPushShortfallOk, providerUnderrunEventsTrack0, providerUnderrunEventsTrack1, providerFramesZeroFilledTrack0, providerFramesZeroFilledTrack1, providerForwardSkipFramesTrack0, providerForwardSkipFramesTrack1, providerRewindRejectsTrack0, providerRewindRejectsTrack1, coordinatorSilenceCount, sinkFullWaitCount, sinkAvailableReadFramesFinal, cancellationPollCount.
//   - Architecture, Steady-State & Lifecycle group: zeroNativeSteadyStateAllocationOk, ownerThreadOk, lifecycleOk, canonical, nativeLastStatus.
//   - Proof Boundary & Summary group: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   native_android_aaudio_callback_sink_diagnostic_only_runtime_dlopen_no_direct_libaaudio_link_min_sdk24_safe_real_decoder_plus_synthetic_second_track_two_decoded_audio_source_nodes_own_ring_writer_provider_by_composition_scheduler_auto_discovery_from_graph_topology_muted_owner_thread_zero_scale_before_callback_ring_callback_pop_or_silence_only_no_product_no_editor_no_connects_app_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_audible_output_claim_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_low_latency_mmap_exclusive_no_xrun_freedom_no_latency_glitch_claim

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAaudioNodeOwnedSinkPhysicalSmokeApp());
}

class AndroidAaudioNodeOwnedSinkPhysicalSmokeApp extends StatefulWidget {
  const AndroidAaudioNodeOwnedSinkPhysicalSmokeApp({super.key});

  @override
  State<AndroidAaudioNodeOwnedSinkPhysicalSmokeApp> createState() =>
      _AndroidAaudioNodeOwnedSinkPhysicalSmokeAppState();
}

class _AndroidAaudioNodeOwnedSinkPhysicalSmokeAppState
    extends State<AndroidAaudioNodeOwnedSinkPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 AAudio Node-Owned Sink smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AAUDIO_NODE_OWNED_SINK_SMOKE_START');

    VGAaudioNodeOwnedSinkSmokeReport? report;
    String? topLevelError;
    File? tempSourceFile;

    try {
      final clipAData = await rootBundle.load(
        'assets/manual_test_clips/clip_A.mov',
      );
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempSourceFile = File(
        '${tempDir.path}/p4_aaudio_node_owned_sink_source_$timestamp.mov',
      );

      await tempSourceFile.writeAsBytes(
        clipAData.buffer.asUint8List(
          clipAData.offsetInBytes,
          clipAData.lengthInBytes,
        ),
        flush: true,
      );

      report =
          await VGAaudioNodeOwnedSinkSmokeReport.runAndroidDagPhase4AaudioNodeOwnedSinkSmoke(
            sourcePath: tempSourceFile.path,
            durationSec: 1.0,
            seekTargetSec: 0.35,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print('ANDROID_DAG_PHASE4_AAUDIO_NODE_OWNED_SINK_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('ANDROID_DAG_PHASE4_AAUDIO_NODE_OWNED_SINK_ERROR: $topLevelError');
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
        const VGAaudioNodeOwnedSinkSmokeReport(
          pass: false,
          status: 'fail',
          marker: VGAaudioNodeOwnedSinkSmokeReport.failMarkerConstant,
          proofBoundary: '',
          failureReason: 'invocation_failed',
          details: '',
          formatProbeOk: false,
          aaudioRuntimeAvailableOk: false,
          aaudioSymbolsResolvedOk: false,
          aaudioStreamOpenOk: false,
          aaudioConfigOk: false,
          aaudioStartOk: false,
          callbackObservedOk: false,
          mutedOutputOk: false,
          nodeOwnedRouteDiscoveryOk: false,
          nodeOwnsRingTrack0Ok: false,
          nodeOwnsRingTrack1Ok: false,
          track0IngestOk: false,
          track1SyntheticIngestOk: false,
          trackFrameAxisLockstepOk: false,
          jointDispatchGateOk: false,
          graphOutputChecksumOk: false,
          aaudioCallbackAccountingOk: false,
          seekOk: false,
          jointTailFlushOk: false,
          noProviderUnderrunOk: false,
          noGraphSilenceOk: false,
          noRingPushShortfallOk: false,
          zeroNativeSteadyStateAllocationOk: false,
          ownerThreadOk: false,
          lifecycleOk: false,
          canonical: false,
          sampleRate: 0,
          channelCount: 0,
          pcmEncoding: 0,
          commonBudgetFrames: 0,
          expectedFrameCount: 0,
          totalFramesExtracted: 0,
          framesTruncatedBeyondBudget: 0,
          totalFramesAcceptedTrack0: 0,
          totalFramesAcceptedTrack1: 0,
          totalOutputFramesPumped: 0,
          totalMutedFramesPushed: 0,
          postSeekFramesAccepted: 0,
          seekAcceptedFrame: -1,
          seekSkippedDeadline: false,
          track1NonZeroSampleCount: 0,
          decoderBenignFormatChangeCount: 0,
          nativeAcceptedChecksumHexTrack0: '',
          nativeAcceptedChecksumHexTrack1: '',
          nativeOutputDrainChecksumHex: '',
          mutedSinkChecksumHex: '',
          kotlinAcceptedChecksumHexTrack0: '',
          kotlinAcceptedChecksumHexTrack1: '',
          kotlinReferenceMixChecksumHex: '',
          routedSourceId0: '',
          routedSourceId1: '',
          dispatchCount: 0,
          nextDispatchFrame: -1,
          coordinatorSilenceCount: 0,
          providerUnderrunEventsTrack0: 0,
          providerUnderrunEventsTrack1: 0,
          providerFramesZeroFilledTrack0: 0,
          providerFramesZeroFilledTrack1: 0,
          providerForwardSkipFramesTrack0: 0,
          providerForwardSkipFramesTrack1: 0,
          providerRewindRejectsTrack0: 0,
          providerRewindRejectsTrack1: 0,
          deviceApiLevel: 0,
          streamSampleRate: 0,
          streamChannelCount: 0,
          streamFormat: 0,
          aaudioChannelCountSymbolFallback: false,
          callbackInvocationCount: 0,
          callbackFramesRequested: 0,
          callbackFramesServed: 0,
          callbackSilenceFrames: 0,
          callbackShortReads: 0,
          errorCallbackCount: 0,
          finalCallbackCountersCoherent: false,
          sinkFullWaitCount: 0,
          sinkAvailableReadFramesFinal: -1,
          cancellationPollCount: 0,
          nativeLastStatus: '',
          maxFramesPerMix: 0,
          lanes: <String, Object?>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          metrics: <String, Object?>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          raw: <String, String>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          lastError: 'invocation_failed',
        );

    // 1. Multi-Source Ingest & Format group
    print(
      '  [LANE] Multi-Source Ingest & Format: '
      'formatProbeOk=${activeReport.formatProbeOk}, '
      'nodeOwnedRouteDiscoveryOk=${activeReport.nodeOwnedRouteDiscoveryOk}, '
      'nodeOwnsRingTrack0Ok=${activeReport.nodeOwnsRingTrack0Ok}, '
      'nodeOwnsRingTrack1Ok=${activeReport.nodeOwnsRingTrack1Ok}, '
      'track0IngestOk=${activeReport.track0IngestOk}, '
      'track1SyntheticIngestOk=${activeReport.track1SyntheticIngestOk}, '
      'trackFrameAxisLockstepOk=${activeReport.trackFrameAxisLockstepOk}, '
      'sampleRate=${activeReport.sampleRate}, '
      'channelCount=${activeReport.channelCount}, '
      'pcmEncoding=${activeReport.pcmEncoding}, '
      'commonBudgetFrames=${activeReport.commonBudgetFrames}, '
      'expectedFrameCount=${activeReport.expectedFrameCount}, '
      'routedSourceId0=${activeReport.routedSourceId0}, '
      'routedSourceId1=${activeReport.routedSourceId1}, '
      'framesTruncatedBeyondBudget=${activeReport.framesTruncatedBeyondBudget}, '
      'totalFramesExtracted=${activeReport.totalFramesExtracted}, '
      'track1NonZeroSampleCount=${activeReport.track1NonZeroSampleCount}, '
      'decoderBenignFormatChangeCount=${activeReport.decoderBenignFormatChangeCount}',
    );

    // 2. AAudio Runtime & Config group
    print(
      '  [LANE] AAudio Runtime & Config: '
      'aaudioRuntimeAvailableOk=${activeReport.aaudioRuntimeAvailableOk}, '
      'aaudioSymbolsResolvedOk=${activeReport.aaudioSymbolsResolvedOk}, '
      'aaudioStreamOpenOk=${activeReport.aaudioStreamOpenOk}, '
      'aaudioConfigOk=${activeReport.aaudioConfigOk}, '
      'aaudioStartOk=${activeReport.aaudioStartOk}, '
      'deviceApiLevel=${activeReport.deviceApiLevel}, '
      'streamSampleRate=${activeReport.streamSampleRate}, '
      'streamChannelCount=${activeReport.streamChannelCount}, '
      'streamFormat=${activeReport.streamFormat}, '
      'aaudioChannelCountSymbolFallback=${activeReport.aaudioChannelCountSymbolFallback}',
    );

    // 3. Callback Accounting & Telemetry group
    print(
      '  [LANE] Callback Accounting & Telemetry: '
      'callbackObservedOk=${activeReport.callbackObservedOk}, '
      'aaudioCallbackAccountingOk=${activeReport.aaudioCallbackAccountingOk}, '
      'callbackAccountingCoherent=${activeReport.callbackAccountingCoherent}, '
      'finalCallbackCountersCoherent=${activeReport.finalCallbackCountersCoherent}, '
      'callbackInvocationCount=${activeReport.callbackInvocationCount}, '
      'callbackFramesRequested=${activeReport.callbackFramesRequested}, '
      'callbackFramesServed=${activeReport.callbackFramesServed}, '
      'callbackSilenceFrames=${activeReport.callbackSilenceFrames}, '
      'callbackShortReads=${activeReport.callbackShortReads}, '
      'errorCallbackCount=${activeReport.errorCallbackCount}',
    );

    // 4. Muted Sink & Checksums group
    print(
      '  [LANE] Muted Sink & Checksums: '
      'mutedOutputOk=${activeReport.mutedOutputOk}, '
      'mutedSinkIsZero=${activeReport.mutedSinkIsZero}, '
      'mutedSinkChecksumHex=${activeReport.mutedSinkChecksumHex}, '
      'nativeAcceptedChecksumHexTrack0=${activeReport.nativeAcceptedChecksumHexTrack0}, '
      'nativeAcceptedChecksumHexTrack1=${activeReport.nativeAcceptedChecksumHexTrack1}, '
      'nativeOutputDrainChecksumHex=${activeReport.nativeOutputDrainChecksumHex}, '
      'kotlinAcceptedChecksumHexTrack0=${activeReport.kotlinAcceptedChecksumHexTrack0}, '
      'kotlinAcceptedChecksumHexTrack1=${activeReport.kotlinAcceptedChecksumHexTrack1}, '
      'kotlinReferenceMixChecksumHex=${activeReport.kotlinReferenceMixChecksumHex}, '
      'graphOutputChecksumOk=${activeReport.graphOutputChecksumOk}, '
      'checksumsMatch=${activeReport.checksumsMatch}',
    );

    // 5. Frame Accounting & Lockstep group
    print(
      '  [LANE] Frame Accounting & Lockstep: '
      'totalFramesAcceptedTrack0=${activeReport.totalFramesAcceptedTrack0}, '
      'totalFramesAcceptedTrack1=${activeReport.totalFramesAcceptedTrack1}, '
      'totalOutputFramesPumped=${activeReport.totalOutputFramesPumped}, '
      'totalMutedFramesPushed=${activeReport.totalMutedFramesPushed}, '
      'postSeekFramesAccepted=${activeReport.postSeekFramesAccepted}, '
      'jointDispatchGateOk=${activeReport.jointDispatchGateOk}, '
      'dispatchCount=${activeReport.dispatchCount}, '
      'nextDispatchFrame=${activeReport.nextDispatchFrame}, '
      'maxFramesPerMix=${activeReport.maxFramesPerMix}',
    );

    // 6. Seek & Joint Tail Flush group
    print(
      '  [LANE] Seek & Joint Tail Flush: '
      'seekOk=${activeReport.seekOk}, '
      'jointTailFlushOk=${activeReport.jointTailFlushOk}, '
      'seekAcceptedFrame=${activeReport.seekAcceptedFrame}, '
      'seekSkippedDeadline=${activeReport.seekSkippedDeadline}',
    );

    // 7. Transport Health & Residuals group
    print(
      '  [LANE] Transport Health & Residuals: '
      'noProviderUnderrunOk=${activeReport.noProviderUnderrunOk}, '
      'noGraphSilenceOk=${activeReport.noGraphSilenceOk}, '
      'noRingPushShortfallOk=${activeReport.noRingPushShortfallOk}, '
      'providerUnderrunEventsTrack0=${activeReport.providerUnderrunEventsTrack0}, '
      'providerUnderrunEventsTrack1=${activeReport.providerUnderrunEventsTrack1}, '
      'providerFramesZeroFilledTrack0=${activeReport.providerFramesZeroFilledTrack0}, '
      'providerFramesZeroFilledTrack1=${activeReport.providerFramesZeroFilledTrack1}, '
      'providerForwardSkipFramesTrack0=${activeReport.providerForwardSkipFramesTrack0}, '
      'providerForwardSkipFramesTrack1=${activeReport.providerForwardSkipFramesTrack1}, '
      'providerRewindRejectsTrack0=${activeReport.providerRewindRejectsTrack0}, '
      'providerRewindRejectsTrack1=${activeReport.providerRewindRejectsTrack1}, '
      'coordinatorSilenceCount=${activeReport.coordinatorSilenceCount}, '
      'sinkFullWaitCount=${activeReport.sinkFullWaitCount}, '
      'sinkAvailableReadFramesFinal=${activeReport.sinkAvailableReadFramesFinal}, '
      'cancellationPollCount=${activeReport.cancellationPollCount}',
    );

    // 8. Architecture, Steady-State & Lifecycle group
    print(
      '  [LANE] Architecture, Steady-State & Lifecycle: '
      'zeroNativeSteadyStateAllocationOk=${activeReport.zeroNativeSteadyStateAllocationOk}, '
      'ownerThreadOk=${activeReport.ownerThreadOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'canonical=${activeReport.canonical}, '
      'nativeLastStatus=${activeReport.nativeLastStatus}',
    );

    // 9. Proof Boundary & Summary group
    print(
      '  [LANE] Proof Boundary & Summary: '
      'hasCanonicalProofBoundary=${activeReport.hasCanonicalProofBoundary}, '
      'hasPassMarker=${activeReport.hasPassMarker}, '
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
        activeReport.allNativeLanesPass &&
        activeReport.hasCanonicalProofBoundary &&
        activeReport.hasPassMarker &&
        activeReport.checksumsMatch &&
        activeReport.mutedSinkIsZero &&
        activeReport.callbackAccountingCoherent &&
        lastErrorOk;

    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AAUDIO_NODE_OWNED_SINK_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AAUDIO_NODE_OWNED_SINK_SMOKE_FAIL',
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAaudioNodeOwnedSinkPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-AAUDIO-NODE-OWNED-SINK-DIAGNOSTIC',
      'target': VGAaudioNodeOwnedSinkSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_AAUDIO_NODE_OWNED_SINK_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AAUDIO_NODE_OWNED_SINK_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AAUDIO_NODE_OWNED_SINK_PHYSICAL_SMOKE_FAIL',
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
