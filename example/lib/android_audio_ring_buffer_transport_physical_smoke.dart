// android_audio_ring_buffer_transport_physical_smoke.dart
// vanguard_media_engine — P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice B: Android True-DAG Phase 4
// native SPSC audio ring-buffer transport primitive + diagnostic provider adapter proof physical harness.
//
// Proof lanes:
//   - Lock-Free, Capacity & Order group: ringSpscLockFreeOk, ringCapacityBoundOk, ringNoAllocationOk, fifoOrderIntegrityOk, wraparoundIntegrityOk, noTornFrameOk.
//   - Overrun, Underrun & Seek group: overrunRejectOk, underrunZeroFillOk, underrunSilentWindowOk, rewindRejectOk, forwardSkipBoundedOk, flushDrainSemanticsOk, seekEpochHandshakeOk.
//   - Concurrency, Scheduler Integration & Lifecycle group: concurrentProducerConsumerOk, schedulerIntegrationChecksumOk, teardownWhileQuiescedOk, lifecycleOk, stackScoped.
//   - Metrics group: framesPushed, framesPopped, overrunEvents, framesRejected, underrunEvents, framesZeroFilled, forwardSkipFrames, rewindRejects, seekRequest, seekAck, concurrentFrames, concurrentRepetitions, producerChecksum, consumerChecksum.
//   - Proof-Boundary & Summary group: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   native_spsc_audio_ring_buffer_transport_primitive_and_diagnostic_provider_adapter_only_no_realtime_no_audio_track_no_playback_no_clock_ownership_no_decoder_writer_no_export_reroute_no_streaming_no_ios_no_product
//   SPSC primitive + diagnostic provider only; no realtime/audible playback,
//   no AudioTrack/AAudio/OpenSL/Oboe, no realtime clock ownership,
//   no production decoder writer, no MediaCodec/MediaExtractor,
//   no C++->Kotlin callback, no export reroute, no streaming/cache,
//   no app/editor/product UI, no iOS, does not close P4-AUDIO-GRAPH-TRANSPORT-CLOCK
//   or P4-AUDIO-MIXBUS.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioRingBufferTransportPhysicalSmokeApp());
}

class AndroidAudioRingBufferTransportPhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioRingBufferTransportPhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioRingBufferTransportPhysicalSmokeApp> createState() =>
      _AndroidAudioRingBufferTransportPhysicalSmokeAppState();
}

class _AndroidAudioRingBufferTransportPhysicalSmokeAppState
    extends State<AndroidAudioRingBufferTransportPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Audio Ring Buffer Transport smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AUDIO_RING_BUFFER_TRANSPORT_SMOKE_START');

    VGAudioRingBufferTransportSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGAudioRingBufferTransportSmokeReport.runAndroidDagPhase4AudioRingBufferTransportSmoke(
            timeout: const Duration(seconds: 15),
          ).timeout(const Duration(seconds: 25));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_RING_BUFFER_TRANSPORT_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_RING_BUFFER_TRANSPORT_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ??
        const VGAudioRingBufferTransportSmokeReport(
          pass: false,
          proofBoundary: '',
          raw: <String, String>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          metrics: <String, Object?>{'status': 'FAIL'},
          lastError: 'invocation_failed',
        );

    // 1. Lock-Free, Capacity & Order group
    print(
      '  [LANE] Lock-Free, Capacity & Order: '
      'ringSpscLockFreeOk=${activeReport.ringSpscLockFreeOk}, '
      'ringCapacityBoundOk=${activeReport.ringCapacityBoundOk}, '
      'ringNoAllocationOk=${activeReport.ringNoAllocationOk}, '
      'fifoOrderIntegrityOk=${activeReport.fifoOrderIntegrityOk}, '
      'wraparoundIntegrityOk=${activeReport.wraparoundIntegrityOk}, '
      'noTornFrameOk=${activeReport.noTornFrameOk}',
    );

    // 2. Overrun, Underrun & Seek group
    print(
      '  [LANE] Overrun, Underrun & Seek: '
      'overrunRejectOk=${activeReport.overrunRejectOk}, '
      'underrunZeroFillOk=${activeReport.underrunZeroFillOk}, '
      'underrunSilentWindowOk=${activeReport.underrunSilentWindowOk}, '
      'rewindRejectOk=${activeReport.rewindRejectOk}, '
      'forwardSkipBoundedOk=${activeReport.forwardSkipBoundedOk}, '
      'flushDrainSemanticsOk=${activeReport.flushDrainSemanticsOk}, '
      'seekEpochHandshakeOk=${activeReport.seekEpochHandshakeOk}',
    );

    // 3. Concurrency, Scheduler Integration & Lifecycle group
    print(
      '  [LANE] Concurrency, Scheduler Integration & Lifecycle: '
      'concurrentProducerConsumerOk=${activeReport.concurrentProducerConsumerOk}, '
      'schedulerIntegrationChecksumOk=${activeReport.schedulerIntegrationChecksumOk}, '
      'teardownWhileQuiescedOk=${activeReport.teardownWhileQuiescedOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'stackScoped=${activeReport.stackScoped}',
    );

    // 4. Metrics group
    print(
      '  [LANE] Metrics: '
      'framesPushed=${activeReport.framesPushed}, '
      'framesPopped=${activeReport.framesPopped}, '
      'overrunEvents=${activeReport.overrunEvents}, '
      'framesRejected=${activeReport.framesRejected}, '
      'underrunEvents=${activeReport.underrunEvents}, '
      'framesZeroFilled=${activeReport.framesZeroFilled}, '
      'forwardSkipFrames=${activeReport.forwardSkipFrames}, '
      'rewindRejects=${activeReport.rewindRejects}, '
      'seekRequest=${activeReport.seekRequest}, '
      'seekAck=${activeReport.seekAck}, '
      'concurrentFrames=${activeReport.concurrentFrames}, '
      'concurrentRepetitions=${activeReport.concurrentRepetitions}, '
      'producerChecksum=${activeReport.producerChecksum}, '
      'consumerChecksum=${activeReport.consumerChecksum}',
    );

    // 5. Proof Boundary & Summary group
    print(
      '  [LANE] Proof Boundary & Summary: '
      'canonical=${activeReport.hasCanonicalProofBoundary}, '
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
        activeReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAudioRingBufferTransportPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-GRAPH-TRANSPORT-CLOCK',
      'target': VGAudioRingBufferTransportSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_AUDIO_RING_BUFFER_TRANSPORT_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIO_RING_BUFFER_TRANSPORT_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIO_RING_BUFFER_TRANSPORT_SMOKE_FAIL',
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
