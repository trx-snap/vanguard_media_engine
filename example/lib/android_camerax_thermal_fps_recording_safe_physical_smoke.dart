// android_camerax_thermal_fps_recording_safe_physical_smoke.dart
// Vanguard Media Engine -- P3-CAM-THERMAL-ACT-CAMERAX-FPS-RECORDING-SAFE: Android
// True-DAG foundation CameraX thermal AE target FPS mid-recording safe physical smoke.
//
// Proof boundary (Harness):
//   camerax_repeating_request_ae_fps_mutation_mid_recording_synthetic_thermal_no_rebind_no_forced_heat_no_product
//
// Proof boundary (Bridge applyResult):
//   camerax_repeating_request_ae_fps_mutation_synthetic_thermal_no_rebind_no_forced_heat_no_product
//
// Proof lanes:
//   Lane 1: startCamera returns a valid non-negative textureId.
//   Lane 2: isCameraReady polls true within the timeout window.
//   Lane 3: diagnostics before recording are coherent: running true, expected
//     textureId, bindGeneration/bindCount/surfaceRequestCount >= 1, observed
//     AE target FPS upper bound non-null, and no applied range yet.
//   Lane 4: startRecording(temp mp4) completes, then poll isRecordingActive true.
//   Lane 5: VGCamera2ThermalLoadSheddingPlanner (serious, wasRecording=true,
//     hadSecondaryCamera=false, currentFps=observedUpper) decides
//     reduceFrameRate with targetFps < observedUpper.
//   Lane 6: apply target FPS returns outcome APPLIED, requestedTargetFps matches,
//     selectedUpper < observedUpper, recordingActiveAtApply true, and
//     isRecordingAtApply true.
//   Lane 7: diagnostics while still recording reach >= 2 consecutive completed
//     captures on the applied range, applied range matches selected range,
//     observed/applied upper < before, and isRecordingActive remains true.
//   Lane 8: no-rebind proof across before/after -- textureId, bindGeneration,
//     bindCount, surfaceRequestCount, and cameraProviderIdentity are unchanged.
//   Lane 9: stopRecording finalizes; returned filePath is non-empty; output
//     exists, size > 0, first bytes include MP4 ftyp header. Delete output
//     only after recording assertions.
//   Lane 10: apply result still carries the existing bridge proofBoundary/nonClaims,
//     and harness JSON carries the mid-recording proof boundary.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _harnessProofBoundary =
    'camerax_repeating_request_ae_fps_mutation_mid_recording_synthetic_thermal_no_rebind_no_forced_heat_no_product';

const String _bridgeExpectedProofBoundary =
    'camerax_repeating_request_ae_fps_mutation_synthetic_thermal_no_rebind_no_forced_heat_no_product';

const Map<String, bool> _bridgeExpectedNonClaims = <String, bool>{
  'midRecordingActuationProven': false,
  'osThermalListenerWired': false,
  'resolutionReconfigured': false,
  'secondaryCameraTouched': false,
  'realForcedOverheat': false,
  'encoderTouched': false,
  'rendererTouched': false,
  'productUiWired': false,
};

const Map<String, bool> _harnessNonClaims = <String, bool>{
  'osThermalListenerWired': false,
  'resolutionReconfigured': false,
  'secondaryCameraDisabled': false,
  'realForcedOverheat': false,
  'productUiWired': false,
  'switchCameraCalled': false,
};

bool _isRecordAudioPermissionBlocker(Object error) {
  if (error is PlatformException) {
    final code = error.code.toUpperCase();
    final message = (error.message ?? '').toUpperCase();
    final details = (error.details?.toString() ?? '').toUpperCase();
    if (code.contains('PERMISSION') ||
        code.contains('SECURITY') ||
        message.contains('RECORD_AUDIO') ||
        message.contains('PERMISSION') ||
        message.contains('SECURITYEXCEPTION') ||
        details.contains('RECORD_AUDIO') ||
        details.contains('PERMISSION')) {
      return true;
    }
  }
  final str = error.toString().toUpperCase();
  return str.contains('RECORD_AUDIO') ||
      str.contains('SECURITYEXCEPTION') ||
      (str.contains('PERMISSION') && str.contains('AUDIO'));
}

void main() {
  runApp(const AndroidCameraXThermalFpsRecordingSafePhysicalSmokeApp());
}

class AndroidCameraXThermalFpsRecordingSafePhysicalSmokeApp
    extends StatefulWidget {
  const AndroidCameraXThermalFpsRecordingSafePhysicalSmokeApp({super.key});

  @override
  State<AndroidCameraXThermalFpsRecordingSafePhysicalSmokeApp> createState() =>
      _AndroidCameraXThermalFpsRecordingSafePhysicalSmokeAppState();
}

class _AndroidCameraXThermalFpsRecordingSafePhysicalSmokeAppState
    extends State<AndroidCameraXThermalFpsRecordingSafePhysicalSmokeApp> {
  String _status =
      'Initializing CameraX Thermal FPS Recording-Safe Physical Smoke...';

  static const MethodChannel _rawChannel = MethodChannel(
    'vanguard_media_engine',
  );
  static final bridge = VGCameraXThermalFpsBridge();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<bool> _pollIsCameraReady(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final ready = await _rawChannel.invokeMethod<bool>('isCameraReady');
      if (ready == true) return true;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  Future<bool> _pollIsRecordingActive(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final active = await _rawChannel.invokeMethod<bool>('isRecordingActive');
      if (active == true) return true;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return false;
  }

  Future<VGCameraXThermalFpsDiagnostics> _pollDiagnosticsUntil(
    bool Function(VGCameraXThermalFpsDiagnostics) predicate,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    var last = await bridge.getAndroidCameraXThermalFpsDiagnostics();
    while (!predicate(last) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      last = await bridge.getAndroidCameraXThermalFpsDiagnostics();
    }
    return last;
  }

  Future<void> _runSmoke() async {
    print(
      'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_PHYSICAL_SMOKE_START',
    );
    String? topLevelError;
    int? textureId;
    VGCameraXThermalFpsDiagnostics? diagnosticsBefore;
    VGCamera2ThermalLoadSheddingPlan? plan;
    VGCameraXThermalFpsApplyResult? applyResult;
    VGCameraXThermalFpsDiagnostics? diagnosticsDuringRecording;

    var cameraStarted = false;
    var recordingStarted = false;
    var recordingStopped = false;
    var recordingActive = false;
    String returnedFilePath = '';
    int fileSize = 0;
    bool hasFtyp = false;
    int? observedUpper;

    File? tempMp4File;
    File? recordedOutputFile;

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

    try {
      // 0. Wait to allow the grant runner to grant CAMERA and RECORD_AUDIO.
      await Future<void>.delayed(const Duration(seconds: 5));

      // Generate a unique temp mp4 path under Directory.systemTemp.
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final uniqueName = 'camerax_thermal_rec_safe_${timestamp}_$pid.mp4';
      final tempMp4Path = '${Directory.systemTemp.path}/$uniqueName';
      tempMp4File = File(tempMp4Path);

      // 1. Start camera: returns non-negative textureId.
      textureId = await VanguardEngine.startCamera(
        position: 1,
        fps: 30,
      ).timeout(const Duration(seconds: 15));
      cameraStarted = true;

      lane1Pass = textureId >= 0;
      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_LANE_1: pass=$lane1Pass textureId=$textureId',
      );

      // 2. Poll isCameraReady becomes true.
      final ready = await _pollIsCameraReady(const Duration(seconds: 15));
      lane2Pass = ready;
      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_LANE_2: pass=$lane2Pass ready=$ready',
      );

      if (lane1Pass && lane2Pass) {
        // 3. Diagnostics before recording: running true, expected textureId,
        // bindGeneration/bindCount/surfaceRequestCount >= 1, observed FPS upper
        // non-null, no applied range.
        diagnosticsBefore = await _pollDiagnosticsUntil(
          (d) => d.observedAeTargetFpsUpper != null,
          const Duration(seconds: 10),
        );

        lane3Pass =
            diagnosticsBefore.running == true &&
            diagnosticsBefore.textureId == textureId &&
            diagnosticsBefore.bindGeneration >= 1 &&
            diagnosticsBefore.bindCount >= 1 &&
            diagnosticsBefore.surfaceRequestCount >= 1 &&
            diagnosticsBefore.observedAeTargetFpsUpper != null &&
            diagnosticsBefore.appliedAeTargetFpsLower == null &&
            diagnosticsBefore.appliedAeTargetFpsUpper == null &&
            diagnosticsBefore.appliedRange == null;
        print(
          'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_LANE_3: pass=$lane3Pass diagnosticsBefore=$diagnosticsBefore',
        );

        if (lane3Pass) {
          // 4. Start recording to temp mp4, then poll isRecordingActive true.
          try {
            await VanguardEngine.startRecording(
              tempMp4Path,
            ).timeout(const Duration(seconds: 15));
            recordingStarted = true;
          } catch (e) {
            if (_isRecordAudioPermissionBlocker(e)) {
              topLevelError = 'ENV_BLOCKER_RECORD_AUDIO_PERMISSION: $e';
            } else {
              topLevelError = 'startRecording failed: $e';
            }
            rethrow;
          }

          recordingActive = await _pollIsRecordingActive(
            const Duration(seconds: 10),
          );
          lane4Pass = recordingStarted && recordingActive;
          print(
            'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_LANE_4: pass=$lane4Pass recordingActive=$recordingActive',
          );

          if (lane4Pass) {
            // 5. Synthetic serious VGCamera2ThermalLoadSheddingPlanner with
            // wasRecording=true/hadSecondaryCamera=false/currentFps=observedUpper
            // chooses reduceFrameRate and targetFps < observedUpper.
            observedUpper = diagnosticsBefore.observedAeTargetFpsUpper ?? 30;
            const planner = VGCamera2ThermalLoadSheddingPlanner();
            plan = planner.evaluate(
              thermalState: VGThermalState.serious,
              wasRecording: true,
              hadSecondaryCamera: false,
              currentFps: observedUpper,
            );

            lane5Pass =
                plan.decision ==
                    VGCamera2ThermalLoadSheddingDecision.reduceFrameRate &&
                plan.targetFps < observedUpper;
            print(
              'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_LANE_5: '
              'pass=$lane5Pass decision=${plan.decision.name} observedUpper=$observedUpper targetFps=${plan.targetFps}',
            );

            if (lane5Pass) {
              // 6. Apply target FPS returns outcome APPLIED, requestedTargetFps matches,
              // selectedUpper < observedUpper, recordingActiveAtApply true, isRecordingAtApply true.
              applyResult = await bridge
                  .applyAndroidCameraXThermalTargetFps(plan.targetFps)
                  .timeout(const Duration(seconds: 10));

              lane6Pass =
                  applyResult.outcome == 'APPLIED' &&
                  applyResult.requestedTargetFps == plan.targetFps &&
                  applyResult.selectedUpper < observedUpper &&
                  applyResult.recordingActiveAtApply == true &&
                  applyResult.isRecordingAtApply == true;
              print(
                'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_LANE_6: '
                'pass=$lane6Pass outcome=${applyResult.outcome} selectedUpper=${applyResult.selectedUpper} '
                'recordingActiveAtApply=${applyResult.recordingActiveAtApply} isRecordingAtApply=${applyResult.isRecordingAtApply}',
              );

              if (lane6Pass) {
                // 7. Diagnostics while still recording reach consecutiveAppliedRangeCompletedCaptures >= 2,
                // applied range matches selected range, observed/applied upper < before, and isRecordingActive remains true.
                diagnosticsDuringRecording = await _pollDiagnosticsUntil(
                  (d) =>
                      d.consecutiveAppliedRangeCompletedCaptures >= 2 &&
                      d.isRecordingActive == true,
                  const Duration(seconds: 15),
                );

                lane7Pass =
                    diagnosticsDuringRecording
                            .consecutiveAppliedRangeCompletedCaptures >=
                        2 &&
                    diagnosticsDuringRecording.appliedAeTargetFpsUpper ==
                        applyResult.selectedUpper &&
                    diagnosticsDuringRecording.appliedAeTargetFpsLower ==
                        applyResult.selectedLower &&
                    diagnosticsDuringRecording.appliedRange != null &&
                    diagnosticsDuringRecording.appliedRange ==
                        applyResult.selectedRange &&
                    diagnosticsDuringRecording.appliedAeTargetFpsUpper! <
                        observedUpper &&
                    (diagnosticsDuringRecording.observedAeTargetFpsUpper ==
                            null ||
                        diagnosticsDuringRecording.observedAeTargetFpsUpper! <
                            observedUpper) &&
                    diagnosticsDuringRecording.isRecordingActive == true &&
                    diagnosticsDuringRecording.isRecording == true;
                print(
                  'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_LANE_7: '
                  'pass=$lane7Pass consecutive=${diagnosticsDuringRecording.consecutiveAppliedRangeCompletedCaptures} '
                  'appliedUpper=${diagnosticsDuringRecording.appliedAeTargetFpsUpper} '
                  'observedUpper=${diagnosticsDuringRecording.observedAeTargetFpsUpper} '
                  'isRecordingActive=${diagnosticsDuringRecording.isRecordingActive}',
                );

                // 8. No rebind across before/during: textureId, bindGeneration, bindCount,
                // surfaceRequestCount, cameraProviderIdentity unchanged.
                lane8Pass =
                    diagnosticsDuringRecording.textureId ==
                        diagnosticsBefore.textureId &&
                    diagnosticsDuringRecording.bindGeneration ==
                        diagnosticsBefore.bindGeneration &&
                    diagnosticsDuringRecording.bindCount ==
                        diagnosticsBefore.bindCount &&
                    diagnosticsDuringRecording.surfaceRequestCount ==
                        diagnosticsBefore.surfaceRequestCount &&
                    diagnosticsDuringRecording.cameraProviderIdentity ==
                        diagnosticsBefore.cameraProviderIdentity;
                print(
                  'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_LANE_8: '
                  'pass=$lane8Pass beforeTextureId=${diagnosticsBefore.textureId} '
                  'beforeBindGen=${diagnosticsBefore.bindGeneration} duringBindGen=${diagnosticsDuringRecording.bindGeneration}',
                );

                // 9. Stop recording finalizes; returned filePath is non-empty;
                // output exists, size > 0, first bytes include MP4 ftyp header.
                // Delete output only after recording assertions.
                final stopMap = await VanguardEngine.stopRecording().timeout(
                  const Duration(seconds: 15),
                );
                recordingStopped = true;

                returnedFilePath = (stopMap['filePath'] as String?) ?? '';
                final finalPath = returnedFilePath.isNotEmpty
                    ? returnedFilePath
                    : tempMp4Path;
                final outputFile = File(finalPath);
                recordedOutputFile = outputFile;

                final fileExists = await outputFile.exists();
                fileSize = fileExists ? await outputFile.length() : 0;

                hasFtyp = false;
                if (fileExists && fileSize >= 8) {
                  final raf = await outputFile.open();
                  try {
                    final headerBytes = await raf.read(64);
                    final headerAscii = String.fromCharCodes(headerBytes);
                    hasFtyp = headerAscii.contains('ftyp');
                  } finally {
                    await raf.close();
                  }
                }

                lane9Pass =
                    returnedFilePath.isNotEmpty &&
                    fileExists &&
                    fileSize > 0 &&
                    hasFtyp;
                print(
                  'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_LANE_9: '
                  'pass=$lane9Pass filePath=$returnedFilePath size=$fileSize hasFtyp=$hasFtyp',
                );

                // Delete output only after recording assertions.
                if (fileExists) {
                  try {
                    await outputFile.delete();
                  } catch (_) {
                    // Best-effort file cleanup.
                  }
                }

                // 10. Apply result still carries the existing bridge proofBoundary/nonClaims,
                // but harness JSON carries the mid-recording proof boundary.
                lane10Pass =
                    applyResult.proofBoundary == _bridgeExpectedProofBoundary &&
                    mapEquals(applyResult.nonClaims, _bridgeExpectedNonClaims);
                print(
                  'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_LANE_10: '
                  'pass=$lane10Pass bridgeProofBoundary=${applyResult.proofBoundary} '
                  'harnessProofBoundary=$_harnessProofBoundary',
                );
              }
            }
          }
        }
      }
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: CameraX Thermal FPS Recording-Safe Physical Smoke exceeded timeout: $te';
      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_PHYSICAL_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      if (_isRecordAudioPermissionBlocker(e)) {
        topLevelError = 'ENV_BLOCKER_RECORD_AUDIO_PERMISSION: $e';
      } else {
        topLevelError ??= '$e\n$st';
      }
      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_PHYSICAL_SMOKE_ERROR: $topLevelError',
      );
    } finally {
      // P0 teardown: never call stopCamera before stopRecording is awaited/finalized
      // if recording started. In finally, if recording started and not stopped,
      // attempt stopRecording with a bounded timeout first; tolerate no-active-recording errors.
      // Then call stopCamera. Delete temp output after final assertions and after stopping.
      if (recordingStarted && !recordingStopped) {
        try {
          await VanguardEngine.stopRecording().timeout(
            const Duration(seconds: 10),
          );
        } catch (_) {
          // Tolerate no-active-recording or already-finalized errors.
        }
        recordingStopped = true;
      }

      if (cameraStarted) {
        try {
          await VanguardEngine.stopCamera().timeout(
            const Duration(seconds: 10),
          );
        } catch (_) {
          // Best-effort teardown -- do not mask original failure.
        }
      }

      if (recordedOutputFile != null) {
        try {
          if (await recordedOutputFile.exists()) {
            await recordedOutputFile.delete();
          }
        } catch (_) {}
      }
      if (tempMp4File != null) {
        try {
          if (await tempMp4File.exists()) {
            await tempMp4File.delete();
          }
        } catch (_) {}
      }

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
        'unit': 'AndroidCameraXThermalFpsActuator',
        'slice': 'P3-CAM-THERMAL-ACT-CAMERAX-FPS-RECORDING-SAFE',
        'target': 'android_physical',
        'pass': allPass,
        'proofBoundary': _harnessProofBoundary,
        'nonClaims': _harnessNonClaims,
        'bridgeProofBoundary': applyResult?.proofBoundary,
        'bridgeNonClaims': applyResult?.nonClaims,
        'lanes': <String, dynamic>{
          'lane1_startCameraValidTextureId': {
            'pass': lane1Pass,
            'textureId': textureId,
          },
          'lane2_isCameraReadyPolledTrue': {'pass': lane2Pass},
          'lane3_diagnosticsBeforeCoherent': {
            'pass': lane3Pass,
            'diagnosticsBefore': diagnosticsBefore?.toMap(),
          },
          'lane4_startRecordingAndActive': {
            'pass': lane4Pass,
            'recordingStarted': recordingStarted,
            'recordingActive': recordingActive,
          },
          'lane5_plannerReduceFrameRate': {
            'pass': lane5Pass,
            'decision': plan?.decision.name,
            'targetFps': plan?.targetFps,
            'observedUpper': observedUpper,
          },
          'lane6_applyTargetFpsMidRecording': {
            'pass': lane6Pass,
            'outcome': applyResult?.outcome,
            'requestedTargetFps': applyResult?.requestedTargetFps,
            'selectedUpper': applyResult?.selectedUpper,
            'recordingActiveAtApply': applyResult?.recordingActiveAtApply,
            'isRecordingAtApply': applyResult?.isRecordingAtApply,
          },
          'lane7_consecutiveCapturesWhileRecording': {
            'pass': lane7Pass,
            'consecutiveAppliedRangeCompletedCaptures':
                diagnosticsDuringRecording
                    ?.consecutiveAppliedRangeCompletedCaptures,
            'appliedUpper': diagnosticsDuringRecording?.appliedAeTargetFpsUpper,
            'isRecordingActive': diagnosticsDuringRecording?.isRecordingActive,
          },
          'lane8_noRebindProof': {'pass': lane8Pass},
          'lane9_stopRecordingFinalizedMp4': {
            'pass': lane9Pass,
            'returnedFilePath': returnedFilePath,
            'fileSize': fileSize,
            'hasFtyp': hasFtyp,
          },
          'lane10_proofBoundaryAndNonClaims': {
            'pass': lane10Pass,
            'bridgeProofBoundary': applyResult?.proofBoundary,
            'bridgeNonClaims': applyResult?.nonClaims,
            'harnessProofBoundary': _harnessProofBoundary,
          },
        },
        'error': topLevelError,
      };

      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_PHYSICAL_SMOKE_PASS'
            : 'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_RECORDING_SAFE_PHYSICAL_SMOKE_FAIL',
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
