// Copyright 2026, Connects. All rights reserved.
// android_duet_green_screen_free_transform_preview_physical_smoke.dart
//
// Standalone physical smoke harness for Android Duet green-screen live preview
// free-transform contract verification.
//
// Proof boundary:
//   - Device requirement: Android physical device with camera permission available.
//   - Harness command:
//       cd packages/vanguard_media_engine/example &&
//       flutter run -d <deviceId> -t lib/android_duet_green_screen_free_transform_preview_physical_smoke.dart
//   - Claims allowed:
//       * local source session init from staged clip_A.mov fixture
//       * attach-time greenScreen layout accepts and preserves the v2 free foregroundTransform
//         (scale > 1.0, non-zero offset, centered anchor, non-zero rotationDegrees, partial off-canvas)
//       * native attach-time layout rect for camera matches VGDuetLayoutMath.computeGreenScreenRects
//         geometry within 0.5px tolerance
//       * preview texture attach success with 1080x1920 canvas
//       * diagnostic keys debugGreenScreenBackgroundMode=solid_teal and
//         debugGreenScreenView=camera_passthrough passed to stabilize visual observation
//       * startRecording activates preview render loop and camera
//       * bounded initial free-transform observation window (~2s) executes cleanly
//       * mid-session updateLayout accepts second free transform (scale < 1.0, non-zero offset,
//         off-center anchor, negative rotationDegrees)
//       * bounded updated free-transform observation window (~2s) executes cleanly
//       * stop recording, detach preview, dispose session, and temp directory cleanup complete
//   - Non-claims:
//       * no automated pixel rotation verification (actual GPU-rendered rotated camera
//         pixels are not measured or read back; visual confirmation on physical display)
//       * no matte quality or segmentation boundary accuracy proof
//       * no MediaPipe GPU delegate or promotion proof (production GLES pipeline exercised)
//       * no offline export or audio mixing proof
//       * no low-end / multi-device performance proof

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_duet.dart';

const String kSmokeStartMarker =
    'ANDROID_DUET_GREENSCREEN_FREE_TRANSFORM_PREVIEW_START';
const String kSmokePassMarker =
    'ANDROID_DUET_GREENSCREEN_FREE_TRANSFORM_PREVIEW_PHYSICAL_PASS';
const String kSmokeFailMarker =
    'ANDROID_DUET_GREENSCREEN_FREE_TRANSFORM_PREVIEW_PHYSICAL_FAIL';
const String kSmokeJsonPrefix =
    'ANDROID_DUET_GREENSCREEN_FREE_TRANSFORM_PREVIEW_JSON:';
const String kObserveTickMarker =
    'ANDROID_DUET_GREENSCREEN_FREE_TRANSFORM_OBSERVE_TICK';

/// Raw channel used for attach and updateLayout so layoutConfig can carry
/// diagnostic keys (`debugGreenScreenBackgroundMode`, `debugGreenScreenView`)
/// not exposed on the typed [VGDuetLayoutConfig] model.
const MethodChannel _rawDuetChannel = MethodChannel('vanguard_media_engine');

/// Canvas size for preview attachment (standard 9:16 vertical video).
const VGDuetSize kCanvasSize = VGDuetSize(1080, 1920);

/// First free transform: scale > 1.0, non-zero offset, centered anchor, 90° rotation,
/// allowing partial off-canvas placement.
const VGDuetForegroundTransform kFirstTransform = VGDuetForegroundTransform(
  scale: 1.35,
  offset: VGDuetPoint(-0.65, 0.25),
  anchor: VGDuetPoint(0.5, 0.5),
  rotationDegrees: 90.0,
);

/// Second free transform: scale < 1.0, non-zero offset, off-center anchor, -35° rotation.
const VGDuetForegroundTransform kSecondTransform = VGDuetForegroundTransform(
  scale: 0.55,
  offset: VGDuetPoint(0.85, -0.35),
  anchor: VGDuetPoint(0.25, 0.75),
  rotationDegrees: -35.0,
);

const int kFirstHoldSeconds = 2;
const int kSecondHoldSeconds = 2;
const double kTrimEndSeconds = 5.0;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetGreenScreenFreeTransformPreviewPhysicalSmokeApp());
}

class AndroidDuetGreenScreenFreeTransformPreviewPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidDuetGreenScreenFreeTransformPreviewPhysicalSmokeApp({super.key});

  @override
  State<AndroidDuetGreenScreenFreeTransformPreviewPhysicalSmokeApp>
  createState() =>
      _AndroidDuetGreenScreenFreeTransformPreviewPhysicalSmokeAppState();
}

class _AndroidDuetGreenScreenFreeTransformPreviewPhysicalSmokeAppState
    extends State<AndroidDuetGreenScreenFreeTransformPreviewPhysicalSmokeApp> {
  final VGDuetPlatformInterface _platform = const MethodChannelVGDuetPlatform();

  String _status = 'Starting free-transform preview smoke harness...';
  String _currentStep = 'INIT';
  String _activeTransformLabel = 'none';
  int? _textureId;
  int _elapsedHoldSeconds = 0;
  int _totalHoldSeconds = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  void _updateStatus(
    String step,
    String status, {
    String? transformLabel,
    int? elapsed,
    int? total,
  }) {
    if (mounted) {
      setState(() {
        _currentStep = step;
        _status = status;
        if (transformLabel != null) _activeTransformLabel = transformLabel;
        if (elapsed != null) _elapsedHoldSeconds = elapsed;
        if (total != null) _totalHoldSeconds = total;
      });
    }
  }

  Future<T> _withTimeout<T>(Future<T> future, String operationName) {
    return future.timeout(
      const Duration(seconds: 12),
      onTimeout: () =>
          throw TimeoutException('$operationName timed out after 12 seconds'),
    );
  }

  Future<void> _runSmoke() async {
    print(kSmokeStartMarker);

    bool pass = false;
    String? sessionId;
    int? textureId;
    Directory? tempDir;
    VGDuetCaptureResult? captureResult;

    // Gates tracking required by Requirement 10
    bool fixtureOk = false;
    bool initOk = false;
    bool attachOk = false;
    bool firstRectMatchesOk = false;
    bool startOk = false;
    bool updateOk = false;
    bool stopOk = false;
    bool detachOk = false;
    bool disposeOk = false;
    bool cleanupOk = false;

    VGDuetRect? firstActualCameraRect;
    VGDuetRect? firstExpectedCameraRect;
    VGDuetRect? secondExpectedCameraRect;

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
        print('ANDROID_DUET_GREENSCREEN_FREE_TRANSFORM_STEP_${stepName}_PASS');
        return result;
      } catch (e, st) {
        stepResults[stepName] = 'FAIL';
        final failureMsg = '$stepName: $e';
        if (!failures.contains(failureMsg)) {
          failures.add(failureMsg);
        }
        print(
          'ANDROID_DUET_GREENSCREEN_FREE_TRANSFORM_STEP_${stepName}_FAIL: $e\n$st',
        );
        rethrow;
      }
    }

    try {
      // Step 1: Stage clip_A.mov fixture from rootBundle into temp directory
      final source = await runStep<VGDuetSource>(
        'STAGE_FIXTURE',
        'Staging clip_A.mov into temp directory',
        () async {
          tempDir = await Directory.systemTemp.createTemp(
            'duet_greenscreen_free_transform_smoke_',
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
          fixtureOk = true;
          return VGDuetSource.localFile(targetFile.path);
        },
      );

      // Step 2: Initialize Duet session via public VGDuetPlatformInterface
      sessionId = await runStep<String>(
        'INIT_SESSION',
        'Initializing Duet session (trim: 0.0s - ${kTrimEndSeconds}s)',
        () async {
          final trimWindow = VGDuetTrimWindow(
            startSeconds: 0.0,
            endSeconds: kTrimEndSeconds,
          );
          final sid = await _withTimeout(
            _platform.initializeSession(source: source, trimWindow: trimWindow),
            'initializeSession',
          );
          if (sid.isEmpty) {
            throw StateError('initializeSession returned empty sessionId');
          }
          initOk = true;
          return sid;
        },
      );

      // Step 3: Attach preview texture with canvas 1080x1920, greenScreen layout,
      // first free foregroundTransform, and diagnostic keys (solid_teal, camera_passthrough).
      await runStep<VGDuetPreviewTexture>(
        'ATTACH_PREVIEW_GREENSCREEN',
        'Attaching preview texture (1080x1920, greenScreen, freeTransform v2, solid_teal, camera_passthrough)',
        () async {
          final rawResult = await _withTimeout(
            _rawDuetChannel.invokeMethod<Map>(
              'attachDuetPreviewTexture',
              <String, dynamic>{
                'sessionId': sessionId!,
                'canvasSize': kCanvasSize.toMap(),
                'layoutConfig': <String, dynamic>{
                  'mode': 'greenScreen',
                  'isSideSwapped': false,
                  'isTopBottomSwapped': false,
                  'foregroundTransform': kFirstTransform.toMap(),
                  'greenScreenBackground':
                      const VGDuetGreenScreenBackground.solidColor(
                        0xFF008080,
                      ).toMap(),
                  'debugGreenScreenBackgroundMode': 'solid_teal',
                  'debugGreenScreenView': 'camera_passthrough',
                },
              },
            ),
            'attachDuetPreviewTexture',
          );
          if (rawResult == null) {
            throw StateError('attachDuetPreviewTexture returned null');
          }
          final parsed = VGDuetPreviewTexture.fromMap(
            Map<String, dynamic>.from(rawResult),
          );
          if (parsed.textureId < 0) {
            throw StateError('Invalid textureId: ${parsed.textureId}');
          }
          attachOk = true;
          textureId = parsed.textureId;

          // Compute expected camera rect via VGDuetLayoutMath
          final expectedRects = VGDuetLayoutMath.computeGreenScreenRects(
            canvasSize: kCanvasSize,
            transform: kFirstTransform,
          );
          firstExpectedCameraRect = expectedRects[1];

          final actualCameraRect = parsed.layoutRects?['camera'];
          if (actualCameraRect == null) {
            throw StateError(
              'Missing preview.layoutRects["camera"] in attach reply',
            );
          }
          firstActualCameraRect = actualCameraRect;

          // Assert returned camera rect equals expected rect within 0.5px
          const double tolerance = 0.5;
          final leftDiff =
              (actualCameraRect.left - firstExpectedCameraRect!.left).abs();
          final topDiff = (actualCameraRect.top - firstExpectedCameraRect!.top)
              .abs();
          final widthDiff =
              (actualCameraRect.width - firstExpectedCameraRect!.width).abs();
          final heightDiff =
              (actualCameraRect.height - firstExpectedCameraRect!.height).abs();

          if (leftDiff > tolerance ||
              topDiff > tolerance ||
              widthDiff > tolerance ||
              heightDiff > tolerance) {
            throw StateError(
              'Mismatched first free transform camera rect: got $actualCameraRect, '
              'expected $firstExpectedCameraRect (diffs: left=$leftDiff, top=$topDiff, '
              'width=$widthDiff, height=$heightDiff, tolerance=$tolerance)',
            );
          }
          firstRectMatchesOk = true;

          if (mounted) {
            setState(() {
              _textureId = parsed.textureId;
              _activeTransformLabel = 'scale=1.35 offset=(-0.65,0.25) rot=90°';
            });
          }
          return parsed;
        },
      );

      // Pre-compute second transform expected rect for reporting
      final secondRects = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: kCanvasSize,
        transform: kSecondTransform,
      );
      secondExpectedCameraRect = secondRects[1];

      // Step 4: Start recording (activates preview render loop & camera)
      await runStep<void>(
        'START_RECORDING',
        'Starting recording to activate preview render loop',
        () async {
          await _withTimeout(
            _platform.startRecording(sessionId: sessionId!),
            'startRecording',
          );
          startOk = true;
        },
      );

      // Step 5: Hold/observe initial free transform preview for ~2 seconds
      await runStep<void>(
        'FIRST_TRANSFORM_PREVIEW_ACTIVE',
        'Observing initial free transform preview (${kFirstHoldSeconds}s)',
        () async {
          for (int elapsed = 1; elapsed <= kFirstHoldSeconds; elapsed++) {
            await Future<void>.delayed(const Duration(seconds: 1));
            _updateStatus(
              'FIRST_TRANSFORM_ACTIVE',
              'Observing first transform ($elapsed/${kFirstHoldSeconds}s)',
              transformLabel: 'scale=1.35 offset=(-0.65,0.25) rot=90°',
              elapsed: elapsed,
              total: kFirstHoldSeconds,
            );
            print(
              '$kObserveTickMarker phase=first elapsed=$elapsed/$kFirstHoldSeconds '
              'scale=1.35 offset=(-0.65,0.25) rot=90.0',
            );
          }
        },
      );

      // Step 6: Update layout to second free transform:
      // scale 0.55, offset {x:0.85, y:-0.35}, anchor {x:0.25, y:0.75}, rotationDegrees -35.0
      await runStep<void>(
        'UPDATE_LAYOUT_SECOND_TRANSFORM',
        'Updating layout to second free transform (scale=0.55, offset=(0.85,-0.35), anchor=(0.25,0.75), rot=-35°)',
        () async {
          await _withTimeout(
            _rawDuetChannel.invokeMethod<void>(
              'updateDuetLayout',
              <String, dynamic>{
                'sessionId': sessionId!,
                'layoutConfig': <String, dynamic>{
                  'mode': 'greenScreen',
                  'isSideSwapped': false,
                  'isTopBottomSwapped': false,
                  'foregroundTransform': kSecondTransform.toMap(),
                  'greenScreenBackground':
                      const VGDuetGreenScreenBackground.solidColor(
                        0xFF008080,
                      ).toMap(),
                  'debugGreenScreenBackgroundMode': 'solid_teal',
                  'debugGreenScreenView': 'camera_passthrough',
                },
              },
            ),
            'updateDuetLayout',
          );
          updateOk = true;
          if (mounted) {
            setState(() {
              _activeTransformLabel =
                  'scale=0.55 offset=(0.85,-0.35) anchor=(0.25,0.75) rot=-35°';
            });
          }
        },
      );

      // Step 7: Hold/observe second free transform preview for ~2 seconds
      await runStep<void>(
        'SECOND_TRANSFORM_PREVIEW_ACTIVE',
        'Observing second free transform preview (${kSecondHoldSeconds}s)',
        () async {
          for (int elapsed = 1; elapsed <= kSecondHoldSeconds; elapsed++) {
            await Future<void>.delayed(const Duration(seconds: 1));
            _updateStatus(
              'SECOND_TRANSFORM_ACTIVE',
              'Observing second transform ($elapsed/${kSecondHoldSeconds}s)',
              transformLabel:
                  'scale=0.55 offset=(0.85,-0.35) anchor=(0.25,0.75) rot=-35°',
              elapsed: elapsed,
              total: kSecondHoldSeconds,
            );
            print(
              '$kObserveTickMarker phase=second elapsed=$elapsed/$kSecondHoldSeconds '
              'scale=0.55 offset=(0.85,-0.35) rot=-35.0',
            );
          }
        },
      );

      // Step 8: Stop recording
      captureResult = await runStep<VGDuetCaptureResult>(
        'STOP_RECORDING',
        'Stopping recording and retrieving capture result',
        () async {
          final res = await _withTimeout(
            _platform.stopRecording(sessionId: sessionId!),
            'stopRecording',
          );
          stopOk = true;
          return res;
        },
      );

      // Step 9: Detach preview texture
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
              'ANDROID_DUET_GREENSCREEN_FREE_TRANSFORM: texture already detached during stopRecording: $e',
            );
          } else {
            rethrow;
          }
        }
        detachOk = true;
      });

      // Step 10: Dispose session
      await runStep<void>(
        'DISPOSE_SESSION',
        'Disposing native Duet session',
        () async {
          await _withTimeout(
            _platform.disposeSession(sessionId: sessionId!),
            'disposeSession',
          );
          disposeOk = true;
        },
      );

      // Step 11: Cleanup temp fixture directory
      await runStep<void>(
        'CLEANUP_TEMP_FIXTURE',
        'Deleting staged fixture temp directory',
        () async {
          if (tempDir != null && await tempDir!.exists()) {
            await tempDir!.delete(recursive: true);
          }
          cleanupOk = true;
        },
      );
    } catch (e) {
      // Failure recorded in stepResults and failures
    } finally {
      // Guaranteed cleanup fallback in finally
      if (sessionId != null) {
        if (!detachOk) {
          try {
            await _withTimeout(
              _platform.detachPreviewTexture(sessionId: sessionId),
              'cleanup detachPreviewTexture',
            );
            detachOk = true;
          } catch (e) {
            print(
              'ANDROID_DUET_GREENSCREEN_FREE_TRANSFORM: cleanup detachPreviewTexture note: $e',
            );
          }
        }
        if (!disposeOk) {
          try {
            await _withTimeout(
              _platform.disposeSession(sessionId: sessionId),
              'cleanup disposeSession',
            );
            disposeOk = true;
          } catch (e) {
            print(
              'ANDROID_DUET_GREENSCREEN_FREE_TRANSFORM: cleanup disposeSession note: $e',
            );
          }
        }
      }

      if (tempDir != null && !cleanupOk) {
        try {
          if (await tempDir!.exists()) {
            await tempDir!.delete(recursive: true);
          }
          cleanupOk = true;
        } catch (e) {
          print(
            'ANDROID_DUET_GREENSCREEN_FREE_TRANSFORM: cleanup tempDir delete note: $e',
          );
        }
      }

      final canonical =
          fixtureOk &&
          initOk &&
          attachOk &&
          firstRectMatchesOk &&
          startOk &&
          updateOk &&
          stopOk &&
          detachOk &&
          disposeOk &&
          cleanupOk;
      pass = canonical;

      final payload = <String, Object?>{
        'pass': pass,
        'canonical': canonical,
        'proofBoundary':
            'android_duet_green_screen_live_preview_free_transform_contract_smoke',
        'gates': <String, bool>{
          'fixtureOk': fixtureOk,
          'initOk': initOk,
          'attachOk': attachOk,
          'firstRectMatchesOk': firstRectMatchesOk,
          'startOk': startOk,
          'updateOk': updateOk,
          'stopOk': stopOk,
          'detachOk': detachOk,
          'disposeOk': disposeOk,
          'cleanupOk': cleanupOk,
          'canonical': canonical,
        },
        'fixtureOk': fixtureOk,
        'initOk': initOk,
        'attachOk': attachOk,
        'firstRectMatchesOk': firstRectMatchesOk,
        'startOk': startOk,
        'updateOk': updateOk,
        'stopOk': stopOk,
        'detachOk': detachOk,
        'disposeOk': disposeOk,
        'cleanupOk': cleanupOk,
        'claimsAllowed': <String>[
          'local source session init from staged clip_A.mov fixture in temp directory',
          'attach-time greenScreen layout accepts and preserves v2 free foregroundTransform '
              '(scale 1.35 > 1.0, non-zero offset {-0.65, 0.25}, centered anchor {0.5, 0.5}, '
              'rotationDegrees 90.0, partial off-canvas placement)',
          'native attach-time layout rect for camera matches VGDuetLayoutMath.computeGreenScreenRects '
              'geometry within 0.5px tolerance',
          'preview texture attach success (1080x1920 canvas)',
          'diagnostic layoutConfig keys (debugGreenScreenBackgroundMode=solid_teal, '
              'debugGreenScreenView=camera_passthrough) accepted and forwarded to preview render loop',
          'startRecording activates preview render loop and camera',
          'bounded initial free-transform observation window (~2s) executes cleanly',
          'mid-session updateLayout accepts second free transform (scale 0.55 < 1.0, '
              'offset {0.85, -0.35}, off-center anchor {0.25, 0.75}, rotationDegrees -35.0)',
          'bounded updated free-transform observation window (~2s) executes cleanly',
          'clean stopRecording, detachPreviewTexture, disposeSession, and temp directory cleanup',
        ],
        'nonClaims': <String>[
          'no automated pixel rotation verification: actual on-screen or GPU-rendered pixel rotation '
              'is not read back or numerically measured by this harness; requires visual confirmation '
              'on physical device display',
          'no matte quality or edge accuracy proof: live segmentation mask quality is not measured',
          'no MediaPipe GPU delegate proof: default production GLES compositor path is exercised',
          'no offline export or audio mixing proof',
          'no low-end or multi-device performance proof',
        ],
        'sessionId': sessionId,
        'textureId': textureId,
        'canvasSize': kCanvasSize.toMap(),
        'firstTransform': kFirstTransform.toMap(),
        'firstExpectedCameraRect': firstExpectedCameraRect?.toMap(),
        'firstActualCameraRect': firstActualCameraRect?.toMap(),
        'secondTransform': kSecondTransform.toMap(),
        'secondExpectedCameraRect': secondExpectedCameraRect?.toMap(),
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
                  aspectRatio: kCanvasSize.aspectRatio,
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
                        'Android Duet Green Screen Free Transform Smoke',
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
                          'Texture ID: $_textureId | Transform: $_activeTransformLabel',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      if (_totalHoldSeconds > 0)
                        Text(
                          'Hold Progress: $_elapsedHoldSeconds/$_totalHoldSeconds s',
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
