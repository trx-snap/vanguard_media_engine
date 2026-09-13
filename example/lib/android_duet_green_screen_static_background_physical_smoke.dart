// Copyright 2026, Connects. All rights reserved.
// android_duet_green_screen_static_background_physical_smoke.dart
//
// Dedicated physical smoke harness proving the Duet green-screen static
// background contract can present a live masked camera over:
//   (1) a solid ARGB color fill
//   (2) a still image file
//
// Proof boundary:
//   - Device requirement: Android physical device with camera permission available.
//   - Harness command:
//       cd packages/vanguard_media_engine/example &&
//       flutter run -d <deviceId> \
//         -t lib/android_duet_green_screen_static_background_physical_smoke.dart \
//         --dart-define=STATIC_BACKGROUND_HOLD_SECONDS=8 \
//         --dart-define=STATIC_BACKGROUND_IMAGE_SCALE_MODE=aspectFill
//   - Claims allowed:
//       * local source session init
//       * public Dart static background contract serialization (VGDuetGreenScreenBackground solidColor and imageFile)
//       * solid color attach and image updateLayout accepted by native Duet engine
//       * live preview texture active for manual observation across solid color and still image background phases
//       * zero green_screen_degraded or green_screen_fallback events for this session during observation windows
//       * stop/detach/dispose/temp cleanup complete
//   - Non-claims:
//       * no automated pixel or matte quality proof
//       * no export or audio proof
//       * no video background proof
//       * no iOS proof
//       * no all-device or low-end device proof

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_duet.dart';

const MethodChannel _channel = MethodChannel('vanguard_media_engine');

const String kSmokeStartMarker =
    'ANDROID_DUET_GREENSCREEN_STATIC_BACKGROUND_PHYSICAL_SMOKE_START';
const String kSolidObserveBeginMarker =
    'ANDROID_DUET_GREENSCREEN_STATIC_BACKGROUND_SOLID_OBSERVE_BEGIN';
const String kImageObserveBeginMarker =
    'ANDROID_DUET_GREENSCREEN_STATIC_BACKGROUND_IMAGE_OBSERVE_BEGIN';
const String kSmokeJsonPrefix =
    'ANDROID_DUET_GREENSCREEN_STATIC_BACKGROUND_PHYSICAL_JSON:';
const String kSmokePassMarker =
    'ANDROID_DUET_GREENSCREEN_STATIC_BACKGROUND_PHYSICAL_PASS';
const String kSmokeFailMarker =
    'ANDROID_DUET_GREENSCREEN_STATIC_BACKGROUND_PHYSICAL_FAIL';

/// Length of each observation phase (solid color and image), in seconds.
/// Override with `--dart-define=STATIC_BACKGROUND_HOLD_SECONDS=<n>`.
/// Clamped to minimum 2 seconds.
const int _rawHoldSeconds = int.fromEnvironment(
  'STATIC_BACKGROUND_HOLD_SECONDS',
  defaultValue: 8,
);
const int kHoldSeconds = _rawHoldSeconds < 2 ? 2 : _rawHoldSeconds;

/// Scale mode for the still image background.
/// Override with `--dart-define=STATIC_BACKGROUND_IMAGE_SCALE_MODE=<aspectFill|aspectFit>`.
const String _rawImageScaleMode = String.fromEnvironment(
  'STATIC_BACKGROUND_IMAGE_SCALE_MODE',
  defaultValue: 'aspectFill',
);

VGDuetBackgroundScaleMode _resolveScaleMode(String raw) {
  if (raw.trim().toLowerCase() == 'aspectfit') {
    return VGDuetBackgroundScaleMode.aspectFit;
  }
  return VGDuetBackgroundScaleMode.aspectFill;
}

final VGDuetBackgroundScaleMode kImageScaleMode = _resolveScaleMode(
  _rawImageScaleMode,
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetGreenScreenStaticBackgroundPhysicalSmokeApp());
}

class AndroidDuetGreenScreenStaticBackgroundPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidDuetGreenScreenStaticBackgroundPhysicalSmokeApp({super.key});

  @override
  State<AndroidDuetGreenScreenStaticBackgroundPhysicalSmokeApp> createState() =>
      _AndroidDuetGreenScreenStaticBackgroundPhysicalSmokeAppState();
}

class _AndroidDuetGreenScreenStaticBackgroundPhysicalSmokeAppState
    extends State<AndroidDuetGreenScreenStaticBackgroundPhysicalSmokeApp> {
  String _status = 'Starting green-screen static background harness...';
  String _currentStep = 'INIT';
  String _phase = 'INIT';
  int? _textureId;
  int _eventCount = 0;
  int _phaseElapsedSeconds = 0;

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

  void _updateObserveProgress(
    String phase,
    int elapsedSeconds,
    int totalSeconds,
    int eventCount,
  ) {
    if (mounted) {
      setState(() {
        _phase = phase;
        _phaseElapsedSeconds = elapsedSeconds;
        _eventCount = eventCount;
        _status = 'Observing $phase ($elapsedSeconds/$totalSeconds s)';
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
          'ANDROID_DUET_GREENSCREEN_STATIC_BACKGROUND_STEP_${stepName}_PASS',
        );
        return result;
      } catch (e, st) {
        stepResults[stepName] = 'FAIL';
        final failureMsg = '$stepName: $e';
        if (!failures.contains(failureMsg)) {
          failures.add(failureMsg);
        }
        print(
          'ANDROID_DUET_GREENSCREEN_STATIC_BACKGROUND_STEP_${stepName}_FAIL: $e\n$st',
        );
        rethrow;
      }
    }

    try {
      // Step 1: Stage clip_A.mov and still_C.png fixtures from rootBundle into temp directory.
      late final File clipFile;
      late final File stillFile;
      await runStep<void>(
        'STAGE_FIXTURES',
        'Staging clip_A.mov and still_C.png into temp directory',
        () async {
          tempDir = await Directory.systemTemp.createTemp(
            'duet_greenscreen_static_bg_smoke_',
          );

          clipFile = File('${tempDir!.path}/clip_A.mov');
          final clipData = await rootBundle.load(
            'assets/manual_test_clips/clip_A.mov',
          );
          await clipFile.writeAsBytes(
            clipData.buffer.asUint8List(
              clipData.offsetInBytes,
              clipData.lengthInBytes,
            ),
            flush: true,
          );
          if (!await clipFile.exists() || await clipFile.length() == 0) {
            throw StateError('Staged clip_A.mov fixture missing or empty');
          }

          stillFile = File('${tempDir!.path}/still_C.png');
          final stillData = await rootBundle.load(
            'assets/manual_test_clips/still_C.png',
          );
          await stillFile.writeAsBytes(
            stillData.buffer.asUint8List(
              stillData.offsetInBytes,
              stillData.lengthInBytes,
            ),
            flush: true,
          );
          if (!await stillFile.exists() || await stillFile.length() == 0) {
            throw StateError('Staged still_C.png fixture missing or empty');
          }
        },
      );

      // Step 2: Initialize Duet session with source file clip_A.mov and trim 0.0 to 9.0.
      sessionId = await runStep<String>(
        'INIT_SESSION',
        'Initializing Duet session (trim: 0.0s - 9.0s)',
        () async {
          final result = await _withTimeout(
            _channel.invokeMethod<String>(
              'initializeDuetSession',
              <String, dynamic>{
                'source': VGDuetSource.localFile(clipFile.path).toMap(),
                'trimWindow': VGDuetTrimWindow(
                  startSeconds: 0.0,
                  endSeconds: 9.0,
                ).toMap(),
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

      // Subscribe to VGDuetEvents.stream after sessionId is known to catch any
      // green_screen_degraded or green_screen_fallback events for this session.
      final capturedSessionId = sessionId;
      duetEventsSub = VGDuetEvents.stream.listen((event) {
        if (event.sessionId == capturedSessionId) {
          duetEvents.add(<String, dynamic>{
            'type': event.type.name,
            'sessionId': event.sessionId,
            'previousBackend': event.previousBackend,
            'currentBackend': event.currentBackend,
            'reason': event.reason,
            'userMessage': event.userMessage,
          });
        }
      });

      // Step 3: Attach preview texture (1080x1920) with greenScreen layout,
      // creatorOverlay transform, and solidColor(0xFF00B894) background.
      // Built via VGDuetLayoutConfig(...).toMap() without debug override keys.
      final solidLayoutConfig = VGDuetLayoutConfig(
        mode: VGDuetLayoutMode.greenScreen,
        foregroundTransform: VGDuetForegroundTransform.creatorOverlay,
        greenScreenBackground: const VGDuetGreenScreenBackground.solidColor(
          0xFF00B894,
        ),
      );
      await runStep<void>(
        'ATTACH_PREVIEW_SOLID_COLOR',
        'Attaching preview texture (1080x1920, solidColor 0xFF00B894)',
        () async {
          final result = await _withTimeout(
            _channel.invokeMethod<Map>(
              'attachDuetPreviewTexture',
              <String, dynamic>{
                'sessionId': sessionId!,
                'canvasSize': const VGDuetSize(1080, 1920).toMap(),
                'layoutConfig': solidLayoutConfig.toMap(),
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
        'Starting recording to activate preview render loop and camera',
        () async {
          await _withTimeout(
            _channel.invokeMethod<void>('startDuetRecording', <String, dynamic>{
              'sessionId': sessionId!,
            }),
            'startDuetRecording',
          );
        },
      );

      // Step 5: Observe solid color phase for holdSeconds.
      await runStep<void>(
        'OBSERVE_SOLID_COLOR',
        'Observing solid color background preview (${kHoldSeconds}s)',
        () async {
          print(kSolidObserveBeginMarker);
          var elapsed = 0;
          while (elapsed < kHoldSeconds) {
            final remaining = kHoldSeconds - elapsed;
            final step = remaining < 1 ? remaining : 1;
            await Future<void>.delayed(Duration(seconds: step));
            elapsed += step;
            _updateObserveProgress(
              'SOLID_COLOR',
              elapsed,
              kHoldSeconds,
              duetEvents.length,
            );
            if (duetEvents.isNotEmpty) {
              throw StateError(
                'Detected ${duetEvents.length} green_screen_degraded/green_screen_fallback '
                'event(s) during solid color observation: ${jsonEncode(duetEvents)}',
              );
            }
          }
        },
      );

      // Step 6: Update layout to still image background.
      final imageLayoutConfig = VGDuetLayoutConfig(
        mode: VGDuetLayoutMode.greenScreen,
        foregroundTransform: VGDuetForegroundTransform.creatorOverlay,
        greenScreenBackground: VGDuetGreenScreenBackground.imageFile(
          stillFile.path,
          scaleMode: kImageScaleMode,
        ),
      );
      await runStep<void>(
        'UPDATE_LAYOUT_IMAGE',
        'Updating layout to still image background (${kImageScaleMode.name})',
        () async {
          await _withTimeout(
            _channel.invokeMethod<void>('updateDuetLayout', <String, dynamic>{
              'sessionId': sessionId!,
              'layoutConfig': imageLayoutConfig.toMap(),
            }),
            'updateDuetLayout',
          );
        },
      );

      // Step 7: Observe image phase for holdSeconds.
      await runStep<void>(
        'OBSERVE_IMAGE',
        'Observing still image background preview (${kHoldSeconds}s)',
        () async {
          print(kImageObserveBeginMarker);
          var elapsed = 0;
          while (elapsed < kHoldSeconds) {
            final remaining = kHoldSeconds - elapsed;
            final step = remaining < 1 ? remaining : 1;
            await Future<void>.delayed(Duration(seconds: step));
            elapsed += step;
            _updateObserveProgress(
              'IMAGE_FILE',
              elapsed,
              kHoldSeconds,
              duetEvents.length,
            );
            if (duetEvents.isNotEmpty) {
              throw StateError(
                'Detected ${duetEvents.length} green_screen_degraded/green_screen_fallback '
                'event(s) during image observation: ${jsonEncode(duetEvents)}',
              );
            }
          }
        },
      );

      // Step 8: Stop recording and collect capture result.
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

      // Step 9: Detach preview texture.
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
              'ANDROID_DUET_GREENSCREEN_STATIC_BACKGROUND: texture already detached during stopRecording: $e',
            );
          } else {
            rethrow;
          }
        }
        isDetached = true;
      });

      // Step 10: Dispose native Duet session.
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

      // Step 11: Cleanup temp fixtures directory.
      await runStep<void>(
        'CLEANUP_TEMP_FIXTURES',
        'Deleting staged fixtures temp directory',
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

      // Guaranteed cleanup fallback for detach, dispose, and temp directory.
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
              'ANDROID_DUET_GREENSCREEN_STATIC_BACKGROUND: cleanup detach note: $e',
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
              'ANDROID_DUET_GREENSCREEN_STATIC_BACKGROUND: cleanup dispose note: $e',
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
            'ANDROID_DUET_GREENSCREEN_STATIC_BACKGROUND: cleanup tempDir note: $e',
          );
        }
      }

      final payload = <String, Object?>{
        'pass': pass,
        'proofBoundary':
            'android_duet_green_screen_static_background_physical_smoke',
        'holdSeconds': kHoldSeconds,
        'imageScaleMode': kImageScaleMode.name,
        'sessionId': sessionId,
        'textureId': textureId,
        'stepResults': stepResults,
        'failures': failures,
        'duetEvents': duetEvents,
        'claimsAllowed': <String>[
          'local source session init',
          'public Dart static background contract serialization (VGDuetGreenScreenBackground solidColor and imageFile)',
          'solid color attach and image updateLayout accepted by native Duet engine',
          'live preview texture active for manual observation across solid color and still image background phases',
          'zero green_screen_degraded or green_screen_fallback events for this session during observation windows',
          'stop/detach/dispose/temp cleanup complete',
        ],
        'nonClaims': <String>[
          'no automated pixel or matte quality proof',
          'no export or audio proof',
          'no video background proof',
          'no iOS proof',
          'no all-device or low-end device proof',
        ],
        'captureResult': ?captureResultMap,
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
                        'Android Duet Green Screen Static Background Physical Smoke',
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
                        'Phase: $_phase | Elapsed: ${_phaseElapsedSeconds}s / ${kHoldSeconds}s | '
                        'Scale: ${kImageScaleMode.name} | Duet events: $_eventCount',
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
