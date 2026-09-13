// Copyright 2026, Connects. All rights reserved.
// android_duet_green_screen_tasks_live_physical_smoke.dart
//
// Android Duet green-screen "right foundation" RND physical smoke harness:
//   CameraX ImageAnalysis -> official MediaPipe Tasks ImageSegmenter
//   (RunningMode.LIVE_STREAM) -> static background composite -> Flutter Texture.
//
// Proof boundary:
//   - Device requirement: Android physical device with CAMERA permission
//     already granted to the example app.
//   - Harness command:
//       cd packages/vanguard_media_engine/example && flutter run -d <deviceId> \
//         -t lib/android_duet_green_screen_tasks_live_physical_smoke.dart \
//         --dart-define=VG_DUET_GREENSCREEN_TASKS_BACKEND=cpu_confidence \
//         --dart-define=VG_DUET_GREENSCREEN_TASKS_HOLD_SECONDS=12 \
//         --dart-define=VG_DUET_GREENSCREEN_TASKS_BACKGROUND_MODE=solid_teal \
//         --dart-define=VG_DUET_GREENSCREEN_TASKS_MAX_FRESHNESS_MS=250 \
//         --dart-define=VG_DUET_GREENSCREEN_TASKS_VIEW_MODE=composite
//   - Claims allowed (if PASS):
//       * RND diagnostic only
//       * real front camera frames reached MediaPipe Tasks LIVE_STREAM
//       * fresh person masks were composited over a STATIC background
//       * the composite was presented through a Flutter Texture
//       * CameraX Preview was consumed offscreen and never presented
//       * clean stop / release
//   - Non-claims:
//       * no video background
//       * no export
//       * no production Duet session or app wiring
//       * no TikTok-quality (matte quality / latency / thermal) claim
//       * no GPU confidence-mask proof (GPU is category-mask only)

// ignore_for_file: avoid_print, use_null_aware_elements

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String kSmokeStartMarker = 'ANDROID_DUET_GREENSCREEN_TASKS_LIVE_START';
const String kSmokePassMarker = 'ANDROID_DUET_GREENSCREEN_TASKS_LIVE_PASS';
const String kSmokeFailMarker = 'ANDROID_DUET_GREENSCREEN_TASKS_LIVE_FAIL';
const String kSmokeJsonPrefix = 'ANDROID_DUET_GREENSCREEN_TASKS_LIVE_JSON:';

const String kEngineChannel = 'vanguard_media_engine';
const String kStartMethod = 'startAndroidDuetGreenScreenTasksLiveSmoke';
const String kStopMethod = 'stopAndroidDuetGreenScreenTasksLiveSmoke';

/// cpu_confidence (default) | cpu_category | gpu_category
const String kBackend = String.fromEnvironment(
  'VG_DUET_GREENSCREEN_TASKS_BACKEND',
  defaultValue: 'cpu_confidence',
);

const int kHoldSeconds = int.fromEnvironment(
  'VG_DUET_GREENSCREEN_TASKS_HOLD_SECONDS',
  defaultValue: 12,
);

/// solid_teal (default) | checker | picture_still_c
const String kBackgroundMode = String.fromEnvironment(
  'VG_DUET_GREENSCREEN_TASKS_BACKGROUND_MODE',
  defaultValue: 'solid_teal',
);

/// raw | smoothstep (default) | binary
const String kMatteMode = String.fromEnvironment(
  'VG_DUET_GREENSCREEN_TASKS_MATTE_MODE',
  defaultValue: 'smoothstep',
);

/// camera (default) | none | inverse
const String kMaskRotationPolicy = String.fromEnvironment(
  'VG_DUET_GREENSCREEN_TASKS_MASK_ROTATION_POLICY',
  defaultValue: 'camera',
);

/// metadata (default) | upright_bitmap
const String kSegmentInputOrientationPolicy = String.fromEnvironment(
  'VG_DUET_GREENSCREEN_TASKS_SEGMENT_INPUT_ORIENTATION_POLICY',
  defaultValue: 'metadata',
);

const String kMatteLowRaw = String.fromEnvironment(
  'VG_DUET_GREENSCREEN_TASKS_MATTE_LOW',
  defaultValue: '0.18',
);

const String kMatteHighRaw = String.fromEnvironment(
  'VG_DUET_GREENSCREEN_TASKS_MATTE_HIGH',
  defaultValue: '0.62',
);

const String kMatteGammaRaw = String.fromEnvironment(
  'VG_DUET_GREENSCREEN_TASKS_MATTE_GAMMA',
  defaultValue: '0.85',
);

double get kMatteLow => double.tryParse(kMatteLowRaw) ?? 0.18;

double get kMatteHigh => double.tryParse(kMatteHighRaw) ?? 0.62;

double get kMatteGamma => double.tryParse(kMatteGammaRaw) ?? 0.85;

const int kMaxFreshnessMs = int.fromEnvironment(
  'VG_DUET_GREENSCREEN_TASKS_MAX_FRESHNESS_MS',
  defaultValue: 250,
);

const int kStatsWarmupSeconds = int.fromEnvironment(
  'VG_DUET_GREENSCREEN_TASKS_STATS_WARMUP_SECONDS',
  defaultValue: 0,
);

const int kSegmentLongEdge = int.fromEnvironment(
  'VG_DUET_GREENSCREEN_TASKS_SEGMENT_LONG_EDGE',
  defaultValue: 256,
);

/// composite (default) | mask | binary_mask
const String kViewMode = String.fromEnvironment(
  'VG_DUET_GREENSCREEN_TASKS_VIEW_MODE',
  defaultValue: 'composite',
);

const String kProofBoundary =
    'android_duet_green_screen_tasks_live_physical_smoke_rnd_static_background_only';

const List<String> kClaimsAllowed = <String>[
  'rnd diagnostic only',
  'real front camera frames reached MediaPipe Tasks ImageSegmenter LIVE_STREAM',
  'fresh person masks composited over a static background',
  'composite presented through a Flutter Texture',
  'CameraX Preview consumed offscreen, never presented',
  'clean stop / release',
];

const List<String> kNonClaims = <String>[
  'no video background',
  'no export',
  'no production Duet session or app wiring',
  'no TikTok-quality claim (matte quality, latency, thermal)',
  'no GPU confidence-mask proof (GPU is category-mask only)',
  'viewMode=$kViewMode (mask modes are diagnostic only; no composite claim)',
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetGreenScreenTasksLiveSmokeApp());
}

class AndroidDuetGreenScreenTasksLiveSmokeApp extends StatefulWidget {
  const AndroidDuetGreenScreenTasksLiveSmokeApp({super.key});

  @override
  State<AndroidDuetGreenScreenTasksLiveSmokeApp> createState() =>
      _AndroidDuetGreenScreenTasksLiveSmokeAppState();
}

class _AndroidDuetGreenScreenTasksLiveSmokeAppState
    extends State<AndroidDuetGreenScreenTasksLiveSmokeApp> {
  static const MethodChannel _channel = MethodChannel(kEngineChannel);

  String _step = 'INIT';
  String _status = 'Starting green-screen Tasks live proof...';
  int? _textureId;
  int _outputWidth = 720;
  int _outputHeight = 1280;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runProof();
    });
  }

  void _updateStatus(String step, String status) {
    if (!mounted) return;
    setState(() {
      _step = step;
      _status = status;
    });
  }

  Future<void> _runProof() async {
    print(kSmokeStartMarker);
    print(
      'config backend=$kBackend holdSeconds=$kHoldSeconds '
      'backgroundMode=$kBackgroundMode maxFreshnessMs=$kMaxFreshnessMs '
      'viewMode=$kViewMode matteMode=$kMatteMode '
      'maskRotationPolicy=$kMaskRotationPolicy '
      'segmentInputOrientationPolicy=$kSegmentInputOrientationPolicy '
      'matteLow=$kMatteLow matteHigh=$kMatteHigh matteGamma=$kMatteGamma '
      'statsWarmupSeconds=$kStatsWarmupSeconds '
      'segmentLongEdge=$kSegmentLongEdge',
    );

    bool pass = false;
    String? errorMessage;
    Map<String, dynamic>? startResult;
    Map<String, dynamic>? stopResult;
    final holdSeconds = kHoldSeconds < 1 ? 1 : kHoldSeconds;

    try {
      // 1. Start the native proof; it replies as soon as the segmenter exists
      //    and the camera bind was requested.
      _updateStatus(
        'START',
        'Invoking $kStartMethod ($kBackend, viewMode=$kViewMode)...',
      );
      final dynamic rawStart = await _channel
          .invokeMethod<dynamic>(kStartMethod, <String, Object?>{
            'backend': kBackend,
            'backgroundMode': kBackgroundMode,
            'matteMode': kMatteMode,
            'matteLow': kMatteLow,
            'matteHigh': kMatteHigh,
            'matteGamma': kMatteGamma,
            'maskRotationPolicy': kMaskRotationPolicy,
            'segmentInputOrientationPolicy': kSegmentInputOrientationPolicy,
            'maxFreshnessMs': kMaxFreshnessMs,
            'statsWarmupMs': kStatsWarmupSeconds < 0
                ? 0
                : kStatsWarmupSeconds * 1000,
            'segmentLongEdgePx': kSegmentLongEdge,
            'viewMode': kViewMode,
          })
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
              'Start timed out after 30 seconds waiting for native response',
            ),
          );
      if (rawStart is! Map) {
        throw StateError('Start returned unexpected result: $rawStart');
      }
      startResult = Map<String, dynamic>.from(rawStart);
      if (startResult['pass'] != true) {
        throw StateError(
          'Start failed: ${startResult['failureReason'] ?? startResult}',
        );
      }
      final textureId = (startResult['textureId'] as num?)?.toInt();
      if (textureId == null || textureId < 0) {
        throw StateError('Start returned no textureId: $startResult');
      }
      final outputWidth = (startResult['outputWidth'] as num?)?.toInt() ?? 720;
      final outputHeight =
          (startResult['outputHeight'] as num?)?.toInt() ?? 1280;
      if (mounted) {
        setState(() {
          _textureId = textureId;
          _outputWidth = outputWidth;
          _outputHeight = outputHeight;
        });
      }

      // 2. Hold with the Texture on screen.
      _updateStatus(
        'HOLD',
        'Texture $textureId live; holding $holdSeconds s ($kBackend, $kBackgroundMode, viewMode=$kViewMode)',
      );
      await Future<void>.delayed(Duration(seconds: holdSeconds));

      // 3. Stop and collect telemetry.
      _updateStatus('STOP', 'Invoking $kStopMethod...');
      final dynamic rawStop = await _channel
          .invokeMethod<dynamic>(kStopMethod)
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw TimeoutException(
              'Stop timed out after 20 seconds waiting for native response',
            ),
          );
      if (rawStop is! Map) {
        throw StateError('Stop returned unexpected result: $rawStop');
      }
      stopResult = Map<String, dynamic>.from(rawStop);
      pass = stopResult['pass'] == true;
      if (!pass) {
        errorMessage = 'Stop summary failed: ${stopResult['failureReason']}';
      }
    } catch (e, st) {
      pass = false;
      errorMessage = '$e\n$st';
      // Best effort: never leave the native proof running after a harness error.
      try {
        final dynamic rawStop = await _channel
            .invokeMethod<dynamic>(kStopMethod)
            .timeout(const Duration(seconds: 10));
        if (rawStop is Map && stopResult == null) {
          stopResult = Map<String, dynamic>.from(rawStop);
        }
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _textureId = null;
        _finished = true;
      });
    }

    final payload = <String, Object?>{
      'pass': pass,
      'proofBoundary': kProofBoundary,
      'viewMode': kViewMode,
      'backend': kBackend,
      'backgroundMode': kBackgroundMode,
      'matteMode': kMatteMode,
      'matteLow': kMatteLow,
      'matteHigh': kMatteHigh,
      'matteGamma': kMatteGamma,
      'maskRotationPolicy': kMaskRotationPolicy,
      'segmentInputOrientationPolicy': kSegmentInputOrientationPolicy,
      'holdSeconds': holdSeconds,
      'maxFreshnessMs': kMaxFreshnessMs,
      'claimsAllowed': kClaimsAllowed,
      'nonClaims': kNonClaims,
      if (startResult != null) 'nativeStart': startResult,
      if (stopResult != null) 'nativeSummary': stopResult,
      if (errorMessage != null) 'error': errorMessage,
    };

    print('$kSmokeJsonPrefix${jsonEncode(payload)}');
    if (pass) {
      print(kSmokePassMarker);
      _updateStatus(
        'PASS',
        'viewMode=$kViewMode masks=${stopResult?['masks']} '
            'keyedDraws=${stopResult?['keyedDraws']} '
            'maskDebugDraws=${stopResult?['maskDebugDraws']} '
            'droppedBusy=${stopResult?['droppedBusy']} '
            'staleMasks=${stopResult?['staleMasks']}',
      );
    } else {
      print(kSmokeFailMarker);
      _updateStatus('FAIL', errorMessage ?? 'Proof failed');
    }

    await Future<void>.delayed(const Duration(milliseconds: 750));
    exit(pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    final textureId = _textureId;
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (textureId != null)
              // Full-screen presentation of the native composite; aspect
              // ratio preserved (cover), never stretched.
              FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: _outputWidth.toDouble(),
                  height: _outputHeight.toDouble(),
                  child: Texture(textureId: textureId),
                ),
              ),
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Duet green-screen Tasks LIVE_STREAM ($kViewMode, RND)',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Step: $_step',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        'Status: $_status',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                      if (_finished)
                        const Text(
                          'Done — see log markers',
                          style: TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 12,
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
