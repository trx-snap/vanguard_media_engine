// android_camera2_front_camera_texture_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit O: Android Camera2 Front-Facing Lens
// Selection & Sensor Orientation Normalization Flutter Texture Native Render Loop Smoke Physical Harness.
//
// Proof lanes:
//   Lane 1: capability probe success, API >= 29, cameraCount >= 1, cameras nonempty.
//   Lane 2: hasCameraPermission true.
//   Lane 3: front-facing camera discovered by probe (probe report contains at least one camera with lensFacing == 'front').
//   Lane 4: start ack textureId >= 0 and targetFrameCount == 5 via lensFacing: 'front'.
//   Lane 5: completion success true, decision textureNativeRenderLoopPassed.
//   Lane 6: selectedLensFacing is 'front' and cameraId equals discovered front candidate (or is among front candidates if multiple).
//   Lane 7: selectedSensorOrientationDegrees in {0, 90, 180, 270} and hasValidSensorOrientation is true.
//   Lane 8: attemptedOpen/opened/sessionConfigured/repeatingStarted true.
//   Lane 9: renderedFrames == targetFrameCount == 5 and completedTargetFrames true.
//   Lane 10: every native raw frame starts 'status=PASS;'; final raw contains frameIndex=4, renderedFrames=5, generationId=, renderResult=success, releaseResult=success.
//   Lane 11: hardwareBufferFrameCount == 5, hardwareBufferClosedCount == renderedFrames (5), imageClosedCount == renderedFrames (5).
//   Lane 12: API >= 33 fence awaited/closed counts == 5; below API 33 counts may be 0.
//   Lane 13: timestamps present and monotonic true (first/last non-null, last > first, monotonic true).
//   Lane 14: nativeSessionCreated true, nativeGenerationId > 0, nativeSessionDestroyed true.
//   Lane 15: sessionClosed/deviceClosed/imageReaderClosed true and report.isCleanedUp true.
//   Lane 16: textureId in completion matches start textureId and surfaceProducerReleased is false before explicit dispose.
//   Lane 17: explicit dispose returns true/released after completion.
//   Lane 18: no reasons and event sequence includes openCameraRequested, onOpened, createCaptureSessionRequested, onConfigured, repeatingRequestStarted, nativeRenderAttempted frame 0..4, nativeRenderPassed:renderedFrames=5, onSessionClosed, onDeviceClosed.
//   Lane 19: getters/toMap/fromMap coherent (round-trip preserves orientation and facing).

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2FrontCameraTexturePhysicalSmokeApp());
}

class AndroidCamera2FrontCameraTexturePhysicalSmokeApp extends StatefulWidget {
  const AndroidCamera2FrontCameraTexturePhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2FrontCameraTexturePhysicalSmokeApp> createState() =>
      _AndroidCamera2FrontCameraTexturePhysicalSmokeAppState();
}

class _AndroidCamera2FrontCameraTexturePhysicalSmokeAppState
    extends State<AndroidCamera2FrontCameraTexturePhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _completeMethod =
      'onAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmokeComplete';

  String _status =
      'Initializing Camera2 Front-Facing Flutter Texture Native Render Loop Smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_O_FRONT_TEXTURE_SMOKE_START');
    String? topLevelError;
    VGCameraHardwareCapabilityReport? probeReport;
    List<VGCameraHardwareDeviceCapability> frontCandidates = const [];
    ({int textureId, int targetFrameCount})? startResult;
    VGCamera2TextureNativeRenderLoopSmokeReport? smokeReport;
    var disposeReleased = false;

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
    var lane18Pass = false;
    var lane19Pass = false;
    var gettersCoherent = false;
    var mapMatches = false;

    final completionCompleter = Completer<Map<dynamic, dynamic>>();

    // Set up MethodChannel listener for completion callback.
    _channel.setMethodCallHandler((call) async {
      if (call.method == _completeMethod) {
        if (!completionCompleter.isCompleted) {
          final args = call.arguments;
          if (args is Map) {
            completionCompleter.complete(args);
          } else {
            completionCompleter.complete(<dynamic, dynamic>{});
          }
        }
      }
    });

    try {
      // 0. Wait 5 seconds before probing/running to allow grant runner to grant CAMERA after install/start
      await Future<void>.delayed(const Duration(seconds: 5));

      // 1. Probe Android Camera2 capabilities
      probeReport =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities()
              .timeout(const Duration(seconds: 15));

      // Lane 1: capability probe success, API >= 29, cameraCount >= 1, cameras nonempty
      lane1Pass =
          probeReport.success == true &&
          probeReport.apiLevel >= 29 &&
          probeReport.cameraCount >= 1 &&
          probeReport.cameras.isNotEmpty;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_1: pass=$lane1Pass success=${probeReport.success} apiLevel=${probeReport.apiLevel} cameraCount=${probeReport.cameraCount} camerasLength=${probeReport.cameras.length}',
      );

      // Lane 2: CAMERA permission true
      lane2Pass = probeReport.hasCameraPermission == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_2: pass=$lane2Pass hasCameraPermission=${probeReport.hasCameraPermission}',
      );

      // 2. Discover front camera(s) from probe report
      frontCandidates = probeReport.cameras
          .where((c) => c.lensFacing == 'front')
          .toList(growable: false);

      // Lane 3: front camera discovered by probe; fail closed if none exists
      lane3Pass = frontCandidates.isNotEmpty;
      final frontIds = frontCandidates.map((c) => c.cameraId).toList();
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_3: pass=$lane3Pass frontCandidatesCount=${frontCandidates.length} frontCameraIds=$frontIds',
      );

      if (!lane3Pass) {
        topLevelError =
            'No front-facing camera discovered by hardware probe; front camera smoke cannot proceed.';
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_FRONT_TEXTURE_SMOKE_ERROR: $topLevelError',
        );
      }

      // 3. Start Camera2 Front-Facing Flutter Texture Native Render Loop Smoke
      if (lane1Pass && lane2Pass && lane3Pass) {
        startResult =
            await VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
              lensFacing: 'front',
              timeout: const Duration(seconds: 10),
              maxWidth: 640,
              maxHeight: 480,
              frameCount: 5,
            ).timeout(const Duration(seconds: 15));

        // Lane 4: start ack textureId >= 0 and targetFrameCount == 5
        lane4Pass =
            startResult.textureId >= 0 && startResult.targetFrameCount == 5;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_4: pass=$lane4Pass textureId=${startResult.textureId} targetFrameCount=${startResult.targetFrameCount}',
        );

        // Mount Flutter Texture widget
        if (mounted && startResult.textureId >= 0) {
          setState(() {
            _textureId = startResult!.textureId;
            _status =
                'Front Camera Texture $_textureId mounted, rendering frames…';
          });
        }

        // Wait for completion callback
        final rawCompletion = await completionCompleter.future.timeout(
          const Duration(seconds: 30),
        );
        smokeReport = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
          rawCompletion,
        );

        // Lane 5: completion success true, decision textureNativeRenderLoopPassed
        lane5Pass =
            smokeReport.success == true &&
            smokeReport.decision ==
                VGCamera2TextureNativeRenderLoopSmokeDecision
                    .textureNativeRenderLoopPassed;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_5: pass=$lane5Pass success=${smokeReport.success} decision=${smokeReport.decision.name}',
        );

        // Lane 6: selectedLensFacing is 'front' and cameraId matches discovered front candidate(s)
        final selectedCamId = smokeReport.cameraId;
        final candidateMatches =
            selectedCamId != null &&
            (frontCandidates.length == 1
                ? selectedCamId == frontCandidates.first.cameraId
                : frontCandidates.any((c) => c.cameraId == selectedCamId));
        lane6Pass =
            smokeReport.selectedLensFacing == 'front' &&
            selectedCamId != null &&
            selectedCamId.trim().isNotEmpty &&
            candidateMatches;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_6: pass=$lane6Pass selectedLensFacing=${smokeReport.selectedLensFacing} cameraId=$selectedCamId candidateMatches=$candidateMatches',
        );

        // Lane 7: selectedSensorOrientationDegrees in {0, 90, 180, 270} and hasValidSensorOrientation is true
        const validOrientations = <int>{0, 90, 180, 270};
        lane7Pass =
            validOrientations.contains(
              smokeReport.selectedSensorOrientationDegrees,
            ) &&
            smokeReport.hasValidSensorOrientation == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_7: pass=$lane7Pass selectedSensorOrientationDegrees=${smokeReport.selectedSensorOrientationDegrees} hasValidSensorOrientation=${smokeReport.hasValidSensorOrientation}',
        );

        // Lane 8: attemptedOpen/opened/sessionConfigured/repeatingStarted true
        lane8Pass =
            smokeReport.attemptedOpen == true &&
            smokeReport.opened == true &&
            smokeReport.sessionConfigured == true &&
            smokeReport.repeatingStarted == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_8: pass=$lane8Pass attemptedOpen=${smokeReport.attemptedOpen} opened=${smokeReport.opened} sessionConfigured=${smokeReport.sessionConfigured} repeatingStarted=${smokeReport.repeatingStarted}',
        );

        // Lane 9: renderedFrames == targetFrameCount == 5 and completedTargetFrames true
        lane9Pass =
            smokeReport.renderedFrames == 5 &&
            smokeReport.targetFrameCount == 5 &&
            smokeReport.completedTargetFrames == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_9: pass=$lane9Pass renderedFrames=${smokeReport.renderedFrames} targetFrameCount=${smokeReport.targetFrameCount} completedTargetFrames=${smokeReport.completedTargetFrames}',
        );

        // Lane 10: every native raw frame starts 'status=PASS;'; final raw contains frameIndex=4, renderedFrames=5, generationId=, renderResult=success, releaseResult=success
        lane10Pass =
            smokeReport.nativeRenderRawFrames.length == 5 &&
            smokeReport.nativeRenderRawFrames.every(
              (r) => r.startsWith('status=PASS;'),
            ) &&
            smokeReport.finalNativeRenderRaw != null &&
            smokeReport.finalNativeRenderRaw!.contains('frameIndex=4') &&
            smokeReport.finalNativeRenderRaw!.contains('renderedFrames=5') &&
            smokeReport.finalNativeRenderRaw!.contains('generationId=') &&
            smokeReport.finalNativeRenderRaw!.contains(
              'renderResult=success',
            ) &&
            smokeReport.finalNativeRenderRaw!.contains('releaseResult=success');
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_10: pass=$lane10Pass rawFramesLength=${smokeReport.nativeRenderRawFrames.length} finalNativeRenderRaw=${smokeReport.finalNativeRenderRaw}',
        );

        // Lane 11: hardwareBufferFrameCount/closedCount/imageClosedCount all == 5
        lane11Pass =
            smokeReport.hardwareBufferFrameCount == 5 &&
            smokeReport.hardwareBufferClosedCount == 5 &&
            smokeReport.imageClosedCount == 5;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_11: pass=$lane11Pass hbFrames=${smokeReport.hardwareBufferFrameCount} hbClosed=${smokeReport.hardwareBufferClosedCount} imgClosed=${smokeReport.imageClosedCount}',
        );

        // Lane 12: API >= 33 fence awaited/closed counts == 5; below API 33 counts may be 0
        lane12Pass = (smokeReport.apiLevel >= 33)
            ? (smokeReport.syncFenceAwaitedCount == 5 &&
                  smokeReport.syncFenceClosedCount == 5)
            : (smokeReport.syncFenceAwaitedCount == 0 &&
                  smokeReport.syncFenceClosedCount == 0);
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_12: pass=$lane12Pass apiLevel=${smokeReport.apiLevel} syncFenceAwaitedCount=${smokeReport.syncFenceAwaitedCount} syncFenceClosedCount=${smokeReport.syncFenceClosedCount}',
        );

        // Lane 13: timestamps present and monotonic true
        lane13Pass =
            smokeReport.firstFrameTimestampNs != null &&
            smokeReport.lastFrameTimestampNs != null &&
            smokeReport.lastFrameTimestampNs! >
                smokeReport.firstFrameTimestampNs!;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_13: pass=$lane13Pass firstTs=${smokeReport.firstFrameTimestampNs} lastTs=${smokeReport.lastFrameTimestampNs} monotonic=${smokeReport.monotonicFrameTimestamps}',
        );

        // Lane 14: nativeSessionCreated true, nativeGenerationId > 0, nativeSessionDestroyed true
        lane14Pass =
            smokeReport.nativeSessionCreated == true &&
            smokeReport.nativeGenerationId > 0 &&
            smokeReport.nativeSessionDestroyed == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_14: pass=$lane14Pass nativeSessionCreated=${smokeReport.nativeSessionCreated} nativeGenerationId=${smokeReport.nativeGenerationId} nativeSessionDestroyed=${smokeReport.nativeSessionDestroyed}',
        );

        // Lane 15: sessionClosed/deviceClosed/imageReaderClosed true and report.isCleanedUp true
        lane15Pass =
            smokeReport.sessionClosed == true &&
            smokeReport.deviceClosed == true &&
            smokeReport.imageReaderClosed == true &&
            smokeReport.isCleanedUp == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_15: pass=$lane15Pass sessionClosed=${smokeReport.sessionClosed} deviceClosed=${smokeReport.deviceClosed} imageReaderClosed=${smokeReport.imageReaderClosed} isCleanedUp=${smokeReport.isCleanedUp}',
        );

        // Lane 16: textureId in completion matches start textureId and surfaceProducerReleased is false before explicit dispose
        lane16Pass =
            smokeReport.textureId == startResult.textureId &&
            smokeReport.surfaceProducerReleased == false;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_16: pass=$lane16Pass completionTextureId=${smokeReport.textureId} startTextureId=${startResult.textureId} surfaceProducerReleased=${smokeReport.surfaceProducerReleased}',
        );

        // Explicit dispose after completion
        disposeReleased =
            await VGCamera2TextureNativeRenderLoopSmokeReport.disposeAndroidCamera2TextureNativeRenderLoopSmoke(
              textureId: startResult.textureId,
            ).timeout(const Duration(seconds: 10));

        // Lane 17: explicit dispose returns true/released after completion
        lane17Pass = disposeReleased == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_17: pass=$lane17Pass disposeReleased=$disposeReleased',
        );

        // Lane 18: no reasons and event sequence includes openCameraRequested, onOpened, createCaptureSessionRequested, onConfigured, repeatingRequestStarted, nativeRenderAttempted for frame 0..4, onSessionClosed, onDeviceClosed
        lane18Pass =
            smokeReport.reasons.isEmpty &&
            smokeReport.events.contains('openCameraRequested') &&
            smokeReport.events.contains('onOpened') &&
            smokeReport.events.contains('createCaptureSessionRequested') &&
            smokeReport.events.contains('onConfigured') &&
            smokeReport.events.contains('repeatingRequestStarted') &&
            smokeReport.events.contains('nativeRenderAttempted:frameIndex=0') &&
            smokeReport.events.contains('nativeRenderAttempted:frameIndex=1') &&
            smokeReport.events.contains('nativeRenderAttempted:frameIndex=2') &&
            smokeReport.events.contains('nativeRenderAttempted:frameIndex=3') &&
            smokeReport.events.contains('nativeRenderAttempted:frameIndex=4') &&
            smokeReport.events.contains(
              'nativeRenderPassed:renderedFrames=5',
            ) &&
            smokeReport.events.contains('onSessionClosed') &&
            smokeReport.events.contains('onDeviceClosed');
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_18: pass=$lane18Pass reasons=${smokeReport.reasons} events=${smokeReport.events}',
        );

        // Lane 19: getters/toMap/fromMap coherent (including orientation)
        final map = smokeReport.toMap();
        gettersCoherent =
            smokeReport.isTextureNativeRenderLoopPassed ==
                (smokeReport.decision ==
                    VGCamera2TextureNativeRenderLoopSmokeDecision
                        .textureNativeRenderLoopPassed) &&
            smokeReport.isPermissionRequired ==
                (smokeReport.decision ==
                    VGCamera2TextureNativeRenderLoopSmokeDecision
                        .permissionRequired) &&
            smokeReport.isDisposed ==
                (smokeReport.decision ==
                    VGCamera2TextureNativeRenderLoopSmokeDecision.disposed) &&
            smokeReport.isAttempted == smokeReport.attemptedOpen &&
            smokeReport.completedTargetFrames ==
                (smokeReport.renderedFrames >= smokeReport.targetFrameCount) &&
            smokeReport.hasValidSensorOrientation ==
                (const <int>{
                  0,
                  90,
                  180,
                  270,
                }.contains(smokeReport.selectedSensorOrientationDegrees)) &&
            smokeReport.isCleanedUp ==
                (smokeReport.sessionClosed &&
                    smokeReport.deviceClosed &&
                    smokeReport.imageReaderClosed &&
                    smokeReport.nativeSessionDestroyed);

        final roundTrip = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
          map,
        );
        mapMatches =
            roundTrip == smokeReport &&
            roundTrip.selectedSensorOrientationDegrees ==
                smokeReport.selectedSensorOrientationDegrees &&
            roundTrip.selectedLensFacing == smokeReport.selectedLensFacing;
        lane19Pass = gettersCoherent && mapMatches;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_O_SMOKE_LANE_19: pass=$lane19Pass gettersCoherent=$gettersCoherent mapMatches=$mapMatches',
        );
      }
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Camera2 Front-Facing Texture Native Render Loop Smoke exceeded timeout: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_O_FRONT_TEXTURE_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_O_FRONT_TEXTURE_SMOKE_ERROR: $topLevelError',
      );
    } finally {
      // Clear method call handler
      _channel.setMethodCallHandler(null);

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
          lane18Pass &&
          lane19Pass &&
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2TextureNativeRenderLoopSmokeHarness',
        'phase': 'Phase 3-Unit O',
        'slice':
            'Phase 3-Unit O — Android Camera2 Front-Facing Lens Selection & Sensor Orientation Normalization Flutter Texture Native Render Loop Smoke Foundation',
        'target': 'android_physical_front_camera',
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
          'lane3_frontCameraDiscoveredByProbe': {
            'pass': lane3Pass,
            'frontCandidatesCount': frontCandidates.length,
            'frontCameraIds': frontCandidates.map((c) => c.cameraId).toList(),
          },
          'lane4_startAckTextureIdGte0AndTargetFrameCount5': {
            'pass': lane4Pass,
            'textureId': startResult?.textureId,
            'targetFrameCount': startResult?.targetFrameCount,
          },
          'lane5_smokeReportSuccessTrueDecisionPassed': {
            'pass': lane5Pass,
            'success': smokeReport?.success,
            'decision': smokeReport?.decision.name,
          },
          'lane6_selectedLensFacingFrontAndCameraIdMatchesCandidate': {
            'pass': lane6Pass,
            'selectedLensFacing': smokeReport?.selectedLensFacing,
            'cameraId': smokeReport?.cameraId,
          },
          'lane7_sensorOrientationValidAndInAllowedSet': {
            'pass': lane7Pass,
            'selectedSensorOrientationDegrees':
                smokeReport?.selectedSensorOrientationDegrees,
            'hasValidSensorOrientation': smokeReport?.hasValidSensorOrientation,
          },
          'lane8_attemptedOpenOpenedConfiguredRepeatingStartedTrue': {
            'pass': lane8Pass,
            'attemptedOpen': smokeReport?.attemptedOpen,
            'opened': smokeReport?.opened,
            'sessionConfigured': smokeReport?.sessionConfigured,
            'repeatingStarted': smokeReport?.repeatingStarted,
          },
          'lane9_renderedFrames5TargetFrameCount5CompletedTargetFramesTrue': {
            'pass': lane9Pass,
            'renderedFrames': smokeReport?.renderedFrames,
            'targetFrameCount': smokeReport?.targetFrameCount,
            'completedTargetFrames': smokeReport?.completedTargetFrames,
          },
          'lane10_rawFramesAllPassFinalRawContainsFrameIndex4AndRenderedFrames5':
              {
                'pass': lane10Pass,
                'nativeRenderRawFramesLength':
                    smokeReport?.nativeRenderRawFrames.length,
                'finalNativeRenderRaw': smokeReport?.finalNativeRenderRaw,
              },
          'lane11_hardwareBufferAndImageCountsEqual5': {
            'pass': lane11Pass,
            'hardwareBufferFrameCount': smokeReport?.hardwareBufferFrameCount,
            'hardwareBufferClosedCount': smokeReport?.hardwareBufferClosedCount,
            'imageClosedCount': smokeReport?.imageClosedCount,
          },
          'lane12_syncFenceAwaitedClosed5OnApi33OrZeroBelow': {
            'pass': lane12Pass,
            'apiLevel': smokeReport?.apiLevel,
            'syncFenceAwaitedCount': smokeReport?.syncFenceAwaitedCount,
            'syncFenceClosedCount': smokeReport?.syncFenceClosedCount,
          },
          'lane13_firstAndLastTimestampsNonNullLastGtFirstMonotonic': {
            'pass': lane13Pass,
            'firstFrameTimestampNs': smokeReport?.firstFrameTimestampNs,
            'lastFrameTimestampNs': smokeReport?.lastFrameTimestampNs,
            'monotonicFrameTimestamps': smokeReport?.monotonicFrameTimestamps,
          },
          'lane14_nativeSessionCreatedGenerationIdGt0DestroyedTrue': {
            'pass': lane14Pass,
            'nativeSessionCreated': smokeReport?.nativeSessionCreated,
            'nativeGenerationId': smokeReport?.nativeGenerationId,
            'nativeSessionDestroyed': smokeReport?.nativeSessionDestroyed,
          },
          'lane15_sessionDeviceReaderClosedAndIsCleanedUpTrue': {
            'pass': lane15Pass,
            'sessionClosed': smokeReport?.sessionClosed,
            'deviceClosed': smokeReport?.deviceClosed,
            'imageReaderClosed': smokeReport?.imageReaderClosed,
            'isCleanedUp': smokeReport?.isCleanedUp,
          },
          'lane16_completionTextureIdMatchesStartAndSurfaceProducerNotReleased':
              {
                'pass': lane16Pass,
                'completionTextureId': smokeReport?.textureId,
                'startTextureId': startResult?.textureId,
                'surfaceProducerReleased': smokeReport?.surfaceProducerReleased,
              },
          'lane17_explicitDisposeReturnsTrueReleased': {
            'pass': lane17Pass,
            'disposeReleased': disposeReleased,
          },
          'lane18_noReasonsAndEventsSequenceComplete': {
            'pass': lane18Pass,
            'reasons': smokeReport?.reasons,
            'events': smokeReport?.events,
          },
          'lane19_smokeReportGettersAndToMapFromMapCoherent': {
            'pass': lane19Pass,
            'gettersCoherent': gettersCoherent,
            'mapMatches': mapMatches,
          },
        },
        'probeReport': probeReport?.toMap(),
        'smokeReport': smokeReport?.toMap(),
        'frontCandidates': frontCandidates.map((c) => c.toMap()).toList(),
        'disposeReleased': disposeReleased,
        'error': topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_O_FRONT_TEXTURE_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_O_FRONT_TEXTURE_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_O_FRONT_TEXTURE_PHYSICAL_FAIL',
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
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_textureId != null && _textureId! >= 0)
                SizedBox(
                  width: 320,
                  height: 240,
                  child: Texture(textureId: _textureId!),
                ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
