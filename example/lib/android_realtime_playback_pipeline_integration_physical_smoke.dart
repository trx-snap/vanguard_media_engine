// android_realtime_playback_pipeline_integration_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-INTEGRATION-A (Y6a): Android True-DAG Phase 4
// realtime playback pipeline integration diagnostic physical harness.
//
// Proof lanes:
//   - Format Probe: formatProbeOk, sourceMime, sourceDurationUs, sampleRate, channelCount, pcmEncoding, declaredFrameCount.
//   - Pre-Roll: preRollOk, preRollFrames, preRollRingFullObserved, preRollPartialWriteObserved, preRollStatePrepared.
//   - Real Decoder Ingest: realDecoderIngestOk, decoderAcceptedFrames, decoderDecodedFramesAccepted, eosPaddedFrames, eosTruncatedFrames, codecChunks.
//   - AudioTrack & Gain: nonZeroGainSetOk, audioTrackInitOk, gainValue, audioTrackBufferBytes.
//   - Sink Write Accounting: sinkWriteAccountingOk, framesReadFromTransport, framesWrittenToSink, partialWriteCount, zeroWriteCount, drainCalls.
//   - Checksum Identity: checksumIdentityOk, kotlinDecoderChecksumHex, nativePushedChecksumHex, nativeDrainedChecksumHex, kotlinSinkChecksumHex.
//   - Backpressure & Underrun: backpressureObservedOk, ingestRingFullCount, ingestPartialWriteCount, nativeBackpressureCount, underrunNonterminalOk, nativeUnderrunCount.
//   - EOS & Playback Head: eosAccountingOk, playbackHeadAdvancedOk, playbackHeadFinal, playbackHeadCaughtUp.
//   - Transport & Thread Ownership: transportCompletedOk, threadOwnershipOk, ingestCallbacksOnOwner, ingestCallbacksOffOwner, listenerCallbacksOnOwner, listenerCallbacksOffOwner.
//   - Cancellation & Lifecycle: cancellationOk, lifecycleDisposeOk, mediaReleaseClean, mediaReleaseCount, audioTrackReleaseCount, transportDisposeCalls.
//   - Proof Boundary & Canonical: proofBoundaryOk, canonical.
//
// Target / proof boundary:
//   realtime_playback_pipeline_integration_a_diagnostic_only_real_mediacodec_mediaextractor_streaming_pcm16_to_y5a_external_ingest_seam_native_dag_transport_to_nonzero_gain_audiotrack_sink_base_gain_0_5_single_track_forward_playthrough_no_seek_no_pause_resume_no_interactive_controls_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_no_latency_drift_loudness_snr_claim_no_resample_no_downmix_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_native_cpp_changes

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidRealtimePlaybackPipelineIntegrationPhysicalSmokeApp());
}

class AndroidRealtimePlaybackPipelineIntegrationPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRealtimePlaybackPipelineIntegrationPhysicalSmokeApp({super.key});

  @override
  State<AndroidRealtimePlaybackPipelineIntegrationPhysicalSmokeApp>
  createState() =>
      _AndroidRealtimePlaybackPipelineIntegrationPhysicalSmokeAppState();
}

class _AndroidRealtimePlaybackPipelineIntegrationPhysicalSmokeAppState
    extends State<AndroidRealtimePlaybackPipelineIntegrationPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Realtime Playback Pipeline Integration smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(VGRealtimePlaybackPipelineIntegrationSmokeReport.startMarkerConstant);

    VGRealtimePlaybackPipelineIntegrationSmokeReport? report;
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
          '${tempDir.path}/p4_realtime_playback_pipeline_integration_source_$timestamp.$ext',
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
            await VGRealtimePlaybackPipelineIntegrationSmokeReport.runRealtimePlaybackPipelineIntegrationSmoke(
              sourcePath: tempSourceFile.path,
              maxDurationSec: 3.0,
              maxFramesPerMix: 256,
              baseVolume: 0.5,
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
          'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_ERROR ($candidate): $topLevelError',
        );
      } catch (e, st) {
        topLevelError = '$e\n$st';
        print(
          'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_ERROR ($candidate): $topLevelError',
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
        report ??
        VGRealtimePlaybackPipelineIntegrationSmokeReport.fromMap(null);

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

    // 2. Pre-Roll
    print(
      '  [LANE] Pre-Roll: '
      'preRollOk=${activeReport.preRollOk}, '
      'preRollFrames=${activeReport.metrics['preRollFrames']}, '
      'preRollRingFullObserved=${activeReport.metrics['preRollRingFullObserved']}, '
      'preRollPartialWriteObserved=${activeReport.metrics['preRollPartialWriteObserved']}, '
      'preRollStatePrepared=${activeReport.metrics['preRollStatePrepared']}',
    );

    // 3. Real Decoder Ingest
    print(
      '  [LANE] Real Decoder Ingest: '
      'realDecoderIngestOk=${activeReport.realDecoderIngestOk}, '
      'decoderAcceptedFrames=${activeReport.metrics['decoderAcceptedFrames']}, '
      'decoderDecodedFramesAccepted=${activeReport.metrics['decoderDecodedFramesAccepted']}, '
      'eosPaddedFrames=${activeReport.metrics['eosPaddedFrames']}, '
      'eosTruncatedFrames=${activeReport.metrics['eosTruncatedFrames']}, '
      'codecChunks=${activeReport.metrics['codecChunks']}',
    );

    // 4. AudioTrack & Gain
    print(
      '  [LANE] AudioTrack & Gain: '
      'audioTrackInitOk=${activeReport.audioTrackInitOk}, '
      'nonZeroGainSetOk=${activeReport.nonZeroGainSetOk}, '
      'gainValue=${activeReport.metrics['gainValue']}, '
      'audioTrackBufferBytes=${activeReport.metrics['audioTrackBufferBytes']}',
    );

    // 5. Sink Write Accounting
    print(
      '  [LANE] Sink Write Accounting: '
      'sinkWriteAccountingOk=${activeReport.sinkWriteAccountingOk}, '
      'framesReadFromTransport=${activeReport.metrics['framesReadFromTransport']}, '
      'framesWrittenToSink=${activeReport.metrics['framesWrittenToSink']}, '
      'partialWriteCount=${activeReport.metrics['partialWriteCount']}, '
      'zeroWriteCount=${activeReport.metrics['zeroWriteCount']}, '
      'drainCalls=${activeReport.metrics['drainCalls']}',
    );

    // 6. Checksum Identity
    print(
      '  [LANE] Checksum Identity: '
      'checksumIdentityOk=${activeReport.checksumIdentityOk}, '
      'kotlinDecoderChecksumHex=${activeReport.metrics['kotlinDecoderChecksumHex']}, '
      'nativePushedChecksumHex=${activeReport.metrics['nativePushedChecksumHex']}, '
      'nativeDrainedChecksumHex=${activeReport.metrics['nativeDrainedChecksumHex']}, '
      'kotlinSinkChecksumHex=${activeReport.metrics['kotlinSinkChecksumHex']}',
    );

    // 7. Backpressure & Underrun
    print(
      '  [LANE] Backpressure & Underrun: '
      'backpressureObservedOk=${activeReport.backpressureObservedOk}, '
      'ingestRingFullCount=${activeReport.metrics['ingestRingFullCount']}, '
      'ingestPartialWriteCount=${activeReport.metrics['ingestPartialWriteCount']}, '
      'nativeBackpressureCount=${activeReport.metrics['nativeBackpressureCount']}, '
      'underrunNonterminalOk=${activeReport.underrunNonterminalOk}, '
      'nativeUnderrunCount=${activeReport.metrics['nativeUnderrunCount']}',
    );

    // 8. EOS & Playback Head
    print(
      '  [LANE] EOS & Playback Head: '
      'eosAccountingOk=${activeReport.eosAccountingOk}, '
      'playbackHeadAdvancedOk=${activeReport.playbackHeadAdvancedOk}, '
      'playbackHeadFinal=${activeReport.metrics['playbackHeadFinal']}, '
      'playbackHeadCaughtUp=${activeReport.metrics['playbackHeadCaughtUp']}',
    );

    // 9. Transport & Thread Ownership
    print(
      '  [LANE] Transport & Thread Ownership: '
      'transportCompletedOk=${activeReport.transportCompletedOk}, '
      'threadOwnershipOk=${activeReport.threadOwnershipOk}, '
      'ingestCallbacksOnOwner=${activeReport.metrics['ingestCallbacksOnOwner']}, '
      'ingestCallbacksOffOwner=${activeReport.metrics['ingestCallbacksOffOwner']}, '
      'listenerCallbacksOnOwner=${activeReport.metrics['listenerCallbacksOnOwner']}, '
      'listenerCallbacksOffOwner=${activeReport.metrics['listenerCallbacksOffOwner']}',
    );

    // 10. Cancellation & Lifecycle
    print(
      '  [LANE] Cancellation & Lifecycle: '
      'cancellationOk=${activeReport.cancellationOk}, '
      'lifecycleDisposeOk=${activeReport.lifecycleDisposeOk}, '
      'mediaReleaseClean=${activeReport.metrics['mediaReleaseClean']}, '
      'mediaReleaseCount=${activeReport.metrics['mediaReleaseCount']}, '
      'audioTrackReleaseCount=${activeReport.metrics['audioTrackReleaseCount']}, '
      'transportDisposeCalls=${activeReport.metrics['transportDisposeCalls']}',
    );

    // 11. Proof Boundary & Verification
    print(
      '  [LANE] Proof Boundary & Verification: '
      'proofBoundaryOk=${activeReport.proofBoundaryOk}, '
      'canonical=${activeReport.canonical}, '
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
          ? VGRealtimePlaybackPipelineIntegrationSmokeReport.passMarkerConstant
          : VGRealtimePlaybackPipelineIntegrationSmokeReport.failMarkerConstant,
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidRealtimePlaybackPipelineIntegrationPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-INTEGRATION-A',
      'target': VGRealtimePlaybackPipelineIntegrationSmokeReport
          .proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      '${VGRealtimePlaybackPipelineIntegrationSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_INTEGRATION_PHYSICAL_SMOKE_FAIL',
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
