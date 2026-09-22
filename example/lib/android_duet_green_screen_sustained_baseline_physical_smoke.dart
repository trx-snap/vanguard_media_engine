// Copyright 2026, Connects. All rights reserved.
// android_duet_green_screen_sustained_baseline_physical_smoke.dart
//
// Dedicated physical smoke harness for a *sustained* production live preview
// window on the Android Duet green-screen backend. This harness attaches with
// production defaults (production Duet GPU GreenScreen path): no
// debugSegmentationBackend, no debugRawTfliteGpuDelegateMode, and no
// debugRawTfliteGpuModelAssetPath are passed. It establishes a sustained
// baseline observation window (default 45s, override with
// --dart-define=SUSTAINED_SECONDS=<n>) and fails if any Duet green-screen
// degrade/fallback event is observed for this session during that window.
//
// Proof boundary:
//   - Device requirement: Android physical device with camera permission available.
//   - Harness command:
//       cd packages/vanguard_media_engine/example &&
//       flutter run -d <deviceId> \
//         -t lib/android_duet_green_screen_sustained_baseline_physical_smoke.dart \
//         --dart-define=SUSTAINED_SECONDS=45
//   - Claims allowed:
//       * local source session init
//       * attach-time greenScreen layout accepted on production defaults while
//         omitting legacy/debug segmentation keys
//       * production Duet GPU GreenScreen path selected by engine defaults when
//         paired with native logcat markers
//       * preview texture attach success
//       * startRecording activates render loop and camera
//       * sustained 45s segmentation window runs with zero Duet degrade/fallback
//         events via VGDuetEvents.stream
//       * decoded source video is moving for the default 45s in-trim observation
//         window using the new 60s fixture
//       * cleanup completion
//   - Non-claims:
//       * no automated pixel/matte-quality proof
//       * no export/audio proof
//       * no all-device/low-end proof
//       * no standalone logcat assertion inside Dart because GPU route proof
//         requires pairing with native logcat markers
//       * no claim beyond the fixture/trim window if someone overrides
//         SUSTAINED_SECONDS above 45

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_duet.dart';

const MethodChannel _channel = MethodChannel('vanguard_media_engine');

const String kSmokeStartMarker =
    'ANDROID_DUET_GREENSCREEN_SUSTAINED_BASELINE_PHYSICAL_SMOKE_START';
const String kSmokePassMarker =
    'ANDROID_DUET_GREENSCREEN_SUSTAINED_BASELINE_PHYSICAL_PASS';
const String kSmokeFailMarker =
    'ANDROID_DUET_GREENSCREEN_SUSTAINED_BASELINE_PHYSICAL_FAIL';
const String kSmokeJsonPrefix =
    'ANDROID_DUET_GREENSCREEN_SUSTAINED_BASELINE_PHYSICAL_JSON:';
const String kObserveTickMarker =
    'ANDROID_DUET_GREENSCREEN_SUSTAINED_BASELINE_OBSERVE_TICK';

/// Length of the sustained live-preview observation window, in seconds.
/// Override with `--dart-define=SUSTAINED_SECONDS=<n>`.
const int kSustainedObservationSeconds = int.fromEnvironment(
  'SUSTAINED_SECONDS',
  defaultValue: 45,
);

/// Optional debug-only MediaPipe CPU model asset override for R&D comparison.
/// Empty keeps the production default model.
const String kMediaPipeCpuModelAsset = String.fromEnvironment(
  'MEDIAPIPE_CPU_MODEL_ASSET',
  defaultValue: '',
);

/// How often an observe tick (and eventCount snapshot) is printed.
const int kObserveTickIntervalSeconds = 5;

/// ANDROID-DUET-VISUAL-REGISTRATION: trim end (seconds) for the staged source
/// clip. Uses the generated 60.0s portrait moving fixture
/// (assets/manual_test_clips/duet_sustained_motion_60s_720x1280.mp4).
/// Setting trim end to 45.0s ensures the default 45s observation window is
/// entirely inside a moving-video window, with the 60s fixture providing margin.
const double kTrimEndSeconds = 45.0;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetGreenScreenSustainedBaselinePhysicalSmokeApp());
}

class AndroidDuetGreenScreenSustainedBaselinePhysicalSmokeApp
    extends StatefulWidget {
  const AndroidDuetGreenScreenSustainedBaselinePhysicalSmokeApp({super.key});

  @override
  State<AndroidDuetGreenScreenSustainedBaselinePhysicalSmokeApp>
  createState() =>
      _AndroidDuetGreenScreenSustainedBaselinePhysicalSmokeAppState();
}

class _AndroidDuetGreenScreenSustainedBaselinePhysicalSmokeAppState
    extends State<AndroidDuetGreenScreenSustainedBaselinePhysicalSmokeApp> {
  String _status = 'Starting green-screen sustained baseline harness...';
  String _currentStep = 'INIT';
  int? _textureId;
  int _eventCount = 0;
  int _elapsedSeconds = 0;

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

  void _updateObserveProgress(int elapsedSeconds, int eventCount) {
    if (mounted) {
      setState(() {
        _elapsedSeconds = elapsedSeconds;
        _eventCount = eventCount;
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
    StreamSubscription<VGDuetEvent>? duetEventsSub;
    final duetEvents = <Map<String, dynamic>>[];

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
        print(
          'ANDROID_DUET_GREENSCREEN_SUSTAINED_BASELINE_STEP_${stepName}_PASS',
        );
        return result;
      } catch (e, st) {
        stepResults[stepName] = 'FAIL';
        final failureMsg = '$stepName: $e';
        if (!failures.contains(failureMsg)) {
          failures.add(failureMsg);
        }
        print(
          'ANDROID_DUET_GREENSCREEN_SUSTAINED_BASELINE_STEP_${stepName}_FAIL: $e\n$st',
        );
        rethrow;
      }
    }

    try {
      // Step 1: Stage duet_sustained_motion_60s_720x1280.mp4 fixture from
      // rootBundle into temp directory.
      final sourcePath = await runStep<String>(
        'STAGE_FIXTURE',
        'Staging duet_sustained_motion_60s_720x1280.mp4 into temp directory',
        () async {
          tempDir = await Directory.systemTemp.createTemp(
            'duet_greenscreen_sustained_baseline_smoke_',
          );
          final targetFile = File(
            '${tempDir!.path}/duet_sustained_motion_60s_720x1280.mp4',
          );
          final byteData = await rootBundle.load(
            'assets/manual_test_clips/duet_sustained_motion_60s_720x1280.mp4',
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

      // Step 2: Initialize Duet session (trim: 0.0s - kTrimEndSeconds). The
      // staged 60s fixture provides full motion throughout the default 45s
      // observation window with margin.
      sessionId = await runStep<String>(
        'INIT_SESSION',
        'Initializing Duet session (trim: 0.0s - ${kTrimEndSeconds}s)',
        () async {
          final result = await _withTimeout(
            _channel.invokeMethod<String>(
              'initializeDuetSession',
              <String, dynamic>{
                'source': <String, dynamic>{'filePath': sourcePath},
                'trimWindow': <String, dynamic>{
                  'startSeconds': 0.0,
                  'endSeconds': kTrimEndSeconds,
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

      // Subscribe to VGDuetEvents.stream now that sessionId is known, so any
      // green_screen_degraded / green_screen_fallback event for this session
      // during the sustained window is captured (not just events during the
      // explicit observe step).
      final capturedSessionId = sessionId;
      duetEventsSub = VGDuetEvents.stream.listen((event) {
        if (event.sessionId == capturedSessionId) {
          duetEvents.add(<String, dynamic>{
            'type': event.type.toString(),
            'sessionId': event.sessionId,
            'previousBackend': event.previousBackend,
            'currentBackend': event.currentBackend,
            'reason': event.reason,
            'userMessage': event.userMessage,
          });
        }
      });

      // Step 3: Attach preview texture with greenScreen layout on production
      // defaults. Deliberately omits debugSegmentationBackend,
      // debugRawTfliteGpuDelegateMode, and debugRawTfliteGpuModelAssetPath so
      // the session selects the production Duet GPU GreenScreen path by engine
      // defaults, exactly as a production session would.
      final layoutConfig = <String, dynamic>{
        'mode': 'greenScreen',
        'isSideSwapped': false,
        'isTopBottomSwapped': false,
        if (kMediaPipeCpuModelAsset.isNotEmpty)
          'debugMediaPipeCpuModelAssetPath': kMediaPipeCpuModelAsset,
      };
      await runStep<void>(
        'ATTACH_PREVIEW_GREENSCREEN',
        'Attaching preview texture (1080x1920, greenScreen, production GPU path)',
        () async {
          final result = await _withTimeout(
            _channel.invokeMethod<Map>(
              'attachDuetPreviewTexture',
              <String, dynamic>{
                'sessionId': sessionId!,
                'canvasSize': <String, dynamic>{'width': 1080, 'height': 1920},
                'layoutConfig': layoutConfig,
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

      // Step 5: Observe the sustained live preview window. Prints a
      // kObserveTickMarker line every kObserveTickIntervalSeconds with the
      // running Duet event count for this session. When paired with native
      // logcat markers (e.g. ANDROID_DUET_GREENSCREEN_MASK_PATH_SELECTED,
      // ANDROID_DUET_GPU_GREENSCREEN_FIRST_MASK_READY, release summary),
      // this confirms the production Duet GPU GreenScreen path is active.
      // Fails if any green_screen_degraded / green_screen_fallback event for
      // this session arrived during the window.
      await runStep<void>(
        'GREENSCREEN_SUSTAINED_BASELINE_PREVIEW_ACTIVE',
        'Observing greenScreen sustained baseline preview (${kSustainedObservationSeconds}s)',
        () async {
          var elapsed = 0;
          while (elapsed < kSustainedObservationSeconds) {
            final remaining = kSustainedObservationSeconds - elapsed;
            final step = remaining < kObserveTickIntervalSeconds
                ? remaining
                : kObserveTickIntervalSeconds;
            await Future<void>.delayed(Duration(seconds: step));
            elapsed += step;
            _updateObserveProgress(elapsed, duetEvents.length);
            print(
              '$kObserveTickMarker elapsedSeconds=$elapsed eventCount=${duetEvents.length}',
            );
          }
          if (duetEvents.isNotEmpty) {
            throw StateError(
              'Detected ${duetEvents.length} green_screen_degraded/green_screen_fallback '
              'event(s) for session $sessionId during sustained baseline window: '
              '${jsonEncode(duetEvents)}',
            );
          }
        },
      );

      // Step 6: Stop recording and collect capture result.
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

      // Step 7: Detach preview texture.
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
              'ANDROID_DUET_GREENSCREEN_SUSTAINED_BASELINE: texture already detached during stopRecording: $e',
            );
          } else {
            rethrow;
          }
        }
        isDetached = true;
      });

      // Step 8: Dispose session.
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

      // Step 9: Cleanup temp fixture directory.
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
      await duetEventsSub?.cancel();

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
            print(
              'ANDROID_DUET_GREENSCREEN_SUSTAINED_BASELINE: cleanup detach note: $e',
            );
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
            print(
              'ANDROID_DUET_GREENSCREEN_SUSTAINED_BASELINE: cleanup dispose note: $e',
            );
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
          print(
            'ANDROID_DUET_GREENSCREEN_SUSTAINED_BASELINE: cleanup tempDir note: $e',
          );
        }
      }

      final payload = <String, Object?>{
        'pass': pass,
        'proofBoundary':
            'android_duet_green_screen_sustained_baseline_physical_smoke',
        'observationSeconds': kSustainedObservationSeconds,
        'claimsAllowed': <String>[
          'local source session init',
          'attach-time greenScreen layout accepted on production defaults while '
              'omitting legacy/debug segmentation keys',
          'production Duet GPU GreenScreen path selected by engine defaults when '
              'paired with native logcat markers',
          'preview texture attach success',
          'startRecording activates render loop and camera',
          'sustained 45s segmentation window runs with zero Duet degrade/fallback '
              'events via VGDuetEvents.stream',
          'decoded source video is moving for the default 45s in-trim observation '
              'window using the new 60s fixture',
          'cleanup completion',
        ],
        'nonClaims': <String>[
          'no automated pixel/matte-quality proof',
          'no export/audio proof',
          'no all-device/low-end proof',
          'no standalone logcat assertion inside Dart because GPU route proof '
              'requires pairing with native logcat markers',
          'no claim beyond the fixture/trim window if someone overrides '
              'SUSTAINED_SECONDS above 45',
        ],
        'sessionId': sessionId,
        'textureId': textureId,
        'trimEndSeconds': kTrimEndSeconds,
        'duetEvents': duetEvents,
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
                        'Android Duet Green Screen Sustained Baseline Physical Smoke',
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
                          'Texture ID: $_textureId',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      Text(
                        'Elapsed: ${_elapsedSeconds}s / ${kSustainedObservationSeconds}s | '
                        'Duet events: $_eventCount',
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
