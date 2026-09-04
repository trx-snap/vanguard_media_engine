// android_camerax_thermal_critical_stop_physical_smoke.dart
// Vanguard Media Engine -- P3-CAM-THERMAL-ACT-CAMERAX-CRITICAL-STOP-RECORDING:
// Android True-DAG foundation physical smoke proving the Dart thermal
// callback/stream critical-stop-recording action via
// VGCameraXThermalLoadSheddingCoordinator: a `critical` thermal event that
// arrives while a `serious` FPS-apply event is in flight latches, is
// reported as `apply_in_progress`-skipped, and is then processed once the
// in-flight FPS apply completes, invoking the real stop-recording action.
//
// Claim boundary: dart_thermal_callback_critical_stop_recording_mid_recording_synthetic_no_forced_heat_no_rebind_no_product
// Does NOT claim real OS thermal delivery, real forced overheat, PowerManager
// thermal-state mutation, resolution reconfiguration, secondary-camera
// disablement, product/UI wiring, or fleet proof beyond SM-A566B --
// simulateThermalState is a debug-only synthetic trigger of the same
// onThermalStateChanged callback path.
//
// Proof lanes:
//   Lane 1: startCamera returns a valid non-negative textureId.
//   Lane 2: isCameraReady polls true within the timeout window.
//   Lane 3: diagnostics before recording are coherent.
//   Lane 4: startRecording(temp mp4) completes, then poll isRecordingActive
//     true.
//   Lane 5: coordinator is created and started before any simulated thermal
//     event.
//   Lane 6: simulateThermalState(serious) then, without awaiting the
//     coordinator's processing, simulateThermalState(critical) is issued
//     immediately; a report with thermalState critical, skipped true,
//     reason apply_in_progress is observed before any stoppedRecording
//     report (latch proof -- a direct stoppedRecording report with no prior
//     apply_in_progress skip fails this lane).
//   Lane 7: a later report has stoppedRecording true, decision stopRecording,
//     and a non-empty filePath; the serious report (if observed) is applied
//     with decision reduceFrameRate and applyResult outcome APPLIED.
//   Lane 8: the finalized MP4 at the reported filePath exists, has size > 0,
//     and has an ftyp header.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _proofBoundary =
    VGCameraXThermalLoadSheddingCoordinatorReport.criticalStopProofBoundary;

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
  runApp(const AndroidCameraXThermalCriticalStopPhysicalSmokeApp());
}

class AndroidCameraXThermalCriticalStopPhysicalSmokeApp extends StatefulWidget {
  const AndroidCameraXThermalCriticalStopPhysicalSmokeApp({super.key});

  @override
  State<AndroidCameraXThermalCriticalStopPhysicalSmokeApp> createState() =>
      _AndroidCameraXThermalCriticalStopPhysicalSmokeAppState();
}

class _AndroidCameraXThermalCriticalStopPhysicalSmokeAppState
    extends State<AndroidCameraXThermalCriticalStopPhysicalSmokeApp> {
  String _status =
      'Initializing CameraX Thermal Critical Stop Physical Smoke...';

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

  Future<void> _runSmoke() async {
    print(
      'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_PHYSICAL_SMOKE_START',
    );
    String? topLevelError;
    int? textureId;
    VGCameraXThermalFpsDiagnostics? diagnosticsBefore;

    var cameraStarted = false;
    var recordingStarted = false;
    var recordingStoppedByCoordinator = false;
    var recordingActive = false;
    var coordinatorStarted = false;

    File? tempMp4File;
    File? recordedOutputFile;
    VGCameraXThermalLoadSheddingCoordinator? coordinator;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;
    var lane8Pass = false;

    VGCameraXThermalLoadSheddingCoordinatorReport? seriousReport;
    VGCameraXThermalLoadSheddingCoordinatorReport? criticalSkipReport;
    VGCameraXThermalLoadSheddingCoordinatorReport? stoppedReport;
    var sawDirectStopWithoutSkip = false;
    var returnedFilePath = '';
    var fileSize = 0;
    var hasFtyp = false;

    try {
      // 0. Wait to allow the grant runner to grant CAMERA and RECORD_AUDIO.
      await Future<void>.delayed(const Duration(seconds: 5));

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final uniqueName = 'camerax_thermal_critical_stop_${timestamp}_$pid.mp4';
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
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_LANE_1: pass=$lane1Pass textureId=$textureId',
      );

      // 2. Poll isCameraReady becomes true.
      final ready = await _pollIsCameraReady(const Duration(seconds: 15));
      lane2Pass = ready;
      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_LANE_2: pass=$lane2Pass ready=$ready',
      );

      if (lane1Pass && lane2Pass) {
        // 3. Diagnostics before recording are coherent.
        diagnosticsBefore = await bridge
            .getAndroidCameraXThermalFpsDiagnostics();
        lane3Pass = diagnosticsBefore.running == true;
        print(
          'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_LANE_3: pass=$lane3Pass diagnosticsBefore=$diagnosticsBefore',
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
            'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_LANE_4: pass=$lane4Pass recordingActive=$recordingActive',
          );

          if (lane4Pass) {
            // 5. Create/start the coordinator before any simulated thermal
            // event, wired to a local synthetic thermal-state stream (not
            // the default VGThermalMonitor.simulate path) so the
            // serious-in-flight/critical-race timing is deterministic
            // instead of relying on MethodChannel scheduling. The wrapped
            // apply still calls the real bridge apply; only the thermal
            // event source and apply-completion timing are controlled here.
            // Uses the default stopRecordingAction (VanguardEngine.stopRecording)
            // for a real stop.
            final thermalController =
                StreamController<VGThermalState>.broadcast();
            final applyStarted = Completer<void>();
            final allowApplyReport = Completer<void>();

            Future<VGCameraXThermalFpsApplyResult> heldApply(
              int targetFps,
            ) async {
              if (!applyStarted.isCompleted) applyStarted.complete();
              final result = await bridge.applyAndroidCameraXThermalTargetFps(
                targetFps,
              );
              await allowApplyReport.future.timeout(
                const Duration(seconds: 20),
                onTimeout: () {
                  if (!allowApplyReport.isCompleted) {
                    allowApplyReport.complete();
                  }
                },
              );
              return result;
            }

            coordinator = VGCameraXThermalLoadSheddingCoordinator(
              thermalStates: thermalController.stream,
              applyTargetFps: heldApply,
              getDiagnostics: bridge.getAndroidCameraXThermalFpsDiagnostics,
              stopRecordingAction: VanguardEngine.stopRecording,
            );
            coordinator.start();
            coordinatorStarted = true;
            lane5Pass = coordinator.isRunning;
            print(
              'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_LANE_5: pass=$lane5Pass',
            );

            if (lane5Pass) {
              // 6. Push serious on the synthetic stream, await proof that
              // the real apply wrapper was reached, then push critical while
              // the wrapper is still held -- this deterministically races
              // the critical event against the in-flight serious FPS-apply,
              // exercising the pending-critical-stop latch without relying
              // on VGThermalMonitor.simulate scheduling.
              final reportsList =
                  <VGCameraXThermalLoadSheddingCoordinatorReport>[];
              final subscription = coordinator.reports.listen((r) {
                reportsList.add(r);
                print(
                  'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_REPORT: $r',
                );
              });

              thermalController.add(VGThermalState.serious);

              try {
                await applyStarted.future.timeout(const Duration(seconds: 15));
              } on TimeoutException {
                // Proceed regardless; lanes 6/7 fail naturally below if the
                // real apply wrapper was never reached.
              }

              thermalController.add(VGThermalState.critical);

              final skipDeadline = DateTime.now().add(
                const Duration(seconds: 20),
              );
              while (DateTime.now().isBefore(skipDeadline)) {
                for (final r in reportsList) {
                  if (r.thermalState == VGThermalState.critical &&
                      r.skipped == true &&
                      r.reason ==
                          VGCameraXThermalLoadSheddingCoordinator
                              .reasonApplyInProgress) {
                    criticalSkipReport ??= r;
                  }
                }
                if (criticalSkipReport != null) break;
                await Future<void>.delayed(const Duration(milliseconds: 100));
              }

              if (!allowApplyReport.isCompleted) allowApplyReport.complete();

              final deadline = DateTime.now().add(const Duration(seconds: 30));
              while (DateTime.now().isBefore(deadline)) {
                for (final r in reportsList) {
                  if (r.thermalState == VGThermalState.serious &&
                      r.applied == true) {
                    seriousReport ??= r;
                  }
                  if (r.stoppedRecording == true) {
                    stoppedReport ??= r;
                  }
                }
                if (stoppedReport != null) break;
                await Future<void>.delayed(const Duration(milliseconds: 100));
              }
              await subscription.cancel();
              await thermalController.close();

              if (stoppedReport != null && criticalSkipReport == null) {
                sawDirectStopWithoutSkip = true;
              }
              recordingStoppedByCoordinator =
                  stoppedReport?.stoppedRecording == true;

              lane6Pass =
                  criticalSkipReport != null && !sawDirectStopWithoutSkip;
              print(
                'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_LANE_6: '
                'pass=$lane6Pass sawDirectStopWithoutSkip=$sawDirectStopWithoutSkip '
                'criticalSkipReport=$criticalSkipReport',
              );

              final seriousLooksApplied =
                  seriousReport == null ||
                  (seriousReport.evaluation?.decision ==
                          VGCamera2ThermalLoadSheddingDecision
                              .reduceFrameRate &&
                      seriousReport.applyResult?.outcome == 'APPLIED');

              lane7Pass =
                  stoppedReport != null &&
                  stoppedReport.stoppedRecording == true &&
                  stoppedReport.evaluation?.decision ==
                      VGCamera2ThermalLoadSheddingDecision.stopRecording &&
                  (stoppedReport.filePath?.isNotEmpty ?? false) &&
                  seriousLooksApplied;
              print(
                'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_LANE_7: '
                'pass=$lane7Pass stoppedReport=$stoppedReport seriousReport=$seriousReport',
              );

              if (lane7Pass) {
                // 8. Finalized MP4 exists, has size > 0, and has an ftyp
                // header.
                returnedFilePath = stoppedReport.filePath ?? '';
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

                lane8Pass =
                    returnedFilePath.isNotEmpty &&
                    fileExists &&
                    fileSize > 0 &&
                    hasFtyp;
                print(
                  'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_LANE_8: '
                  'pass=$lane8Pass filePath=$returnedFilePath size=$fileSize hasFtyp=$hasFtyp',
                );
              }
            }
          }
        }
      }
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: CameraX Thermal Critical Stop Physical Smoke exceeded timeout: $te';
      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_PHYSICAL_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      if (_isRecordAudioPermissionBlocker(e)) {
        topLevelError = 'ENV_BLOCKER_RECORD_AUDIO_PERMISSION: $e';
      } else {
        topLevelError ??= '$e\n$st';
      }
      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_PHYSICAL_SMOKE_ERROR: $topLevelError',
      );
    } finally {
      // P0 teardown: if recording started and was not stopped by the
      // coordinator's real stop-recording action, stop it explicitly
      // (bounded) before stopCamera. Never call stopCamera before recording
      // is finalized.
      if (recordingStarted && !recordingStoppedByCoordinator) {
        try {
          await VanguardEngine.stopRecording().timeout(
            const Duration(seconds: 10),
          );
        } catch (_) {
          // Tolerate no-active-recording or already-finalized errors.
        }
      }

      if (coordinatorStarted && coordinator != null) {
        try {
          await coordinator.dispose();
        } catch (_) {
          // Best-effort teardown.
        }
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
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'VGCameraXThermalLoadSheddingCoordinator',
        'slice': 'P3-CAM-THERMAL-ACT-CAMERAX-CRITICAL-STOP-RECORDING',
        'target': 'android_physical',
        'pass': allPass,
        'proofBoundary': _proofBoundary,
        'nonClaims':
            VGCameraXThermalLoadSheddingCoordinatorReport.criticalStopNonClaims,
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
          'lane5_coordinatorStartedBeforeSimulate': {'pass': lane5Pass},
          'lane6_criticalLatchesWhileSeriousInFlight': {
            'pass': lane6Pass,
            'sawDirectStopWithoutSkip': sawDirectStopWithoutSkip,
            'criticalSkipReport': criticalSkipReport?.toMap(),
          },
          'lane7_stoppedRecordingReportShape': {
            'pass': lane7Pass,
            'stoppedReport': stoppedReport?.toMap(),
            'seriousReport': seriousReport?.toMap(),
          },
          'lane8_finalizedMp4NonEmptyFtyp': {
            'pass': lane8Pass,
            'returnedFilePath': returnedFilePath,
            'fileSize': fileSize,
            'hasFtyp': hasFtyp,
          },
        },
        'error': topLevelError,
      };

      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_PHYSICAL_SMOKE_PASS'
            : 'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CRITICAL_STOP_PHYSICAL_SMOKE_FAIL',
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
