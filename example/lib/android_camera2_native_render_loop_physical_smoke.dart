// android_camera2_native_render_loop_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit L: Android Camera2 PRIVATE
// ImageReader HardwareBuffer Multi-Frame Native Render Loop Smoke Physical Harness.
//
// Proof lanes:
//   Lane 1: probe success true, apiLevel >= 29, cameraCount >= 1, cameras nonempty.
//   Lane 2: probe hasCameraPermission true, proving adb grant path active with no permission UI.
//   Lane 3: selected primary camera id nonblank and exists in probe cameras, prefer back.
//   Lane 4: smoke report success true.
//   Lane 5: report.hasCameraPermission true, attemptedOpen/opened/sessionConfigured/repeatingStarted true.
//   Lane 6: targetFrameCount == 5, renderedFrames == 5, completedTargetFrames true.
//   Lane 7: nativeRenderRawFrames length == 5, every raw starts 'status=PASS;', finalNativeRenderRaw starts 'status=PASS;', final raw includes 'renderedFrames=5'.
//   Lane 8: hardwareBufferFrameCount >= 5, hardwareBufferClosedCount >= 5, imageClosedCount >= 5.
//   Lane 9: on API >= 33, syncFenceAwaitedCount >= 5 and syncFenceClosedCount >= 5; below API 33, both zero acceptable.
//   Lane 10: firstFrameTimestampNs and lastFrameTimestampNs non-null, last > first, monotonicFrameTimestamps true.
//   Lane 11: report.nativeSessionCreated true and nativeSessionDestroyed true.
//   Lane 12: sessionClosed/deviceClosed/imageReaderClosed/outputSurfaceReleased/surfaceTextureReleased/isCleanedUp true.
//   Lane 13: report.decision == nativeRenderLoopPassed and reasons empty.
//   Lane 14: imageFormatName == 'PRIVATE', cameraId selected, selectedWidth/selectedHeight > 0 and <= 640/480.
//   Lane 15: events include onOpened, onConfigured, repeatingRequestStarted, nativeRenderPassed:renderedFrames=5.
//   Lane 16: getters/toMap coherent.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2NativeRenderLoopPhysicalSmokeApp());
}

class AndroidCamera2NativeRenderLoopPhysicalSmokeApp extends StatefulWidget {
  const AndroidCamera2NativeRenderLoopPhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2NativeRenderLoopPhysicalSmokeApp> createState() =>
      _AndroidCamera2NativeRenderLoopPhysicalSmokeAppState();
}

class _AndroidCamera2NativeRenderLoopPhysicalSmokeAppState
    extends State<AndroidCamera2NativeRenderLoopPhysicalSmokeApp> {
  String _status =
      'Initializing Camera2 PRIVATE HardwareBuffer Multi-Frame Native Render Loop Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_L_NATIVE_RENDER_LOOP_SMOKE_START');
    String? topLevelError;
    VGCameraHardwareCapabilityReport? probeReport;
    VGCameraHardwareDeviceCapability? primary;
    VGCamera2NativeRenderLoopSmokeReport? smokeReport;

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
    var gettersCoherent = false;
    var mapMatches = false;

    try {
      // 0. Wait 5 seconds before probing/running to allow grant runner to grant CAMERA after install/start
      await Future<void>.delayed(const Duration(seconds: 5));

      // 1. Probe Android Camera2 capabilities
      probeReport =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities()
              .timeout(const Duration(seconds: 15));

      // Lane 1: api >= 29, probe success true, cameraCount >= 1, cameras nonempty
      lane1Pass =
          probeReport.success == true &&
          probeReport.apiLevel >= 29 &&
          probeReport.cameraCount >= 1 &&
          probeReport.cameras.isNotEmpty;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_1: pass=$lane1Pass success=${probeReport.success} apiLevel=${probeReport.apiLevel} cameraCount=${probeReport.cameraCount} camerasLength=${probeReport.cameras.length}',
      );

      // Lane 2: CAMERA permission true
      lane2Pass = probeReport.hasCameraPermission == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_2: pass=$lane2Pass hasCameraPermission=${probeReport.hasCameraPermission}',
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

      // Lane 3: selected camera id nonblank and present, prefer back
      lane3Pass =
          primaryCam != null &&
          primaryCam.cameraId.trim().isNotEmpty &&
          probeReport.cameras.any((c) => c.cameraId == primaryCam.cameraId);
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_3: pass=$lane3Pass primaryCameraId=${primaryCam?.cameraId} lensFacing=${primaryCam?.lensFacing}',
      );

      // 3. Execute Camera2 PRIVATE ImageReader HardwareBuffer Multi-Frame Native Render Loop Smoke
      if (lane1Pass && lane2Pass && lane3Pass) {
        smokeReport =
            await VGCamera2NativeRenderLoopSmokeReport.runAndroidCamera2NativeRenderLoopSmoke(
              cameraId: primaryCam.cameraId,
              timeout: const Duration(seconds: 12),
              maxWidth: 640,
              maxHeight: 480,
              frameCount: 5,
            ).timeout(const Duration(seconds: 30));

        // Lane 4: report.success true
        lane4Pass = smokeReport.success == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_4: pass=$lane4Pass success=${smokeReport.success}',
        );

        // Lane 5: report.hasCameraPermission true, attemptedOpen/opened/sessionConfigured/repeatingStarted true
        lane5Pass =
            smokeReport.hasCameraPermission == true &&
            smokeReport.attemptedOpen == true &&
            smokeReport.opened == true &&
            smokeReport.sessionConfigured == true &&
            smokeReport.repeatingStarted == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_5: pass=$lane5Pass hasCameraPermission=${smokeReport.hasCameraPermission} attemptedOpen=${smokeReport.attemptedOpen} opened=${smokeReport.opened} sessionConfigured=${smokeReport.sessionConfigured} repeatingStarted=${smokeReport.repeatingStarted}',
        );

        // Lane 6: targetFrameCount==5, renderedFrames==5, completedTargetFrames true
        lane6Pass =
            smokeReport.targetFrameCount == 5 &&
            smokeReport.renderedFrames == 5 &&
            smokeReport.completedTargetFrames == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_6: pass=$lane6Pass targetFrameCount=${smokeReport.targetFrameCount} renderedFrames=${smokeReport.renderedFrames} completedTargetFrames=${smokeReport.completedTargetFrames}',
        );

        // Lane 7: nativeRenderRawFrames length==5, every raw starts 'status=PASS;', finalNativeRenderRaw starts 'status=PASS;', final raw includes 'renderedFrames=5'
        lane7Pass =
            smokeReport.nativeRenderRawFrames.length == 5 &&
            smokeReport.nativeRenderRawFrames.every(
              (r) => r.startsWith('status=PASS;'),
            ) &&
            smokeReport.finalNativeRenderRaw != null &&
            smokeReport.finalNativeRenderRaw!.startsWith('status=PASS;') &&
            smokeReport.finalNativeRenderRaw!.contains('renderedFrames=5');
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_7: pass=$lane7Pass rawFramesLength=${smokeReport.nativeRenderRawFrames.length} finalNativeRenderRaw=${smokeReport.finalNativeRenderRaw}',
        );

        // Lane 8: hardwareBufferFrameCount>=5, hardwareBufferClosedCount>=5, imageClosedCount>=5
        lane8Pass =
            smokeReport.hardwareBufferFrameCount >= 5 &&
            smokeReport.hardwareBufferClosedCount >= 5 &&
            smokeReport.imageClosedCount >= 5;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_8: pass=$lane8Pass hbFrames=${smokeReport.hardwareBufferFrameCount} hbClosed=${smokeReport.hardwareBufferClosedCount} imgClosed=${smokeReport.imageClosedCount}',
        );

        // Lane 9: API>=33 syncFenceAwaitedCount>=5 and syncFenceClosedCount>=5; below API33 both zero acceptable
        lane9Pass = (smokeReport.apiLevel >= 33)
            ? (smokeReport.syncFenceAwaitedCount >= 5 &&
                  smokeReport.syncFenceClosedCount >= 5)
            : (smokeReport.syncFenceAwaitedCount == 0 &&
                  smokeReport.syncFenceClosedCount == 0);
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_9: pass=$lane9Pass apiLevel=${smokeReport.apiLevel} syncFenceAwaitedCount=${smokeReport.syncFenceAwaitedCount} syncFenceClosedCount=${smokeReport.syncFenceClosedCount}',
        );

        // Lane 10: firstFrameTimestampNs and lastFrameTimestampNs non-null, last > first, monotonicFrameTimestamps true
        lane10Pass =
            smokeReport.firstFrameTimestampNs != null &&
            smokeReport.lastFrameTimestampNs != null &&
            smokeReport.lastFrameTimestampNs! >
                smokeReport.firstFrameTimestampNs! &&
            smokeReport.monotonicFrameTimestamps == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_10: pass=$lane10Pass firstTs=${smokeReport.firstFrameTimestampNs} lastTs=${smokeReport.lastFrameTimestampNs} monotonic=${smokeReport.monotonicFrameTimestamps}',
        );

        // Lane 11: nativeSessionCreated/nativeSessionDestroyed true
        lane11Pass =
            smokeReport.nativeSessionCreated == true &&
            smokeReport.nativeSessionDestroyed == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_11: pass=$lane11Pass nativeSessionCreated=${smokeReport.nativeSessionCreated} nativeSessionDestroyed=${smokeReport.nativeSessionDestroyed}',
        );

        // Lane 12: sessionClosed/deviceClosed/imageReaderClosed/outputSurfaceReleased/surfaceTextureReleased/isCleanedUp true
        lane12Pass =
            smokeReport.sessionClosed == true &&
            smokeReport.deviceClosed == true &&
            smokeReport.imageReaderClosed == true &&
            smokeReport.outputSurfaceReleased == true &&
            smokeReport.surfaceTextureReleased == true &&
            smokeReport.isCleanedUp == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_12: pass=$lane12Pass sessionClosed=${smokeReport.sessionClosed} deviceClosed=${smokeReport.deviceClosed} imageReaderClosed=${smokeReport.imageReaderClosed} outputSurfaceReleased=${smokeReport.outputSurfaceReleased} surfaceTextureReleased=${smokeReport.surfaceTextureReleased} isCleanedUp=${smokeReport.isCleanedUp}',
        );

        // Lane 13: decision nativeRenderLoopPassed and reasons empty
        lane13Pass =
            smokeReport.decision ==
                VGCamera2NativeRenderLoopSmokeDecision.nativeRenderLoopPassed &&
            smokeReport.reasons.isEmpty;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_13: pass=$lane13Pass decision=${smokeReport.decision.name} reasons=${smokeReport.reasons}',
        );

        // Lane 14: imageFormatName PRIVATE, cameraId selected, selectedWidth/selectedHeight >0 and <=640/480
        lane14Pass =
            smokeReport.imageFormatName == 'PRIVATE' &&
            smokeReport.cameraId == primaryCam.cameraId &&
            smokeReport.selectedWidth > 0 &&
            smokeReport.selectedHeight > 0 &&
            smokeReport.selectedWidth <= 640 &&
            smokeReport.selectedHeight <= 480;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_14: pass=$lane14Pass cameraId=${smokeReport.cameraId} format=${smokeReport.imageFormatName} width=${smokeReport.selectedWidth} height=${smokeReport.selectedHeight}',
        );

        // Lane 15: events include onOpened, onConfigured, repeatingRequestStarted, nativeRenderPassed:renderedFrames=5
        lane15Pass =
            smokeReport.events.contains('onOpened') &&
            smokeReport.events.contains('onConfigured') &&
            smokeReport.events.contains('repeatingRequestStarted') &&
            smokeReport.events.contains('nativeRenderPassed:renderedFrames=5');
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_15: pass=$lane15Pass events=${smokeReport.events}',
        );

        // Lane 16: getters/toMap coherent
        final map = smokeReport.toMap();
        gettersCoherent =
            smokeReport.isNativeRenderLoopPassed ==
                (smokeReport.decision ==
                    VGCamera2NativeRenderLoopSmokeDecision
                        .nativeRenderLoopPassed) &&
            smokeReport.isPermissionRequired ==
                (smokeReport.decision ==
                    VGCamera2NativeRenderLoopSmokeDecision
                        .permissionRequired) &&
            smokeReport.isAttempted == smokeReport.attemptedOpen &&
            smokeReport.completedTargetFrames ==
                (smokeReport.renderedFrames >= smokeReport.targetFrameCount) &&
            smokeReport.isCleanedUp ==
                (smokeReport.sessionClosed &&
                    smokeReport.deviceClosed &&
                    smokeReport.imageReaderClosed &&
                    smokeReport.nativeSessionDestroyed &&
                    smokeReport.outputSurfaceReleased &&
                    smokeReport.surfaceTextureReleased);

        mapMatches =
            map['success'] == smokeReport.success &&
            map['apiLevel'] == smokeReport.apiLevel &&
            map['hasCameraPermission'] == smokeReport.hasCameraPermission &&
            map['attemptedOpen'] == smokeReport.attemptedOpen &&
            map['opened'] == smokeReport.opened &&
            map['sessionConfigured'] == smokeReport.sessionConfigured &&
            map['repeatingStarted'] == smokeReport.repeatingStarted &&
            map['cameraId'] == smokeReport.cameraId &&
            map['selectedLensFacing'] == smokeReport.selectedLensFacing &&
            map['selectedWidth'] == smokeReport.selectedWidth &&
            map['selectedHeight'] == smokeReport.selectedHeight &&
            map['imageFormatName'] == smokeReport.imageFormatName &&
            map['targetFrameCount'] == smokeReport.targetFrameCount &&
            map['renderedFrames'] == smokeReport.renderedFrames &&
            map['hardwareBufferFrameCount'] ==
                smokeReport.hardwareBufferFrameCount &&
            map['hardwareBufferClosedCount'] ==
                smokeReport.hardwareBufferClosedCount &&
            map['imageClosedCount'] == smokeReport.imageClosedCount &&
            map['syncFenceAwaitedCount'] == smokeReport.syncFenceAwaitedCount &&
            map['syncFenceClosedCount'] == smokeReport.syncFenceClosedCount &&
            map['firstFrameTimestampNs'] == smokeReport.firstFrameTimestampNs &&
            map['lastFrameTimestampNs'] == smokeReport.lastFrameTimestampNs &&
            map['monotonicFrameTimestamps'] ==
                smokeReport.monotonicFrameTimestamps &&
            listEquals(
              map['nativeRenderRawFrames'] as List?,
              smokeReport.nativeRenderRawFrames,
            ) &&
            map['finalNativeRenderRaw'] == smokeReport.finalNativeRenderRaw &&
            map['sessionClosed'] == smokeReport.sessionClosed &&
            map['deviceClosed'] == smokeReport.deviceClosed &&
            map['imageReaderClosed'] == smokeReport.imageReaderClosed &&
            map['nativeSessionCreated'] == smokeReport.nativeSessionCreated &&
            map['nativeSessionDestroyed'] ==
                smokeReport.nativeSessionDestroyed &&
            map['outputSurfaceReleased'] == smokeReport.outputSurfaceReleased &&
            map['surfaceTextureReleased'] ==
                smokeReport.surfaceTextureReleased &&
            map['decision'] == smokeReport.decision.name &&
            listEquals(map['reasons'] as List?, smokeReport.reasons) &&
            listEquals(map['events'] as List?, smokeReport.events) &&
            mapEquals(
              map['diagnostics'] as Map<String, Object?>?,
              smokeReport.diagnostics,
            ) &&
            map['durationMs'] == smokeReport.durationMs;

        lane16Pass = gettersCoherent && mapMatches;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_L_SMOKE_LANE_16: pass=$lane16Pass gettersCoherent=$gettersCoherent mapMatches=$mapMatches',
        );
      }
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Camera2 Multi-Frame Native Render Loop Smoke exceeded timeout: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_L_NATIVE_RENDER_LOOP_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_L_NATIVE_RENDER_LOOP_SMOKE_ERROR: $topLevelError',
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
          lane15Pass &&
          lane16Pass &&
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2NativeRenderLoopSmokeHarness',
        'phase': 'Phase 3-Unit L',
        'slice':
            'Phase 3-Unit L — Android Camera2 PRIVATE ImageReader HardwareBuffer Multi-Frame Native Render Loop Smoke Foundation',
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
          'lane5_smokeReportHasCameraPermissionAndAttemptedOpenAndStarted': {
            'pass': lane5Pass,
            'hasCameraPermission': smokeReport?.hasCameraPermission,
            'attemptedOpen': smokeReport?.attemptedOpen,
            'opened': smokeReport?.opened,
            'sessionConfigured': smokeReport?.sessionConfigured,
            'repeatingStarted': smokeReport?.repeatingStarted,
          },
          'lane6_targetFrameCount5RenderedFrames5CompletedTargetFrames': {
            'pass': lane6Pass,
            'targetFrameCount': smokeReport?.targetFrameCount,
            'renderedFrames': smokeReport?.renderedFrames,
            'completedTargetFrames': smokeReport?.completedTargetFrames,
          },
          'lane7_nativeRenderRawFrames5AllPassFinalPassContainsRenderedFrames5':
              {
                'pass': lane7Pass,
                'nativeRenderRawFramesLength':
                    smokeReport?.nativeRenderRawFrames.length,
                'finalNativeRenderRaw': smokeReport?.finalNativeRenderRaw,
              },
          'lane8_hardwareBufferAndImageCountsGte5': {
            'pass': lane8Pass,
            'hardwareBufferFrameCount': smokeReport?.hardwareBufferFrameCount,
            'hardwareBufferClosedCount': smokeReport?.hardwareBufferClosedCount,
            'imageClosedCount': smokeReport?.imageClosedCount,
          },
          'lane9_syncFenceAwaitedClosedGte5OnApi33OrZeroBelow': {
            'pass': lane9Pass,
            'apiLevel': smokeReport?.apiLevel,
            'syncFenceAwaitedCount': smokeReport?.syncFenceAwaitedCount,
            'syncFenceClosedCount': smokeReport?.syncFenceClosedCount,
          },
          'lane10_firstAndLastTimestampsNonNullLastGtFirstMonotonic': {
            'pass': lane10Pass,
            'firstFrameTimestampNs': smokeReport?.firstFrameTimestampNs,
            'lastFrameTimestampNs': smokeReport?.lastFrameTimestampNs,
            'monotonicFrameTimestamps': smokeReport?.monotonicFrameTimestamps,
          },
          'lane11_smokeReportNativeSessionCreatedAndDestroyedTrue': {
            'pass': lane11Pass,
            'nativeSessionCreated': smokeReport?.nativeSessionCreated,
            'nativeSessionDestroyed': smokeReport?.nativeSessionDestroyed,
          },
          'lane12_smokeReportSessionDeviceReaderSurfaceTextureClosedAndIsCleanedUpTrue':
              {
                'pass': lane12Pass,
                'sessionClosed': smokeReport?.sessionClosed,
                'deviceClosed': smokeReport?.deviceClosed,
                'imageReaderClosed': smokeReport?.imageReaderClosed,
                'outputSurfaceReleased': smokeReport?.outputSurfaceReleased,
                'surfaceTextureReleased': smokeReport?.surfaceTextureReleased,
                'isCleanedUp': smokeReport?.isCleanedUp,
              },
          'lane13_smokeReportDecisionNativeRenderLoopPassedReasonsEmpty': {
            'pass': lane13Pass,
            'decision': smokeReport?.decision.name,
            'reasons': smokeReport?.reasons,
          },
          'lane14_imageFormatPrivateCameraIdDimensionsMatch': {
            'pass': lane14Pass,
            'cameraId': smokeReport?.cameraId,
            'imageFormatName': smokeReport?.imageFormatName,
            'selectedWidth': smokeReport?.selectedWidth,
            'selectedHeight': smokeReport?.selectedHeight,
          },
          'lane15_eventsIncludeOpenedConfiguredRepeatingStartedNativeRenderPassed5':
              {'pass': lane15Pass, 'events': smokeReport?.events},
          'lane16_smokeReportGettersAndToMapCoherent': {
            'pass': lane16Pass,
            'gettersCoherent': gettersCoherent,
            'mapMatches': mapMatches,
          },
        },
        'probeReport': probeReport?.toMap(),
        'smokeReport': smokeReport?.toMap(),
        'error': topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_L_NATIVE_RENDER_LOOP_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_L_NATIVE_RENDER_LOOP_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_L_NATIVE_RENDER_LOOP_PHYSICAL_FAIL',
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
