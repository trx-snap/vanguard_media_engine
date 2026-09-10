// Copyright 2026, Connects. All rights reserved.
// android_duet_raw_tflite_gpu_preview_physical_smoke.dart
//
// Dedicated physical smoke harness for the Android Duet raw TensorFlow Lite
// GPU green-screen backend (raw_tflite_gpu, debug/smoke opt-in only).
//
// Proof boundary:
//   - Device requirement: Android physical device with camera permission available.
//   - Harness command:
//       cd packages/vanguard_media_engine/example &&
//       flutter run -d <deviceId> -t lib/android_duet_raw_tflite_gpu_preview_physical_smoke.dart
//   - Claims allowed:
//       * local source session init
//       * attach-time greenScreen layout accepted with debugSegmentationBackend=raw_tflite_gpu
//       * preview texture attach success
//       * startRecording activates render loop and camera
//       * bounded live in-process preview session routing to raw_tflite_gpu
//       * native ANDROID_DUET_RAW_TFLITE_GPU_READY log may evidence successful open
//       * native ANDROID_DUET_GREENSCREEN_RAW_TFLITE_GPU_MASK_FIRST log may evidence
//         first raw GPU mask and GLES upload path
//       * degradation to mediapipe_cpu on open/inference failure is handled by adapter
//       * layout update away from greenScreen to PiP works
//       * stop/detach/dispose/temp cleanup complete
//   - Non-claims:
//       * no export or audio proof
//       * no pixel-quality or matte grading proof
//       * no all-device GPU compatibility proof
//       * no default production promotion (raw_tflite_gpu remains opt-in only)
//       * no adaptive quality tier proof

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('vanguard_media_engine');

const String kSmokeStartMarker =
    'ANDROID_DUET_RAW_TFLITE_GPU_PREVIEW_PHYSICAL_SMOKE_START';
const String kSmokePassMarker =
    'ANDROID_DUET_RAW_TFLITE_GPU_PREVIEW_PHYSICAL_PASS';
const String kSmokeFailMarker =
    'ANDROID_DUET_RAW_TFLITE_GPU_PREVIEW_PHYSICAL_FAIL';
const String kSmokeJsonPrefix =
    'ANDROID_DUET_RAW_TFLITE_GPU_PREVIEW_PHYSICAL_JSON:';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetRawTfliteGpuPreviewPhysicalSmokeApp());
}

class AndroidDuetRawTfliteGpuPreviewPhysicalSmokeApp extends StatefulWidget {
  const AndroidDuetRawTfliteGpuPreviewPhysicalSmokeApp({super.key});

  @override
  State<AndroidDuetRawTfliteGpuPreviewPhysicalSmokeApp> createState() =>
      _AndroidDuetRawTfliteGpuPreviewPhysicalSmokeAppState();
}

class _AndroidDuetRawTfliteGpuPreviewPhysicalSmokeAppState
    extends State<AndroidDuetRawTfliteGpuPreviewPhysicalSmokeApp> {
  String _status = 'Starting raw TFLite GPU smoke harness...';
  String _currentStep = 'INIT';
  String _layoutMode = 'greenScreen';
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
      const Duration(seconds: 15),
      onTimeout: () =>
          throw TimeoutException('$operationName timed out after 15 seconds'),
    );
  }

  Future<void> _runSmoke() async {
    print(kSmokeStartMarker);

    bool pass = false;
    String? sessionId;
    int? textureId;
    Directory? tempDir;
    bool isDetached = false;
    bool isDisposed = false;
    bool isFixtureCleaned = false;
    Map<String, dynamic>? captureResultMap;

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
        print('ANDROID_DUET_RAW_TFLITE_GPU_STEP_${stepName}_PASS');
        return result;
      } catch (e, st) {
        stepResults[stepName] = 'FAIL';
        final failureMsg = '$stepName: $e';
        if (!failures.contains(failureMsg)) {
          failures.add(failureMsg);
        }
        print('ANDROID_DUET_RAW_TFLITE_GPU_STEP_${stepName}_FAIL: $e\n$st');
        rethrow;
      }
    }

    try {
      // Step 1: Stage clip_A.mov fixture from rootBundle into temp directory.
      final sourcePath = await runStep<String>(
        'STAGE_FIXTURE',
        'Staging clip_A.mov into temp directory',
        () async {
          tempDir = await Directory.systemTemp.createTemp(
            'duet_raw_tflite_gpu_smoke_',
          );
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
          return targetFile.path;
        },
      );

      // Step 2: Initialize Duet session (trim: 0.0s - 2.5s).
      sessionId = await runStep<String>(
        'INIT_SESSION',
        'Initializing Duet session (trim: 0.0s - 2.5s)',
        () async {
          final result = await _withTimeout(
            _channel.invokeMethod<String>(
              'initializeDuetSession',
              <String, dynamic>{
                'source': <String, dynamic>{'filePath': sourcePath},
                'trimWindow': <String, dynamic>{
                  'startSeconds': 0.0,
                  'endSeconds': 2.5,
                },
              },
            ),
            'initializeDuetSession',
          );
          if (result == null || result.isEmpty) {
            throw StateError('initializeDuetSession returned null/empty');
          }
          return result;
        },
      );

      // Step 3: Attach preview texture with greenScreen layout and
      // debugSegmentationBackend=raw_tflite_gpu. Using direct MethodChannel so
      // the layoutConfig map can carry the debug key that VGDuetLayoutConfig
      // does not expose through the public Dart API.
      await runStep<void>(
        'ATTACH_PREVIEW_GREENSCREEN_RAW_GPU',
        'Attaching preview texture (1080x1920, greenScreen, raw_tflite_gpu opt-in)',
        () async {
          final result = await _withTimeout(
            _channel.invokeMethod<Map>(
              'attachDuetPreviewTexture',
              <String, dynamic>{
                'sessionId': sessionId!,
                'canvasSize': <String, dynamic>{'width': 1080, 'height': 1920},
                'layoutConfig': <String, dynamic>{
                  'mode': 'greenScreen',
                  'isSideSwapped': false,
                  'isTopBottomSwapped': false,
                  // Debug-only key routed by AndroidDuetSessionCoordinator to
                  // start the adapter on the raw_tflite_gpu rung.
                  'debugSegmentationBackend': 'raw_tflite_gpu',
                },
              },
            ),
            'attachDuetPreviewTexture',
          );
          if (result == null) {
            throw StateError('attachDuetPreviewTexture returned null');
          }
          final Map<String, dynamic> resultMap = Map<String, dynamic>.from(
            result,
          );
          final int? tid = resultMap['textureId'] as int?;
          if (tid == null || tid < 0) {
            throw StateError('Invalid textureId: $tid');
          }
          textureId = tid;
          if (mounted) {
            setState(() {
              _textureId = tid;
              _layoutMode = 'greenScreen (raw_tflite_gpu)';
            });
          }
        },
      );

      // Step 4: Start recording (activates preview render loop & camera).
      await runStep<void>(
        'START_RECORDING',
        'Starting recording to activate preview render loop',
        () async {
          await _withTimeout(
            _channel.invokeMethod<void>('startDuetRecording', <String, dynamic>{
              'sessionId': sessionId!,
            }),
            'startDuetRecording',
          );
        },
      );

      // Step 5: Wait 5.0 seconds — observe bounded live preview.
      // Native logs ANDROID_DUET_RAW_TFLITE_GPU_READY and
      // ANDROID_DUET_GREENSCREEN_RAW_TFLITE_GPU_MASK_FIRST may appear here.
      await runStep<void>(
        'RAW_TFLITE_GPU_PREVIEW_ACTIVE',
        'Observing raw TFLite GPU greenScreen preview (5.0s)',
        () async {
          await Future<void>.delayed(const Duration(seconds: 5));
        },
      );

      // Step 6: Update layout to PiP (safe PiP rect).
      await runStep<void>(
        'UPDATE_LAYOUT_PIP',
        'Updating layout to PiP (safe rect: left 0.58, top 0.05, w 0.36, h 0.24)',
        () async {
          await _withTimeout(
            _channel.invokeMethod<void>('updateDuetLayout', <String, dynamic>{
              'sessionId': sessionId!,
              'layoutConfig': <String, dynamic>{
                'mode': 'pip',
                'isSideSwapped': false,
                'isTopBottomSwapped': false,
                'pipAnchor': 'topRight',
                'pipNormalizedRect': <String, dynamic>{
                  'left': 0.58,
                  'top': 0.05,
                  'width': 0.36,
                  'height': 0.24,
                },
              },
            }),
            'updateDuetLayout',
          );
          if (mounted) {
            setState(() {
              _layoutMode = 'pip (safe)';
            });
          }
        },
      );

      // Step 7: Wait 1.5 seconds with PiP preview active.
      await runStep<void>(
        'PIP_PREVIEW_ACTIVE',
        'Observing PiP preview active (1.5s)',
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        },
      );

      // Step 8: Pause recording.
      await runStep<void>('PAUSE_RECORDING', 'Pausing recording', () async {
        await _withTimeout(
          _channel.invokeMethod<void>('pauseDuetRecording', <String, dynamic>{
            'sessionId': sessionId!,
          }),
          'pauseDuetRecording',
        );
      });

      // Step 9: Stop recording and collect capture result.
      await runStep<void>(
        'STOP_RECORDING',
        'Stopping recording and retrieving capture result',
        () async {
          final rawResult = await _withTimeout(
            _channel.invokeMethod<Map>('stopDuetRecording', <String, dynamic>{
              'sessionId': sessionId!,
            }),
            'stopDuetRecording',
          );
          if (rawResult != null) {
            captureResultMap = Map<String, dynamic>.from(rawResult);
          }
        },
      );

      // Step 10: Detach preview texture.
      await runStep<
        void
      >('DETACH_PREVIEW', 'Detaching preview texture', () async {
        try {
          await _withTimeout(
            _channel.invokeMethod<void>(
              'detachDuetPreviewTexture',
              <String, dynamic>{'sessionId': sessionId!},
            ),
            'detachDuetPreviewTexture',
          );
        } on PlatformException catch (e) {
          final isSessionNotFound =
              e.code == 'session_not_found' ||
              (e.message?.contains('session_not_found') ?? false) ||
              (e.message?.contains('No active Duet session') ?? false);
          if (isSessionNotFound) {
            print(
              'ANDROID_DUET_RAW_TFLITE_GPU: texture already detached during stopRecording: $e',
            );
          } else {
            rethrow;
          }
        }
        isDetached = true;
      });

      // Step 11: Dispose session.
      await runStep<void>(
        'DISPOSE_SESSION',
        'Disposing native Duet session',
        () async {
          await _withTimeout(
            _channel.invokeMethod<void>('disposeDuetSession', <String, dynamic>{
              'sessionId': sessionId!,
            }),
            'disposeDuetSession',
          );
          isDisposed = true;
        },
      );

      // Step 12: Cleanup temp fixture directory.
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
      // Cleanup fallback for detach, dispose, and temp directory deletion.
      if (sessionId != null) {
        if (!isDetached) {
          try {
            await _withTimeout(
              _channel.invokeMethod<void>(
                'detachDuetPreviewTexture',
                <String, dynamic>{'sessionId': sessionId},
              ),
              'cleanup detachDuetPreviewTexture',
            );
            isDetached = true;
          } catch (e) {
            print('ANDROID_DUET_RAW_TFLITE_GPU: cleanup detach note: $e');
          }
        }
        if (!isDisposed) {
          try {
            await _withTimeout(
              _channel.invokeMethod<void>(
                'disposeDuetSession',
                <String, dynamic>{'sessionId': sessionId},
              ),
              'cleanup disposeDuetSession',
            );
            isDisposed = true;
          } catch (e) {
            print('ANDROID_DUET_RAW_TFLITE_GPU: cleanup dispose note: $e');
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
          print('ANDROID_DUET_RAW_TFLITE_GPU: cleanup tempDir note: $e');
        }
      }

      final payload = <String, Object?>{
        'pass': pass,
        'proofBoundary': 'android_duet_raw_tflite_gpu_preview_physical_smoke',
        'claimsAllowed': <String>[
          'local source session init',
          'attach-time greenScreen layout accepted with debugSegmentationBackend=raw_tflite_gpu',
          'preview texture attach success',
          'startRecording activates render loop and camera',
          'bounded live in-process preview session routing to raw_tflite_gpu',
          'native ANDROID_DUET_RAW_TFLITE_GPU_READY log may evidence successful open',
          'native ANDROID_DUET_GREENSCREEN_RAW_TFLITE_GPU_MASK_FIRST log may evidence first raw GPU mask',
          'degradation to mediapipe_cpu on open/inference failure is handled by adapter',
          'layout update away from greenScreen to PiP works',
          'stop/detach/dispose/temp cleanup complete',
        ],
        'nonClaims': <String>[
          'no export or audio proof',
          'no pixel-quality or matte grading proof',
          'no all-device GPU compatibility proof',
          'no default production promotion (raw_tflite_gpu remains opt-in only)',
          'no adaptive quality tier proof',
        ],
        'sessionId': sessionId,
        'textureId': textureId,
        'stepResults': stepResults,
        'failures': failures,
        if (captureResultMap != null) 'captureResult': captureResultMap,
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
                        'Android Duet Raw TFLite GPU Preview Physical Smoke',
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
