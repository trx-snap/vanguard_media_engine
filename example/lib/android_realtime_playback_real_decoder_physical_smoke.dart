// android_realtime_playback_real_decoder_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER (Y5b): Android True-DAG Phase 4
// realtime playback real MediaExtractor/MediaCodec PCM16 decode to external ingest seam diagnostic physical harness.
//
// Proof lanes:
//   - Format Probe: formatProbeOk, sourceMime, sourceDurationUs, sampleRate, channelCount, pcmEncoding, declaredFrameCount.
//   - Real Decoder Ingest: realDecoderIngestOk, playPrerollFrames, playPushedFrames, playDrainedFrames, playAcceptedFrames, playDecodedFramesAccepted, playKotlinChecksumHex, playPushedChecksumHex, playDrainedChecksumHex, playCodecChunks.
//   - Seek Re-anchor: seekReanchorOk, seekTargetFrame, preSeekFrames, seekPositionFrame, seekPushedFrames, seekDrainedFrames, seekPostSeekAcceptedFrames, seekKotlinChecksumHex, seekPushedChecksumHex, seekDrainedChecksumHex.
//   - Backpressure & Recovery: backpressureRecoveryOk, playObservedPartialWrite, playObservedRingFull, playRemainderRetryAccepted, playBackpressureCount.
//   - Underrun Tolerance: underrunToleranceOk, playStarvationObserved, playStarvedPositionFrame, playStarvedUnderrunCount, playFinalUnderrunCount.
//   - EOS Accounting: eosAccountingOk, playPaddedFrames, playTruncatedFrames, seekPaddedFrames, seekTruncatedFrames.
//   - Stale Generation: staleGenerationRejectedOk, seekStaleGeneration, seekNewGeneration, seekStaleReason, seekStaleReplyNull.
//   - Lifecycle & Dispose: lifecycleDisposeOk, disposeState, disposeIngestReason, disposePostIngestPosted, disposeMediaReleaseClean.
//   - Proof Boundary & Canonical: proofBoundaryOk, canonical.
//
// Target / proof boundary:
//   realtime_playback_real_decoder_diagnostic_only_mediacodec_mediaextractor_streaming_pcm16_to_y5a_external_ingest_seam_generation_pinned_owner_thread_handoff_no_presentation_clock_no_av_sync_no_resample_no_downmix_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_native_cpp_changes

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidRealtimePlaybackRealDecoderPhysicalSmokeApp());
}

class AndroidRealtimePlaybackRealDecoderPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRealtimePlaybackRealDecoderPhysicalSmokeApp({super.key});

  @override
  State<AndroidRealtimePlaybackRealDecoderPhysicalSmokeApp> createState() =>
      _AndroidRealtimePlaybackRealDecoderPhysicalSmokeAppState();
}

class _AndroidRealtimePlaybackRealDecoderPhysicalSmokeAppState
    extends State<AndroidRealtimePlaybackRealDecoderPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Realtime Playback Real Decoder smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(VGRealtimePlaybackRealDecoderSmokeReport.startMarkerConstant);

    VGRealtimePlaybackRealDecoderSmokeReport? report;
    String? topLevelError;

    final candidates = <String>[
      'assets/manual_test_clips/clip_B.mov',
      'assets/manual_test_clips/clip_A.mov',
      'assets/manual_test_clips/clip_A.mp3',
    ];

    for (final candidate in candidates) {
      File? tempSourceFile;
      try {
        ByteData assetData;
        try {
          assetData = await rootBundle.load(candidate);
        } catch (loadErr) {
          print('  [CANDIDATE_SKIP] Could not load $candidate: $loadErr');
          continue;
        }

        final ext = candidate.endsWith('.mp3') ? 'mp3' : 'mov';
        final tempDir = Directory.systemTemp;
        final timestamp = DateTime.now().microsecondsSinceEpoch;
        tempSourceFile = File(
          '${tempDir.path}/p4_realtime_playback_real_decoder_source_$timestamp.$ext',
        );

        await tempSourceFile.writeAsBytes(
          assetData.buffer.asUint8List(
            assetData.offsetInBytes,
            assetData.lengthInBytes,
          ),
          flush: true,
        );

        print('  [SETUP] Extracted asset $candidate to ${tempSourceFile.path}');

        final candidateReport =
            await VGRealtimePlaybackRealDecoderSmokeReport.runRealtimePlaybackRealDecoderSmoke(
              sourcePath: tempSourceFile.path,
              maxDurationSec: 1.0,
              seekTargetSec: 0.35,
              maxFramesPerMix: 256,
              deadlineMs: 30000,
              timeout: const Duration(seconds: 40),
            );

        report = candidateReport;
        topLevelError = null;

        if (candidateReport.isVerifiedPass) {
          print('  [CANDIDATE_PASS] Verified pass achieved with $candidate');
          break;
        } else {
          print(
            '  [CANDIDATE_FAIL] Candidate $candidate failed: status=${candidateReport.status}, reason=${candidateReport.failureReason}. Trying next candidate...',
          );
        }
      } on TimeoutException catch (te) {
        topLevelError = 'timeout: $te';
        print(
          'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_REAL_DECODER_ERROR ($candidate): $topLevelError',
        );
      } catch (e, st) {
        topLevelError = '$e\n$st';
        print(
          'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_REAL_DECODER_ERROR ($candidate): $topLevelError',
        );
      } finally {
        if (tempSourceFile != null) {
          try {
            if (await tempSourceFile.exists()) {
              await tempSourceFile.delete();
              print('  [CLEANUP] Deleted temp file ${tempSourceFile.path}');
            }
          } catch (cleanupErr) {
            print('  [CLEANUP_WARN] Failed to delete temp file: $cleanupErr');
          }
        }
      }
    }

    final activeReport =
        report ?? VGRealtimePlaybackRealDecoderSmokeReport.fromMap(null);

    // 1. Format Probe
    print(
      '  [LANE] Format Probe: '
      'formatProbeOk=${activeReport.formatProbeOk}, '
      'sourceMime=${activeReport.metrics['sourceMime']}, '
      'sourceDurationUs=${activeReport.metrics['sourceDurationUs']}, '
      'sampleRate=${activeReport.metrics['sampleRate']}, '
      'channelCount=${activeReport.metrics['channelCount']}, '
      'pcmEncoding=${activeReport.metrics['pcmEncoding']}, '
      'declaredFrameCount=${activeReport.metrics['declaredFrameCount']}',
    );

    // 2. Real Decoder Ingest
    print(
      '  [LANE] Real Decoder Ingest: '
      'realDecoderIngestOk=${activeReport.realDecoderIngestOk}, '
      'playPrerollFrames=${activeReport.metrics['playPrerollFrames']}, '
      'playPushedFrames=${activeReport.metrics['playPushedFrames']}, '
      'playDrainedFrames=${activeReport.metrics['playDrainedFrames']}, '
      'playAcceptedFrames=${activeReport.metrics['playAcceptedFrames']}, '
      'playDecodedFramesAccepted=${activeReport.metrics['playDecodedFramesAccepted']}, '
      'playKotlinChecksumHex=${activeReport.metrics['playKotlinChecksumHex']}, '
      'playPushedChecksumHex=${activeReport.metrics['playPushedChecksumHex']}, '
      'playDrainedChecksumHex=${activeReport.metrics['playDrainedChecksumHex']}, '
      'playCodecChunks=${activeReport.metrics['playCodecChunks']}',
    );

    // 3. Seek Re-anchor
    print(
      '  [LANE] Seek Re-anchor: '
      'seekReanchorOk=${activeReport.seekReanchorOk}, '
      'seekTargetFrame=${activeReport.metrics['seekTargetFrame']}, '
      'preSeekFrames=${activeReport.metrics['preSeekFrames']}, '
      'seekPositionFrame=${activeReport.metrics['seekPositionFrame']}, '
      'seekPushedFrames=${activeReport.metrics['seekPushedFrames']}, '
      'seekDrainedFrames=${activeReport.metrics['seekDrainedFrames']}, '
      'seekPostSeekAcceptedFrames=${activeReport.metrics['seekPostSeekAcceptedFrames']}, '
      'seekKotlinChecksumHex=${activeReport.metrics['seekKotlinChecksumHex']}, '
      'seekPushedChecksumHex=${activeReport.metrics['seekPushedChecksumHex']}, '
      'seekDrainedChecksumHex=${activeReport.metrics['seekDrainedChecksumHex']}',
    );

    // 4. Backpressure & Recovery
    print(
      '  [LANE] Backpressure & Recovery: '
      'backpressureRecoveryOk=${activeReport.backpressureRecoveryOk}, '
      'playObservedPartialWrite=${activeReport.metrics['playObservedPartialWrite']}, '
      'playObservedRingFull=${activeReport.metrics['playObservedRingFull']}, '
      'playRemainderRetryAccepted=${activeReport.metrics['playRemainderRetryAccepted']}, '
      'playBackpressureCount=${activeReport.metrics['playBackpressureCount']}',
    );

    // 5. Underrun Tolerance
    print(
      '  [LANE] Underrun Tolerance: '
      'underrunToleranceOk=${activeReport.underrunToleranceOk}, '
      'playStarvationObserved=${activeReport.metrics['playStarvationObserved']}, '
      'playStarvedPositionFrame=${activeReport.metrics['playStarvedPositionFrame']}, '
      'playStarvedUnderrunCount=${activeReport.metrics['playStarvedUnderrunCount']}, '
      'playFinalUnderrunCount=${activeReport.metrics['playFinalUnderrunCount']}',
    );

    // 6. EOS Accounting
    print(
      '  [LANE] EOS Accounting: '
      'eosAccountingOk=${activeReport.eosAccountingOk}, '
      'playPaddedFrames=${activeReport.metrics['playPaddedFrames']}, '
      'playTruncatedFrames=${activeReport.metrics['playTruncatedFrames']}, '
      'seekPaddedFrames=${activeReport.metrics['seekPaddedFrames']}, '
      'seekTruncatedFrames=${activeReport.metrics['seekTruncatedFrames']}',
    );

    // 7. Stale Generation
    print(
      '  [LANE] Stale Generation: '
      'staleGenerationRejectedOk=${activeReport.staleGenerationRejectedOk}, '
      'seekStaleGeneration=${activeReport.metrics['seekStaleGeneration']}, '
      'seekNewGeneration=${activeReport.metrics['seekNewGeneration']}, '
      'seekStaleReason=${activeReport.metrics['seekStaleReason']}, '
      'seekStaleReplyNull=${activeReport.metrics['seekStaleReplyNull']}',
    );

    // 8. Lifecycle & Aggregates
    print(
      '  [LANE] Lifecycle & Aggregates: '
      'lifecycleDisposeOk=${activeReport.lifecycleDisposeOk}, '
      'disposeState=${activeReport.metrics['disposeState']}, '
      'disposeIngestReason=${activeReport.metrics['disposeIngestReason']}, '
      'disposePostIngestPosted=${activeReport.metrics['disposePostIngestPosted']}, '
      'disposeMediaReleaseClean=${activeReport.metrics['disposeMediaReleaseClean']}, '
      'proofBoundaryOk=${activeReport.proofBoundaryOk}, '
      'canonical=${activeReport.canonical}',
    );

    // 9. Proof Boundary & Verification
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
          ? VGRealtimePlaybackRealDecoderSmokeReport.passMarkerConstant
          : VGRealtimePlaybackRealDecoderSmokeReport.failMarkerConstant,
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidRealtimePlaybackRealDecoderPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER',
      'target': VGRealtimePlaybackRealDecoderSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      '${VGRealtimePlaybackRealDecoderSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_REAL_DECODER_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_REAL_DECODER_PHYSICAL_SMOKE_FAIL',
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
