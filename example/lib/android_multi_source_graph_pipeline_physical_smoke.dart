// android_multi_source_graph_pipeline_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-MULTI-SOURCE-GRAPH-PIPELINE: Android True-DAG Phase 4
// two-source closed-loop native audio graph pipeline diagnostic proof physical harness.
//
// Proof lanes:
//   - Multi-Source Ingest & Format group: formatProbeOk, topologyRoutedSourcesOk, track0IngestOk, track1SyntheticIngestOk, sampleRate, channelCount, pcmEncoding, commonBudgetFrames, framesTruncatedBeyondBudget, totalFramesExtracted, track1NonZeroSampleCount, decoderBenignFormatChangeCount.
//   - Joint Gating & Contribution group: jointDispatchGateOk, twoTrackContributionOk, mixedChecksumDiffersFromTrack0, mixedChecksumDiffersFromTrack1, maxFramesPerMix, dispatchCount, nextDispatchFrame.
//   - Checksum Identity group: kotlinAcceptedChecksumHexTrack0, nativeAcceptedChecksumHexTrack0, kotlinAcceptedChecksumHexTrack1, nativeAcceptedChecksumHexTrack1, kotlinReferenceMixChecksumHex, nativeOutputDrainChecksumHex, referenceMixChecksumOk, checksumsMatch.
//   - Frame Accounting & Lockstep group: totalFramesAcceptedTrack0, totalFramesAcceptedTrack1, totalOutputFramesDrained, postSeekFramesAccepted, postSeekFramesDrained, trackFrameAxisLockstepOk, mixedOutputFrameAccountingOk.
//   - Seek & Joint Tail Flush group: seekOk, jointTailFlushOk, seekAcceptedFrame.
//   - Transport Health & Residuals group: noProviderUnderrunOk, noZeroFillOk, noForwardSkipOk, noRewindRejectOk, noSilenceOk, noRingPushShortfallOk, providerUnderrunEventsTrack0, providerUnderrunEventsTrack1, providerFramesZeroFilledTrack0, providerFramesZeroFilledTrack1, providerForwardSkipFramesTrack0, providerForwardSkipFramesTrack1, providerRewindRejectsTrack0, providerRewindRejectsTrack1, coordinatorSilenceCount, sourceAvailableReadFramesTrack0, sourceAvailableReadFramesTrack1, outputAvailableReadFrames.
//   - Architecture, Steady-State & Lifecycle group: zeroNativeSteadyStateAllocationOk, ownerThreadOk, lifecycleOk, canonical, nativeLastStatus.
//   - Proof Boundary & Summary group: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   kotlin_owned_real_decoder_plus_synthetic_second_track_step_driven_multi_source_closed_loop_native_audio_graph_pipeline_session_proof_only_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_diagnostic_graph_topology_only_two_routed_tracks_unit_gain_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_joint_tail_flush_diagnostic_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidMultiSourceGraphPipelinePhysicalSmokeApp());
}

class AndroidMultiSourceGraphPipelinePhysicalSmokeApp extends StatefulWidget {
  const AndroidMultiSourceGraphPipelinePhysicalSmokeApp({super.key});

  @override
  State<AndroidMultiSourceGraphPipelinePhysicalSmokeApp> createState() =>
      _AndroidMultiSourceGraphPipelinePhysicalSmokeAppState();
}

class _AndroidMultiSourceGraphPipelinePhysicalSmokeAppState
    extends State<AndroidMultiSourceGraphPipelinePhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Multi-Source Graph Pipeline smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_MULTI_SOURCE_GRAPH_PIPELINE_SMOKE_START');

    VGMultiSourceGraphPipelineSmokeReport? report;
    String? topLevelError;
    File? tempSourceFile;

    try {
      final clipBData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempSourceFile = File(
        '${tempDir.path}/p4_multi_source_pipeline_source_$timestamp.mov',
      );

      await tempSourceFile.writeAsBytes(
        clipBData.buffer.asUint8List(
          clipBData.offsetInBytes,
          clipBData.lengthInBytes,
        ),
        flush: true,
      );

      report =
          await VGMultiSourceGraphPipelineSmokeReport.runAndroidDagPhase4MultiSourceGraphPipelineSmoke(
            sourcePath: tempSourceFile.path,
            durationSec: 1.0,
            seekTargetSec: 0.35,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_MULTI_SOURCE_GRAPH_PIPELINE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_MULTI_SOURCE_GRAPH_PIPELINE_ERROR: $topLevelError',
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
        const VGMultiSourceGraphPipelineSmokeReport(
          pass: false,
          status: 'fail',
          marker: VGMultiSourceGraphPipelineSmokeReport.failMarkerConstant,
          proofBoundary: '',
          failureReason: 'invocation_failed',
          details: '',
          formatProbeOk: false,
          topologyRoutedSourcesOk: false,
          track0IngestOk: false,
          track1SyntheticIngestOk: false,
          trackFrameAxisLockstepOk: false,
          jointDispatchGateOk: false,
          referenceMixChecksumOk: false,
          mixedOutputFrameAccountingOk: false,
          twoTrackContributionOk: false,
          seekOk: false,
          jointTailFlushOk: false,
          noProviderUnderrunOk: false,
          noZeroFillOk: false,
          noForwardSkipOk: false,
          noRewindRejectOk: false,
          noSilenceOk: false,
          noRingPushShortfallOk: false,
          zeroNativeSteadyStateAllocationOk: false,
          ownerThreadOk: false,
          lifecycleOk: false,
          canonical: false,
          sampleRate: 0,
          channelCount: 0,
          pcmEncoding: 0,
          commonBudgetFrames: 0,
          framesTruncatedBeyondBudget: 0,
          totalFramesExtracted: 0,
          totalFramesAcceptedTrack0: 0,
          totalFramesAcceptedTrack1: 0,
          totalOutputFramesDrained: 0,
          postSeekFramesAccepted: 0,
          postSeekFramesDrained: 0,
          seekAcceptedFrame: -1,
          track1NonZeroSampleCount: 0,
          mixedChecksumDiffersFromTrack0: false,
          mixedChecksumDiffersFromTrack1: false,
          decoderBenignFormatChangeCount: 0,
          providerUnderrunEventsTrack0: 0,
          providerUnderrunEventsTrack1: 0,
          providerFramesZeroFilledTrack0: 0,
          providerFramesZeroFilledTrack1: 0,
          providerForwardSkipFramesTrack0: 0,
          providerForwardSkipFramesTrack1: 0,
          providerRewindRejectsTrack0: 0,
          providerRewindRejectsTrack1: 0,
          coordinatorSilenceCount: 0,
          nativeAcceptedChecksumHexTrack0: '',
          nativeAcceptedChecksumHexTrack1: '',
          nativeOutputDrainChecksumHex: '',
          kotlinAcceptedChecksumHexTrack0: '',
          kotlinAcceptedChecksumHexTrack1: '',
          kotlinReferenceMixChecksumHex: '',
          maxFramesPerMix: 0,
          sourceAvailableReadFramesTrack0: -1,
          sourceAvailableReadFramesTrack1: -1,
          outputAvailableReadFrames: -1,
          dispatchCount: 0,
          nextDispatchFrame: -1,
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
      'topologyRoutedSourcesOk=${activeReport.topologyRoutedSourcesOk}, '
      'track0IngestOk=${activeReport.track0IngestOk}, '
      'track1SyntheticIngestOk=${activeReport.track1SyntheticIngestOk}, '
      'sampleRate=${activeReport.sampleRate}, '
      'channelCount=${activeReport.channelCount}, '
      'pcmEncoding=${activeReport.pcmEncoding}, '
      'commonBudgetFrames=${activeReport.commonBudgetFrames}, '
      'framesTruncatedBeyondBudget=${activeReport.framesTruncatedBeyondBudget}, '
      'totalFramesExtracted=${activeReport.totalFramesExtracted}, '
      'track1NonZeroSampleCount=${activeReport.track1NonZeroSampleCount}, '
      'decoderBenignFormatChangeCount=${activeReport.decoderBenignFormatChangeCount}',
    );

    // 2. Joint Gating & Contribution group
    print(
      '  [LANE] Joint Gating & Contribution: '
      'jointDispatchGateOk=${activeReport.jointDispatchGateOk}, '
      'twoTrackContributionOk=${activeReport.twoTrackContributionOk}, '
      'mixedChecksumDiffersFromTrack0=${activeReport.mixedChecksumDiffersFromTrack0}, '
      'mixedChecksumDiffersFromTrack1=${activeReport.mixedChecksumDiffersFromTrack1}, '
      'maxFramesPerMix=${activeReport.maxFramesPerMix}, '
      'dispatchCount=${activeReport.dispatchCount}, '
      'nextDispatchFrame=${activeReport.nextDispatchFrame}',
    );

    // 3. Checksum Identity group
    print(
      '  [LANE] Checksum Identity: '
      'kotlinAcceptedChecksumHexTrack0=${activeReport.kotlinAcceptedChecksumHexTrack0}, '
      'nativeAcceptedChecksumHexTrack0=${activeReport.nativeAcceptedChecksumHexTrack0}, '
      'kotlinAcceptedChecksumHexTrack1=${activeReport.kotlinAcceptedChecksumHexTrack1}, '
      'nativeAcceptedChecksumHexTrack1=${activeReport.nativeAcceptedChecksumHexTrack1}, '
      'kotlinReferenceMixChecksumHex=${activeReport.kotlinReferenceMixChecksumHex}, '
      'nativeOutputDrainChecksumHex=${activeReport.nativeOutputDrainChecksumHex}, '
      'referenceMixChecksumOk=${activeReport.referenceMixChecksumOk}, '
      'checksumsMatch=${activeReport.checksumsMatch}',
    );

    // 4. Frame Accounting & Lockstep group
    print(
      '  [LANE] Frame Accounting & Lockstep: '
      'totalFramesAcceptedTrack0=${activeReport.totalFramesAcceptedTrack0}, '
      'totalFramesAcceptedTrack1=${activeReport.totalFramesAcceptedTrack1}, '
      'totalOutputFramesDrained=${activeReport.totalOutputFramesDrained}, '
      'postSeekFramesAccepted=${activeReport.postSeekFramesAccepted}, '
      'postSeekFramesDrained=${activeReport.postSeekFramesDrained}, '
      'trackFrameAxisLockstepOk=${activeReport.trackFrameAxisLockstepOk}, '
      'mixedOutputFrameAccountingOk=${activeReport.mixedOutputFrameAccountingOk}',
    );

    // 5. Seek & Joint Tail Flush group
    print(
      '  [LANE] Seek & Joint Tail Flush: '
      'seekOk=${activeReport.seekOk}, '
      'jointTailFlushOk=${activeReport.jointTailFlushOk}, '
      'seekAcceptedFrame=${activeReport.seekAcceptedFrame}',
    );

    // 6. Transport Health & Residuals group
    print(
      '  [LANE] Transport Health & Residuals: '
      'noProviderUnderrunOk=${activeReport.noProviderUnderrunOk}, '
      'noZeroFillOk=${activeReport.noZeroFillOk}, '
      'noForwardSkipOk=${activeReport.noForwardSkipOk}, '
      'noRewindRejectOk=${activeReport.noRewindRejectOk}, '
      'noSilenceOk=${activeReport.noSilenceOk}, '
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
      'sourceAvailableReadFramesTrack0=${activeReport.sourceAvailableReadFramesTrack0}, '
      'sourceAvailableReadFramesTrack1=${activeReport.sourceAvailableReadFramesTrack1}, '
      'outputAvailableReadFrames=${activeReport.outputAvailableReadFrames}',
    );

    // 7. Architecture, Steady-State & Lifecycle group
    print(
      '  [LANE] Architecture, Steady-State & Lifecycle: '
      'zeroNativeSteadyStateAllocationOk=${activeReport.zeroNativeSteadyStateAllocationOk}, '
      'ownerThreadOk=${activeReport.ownerThreadOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'canonical=${activeReport.canonical}, '
      'nativeLastStatus=${activeReport.nativeLastStatus}',
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
        activeReport.sourceAvailableReadFramesTrack0 == 0 &&
        activeReport.sourceAvailableReadFramesTrack1 == 0 &&
        activeReport.outputAvailableReadFrames == 0 &&
        lastErrorOk;

    print(
      pass
          ? 'ANDROID_DAG_PHASE4_MULTI_SOURCE_GRAPH_PIPELINE_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_MULTI_SOURCE_GRAPH_PIPELINE_SMOKE_FAIL',
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidMultiSourceAudioGraphPipelinePhysicalSmokeHarness',
      'slice': 'P4-AUDIO-MULTI-SOURCE-GRAPH-PIPELINE',
      'target': VGMultiSourceGraphPipelineSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_MULTI_SOURCE_GRAPH_PIPELINE_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_MULTI_SOURCE_GRAPH_PIPELINE_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_MULTI_SOURCE_GRAPH_PIPELINE_PHYSICAL_SMOKE_FAIL',
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
