// android_camera2_hardware_buffer_frame_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit J: Android Camera2 Single-Camera
// PRIVATE ImageReader HardwareBuffer Frame Smoke Physical Harness.
//
// Proof lanes:
//   Lane 1: probe success true, apiLevel >= 29, cameraCount >= 1, cameras not empty.
//   Lane 2: probe hasCameraPermission true, proving adb grant path active with no permission UI.
//   Lane 3: selected primary camera id nonblank and exists in probe cameras.
//   Lane 4: smoke report success true.
//   Lane 5: report.hasCameraPermission true and attemptedOpen true.
//   Lane 6: report.opened true and events contains onOpened.
//   Lane 7: report.sessionConfigured true and events contains onConfigured.
//   Lane 8: report.repeatingStarted true and events contains repeatingRequestStarted.
//   Lane 9: report.frameReceived true, frameTimestampNs non-null, imageClosed true, events contains onImageAvailable.
//   Lane 10: report.hardwareBufferAvailable true, hardwareBufferClosed true, hardwareBufferWidth == selectedWidth, hardwareBufferHeight == selectedHeight, hardwareBufferFormat non-null, hardwareBufferLayers >= 1, hardwareBufferUsage non-null and > 0.
//   Lane 11: on API >= 33, syncFenceAwaited true and syncFenceClosed true; below API 33, both false is acceptable.
//   Lane 12: report.sessionClosed true, deviceClosed true, imageReaderClosed true, and isCleanedUp true.
//   Lane 13: report.decision == frameCaptured, reasons empty, cameraId equals selected id, imageFormatName == PRIVATE, selectedWidth/selectedHeight > 0 and <= 640/480.
//   Lane 14: getters/toMap coherent (isFrameCaptured, isAttempted, isCleanedUp, map fields match).

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2HardwareBufferFramePhysicalSmokeApp());
}

class AndroidCamera2HardwareBufferFramePhysicalSmokeApp extends StatefulWidget {
  const AndroidCamera2HardwareBufferFramePhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2HardwareBufferFramePhysicalSmokeApp> createState() =>
      _AndroidCamera2HardwareBufferFramePhysicalSmokeAppState();
}

class _AndroidCamera2HardwareBufferFramePhysicalSmokeAppState
    extends State<AndroidCamera2HardwareBufferFramePhysicalSmokeApp> {
  String _status =
      'Initializing Camera2 PRIVATE HardwareBuffer Frame Physical Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_J_HARDWARE_BUFFER_FRAME_SMOKE_START');
    String? topLevelError;
    VGCameraHardwareCapabilityReport? probeReport;
    VGCameraHardwareDeviceCapability? primary;
    VGCamera2HardwareBufferFrameSmokeReport? smokeReport;

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
    var gettersCoherent = false;
    var mapMatches = false;

    try {
      // 0. Wait 5 seconds before probing/running to allow grant runner to grant CAMERA after install/start
      await Future<void>.delayed(const Duration(seconds: 5));

      // 1. Probe Android Camera2 capabilities
      probeReport =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities()
              .timeout(const Duration(seconds: 15));

      // Lane 1: probe success true, apiLevel >= 29, cameraCount >= 1, cameras not empty
      lane1Pass =
          probeReport.success == true &&
          probeReport.apiLevel >= 29 &&
          probeReport.cameraCount >= 1 &&
          probeReport.cameras.isNotEmpty;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_J_SMOKE_LANE_1: pass=$lane1Pass success=${probeReport.success} apiLevel=${probeReport.apiLevel} cameraCount=${probeReport.cameraCount} camerasLength=${probeReport.cameras.length}',
      );

      // Lane 2: probe hasCameraPermission true, proving adb grant path active with no permission UI
      lane2Pass = probeReport.hasCameraPermission == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_J_SMOKE_LANE_2: pass=$lane2Pass hasCameraPermission=${probeReport.hasCameraPermission}',
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
        'ANDROID_CAMERA_PHASE3_UNIT_J_SMOKE_LANE_3: pass=$lane3Pass primaryCameraId=${primaryCam?.cameraId} lensFacing=${primaryCam?.lensFacing}',
      );

      // 3. Execute Camera2 PRIVATE ImageReader HardwareBuffer Frame Smoke
      if (lane1Pass && lane2Pass && lane3Pass) {
        smokeReport =
            await VGCamera2HardwareBufferFrameSmokeReport.runAndroidCamera2HardwareBufferFrameSmoke(
              cameraId: primaryCam.cameraId,
              timeout: const Duration(seconds: 10),
              maxWidth: 640,
              maxHeight: 480,
            ).timeout(const Duration(seconds: 30));

        // Lane 4: smoke report success true
        lane4Pass = smokeReport.success == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_J_SMOKE_LANE_4: pass=$lane4Pass success=${smokeReport.success}',
        );

        // Lane 5: report.hasCameraPermission true and attemptedOpen true
        lane5Pass =
            smokeReport.hasCameraPermission == true &&
            smokeReport.attemptedOpen == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_J_SMOKE_LANE_5: pass=$lane5Pass hasCameraPermission=${smokeReport.hasCameraPermission} attemptedOpen=${smokeReport.attemptedOpen}',
        );

        // Lane 6: report.opened true and events contains onOpened
        lane6Pass =
            smokeReport.opened == true &&
            smokeReport.events.contains('onOpened');
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_J_SMOKE_LANE_6: pass=$lane6Pass opened=${smokeReport.opened} events=${smokeReport.events}',
        );

        // Lane 7: report.sessionConfigured true and events contains onConfigured
        lane7Pass =
            smokeReport.sessionConfigured == true &&
            smokeReport.events.contains('onConfigured');
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_J_SMOKE_LANE_7: pass=$lane7Pass sessionConfigured=${smokeReport.sessionConfigured} events=${smokeReport.events}',
        );

        // Lane 8: report.repeatingStarted true and events contains repeatingRequestStarted
        lane8Pass =
            smokeReport.repeatingStarted == true &&
            smokeReport.events.contains('repeatingRequestStarted');
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_J_SMOKE_LANE_8: pass=$lane8Pass repeatingStarted=${smokeReport.repeatingStarted} events=${smokeReport.events}',
        );

        // Lane 9: report.frameReceived true, frameTimestampNs non-null, imageClosed true, events contains onImageAvailable
        lane9Pass =
            smokeReport.frameReceived == true &&
            smokeReport.frameTimestampNs != null &&
            smokeReport.imageClosed == true &&
            smokeReport.events.contains('onImageAvailable');
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_J_SMOKE_LANE_9: pass=$lane9Pass frameReceived=${smokeReport.frameReceived} timestampNs=${smokeReport.frameTimestampNs} imageClosed=${smokeReport.imageClosed} events=${smokeReport.events}',
        );

        // Lane 10: report.hardwareBufferAvailable true, hardwareBufferClosed true, hardwareBufferWidth == selectedWidth, hardwareBufferHeight == selectedHeight, hardwareBufferFormat non-null, hardwareBufferLayers >= 1, hardwareBufferUsage non-null and > 0
        lane10Pass =
            smokeReport.hardwareBufferAvailable == true &&
            smokeReport.hardwareBufferClosed == true &&
            smokeReport.hardwareBufferWidth == smokeReport.selectedWidth &&
            smokeReport.hardwareBufferHeight == smokeReport.selectedHeight &&
            smokeReport.hardwareBufferFormat != null &&
            smokeReport.hardwareBufferLayers != null &&
            smokeReport.hardwareBufferLayers! >= 1 &&
            smokeReport.hardwareBufferUsage != null &&
            smokeReport.hardwareBufferUsage! > 0;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_J_SMOKE_LANE_10: pass=$lane10Pass hbAvailable=${smokeReport.hardwareBufferAvailable} hbClosed=${smokeReport.hardwareBufferClosed} hbWidth=${smokeReport.hardwareBufferWidth} hbHeight=${smokeReport.hardwareBufferHeight} hbFormat=${smokeReport.hardwareBufferFormat} hbLayers=${smokeReport.hardwareBufferLayers} hbUsage=${smokeReport.hardwareBufferUsage}',
        );

        // Lane 11: on API >= 33, syncFenceAwaited true and syncFenceClosed true; below API 33, both false is acceptable
        lane11Pass = (smokeReport.apiLevel >= 33)
            ? (smokeReport.syncFenceAwaited == true &&
                  smokeReport.syncFenceClosed == true)
            : (smokeReport.syncFenceAwaited == false &&
                  smokeReport.syncFenceClosed == false);
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_J_SMOKE_LANE_11: pass=$lane11Pass apiLevel=${smokeReport.apiLevel} syncFenceAwaited=${smokeReport.syncFenceAwaited} syncFenceClosed=${smokeReport.syncFenceClosed}',
        );

        // Lane 12: report.sessionClosed true, deviceClosed true, imageReaderClosed true, and isCleanedUp true
        lane12Pass =
            smokeReport.sessionClosed == true &&
            smokeReport.deviceClosed == true &&
            smokeReport.imageReaderClosed == true &&
            smokeReport.isCleanedUp == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_J_SMOKE_LANE_12: pass=$lane12Pass sessionClosed=${smokeReport.sessionClosed} deviceClosed=${smokeReport.deviceClosed} imageReaderClosed=${smokeReport.imageReaderClosed} isCleanedUp=${smokeReport.isCleanedUp}',
        );

        // Lane 13: report.decision == frameCaptured, reasons empty, cameraId equals selected id, imageFormatName == PRIVATE, selectedWidth/selectedHeight > 0 and <= 640/480
        lane13Pass =
            smokeReport.decision ==
                VGCamera2HardwareBufferFrameSmokeDecision.frameCaptured &&
            smokeReport.reasons.isEmpty &&
            smokeReport.cameraId == primaryCam.cameraId &&
            smokeReport.imageFormatName == 'PRIVATE' &&
            smokeReport.selectedWidth > 0 &&
            smokeReport.selectedHeight > 0 &&
            smokeReport.selectedWidth <= 640 &&
            smokeReport.selectedHeight <= 480;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_J_SMOKE_LANE_13: pass=$lane13Pass decision=${smokeReport.decision.name} reasons=${smokeReport.reasons} cameraId=${smokeReport.cameraId} format=${smokeReport.imageFormatName} width=${smokeReport.selectedWidth} height=${smokeReport.selectedHeight}',
        );

        // Lane 14: getters/toMap coherent (isFrameCaptured, isAttempted, isCleanedUp, map fields match)
        final map = smokeReport.toMap();
        gettersCoherent =
            smokeReport.isFrameCaptured ==
                (smokeReport.decision ==
                    VGCamera2HardwareBufferFrameSmokeDecision.frameCaptured) &&
            smokeReport.isPermissionRequired ==
                (smokeReport.decision ==
                    VGCamera2HardwareBufferFrameSmokeDecision
                        .permissionRequired) &&
            smokeReport.isAttempted == smokeReport.attemptedOpen &&
            smokeReport.isCleanedUp ==
                (smokeReport.sessionClosed &&
                    smokeReport.deviceClosed &&
                    smokeReport.imageReaderClosed);

        mapMatches =
            map['success'] == smokeReport.success &&
            map['apiLevel'] == smokeReport.apiLevel &&
            map['hasCameraPermission'] == smokeReport.hasCameraPermission &&
            map['attemptedOpen'] == smokeReport.attemptedOpen &&
            map['opened'] == smokeReport.opened &&
            map['sessionConfigured'] == smokeReport.sessionConfigured &&
            map['repeatingStarted'] == smokeReport.repeatingStarted &&
            map['frameReceived'] == smokeReport.frameReceived &&
            map['hardwareBufferAvailable'] ==
                smokeReport.hardwareBufferAvailable &&
            map['hardwareBufferClosed'] == smokeReport.hardwareBufferClosed &&
            map['imageClosed'] == smokeReport.imageClosed &&
            map['sessionClosed'] == smokeReport.sessionClosed &&
            map['deviceClosed'] == smokeReport.deviceClosed &&
            map['imageReaderClosed'] == smokeReport.imageReaderClosed &&
            map['cameraId'] == smokeReport.cameraId &&
            map['selectedLensFacing'] == smokeReport.selectedLensFacing &&
            map['selectedWidth'] == smokeReport.selectedWidth &&
            map['selectedHeight'] == smokeReport.selectedHeight &&
            map['imageFormatName'] == smokeReport.imageFormatName &&
            map['frameTimestampNs'] == smokeReport.frameTimestampNs &&
            map['hardwareBufferWidth'] == smokeReport.hardwareBufferWidth &&
            map['hardwareBufferHeight'] == smokeReport.hardwareBufferHeight &&
            map['hardwareBufferFormat'] == smokeReport.hardwareBufferFormat &&
            map['hardwareBufferLayers'] == smokeReport.hardwareBufferLayers &&
            map['hardwareBufferUsage'] == smokeReport.hardwareBufferUsage &&
            map['syncFenceAwaited'] == smokeReport.syncFenceAwaited &&
            map['syncFenceClosed'] == smokeReport.syncFenceClosed &&
            map['decision'] == smokeReport.decision.name &&
            listEquals(map['reasons'] as List?, smokeReport.reasons) &&
            listEquals(map['events'] as List?, smokeReport.events) &&
            mapEquals(
              map['diagnostics'] as Map<String, Object?>?,
              smokeReport.diagnostics,
            ) &&
            map['durationMs'] == smokeReport.durationMs;

        lane14Pass = gettersCoherent && mapMatches;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_J_SMOKE_LANE_14: pass=$lane14Pass gettersCoherent=$gettersCoherent mapMatches=$mapMatches',
        );
      }
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Camera2 HardwareBuffer Frame Smoke exceeded timeout: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_J_HARDWARE_BUFFER_FRAME_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_J_HARDWARE_BUFFER_FRAME_SMOKE_ERROR: $topLevelError',
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
          lane11Pass &&
          lane12Pass &&
          lane13Pass &&
          lane14Pass &&
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2HardwareBufferFrameSmokeHarness',
        'phase': 'Phase 3-Unit J',
        'slice':
            'Phase 3-Unit J — Android Camera2 Single-Camera PRIVATE ImageReader HardwareBuffer Frame Smoke Foundation',
        'target': 'android_physical',
        'pass': allPass,
        'lanes': <String, dynamic>{
          'lane1_probeSuccessApiLevelGte29CameraCountGte1': {
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
          'lane5_smokeReportHasCameraPermissionAndAttemptedOpenTrue': {
            'pass': lane5Pass,
            'hasCameraPermission': smokeReport?.hasCameraPermission,
            'attemptedOpen': smokeReport?.attemptedOpen,
          },
          'lane6_smokeReportOpenedAndEventsContainOnOpened': {
            'pass': lane6Pass,
            'opened': smokeReport?.opened,
            'events': smokeReport?.events,
          },
          'lane7_smokeReportSessionConfiguredAndEventsContainOnConfigured': {
            'pass': lane7Pass,
            'sessionConfigured': smokeReport?.sessionConfigured,
            'events': smokeReport?.events,
          },
          'lane8_smokeReportRepeatingStartedAndEventsContainRepeatingStarted': {
            'pass': lane8Pass,
            'repeatingStarted': smokeReport?.repeatingStarted,
            'events': smokeReport?.events,
          },
          'lane9_smokeReportFrameReceivedImageClosedTimestampEventsContainOnImageAvailable':
              {
                'pass': lane9Pass,
                'frameReceived': smokeReport?.frameReceived,
                'frameTimestampNs': smokeReport?.frameTimestampNs,
                'imageClosed': smokeReport?.imageClosed,
                'events': smokeReport?.events,
              },
          'lane10_smokeReportHardwareBufferAvailableClosedWidthHeightFormatLayersUsage':
              {
                'pass': lane10Pass,
                'hardwareBufferAvailable': smokeReport?.hardwareBufferAvailable,
                'hardwareBufferClosed': smokeReport?.hardwareBufferClosed,
                'hardwareBufferWidth': smokeReport?.hardwareBufferWidth,
                'hardwareBufferHeight': smokeReport?.hardwareBufferHeight,
                'hardwareBufferFormat': smokeReport?.hardwareBufferFormat,
                'hardwareBufferLayers': smokeReport?.hardwareBufferLayers,
                'hardwareBufferUsage': smokeReport?.hardwareBufferUsage,
              },
          'lane11_smokeReportSyncFenceAwaitedClosedOnApi33OrValidBelowApi33': {
            'pass': lane11Pass,
            'apiLevel': smokeReport?.apiLevel,
            'syncFenceAwaited': smokeReport?.syncFenceAwaited,
            'syncFenceClosed': smokeReport?.syncFenceClosed,
          },
          'lane12_smokeReportSessionDeviceReaderClosedAndIsCleanedUpTrue': {
            'pass': lane12Pass,
            'sessionClosed': smokeReport?.sessionClosed,
            'deviceClosed': smokeReport?.deviceClosed,
            'imageReaderClosed': smokeReport?.imageReaderClosed,
            'isCleanedUp': smokeReport?.isCleanedUp,
          },
          'lane13_smokeReportDecisionFrameCapturedReasonsEmptyCameraIdFormatDimensionsMatch':
              {
                'pass': lane13Pass,
                'decision': smokeReport?.decision.name,
                'reasons': smokeReport?.reasons,
                'cameraId': smokeReport?.cameraId,
                'imageFormatName': smokeReport?.imageFormatName,
                'selectedWidth': smokeReport?.selectedWidth,
                'selectedHeight': smokeReport?.selectedHeight,
              },
          'lane14_smokeReportGettersAndToMapCoherent': {
            'pass': lane14Pass,
            'gettersCoherent': gettersCoherent,
            'mapMatches': mapMatches,
          },
        },
        'probeReport': probeReport?.toMap(),
        'smokeReport': smokeReport?.toMap(),
        'error': topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_J_HARDWARE_BUFFER_FRAME_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_J_HARDWARE_BUFFER_FRAME_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_J_HARDWARE_BUFFER_FRAME_PHYSICAL_FAIL',
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
