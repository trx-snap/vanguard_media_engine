// android_node_owned_audio_source_graph_pipeline_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-DECODER-SOURCE-NODE-WIRING: Android True-DAG Phase 4
// node-owned decoded audio source closed-loop native audio graph pipeline physical smoke harness.
//
// Proof lanes:
//   - Route & Node Ownership group: routeDiscoveryOk, nodeOwnsRingOk, routedSourceCount, routedSourceId0, nodeOwnsRing.
//   - Checksum Identity & Frame Accounting group: checksumIdentityOk, frameAccountingOk, checksumsMatch, totalFramesAccepted, totalOutputFramesDrained, kotlinAcceptedChecksumHex, nativeAcceptedChecksumHex, nativeOutputDrainChecksumHex.
//   - Seek, Tail Flush & Underrun Gate group: seekOk, underrunGateOk, tailFlushOk.
//   - Transport Health & Residuals group: noUnderrunOk, noSilenceOk, providerUnderrunEvents, providerFramesZeroFilled, providerForwardSkipFrames, providerRewindRejects, coordinatorSilenceCount, sourceAvailableReadFrames, outputAvailableReadFrames.
//   - Steady-State, Lifecycle & Capacities group: invalidCreateRejectedOk, zeroNativeSteadyStateAllocationOk, lifecycleOk, dispatchCount, schedulerTrackScratchCapacitySamples, schedulerTrackScratchCapacityTracks, sourceRingStorageCapacitySamples, outputRingStorageCapacitySamples.
//   - Proof Boundary & Summary group: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   diagnostic_node_owned_decoded_audio_source_ring_provider_wiring_proof_only_source_node_owns_ring_writer_provider_by_composition_scheduler_auto_discovers_provider_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_no_hybrid_routing_no_production_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_mediacodec_no_mediaextractor_no_cpp_os_decoder_ownership_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_no_audio_focus_no_route_no_dead_object_no_audible_no_speaker_no_latency_no_glitch_claims_no_streaming_no_cache_no_ios_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_destroy_idempotent_any_thread_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_single_routed_track_unit_gain_only_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidNodeOwnedAudioSourceGraphPipelinePhysicalSmokeApp());
}

class AndroidNodeOwnedAudioSourceGraphPipelinePhysicalSmokeApp
    extends StatefulWidget {
  const AndroidNodeOwnedAudioSourceGraphPipelinePhysicalSmokeApp({super.key});

  @override
  State<AndroidNodeOwnedAudioSourceGraphPipelinePhysicalSmokeApp>
  createState() =>
      _AndroidNodeOwnedAudioSourceGraphPipelinePhysicalSmokeAppState();
}

class _AndroidNodeOwnedAudioSourceGraphPipelinePhysicalSmokeAppState
    extends State<AndroidNodeOwnedAudioSourceGraphPipelinePhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Node-Owned Audio Source Graph Pipeline smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AUDIO_DECODER_SOURCE_NODE_WIRING_SMOKE_START');

    VGNodeOwnedAudioSourceGraphPipelineSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGNodeOwnedAudioSourceGraphPipelineSmokeReport.runAndroidNodeOwnedAudioSourceGraphPipelineSmoke(
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_DECODER_SOURCE_NODE_WIRING_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_DECODER_SOURCE_NODE_WIRING_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ??
        const VGNodeOwnedAudioSourceGraphPipelineSmokeReport(
          pass: false,
          status: 'fail',
          marker:
              VGNodeOwnedAudioSourceGraphPipelineSmokeReport.failMarkerConstant,
          proofBoundary: '',
          failureReason: 'invocation_failed',
          details: '',
          invalidCreateRejectedOk: false,
          routeDiscoveryOk: false,
          nodeOwnsRingOk: false,
          checksumIdentityOk: false,
          frameAccountingOk: false,
          seekOk: false,
          underrunGateOk: false,
          tailFlushOk: false,
          noUnderrunOk: false,
          noSilenceOk: false,
          zeroNativeSteadyStateAllocationOk: false,
          lifecycleOk: false,
          routedSourceCount: -1,
          routedSourceId0: '',
          nodeOwnsRing: false,
          totalFramesAccepted: 0,
          totalOutputFramesDrained: 0,
          providerUnderrunEvents: -1,
          providerFramesZeroFilled: -1,
          providerForwardSkipFrames: -1,
          providerRewindRejects: -1,
          coordinatorSilenceCount: -1,
          dispatchCount: 0,
          nativeAcceptedChecksumHex: '',
          nativeOutputDrainChecksumHex: '',
          kotlinAcceptedChecksumHex: '',
          sourceAvailableReadFrames: -1,
          outputAvailableReadFrames: -1,
          schedulerTrackScratchCapacitySamples: -1,
          schedulerTrackScratchCapacityTracks: -1,
          sourceRingStorageCapacitySamples: -1,
          outputRingStorageCapacitySamples: -1,
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

    // 1. Route & Node Ownership group
    print(
      '  [LANE] Route & Node Ownership: '
      'routeDiscoveryOk=${activeReport.routeDiscoveryOk}, '
      'nodeOwnsRingOk=${activeReport.nodeOwnsRingOk}, '
      'routedSourceCount=${activeReport.routedSourceCount}, '
      'routedSourceId0=${activeReport.routedSourceId0}, '
      'nodeOwnsRing=${activeReport.nodeOwnsRing}',
    );

    // 2. Checksum Identity & Frame Accounting group
    print(
      '  [LANE] Checksum Identity & Frame Accounting: '
      'checksumIdentityOk=${activeReport.checksumIdentityOk}, '
      'frameAccountingOk=${activeReport.frameAccountingOk}, '
      'checksumsMatch=${activeReport.checksumsMatch}, '
      'totalFramesAccepted=${activeReport.totalFramesAccepted}, '
      'totalOutputFramesDrained=${activeReport.totalOutputFramesDrained}, '
      'kotlinAcceptedChecksumHex=${activeReport.kotlinAcceptedChecksumHex}, '
      'nativeAcceptedChecksumHex=${activeReport.nativeAcceptedChecksumHex}, '
      'nativeOutputDrainChecksumHex=${activeReport.nativeOutputDrainChecksumHex}',
    );

    // 3. Seek, Tail Flush & Underrun Gate group
    print(
      '  [LANE] Seek, Tail Flush & Underrun Gate: '
      'seekOk=${activeReport.seekOk}, '
      'underrunGateOk=${activeReport.underrunGateOk}, '
      'tailFlushOk=${activeReport.tailFlushOk}',
    );

    // 4. Transport Health & Residuals group
    print(
      '  [LANE] Transport Health & Residuals: '
      'noUnderrunOk=${activeReport.noUnderrunOk}, '
      'noSilenceOk=${activeReport.noSilenceOk}, '
      'providerUnderrunEvents=${activeReport.providerUnderrunEvents}, '
      'providerFramesZeroFilled=${activeReport.providerFramesZeroFilled}, '
      'providerForwardSkipFrames=${activeReport.providerForwardSkipFrames}, '
      'providerRewindRejects=${activeReport.providerRewindRejects}, '
      'coordinatorSilenceCount=${activeReport.coordinatorSilenceCount}, '
      'sourceAvailableReadFrames=${activeReport.sourceAvailableReadFrames}, '
      'outputAvailableReadFrames=${activeReport.outputAvailableReadFrames}',
    );

    // 5. Steady-State, Lifecycle & Capacities group
    print(
      '  [LANE] Steady-State, Lifecycle & Capacities: '
      'invalidCreateRejectedOk=${activeReport.invalidCreateRejectedOk}, '
      'zeroNativeSteadyStateAllocationOk=${activeReport.zeroNativeSteadyStateAllocationOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'dispatchCount=${activeReport.dispatchCount}, '
      'schedulerTrackScratchCapacitySamples=${activeReport.schedulerTrackScratchCapacitySamples}, '
      'schedulerTrackScratchCapacityTracks=${activeReport.schedulerTrackScratchCapacityTracks}, '
      'sourceRingStorageCapacitySamples=${activeReport.sourceRingStorageCapacitySamples}, '
      'outputRingStorageCapacitySamples=${activeReport.outputRingStorageCapacitySamples}',
    );

    // 6. Proof Boundary & Summary group
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
      'unit': 'AndroidNodeOwnedAudioSourceGraphPipelinePhysicalSmokeHarness',
      'slice': 'P4-AUDIO-DECODER-SOURCE-NODE-WIRING',
      'target':
          VGNodeOwnedAudioSourceGraphPipelineSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_AUDIO_DECODER_SOURCE_NODE_WIRING_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIO_DECODER_SOURCE_NODE_WIRING_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIO_DECODER_SOURCE_NODE_WIRING_PHYSICAL_SMOKE_FAIL',
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
