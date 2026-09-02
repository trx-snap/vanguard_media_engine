// android_realtime_playback_ingest_seam_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-EXTERNAL-INGEST-SEAM (Y5a): Android True-DAG Phase 4
// realtime playback external PCM16 ingest seam diagnostic physical harness.
//
// Proof lanes:
//   - Ingest Identity: ingestIdentityOk, identityPrerollFrames, identityIngestCalls, identityAcceptedFrames, identityDrainCalls, identitySampleMismatches, identityPushedChecksumHex, identityDrainedChecksumHex, identityReferenceChecksumHex.
//   - Seek Re-anchor: seekReanchorOk, seekFirstIngestOk, seekAccepted, seekStaleAnchorRejected, seekStaleStatus, seekStaleNextWriteFrame, seekReanchorNext, seekDrainedFrames, seekReferenceChecksumHex, seekDrainedChecksumHex, seekSampleMismatches.
//   - Backpressure & Recovery: backpressureOk, backpressurePartialStatus, backpressurePartialAccepted, backpressurePartialFreeFrames, backpressureFullStatus, backpressureFullAccepted, backpressureRecoveryAccepted, backpressureRecoveryStatus.
//   - Direct-Native Guards: directNativeGuardsOk, guardWrongOwnerStatus, guardFormatMismatchStatus, guardSyntheticTrackStatus, guardHeapBufferStatus, guardOwnerIngestStatus, guardOwnerNextWriteFrame, nativeFirstDestroyStatus, nativeFirstDestroyWorkerJoined, nativeSecondDestroyStatus.
//   - Nonterminal Underrun: underrunNonterminalOk, underrunPrerollOk, underrunStarvedState, underrunStarvedUnderrunCount, underrunStarvedPositionFrame, underrunStarvedPushedFrames, underrunFinalUnderrunCount, underrunFinalDrainedChecksumHex, underrunSampleMismatches.
//   - Stale Generation: staleGenerationOk, staleGenerationPinned, staleCurrentGeneration, staleResultReason, stalePinnedIngestStatus, stalePinnedOnOwnerThread.
//   - Lifecycle & Dispose: lifecycleDisposeOk, disposeState, disposeIngestReason, disposePostIngestPosted, proofBoundaryOk, canonical.
//
// Target / proof boundary:
//   realtime_playback_external_ingest_seam_diagnostic_only_kotlin_synthetic_pcm_to_y_series_native_source_ring_owner_thread_ingest_generation_pinned_no_mediacodec_no_mediaextractor_no_decoder_lifecycle_no_presentation_clock_no_av_sync_no_audio_quality_claim_no_latency_claim_no_fleet_claim_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_src_audio_primitive_changes

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidRealtimePlaybackIngestSeamPhysicalSmokeApp());
}

class AndroidRealtimePlaybackIngestSeamPhysicalSmokeApp extends StatefulWidget {
  const AndroidRealtimePlaybackIngestSeamPhysicalSmokeApp({super.key});

  @override
  State<AndroidRealtimePlaybackIngestSeamPhysicalSmokeApp> createState() =>
      _AndroidRealtimePlaybackIngestSeamPhysicalSmokeAppState();
}

class _AndroidRealtimePlaybackIngestSeamPhysicalSmokeAppState
    extends State<AndroidRealtimePlaybackIngestSeamPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Realtime Playback External Ingest Seam smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(VGRealtimePlaybackIngestSeamSmokeReport.startMarkerConstant);

    VGRealtimePlaybackIngestSeamSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGRealtimePlaybackIngestSeamSmokeReport.runRealtimePlaybackIngestSeamSmoke(
            timeout: const Duration(seconds: 30),
          );
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INGEST_SEAM_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INGEST_SEAM_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ?? VGRealtimePlaybackIngestSeamSmokeReport.fromMap(null);

    // 1. Ingest Identity
    print(
      '  [LANE] Ingest Identity: '
      'ingestIdentityOk=${activeReport.ingestIdentityOk}, '
      'identityPrerollFrames=${activeReport.metrics['identityPrerollFrames']}, '
      'identityIngestCalls=${activeReport.metrics['identityIngestCalls']}, '
      'identityAcceptedFrames=${activeReport.metrics['identityAcceptedFrames']}, '
      'identityDrainCalls=${activeReport.metrics['identityDrainCalls']}, '
      'identitySampleMismatches=${activeReport.metrics['identitySampleMismatches']}, '
      'identityPushedChecksumHex=${activeReport.metrics['identityPushedChecksumHex']}, '
      'identityDrainedChecksumHex=${activeReport.metrics['identityDrainedChecksumHex']}, '
      'identityReferenceChecksumHex=${activeReport.metrics['identityReferenceChecksumHex']}',
    );

    // 2. Seek Re-anchor
    print(
      '  [LANE] Seek Re-anchor: '
      'seekReanchorOk=${activeReport.seekReanchorOk}, '
      'seekFirstIngestOk=${activeReport.metrics['seekFirstIngestOk']}, '
      'seekAccepted=${activeReport.metrics['seekAccepted']}, '
      'seekStaleAnchorRejected=${activeReport.metrics['seekStaleAnchorRejected']}, '
      'seekStaleStatus=${activeReport.metrics['seekStaleStatus']}, '
      'seekStaleNextWriteFrame=${activeReport.metrics['seekStaleNextWriteFrame']}, '
      'seekReanchorNext=${activeReport.metrics['seekReanchorNext']}, '
      'seekDrainedFrames=${activeReport.metrics['seekDrainedFrames']}, '
      'seekReferenceChecksumHex=${activeReport.metrics['seekReferenceChecksumHex']}, '
      'seekDrainedChecksumHex=${activeReport.metrics['seekDrainedChecksumHex']}, '
      'seekSampleMismatches=${activeReport.metrics['seekSampleMismatches']}',
    );

    // 3. Backpressure & Recovery
    print(
      '  [LANE] Backpressure & Recovery: '
      'backpressureOk=${activeReport.backpressureOk}, '
      'backpressurePartialStatus=${activeReport.metrics['backpressurePartialStatus']}, '
      'backpressurePartialAccepted=${activeReport.metrics['backpressurePartialAccepted']}, '
      'backpressurePartialFreeFrames=${activeReport.metrics['backpressurePartialFreeFrames']}, '
      'backpressureFullStatus=${activeReport.metrics['backpressureFullStatus']}, '
      'backpressureFullAccepted=${activeReport.metrics['backpressureFullAccepted']}, '
      'backpressureRecoveryAccepted=${activeReport.metrics['backpressureRecoveryAccepted']}, '
      'backpressureRecoveryStatus=${activeReport.metrics['backpressureRecoveryStatus']}',
    );

    // 4. Direct-Native Guards
    print(
      '  [LANE] Direct-Native Guards: '
      'directNativeGuardsOk=${activeReport.directNativeGuardsOk}, '
      'guardWrongOwnerStatus=${activeReport.metrics['guardWrongOwnerStatus']}, '
      'guardFormatMismatchStatus=${activeReport.metrics['guardFormatMismatchStatus']}, '
      'guardSyntheticTrackStatus=${activeReport.metrics['guardSyntheticTrackStatus']}, '
      'guardHeapBufferStatus=${activeReport.metrics['guardHeapBufferStatus']}, '
      'guardOwnerIngestStatus=${activeReport.metrics['guardOwnerIngestStatus']}, '
      'guardOwnerNextWriteFrame=${activeReport.metrics['guardOwnerNextWriteFrame']}, '
      'nativeFirstDestroyStatus=${activeReport.metrics['nativeFirstDestroyStatus']}, '
      'nativeFirstDestroyWorkerJoined=${activeReport.metrics['nativeFirstDestroyWorkerJoined']}, '
      'nativeSecondDestroyStatus=${activeReport.metrics['nativeSecondDestroyStatus']}',
    );

    // 5. Nonterminal Underrun
    print(
      '  [LANE] Nonterminal Underrun: '
      'underrunNonterminalOk=${activeReport.underrunNonterminalOk}, '
      'underrunPrerollOk=${activeReport.metrics['underrunPrerollOk']}, '
      'underrunStarvedState=${activeReport.metrics['underrunStarvedState']}, '
      'underrunStarvedUnderrunCount=${activeReport.metrics['underrunStarvedUnderrunCount']}, '
      'underrunStarvedPositionFrame=${activeReport.metrics['underrunStarvedPositionFrame']}, '
      'underrunStarvedPushedFrames=${activeReport.metrics['underrunStarvedPushedFrames']}, '
      'underrunFinalUnderrunCount=${activeReport.metrics['underrunFinalUnderrunCount']}, '
      'underrunFinalDrainedChecksumHex=${activeReport.metrics['underrunFinalDrainedChecksumHex']}, '
      'underrunSampleMismatches=${activeReport.metrics['underrunSampleMismatches']}',
    );

    // 6. Stale Generation
    print(
      '  [LANE] Stale Generation: '
      'staleGenerationOk=${activeReport.staleGenerationOk}, '
      'staleGenerationPinned=${activeReport.metrics['staleGenerationPinned']}, '
      'staleCurrentGeneration=${activeReport.metrics['staleCurrentGeneration']}, '
      'staleResultReason=${activeReport.metrics['staleResultReason']}, '
      'stalePinnedIngestStatus=${activeReport.metrics['stalePinnedIngestStatus']}, '
      'stalePinnedOnOwnerThread=${activeReport.metrics['stalePinnedOnOwnerThread']}',
    );

    // 7. Lifecycle & Aggregates
    print(
      '  [LANE] Lifecycle & Aggregates: '
      'lifecycleDisposeOk=${activeReport.lifecycleDisposeOk}, '
      'disposeState=${activeReport.metrics['disposeState']}, '
      'disposeIngestReason=${activeReport.metrics['disposeIngestReason']}, '
      'disposePostIngestPosted=${activeReport.metrics['disposePostIngestPosted']}, '
      'proofBoundaryOk=${activeReport.proofBoundaryOk}, '
      'canonical=${activeReport.canonical}',
    );

    // 8. Proof Boundary & Verification
    print(
      '  [LANE] Proof Boundary & Verification: '
      'hasCanonicalProofBoundary=${activeReport.hasCanonicalProofBoundary}, '
      'hasPassMarker=${activeReport.hasPassMarker}, '
      'isVerifiedPass=${activeReport.isVerifiedPass}, '
      'failureReason=${activeReport.failureReason}, '
      'lastError=${activeReport.lastError}',
    );

    final lastErrorOk =
        activeReport.lastError.isEmpty ||
        activeReport.lastError == 'none' ||
        activeReport.lastError == 'null';

    final pass =
        (topLevelError == null) &&
        activeReport.pass &&
        activeReport.isVerifiedPass &&
        activeReport.hasCanonicalProofBoundary &&
        activeReport.hasPassMarker &&
        lastErrorOk;

    print(
      pass
          ? VGRealtimePlaybackIngestSeamSmokeReport.passMarkerConstant
          : VGRealtimePlaybackIngestSeamSmokeReport.failMarkerConstant,
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidRealtimePlaybackIngestSeamPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-EXTERNAL-INGEST-SEAM',
      'target': VGRealtimePlaybackIngestSeamSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      '${VGRealtimePlaybackIngestSeamSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INGEST_SEAM_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INGEST_SEAM_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (isVerifiedPass=true, hasCanonicalProofBoundary=true)'
            : 'FAIL: lastError=${activeReport.lastError}, failureReason=${activeReport.failureReason}, error=$topLevelError';
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
