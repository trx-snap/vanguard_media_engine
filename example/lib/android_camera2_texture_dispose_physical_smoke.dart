// android_camera2_texture_dispose_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit N: Android Camera2 PRIVATE
// ImageReader HardwareBuffer Flutter Texture Native Render Loop Active Dispose/Cancellation Smoke Physical Harness.
//
// Proof lanes:
//   Lane 1: capability probe success, API >= 29, cameraCount >= 1, cameras nonempty.
//   Lane 2: hasCameraPermission true.
//   Lane 3: primary/back camera id selected and nonblank.
//   Lane 4: start ack textureId >= 0 and targetFrameCount == 30.
//   Lane 5: active dispose invocation returns pass true and surfaceProducerReleased false (pending release).
//   Lane 6: completion callback received, decision disposed, isDisposed true.
//   Lane 7: reasons includes 'disposed_during_run' and success false.
//   Lane 8: textureId matches start, targetFrameCount == 30, renderedFrames < 30, completedTargetFrames false.
//   Lane 9: completion surfaceProducerReleased true (released after harness cleanup).
//   Lane 10: native session cleanup invariant (!nativeSessionCreated || nativeSessionDestroyed).
//   Lane 11: camera device cleanup invariant (!opened || deviceClosed).
//   Lane 12: capture session cleanup invariant (!sessionConfigured || sessionClosed).
//   Lane 13: image reader cleanup invariant (imageReaderClosed || !opened).
//   Lane 14: no raw frame reports status=FAIL from native render.
//   Lane 15: hardwareBufferClosedCount and imageClosedCount equal renderedFrames.
//   Lane 16: getters and toMap/fromMap serialization coherent.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2TextureDisposePhysicalSmokeApp());
}

class AndroidCamera2TextureDisposePhysicalSmokeApp extends StatefulWidget {
  const AndroidCamera2TextureDisposePhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2TextureDisposePhysicalSmokeApp> createState() =>
      _AndroidCamera2TextureDisposePhysicalSmokeAppState();
}

class _AndroidCamera2TextureDisposePhysicalSmokeAppState
    extends State<AndroidCamera2TextureDisposePhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _completeMethod =
      'onAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmokeComplete';
  static const _disposeMethod =
      'disposeAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke';

  String _status =
      'Initializing Camera2 Flutter Texture Native Render Loop Active Dispose Smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_N_TEXTURE_DISPOSE_SMOKE_START');
    String? topLevelError;
    VGCameraHardwareCapabilityReport? probeReport;
    VGCameraHardwareDeviceCapability? primary;
    ({int textureId, int targetFrameCount})? startResult;
    Map<String, Object?>? activeDisposeResult;
    VGCamera2TextureNativeRenderLoopSmokeReport? smokeReport;

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
        'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_1: pass=$lane1Pass success=${probeReport.success} apiLevel=${probeReport.apiLevel} cameraCount=${probeReport.cameraCount} camerasLength=${probeReport.cameras.length}',
      );

      // Lane 2: CAMERA permission true
      lane2Pass = probeReport.hasCameraPermission == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_2: pass=$lane2Pass hasCameraPermission=${probeReport.hasCameraPermission}',
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
        'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_3: pass=$lane3Pass primaryCameraId=${primaryCam?.cameraId} lensFacing=${primaryCam?.lensFacing}',
      );

      // 3. Start Camera2 PRIVATE ImageReader HardwareBuffer Flutter Texture Native Render Loop Smoke with frameCount = 30
      if (lane1Pass && lane2Pass && lane3Pass) {
        startResult =
            await VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
              cameraId: primaryCam.cameraId,
              timeout: const Duration(seconds: 12),
              maxWidth: 640,
              maxHeight: 480,
              frameCount: 30,
            ).timeout(const Duration(seconds: 15));

        // Lane 4: start ack textureId >= 0 and targetFrameCount == 30
        lane4Pass =
            startResult.textureId >= 0 && startResult.targetFrameCount == 30;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_4: pass=$lane4Pass textureId=${startResult.textureId} targetFrameCount=${startResult.targetFrameCount}',
        );

        // Mount Flutter Texture widget
        if (mounted && startResult.textureId >= 0) {
          setState(() {
            _textureId = startResult!.textureId;
            _status = 'Texture $_textureId mounted, triggering active dispose…';
          });
        }

        // 4. Immediately trigger active dispose while harness is running
        final rawDispose = await _channel
            .invokeMapMethod<String, Object?>(_disposeMethod, {
              'textureId': startResult.textureId,
            })
            .timeout(const Duration(seconds: 10));
        activeDisposeResult = rawDispose != null
            ? Map<String, Object?>.from(rawDispose)
            : null;

        final activePass = activeDisposeResult?['pass'] as bool? ?? false;
        final activeReleased =
            activeDisposeResult?['surfaceProducerReleased'] as bool? ?? false;
        final activeRaw = activeDisposeResult?['raw'] as String?;

        // Lane 5: active dispose returns pass true and surfaceProducerReleased false (pending release)
        lane5Pass = activePass == true && activeReleased == false;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_5: pass=$lane5Pass passField=$activePass surfaceProducerReleased=$activeReleased raw=$activeRaw',
        );

        // 5. Wait for completion callback from background harness
        final rawCompletion = await completionCompleter.future.timeout(
          const Duration(seconds: 30),
        );
        smokeReport = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
          rawCompletion,
        );

        // Lane 6: completion decision disposed and isDisposed true
        lane6Pass =
            smokeReport.decision ==
                VGCamera2TextureNativeRenderLoopSmokeDecision.disposed &&
            smokeReport.isDisposed == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_6: pass=$lane6Pass decision=${smokeReport.decision.name} isDisposed=${smokeReport.isDisposed}',
        );

        // Lane 7: reasons includes 'disposed_during_run' and success false
        lane7Pass =
            smokeReport.reasons.contains('disposed_during_run') &&
            smokeReport.success == false;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_7: pass=$lane7Pass success=${smokeReport.success} reasons=${smokeReport.reasons}',
        );

        // Lane 8: textureId matches start, targetFrameCount == 30, renderedFrames < 30, completedTargetFrames false
        lane8Pass =
            smokeReport.textureId == startResult.textureId &&
            smokeReport.targetFrameCount == 30 &&
            smokeReport.renderedFrames < 30 &&
            smokeReport.completedTargetFrames == false;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_8: pass=$lane8Pass textureId=${smokeReport.textureId} targetFrameCount=${smokeReport.targetFrameCount} renderedFrames=${smokeReport.renderedFrames} completedTargetFrames=${smokeReport.completedTargetFrames}',
        );

        // Lane 9: completion surfaceProducerReleased true (released after harness cleanup)
        lane9Pass = smokeReport.surfaceProducerReleased == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_9: pass=$lane9Pass surfaceProducerReleased=${smokeReport.surfaceProducerReleased}',
        );

        // Lane 10: native session cleanup invariant (!nativeSessionCreated || nativeSessionDestroyed)
        lane10Pass =
            !smokeReport.nativeSessionCreated ||
            smokeReport.nativeSessionDestroyed;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_10: pass=$lane10Pass nativeSessionCreated=${smokeReport.nativeSessionCreated} nativeSessionDestroyed=${smokeReport.nativeSessionDestroyed}',
        );

        // Lane 11: camera device cleanup invariant (!opened || deviceClosed)
        lane11Pass = !smokeReport.opened || smokeReport.deviceClosed;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_11: pass=$lane11Pass opened=${smokeReport.opened} deviceClosed=${smokeReport.deviceClosed}',
        );

        // Lane 12: capture session cleanup invariant (!sessionConfigured || sessionClosed)
        lane12Pass =
            !smokeReport.sessionConfigured || smokeReport.sessionClosed;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_12: pass=$lane12Pass sessionConfigured=${smokeReport.sessionConfigured} sessionClosed=${smokeReport.sessionClosed}',
        );

        // Lane 13: image reader cleanup invariant (imageReaderClosed || !opened)
        lane13Pass = smokeReport.imageReaderClosed || !smokeReport.opened;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_13: pass=$lane13Pass imageReaderClosed=${smokeReport.imageReaderClosed} opened=${smokeReport.opened}',
        );

        // Lane 14: no raw frame reports status=FAIL or status=EXCEPTION from native render
        lane14Pass =
            smokeReport.nativeRenderRawFrames.every(
              (r) => r.startsWith('status=PASS;'),
            ) &&
            (smokeReport.finalNativeRenderRaw == null ||
                smokeReport.finalNativeRenderRaw!.startsWith('status=PASS;'));
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_14: pass=$lane14Pass rawFramesCount=${smokeReport.nativeRenderRawFrames.length} finalRaw=${smokeReport.finalNativeRenderRaw}',
        );

        // Lane 15: hardwareBufferClosedCount and imageClosedCount equal renderedFrames
        lane15Pass =
            smokeReport.hardwareBufferClosedCount ==
                smokeReport.renderedFrames &&
            smokeReport.imageClosedCount == smokeReport.renderedFrames;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_15: pass=$lane15Pass renderedFrames=${smokeReport.renderedFrames} hbClosedCount=${smokeReport.hardwareBufferClosedCount} imgClosedCount=${smokeReport.imageClosedCount}',
        );

        // Lane 16: getters and toMap/fromMap serialization coherent
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
        lane16Pass = gettersCoherent && mapMatches;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_N_SMOKE_LANE_16: pass=$lane16Pass gettersCoherent=$gettersCoherent mapMatches=$mapMatches',
        );
      }
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Camera2 Texture Native Render Loop Dispose Smoke exceeded timeout: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_N_TEXTURE_DISPOSE_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_N_TEXTURE_DISPOSE_SMOKE_ERROR: $topLevelError',
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
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2TextureNativeRenderLoopSmokeHarness',
        'phase': 'Phase 3-Unit N',
        'slice':
            'Phase 3-Unit N — Android Camera2 Flutter Texture Native Render Loop Active Dispose/Cancellation Physical Proof',
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
          'lane4_startAckTextureIdGte0AndTargetFrameCount30': {
            'pass': lane4Pass,
            'textureId': startResult?.textureId,
            'targetFrameCount': startResult?.targetFrameCount,
          },
          'lane5_activeDisposeReturnsPassTrueAndProducerNotReleased': {
            'pass': lane5Pass,
            'activeDisposeResult': activeDisposeResult,
          },
          'lane6_completionDecisionDisposedAndIsDisposedTrue': {
            'pass': lane6Pass,
            'decision': smokeReport?.decision.name,
            'isDisposed': smokeReport?.isDisposed,
          },
          'lane7_reasonsContainsDisposedDuringRunAndSuccessFalse': {
            'pass': lane7Pass,
            'success': smokeReport?.success,
            'reasons': smokeReport?.reasons,
          },
          'lane8_textureIdMatchesTarget30RenderedLt30CompletedFramesFalse': {
            'pass': lane8Pass,
            'textureId': smokeReport?.textureId,
            'targetFrameCount': smokeReport?.targetFrameCount,
            'renderedFrames': smokeReport?.renderedFrames,
            'completedTargetFrames': smokeReport?.completedTargetFrames,
          },
          'lane9_completionSurfaceProducerReleasedTrue': {
            'pass': lane9Pass,
            'surfaceProducerReleased': smokeReport?.surfaceProducerReleased,
          },
          'lane10_nativeSessionCleanupInvariant': {
            'pass': lane10Pass,
            'nativeSessionCreated': smokeReport?.nativeSessionCreated,
            'nativeSessionDestroyed': smokeReport?.nativeSessionDestroyed,
          },
          'lane11_cameraDeviceCleanupInvariant': {
            'pass': lane11Pass,
            'opened': smokeReport?.opened,
            'deviceClosed': smokeReport?.deviceClosed,
          },
          'lane12_captureSessionCleanupInvariant': {
            'pass': lane12Pass,
            'sessionConfigured': smokeReport?.sessionConfigured,
            'sessionClosed': smokeReport?.sessionClosed,
          },
          'lane13_imageReaderCleanupInvariant': {
            'pass': lane13Pass,
            'imageReaderClosed': smokeReport?.imageReaderClosed,
            'opened': smokeReport?.opened,
          },
          'lane14_noRawFrameFailsFromNativeRender': {
            'pass': lane14Pass,
            'nativeRenderRawFramesCount':
                smokeReport?.nativeRenderRawFrames.length,
            'finalNativeRenderRaw': smokeReport?.finalNativeRenderRaw,
          },
          'lane15_hardwareBufferAndImageClosedCountsEqualRenderedFrames': {
            'pass': lane15Pass,
            'renderedFrames': smokeReport?.renderedFrames,
            'hardwareBufferClosedCount': smokeReport?.hardwareBufferClosedCount,
            'imageClosedCount': smokeReport?.imageClosedCount,
          },
          'lane16_gettersAndSerializationCoherent': {
            'pass': lane16Pass,
            'gettersCoherent': gettersCoherent,
            'mapMatches': mapMatches,
          },
        },
        'probeReport': probeReport?.toMap(),
        'smokeReport': smokeReport?.toMap(),
        'activeDisposeResult': activeDisposeResult,
        'error': topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_N_TEXTURE_DISPOSE_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_N_TEXTURE_DISPOSE_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_N_TEXTURE_DISPOSE_PHYSICAL_FAIL',
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
