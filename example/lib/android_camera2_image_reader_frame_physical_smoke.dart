// android_camera2_image_reader_frame_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit I: Android Camera2 Single-Camera
// ImageReader Frame Smoke Physical Harness.
//
// Proof lanes:
//   Lane 1: probe success true, apiLevel >= 24, cameraCount >= 1, cameras not empty.
//   Lane 2: probe hasCameraPermission true, proving adb grant path active with no permission UI.
//   Lane 3: selected primary camera id nonblank and exists in probe cameras.
//   Lane 4: frame smoke report success true.
//   Lane 5: report.hasCameraPermission true and attemptedOpen true.
//   Lane 6: report.opened true and events contains onOpened.
//   Lane 7: report.sessionConfigured true and events contains onConfigured.
//   Lane 8: report.repeatingStarted true and events contains repeatingRequestStarted.
//   Lane 9: report.frameReceived true, imageClosed true, events contains onImageAvailable, frameTimestampNs non-null, framePlaneCount >= 1.
//   Lane 10: report.sessionClosed true, deviceClosed true, imageReaderClosed true, and isCleanedUp true.
//   Lane 11: report.decision == frameCaptured, reasons empty, cameraId equals selected id, imageFormatName == YUV_420_888, selectedWidth/selectedHeight > 0 and <= 640/480 when the device offers a fitting size.
//   Lane 12: getters/toMap coherent (isFrameCaptured, isAttempted, isCleanedUp, map fields match).

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2ImageReaderFramePhysicalSmokeApp());
}

class AndroidCamera2ImageReaderFramePhysicalSmokeApp extends StatefulWidget {
  const AndroidCamera2ImageReaderFramePhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2ImageReaderFramePhysicalSmokeApp> createState() =>
      _AndroidCamera2ImageReaderFramePhysicalSmokeAppState();
}

class _AndroidCamera2ImageReaderFramePhysicalSmokeAppState
    extends State<AndroidCamera2ImageReaderFramePhysicalSmokeApp> {
  String _status = 'Initializing Camera2 ImageReader Frame Physical Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_I_IMAGE_READER_FRAME_SMOKE_START');
    String? topLevelError;
    VGCameraHardwareCapabilityReport? probeReport;
    VGCameraHardwareDeviceCapability? primary;
    VGCamera2ImageReaderFrameSmokeReport? smokeReport;

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
    var gettersCoherent = false;
    var mapMatches = false;

    try {
      // 0. Wait 5 seconds before probing/running to allow grant runner to grant CAMERA after install/start
      await Future<void>.delayed(const Duration(seconds: 5));

      // 1. Probe Android Camera2 capabilities
      probeReport =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities()
              .timeout(const Duration(seconds: 15));

      // Lane 1: probe success true, apiLevel >= 24, cameraCount >= 1, cameras not empty
      lane1Pass =
          probeReport.success == true &&
          probeReport.apiLevel >= 24 &&
          probeReport.cameraCount >= 1 &&
          probeReport.cameras.isNotEmpty;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_I_SMOKE_LANE_1: pass=$lane1Pass success=${probeReport.success} apiLevel=${probeReport.apiLevel} cameraCount=${probeReport.cameraCount} camerasLength=${probeReport.cameras.length}',
      );

      // Lane 2: probe hasCameraPermission true, proving adb grant path active with no permission UI
      lane2Pass = probeReport.hasCameraPermission == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_I_SMOKE_LANE_2: pass=$lane2Pass hasCameraPermission=${probeReport.hasCameraPermission}',
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
        'ANDROID_CAMERA_PHASE3_UNIT_I_SMOKE_LANE_3: pass=$lane3Pass primaryCameraId=${primaryCam?.cameraId} lensFacing=${primaryCam?.lensFacing}',
      );

      // 3. Execute Camera2 ImageReader Frame Smoke
      if (lane1Pass && lane2Pass && lane3Pass) {
        smokeReport =
            await VGCamera2ImageReaderFrameSmokeReport.runAndroidCamera2ImageReaderFrameSmoke(
              cameraId: primaryCam.cameraId,
              timeout: const Duration(seconds: 10),
              maxWidth: 640,
              maxHeight: 480,
            ).timeout(const Duration(seconds: 30));

        // Lane 4: frame smoke report success true
        lane4Pass = smokeReport.success == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_I_SMOKE_LANE_4: pass=$lane4Pass success=${smokeReport.success}',
        );

        // Lane 5: report.hasCameraPermission true and attemptedOpen true
        lane5Pass =
            smokeReport.hasCameraPermission == true &&
            smokeReport.attemptedOpen == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_I_SMOKE_LANE_5: pass=$lane5Pass hasCameraPermission=${smokeReport.hasCameraPermission} attemptedOpen=${smokeReport.attemptedOpen}',
        );

        // Lane 6: report.opened true and events contains onOpened
        lane6Pass =
            smokeReport.opened == true &&
            smokeReport.events.contains('onOpened');
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_I_SMOKE_LANE_6: pass=$lane6Pass opened=${smokeReport.opened} events=${smokeReport.events}',
        );

        // Lane 7: report.sessionConfigured true and events contains onConfigured
        lane7Pass =
            smokeReport.sessionConfigured == true &&
            smokeReport.events.contains('onConfigured');
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_I_SMOKE_LANE_7: pass=$lane7Pass sessionConfigured=${smokeReport.sessionConfigured} events=${smokeReport.events}',
        );

        // Lane 8: report.repeatingStarted true and events contains repeatingRequestStarted
        lane8Pass =
            smokeReport.repeatingStarted == true &&
            smokeReport.events.contains('repeatingRequestStarted');
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_I_SMOKE_LANE_8: pass=$lane8Pass repeatingStarted=${smokeReport.repeatingStarted} events=${smokeReport.events}',
        );

        // Lane 9: report.frameReceived true, imageClosed true, events contains onImageAvailable, frameTimestampNs non-null, framePlaneCount >= 1
        lane9Pass =
            smokeReport.frameReceived == true &&
            smokeReport.imageClosed == true &&
            smokeReport.events.contains('onImageAvailable') &&
            smokeReport.frameTimestampNs != null &&
            smokeReport.framePlaneCount != null &&
            smokeReport.framePlaneCount! >= 1;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_I_SMOKE_LANE_9: pass=$lane9Pass frameReceived=${smokeReport.frameReceived} imageClosed=${smokeReport.imageClosed} timestampNs=${smokeReport.frameTimestampNs} planeCount=${smokeReport.framePlaneCount} events=${smokeReport.events}',
        );

        // Lane 10: report.sessionClosed true, deviceClosed true, imageReaderClosed true, and isCleanedUp true
        lane10Pass =
            smokeReport.sessionClosed == true &&
            smokeReport.deviceClosed == true &&
            smokeReport.imageReaderClosed == true &&
            smokeReport.isCleanedUp == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_I_SMOKE_LANE_10: pass=$lane10Pass sessionClosed=${smokeReport.sessionClosed} deviceClosed=${smokeReport.deviceClosed} imageReaderClosed=${smokeReport.imageReaderClosed} isCleanedUp=${smokeReport.isCleanedUp}',
        );

        // Lane 11: report.decision == frameCaptured, reasons empty, cameraId equals selected id, imageFormatName == YUV_420_888, selectedWidth/selectedHeight > 0 and <= 640/480 when the device offers a fitting size
        lane11Pass =
            smokeReport.decision ==
                VGCamera2ImageReaderFrameSmokeDecision.frameCaptured &&
            smokeReport.reasons.isEmpty &&
            smokeReport.cameraId == primaryCam.cameraId &&
            smokeReport.imageFormatName == 'YUV_420_888' &&
            smokeReport.selectedWidth > 0 &&
            smokeReport.selectedHeight > 0 &&
            smokeReport.selectedWidth <= 640 &&
            smokeReport.selectedHeight <= 480;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_I_SMOKE_LANE_11: pass=$lane11Pass decision=${smokeReport.decision.name} reasons=${smokeReport.reasons} cameraId=${smokeReport.cameraId} format=${smokeReport.imageFormatName} width=${smokeReport.selectedWidth} height=${smokeReport.selectedHeight}',
        );

        // Lane 12: getters/toMap coherent (isFrameCaptured, isAttempted, isCleanedUp, map fields match)
        final map = smokeReport.toMap();
        gettersCoherent =
            smokeReport.isFrameCaptured ==
                (smokeReport.decision ==
                    VGCamera2ImageReaderFrameSmokeDecision.frameCaptured) &&
            smokeReport.isPermissionRequired ==
                (smokeReport.decision ==
                    VGCamera2ImageReaderFrameSmokeDecision
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
            map['framePlaneCount'] == smokeReport.framePlaneCount &&
            map['decision'] == smokeReport.decision.name &&
            listEquals(map['reasons'] as List?, smokeReport.reasons) &&
            listEquals(map['events'] as List?, smokeReport.events) &&
            mapEquals(
              map['diagnostics'] as Map<String, Object?>?,
              smokeReport.diagnostics,
            ) &&
            map['durationMs'] == smokeReport.durationMs;

        lane12Pass = gettersCoherent && mapMatches;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_I_SMOKE_LANE_12: pass=$lane12Pass gettersCoherent=$gettersCoherent mapMatches=$mapMatches',
        );
      }
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Camera2 ImageReader Frame Smoke exceeded timeout: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_I_IMAGE_READER_FRAME_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_I_IMAGE_READER_FRAME_SMOKE_ERROR: $topLevelError',
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
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2ImageReaderFrameSmokeHarness',
        'phase': 'Phase 3-Unit I',
        'slice':
            'Phase 3-Unit I — Android Camera2 Single-Camera ImageReader Frame Smoke Foundation',
        'target': 'android_physical',
        'pass': allPass,
        'lanes': <String, dynamic>{
          'lane1_probeSuccessApiLevelGte24CameraCountGte1': {
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
          'lane9_smokeReportFrameReceivedImageClosedFrameTimestampPlaneCountGte1':
              {
                'pass': lane9Pass,
                'frameReceived': smokeReport?.frameReceived,
                'imageClosed': smokeReport?.imageClosed,
                'frameTimestampNs': smokeReport?.frameTimestampNs,
                'framePlaneCount': smokeReport?.framePlaneCount,
                'events': smokeReport?.events,
              },
          'lane10_smokeReportSessionDeviceReaderClosedAndIsCleanedUpTrue': {
            'pass': lane10Pass,
            'sessionClosed': smokeReport?.sessionClosed,
            'deviceClosed': smokeReport?.deviceClosed,
            'imageReaderClosed': smokeReport?.imageReaderClosed,
            'isCleanedUp': smokeReport?.isCleanedUp,
          },
          'lane11_smokeReportDecisionFrameCapturedReasonsEmptyCameraIdFormatDimensionsMatch':
              {
                'pass': lane11Pass,
                'decision': smokeReport?.decision.name,
                'reasons': smokeReport?.reasons,
                'cameraId': smokeReport?.cameraId,
                'imageFormatName': smokeReport?.imageFormatName,
                'selectedWidth': smokeReport?.selectedWidth,
                'selectedHeight': smokeReport?.selectedHeight,
              },
          'lane12_smokeReportGettersAndToMapCoherent': {
            'pass': lane12Pass,
            'gettersCoherent': gettersCoherent,
            'mapMatches': mapMatches,
          },
        },
        'probeReport': probeReport?.toMap(),
        'smokeReport': smokeReport?.toMap(),
        'error': topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_I_IMAGE_READER_FRAME_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_I_IMAGE_READER_FRAME_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_I_IMAGE_READER_FRAME_PHYSICAL_FAIL',
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
