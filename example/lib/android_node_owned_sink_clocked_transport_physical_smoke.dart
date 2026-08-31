// android_node_owned_sink_clocked_transport_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-NODE-OWNED-SINK-CLOCKED-TRANSPORT: Android True-DAG Phase 4
// node-owned AudioTrack sink-clocked transport diagnostic proof physical harness.
//
// Proof lanes:
//   - Codec & Format group: formatProbeOk, mutedOutputOk, sampleRate, channelCount, pcmEncoding, expectedFrameCount.
//   - Sink & Buffer group: audioTrackInitOk, bufferSizeInFrames, bufferCapacityInFrames, startThresholdFrames, prerollFrames, targetLeadFrames, zeroWriteCount, partialWriteCount, audioTrackReleaseCount.
//   - Routing & Ownership group: nodeOwnedRouteDiscoveryOk, nodeOwnsRingOk.
//   - Timebase & Clock group: startAckOk, sinkClockedDispatchOk, timestampTelemetryOk, playbackHeadMonotonicOk, playbackHeadAdvancedOk, playbackHeadFinal, audioTimestampAttemptCount, audioTimestampSuccessCount, headSampleCount, maxSinkLagFrames, maxDispatchLeadFrames, minDispatchLeadFrames.
//   - Checksum Identity group: kotlinSinkChecksumHex, nativeAcceptedChecksumHex, nativeOutputDrainChecksumHex, checksumIdentityOk, checksumsMatch.
//   - Frame Accounting group: totalFramesExtracted, totalFramesAccepted, totalOutputFramesDrained, framesReadFromRingTotal, framesWrittenTotal, postSeekFramesAccepted, postSeekFramesDrained, frameAccountingOk, sinkWriteAccountingOk, sinkFramesAccounted.
//   - Seek & Tail Flush group: seekOk, seekAcceptedFrame, tailFlushOk, finalSeekAckClearOk.
//   - Integrity & Health group: steadyStateUnderrunFreeOk, underrunBaseline, underrunFinal, underrunDelta, noProviderUnderrunOk, noSilenceOk, noForwardSkipOk, noRewindRejectOk, finalNotTerminalOk, providerUnderrunEvents, providerFramesZeroFilled, providerForwardSkipFrames, providerRewindRejects, coordinatorSilenceCount.
//   - Architecture & Concurrency group: zeroNativeSteadyStateAllocationOk, cancellationPollingOk, cancellationPollCount, lifecycleOk, nativeDestroyCallCount, canonical, dispatchCount, bootstrapDispatchCount, sinkClockedDispatchCountEpoch0, sinkClockedDispatchCountEpoch1, maxFramesPerMix, sourceAvailableReadFrames, outputAvailableReadFrames, nextDispatchFrame.
//   - Proof Boundary & Summary group: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   kotlin_owned_android_audiotrack_node_owned_source_sink_clocked_transport_diagnostic_proof_only_real_decoder_to_node_owned_decoded_audio_source_graph_pipeline_output_ring_to_audiotrack_write_accounting_sink_clocked_timebase_audio_timestamp_conditional_playback_head_fallback_system_nanotime_anchor_kotlin_only_no_cpp_wall_clock_read_no_native_audio_sink_no_aaudio_no_opensl_no_oboe_no_audible_output_claim_no_speaker_route_verification_no_audio_quality_claim_no_glitch_freedom_no_latency_budget_no_realtime_av_sync_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_dead_object_recovery_no_offload_no_low_latency_mode_no_production_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_streaming_no_cache_no_ios_single_routed_track_unit_gain_only_no_resample_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_single_kotlin_worker_thread_all_jni_and_audiotrack_calls_no_jni_reverse_callbacks_no_native_worker_threads_jni_session_registry_mutex_lifecycle_only_no_locks_in_vanguard_audio_primitives_direct_bytebuffer_reused_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidNodeOwnedSinkClockedTransportPhysicalSmokeApp());
}

class AndroidNodeOwnedSinkClockedTransportPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidNodeOwnedSinkClockedTransportPhysicalSmokeApp({super.key});

  @override
  State<AndroidNodeOwnedSinkClockedTransportPhysicalSmokeApp> createState() =>
      _AndroidNodeOwnedSinkClockedTransportPhysicalSmokeAppState();
}

class _AndroidNodeOwnedSinkClockedTransportPhysicalSmokeAppState
    extends State<AndroidNodeOwnedSinkClockedTransportPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Node-Owned Sink-Clocked Transport smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_NODE_OWNED_SINK_CLOCKED_TRANSPORT_SMOKE_START');

    VGNodeOwnedSinkClockedTransportSmokeReport? report;
    String? topLevelError;
    File? tempSourceFile;

    try {
      final clipBData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempSourceFile = File(
        '${tempDir.path}/p4_node_owned_sink_clocked_transport_source_$timestamp.mov',
      );

      await tempSourceFile.writeAsBytes(
        clipBData.buffer.asUint8List(
          clipBData.offsetInBytes,
          clipBData.lengthInBytes,
        ),
        flush: true,
      );

      report =
          await VGNodeOwnedSinkClockedTransportSmokeReport.runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke(
            sourcePath: tempSourceFile.path,
            durationSec: 1.0,
            seekTargetSec: 0.35,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_NODE_OWNED_SINK_CLOCKED_TRANSPORT_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_NODE_OWNED_SINK_CLOCKED_TRANSPORT_ERROR: $topLevelError',
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
        const VGNodeOwnedSinkClockedTransportSmokeReport(
          pass: false,
          status: 'fail',
          marker: VGNodeOwnedSinkClockedTransportSmokeReport.failMarkerConstant,
          proofBoundary: '',
          failureReason: 'invocation_failed',
          details: '',
          formatProbeOk: false,
          audioTrackInitOk: false,
          mutedOutputOk: false,
          nodeOwnedRouteDiscoveryOk: false,
          nodeOwnsRingOk: false,
          startAckOk: false,
          sinkClockedDispatchOk: false,
          timestampTelemetryOk: false,
          playbackHeadMonotonicOk: false,
          playbackHeadAdvancedOk: false,
          sinkWriteAccountingOk: false,
          checksumIdentityOk: false,
          frameAccountingOk: false,
          seekOk: false,
          tailFlushOk: false,
          steadyStateUnderrunFreeOk: false,
          noProviderUnderrunOk: false,
          noSilenceOk: false,
          noForwardSkipOk: false,
          noRewindRejectOk: false,
          finalNotTerminalOk: false,
          finalSeekAckClearOk: false,
          zeroNativeSteadyStateAllocationOk: false,
          cancellationPollingOk: false,
          lifecycleOk: false,
          canonical: false,
          sampleRate: 0,
          channelCount: 0,
          pcmEncoding: 0,
          expectedFrameCount: 0,
          totalFramesExtracted: 0,
          totalFramesAccepted: 0,
          totalOutputFramesDrained: 0,
          framesReadFromRingTotal: 0,
          framesWrittenTotal: 0,
          postSeekFramesAccepted: 0,
          postSeekFramesDrained: 0,
          nativeAcceptedChecksumHex: '',
          nativeOutputDrainChecksumHex: '',
          kotlinSinkChecksumHex: '',
          dispatchCount: 0,
          maxFramesPerMix: 0,
          sourceAvailableReadFrames: -1,
          outputAvailableReadFrames: -1,
          nextDispatchFrame: -1,
          bootstrapDispatchCount: 0,
          sinkClockedDispatchCountEpoch0: 0,
          sinkClockedDispatchCountEpoch1: 0,
          prerollFrames: 0,
          targetLeadFrames: 0,
          bufferSizeInFrames: 0,
          bufferCapacityInFrames: 0,
          startThresholdFrames: -1,
          audioTimestampAttemptCount: 0,
          audioTimestampSuccessCount: 0,
          headSampleCount: 0,
          playbackHeadFinal: 0,
          maxSinkLagFrames: -1,
          maxDispatchLeadFrames: -1,
          minDispatchLeadFrames: -1,
          underrunBaseline: -1,
          underrunFinal: -1,
          underrunDelta: 0,
          zeroWriteCount: 0,
          partialWriteCount: 0,
          audioTrackReleaseCount: 0,
          nativeDestroyCallCount: 0,
          seekAcceptedFrame: -1,
          providerUnderrunEvents: -1,
          providerFramesZeroFilled: -1,
          providerForwardSkipFrames: -1,
          providerRewindRejects: -1,
          coordinatorSilenceCount: -1,
          cancellationPollCount: 0,
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

    // 1. Codec & Format group
    print(
      '  [LANE] Codec & Format: '
      'formatProbeOk=${activeReport.formatProbeOk}, '
      'mutedOutputOk=${activeReport.mutedOutputOk}, '
      'sampleRate=${activeReport.sampleRate}, '
      'channelCount=${activeReport.channelCount}, '
      'pcmEncoding=${activeReport.pcmEncoding}, '
      'expectedFrameCount=${activeReport.expectedFrameCount}',
    );

    // 2. Sink & Buffer group
    print(
      '  [LANE] Sink & Buffer: '
      'audioTrackInitOk=${activeReport.audioTrackInitOk}, '
      'bufferSizeInFrames=${activeReport.bufferSizeInFrames}, '
      'bufferCapacityInFrames=${activeReport.bufferCapacityInFrames}, '
      'startThresholdFrames=${activeReport.startThresholdFrames}, '
      'prerollFrames=${activeReport.prerollFrames}, '
      'targetLeadFrames=${activeReport.targetLeadFrames}, '
      'zeroWriteCount=${activeReport.zeroWriteCount}, '
      'partialWriteCount=${activeReport.partialWriteCount}, '
      'audioTrackReleaseCount=${activeReport.audioTrackReleaseCount}',
    );

    // 3. Routing & Ownership group
    print(
      '  [LANE] Routing & Ownership: '
      'nodeOwnedRouteDiscoveryOk=${activeReport.nodeOwnedRouteDiscoveryOk}, '
      'nodeOwnsRingOk=${activeReport.nodeOwnsRingOk}',
    );

    // 4. Timebase & Clock group
    print(
      '  [LANE] Timebase & Clock: '
      'startAckOk=${activeReport.startAckOk}, '
      'sinkClockedDispatchOk=${activeReport.sinkClockedDispatchOk}, '
      'timestampTelemetryOk=${activeReport.timestampTelemetryOk}, '
      'playbackHeadMonotonicOk=${activeReport.playbackHeadMonotonicOk}, '
      'playbackHeadAdvancedOk=${activeReport.playbackHeadAdvancedOk}, '
      'playbackHeadFinal=${activeReport.playbackHeadFinal}, '
      'audioTimestampAttemptCount=${activeReport.audioTimestampAttemptCount}, '
      'audioTimestampSuccessCount=${activeReport.audioTimestampSuccessCount}, '
      'headSampleCount=${activeReport.headSampleCount}, '
      'maxSinkLagFrames=${activeReport.maxSinkLagFrames}, '
      'maxDispatchLeadFrames=${activeReport.maxDispatchLeadFrames}, '
      'minDispatchLeadFrames=${activeReport.minDispatchLeadFrames}',
    );

    // 5. Checksum Identity group
    print(
      '  [LANE] Checksum Identity: '
      'kotlinSinkChecksumHex=${activeReport.kotlinSinkChecksumHex}, '
      'nativeAcceptedChecksumHex=${activeReport.nativeAcceptedChecksumHex}, '
      'nativeOutputDrainChecksumHex=${activeReport.nativeOutputDrainChecksumHex}, '
      'checksumIdentityOk=${activeReport.checksumIdentityOk}, '
      'checksumsMatch=${activeReport.checksumsMatch}',
    );

    // 6. Frame Accounting group
    print(
      '  [LANE] Frame Accounting: '
      'totalFramesExtracted=${activeReport.totalFramesExtracted}, '
      'totalFramesAccepted=${activeReport.totalFramesAccepted}, '
      'totalOutputFramesDrained=${activeReport.totalOutputFramesDrained}, '
      'framesReadFromRingTotal=${activeReport.framesReadFromRingTotal}, '
      'framesWrittenTotal=${activeReport.framesWrittenTotal}, '
      'postSeekFramesAccepted=${activeReport.postSeekFramesAccepted}, '
      'postSeekFramesDrained=${activeReport.postSeekFramesDrained}, '
      'frameAccountingOk=${activeReport.frameAccountingOk}, '
      'sinkWriteAccountingOk=${activeReport.sinkWriteAccountingOk}, '
      'sinkFramesAccounted=${activeReport.sinkFramesAccounted}',
    );

    // 7. Seek & Tail Flush group
    print(
      '  [LANE] Seek & Tail Flush: '
      'seekOk=${activeReport.seekOk}, '
      'seekAcceptedFrame=${activeReport.seekAcceptedFrame}, '
      'tailFlushOk=${activeReport.tailFlushOk}, '
      'finalSeekAckClearOk=${activeReport.finalSeekAckClearOk}',
    );

    // 8. Integrity & Health group
    print(
      '  [LANE] Integrity & Health: '
      'steadyStateUnderrunFreeOk=${activeReport.steadyStateUnderrunFreeOk}, '
      'underrunBaseline=${activeReport.underrunBaseline}, '
      'underrunFinal=${activeReport.underrunFinal}, '
      'underrunDelta=${activeReport.underrunDelta}, '
      'noProviderUnderrunOk=${activeReport.noProviderUnderrunOk}, '
      'noSilenceOk=${activeReport.noSilenceOk}, '
      'noForwardSkipOk=${activeReport.noForwardSkipOk}, '
      'noRewindRejectOk=${activeReport.noRewindRejectOk}, '
      'finalNotTerminalOk=${activeReport.finalNotTerminalOk}, '
      'providerUnderrunEvents=${activeReport.providerUnderrunEvents}, '
      'providerFramesZeroFilled=${activeReport.providerFramesZeroFilled}, '
      'providerForwardSkipFrames=${activeReport.providerForwardSkipFrames}, '
      'providerRewindRejects=${activeReport.providerRewindRejects}, '
      'coordinatorSilenceCount=${activeReport.coordinatorSilenceCount}',
    );

    // 9. Architecture & Concurrency group
    print(
      '  [LANE] Architecture & Concurrency: '
      'zeroNativeSteadyStateAllocationOk=${activeReport.zeroNativeSteadyStateAllocationOk}, '
      'cancellationPollingOk=${activeReport.cancellationPollingOk}, '
      'cancellationPollCount=${activeReport.cancellationPollCount}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'nativeDestroyCallCount=${activeReport.nativeDestroyCallCount}, '
      'canonical=${activeReport.canonical}, '
      'dispatchCount=${activeReport.dispatchCount}, '
      'bootstrapDispatchCount=${activeReport.bootstrapDispatchCount}, '
      'sinkClockedDispatchCountEpoch0=${activeReport.sinkClockedDispatchCountEpoch0}, '
      'sinkClockedDispatchCountEpoch1=${activeReport.sinkClockedDispatchCountEpoch1}, '
      'maxFramesPerMix=${activeReport.maxFramesPerMix}, '
      'sourceAvailableReadFrames=${activeReport.sourceAvailableReadFrames}, '
      'outputAvailableReadFrames=${activeReport.outputAvailableReadFrames}, '
      'nextDispatchFrame=${activeReport.nextDispatchFrame}',
    );

    // 10. Proof Boundary & Summary group
    print(
      '  [LANE] Proof Boundary & Summary: '
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
        activeReport.sinkFramesAccounted &&
        activeReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidNodeOwnedSinkClockedTransportPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-NODE-OWNED-SINK-CLOCKED-TRANSPORT',
      'target':
          VGNodeOwnedSinkClockedTransportSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_NODE_OWNED_SINK_CLOCKED_TRANSPORT_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? VGNodeOwnedSinkClockedTransportSmokeReport.passMarkerConstant
          : VGNodeOwnedSinkClockedTransportSmokeReport.failMarkerConstant,
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
