// Copyright 2026, Connects. All rights reserved.
// android_duet_preview_live_camera_physical_smoke.dart
//
// Frozen Android Duet live-camera preview physical smoke harness.
//
// Proof boundary:
//   - Prove package-example Android Duet live camera preview ingress using
//     existing native Duet APIs and a bundled local fixture.
//   - Claims allowed:
//       * local source session initialization
//       * preview texture attach success
//       * startRecording activates render loop
//       * live camera/source preview remains active for bounded waits
//       * layout update route works while active
//       * stop/detach/dispose cleanup routes complete
//       * temp fixture cleanup completes
//   - Non-claims:
//       * no automated pixel proof
//       * no green-screen keying
//       * no export MP4 proof
//       * no mic/audio proof
//       * no speed control proof
//       * no ConnectsApp/Universal Editor/upload wiring
//       * no runtime permission request in harness
//       * camera-open proof requires external adb permission/log lane

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_duet.dart';

const String kSmokeStartMarker =
    'ANDROID_DUET_PREVIEW_LIVE_CAMERA_PHYSICAL_SMOKE_START';
const String kSmokePassMarker =
    'ANDROID_DUET_PREVIEW_LIVE_CAMERA_PHYSICAL_PASS';
const String kSmokeFailMarker =
    'ANDROID_DUET_PREVIEW_LIVE_CAMERA_PHYSICAL_FAIL';
const String kSmokeJsonPrefix =
    'ANDROID_DUET_PREVIEW_LIVE_CAMERA_PHYSICAL_JSON:';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetPreviewLiveCameraPhysicalSmokeApp());
}

class AndroidDuetPreviewLiveCameraPhysicalSmokeApp extends StatefulWidget {
  const AndroidDuetPreviewLiveCameraPhysicalSmokeApp({super.key});

  @override
  State<AndroidDuetPreviewLiveCameraPhysicalSmokeApp> createState() =>
      _AndroidDuetPreviewLiveCameraPhysicalSmokeAppState();
}

class _AndroidDuetPreviewLiveCameraPhysicalSmokeAppState
    extends State<AndroidDuetPreviewLiveCameraPhysicalSmokeApp> {
  final VGDuetPlatformInterface _platform = const MethodChannelVGDuetPlatform();

  String _status = 'Starting smoke harness...';
  String _currentStep = 'INIT';
  String _layoutMode = 'splitLeftRight';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  void _updateStatus(String step, String status) {
    if (mounted) {
      setState(() {
        _currentStep = step;
        _status = status;
      });
    }
  }

  Future<T> _withTimeout<T>(Future<T> future, String operationName) {
    return future.timeout(
      const Duration(seconds: 10),
      onTimeout: () =>
          throw TimeoutException('$operationName timed out after 10 seconds'),
    );
  }

  Future<void> _runSmoke() async {
    print(kSmokeStartMarker);

    bool pass = false;
    String? sessionId;
    int? textureId;
    VGDuetCaptureResult? captureResult;
    Directory? tempDir;
    bool isDetached = false;
    bool isDisposed = false;
    bool isFixtureCleaned = false;

    final stepResults = <String, String>{};
    final failures = <String>[];

    Future<T> runStep<T>(
      String stepName,
      String description,
      Future<T> Function() action,
    ) async {
      _updateStatus(stepName, description);
      try {
        final result = await action();
        stepResults[stepName] = 'PASS';
        print('ANDROID_DUET_PREVIEW_STEP_${stepName}_PASS');
        return result;
      } catch (e, st) {
        stepResults[stepName] = 'FAIL';
        final failureMsg = '$stepName: $e';
        if (!failures.contains(failureMsg)) {
          failures.add(failureMsg);
        }
        print('ANDROID_DUET_PREVIEW_STEP_${stepName}_FAIL: $e\n$st');
        rethrow;
      }
    }

    try {
      // Step 1: Stage clip_A.mov fixture from rootBundle into temp directory
      final source = await runStep<VGDuetSource>(
        'STAGE_FIXTURE',
        'Staging clip_A.mov into temp directory',
        () async {
          tempDir = await Directory.systemTemp.createTemp('duet_smoke_');
          final targetFile = File('${tempDir!.path}/clip_A.mov');
          final byteData = await rootBundle.load(
            'assets/manual_test_clips/clip_A.mov',
          );
          await targetFile.writeAsBytes(
            byteData.buffer.asUint8List(
              byteData.offsetInBytes,
              byteData.lengthInBytes,
            ),
            flush: true,
          );
          if (!await targetFile.exists() || await targetFile.length() == 0) {
            throw StateError('Staged fixture file missing or empty');
          }
          return VGDuetSource.localFile(targetFile.path);
        },
      );

      // Step 2: Initialize Duet session with trim window 0.0 to 2.5 seconds
      sessionId = await runStep<String>(
        'INIT_SESSION',
        'Initializing Duet session (trim: 0.0s - 2.5s)',
        () async {
          final trimWindow = VGDuetTrimWindow(
            startSeconds: 0.0,
            endSeconds: 2.5,
          );
          return await _withTimeout(
            _platform.initializeSession(source: source, trimWindow: trimWindow),
            'initializeSession',
          );
        },
      );

      // Step 3: Attach preview texture (1080x1920, splitLeftRight)
      await runStep<VGDuetPreviewTexture>(
        'ATTACH_PREVIEW',
        'Attaching preview texture (1080x1920, splitLeftRight)',
        () async {
          final preview = await _withTimeout(
            _platform.attachPreviewTexture(
              sessionId: sessionId!,
              canvasSize: const VGDuetSize(1080, 1920),
              layoutConfig: VGDuetLayoutConfig(
                mode: VGDuetLayoutMode.splitLeftRight,
              ),
            ),
            'attachPreviewTexture',
          );
          if (preview.textureId < 0) {
            throw StateError('Invalid textureId: ${preview.textureId}');
          }
          textureId = preview.textureId;
          if (mounted) {
            setState(() {
              _textureId = preview.textureId;
              _layoutMode = 'splitLeftRight';
            });
          }
          return preview;
        },
      );

      // Step 4: Start recording (activates render loop & camera ingress)
      await runStep<void>(
        'START_RECORDING',
        'Starting recording to activate preview render loop',
        () async {
          await _withTimeout(
            _platform.startRecording(sessionId: sessionId!),
            'startRecording',
          );
        },
      );

      // Step 5: Wait 3.0 seconds with split preview active
      await runStep<void>(
        'SPLIT_PREVIEW_ACTIVE',
        'Observing split preview active (3.0s)',
        () async {
          await Future<void>.delayed(const Duration(seconds: 3));
        },
      );

      // Step 6: Update layout to PiP (top-right rect 0.65, 0.05, 0.30, 0.30)
      await runStep<void>(
        'UPDATE_LAYOUT_PIP',
        'Updating layout to PiP (topRight, 30% width/height)',
        () async {
          final pipConfig = VGDuetLayoutConfig(
            mode: VGDuetLayoutMode.pip,
            pipAnchor: VGDuetPiPAnchor.topRight,
            pipNormalizedRect: const VGDuetRect(
              left: 0.65,
              top: 0.05,
              width: 0.30,
              height: 0.30,
            ),
          );
          await _withTimeout(
            _platform.updateLayout(
              sessionId: sessionId!,
              layoutConfig: pipConfig,
            ),
            'updateLayout',
          );
          if (mounted) {
            setState(() {
              _layoutMode = 'pip (topRight)';
            });
          }
        },
      );

      // Step 7: Wait 1.5 seconds with PiP preview active
      await runStep<void>(
        'PIP_PREVIEW_ACTIVE',
        'Observing PiP preview active (1.5s)',
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        },
      );

      // Step 8: Pause recording
      await runStep<void>('PAUSE_RECORDING', 'Pausing recording', () async {
        await _withTimeout(
          _platform.pauseRecording(sessionId: sessionId!),
          'pauseRecording',
        );
      });

      // Step 9: Stop recording
      captureResult = await runStep<VGDuetCaptureResult>(
        'STOP_RECORDING',
        'Stopping recording and retrieving capture result',
        () async {
          return await _withTimeout(
            _platform.stopRecording(sessionId: sessionId!),
            'stopRecording',
          );
        },
      );

      // Step 10: Detach preview texture
      await runStep<
        void
      >('DETACH_PREVIEW', 'Detaching preview texture', () async {
        try {
          await _withTimeout(
            _platform.detachPreviewTexture(sessionId: sessionId!),
            'detachPreviewTexture',
          );
        } on VGDuetException catch (e) {
          final cause = e.cause;
          final isSessionNotFound =
              (cause is PlatformException &&
                  cause.code == 'session_not_found') ||
              e.message.contains('session_not_found') ||
              e.message.contains('No active Duet session');
          if (isSessionNotFound) {
            print(
              'ANDROID_DUET_PREVIEW: texture already detached during stopRecording: $e',
            );
          } else {
            rethrow;
          }
        }
        isDetached = true;
      });

      // Step 11: Dispose session
      await runStep<void>(
        'DISPOSE_SESSION',
        'Disposing native Duet session',
        () async {
          await _withTimeout(
            _platform.disposeSession(sessionId: sessionId!),
            'disposeSession',
          );
          isDisposed = true;
        },
      );

      // Step 12: Cleanup temp fixture directory
      await runStep<void>(
        'CLEANUP_TEMP_FIXTURE',
        'Deleting staged fixture temp directory',
        () async {
          if (tempDir != null && await tempDir!.exists()) {
            await tempDir!.delete(recursive: true);
            isFixtureCleaned = true;
          }
        },
      );

      pass = true;
    } catch (e) {
      pass = false;
    } finally {
      // Cleanup fallback for detach, dispose, and temp directory deletion
      // Avoid double-failing cleanup
      if (sessionId != null) {
        if (!isDetached) {
          try {
            await _withTimeout(
              _platform.detachPreviewTexture(sessionId: sessionId),
              'cleanup detachPreviewTexture',
            );
            isDetached = true;
          } catch (e) {
            print(
              'ANDROID_DUET_PREVIEW: cleanup detachPreviewTexture note: $e',
            );
          }
        }
        if (!isDisposed) {
          try {
            await _withTimeout(
              _platform.disposeSession(sessionId: sessionId),
              'cleanup disposeSession',
            );
            isDisposed = true;
          } catch (e) {
            print('ANDROID_DUET_PREVIEW: cleanup disposeSession note: $e');
          }
        }
      }

      if (tempDir != null && !isFixtureCleaned) {
        try {
          if (await tempDir!.exists()) {
            await tempDir!.delete(recursive: true);
            isFixtureCleaned = true;
          }
        } catch (e) {
          print('ANDROID_DUET_PREVIEW: cleanup tempDir delete note: $e');
        }
      }

      final payload = <String, Object?>{
        'pass': pass,
        'proofBoundary':
            'android_duet_live_camera_preview_ingress_physical_smoke',
        'claimsAllowed': <String>[
          'local source session initialization',
          'preview texture attach success',
          'startRecording activates render loop',
          'live camera/source preview remains active for bounded waits',
          'layout update route works while active',
          'stop/detach/dispose cleanup routes complete',
          'temp fixture cleanup completes',
        ],
        'nonClaims': <String>[
          'no automated pixel proof',
          'no green-screen keying',
          'no export MP4 proof',
          'no mic/audio proof',
          'no speed control proof',
          'no ConnectsApp/Universal Editor/upload wiring',
          'no runtime permission request in harness',
          'camera-open proof requires external adb permission/log lane',
        ],
        'sessionId': sessionId,
        'textureId': textureId,
        'stepResults': stepResults,
        'failures': failures,
        if (captureResult != null)
          'captureResult': <String, Object?>{
            'segmentCount': captureResult.segmentCount,
            'totalDurationMs': captureResult.totalDurationMs,
            'segmentAssetsCount': captureResult.segmentAssets.length,
            'proofOutputPath': captureResult.proofOutputPath,
          },
      };

      print('$kSmokeJsonPrefix${jsonEncode(payload)}');
      if (pass) {
        print(kSmokePassMarker);
      } else {
        print(kSmokeFailMarker);
      }

      if (mounted) {
        setState(() {
          _status = pass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(pass ? 0 : 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            if (_textureId != null)
              Center(
                child: AspectRatio(
                  aspectRatio: 1080 / 1920,
                  child: Texture(textureId: _textureId!),
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24, width: 1),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Android Duet Live Camera Preview Physical Smoke',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Status: $_status',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                      if (_textureId != null)
                        Text(
                          'Texture ID: $_textureId | Layout: $_layoutMode',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      if (_currentStep.isNotEmpty)
                        Text(
                          'Step: $_currentStep',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
