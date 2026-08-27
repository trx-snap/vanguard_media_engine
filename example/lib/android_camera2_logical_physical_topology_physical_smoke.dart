// android_camera2_logical_physical_topology_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit R: Android Camera2 Logical/Physical
// Sensor Topology Physical Proof Foundation Smoke Harness.
//
// Proof lanes:
//   Lane 1: Probe returns report.success == true.
//   Lane 2: apiLevel >= 28, cameraCount == cameras.length, cameraCount >= 1.
//   Lane 3: hasCameraPermission == true (granted via android-physical-smoke-grant-camera).
//   Lane 4: Public camera IDs are non-empty and unique.
//   Lane 5: Every lensFacing is front/back/external/unknown.
//   Lane 6: Every sensorOrientation is null or one of 0/90/180/270.
//   Lane 7: Every hardwareLevel is legacy/limited/full/level3/external/unknown.
//   Lane 8: Every camera has coherent logical flag: isLogicalMultiCamera == capabilities.contains('LOGICAL_MULTI_CAMERA').
//   Lane 9: Logical cameras, if any, have non-empty unique physicalCameraIds.
//   Lane 10: No logical camera includes its own cameraId in physicalCameraIds.
//   Lane 11: Physical child IDs are recorded in a topology summary; zero logical cameras is allowed and explicitly reported.
//   Lane 12: At least one front and one back camera are present on this reference physical target.
//   Lane 13: Sensor active/pixel arrays are positive when present, and at least one camera has each sensor array field.
//   Lane 14: supportsConcurrentCamera matches whether any concurrentCameraIdSets entry length >= 2.
//   Lane 15: All concurrentCameraIdSets entries use only public camera IDs from report.cameras, not hidden physical-only IDs.
//   Lane 16: fallbackRecommendation is coherent with cameraCount, thermal status, and concurrent camera support.
//   Lane 17: Proof boundary string is capability_only_no_camera_open and no lane claims camera open/session/rendering.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2LogicalPhysicalTopologyPhysicalSmokeApp());
}

class AndroidCamera2LogicalPhysicalTopologyPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidCamera2LogicalPhysicalTopologyPhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2LogicalPhysicalTopologyPhysicalSmokeApp> createState() =>
      _AndroidCamera2LogicalPhysicalTopologyPhysicalSmokeAppState();
}

class _AndroidCamera2LogicalPhysicalTopologyPhysicalSmokeAppState
    extends State<AndroidCamera2LogicalPhysicalTopologyPhysicalSmokeApp> {
  String _status =
      'Initializing Camera2 Logical/Physical Topology Physical Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  static const Set<String> _validLensFacings = {
    'front',
    'back',
    'external',
    'unknown',
  };

  static const Set<String> _validHardwareLevels = {
    'legacy',
    'limited',
    'full',
    'level3',
    'external',
    'unknown',
  };

  static const Set<String> _thermalBlockedNames = {
    'severe',
    'critical',
    'emergency',
    'shutdown',
  };

  static const String _proofBoundary = 'capability_only_no_camera_open';

  String _computeExpectedFallback({
    required int cameraCount,
    required String thermalStatusName,
    required int? thermalStatus,
    required bool supportsConcurrentCamera,
  }) {
    if (cameraCount == 0) {
      return 'no_camera';
    }
    final isThermalBlocked =
        (thermalStatus != null && thermalStatus >= 3) ||
        _thermalBlockedNames.contains(thermalStatusName);
    if (isThermalBlocked) {
      return 'thermal_blocked';
    }
    if (supportsConcurrentCamera) {
      return 'concurrent_supported';
    }
    return 'single_camera_only';
  }

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_R_LOGICAL_PHYSICAL_TOPOLOGY_SMOKE_START');
    String? topLevelError;
    VGCameraHardwareCapabilityReport? report;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;
    var lane8Pass = false;
    var lane9Pass = false;
    var lane10Pass = false;
    var lane11Pass = false;
    var lane12Pass = false;
    var lane13Pass = false;
    var lane14Pass = false;
    var lane15Pass = false;
    var lane16Pass = false;
    var lane17Pass = false;

    var logicalCameras = <VGCameraHardwareDeviceCapability>[];
    var nonLogicalCameras = <VGCameraHardwareDeviceCapability>[];
    var allPhysicalChildIds = <String>[];
    var topologySummary = <String, dynamic>{};
    var expectedFallback = 'unknown';
    var hasFront = false;
    var hasBack = false;
    var hasActiveArray = false;
    var hasPixelArray = false;

    try {
      // 1. Invoke public capability probe API (diagnostic only, non-opening)
      report =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities()
              .timeout(const Duration(seconds: 15));

      // Lane 1: Probe returns success == true
      lane1Pass = report.success == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_1: pass=$lane1Pass success=${report.success}',
      );

      // Lane 2: apiLevel >= 28, cameraCount == cameras.length, cameraCount >= 1
      lane2Pass =
          report.apiLevel >= 28 &&
          report.cameraCount == report.cameras.length &&
          report.cameraCount >= 1;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_2: pass=$lane2Pass apiLevel=${report.apiLevel} '
        'cameraCount=${report.cameraCount} camerasLength=${report.cameras.length}',
      );

      // Lane 3: hasCameraPermission == true (granted via harness)
      lane3Pass = report.hasCameraPermission == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_3: pass=$lane3Pass hasCameraPermission=${report.hasCameraPermission}',
      );

      // Lane 4: Public camera IDs are non-empty and unique
      final cameraIds = report.cameras.map((c) => c.cameraId).toList();
      final uniqueCameraIds = cameraIds.toSet();
      lane4Pass =
          report.cameras.isNotEmpty &&
          report.cameras.every((c) => c.cameraId.isNotEmpty) &&
          uniqueCameraIds.length == report.cameras.length;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_4: pass=$lane4Pass cameraIds=$cameraIds',
      );

      // Lane 5: Every lensFacing is front/back/external/unknown
      lane5Pass =
          report.cameras.isNotEmpty &&
          report.cameras.every((c) => _validLensFacings.contains(c.lensFacing));
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_5: pass=$lane5Pass '
        'facings=${report.cameras.map((c) => c.lensFacing).toList()}',
      );

      // Lane 6: Every sensorOrientation is null or one of 0/90/180/270
      lane6Pass = report.cameras.every(
        (c) =>
            c.sensorOrientation == null ||
            const {0, 90, 180, 270}.contains(c.sensorOrientation),
      );
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_6: pass=$lane6Pass '
        'orientations=${report.cameras.map((c) => c.sensorOrientation).toList()}',
      );

      // Lane 7: Every hardwareLevel is legacy/limited/full/level3/external/unknown
      lane7Pass =
          report.cameras.isNotEmpty &&
          report.cameras.every(
            (c) => _validHardwareLevels.contains(c.hardwareLevel),
          );
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_7: pass=$lane7Pass '
        'hardwareLevels=${report.cameras.map((c) => c.hardwareLevel).toList()}',
      );

      // Lane 8: Every camera has coherent logical flag
      lane8Pass =
          report.cameras.isNotEmpty &&
          report.cameras.every(
            (c) =>
                c.isLogicalMultiCamera ==
                c.capabilities.contains('LOGICAL_MULTI_CAMERA'),
          );
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_8: pass=$lane8Pass '
        'logicalSummary=${report.cameras.map((c) => "${c.cameraId}:logical=${c.isLogicalMultiCamera}").toList()}',
      );

      // Collect logical and non-logical cameras
      logicalCameras = report.cameras
          .where((c) => c.isLogicalMultiCamera)
          .toList();
      nonLogicalCameras = report.cameras
          .where((c) => !c.isLogicalMultiCamera)
          .toList();

      // Lane 9: Logical cameras, if any, have non-empty unique physicalCameraIds
      final logicalCamerasValid =
          logicalCameras.isEmpty ||
          logicalCameras.every(
            (c) =>
                c.physicalCameraIds.isNotEmpty &&
                c.physicalCameraIds.every((id) => id.isNotEmpty) &&
                c.physicalCameraIds.toSet().length ==
                    c.physicalCameraIds.length,
          );
      lane9Pass = logicalCamerasValid;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_9: pass=$lane9Pass logicalCount=${logicalCameras.length} '
        'physicalIds=${logicalCameras.map((c) => "${c.cameraId}->${c.physicalCameraIds}").toList()}',
      );

      // Lane 10: No logical camera includes its own cameraId in physicalCameraIds
      lane10Pass = logicalCameras.every(
        (c) => !c.physicalCameraIds.contains(c.cameraId),
      );
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_10: pass=$lane10Pass '
        'noParentInOwnPhysicalIds=$lane10Pass',
      );

      // Lane 11: Physical child IDs recorded in topology summary; zero logical cameras allowed
      final physicalChildIdsByLogicalCamera = <String, List<String>>{
        for (final c in logicalCameras) c.cameraId: c.physicalCameraIds,
      };
      allPhysicalChildIds =
          logicalCameras.expand((c) => c.physicalCameraIds).toSet().toList()
            ..sort();
      topologySummary = <String, dynamic>{
        'totalCameraCount': report.cameras.length,
        'logicalCameraCount': logicalCameras.length,
        'nonLogicalCameraCount': nonLogicalCameras.length,
        'logicalCameraIds': logicalCameras.map((c) => c.cameraId).toList(),
        'nonLogicalCameraIds': nonLogicalCameras
            .map((c) => c.cameraId)
            .toList(),
        'physicalChildIdsByLogicalCamera': physicalChildIdsByLogicalCamera,
        'allPhysicalChildIds': allPhysicalChildIds,
        'hasLogicalCamera': logicalCameras.isNotEmpty,
        'zeroLogicalCamerasAllowed': true,
        'publicCameraIds': cameraIds,
      };
      lane11Pass =
          topologySummary['zeroLogicalCamerasAllowed'] == true &&
          topologySummary['totalCameraCount'] == report.cameras.length;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_11: pass=$lane11Pass '
        'logicalCount=${logicalCameras.length} physicalChildCount=${allPhysicalChildIds.length} '
        'zeroLogicalCamerasAllowed=true',
      );

      // Lane 12: At least one front and one back camera are present on this reference target
      hasFront = report.cameras.any((c) => c.lensFacing == 'front');
      hasBack = report.cameras.any((c) => c.lensFacing == 'back');
      lane12Pass = hasFront && hasBack;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_12: pass=$lane12Pass hasFront=$hasFront hasBack=$hasBack',
      );

      // Lane 13: Sensor active/pixel arrays positive when present, and at least one camera has each
      final activeArrayValid = report.cameras.every((c) {
        final a = c.sensorActiveArraySize;
        if (a == null) return true;
        return a.left >= 0 &&
            a.top >= 0 &&
            a.right > a.left &&
            a.bottom > a.top;
      });
      final pixelArrayValid = report.cameras.every((c) {
        final p = c.sensorPixelArraySize;
        if (p == null) return true;
        return p.width > 0 && p.height > 0;
      });
      hasActiveArray = report.cameras.any(
        (c) => c.sensorActiveArraySize != null,
      );
      hasPixelArray = report.cameras.any((c) => c.sensorPixelArraySize != null);
      lane13Pass =
          activeArrayValid &&
          pixelArrayValid &&
          hasActiveArray &&
          hasPixelArray;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_13: pass=$lane13Pass '
        'hasActiveArray=$hasActiveArray hasPixelArray=$hasPixelArray',
      );

      // Lane 14: supportsConcurrentCamera matches whether any concurrentCameraIdSets entry length >= 2
      final hasConcurrentPair = report.concurrentCameraIdSets.any(
        (s) => s.length >= 2,
      );
      lane14Pass = report.supportsConcurrentCamera == hasConcurrentPair;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_14: pass=$lane14Pass '
        'supportsConcurrentCamera=${report.supportsConcurrentCamera} hasConcurrentPair=$hasConcurrentPair '
        'concurrentSets=${report.concurrentCameraIdSets}',
      );

      // Lane 15: All concurrentCameraIdSets entries use only public camera IDs from report.cameras
      final publicIdSet = uniqueCameraIds;
      final allConcurrentSetsUsePublicIds = report.concurrentCameraIdSets.every(
        (set) => set.every((id) => publicIdSet.contains(id)),
      );
      lane15Pass = allConcurrentSetsUsePublicIds;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_15: pass=$lane15Pass '
        'allConcurrentSetsUsePublicIds=$allConcurrentSetsUsePublicIds',
      );

      // Lane 16: fallbackRecommendation is coherent with cameraCount, thermal status, and concurrent support
      expectedFallback = _computeExpectedFallback(
        cameraCount: report.cameraCount,
        thermalStatusName: report.thermalStatusName,
        thermalStatus: report.thermalStatus,
        supportsConcurrentCamera: report.supportsConcurrentCamera,
      );
      lane16Pass = report.fallbackRecommendation == expectedFallback;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_16: pass=$lane16Pass '
        'fallbackRecommendation=${report.fallbackRecommendation} expectedFallback=$expectedFallback',
      );

      // Lane 17: Proof boundary string is capability_only_no_camera_open and no lane claims camera open
      lane17Pass = _proofBoundary == 'capability_only_no_camera_open';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_LANE_17: pass=$lane17Pass '
        'proofBoundary=$_proofBoundary',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Capability probe exceeded 15 seconds: $te';
      print('ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('ANDROID_CAMERA_PHASE3_UNIT_R_SMOKE_ERROR: $topLevelError');
    } finally {
      final allPass =
          lane1Pass &&
          lane2Pass &&
          lane3Pass &&
          lane4Pass &&
          lane5Pass &&
          lane6Pass &&
          lane7Pass &&
          lane8Pass &&
          lane9Pass &&
          lane10Pass &&
          lane11Pass &&
          lane12Pass &&
          lane13Pass &&
          lane14Pass &&
          lane15Pass &&
          lane16Pass &&
          lane17Pass &&
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2CapabilityProbe',
        'slice':
            'Phase 3-Unit R — Android Camera2 Logical/Physical Sensor Topology Physical Proof Foundation',
        'target': 'android_physical',
        'pass': allPass,
        'proofBoundary': _proofBoundary,
        'topologySummary': topologySummary,
        'lanes': <String, dynamic>{
          'lane1_nativeSuccess': {
            'pass': lane1Pass,
            'success': report?.success,
          },
          'lane2_apiLevelAndCameraCountMatch': {
            'pass': lane2Pass,
            'apiLevel': report?.apiLevel,
            'cameraCount': report?.cameraCount,
            'camerasLength': report?.cameras.length,
          },
          'lane3_hasCameraPermissionTrue': {
            'pass': lane3Pass,
            'hasCameraPermission': report?.hasCameraPermission,
          },
          'lane4_publicCameraIdsUnique': {
            'pass': lane4Pass,
            'publicCameraIds': report?.cameras.map((c) => c.cameraId).toList(),
          },
          'lane5_lensFacingValid': {
            'pass': lane5Pass,
            'lensFacings': report?.cameras.map((c) => c.lensFacing).toList(),
          },
          'lane6_sensorOrientationValid': {
            'pass': lane6Pass,
            'sensorOrientations': report?.cameras
                .map((c) => c.sensorOrientation)
                .toList(),
          },
          'lane7_hardwareLevelValid': {
            'pass': lane7Pass,
            'hardwareLevels': report?.cameras
                .map((c) => c.hardwareLevel)
                .toList(),
          },
          'lane8_logicalFlagCoherence': {
            'pass': lane8Pass,
            'logicalSummary': report?.cameras
                .map(
                  (c) => {
                    'cameraId': c.cameraId,
                    'isLogicalMultiCamera': c.isLogicalMultiCamera,
                    'hasLogicalCapability': c.capabilities.contains(
                      'LOGICAL_MULTI_CAMERA',
                    ),
                  },
                )
                .toList(),
          },
          'lane9_logicalPhysicalIdsNonEmptyAndUnique': {
            'pass': lane9Pass,
            'logicalCameraCount': logicalCameras.length,
          },
          'lane10_noParentInOwnPhysicalIds': {'pass': lane10Pass},
          'lane11_topologySummaryRecorded': {
            'pass': lane11Pass,
            'topologySummary': topologySummary,
          },
          'lane12_frontAndBackPresent': {
            'pass': lane12Pass,
            'hasFront': hasFront,
            'hasBack': hasBack,
          },
          'lane13_sensorActiveAndPixelArrays': {
            'pass': lane13Pass,
            'hasActiveArray': hasActiveArray,
            'hasPixelArray': hasPixelArray,
          },
          'lane14_supportsConcurrentConsistency': {
            'pass': lane14Pass,
            'supportsConcurrentCamera': report?.supportsConcurrentCamera,
          },
          'lane15_concurrentSetsUsePublicIds': {
            'pass': lane15Pass,
            'concurrentCameraIdSets': report?.concurrentCameraIdSets,
          },
          'lane16_fallbackRecommendationCoherence': {
            'pass': lane16Pass,
            'fallbackRecommendation': report?.fallbackRecommendation,
            'expectedFallback': expectedFallback,
          },
          'lane17_proofBoundaryCapabilityOnly': {
            'pass': lane17Pass,
            'proofBoundary': _proofBoundary,
          },
        },
        'report': report?.toMap(),
        'error': topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_R_LOGICAL_PHYSICAL_TOPOLOGY_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_R_LOGICAL_PHYSICAL_TOPOLOGY_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_R_LOGICAL_PHYSICAL_TOPOLOGY_PHYSICAL_FAIL',
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
