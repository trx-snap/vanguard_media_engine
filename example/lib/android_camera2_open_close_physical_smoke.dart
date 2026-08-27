// android_camera2_open_close_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit H: Android Camera2 Single-Camera
// Open/Close Lifecycle Smoke Physical Harness.
//
// Proof lanes:
//   Lane 1: probe success true, apiLevel >= 21, cameraCount >= 1, cameras not empty.
//   Lane 2: probe hasCameraPermission true, proving adb grant path active with no permission UI.
//   Lane 3: selected primary camera id nonblank and exists in probe cameras.
//   Lane 4: open/close report success true.
//   Lane 5: report.hasCameraPermission true.
//   Lane 6: report.attemptedOpen true.
//   Lane 7: report.opened true and events contains onOpened.
//   Lane 8: report.closed true and events contains onClosed.
//   Lane 9: report.decision == openedAndClosed, reasons empty, cameraId equals selected id.
//   Lane 10: getters/toMap coherent (isOpenedAndClosed, isAttempted, isClosed, and map fields match).

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2OpenClosePhysicalSmokeApp());
}

class AndroidCamera2OpenClosePhysicalSmokeApp extends StatefulWidget {
  const AndroidCamera2OpenClosePhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2OpenClosePhysicalSmokeApp> createState() =>
      _AndroidCamera2OpenClosePhysicalSmokeAppState();
}

class _AndroidCamera2OpenClosePhysicalSmokeAppState
    extends State<AndroidCamera2OpenClosePhysicalSmokeApp> {
  String _status = 'Initializing Camera2 Open/Close Physical Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_H_OPEN_CLOSE_SMOKE_START');
    String? topLevelError;
    VGCameraHardwareCapabilityReport? probeReport;
    VGCameraHardwareDeviceCapability? primary;
    VGCamera2OpenCloseSmokeReport? smokeReport;

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
    var gettersCoherent = false;
    var mapMatches = false;

    try {
      // 0. Wait 5 seconds before probing/running to allow grant runner to grant CAMERA after install/start
      await Future<void>.delayed(const Duration(seconds: 5));

      // 1. Probe Android Camera2 capabilities
      probeReport =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities()
              .timeout(const Duration(seconds: 15));

      // Lane 1: probe success true, apiLevel >= 21, cameraCount >= 1, cameras not empty
      lane1Pass =
          probeReport.success == true &&
          probeReport.apiLevel >= 21 &&
          probeReport.cameraCount >= 1 &&
          probeReport.cameras.isNotEmpty;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_H_SMOKE_LANE_1: pass=$lane1Pass success=${probeReport.success} apiLevel=${probeReport.apiLevel} cameraCount=${probeReport.cameraCount} camerasLength=${probeReport.cameras.length}',
      );

      // Lane 2: probe hasCameraPermission true, proving adb grant path active with no permission UI
      lane2Pass = probeReport.hasCameraPermission == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_H_SMOKE_LANE_2: pass=$lane2Pass hasCameraPermission=${probeReport.hasCameraPermission}',
      );

      // 2. Select primary camera: first lensFacing == 'back', else first camera
      for (final camera in probeReport.cameras) {
        if (camera.lensFacing == 'back') {
          primary = camera;
          break;
        }
      }
      primary ??= probeReport.cameras.isNotEmpty
          ? probeReport.cameras.first
          : null;

      final primaryCam = primary;

      // Lane 3: selected primary camera id nonblank and exists in probe cameras
      lane3Pass =
          primaryCam != null &&
          primaryCam.cameraId.trim().isNotEmpty &&
          probeReport.cameras.any((c) => c.cameraId == primaryCam.cameraId);
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_H_SMOKE_LANE_3: pass=$lane3Pass primaryCameraId=${primaryCam?.cameraId} lensFacing=${primaryCam?.lensFacing}',
      );

      // 3. Execute Camera2 Open/Close Smoke
      if (lane1Pass && lane2Pass && lane3Pass) {
        smokeReport =
            await VGCamera2OpenCloseSmokeReport.runAndroidCamera2OpenCloseSmoke(
              cameraId: primaryCam.cameraId,
              timeout: const Duration(seconds: 8),
            ).timeout(const Duration(seconds: 20));

        // Lane 4: open/close report success true
        lane4Pass = smokeReport.success == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_H_SMOKE_LANE_4: pass=$lane4Pass success=${smokeReport.success}',
        );

        // Lane 5: report.hasCameraPermission true
        lane5Pass = smokeReport.hasCameraPermission == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_H_SMOKE_LANE_5: pass=$lane5Pass hasCameraPermission=${smokeReport.hasCameraPermission}',
        );

        // Lane 6: report.attemptedOpen true
        lane6Pass = smokeReport.attemptedOpen == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_H_SMOKE_LANE_6: pass=$lane6Pass attemptedOpen=${smokeReport.attemptedOpen}',
        );

        // Lane 7: report.opened true and events contains onOpened
        lane7Pass =
            smokeReport.opened == true &&
            smokeReport.events.contains('onOpened');
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_H_SMOKE_LANE_7: pass=$lane7Pass opened=${smokeReport.opened} events=${smokeReport.events}',
        );

        // Lane 8: report.closed true and events contains onClosed
        lane8Pass =
            smokeReport.closed == true &&
            smokeReport.events.contains('onClosed');
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_H_SMOKE_LANE_8: pass=$lane8Pass closed=${smokeReport.closed} events=${smokeReport.events}',
        );

        // Lane 9: report.decision == openedAndClosed, reasons empty, cameraId equals selected id
        lane9Pass =
            smokeReport.decision ==
                VGCamera2OpenCloseSmokeDecision.openedAndClosed &&
            smokeReport.reasons.isEmpty &&
            smokeReport.cameraId == primaryCam.cameraId;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_H_SMOKE_LANE_9: pass=$lane9Pass decision=${smokeReport.decision.name} reasons=${smokeReport.reasons} cameraId=${smokeReport.cameraId}',
        );

        // Lane 10: getters/toMap coherent (isOpenedAndClosed, isAttempted, isClosed, and map fields match)
        final map = smokeReport.toMap();
        gettersCoherent =
            smokeReport.isOpenedAndClosed ==
                (smokeReport.decision ==
                    VGCamera2OpenCloseSmokeDecision.openedAndClosed) &&
            smokeReport.isPermissionRequired ==
                (smokeReport.decision ==
                    VGCamera2OpenCloseSmokeDecision.permissionRequired) &&
            smokeReport.isAttempted == smokeReport.attemptedOpen &&
            smokeReport.isClosed == smokeReport.closed;

        mapMatches =
            map['success'] == smokeReport.success &&
            map['apiLevel'] == smokeReport.apiLevel &&
            map['hasCameraPermission'] == smokeReport.hasCameraPermission &&
            map['attemptedOpen'] == smokeReport.attemptedOpen &&
            map['opened'] == smokeReport.opened &&
            map['closed'] == smokeReport.closed &&
            map['cameraId'] == smokeReport.cameraId &&
            map['selectedLensFacing'] == smokeReport.selectedLensFacing &&
            map['decision'] == smokeReport.decision.name &&
            listEquals(map['reasons'] as List?, smokeReport.reasons) &&
            listEquals(map['events'] as List?, smokeReport.events) &&
            mapEquals(
              map['diagnostics'] as Map<String, Object?>?,
              smokeReport.diagnostics,
            ) &&
            map['durationMs'] == smokeReport.durationMs;

        lane10Pass = gettersCoherent && mapMatches;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_H_SMOKE_LANE_10: pass=$lane10Pass gettersCoherent=$gettersCoherent mapMatches=$mapMatches',
        );
      }
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Camera2 Open/Close Smoke exceeded timeout: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_H_OPEN_CLOSE_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_H_OPEN_CLOSE_SMOKE_ERROR: $topLevelError',
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
          lane8Pass &&
          lane9Pass &&
          lane10Pass &&
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2OpenCloseSmokeHarness',
        'phase': 'Phase 3-Unit H',
        'slice':
            'Phase 3-Unit H — Single-Camera Open/Close Lifecycle Smoke Foundation',
        'target': 'android_physical',
        'pass': allPass,
        'lanes': <String, dynamic>{
          'lane1_probeSuccessApiLevelGte21CameraCountGte1': {
            'pass': lane1Pass,
            'success': probeReport?.success,
            'apiLevel': probeReport?.apiLevel,
            'cameraCount': probeReport?.cameraCount,
            'camerasLength': probeReport?.cameras.length,
          },
          'lane2_probeHasCameraPermissionTrue': {
            'pass': lane2Pass,
            'hasCameraPermission': probeReport?.hasCameraPermission,
          },
          'lane3_primaryCameraIdSelectedAndExists': {
            'pass': lane3Pass,
            'primaryCameraId': primary?.cameraId,
            'lensFacing': primary?.lensFacing,
          },
          'lane4_smokeReportSuccessTrue': {
            'pass': lane4Pass,
            'success': smokeReport?.success,
          },
          'lane5_smokeReportHasCameraPermissionTrue': {
            'pass': lane5Pass,
            'hasCameraPermission': smokeReport?.hasCameraPermission,
          },
          'lane6_smokeReportAttemptedOpenTrue': {
            'pass': lane6Pass,
            'attemptedOpen': smokeReport?.attemptedOpen,
          },
          'lane7_smokeReportOpenedAndEventsContainOnOpened': {
            'pass': lane7Pass,
            'opened': smokeReport?.opened,
            'events': smokeReport?.events,
          },
          'lane8_smokeReportClosedAndEventsContainOnClosed': {
            'pass': lane8Pass,
            'closed': smokeReport?.closed,
            'events': smokeReport?.events,
          },
          'lane9_smokeReportDecisionOpenedAndClosedReasonsEmptyCameraIdMatches':
              {
                'pass': lane9Pass,
                'decision': smokeReport?.decision.name,
                'reasons': smokeReport?.reasons,
                'cameraId': smokeReport?.cameraId,
              },
          'lane10_smokeReportGettersAndToMapCoherent': {
            'pass': lane10Pass,
            'gettersCoherent': gettersCoherent,
            'mapMatches': mapMatches,
          },
        },
        'probeReport': probeReport?.toMap(),
        'smokeReport': smokeReport?.toMap(),
        'error': topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_H_OPEN_CLOSE_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_H_OPEN_CLOSE_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_H_OPEN_CLOSE_PHYSICAL_FAIL',
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
