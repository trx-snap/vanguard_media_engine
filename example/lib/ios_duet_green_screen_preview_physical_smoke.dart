// Copyright 2026, Connects. All rights reserved.
// ios_duet_green_screen_preview_physical_smoke.dart
//
// Frozen iOS Duet green-screen preview physical smoke harness.
//
// Proof boundary:
//   - Prove package-example iOS Duet green-screen preview using bundled
//     local fixture and native green-screen layout attachment.
//   - Claims allowed:
//       * local source session initialization
//       * attach-time greenScreen layout accepts/preserves the creatorOverlay foregroundTransform route through platform setup
//       * attach-time native layout rect for creatorOverlay was returned and matched expected geometry
//       * startRecording activates render loop with green-screen compositor
//       * green-screen preview remains active for bounded wait (5 s)
//       * layout update to safe-parity PiP rect works while active
//       * PiP preview remains active for bounded wait (1.5 s)
//       * stop/detach/dispose cleanup routes complete
//       * temp fixture cleanup completes
//       * native IOS_DUET_GREENSCREEN_MASK_BLEND_FIRST may evidence a mask reached CoreImage blend
//   - Non-claims:
//       * no Dart frame counter
//       * no rendered pixel / visual placement proof (rendered pixels not measured)
//       * no matte quality proof (VanguardMLSegmenter faults are tolerated)
//       * no export MP4 proof
//       * no mic/audio proof
//       * no speed control proof
//       * no ConnectsApp/Universal Editor/upload wiring

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_duet.dart';

const String kSmokeStartMarker =
    'IOS_DUET_GREENSCREEN_PREVIEW_PHYSICAL_SMOKE_START';
const String kSmokePassMarker = 'IOS_DUET_GREENSCREEN_PREVIEW_PHYSICAL_PASS';
const String kSmokeFailMarker = 'IOS_DUET_GREENSCREEN_PREVIEW_PHYSICAL_FAIL';
const String kSmokeJsonPrefix = 'IOS_DUET_GREENSCREEN_PREVIEW_PHYSICAL_JSON:';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IOSDuetGreenScreenPreviewPhysicalSmokeApp());
}

class IOSDuetGreenScreenPreviewPhysicalSmokeApp extends StatefulWidget {
  const IOSDuetGreenScreenPreviewPhysicalSmokeApp({super.key});

  @override
  State<IOSDuetGreenScreenPreviewPhysicalSmokeApp> createState() =>
      _IOSDuetGreenScreenPreviewPhysicalSmokeAppState();
}

class _IOSDuetGreenScreenPreviewPhysicalSmokeAppState
    extends State<IOSDuetGreenScreenPreviewPhysicalSmokeApp> {
  final VGDuetPlatformInterface _platform = const MethodChannelVGDuetPlatform();

  String _status = 'Starting green-screen smoke harness...';
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
    Map<String, dynamic>? creatorOverlayCameraRect;
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
        print('IOS_DUET_GREENSCREEN_STEP_${stepName}_PASS');
        return result;
      } catch (e, st) {
        stepResults[stepName] = 'FAIL';
        final failureMsg = '$stepName: $e';
        if (!failures.contains(failureMsg)) {
          failures.add(failureMsg);
        }
        print('IOS_DUET_GREENSCREEN_STEP_${stepName}_FAIL: $e\n$st');
        rethrow;
      }
    }

    try {
      // Step 1: STAGE_FIXTURE — stage clip_A.mov from rootBundle into temp directory
      final source = await runStep<VGDuetSource>(
        'STAGE_FIXTURE',
        'Staging clip_A.mov into temp directory',
        () async {
          tempDir = await Directory.systemTemp.createTemp('duet_gs_smoke_');
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

      // Step 2: INIT_SESSION — trim 0.0s to 2.5s
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

      // Step 3: ATTACH_PREVIEW_GREENSCREEN — canvas 1080x1920 with greenScreen creatorOverlay layout
      await runStep<VGDuetPreviewTexture>(
        'ATTACH_PREVIEW_GREENSCREEN',
        'Attaching preview texture (1080x1920, greenScreen creatorOverlay)',
        () async {
          final preview = await _withTimeout(
            _platform.attachPreviewTexture(
              sessionId: sessionId!,
              canvasSize: const VGDuetSize(1080, 1920),
              layoutConfig: VGDuetLayoutConfig(
                mode: VGDuetLayoutMode.greenScreen,
                foregroundTransform: VGDuetForegroundTransform.creatorOverlay,
              ),
            ),
            'attachPreviewTexture (greenScreen)',
          );
          if (preview.textureId < 0) {
            throw StateError('Invalid textureId: ${preview.textureId}');
          }
          final cameraRect = preview.layoutRects?['camera'];
          if (cameraRect == null) {
            throw StateError(
              'Missing preview.layoutRects["camera"] in attachPreviewTexture reply',
            );
          }
          const expectedLeft = 205.2;
          const expectedTop = 576.0;
          const expectedWidth = 669.6;
          const expectedHeight = 1190.4;
          const tolerance = 0.5;
          if ((cameraRect.left - expectedLeft).abs() > tolerance ||
              (cameraRect.top - expectedTop).abs() > tolerance ||
              (cameraRect.width - expectedWidth).abs() > tolerance ||
              (cameraRect.height - expectedHeight).abs() > tolerance) {
            throw StateError(
              'Mismatched creatorOverlay camera rect: got $cameraRect, '
              'expected left=$expectedLeft, top=$expectedTop, '
              'width=$expectedWidth, height=$expectedHeight (tolerance=$tolerance)',
            );
          }
          creatorOverlayCameraRect = cameraRect.toMap();
          textureId = preview.textureId;
          if (mounted) {
            setState(() {
              _textureId = preview.textureId;
              _layoutMode = 'greenScreen';
            });
          }
          return preview;
        },
      );

      // Step 4: START_RECORDING
      await runStep<void>(
        'START_RECORDING',
        'Starting recording to activate green-screen preview render loop',
        () async {
          await _withTimeout(
            _platform.startRecording(sessionId: sessionId!),
            'startRecording',
          );
        },
      );

      // Step 5: GREENSCREEN_PREVIEW_ACTIVE — wait 5 seconds
      await runStep<void>(
        'GREENSCREEN_PREVIEW_ACTIVE',
        'Observing green-screen preview active (5.0s)',
        () async {
          await Future<void>.delayed(const Duration(seconds: 5));
        },
      );

      // Step 6: UPDATE_LAYOUT_PIP — safe parity rect left 0.58, top 0.05, width 0.36, height 0.24
      await runStep<void>(
        'UPDATE_LAYOUT_PIP',
        'Updating layout to safe-parity PiP (topRight, 0.58/0.05/0.36/0.24)',
        () async {
          final pipConfig = VGDuetLayoutConfig(
            mode: VGDuetLayoutMode.pip,
            pipAnchor: VGDuetPiPAnchor.topRight,
            pipNormalizedRect: const VGDuetRect(
              left: 0.58,
              top: 0.05,
              width: 0.36,
              height: 0.24,
            ),
          );
          await _withTimeout(
            _platform.updateLayout(
              sessionId: sessionId!,
              layoutConfig: pipConfig,
            ),
            'updateLayout (pip)',
          );
          if (mounted) {
            setState(() {
              _layoutMode = 'pip (topRight safe-parity)';
            });
          }
        },
      );

      // Step 7: PIP_PREVIEW_ACTIVE — wait 1.5 seconds
      await runStep<void>(
        'PIP_PREVIEW_ACTIVE',
        'Observing PiP preview active (1.5s)',
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        },
      );

      // Step 8: PAUSE_RECORDING
      await runStep<void>('PAUSE_RECORDING', 'Pausing recording', () async {
        await _withTimeout(
          _platform.pauseRecording(sessionId: sessionId!),
          'pauseRecording',
        );
      });

      // Step 9: STOP_RECORDING
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

      // Step 10: DETACH_PREVIEW — tolerate session_not_found after stop
      await runStep<void>(
        'DETACH_PREVIEW',
        'Detaching preview texture (session_not_found tolerated)',
        () async {
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
                'IOS_DUET_GREENSCREEN: texture already detached during stopRecording: $e',
              );
            } else {
              rethrow;
            }
          }
          isDetached = true;
        },
      );

      // Step 11: DISPOSE_SESSION
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

      // Step 12: CLEANUP_TEMP_FIXTURE
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
      // Cleanup fallback: detach, dispose, and temp dir deletion — all best-effort.
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
              'IOS_DUET_GREENSCREEN: cleanup detachPreviewTexture note: $e',
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
            print('IOS_DUET_GREENSCREEN: cleanup disposeSession note: $e');
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
          print('IOS_DUET_GREENSCREEN: cleanup tempDir delete note: $e');
        }
      }

      final payload = <String, Object?>{
        'pass': pass,
        'proofBoundary': 'ios_duet_green_screen_preview_physical_smoke',
        'claimsAllowed': <String>[
          'local source session initialization',
          'attach-time greenScreen layout accepts/preserves the creatorOverlay foregroundTransform route through platform setup',
          'attach-time native layout rect for creatorOverlay was returned and matched expected geometry',
          'startRecording activates render loop with green-screen compositor',
          'green-screen preview remains active for bounded wait (5 s)',
          'layout update to safe-parity PiP rect works while active',
          'PiP preview remains active for bounded wait (1.5 s)',
          'stop/detach/dispose cleanup routes complete',
          'temp fixture cleanup completes',
          'native IOS_DUET_GREENSCREEN_MASK_BLEND_FIRST may evidence a mask reached CoreImage blend',
        ],
        'nonClaims': <String>[
          'no Dart frame counter',
          'no rendered pixel / visual placement proof (rendered pixels not measured)',
          'no matte quality proof (VanguardMLSegmenter faults are tolerated)',
          'no export MP4 proof',
          'no mic/audio proof',
          'no speed control proof',
          'no ConnectsApp/Universal Editor/upload wiring',
        ],
        'sessionId': sessionId,
        'textureId': textureId,
        'creatorOverlayCameraRect': ?creatorOverlayCameraRect,
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
                        'iOS Duet Green-Screen Preview Physical Smoke',
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
