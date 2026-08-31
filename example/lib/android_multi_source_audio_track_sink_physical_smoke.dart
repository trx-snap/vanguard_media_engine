// android_multi_source_audio_track_sink_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-MULTI-SOURCE-AUDIOTRACK-SINK
// (P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice K): Android True-DAG Phase 4
// Multi-Source AudioTrack output sink write diagnostic proof physical harness.
//
// Proof lanes:
//   - Multi-Source Ingest & Format: formatProbeOk, sampleRate, channelCount, commonBudgetFrames, framesTruncatedBeyondBudget, totalFramesExtracted, generatorReanchorCount, track1NonZeroSampleCount.
//   - AudioTrack Sink & Write Accounting: audioTrackInitOk, sinkWriteAccountingOk, framesWrittenTotal, framesReadFromRingTotal, partialWriteCount, zeroWriteCount, bufferSizeInFrames, bufferCapacityInFrames.
//   - Playback Head Consumption: playbackHeadMonotonicOk, playbackHeadAdvancedOk, playbackHeadBoundedOk, playbackHeadFinal, maxHeadLagFrames, finalHeadLagFrames.
//   - Pre-roll, Seek & Joint Tail Flush: prerollOk, prerollFrames, prerollEpochsSatisfied, seekEpochAccountingOk, seekAcceptedFrame, jointTailFlushOk.
//   - Joint Gating & Contribution: jointDispatchGateOk, twoTrackContributionOk, dispatchCount.
//   - Checksum Identity: referenceMixChecksumOk, nativeDrainChecksumMatchesSinkOk, kotlinReferenceMixChecksumHex, nativeOutputDrainChecksumHex, kotlinSinkChecksumHex, checksumsMatch.
//   - Frame Accounting & Lockstep: totalFramesAcceptedTrack0, totalFramesAcceptedTrack1, totalOutputFramesDrained, trackFrameAxisLockstepOk, mixedOutputFrameAccountingOk.
//   - Architecture, Steady-State & Lifecycle: zeroNativeSteadyStateAllocationOk, ownerThreadOk, lifecycleOk, canonical, nativeLastStatus, getUnderrunCount.
//   - AudioTimestamp Conditional Telemetry: audioTimestampAvailable, audioTimestampValidOk, audioTimestampAttemptCount, audioTimestampSuccessCount.
//   - Cancellation Polling & Non-Claim: cancellationPollingLiveOk, cancellationPollCount, detachCancellationProven.
//   - Proof Boundary & Summary: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   kotlin_owned_android_audiotrack_multi_source_output_sink_write_diagnostic_proof_only_real_decoder_plus_synthetic_second_track_step_driven_closed_loop_native_audio_graph_pipeline_session_no_second_os_decoder_no_cpp_os_sink_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_read_frame_derived_virtual_ticks_only_system_nanotime_telemetry_only_audio_timestamp_conditional_telemetry_only_playback_head_consumption_assertion_only_no_audible_output_claim_no_speaker_route_verification_no_audio_quality_claim_no_glitch_freedom_no_latency_budget_no_realtime_clock_sync_no_av_sync_audiotrack_pause_flush_for_seek_epoch_only_no_transport_pause_resume_semantics_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_offload_no_low_latency_mode_no_aaudio_no_opensl_no_oboe_no_dead_object_recovery_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_truncation_beyond_budget_non_claim_two_routed_tracks_unit_gain_only_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_joint_tail_flush_diagnostic_only_no_jni_reverse_callbacks_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_source_node_pcm_ingest_topology_anchor_only_no_production_source_node_wiring_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_single_kotlin_worker_thread_all_jni_and_audiotrack_calls_direct_bytebuffer_reused_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim_no_in_band_dispose_cancellation_proof_detach_cancellation_source_audited_invariant_only

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidMultiSourceAudioTrackSinkPhysicalSmokeApp());
}

class AndroidMultiSourceAudioTrackSinkPhysicalSmokeApp extends StatefulWidget {
  const AndroidMultiSourceAudioTrackSinkPhysicalSmokeApp({super.key});

  @override
  State<AndroidMultiSourceAudioTrackSinkPhysicalSmokeApp> createState() =>
      _AndroidMultiSourceAudioTrackSinkPhysicalSmokeAppState();
}

class _AndroidMultiSourceAudioTrackSinkPhysicalSmokeAppState
    extends State<AndroidMultiSourceAudioTrackSinkPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Multi-Source AudioTrack Sink smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_MULTI_SOURCE_AUDIO_TRACK_SINK_SMOKE_START');

    VGMultiSourceAudioTrackSinkSmokeReport? report;
    String? topLevelError;
    File? tempSourceFile;

    try {
      final clipBData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempSourceFile = File(
        '${tempDir.path}/p4_multi_source_audiotrack_sink_source_$timestamp.mov',
      );

      await tempSourceFile.writeAsBytes(
        clipBData.buffer.asUint8List(
          clipBData.offsetInBytes,
          clipBData.lengthInBytes,
        ),
        flush: true,
      );

      report =
          await VGMultiSourceAudioTrackSinkSmokeReport.runAndroidDagPhase4MultiSourceAudioTrackSinkSmoke(
            sourcePath: tempSourceFile.path,
            durationSec: 1.0,
            seekTargetSec: 0.35,
            volume: 0.0,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_MULTI_SOURCE_AUDIO_TRACK_SINK_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_MULTI_SOURCE_AUDIO_TRACK_SINK_ERROR: $topLevelError',
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
        const VGMultiSourceAudioTrackSinkSmokeReport(
          pass: false,
          status: 'fail',
          marker: VGMultiSourceAudioTrackSinkSmokeReport.failMarkerConstant,
          proofBoundary: '',
          failureReason: 'invocation_failed',
          details: '',
          detachCancellationProven: false,
          formatProbeOk: false,
          audioTrackInitOk: false,
          prerollOk: false,
          playbackHeadMonotonicOk: false,
          playbackHeadAdvancedOk: false,
          playbackHeadBoundedOk: false,
          sinkWriteAccountingOk: false,
          seekEpochAccountingOk: false,
          jointDispatchGateOk: false,
          jointTailFlushOk: false,
          twoTrackContributionOk: false,
          referenceMixChecksumOk: false,
          nativeDrainChecksumMatchesSinkOk: false,
          trackFrameAxisLockstepOk: false,
          mixedOutputFrameAccountingOk: false,
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
          commonBudgetFrames: 0,
          framesTruncatedBeyondBudget: 0,
          totalFramesExtracted: 0,
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
          prerollEpochsSatisfied: 0,
          seekAcceptedFrame: -1,
          generatorReanchorCount: 0,
          track1NonZeroSampleCount: 0,
          totalFramesAcceptedTrack0: 0,
          totalFramesAcceptedTrack1: 0,
          totalOutputFramesDrained: 0,
          dispatchCount: 0,
          audioTimestampAttemptCount: 0,
          audioTimestampSuccessCount: 0,
          nativeOutputDrainChecksumHex: '',
          kotlinReferenceMixChecksumHex: '',
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

    // 1. Multi-Source Ingest & Format group
    print(
      '  [LANE] Multi-Source Ingest & Format: '
      'formatProbeOk=${activeReport.formatProbeOk}, '
      'sampleRate=${activeReport.sampleRate}, '
      'channelCount=${activeReport.channelCount}, '
      'commonBudgetFrames=${activeReport.commonBudgetFrames}, '
      'framesTruncatedBeyondBudget=${activeReport.framesTruncatedBeyondBudget}, '
      'totalFramesExtracted=${activeReport.totalFramesExtracted}, '
      'generatorReanchorCount=${activeReport.generatorReanchorCount}, '
      'track1NonZeroSampleCount=${activeReport.track1NonZeroSampleCount}',
    );

    // 2. AudioTrack Sink & Write Accounting group
    print(
      '  [LANE] AudioTrack Sink & Write Accounting: '
      'audioTrackInitOk=${activeReport.audioTrackInitOk}, '
      'sinkWriteAccountingOk=${activeReport.sinkWriteAccountingOk}, '
      'framesWrittenTotal=${activeReport.framesWrittenTotal}, '
      'framesReadFromRingTotal=${activeReport.framesReadFromRingTotal}, '
      'partialWriteCount=${activeReport.partialWriteCount}, '
      'zeroWriteCount=${activeReport.zeroWriteCount}, '
      'bufferSizeInFrames=${activeReport.bufferSizeInFrames}, '
      'bufferCapacityInFrames=${activeReport.bufferCapacityInFrames}',
    );

    // 3. Playback Head Consumption group
    print(
      '  [LANE] Playback Head Consumption: '
      'playbackHeadMonotonicOk=${activeReport.playbackHeadMonotonicOk}, '
      'playbackHeadAdvancedOk=${activeReport.playbackHeadAdvancedOk}, '
      'playbackHeadBoundedOk=${activeReport.playbackHeadBoundedOk}, '
      'playbackHeadFinal=${activeReport.playbackHeadFinal}, '
      'maxHeadLagFrames=${activeReport.maxHeadLagFrames}, '
      'finalHeadLagFrames=${activeReport.finalHeadLagFrames}',
    );

    // 4. Pre-roll, Seek & Joint Tail Flush group
    print(
      '  [LANE] Pre-roll, Seek & Joint Tail Flush: '
      'prerollOk=${activeReport.prerollOk}, '
      'prerollFrames=${activeReport.prerollFrames}, '
      'prerollEpochsSatisfied=${activeReport.prerollEpochsSatisfied}, '
      'seekEpochAccountingOk=${activeReport.seekEpochAccountingOk}, '
      'seekAcceptedFrame=${activeReport.seekAcceptedFrame}, '
      'jointTailFlushOk=${activeReport.jointTailFlushOk}',
    );

    // 5. Joint Gating & Contribution group
    print(
      '  [LANE] Joint Gating & Contribution: '
      'jointDispatchGateOk=${activeReport.jointDispatchGateOk}, '
      'twoTrackContributionOk=${activeReport.twoTrackContributionOk}, '
      'dispatchCount=${activeReport.dispatchCount}',
    );

    // 6. Checksum Identity group
    print(
      '  [LANE] Checksum Identity: '
      'referenceMixChecksumOk=${activeReport.referenceMixChecksumOk}, '
      'nativeDrainChecksumMatchesSinkOk=${activeReport.nativeDrainChecksumMatchesSinkOk}, '
      'kotlinReferenceMixChecksumHex=${activeReport.kotlinReferenceMixChecksumHex}, '
      'nativeOutputDrainChecksumHex=${activeReport.nativeOutputDrainChecksumHex}, '
      'kotlinSinkChecksumHex=${activeReport.kotlinSinkChecksumHex}, '
      'checksumsMatch=${activeReport.checksumsMatch}',
    );

    // 7. Frame Accounting & Lockstep group
    print(
      '  [LANE] Frame Accounting & Lockstep: '
      'totalFramesAcceptedTrack0=${activeReport.totalFramesAcceptedTrack0}, '
      'totalFramesAcceptedTrack1=${activeReport.totalFramesAcceptedTrack1}, '
      'totalOutputFramesDrained=${activeReport.totalOutputFramesDrained}, '
      'trackFrameAxisLockstepOk=${activeReport.trackFrameAxisLockstepOk}, '
      'mixedOutputFrameAccountingOk=${activeReport.mixedOutputFrameAccountingOk}',
    );

    // 8. Architecture, Steady-State & Lifecycle group
    print(
      '  [LANE] Architecture, Steady-State & Lifecycle: '
      'zeroNativeSteadyStateAllocationOk=${activeReport.zeroNativeSteadyStateAllocationOk}, '
      'ownerThreadOk=${activeReport.ownerThreadOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'canonical=${activeReport.canonical}, '
      'nativeLastStatus=${activeReport.nativeLastStatus}, '
      'getUnderrunCount=${activeReport.getUnderrunCount}',
    );

    // 9. AudioTimestamp Conditional Telemetry group
    print(
      '  [LANE] AudioTimestamp Conditional Telemetry: '
      'audioTimestampAvailable=${activeReport.audioTimestampAvailable}, '
      'audioTimestampValidOk=${activeReport.audioTimestampValidOk}, '
      'audioTimestampAttemptCount=${activeReport.audioTimestampAttemptCount}, '
      'audioTimestampSuccessCount=${activeReport.audioTimestampSuccessCount}',
    );

    // 10. Cancellation Polling & Non-Claim group
    print(
      '  [LANE] Cancellation Polling & Non-Claim: '
      'cancellationPollingLiveOk=${activeReport.cancellationPollingLiveOk}, '
      'cancellationPollCount=${activeReport.cancellationPollCount}, '
      'detachCancellationProven=${activeReport.detachCancellationProven}',
    );

    // 11. Proof Boundary & Summary group
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
      'unit': 'AndroidMultiSourceAudioTrackSinkPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-MULTI-SOURCE-AUDIOTRACK-SINK',
      'target': VGMultiSourceAudioTrackSinkSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_MULTI_SOURCE_AUDIO_TRACK_SINK_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_MULTI_SOURCE_AUDIO_TRACK_SINK_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_MULTI_SOURCE_AUDIO_TRACK_SINK_SMOKE_FAIL',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_MULTI_SOURCE_AUDIO_TRACK_SINK_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_MULTI_SOURCE_AUDIO_TRACK_SINK_PHYSICAL_SMOKE_FAIL',
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
