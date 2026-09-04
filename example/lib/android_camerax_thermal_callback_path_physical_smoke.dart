// android_camerax_thermal_callback_path_physical_smoke.dart
// Vanguard Media Engine -- P3-CAM-THERMAL-ACT-DART-CALLBACK-CAMERAX-WIRING:
// Android True-DAG foundation physical smoke proving the Dart thermal
// callback path (VGThermalMonitor.onThermalStateChanged / simulateThermalState)
// reaches the verified CameraX FPS actuator via
// VGCameraXThermalLoadSheddingCoordinator.
//
// Claim boundary: dart_thermal_callback_path_to_camerax_fps_mid_recording_synthetic_no_forced_heat_no_rebind_no_product
// Does NOT claim real OS thermal delivery -- simulateThermalState is a
// debug-only synthetic trigger of the same onThermalStateChanged callback
// path.
//
// Proof lanes:
//   Lane 1: startCamera returns a valid non-negative textureId.
//   Lane 2: isCameraReady polls true within the timeout window.
//   Lane 3: diagnostics before recording are coherent (observed FPS upper
//     non-null, no applied range yet).
//   Lane 4: startRecording(temp mp4) completes, then poll isRecordingActive
//     true.
//   Lane 5: coordinator is created and started before the simulated event;
//     runAndroidDagPhase3UnitTThermalListenerSmoke reports
//     listenerRegistered true when listenerApiSupported true.
//   Lane 6: simulateThermalState(serious) is issued and a coordinator report
//     is observed.
//   Lane 7: the report is applied: decision reduceFrameRate, applyResult
//     outcome APPLIED, recordingActiveAtApply/isRecordingAtApply true, and
//     report proofBoundary matches.
//   Lane 8: diagnostics polled until consecutiveAppliedRangeCompletedCaptures
//     >= 2 and isRecordingActive true; applied/observed upper matches the
//     selected upper; no rebind versus before (textureId, bindGeneration,
//     bindCount, surfaceRequestCount, cameraProviderIdentity unchanged).
//   Lane 9: stopRecording finalizes a non-empty MP4 with an ftyp header.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _proofBoundary =
    'dart_thermal_callback_path_to_camerax_fps_mid_recording_synthetic_no_forced_heat_no_rebind_no_product';

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
  runApp(const AndroidCameraXThermalCallbackPathPhysicalSmokeApp());
}

class AndroidCameraXThermalCallbackPathPhysicalSmokeApp extends StatefulWidget {
  const AndroidCameraXThermalCallbackPathPhysicalSmokeApp({super.key});

  @override
  State<AndroidCameraXThermalCallbackPathPhysicalSmokeApp> createState() =>
      _AndroidCameraXThermalCallbackPathPhysicalSmokeAppState();
}

class _AndroidCameraXThermalCallbackPathPhysicalSmokeAppState
    extends State<AndroidCameraXThermalCallbackPathPhysicalSmokeApp> {
  String _status =
      'Initializing CameraX Thermal Callback Path Physical Smoke...';

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
      'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_PHYSICAL_SMOKE_START',
    );
    String? topLevelError;
    int? textureId;
    VGCameraXThermalFpsDiagnostics? diagnosticsBefore;
    VGCameraXThermalFpsDiagnostics? diagnosticsDuringRecording;
    Map<String, dynamic>? listenerSmokeReport;
    VGCameraXThermalLoadSheddingCoordinatorReport? coordinatorReport;

    var cameraStarted = false;
    var recordingStarted = false;
    var recordingStopped = false;
    var recordingActive = false;
    var coordinatorStarted = false;
    String returnedFilePath = '';
    int fileSize = 0;
    bool hasFtyp = false;

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
    var lane9Pass = false;

    try {
      // 0. Wait to allow the grant runner to grant CAMERA and RECORD_AUDIO.
      await Future<void>.delayed(const Duration(seconds: 5));

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final uniqueName = 'camerax_thermal_callback_path_${timestamp}_$pid.mp4';
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
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_LANE_1: pass=$lane1Pass textureId=$textureId',
      );

      // 2. Poll isCameraReady becomes true.
      final ready = await _pollIsCameraReady(const Duration(seconds: 15));
      lane2Pass = ready;
      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_LANE_2: pass=$lane2Pass ready=$ready',
      );

      if (lane1Pass && lane2Pass) {
        // 3. Diagnostics before recording are coherent.
        diagnosticsBefore = await _pollDiagnosticsUntil(
          (d) => d.observedAeTargetFpsUpper != null,
          const Duration(seconds: 10),
        );

        lane3Pass =
            diagnosticsBefore.running == true &&
            diagnosticsBefore.textureId == textureId &&
            diagnosticsBefore.observedAeTargetFpsUpper != null &&
            diagnosticsBefore.appliedRange == null;
        print(
          'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_LANE_3: pass=$lane3Pass diagnosticsBefore=$diagnosticsBefore',
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
            'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_LANE_4: pass=$lane4Pass recordingActive=$recordingActive',
          );

          if (lane4Pass) {
            // 5. Create/start the coordinator before simulating, then prove
            // the raw listener registration route.
            coordinator = VGCameraXThermalLoadSheddingCoordinator();
            coordinator.start();
            coordinatorStarted = true;

            final rawReport = await _rawChannel
                .invokeMethod<Object?>(
                  'runAndroidDagPhase3UnitTThermalListenerSmoke',
                )
                .timeout(const Duration(seconds: 15));
            listenerSmokeReport = Map<String, dynamic>.from(rawReport! as Map);
            final listenerDiagnostics = Map<String, dynamic>.from(
              listenerSmokeReport['diagnostics'] as Map? ?? const {},
            );
            final listenerApiSupported =
                listenerDiagnostics['listenerApiSupported'] == true;
            final listenerRegistered =
                listenerDiagnostics['listenerRegistered'] == true;

            lane5Pass =
                listenerSmokeReport['success'] == true &&
                (!listenerApiSupported || listenerRegistered);
            print(
              'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_LANE_5: '
              'pass=$lane5Pass listenerApiSupported=$listenerApiSupported '
              'listenerRegistered=$listenerRegistered',
            );

            if (lane5Pass) {
              // 6. Simulate a serious thermal transition and await a
              // coordinator report.
              final reportFuture = coordinator.reports.first;
              await VGThermalMonitor.simulateThermalState(
                VGThermalState.serious,
              );
              coordinatorReport = await reportFuture.timeout(
                const Duration(seconds: 15),
              );
              lane6Pass =
                  coordinatorReport.thermalState == VGThermalState.serious;
              print(
                'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_LANE_6: '
                'pass=$lane6Pass report=$coordinatorReport',
              );

              if (lane6Pass) {
                // 7. Report is applied with the expected shape.
                lane7Pass =
                    coordinatorReport.applied == true &&
                    coordinatorReport.evaluation?.decision ==
                        VGCamera2ThermalLoadSheddingDecision.reduceFrameRate &&
                    coordinatorReport.applyResult?.outcome == 'APPLIED' &&
                    coordinatorReport.applyResult?.recordingActiveAtApply ==
                        true &&
                    coordinatorReport.applyResult?.isRecordingAtApply == true &&
                    VGCameraXThermalLoadSheddingCoordinatorReport
                            .proofBoundary ==
                        _proofBoundary;
                print(
                  'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_LANE_7: '
                  'pass=$lane7Pass applied=${coordinatorReport.applied} '
                  'decision=${coordinatorReport.evaluation?.decision} '
                  'outcome=${coordinatorReport.applyResult?.outcome}',
                );

                if (lane7Pass) {
                  // 8. Diagnostics reach the applied-range consecutive
                  // capture bar mid-recording; no rebind vs. before.
                  diagnosticsDuringRecording = await _pollDiagnosticsUntil(
                    (d) =>
                        d.consecutiveAppliedRangeCompletedCaptures >= 2 &&
                        d.isRecordingActive == true,
                    const Duration(seconds: 15),
                  );

                  final selectedUpper =
                      coordinatorReport.applyResult!.selectedUpper;
                  lane8Pass =
                      diagnosticsDuringRecording
                              .consecutiveAppliedRangeCompletedCaptures >=
                          2 &&
                      diagnosticsDuringRecording.isRecordingActive == true &&
                      diagnosticsDuringRecording.appliedAeTargetFpsUpper ==
                          selectedUpper &&
                      (diagnosticsDuringRecording.observedAeTargetFpsUpper ==
                              null ||
                          diagnosticsDuringRecording.observedAeTargetFpsUpper ==
                              selectedUpper) &&
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
                    'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_LANE_8: '
                    'pass=$lane8Pass selectedUpper=$selectedUpper '
                    'appliedUpper=${diagnosticsDuringRecording.appliedAeTargetFpsUpper} '
                    'consecutive=${diagnosticsDuringRecording.consecutiveAppliedRangeCompletedCaptures}',
                  );

                  // 9. Stop recording finalizes a non-empty MP4 with an
                  // ftyp header.
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
                    'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_LANE_9: '
                    'pass=$lane9Pass filePath=$returnedFilePath size=$fileSize hasFtyp=$hasFtyp',
                  );

                  if (fileExists) {
                    try {
                      await outputFile.delete();
                    } catch (_) {
                      // Best-effort file cleanup.
                    }
                  }
                }
              }
            }
          }
        }
      }
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: CameraX Thermal Callback Path Physical Smoke exceeded timeout: $te';
      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_PHYSICAL_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      if (_isRecordAudioPermissionBlocker(e)) {
        topLevelError = 'ENV_BLOCKER_RECORD_AUDIO_PERMISSION: $e';
      } else {
        topLevelError ??= '$e\n$st';
      }
      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_PHYSICAL_SMOKE_ERROR: $topLevelError',
      );
    } finally {
      // P0 teardown: never call stopCamera before stopRecording is
      // awaited/finalized if recording started.
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
          lane9Pass &&
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'VGCameraXThermalLoadSheddingCoordinator',
        'slice': 'P3-CAM-THERMAL-ACT-DART-CALLBACK-CAMERAX-WIRING',
        'target': 'android_physical',
        'pass': allPass,
        'proofBoundary': _proofBoundary,
        'nonClaims': VGCameraXThermalLoadSheddingCoordinatorReport.nonClaims,
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
          'lane5_listenerRegisteredBeforeSimulate': {
            'pass': lane5Pass,
            'listenerSmokeReport': listenerSmokeReport,
          },
          'lane6_coordinatorReportObserved': {
            'pass': lane6Pass,
            'report': coordinatorReport?.toMap(),
          },
          'lane7_reportAppliedReduceFrameRate': {
            'pass': lane7Pass,
            'applied': coordinatorReport?.applied,
            'decision': coordinatorReport?.evaluation?.decision.name,
            'outcome': coordinatorReport?.applyResult?.outcome,
          },
          'lane8_diagnosticsAppliedRangeNoRebind': {
            'pass': lane8Pass,
            'diagnosticsDuringRecording': diagnosticsDuringRecording?.toMap(),
          },
          'lane9_stopRecordingFinalizedMp4': {
            'pass': lane9Pass,
            'returnedFilePath': returnedFilePath,
            'fileSize': fileSize,
            'hasFtyp': hasFtyp,
          },
        },
        'error': topLevelError,
      };

      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_PHYSICAL_SMOKE_PASS'
            : 'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_CALLBACK_PATH_PHYSICAL_SMOKE_FAIL',
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
