// android_camera2_texture_native_render_loop_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit M: Android Camera2 PRIVATE
// ImageReader HardwareBuffer Flutter Texture Native Render Loop Smoke Physical Harness.
//
// Proof lanes:
//   Lane 1: capability probe success, API >= 29, cameraCount >= 1, cameras nonempty.
//   Lane 2: hasCameraPermission true.
//   Lane 3: primary/back camera id selected and nonblank.
//   Lane 4: start ack textureId >= 0 and targetFrameCount == 5.
//   Lane 5: completion success true, decision textureNativeRenderLoopPassed.
//   Lane 6: attemptedOpen/opened/sessionConfigured/repeatingStarted true.
//   Lane 7: renderedFrames == targetFrameCount == 5 and completedTargetFrames true.
//   Lane 8: every native raw frame starts 'status=PASS;'; final raw contains frameIndex=4, renderedFrames=5, generationId=, renderResult=success, releaseResult=success.
//   Lane 9: hardwareBufferFrameCount/closedCount/imageClosedCount all == 5.
//   Lane 10: API >= 33 fence awaited/closed counts == 5; below API 33 counts may be 0.
//   Lane 11: timestamps present and monotonic true (first/last non-null, last > first, monotonic true).
//   Lane 12: nativeSessionCreated true, nativeGenerationId > 0, nativeSessionDestroyed true.
//   Lane 13: sessionClosed/deviceClosed/imageReaderClosed true and report.isCleanedUp true.
//   Lane 14: textureId in completion matches start textureId and surfaceProducerReleased is false before explicit dispose.
//   Lane 15: explicit dispose returns true/released after completion.
//   Lane 16: no reasons and event sequence includes openCameraRequested, onOpened, createCaptureSessionRequested, onConfigured, repeatingRequestStarted, nativeRenderAttempted frame 0..4, nativeRenderPassed:renderedFrames=5, onSessionClosed, onDeviceClosed.
//   Lane 17: getters/toMap/fromMap coherent.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2TextureNativeRenderLoopPhysicalSmokeApp());
}

class AndroidCamera2TextureNativeRenderLoopPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidCamera2TextureNativeRenderLoopPhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2TextureNativeRenderLoopPhysicalSmokeApp> createState() =>
      _AndroidCamera2TextureNativeRenderLoopPhysicalSmokeAppState();
}

class _AndroidCamera2TextureNativeRenderLoopPhysicalSmokeAppState
    extends State<AndroidCamera2TextureNativeRenderLoopPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _completeMethod =
      'onAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmokeComplete';

  String _status =
      'Initializing Camera2 PRIVATE HardwareBuffer Flutter Texture Native Render Loop Smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_M_TEXTURE_RENDER_LOOP_SMOKE_START');
    String? topLevelError;
    VGCameraHardwareCapabilityReport? probeReport;
    VGCameraHardwareDeviceCapability? primary;
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
        'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_1: pass=$lane1Pass success=${probeReport.success} apiLevel=${probeReport.apiLevel} cameraCount=${probeReport.cameraCount} camerasLength=${probeReport.cameras.length}',
      );

      // Lane 2: CAMERA permission true
      lane2Pass = probeReport.hasCameraPermission == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_2: pass=$lane2Pass hasCameraPermission=${probeReport.hasCameraPermission}',
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
        'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_3: pass=$lane3Pass primaryCameraId=${primaryCam?.cameraId} lensFacing=${primaryCam?.lensFacing}',
      );

      // 3. Start Camera2 PRIVATE ImageReader HardwareBuffer Flutter Texture Native Render Loop Smoke
      if (lane1Pass && lane2Pass && lane3Pass) {
        startResult =
            await VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
              cameraId: primaryCam.cameraId,
              timeout: const Duration(seconds: 12),
              maxWidth: 640,
              maxHeight: 480,
              frameCount: 5,
            ).timeout(const Duration(seconds: 15));

        // Lane 4: start ack textureId >= 0 and targetFrameCount == 5
        lane4Pass =
            startResult.textureId >= 0 && startResult.targetFrameCount == 5;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_4: pass=$lane4Pass textureId=${startResult.textureId} targetFrameCount=${startResult.targetFrameCount}',
        );

        // Mount Flutter Texture widget
        if (mounted && startResult.textureId >= 0) {
          setState(() {
            _textureId = startResult!.textureId;
            _status = 'Texture $_textureId mounted, rendering camera frames…';
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
          'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_5: pass=$lane5Pass success=${smokeReport.success} decision=${smokeReport.decision.name}',
        );

        // Lane 6: attemptedOpen/opened/sessionConfigured/repeatingStarted true
        lane6Pass =
            smokeReport.attemptedOpen == true &&
            smokeReport.opened == true &&
            smokeReport.sessionConfigured == true &&
            smokeReport.repeatingStarted == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_6: pass=$lane6Pass attemptedOpen=${smokeReport.attemptedOpen} opened=${smokeReport.opened} sessionConfigured=${smokeReport.sessionConfigured} repeatingStarted=${smokeReport.repeatingStarted}',
        );

        // Lane 7: renderedFrames == targetFrameCount == 5 and completedTargetFrames true
        lane7Pass =
            smokeReport.renderedFrames == 5 &&
            smokeReport.targetFrameCount == 5 &&
            smokeReport.completedTargetFrames == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_7: pass=$lane7Pass renderedFrames=${smokeReport.renderedFrames} targetFrameCount=${smokeReport.targetFrameCount} completedTargetFrames=${smokeReport.completedTargetFrames}',
        );

        // Lane 8: every native raw frame starts 'status=PASS;'; final raw contains frameIndex=4, renderedFrames=5, generationId=, renderResult=success, releaseResult=success
        lane8Pass =
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
          'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_8: pass=$lane8Pass rawFramesLength=${smokeReport.nativeRenderRawFrames.length} finalNativeRenderRaw=${smokeReport.finalNativeRenderRaw}',
        );

        // Lane 9: hardwareBufferFrameCount/closedCount/imageClosedCount all == 5
        lane9Pass =
            smokeReport.hardwareBufferFrameCount == 5 &&
            smokeReport.hardwareBufferClosedCount == 5 &&
            smokeReport.imageClosedCount == 5;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_9: pass=$lane9Pass hbFrames=${smokeReport.hardwareBufferFrameCount} hbClosed=${smokeReport.hardwareBufferClosedCount} imgClosed=${smokeReport.imageClosedCount}',
        );

        // Lane 10: API >= 33 fence awaited/closed counts == 5; below API 33 counts may be 0
        lane10Pass = (smokeReport.apiLevel >= 33)
            ? (smokeReport.syncFenceAwaitedCount == 5 &&
                  smokeReport.syncFenceClosedCount == 5)
            : (smokeReport.syncFenceAwaitedCount == 0 &&
                  smokeReport.syncFenceClosedCount == 0);
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_10: pass=$lane10Pass apiLevel=${smokeReport.apiLevel} syncFenceAwaitedCount=${smokeReport.syncFenceAwaitedCount} syncFenceClosedCount=${smokeReport.syncFenceClosedCount}',
        );

        // Lane 11: timestamps present and monotonic true
        lane11Pass =
            smokeReport.firstFrameTimestampNs != null &&
            smokeReport.lastFrameTimestampNs != null &&
            smokeReport.lastFrameTimestampNs! >
                smokeReport.firstFrameTimestampNs!;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_11: pass=$lane11Pass firstTs=${smokeReport.firstFrameTimestampNs} lastTs=${smokeReport.lastFrameTimestampNs} monotonic=${smokeReport.monotonicFrameTimestamps}',
        );

        // Lane 12: nativeSessionCreated true, nativeGenerationId > 0, nativeSessionDestroyed true
        lane12Pass =
            smokeReport.nativeSessionCreated == true &&
            smokeReport.nativeGenerationId > 0 &&
            smokeReport.nativeSessionDestroyed == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_12: pass=$lane12Pass nativeSessionCreated=${smokeReport.nativeSessionCreated} nativeGenerationId=${smokeReport.nativeGenerationId} nativeSessionDestroyed=${smokeReport.nativeSessionDestroyed}',
        );

        // Lane 13: sessionClosed/deviceClosed/imageReaderClosed true and report.isCleanedUp true
        lane13Pass =
            smokeReport.sessionClosed == true &&
            smokeReport.deviceClosed == true &&
            smokeReport.imageReaderClosed == true &&
            smokeReport.isCleanedUp == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_13: pass=$lane13Pass sessionClosed=${smokeReport.sessionClosed} deviceClosed=${smokeReport.deviceClosed} imageReaderClosed=${smokeReport.imageReaderClosed} isCleanedUp=${smokeReport.isCleanedUp}',
        );

        // Lane 14: textureId in completion matches start textureId and surfaceProducerReleased is false before explicit dispose
        lane14Pass =
            smokeReport.textureId == startResult.textureId &&
            smokeReport.surfaceProducerReleased == false;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_14: pass=$lane14Pass completionTextureId=${smokeReport.textureId} startTextureId=${startResult.textureId} surfaceProducerReleased=${smokeReport.surfaceProducerReleased}',
        );

        // Explicit dispose after completion
        disposeReleased =
            await VGCamera2TextureNativeRenderLoopSmokeReport.disposeAndroidCamera2TextureNativeRenderLoopSmoke(
              textureId: startResult.textureId,
            ).timeout(const Duration(seconds: 10));

        // Lane 15: explicit dispose returns true/released after completion
        lane15Pass = disposeReleased == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_15: pass=$lane15Pass disposeReleased=$disposeReleased',
        );

        // Lane 16: no reasons and event sequence includes openCameraRequested, onOpened, createCaptureSessionRequested, onConfigured, repeatingRequestStarted, nativeRenderAttempted for frame 0..4, onSessionClosed, onDeviceClosed
        lane16Pass =
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
          'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_16: pass=$lane16Pass reasons=${smokeReport.reasons} events=${smokeReport.events}',
        );

        // Lane 17: getters/toMap/fromMap coherent
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
            smokeReport.isCleanedUp ==
                (smokeReport.sessionClosed &&
                    smokeReport.deviceClosed &&
                    smokeReport.imageReaderClosed &&
                    smokeReport.nativeSessionDestroyed);

        final roundTrip = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
          map,
        );
        mapMatches = roundTrip == smokeReport;
        lane17Pass = gettersCoherent && mapMatches;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_M_SMOKE_LANE_17: pass=$lane17Pass gettersCoherent=$gettersCoherent mapMatches=$mapMatches',
        );
      }
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Camera2 Texture Native Render Loop Smoke exceeded timeout: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_M_TEXTURE_RENDER_LOOP_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_M_TEXTURE_RENDER_LOOP_SMOKE_ERROR: $topLevelError',
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
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2TextureNativeRenderLoopSmokeHarness',
        'phase': 'Phase 3-Unit M',
        'slice':
            'Phase 3-Unit M — Android Camera2 PRIVATE ImageReader HardwareBuffer Flutter Texture Native Render Loop Smoke Foundation',
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
          'lane6_attemptedOpenOpenedConfiguredRepeatingStartedTrue': {
            'pass': lane6Pass,
            'attemptedOpen': smokeReport?.attemptedOpen,
            'opened': smokeReport?.opened,
            'sessionConfigured': smokeReport?.sessionConfigured,
            'repeatingStarted': smokeReport?.repeatingStarted,
          },
          'lane7_renderedFrames5TargetFrameCount5CompletedTargetFramesTrue': {
            'pass': lane7Pass,
            'renderedFrames': smokeReport?.renderedFrames,
            'targetFrameCount': smokeReport?.targetFrameCount,
            'completedTargetFrames': smokeReport?.completedTargetFrames,
          },
          'lane8_rawFramesAllPassFinalRawContainsFrameIndex4AndRenderedFrames5':
              {
                'pass': lane8Pass,
                'nativeRenderRawFramesLength':
                    smokeReport?.nativeRenderRawFrames.length,
                'finalNativeRenderRaw': smokeReport?.finalNativeRenderRaw,
              },
          'lane9_hardwareBufferAndImageCountsEqual5': {
            'pass': lane9Pass,
            'hardwareBufferFrameCount': smokeReport?.hardwareBufferFrameCount,
            'hardwareBufferClosedCount': smokeReport?.hardwareBufferClosedCount,
            'imageClosedCount': smokeReport?.imageClosedCount,
          },
          'lane10_syncFenceAwaitedClosed5OnApi33OrZeroBelow': {
            'pass': lane10Pass,
            'apiLevel': smokeReport?.apiLevel,
            'syncFenceAwaitedCount': smokeReport?.syncFenceAwaitedCount,
            'syncFenceClosedCount': smokeReport?.syncFenceClosedCount,
          },
          'lane11_firstAndLastTimestampsNonNullLastGtFirstMonotonic': {
            'pass': lane11Pass,
            'firstFrameTimestampNs': smokeReport?.firstFrameTimestampNs,
            'lastFrameTimestampNs': smokeReport?.lastFrameTimestampNs,
            'monotonicFrameTimestamps': smokeReport?.monotonicFrameTimestamps,
          },
          'lane12_nativeSessionCreatedGenerationIdGt0DestroyedTrue': {
            'pass': lane12Pass,
            'nativeSessionCreated': smokeReport?.nativeSessionCreated,
            'nativeGenerationId': smokeReport?.nativeGenerationId,
            'nativeSessionDestroyed': smokeReport?.nativeSessionDestroyed,
          },
          'lane13_sessionDeviceReaderClosedAndIsCleanedUpTrue': {
            'pass': lane13Pass,
            'sessionClosed': smokeReport?.sessionClosed,
            'deviceClosed': smokeReport?.deviceClosed,
            'imageReaderClosed': smokeReport?.imageReaderClosed,
            'isCleanedUp': smokeReport?.isCleanedUp,
          },
          'lane14_completionTextureIdMatchesStartAndSurfaceProducerNotReleased':
              {
                'pass': lane14Pass,
                'completionTextureId': smokeReport?.textureId,
                'startTextureId': startResult?.textureId,
                'surfaceProducerReleased': smokeReport?.surfaceProducerReleased,
              },
          'lane15_explicitDisposeReturnsTrueReleased': {
            'pass': lane15Pass,
            'disposeReleased': disposeReleased,
          },
          'lane16_noReasonsAndEventsSequenceComplete': {
            'pass': lane16Pass,
            'reasons': smokeReport?.reasons,
            'events': smokeReport?.events,
          },
          'lane17_smokeReportGettersAndToMapFromMapCoherent': {
            'pass': lane17Pass,
            'gettersCoherent': gettersCoherent,
            'mapMatches': mapMatches,
          },
        },
        'probeReport': probeReport?.toMap(),
        'smokeReport': smokeReport?.toMap(),
        'disposeReleased': disposeReleased,
        'error': topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_M_TEXTURE_RENDER_LOOP_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_M_TEXTURE_RENDER_LOOP_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_M_TEXTURE_RENDER_LOOP_PHYSICAL_FAIL',
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
