// android_async_runtime_queue_scheduler_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-RUNTIME-QUEUE-SCHEDULER: Android True-DAG
// Phase 4 diagnostic async runtime queue/backpressure scheduler integration
// physical smoke harness.
//
// Proof lanes:
//   - Worker Ownership group: asyncThreadDecouplingOk,
//     noOwnerThreadDispatchOk, workerThreadDistinct, ownerDispatchCalls.
//   - Command Serialization group: controlCommandSerializationOk,
//     commandsEnqueued, commandsProcessed, commandErrors.
//   - Backpressure group: sourceBackpressureOk, outputBackpressureOk,
//     writerBackpressureRejects, backpressureCount.
//   - Identity & Zero-Fill group: checksumAccountingOk, checksumsMatch,
//     providerZeroFillAccountingOk, totalFramesAccepted,
//     totalOutputFramesRead, probeFramesZeroFilled, probeSilenceCount.
//   - Seek & Lifecycle group: seekEpochCoordinationOk, workerJoinOnDestroyOk,
//     idempotentDestroyOk.
//   - Proof Boundary & Summary group: proofBoundaryOk,
//     hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   diagnostic_async_runtime_queue_scheduler_integration_proof_only_worker_owned_clock_and_coordinator_command_serialized_source_ring_spsc_output_ring_spsc_caller_derived_systime_ticks_only_steady_clock_pacing_only_no_native_media_timebase_no_audible_output_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_product_editor_app_wiring_no_streaming_cache_no_ios_no_export_route_changes

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAsyncRuntimeQueueSchedulerPhysicalSmokeApp());
}

class AndroidAsyncRuntimeQueueSchedulerPhysicalSmokeApp extends StatefulWidget {
  const AndroidAsyncRuntimeQueueSchedulerPhysicalSmokeApp({super.key});

  @override
  State<AndroidAsyncRuntimeQueueSchedulerPhysicalSmokeApp> createState() =>
      _AndroidAsyncRuntimeQueueSchedulerPhysicalSmokeAppState();
}

class _AndroidAsyncRuntimeQueueSchedulerPhysicalSmokeAppState
    extends State<AndroidAsyncRuntimeQueueSchedulerPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Async Runtime Queue Scheduler smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_SCHEDULER_SMOKE_START');

    VGAsyncRuntimeQueueSchedulerSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGAsyncRuntimeQueueSchedulerSmokeReport.runAsyncRuntimeQueueSchedulerSmoke(
            timeout: const Duration(seconds: 45),
          ).timeout(const Duration(seconds: 55));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_SCHEDULER_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_SCHEDULER_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ??
        VGAsyncRuntimeQueueSchedulerSmokeReport.fromMap(<String, Object?>{
          'pass': false,
          'status': 'fail',
          'marker': VGAsyncRuntimeQueueSchedulerSmokeReport.failMarkerConstant,
          'failureReason': 'invocation_failed',
          'lastError': 'invocation_failed',
        });

    // 1. Worker Ownership group
    print(
      '  [LANE] Worker Ownership: '
      'asyncThreadDecouplingOk=${activeReport.asyncThreadDecouplingOk}, '
      'noOwnerThreadDispatchOk=${activeReport.noOwnerThreadDispatchOk}, '
      'workerThreadDistinct=${activeReport.workerThreadDistinct}, '
      'ownerDispatchCalls=${activeReport.ownerDispatchCalls}',
    );

    // 2. Command Serialization group
    print(
      '  [LANE] Command Serialization: '
      'controlCommandSerializationOk=${activeReport.controlCommandSerializationOk}, '
      'commandsEnqueued=${activeReport.commandsEnqueued}, '
      'commandsProcessed=${activeReport.commandsProcessed}, '
      'commandErrors=${activeReport.commandErrors}',
    );

    // 3. Backpressure group
    print(
      '  [LANE] Backpressure: '
      'sourceBackpressureOk=${activeReport.sourceBackpressureOk}, '
      'outputBackpressureOk=${activeReport.outputBackpressureOk}, '
      'writerBackpressureRejects=${activeReport.writerBackpressureRejects}, '
      'backpressureCount=${activeReport.backpressureCount}',
    );

    // 4. Identity & Zero-Fill group
    print(
      '  [LANE] Identity & Zero-Fill: '
      'checksumAccountingOk=${activeReport.checksumAccountingOk}, '
      'checksumsMatch=${activeReport.checksumsMatch}, '
      'providerZeroFillAccountingOk=${activeReport.providerZeroFillAccountingOk}, '
      'totalFramesAccepted=${activeReport.totalFramesAccepted}, '
      'totalOutputFramesRead=${activeReport.totalOutputFramesRead}, '
      'kotlinAcceptedChecksumHex=${activeReport.kotlinAcceptedChecksumHex}, '
      'nativeAcceptedChecksumHex=${activeReport.nativeAcceptedChecksumHex}, '
      'nativeOutputReadChecksumHex=${activeReport.nativeOutputReadChecksumHex}, '
      'probeFramesZeroFilled=${activeReport.probeFramesZeroFilled}, '
      'probeSilenceCount=${activeReport.probeSilenceCount}',
    );

    // 5. Seek & Lifecycle group
    print(
      '  [LANE] Seek & Lifecycle: '
      'seekEpochCoordinationOk=${activeReport.seekEpochCoordinationOk}, '
      'workerJoinOnDestroyOk=${activeReport.workerJoinOnDestroyOk}, '
      'idempotentDestroyOk=${activeReport.idempotentDestroyOk}',
    );

    // 6. Proof Boundary & Summary group
    print(
      '  [LANE] Proof Boundary & Summary: '
      'proofBoundaryOk=${activeReport.proofBoundaryOk}, '
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
      'unit': 'AndroidAsyncRuntimeQueueSchedulerPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-RUNTIME-QUEUE-SCHEDULER',
      'target': VGAsyncRuntimeQueueSchedulerSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_SCHEDULER_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_SCHEDULER_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_SCHEDULER_PHYSICAL_SMOKE_FAIL',
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
