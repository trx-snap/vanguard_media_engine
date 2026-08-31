// android_real_decoder_pipeline_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice H2: Android True-DAG Phase 4
// real MediaExtractor/MediaCodec decoder closed-loop native audio graph pipeline diagnostic proof physical harness.
//
// Proof lanes:
//   - Codec & Format group: formatProbeOk, decoderBenignFormatChangeObserved, decoderEosReachedOk, sampleRate, channelCount, pcmEncoding.
//   - Ingest & Transport Pressure group: sourcePartialWriteObserved, sourceRingFullObserved, outputBackpressureObserved.
//   - Checksum Identity group: kotlinAcceptedChecksumHex, nativeAcceptedChecksumHex, nativeOutputDrainChecksumHex, checksumIdentityOk, checksumsMatch.
//   - Frame Accounting group: totalFramesExtracted, totalFramesAccepted, totalOutputFramesDrained, postSeekFramesAccepted, postSeekFramesDrained, frameAccountingOk.
//   - Seek & Tail Flush group: seekOk, tailFlushOk, finalSeekAckClearOk.
//   - Integrity & Health group: noUnderrunOk, noSilenceOk, noRingPushShortfallOk, noForwardSkipOk, noRewindRejectOk, finalNotTerminalOk, providerUnderrunEvents, providerFramesZeroFilled, providerForwardSkipFrames, providerRewindRejects, coordinatorSilenceCount.
//   - Architecture & Concurrency group: zeroNativeSteadyStateAllocationOk, ownerThreadOk, lifecycleOk, canonical, dispatchCount, maxFramesPerMix.
//   - Proof-Boundary & Summary group: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   kotlin_owned_real_decoder_step_driven_closed_loop_native_audio_graph_pipeline_session_proof_only_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_native_frame_axis_is_accepted_frame_count_not_media_pts_seek_reanchors_at_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_pre_seek_writer_eos_tail_flush_then_seek_clears_eos_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audio_track_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_diagnostic_graph_topology_only_no_production_source_node_wiring_no_source_node_pcm_ingest_topology_anchor_only_single_routed_track_unit_gain_only_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidRealDecoderPipelinePhysicalSmokeApp());
}

class AndroidRealDecoderPipelinePhysicalSmokeApp extends StatefulWidget {
  const AndroidRealDecoderPipelinePhysicalSmokeApp({super.key});

  @override
  State<AndroidRealDecoderPipelinePhysicalSmokeApp> createState() =>
      _AndroidRealDecoderPipelinePhysicalSmokeAppState();
}

class _AndroidRealDecoderPipelinePhysicalSmokeAppState
    extends State<AndroidRealDecoderPipelinePhysicalSmokeApp> {
  String _status = 'Running Android DAG Phase 4 Real Decoder Pipeline smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_REAL_DECODER_PIPELINE_SMOKE_START');

    VGRealDecoderPipelineSmokeReport? report;
    String? topLevelError;
    File? tempSourceFile;

    try {
      final clipBData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      tempSourceFile = File(
        '${tempDir.path}/p4_real_decoder_pipeline_source_$timestamp.mov',
      );

      await tempSourceFile.writeAsBytes(
        clipBData.buffer.asUint8List(
          clipBData.offsetInBytes,
          clipBData.lengthInBytes,
        ),
        flush: true,
      );

      report =
          await VGRealDecoderPipelineSmokeReport.runAndroidDagPhase4RealDecoderPipelineSmoke(
            sourcePath: tempSourceFile.path,
            durationSec: 1.0,
            seekTargetSec: 0.35,
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print('ANDROID_DAG_PHASE4_REAL_DECODER_PIPELINE_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('ANDROID_DAG_PHASE4_REAL_DECODER_PIPELINE_ERROR: $topLevelError');
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
        const VGRealDecoderPipelineSmokeReport(
          pass: false,
          status: 'fail',
          marker: VGRealDecoderPipelineSmokeReport.failMarkerConstant,
          proofBoundary: '',
          failureReason: 'invocation_failed',
          details: '',
          formatProbeOk: false,
          decoderBenignFormatChangeObserved: false,
          decoderEosReachedOk: false,
          sourcePartialWriteObserved: false,
          sourceRingFullObserved: false,
          outputBackpressureObserved: false,
          checksumIdentityOk: false,
          frameAccountingOk: false,
          seekOk: false,
          tailFlushOk: false,
          noUnderrunOk: false,
          noSilenceOk: false,
          noRingPushShortfallOk: false,
          noForwardSkipOk: false,
          noRewindRejectOk: false,
          finalNotTerminalOk: false,
          finalSeekAckClearOk: false,
          zeroNativeSteadyStateAllocationOk: false,
          ownerThreadOk: false,
          lifecycleOk: false,
          canonical: false,
          sampleRate: 0,
          channelCount: 0,
          pcmEncoding: 0,
          totalFramesExtracted: 0,
          totalFramesAccepted: 0,
          totalOutputFramesDrained: 0,
          postSeekFramesAccepted: 0,
          postSeekFramesDrained: 0,
          decoderBenignFormatChangeCount: 0,
          providerUnderrunEvents: 0,
          providerFramesZeroFilled: 0,
          providerForwardSkipFrames: 0,
          providerRewindRejects: 0,
          coordinatorSilenceCount: 0,
          nativeAcceptedChecksumHex: '',
          nativeOutputDrainChecksumHex: '',
          kotlinAcceptedChecksumHex: '',
          maxFramesPerMix: 0,
          sourceAvailableReadFrames: -1,
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

    // 1. Codec & Format group
    print(
      '  [LANE] Codec & Format: '
      'formatProbeOk=${activeReport.formatProbeOk}, '
      'decoderBenignFormatChangeObserved=${activeReport.decoderBenignFormatChangeObserved}, '
      'decoderEosReachedOk=${activeReport.decoderEosReachedOk}, '
      'sampleRate=${activeReport.sampleRate}, '
      'channelCount=${activeReport.channelCount}, '
      'pcmEncoding=${activeReport.pcmEncoding}',
    );

    // 2. Ingest & Transport Pressure group
    print(
      '  [LANE] Ingest & Transport Pressure: '
      'sourcePartialWriteObserved=${activeReport.sourcePartialWriteObserved}, '
      'sourceRingFullObserved=${activeReport.sourceRingFullObserved}, '
      'outputBackpressureObserved=${activeReport.outputBackpressureObserved}',
    );

    // 3. Checksum Identity group
    print(
      '  [LANE] Checksum Identity: '
      'kotlinAcceptedChecksumHex=${activeReport.kotlinAcceptedChecksumHex}, '
      'nativeAcceptedChecksumHex=${activeReport.nativeAcceptedChecksumHex}, '
      'nativeOutputDrainChecksumHex=${activeReport.nativeOutputDrainChecksumHex}, '
      'checksumIdentityOk=${activeReport.checksumIdentityOk}, '
      'checksumsMatch=${activeReport.checksumsMatch}',
    );

    // 4. Frame Accounting group
    print(
      '  [LANE] Frame Accounting: '
      'totalFramesExtracted=${activeReport.totalFramesExtracted}, '
      'totalFramesAccepted=${activeReport.totalFramesAccepted}, '
      'totalOutputFramesDrained=${activeReport.totalOutputFramesDrained}, '
      'postSeekFramesAccepted=${activeReport.postSeekFramesAccepted}, '
      'postSeekFramesDrained=${activeReport.postSeekFramesDrained}, '
      'frameAccountingOk=${activeReport.frameAccountingOk}',
    );

    // 5. Seek & Tail Flush group
    print(
      '  [LANE] Seek & Tail Flush: '
      'seekOk=${activeReport.seekOk}, '
      'tailFlushOk=${activeReport.tailFlushOk}, '
      'finalSeekAckClearOk=${activeReport.finalSeekAckClearOk}',
    );

    // 6. Integrity & Health group
    print(
      '  [LANE] Integrity & Health: '
      'noUnderrunOk=${activeReport.noUnderrunOk}, '
      'noSilenceOk=${activeReport.noSilenceOk}, '
      'noRingPushShortfallOk=${activeReport.noRingPushShortfallOk}, '
      'noForwardSkipOk=${activeReport.noForwardSkipOk}, '
      'noRewindRejectOk=${activeReport.noRewindRejectOk}, '
      'finalNotTerminalOk=${activeReport.finalNotTerminalOk}, '
      'providerUnderrunEvents=${activeReport.providerUnderrunEvents}, '
      'providerFramesZeroFilled=${activeReport.providerFramesZeroFilled}, '
      'providerForwardSkipFrames=${activeReport.providerForwardSkipFrames}, '
      'providerRewindRejects=${activeReport.providerRewindRejects}, '
      'coordinatorSilenceCount=${activeReport.coordinatorSilenceCount}',
    );

    // 7. Architecture & Concurrency group
    print(
      '  [LANE] Architecture & Concurrency: '
      'zeroNativeSteadyStateAllocationOk=${activeReport.zeroNativeSteadyStateAllocationOk}, '
      'ownerThreadOk=${activeReport.ownerThreadOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'canonical=${activeReport.canonical}, '
      'dispatchCount=${activeReport.dispatchCount}, '
      'maxFramesPerMix=${activeReport.maxFramesPerMix}',
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
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidRealDecoderPipelinePhysicalSmokeHarness',
      'slice': 'P4-AUDIO-GRAPH-TRANSPORT-CLOCK',
      'target': VGRealDecoderPipelineSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_REAL_DECODER_PIPELINE_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_REAL_DECODER_PIPELINE_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_REAL_DECODER_PIPELINE_PHYSICAL_SMOKE_FAIL',
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
