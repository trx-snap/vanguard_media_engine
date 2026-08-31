// android_audiotrack_output_sink_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-AUDIOTRACK-OUTPUT-SINK-WRITE
// (P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice I): Android True-DAG Phase 4
// AudioTrack output sink write diagnostic proof physical harness.
//
// Proof lanes:
//   - AudioTrack Sink & Write Accounting: formatProbeOk, audioTrackInitOk, sinkWriteAccountingOk, checksumIdentityOk, checksumsMatch, framesWrittenTotal, framesReadFromRingTotal, partialWriteCount, zeroWriteCount, sampleRate, channelCount, bufferSizeInFrames, bufferCapacityInFrames.
//   - Playback Head Consumption: playbackHeadMonotonicOk, playbackHeadAdvancedOk, headNeverExceedsWrittenOk, playbackHeadFinal, maxHeadLagFrames, finalHeadLagFrames.
//   - Pre-roll, Seek & Tail Flush: prerollOk, prerollFrames, seekEpochAccountingOk, seekAcceptedFrame, tailDrainedOk.
//   - Health & Transport Integrity: noUnderrunOk, noSilenceOk, noRingPushShortfallOk, zeroNativeSteadyStateAllocationOk, getUnderrunCount, totalFramesAccepted, totalOutputFramesDrained, dispatchCount.
//   - Concurrency & Lifecycle: ownerThreadOk, lifecycleOk, canonical, nativeLastStatus.
//   - AudioTimestamp Conditional Telemetry: audioTimestampAvailable, audioTimestampValidOk, audioTimestampAttemptCount, audioTimestampSuccessCount.
//   - Cancellation Polling & Non-Claim: cancellationPollingLiveOk, cancellationPollCount, detachCancellationProven.
//   - Proof Boundary & Summary: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   kotlin_owned_android_audiotrack_output_sink_write_diagnostic_proof_only_existing_h2_closed_loop_native_output_ring_source_no_cpp_os_sink_no_native_wall_clock_read_frame_derived_virtual_ticks_only_system_nanotime_telemetry_only_audio_timestamp_conditional_telemetry_only_playback_head_consumption_assertion_only_no_audible_output_claim_no_speaker_route_verification_no_audio_quality_claim_no_glitch_freedom_no_latency_budget_no_realtime_clock_sync_no_av_sync_no_pause_resume_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_offload_no_low_latency_mode_no_aaudio_no_opensl_no_oboe_no_dead_object_recovery_no_production_source_node_wiring_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_single_kotlin_worker_thread_all_jni_and_audiotrack_calls_direct_bytebuffer_reused_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim_no_in_band_dispose_cancellation_proof_detach_cancellation_source_audited_invariant_only

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioTrackOutputSinkPhysicalSmokeApp());
}

class AndroidAudioTrackOutputSinkPhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioTrackOutputSinkPhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioTrackOutputSinkPhysicalSmokeApp> createState() =>
      _AndroidAudioTrackOutputSinkPhysicalSmokeAppState();
}

class _AndroidAudioTrackOutputSinkPhysicalSmokeAppState
    extends State<AndroidAudioTrackOutputSinkPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 AudioTrack Output Sink smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AUDIOTRACK_OUTPUT_SINK_SMOKE_START');

    VGAudioTrackOutputSinkSmokeReport? report;
    String? topLevelError;
    File? tempSourceFile;

    try {
      final clipBData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempSourceFile = File(
        '${tempDir.path}/p4_audiotrack_output_sink_source_$timestamp.mov',
      );

      await tempSourceFile.writeAsBytes(
        clipBData.buffer.asUint8List(
          clipBData.offsetInBytes,
          clipBData.lengthInBytes,
        ),
        flush: true,
      );

      report =
          await VGAudioTrackOutputSinkSmokeReport.runAndroidDagPhase4AudioTrackOutputSinkSmoke(
            sourcePath: tempSourceFile.path,
            durationSec: 1.0,
            seekTargetSec: 0.35,
            volume: 0.0,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print('ANDROID_DAG_PHASE4_AUDIOTRACK_OUTPUT_SINK_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('ANDROID_DAG_PHASE4_AUDIOTRACK_OUTPUT_SINK_ERROR: $topLevelError');
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
        const VGAudioTrackOutputSinkSmokeReport(
          pass: false,
          status: 'fail',
          marker: VGAudioTrackOutputSinkSmokeReport.failMarkerConstant,
          proofBoundary: '',
          failureReason: 'invocation_failed',
          details: '',
          detachCancellationProven: false,
          formatProbeOk: false,
          audioTrackInitOk: false,
          prerollOk: false,
          sinkWriteAccountingOk: false,
          checksumIdentityOk: false,
          playbackHeadMonotonicOk: false,
          playbackHeadAdvancedOk: false,
          headNeverExceedsWrittenOk: false,
          tailDrainedOk: false,
          seekEpochAccountingOk: false,
          noUnderrunOk: false,
          noSilenceOk: false,
          noRingPushShortfallOk: false,
          zeroNativeSteadyStateAllocationOk: false,
          ownerThreadOk: false,
          lifecycleOk: false,
          canonical: false,
          cancellationPollingLiveOk: false,
          audioTimestampAvailable: false,
          audioTimestampValidOk: false,
          cancellationPollCount: 0,
          sampleRate: 0,
          channelCount: 0,
          audioTimestampAttemptCount: 0,
          audioTimestampSuccessCount: 0,
          playbackHeadFinal: 0,
          framesWrittenTotal: 0,
          framesReadFromRingTotal: 0,
          partialWriteCount: 0,
          zeroWriteCount: 0,
          getUnderrunCount: -1,
          bufferSizeInFrames: 0,
          bufferCapacityInFrames: 0,
          maxHeadLagFrames: 0,
          finalHeadLagFrames: -1,
          prerollFrames: 0,
          seekAcceptedFrame: -1,
          totalFramesAccepted: 0,
          totalOutputFramesDrained: 0,
          dispatchCount: 0,
          nativeOutputDrainChecksumHex: '',
          kotlinSinkChecksumHex: '',
          nativeLastStatus: '',
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

    // 1. AudioTrack Sink & Write Accounting group
    print(
      '  [LANE] AudioTrack Sink & Write Accounting: '
      'formatProbeOk=${activeReport.formatProbeOk}, '
      'audioTrackInitOk=${activeReport.audioTrackInitOk}, '
      'sinkWriteAccountingOk=${activeReport.sinkWriteAccountingOk}, '
      'checksumIdentityOk=${activeReport.checksumIdentityOk}, '
      'checksumsMatch=${activeReport.checksumsMatch}, '
      'framesWrittenTotal=${activeReport.framesWrittenTotal}, '
      'framesReadFromRingTotal=${activeReport.framesReadFromRingTotal}, '
      'partialWriteCount=${activeReport.partialWriteCount}, '
      'zeroWriteCount=${activeReport.zeroWriteCount}, '
      'sampleRate=${activeReport.sampleRate}, '
      'channelCount=${activeReport.channelCount}, '
      'bufferSizeInFrames=${activeReport.bufferSizeInFrames}, '
      'bufferCapacityInFrames=${activeReport.bufferCapacityInFrames}, '
      'nativeOutputDrainChecksumHex=${activeReport.nativeOutputDrainChecksumHex}, '
      'kotlinSinkChecksumHex=${activeReport.kotlinSinkChecksumHex}',
    );

    // 2. Playback Head Consumption group
    print(
      '  [LANE] Playback Head Consumption: '
      'playbackHeadMonotonicOk=${activeReport.playbackHeadMonotonicOk}, '
      'playbackHeadAdvancedOk=${activeReport.playbackHeadAdvancedOk}, '
      'headNeverExceedsWrittenOk=${activeReport.headNeverExceedsWrittenOk}, '
      'playbackHeadFinal=${activeReport.playbackHeadFinal}, '
      'maxHeadLagFrames=${activeReport.maxHeadLagFrames}, '
      'finalHeadLagFrames=${activeReport.finalHeadLagFrames}',
    );

    // 3. Pre-roll, Seek & Tail Flush group
    print(
      '  [LANE] Pre-roll, Seek & Tail Flush: '
      'prerollOk=${activeReport.prerollOk}, '
      'prerollFrames=${activeReport.prerollFrames}, '
      'seekEpochAccountingOk=${activeReport.seekEpochAccountingOk}, '
      'seekAcceptedFrame=${activeReport.seekAcceptedFrame}, '
      'tailDrainedOk=${activeReport.tailDrainedOk}',
    );

    // 4. Health & Transport Integrity group
    print(
      '  [LANE] Health & Transport Integrity: '
      'noUnderrunOk=${activeReport.noUnderrunOk}, '
      'noSilenceOk=${activeReport.noSilenceOk}, '
      'noRingPushShortfallOk=${activeReport.noRingPushShortfallOk}, '
      'zeroNativeSteadyStateAllocationOk=${activeReport.zeroNativeSteadyStateAllocationOk}, '
      'getUnderrunCount=${activeReport.getUnderrunCount}, '
      'totalFramesAccepted=${activeReport.totalFramesAccepted}, '
      'totalOutputFramesDrained=${activeReport.totalOutputFramesDrained}, '
      'dispatchCount=${activeReport.dispatchCount}',
    );

    // 5. Concurrency & Lifecycle group
    print(
      '  [LANE] Concurrency & Lifecycle: '
      'ownerThreadOk=${activeReport.ownerThreadOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'canonical=${activeReport.canonical}, '
      'nativeLastStatus=${activeReport.nativeLastStatus}',
    );

    // 6. AudioTimestamp Conditional Telemetry group
    print(
      '  [LANE] AudioTimestamp Conditional Telemetry: '
      'audioTimestampAvailable=${activeReport.audioTimestampAvailable}, '
      'audioTimestampValidOk=${activeReport.audioTimestampValidOk}, '
      'audioTimestampAttemptCount=${activeReport.audioTimestampAttemptCount}, '
      'audioTimestampSuccessCount=${activeReport.audioTimestampSuccessCount}',
    );

    // 7. Cancellation Polling & Non-Claim group
    print(
      '  [LANE] Cancellation Polling & Non-Claim: '
      'cancellationPollingLiveOk=${activeReport.cancellationPollingLiveOk}, '
      'cancellationPollCount=${activeReport.cancellationPollCount}, '
      'detachCancellationProven=${activeReport.detachCancellationProven}',
    );

    // 8. Proof Boundary & Summary group
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
        activeReport.allNativeLanesPass &&
        !activeReport.detachCancellationProven &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAudioTrackOutputSinkPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-AUDIOTRACK-OUTPUT-SINK-WRITE',
      'target': VGAudioTrackOutputSinkSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_AUDIOTRACK_OUTPUT_SINK_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIOTRACK_OUTPUT_SINK_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIOTRACK_OUTPUT_SINK_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (allNativeLanesPass=true, hasCanonicalProofBoundary=true, detachCancellationProven=false)'
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
