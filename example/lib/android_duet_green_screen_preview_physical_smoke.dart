// Copyright 2026, Connects. All rights reserved.
// android_duet_green_screen_preview_physical_smoke.dart
//
// Frozen Android Duet green-screen preview physical smoke harness.
//
// This harness exercises the OPT-IN Vulkan preview diagnostic route: the
// attach-time layoutConfig sets `debugPreviewBackend: "vulkan"` (a native-only
// debug key not exposed by the public `VGDuetLayoutConfig` Dart model, sent
// via a raw `MethodChannel("vanguard_media_engine")` call for the attach step
// only) alongside `mode: "greenScreen"`, which is the only combination that
// makes `AndroidDuetPreviewBackendFactory.selectForLayoutConfig` request the
// Vulkan preview backend. If the native Vulkan capability probe fails, the
// existing selector falls back to GLES automatically; either outcome is
// logged once via `ANDROID_DUET_PREVIEW_BACKEND_SELECTED`. Production
// PiP/split layouts and normal greenScreen (without this debug key) are
// unaffected and keep using GLES.
//
// ANDROID-DUET-VULKAN-LAYOUT: after the bounded greenScreen window this
// harness switches the layout mid-session to `pip` and then to
// `splitTopBottom` via the typed `updateDuetLayout` call. Backend selection is
// attach-time only (updateDuetLayout never re-selects or rebuilds the render
// loop), so the attach-time Vulkan diagnostic backend stays in effect and the
// switches exercise the Vulkan compositor's non-green-screen layout render
// path (`ANDROID_DUET_VULKAN_LAYOUT_FRAME_FIRST`) whenever the actual backend
// selected was vulkan. When the actual backend fell back to GLES the same
// switches exercise the production GLES PiP/split path instead.
//
// Proof boundary:
//   - Device requirement: Android physical device with camera permission available.
//   - Harness command:
//       cd packages/vanguard_media_engine/example && flutter run -d <deviceId> -t lib/android_duet_green_screen_preview_physical_smoke.dart
//   - Claims allowed:
//       * local source session init
//       * attach-time greenScreen layout accepts/preserves the creatorOverlay foregroundTransform route through platform setup, with the opt-in `debugPreviewBackend: "vulkan"` diagnostic key present in the raw attach payload
//       * attach-time native layout rect for creatorOverlay was returned and matched expected geometry
//       * preview texture attach success
//       * native `ANDROID_DUET_PREVIEW_BACKEND_SELECTED requested=vulkan ...` log evidences the diagnostic route was requested (actual may still be gles on probe failure — fallback is expected behavior, not a defect)
//       * startRecording activates render loop/camera
//       * bounded green-screen preview remains active
//       * MediaPipe CPU primary (`mediapipe_cpu`) selected when model asset is bundled
//       * native `ANDROID_DUET_GREENSCREEN_MEDIAPIPE_MASK_FIRST` log may evidence first MediaPipe mask
//       * native `ANDROID_DUET_GREENSCREEN_TEMPORAL_SMOOTHING_FIRST` log may evidence temporal smoothing
//       * native `ANDROID_DUET_GREENSCREEN_MASK_UPLOAD_FIRST ... format=uint8_alpha backend=mediapipe_cpu` log may evidence GLES upload
//       * native `ANDROID_DUET_VULKAN_MASK_UPLOAD_FIRST` / `ANDROID_DUET_VULKAN_PREVIEW_FRAME_FIRST` logs may evidence a first successful Vulkan mask upload / composited frame, only when the actual backend selected is vulkan
//       * mid-session `updateDuetLayout` to `pip` (safe rect) and then `splitTopBottom` is accepted by the platform while the attach-time backend selection (Vulkan diagnostic when the probe passed) stays in effect, each followed by a bounded active window
//       * native `ANDROID_DUET_VULKAN_LAYOUT_FRAME_FIRST` log may evidence a first successful Vulkan non-green-screen (PiP / split) layout frame, only when the actual backend selected is vulkan
//       * stop/detach/dispose/temp cleanup complete
//   - Non-claims:
//       * no production-default backend claim: this route is opt-in only via `debugPreviewBackend: "vulkan"`; the default selection (no debug key) remains GLES for all layout modes, including greenScreen, PiP and split
//       * no Vulkan layout production claim: PiP/split attach without the debug key still selects GLES; the Vulkan layout path is only reachable mid-session after a Vulkan diagnostic greenScreen attach
//       * no Vulkan layout pixel proof: PiP / splitTopBottom placement, aspect-fill crop and rendered pixels are not measured, only that the layout switch is accepted and the native layout render path may emit its first-frame log
//       * no MediaPipe GPU delegate proof
//       * no adaptive quality tier proof
//       * no low-end/budget Android proof
//       * no rendered pixel / visual placement proof (rendered pixels not measured)
//       * no pixel-quality proof: Vulkan-composited frame visual/matte quality is not evaluated, only that the render path executes and emits the expected native logs
//       * no matte quality proof
//       * no export/audio/speed/app wiring proof

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_duet.dart';

const String kSmokeStartMarker =
    'ANDROID_DUET_GREENSCREEN_PREVIEW_PHYSICAL_SMOKE_START';
const String kSmokePassMarker =
    'ANDROID_DUET_GREENSCREEN_PREVIEW_PHYSICAL_PASS';
const String kSmokeFailMarker =
    'ANDROID_DUET_GREENSCREEN_PREVIEW_PHYSICAL_FAIL';
const String kSmokeJsonPrefix =
    'ANDROID_DUET_GREENSCREEN_PREVIEW_PHYSICAL_JSON:';

/// Raw channel used ONLY for the attach step, so the layoutConfig map can
/// carry the `debugPreviewBackend` diagnostic key that `VGDuetLayoutConfig`
/// does not expose through the public Dart API. Every other platform call in
/// this harness goes through the typed [VGDuetPlatformInterface] as before.
const MethodChannel _rawDuetChannel = MethodChannel('vanguard_media_engine');

const String _kDefaultSourceAsset = 'assets/manual_test_clips/clip_A.mov';
const double _kDefaultTrimEndSeconds = 2.5;
const double _kDefaultActiveSeconds = 5.0;
const double kTrimStartSeconds = 0.0;

const String _kSourceAssetRaw = String.fromEnvironment(
  'VG_ANDROID_DUET_GREENSCREEN_PREVIEW_SOURCE_ASSET',
  defaultValue: _kDefaultSourceAsset,
);

const String _kTrimEndSecondsRaw = String.fromEnvironment(
  'VG_ANDROID_DUET_GREENSCREEN_PREVIEW_TRIM_END_SECONDS',
  defaultValue: '2.5',
);

const String _kActiveSecondsRaw = String.fromEnvironment(
  'VG_ANDROID_DUET_GREENSCREEN_PREVIEW_ACTIVE_SECONDS',
  defaultValue: '5.0',
);

String _parseSourceAsset(String raw, String defaultValue) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return defaultValue;
  return trimmed;
}

double _parsePositiveSeconds(String raw, double defaultValue) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return defaultValue;
  final parsed = double.tryParse(trimmed);
  if (parsed == null || !parsed.isFinite || parsed <= 0.0) {
    return defaultValue;
  }
  return parsed;
}

String _assetFileName(String assetPath) {
  final trimmed = assetPath.trim().replaceAll(r'\', '/');
  final segments = trimmed.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) {
    return 'clip_A.mov';
  }
  return segments.last;
}

final String kSourceAsset = _parseSourceAsset(
  _kSourceAssetRaw,
  _kDefaultSourceAsset,
);

final double kTrimEndSeconds = _parsePositiveSeconds(
  _kTrimEndSecondsRaw,
  _kDefaultTrimEndSeconds,
);

final double kGreenScreenPreviewActiveSeconds = _parsePositiveSeconds(
  _kActiveSecondsRaw,
  _kDefaultActiveSeconds,
);

final String kStagedSourceFileName = _assetFileName(kSourceAsset);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetGreenScreenPreviewPhysicalSmokeApp());
}

class AndroidDuetGreenScreenPreviewPhysicalSmokeApp extends StatefulWidget {
  const AndroidDuetGreenScreenPreviewPhysicalSmokeApp({super.key});

  @override
  State<AndroidDuetGreenScreenPreviewPhysicalSmokeApp> createState() =>
      _AndroidDuetGreenScreenPreviewPhysicalSmokeAppState();
}

class _AndroidDuetGreenScreenPreviewPhysicalSmokeAppState
    extends State<AndroidDuetGreenScreenPreviewPhysicalSmokeApp> {
  final VGDuetPlatformInterface _platform = const MethodChannelVGDuetPlatform();

  String _status =
      'Starting green-screen smoke harness ($kStagedSourceFileName)...';
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
        print('ANDROID_DUET_GREENSCREEN_PREVIEW_STEP_${stepName}_PASS');
        return result;
      } catch (e, st) {
        stepResults[stepName] = 'FAIL';
        final failureMsg = '$stepName: $e';
        if (!failures.contains(failureMsg)) {
          failures.add(failureMsg);
        }
        print(
          'ANDROID_DUET_GREENSCREEN_PREVIEW_STEP_${stepName}_FAIL: $e\n$st',
        );
        rethrow;
      }
    }

    try {
      // Step 1: Stage $kStagedSourceFileName fixture from rootBundle into temp directory
      final source = await runStep<VGDuetSource>(
        'STAGE_FIXTURE',
        'Staging $kStagedSourceFileName into temp directory',
        () async {
          tempDir = await Directory.systemTemp.createTemp(
            'duet_greenscreen_smoke_',
          );
          final targetFile = File('${tempDir!.path}/$kStagedSourceFileName');
          final byteData = await rootBundle.load(kSourceAsset);
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

      // Step 2: Initialize Duet session with trim window ${kTrimStartSeconds}s to ${kTrimEndSeconds}s
      sessionId = await runStep<String>(
        'INIT_SESSION',
        'Initializing Duet session (trim: ${kTrimStartSeconds}s - ${kTrimEndSeconds}s)',
        () async {
          final trimWindow = VGDuetTrimWindow(
            startSeconds: kTrimStartSeconds,
            endSeconds: kTrimEndSeconds,
          );
          return await _withTimeout(
            _platform.initializeSession(source: source, trimWindow: trimWindow),
            'initializeSession',
          );
        },
      );

      // Step 3: Attach preview texture (1080x1920, greenScreen creatorOverlay,
      // opt-in debugPreviewBackend="vulkan" diagnostic route). Uses the raw
      // MethodChannel directly (not VGDuetPlatformInterface) so the
      // native-only debugPreviewBackend key can ride alongside the existing
      // greenScreen creatorOverlay fields.
      await runStep<VGDuetPreviewTexture>(
        'ATTACH_PREVIEW_GREENSCREEN',
        'Attaching preview texture (1080x1920, greenScreen creatorOverlay, debugPreviewBackend=vulkan)',
        () async {
          final rawResult = await _withTimeout(
            _rawDuetChannel.invokeMethod<Map>(
              'attachDuetPreviewTexture',
              <String, dynamic>{
                'sessionId': sessionId!,
                'canvasSize': const VGDuetSize(1080, 1920).toMap(),
                'layoutConfig': <String, dynamic>{
                  'mode': 'greenScreen',
                  'isSideSwapped': false,
                  'isTopBottomSwapped': false,
                  'foregroundTransform': VGDuetForegroundTransform
                      .creatorOverlay
                      .toMap(),
                  'debugPreviewBackend': 'vulkan',
                },
              },
            ),
            'attachPreviewTexture',
          );
          if (rawResult == null) {
            throw StateError('attachDuetPreviewTexture returned null result');
          }
          final preview = VGDuetPreviewTexture.fromMap(
            Map<String, dynamic>.from(rawResult),
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

      // Step 4: Start recording (activates preview render loop & camera)
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

      // Step 5: Wait ${kGreenScreenPreviewActiveSeconds}s with greenScreen preview active
      await runStep<void>(
        'GREENSCREEN_PREVIEW_ACTIVE',
        'Observing greenScreen preview active (${kGreenScreenPreviewActiveSeconds}s)',
        () async {
          await Future<void>.delayed(
            Duration(
              milliseconds: (kGreenScreenPreviewActiveSeconds * 1000).round(),
            ),
          );
        },
      );

      // Step 6: Switch layout to PiP mid-session (safe PiP rect left 0.58,
      // top 0.05, width 0.36, height 0.24). Backend selection is attach-time
      // only, so the attach-time Vulkan diagnostic backend (when the probe
      // passed) keeps rendering, now through its non-green-screen layout path.
      await runStep<void>(
        'UPDATE_LAYOUT_PIP_VULKAN',
        'Switching layout to PiP mid-session (safe rect: left 0.58, top 0.05, width 0.36, height 0.24) on the attach-time Vulkan diagnostic backend',
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
            'updateLayout(pip)',
          );
          print('ANDROID_DUET_VULKAN_LAYOUT_SMOKE_SWITCHED mode=pip');
          if (mounted) {
            setState(() {
              _layoutMode = 'pip (vulkan diagnostic)';
            });
          }
        },
      );

      // Step 7: Bounded wait with PiP layout active
      await runStep<void>(
        'PIP_VULKAN_LAYOUT_ACTIVE',
        'Observing PiP layout active on the Vulkan diagnostic route (1.5s)',
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        },
      );

      // Step 8: Switch layout to splitTopBottom mid-session
      await runStep<void>(
        'UPDATE_LAYOUT_SPLIT_TOP_BOTTOM_VULKAN',
        'Switching layout to splitTopBottom mid-session on the attach-time Vulkan diagnostic backend',
        () async {
          final splitConfig = VGDuetLayoutConfig(
            mode: VGDuetLayoutMode.splitTopBottom,
          );
          await _withTimeout(
            _platform.updateLayout(
              sessionId: sessionId!,
              layoutConfig: splitConfig,
            ),
            'updateLayout(splitTopBottom)',
          );
          print(
            'ANDROID_DUET_VULKAN_LAYOUT_SMOKE_SWITCHED mode=splitTopBottom',
          );
          if (mounted) {
            setState(() {
              _layoutMode = 'splitTopBottom (vulkan diagnostic)';
            });
          }
        },
      );

      // Step 9: Bounded wait with splitTopBottom layout active
      await runStep<void>(
        'SPLIT_TOP_BOTTOM_VULKAN_LAYOUT_ACTIVE',
        'Observing splitTopBottom layout active on the Vulkan diagnostic route (1.5s)',
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        },
      );

      // Step 10: Pause recording
      await runStep<void>('PAUSE_RECORDING', 'Pausing recording', () async {
        await _withTimeout(
          _platform.pauseRecording(sessionId: sessionId!),
          'pauseRecording',
        );
      });

      // Step 11: Stop recording
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

      // Step 12: Detach preview texture
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
              'ANDROID_DUET_GREENSCREEN_PREVIEW: texture already detached during stopRecording: $e',
            );
          } else {
            rethrow;
          }
        }
        isDetached = true;
      });

      // Step 13: Dispose session
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

      // Step 14: Cleanup temp fixture directory
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
              'ANDROID_DUET_GREENSCREEN_PREVIEW: cleanup detachPreviewTexture note: $e',
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
            print(
              'ANDROID_DUET_GREENSCREEN_PREVIEW: cleanup disposeSession note: $e',
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
            'ANDROID_DUET_GREENSCREEN_PREVIEW: cleanup tempDir delete note: $e',
          );
        }
      }

      final payload = <String, Object?>{
        'pass': pass,
        'proofBoundary': 'android_duet_green_screen_preview_physical_smoke',
        'claimsAllowed': <String>[
          'local source session init',
          'attach-time greenScreen layout accepts/preserves the creatorOverlay foregroundTransform route through platform setup, with the opt-in `debugPreviewBackend: "vulkan"` diagnostic key present in the raw attach payload',
          'attach-time native layout rect for creatorOverlay was returned and matched expected geometry',
          'preview texture attach success',
          'native `ANDROID_DUET_PREVIEW_BACKEND_SELECTED requested=vulkan ...` log evidences the diagnostic route was requested (actual may still be gles on probe failure — fallback is expected behavior, not a defect)',
          'startRecording activates render loop/camera',
          'bounded green-screen preview remains active',
          'MediaPipe CPU primary (`mediapipe_cpu`) selected when model asset is bundled',
          'native `ANDROID_DUET_GREENSCREEN_MEDIAPIPE_MASK_FIRST` log may evidence first MediaPipe mask',
          'native `ANDROID_DUET_GREENSCREEN_TEMPORAL_SMOOTHING_FIRST` log may evidence temporal smoothing',
          'native `ANDROID_DUET_GREENSCREEN_MASK_UPLOAD_FIRST ... format=uint8_alpha backend=mediapipe_cpu` log may evidence GLES upload',
          'native `ANDROID_DUET_VULKAN_MASK_UPLOAD_FIRST` / `ANDROID_DUET_VULKAN_PREVIEW_FRAME_FIRST` logs may evidence a first successful Vulkan mask upload / composited frame, only when the actual backend selected is vulkan',
          'mid-session `updateDuetLayout` to `pip` (safe rect) and then `splitTopBottom` is accepted by the platform while the attach-time backend selection (Vulkan diagnostic when the probe passed) stays in effect, each followed by a bounded active window',
          'native `ANDROID_DUET_VULKAN_LAYOUT_FRAME_FIRST` log may evidence a first successful Vulkan non-green-screen (PiP / split) layout frame, only when the actual backend selected is vulkan',
          'stop/detach/dispose/temp cleanup complete',
        ],
        'nonClaims': <String>[
          'no production-default backend claim: this route is opt-in only via `debugPreviewBackend: "vulkan"`; the default selection (no debug key) remains GLES for all layout modes, including greenScreen, PiP and split',
          'no Vulkan layout production claim: PiP/split attach without the debug key still selects GLES; the Vulkan layout path is only reachable mid-session after a Vulkan diagnostic greenScreen attach',
          'no Vulkan layout pixel proof: PiP / splitTopBottom placement, aspect-fill crop and rendered pixels are not measured, only that the layout switch is accepted and the native layout render path may emit its first-frame log',
          'no MediaPipe GPU delegate proof',
          'no adaptive quality tier proof',
          'no low-end/budget Android proof',
          'no rendered pixel / visual placement proof (rendered pixels not measured)',
          'no pixel-quality proof: Vulkan-composited frame visual/matte quality is not evaluated',
          'no matte quality proof',
          'no export/audio/speed/app wiring proof',
        ],
        'sessionId': sessionId,
        'textureId': textureId,
        'sourceAsset': kSourceAsset,
        'stagedSourceFileName': kStagedSourceFileName,
        'trimStartSeconds': kTrimStartSeconds,
        'trimEndSeconds': kTrimEndSeconds,
        'greenScreenPreviewActiveSeconds': kGreenScreenPreviewActiveSeconds,
        'creatorOverlayCameraRect': ?creatorOverlayCameraRect,
        'vulkanLayoutRoute': <String, Object?>{
          'layoutSwitchSequence': <String>[
            'greenScreen',
            'pip',
            'splitTopBottom',
          ],
          'pipSwitchStep': stepResults['UPDATE_LAYOUT_PIP_VULKAN'],
          'pipActiveStep': stepResults['PIP_VULKAN_LAYOUT_ACTIVE'],
          'splitTopBottomSwitchStep':
              stepResults['UPDATE_LAYOUT_SPLIT_TOP_BOTTOM_VULKAN'],
          'splitTopBottomActiveStep':
              stepResults['SPLIT_TOP_BOTTOM_VULKAN_LAYOUT_ACTIVE'],
          'backendSelectionAttachTimeOnly': true,
          'pixelProof': false,
          'productionGatingUnchanged': true,
        },
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
                        'Android Duet Green Screen Preview Physical Smoke',
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
