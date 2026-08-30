// android_camera2_concurrent_ingest_physical_smoke.dart
// Vanguard Media Engine — P3-CAM-CONCURRENT: Android Camera2 Dual-Camera
// Concurrent PRIVATE AHardwareBuffer Ingest Smoke Physical Harness.
//
// Proof lanes:
//   Lane 1: smoke report pass == true.
//   Lane 2: smoke report hasTwoCameraProof == true (selectedCameraIds >= 2, openedCameraCount >= 2, configuredSessionCount >= 2, capturedFrameCount >= 2).
//   Lane 3: smoke report hasNativeProof == true (nativeIngestPassCount >= 2, nativeCreateRaw PASS, nativeDestroyRaw PASS).
//   Lane 4: smoke report hasApi33FenceProof == true (apiLevel >= 33 -> syncFenceAwaited/Closed >= 2; apiLevel < 33 -> true).
//   Lane 5: smoke report proofBoundary equals canonical P3-CAM-CONCURRENT boundary constant.
//   Lane 6: smoke report decision == ingested and reasons are empty.
//   Lane 7: getters and toMap() serialization are coherent.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2ConcurrentIngestPhysicalSmokeApp());
}

class AndroidCamera2ConcurrentIngestPhysicalSmokeApp extends StatefulWidget {
  const AndroidCamera2ConcurrentIngestPhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2ConcurrentIngestPhysicalSmokeApp> createState() =>
      _AndroidCamera2ConcurrentIngestPhysicalSmokeAppState();
}

class _AndroidCamera2ConcurrentIngestPhysicalSmokeAppState
    extends State<AndroidCamera2ConcurrentIngestPhysicalSmokeApp> {
  String _status = 'Initializing Camera2 Concurrent Ingest Physical Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE3_CAMERA_CONCURRENT_INGEST_SMOKE_START');
    String? topLevelError;
    VGCamera2ConcurrentIngestSmokeReport? report;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;
    var gettersCoherent = false;
    var mapMatches = false;

    try {
      // 0. Wait 5 seconds before running to allow grant runner to grant CAMERA after install/start
      await Future<void>.delayed(const Duration(seconds: 5));

      // 1. Invoke Camera2 concurrent ingest smoke harness
      report =
          await VGCamera2ConcurrentIngestSmokeReport.runAndroidCamera2ConcurrentIngestSmoke(
            timeout: const Duration(seconds: 15),
            maxWidth: 640,
            maxHeight: 480,
          ).timeout(const Duration(seconds: 35));

      // Lane 1: report.pass == true
      lane1Pass = report.pass == true;
      print(
        'ANDROID_DAG_PHASE3_CAMERA_CONCURRENT_INGEST_LANE_1: pass=$lane1Pass reportPass=${report.pass}',
      );

      // Lane 2: report.hasTwoCameraProof == true
      lane2Pass = report.hasTwoCameraProof == true;
      print(
        'ANDROID_DAG_PHASE3_CAMERA_CONCURRENT_INGEST_LANE_2: pass=$lane2Pass hasTwoCameraProof=${report.hasTwoCameraProof} selectedCameraIds=${report.selectedCameraIds} opened=${report.openedCameraCount} configured=${report.configuredSessionCount} captured=${report.capturedFrameCount}',
      );

      // Lane 3: report.hasNativeProof == true
      lane3Pass = report.hasNativeProof == true;
      print(
        'ANDROID_DAG_PHASE3_CAMERA_CONCURRENT_INGEST_LANE_3: pass=$lane3Pass hasNativeProof=${report.hasNativeProof} nativeIngestPassCount=${report.nativeIngestPassCount} nativeCreate=${report.nativeCreateRaw} nativeDestroy=${report.nativeDestroyRaw}',
      );

      // Lane 4: report.hasApi33FenceProof == true
      lane4Pass = report.hasApi33FenceProof == true;
      print(
        'ANDROID_DAG_PHASE3_CAMERA_CONCURRENT_INGEST_LANE_4: pass=$lane4Pass hasApi33FenceProof=${report.hasApi33FenceProof} apiLevel=${report.apiLevel} syncFenceAwaited=${report.syncFenceAwaitedCount} syncFenceClosed=${report.syncFenceClosedCount}',
      );

      // Lane 5: report.proofBoundary matches canonical constant
      lane5Pass =
          report.proofBoundary ==
          VGCamera2ConcurrentIngestSmokeReport.proofBoundaryConstant;
      print(
        'ANDROID_DAG_PHASE3_CAMERA_CONCURRENT_INGEST_LANE_5: pass=$lane5Pass proofBoundary=${report.proofBoundary}',
      );

      // Lane 6: report.decision == ingested and reasons empty
      lane6Pass =
          report.decision == VGCamera2ConcurrentIngestSmokeDecision.ingested &&
          report.reasons.isEmpty;
      print(
        'ANDROID_DAG_PHASE3_CAMERA_CONCURRENT_INGEST_LANE_6: pass=$lane6Pass decision=${report.decision.name} reasons=${report.reasons}',
      );

      // Lane 7: getters and toMap() coherent
      final map = report.toMap();
      gettersCoherent =
          report.isIngested ==
              (report.decision ==
                  VGCamera2ConcurrentIngestSmokeDecision.ingested) &&
          report.isPermissionRequired ==
              (report.decision ==
                  VGCamera2ConcurrentIngestSmokeDecision.permissionRequired) &&
          report.isConcurrentUnsupported ==
              (report.decision ==
                  VGCamera2ConcurrentIngestSmokeDecision
                      .concurrentNotSupported);

      mapMatches =
          map['pass'] == report.pass &&
          map['decision'] == report.decision.name &&
          listEquals(map['reasons'] as List?, report.reasons) &&
          map['apiLevel'] == report.apiLevel &&
          map['hasCameraPermission'] == report.hasCameraPermission &&
          listEquals(
            map['selectedCameraIds'] as List?,
            report.selectedCameraIds,
          ) &&
          map['openedCameraCount'] == report.openedCameraCount &&
          map['configuredSessionCount'] == report.configuredSessionCount &&
          map['capturedFrameCount'] == report.capturedFrameCount &&
          map['nativeIngestPassCount'] == report.nativeIngestPassCount &&
          map['syncFenceAwaitedCount'] == report.syncFenceAwaitedCount &&
          map['syncFenceClosedCount'] == report.syncFenceClosedCount &&
          map['nativeCreateRaw'] == report.nativeCreateRaw &&
          map['nativeDestroyRaw'] == report.nativeDestroyRaw &&
          listEquals(map['events'] as List?, report.events) &&
          mapEquals(
            map['diagnostics'] as Map<String, Object?>?,
            report.diagnostics,
          ) &&
          map['proofBoundary'] == report.proofBoundary &&
          map['durationMs'] == report.durationMs;

      lane7Pass = gettersCoherent && mapMatches;
      print(
        'ANDROID_DAG_PHASE3_CAMERA_CONCURRENT_INGEST_LANE_7: pass=$lane7Pass gettersCoherent=$gettersCoherent mapMatches=$mapMatches',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Camera2 Concurrent Ingest Smoke exceeded timeout: $te';
      print(
        'ANDROID_DAG_PHASE3_CAMERA_CONCURRENT_INGEST_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE3_CAMERA_CONCURRENT_INGEST_SMOKE_ERROR: $topLevelError',
      );
    } finally {
      final allPass =
          lane1Pass &&
          lane2Pass &&
          lane3Pass &&
          lane4Pass &&
          lane5Pass &&
          lane6Pass &&
          lane7Pass &&
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2ConcurrentIngestSmokeHarness',
        'slice': 'P3-CAM-CONCURRENT',
        'target': 'android_physical',
        'pass': allPass,
        'lanes': <String, dynamic>{
          'lane1_passTrue': {'pass': lane1Pass, 'reportPass': report?.pass},
          'lane2_twoCameraProof': {
            'pass': lane2Pass,
            'hasTwoCameraProof': report?.hasTwoCameraProof,
            'selectedCameraIds': report?.selectedCameraIds,
            'openedCameraCount': report?.openedCameraCount,
            'configuredSessionCount': report?.configuredSessionCount,
            'capturedFrameCount': report?.capturedFrameCount,
          },
          'lane3_nativeProof': {
            'pass': lane3Pass,
            'hasNativeProof': report?.hasNativeProof,
            'nativeIngestPassCount': report?.nativeIngestPassCount,
            'nativeCreateRaw': report?.nativeCreateRaw,
            'nativeDestroyRaw': report?.nativeDestroyRaw,
          },
          'lane4_api33FenceProof': {
            'pass': lane4Pass,
            'hasApi33FenceProof': report?.hasApi33FenceProof,
            'apiLevel': report?.apiLevel,
            'syncFenceAwaitedCount': report?.syncFenceAwaitedCount,
            'syncFenceClosedCount': report?.syncFenceClosedCount,
          },
          'lane5_proofBoundaryMatches': {
            'pass': lane5Pass,
            'proofBoundary': report?.proofBoundary,
          },
          'lane6_decisionIngested': {
            'pass': lane6Pass,
            'decision': report?.decision.name,
            'reasons': report?.reasons,
          },
          'lane7_gettersAndToMapCoherent': {
            'pass': lane7Pass,
            'gettersCoherent': gettersCoherent,
            'mapMatches': mapMatches,
          },
        },
        'smokeReport': report?.toMap(),
        'error': topLevelError,
      };

      print(
        'ANDROID_DAG_PHASE3_CAMERA_CONCURRENT_INGEST_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_DAG_PHASE3_CAMERA_CONCURRENT_INGEST_PHYSICAL_SMOKE_PASS'
            : 'ANDROID_DAG_PHASE3_CAMERA_CONCURRENT_INGEST_PHYSICAL_SMOKE_FAIL',
      );

      if (mounted) {
        setState(() {
          _status = allPass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(allPass ? 0 : 1);
    }
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
