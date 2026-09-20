// Copyright 2026, Connects. All rights reserved.
// android_ufm_camera_green_screen_filter_physical_smoke.dart
//
// Focused Android physical smoke harness proving the independent UFM camera
// green-screen path via the public Dart API.
//
// Sequence:
//   1. print ANDROID_UFM_GREENSCREEN_PHYSICAL_START
//   2. startCamera with greenScreenLowLatency (front camera: position 2, fps 30);
//      if texture id valid, print ANDROID_UFM_GREENSCREEN_STEP_START_CAMERA_PASS
//   3. During warmup, keep filter cleared/off and show normal camera.
//   4. Apply exactly one filter: VGFilterSpecs.greenScreenSolidColor(argb: parsed argb).
//      Print ANDROID_UFM_GREENSCREEN_STEP_APPLY_FILTER_PASS
//   5. Poll diagnostics until both greenScreenDiagnostics and filterChainDiagnostics
//      are non-null and graphFrameCount or maskFrameCount/steadyMaskFrameCount is > 0,
//      or time out after 12 seconds. Print ANDROID_UFM_GREENSCREEN_STEP_DIAGNOSTICS_PASS
//   6. Hold visual for hold seconds while periodically refreshing diagnostics.
//   7. Clear filters with setCameraFilterChain([]). Assert both diagnostics return
//      null within a short bounded wait; print ANDROID_UFM_GREENSCREEN_STEP_CLEAR_FILTERS_PASS
//   8. stopCamera in finally. Print ANDROID_UFM_GREENSCREEN_STEP_STOP_CAMERA_PASS if stop succeeds.
//   9. Print one single-line JSON marker ANDROID_UFM_GREENSCREEN_JSON:<json>.
//      Then print ANDROID_UFM_GREENSCREEN_PHYSICAL_PASS or ANDROID_UFM_GREENSCREEN_PHYSICAL_FAIL.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const int kDefaultHoldSeconds = 15;
const int kDefaultWarmupSeconds = 2;
const int kDefaultArgb = 0xFF00796B;

const int kHoldSeconds = int.fromEnvironment(
  'ANDROID_UFM_GREENSCREEN_HOLD_SECONDS',
  defaultValue: kDefaultHoldSeconds,
);

const int kWarmupSeconds = int.fromEnvironment(
  'ANDROID_UFM_GREENSCREEN_WARMUP_SECONDS',
  defaultValue: kDefaultWarmupSeconds,
);

const bool kHideOverlay = bool.fromEnvironment(
  'ANDROID_UFM_GREENSCREEN_HIDE_OVERLAY',
  defaultValue: false,
);

int _resolveArgb() {
  const String raw = String.fromEnvironment(
    'ANDROID_UFM_GREENSCREEN_ARGB',
    defaultValue: '',
  );
  if (raw.isNotEmpty) {
    final parsed = int.tryParse(raw);
    if (parsed != null) return parsed;
  }
  return const int.fromEnvironment(
    'ANDROID_UFM_GREENSCREEN_ARGB',
    defaultValue: kDefaultArgb,
  );
}

final int kParsedArgb = _resolveArgb();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidUfmCameraGreenScreenFilterPhysicalSmokeApp());
}

class AndroidUfmCameraGreenScreenFilterPhysicalSmokeApp extends StatefulWidget {
  const AndroidUfmCameraGreenScreenFilterPhysicalSmokeApp({super.key});

  @override
  State<AndroidUfmCameraGreenScreenFilterPhysicalSmokeApp> createState() =>
      _AndroidUfmCameraGreenScreenFilterPhysicalSmokeAppState();
}

class _AndroidUfmCameraGreenScreenFilterPhysicalSmokeAppState
    extends State<AndroidUfmCameraGreenScreenFilterPhysicalSmokeApp> {
  int? _textureId;
  String _phase = 'INIT';
  bool _isPassed = false;
  bool _isFailed = false;
  String? _errorMessage;
  final Stopwatch _stopwatch = Stopwatch();

  int _textureWidth = 720;
  int _textureHeight = 1280;

  int _graphFrameCount = 0;
  int _maskFrameCount = 0;
  int _steadyMaskFrameCount = 0;
  double? _meanLatencyMs;
  double? _maxLatencyMs;

  @override
  void initState() {
    super.initState();
    _stopwatch.start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  void _updatePhase(String phase) {
    if (mounted) {
      setState(() {
        _phase = phase;
      });
    }
  }

  void _updateDiagnostics(
    Map<String, dynamic>? gsDiag,
    Map<String, dynamic>? fcDiag,
  ) {
    final gCount = _extractGraphFrameCount(fcDiag);
    final mCount = _extractMaskFrameCount(gsDiag);
    final sCount = _extractSteadyMaskFrameCount(gsDiag);
    final mean = _extractMeanLatency(fcDiag, gsDiag);
    final max = _extractMaxLatency(fcDiag, gsDiag);

    int? w;
    int? h;
    if (gsDiag != null) {
      final widthVal = gsDiag['widthPx'];
      final heightVal = gsDiag['heightPx'];
      if (widthVal is num &&
          heightVal is num &&
          widthVal > 0 &&
          heightVal > 0) {
        w = widthVal.toInt();
        h = heightVal.toInt();
      }
    }

    if (mounted) {
      setState(() {
        _graphFrameCount = gCount;
        _maskFrameCount = mCount;
        _steadyMaskFrameCount = sCount;
        _meanLatencyMs = mean;
        _maxLatencyMs = max;
        if (w != null && h != null) {
          _textureWidth = w;
          _textureHeight = h;
        }
      });
    }
  }

  static int _extractGraphFrameCount(Map<String, dynamic>? fcDiag) {
    if (fcDiag == null) return 0;
    final val = fcDiag['graphFrameCount'];
    return val is num ? val.toInt() : 0;
  }

  static Map<String, dynamic>? _extractPipeline(Map<String, dynamic>? gsDiag) {
    if (gsDiag == null) return null;
    final camera = gsDiag['camera'];
    if (camera is Map) {
      final pipeline = camera['pipeline'];
      if (pipeline is Map) {
        return pipeline.map((k, v) => MapEntry(k.toString(), v));
      }
    }
    return null;
  }

  static int _extractMaskFrameCount(Map<String, dynamic>? gsDiag) {
    final pipeline = _extractPipeline(gsDiag);
    if (pipeline == null) return 0;
    final val = pipeline['maskFrameCount'];
    return val is num ? val.toInt() : 0;
  }

  static int _extractSteadyMaskFrameCount(Map<String, dynamic>? gsDiag) {
    final pipeline = _extractPipeline(gsDiag);
    if (pipeline == null) return 0;
    final val = pipeline['steadyMaskFrameCount'];
    return val is num ? val.toInt() : 0;
  }

  static double? _extractMeanLatency(
    Map<String, dynamic>? fcDiag,
    Map<String, dynamic>? gsDiag,
  ) {
    if (fcDiag != null) {
      final mean = fcDiag['meanGraphTotalMs'];
      if (mean is num && mean > 0) return mean.toDouble();
    }
    final pipeline = _extractPipeline(gsDiag);
    if (pipeline != null) {
      final steady = pipeline['meanSteadyMaskLatencyMs'];
      if (steady is num && steady > 0) return steady.toDouble();
      final mean = pipeline['meanMaskLatencyMs'];
      if (mean is num && mean > 0) return mean.toDouble();
    }
    return null;
  }

  static double? _extractMaxLatency(
    Map<String, dynamic>? fcDiag,
    Map<String, dynamic>? gsDiag,
  ) {
    if (fcDiag != null) {
      final max = fcDiag['maxGraphTotalMs'];
      if (max is num && max > 0) return max.toDouble();
    }
    final pipeline = _extractPipeline(gsDiag);
    if (pipeline != null) {
      final steady = pipeline['maxSteadyMaskLatencyMs'];
      if (steady is num && steady > 0) return steady.toDouble();
      final max = pipeline['maxMaskLatencyMs'];
      if (max is num && max > 0) return max.toDouble();
    }
    return null;
  }

  Future<void> _runSmoke() async {
    var pass = false;
    String? errorMessage;
    StackTrace? errorStack;
    int? textureId;
    Map<String, dynamic>? lastGsDiag;
    Map<String, dynamic>? lastFcDiag;

    try {
      // 1. print start
      print('ANDROID_UFM_GREENSCREEN_PHYSICAL_START');

      // 2. startCamera with greenScreenLowLatency (front camera: position 2, fps 30)
      _updatePhase('START_CAMERA');
      textureId = await VanguardEngine.startCamera(
        position: 2,
        fps: 30,
        captureProfile: VanguardCameraCaptureProfile.greenScreenLowLatency,
      );

      if (textureId < 0) {
        throw StateError('startCamera returned invalid texture id: $textureId');
      }

      if (mounted) {
        setState(() {
          _textureId = textureId;
        });
      }

      print('ANDROID_UFM_GREENSCREEN_STEP_START_CAMERA_PASS');

      // 3. During warmup, keep filter cleared/off and show normal camera.
      // Do not assert green diagnostics before applying filter.
      _updatePhase('WARMUP');
      final warmupDeadline = DateTime.now().add(
        Duration(seconds: kWarmupSeconds),
      );
      while (DateTime.now().isBefore(warmupDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (mounted) setState(() {});
      }

      // 4. Apply exactly one filter: VGFilterSpecs.greenScreenSolidColor(argb: parsed argb)
      _updatePhase('APPLY_FILTER');
      await VanguardEngine.setCameraFilterChain(<VGFilterSpec>[
        VGFilterSpecs.greenScreenSolidColor(argb: kParsedArgb),
      ]);
      print('ANDROID_UFM_GREENSCREEN_STEP_APPLY_FILTER_PASS');

      // 5. Poll diagnostics until both greenScreenDiagnostics and filterChainDiagnostics
      // are non-null and graphFrameCount or maskFrameCount/steadyMaskFrameCount is > 0,
      // or time out after 12 seconds.
      _updatePhase('POLL_DIAGNOSTICS');
      final pollDeadline = DateTime.now().add(const Duration(seconds: 12));
      var diagSatisfied = false;

      while (DateTime.now().isBefore(pollDeadline)) {
        final gs = await VanguardEngine.getCameraGreenScreenDiagnostics();
        final fc = await VanguardEngine.getCameraFilterChainDiagnostics();
        if (gs != null && fc != null) {
          lastGsDiag = gs;
          lastFcDiag = fc;
          _updateDiagnostics(gs, fc);

          final gCount = _extractGraphFrameCount(fc);
          final mCount = _extractMaskFrameCount(gs);
          final sCount = _extractSteadyMaskFrameCount(gs);

          if (gCount > 0 || mCount > 0 || sCount > 0) {
            diagSatisfied = true;
            break;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      if (!diagSatisfied) {
        throw TimeoutException(
          'Timed out after 12s waiting for green-screen diagnostics with frame count > 0: '
          'gsDiag=${lastGsDiag != null}, fcDiag=${lastFcDiag != null}',
        );
      }
      print('ANDROID_UFM_GREENSCREEN_STEP_DIAGNOSTICS_PASS');

      // 6. Hold visual for hold seconds while periodically refreshing diagnostics.
      _updatePhase('HOLD_VISUAL');
      final holdDeadline = DateTime.now().add(Duration(seconds: kHoldSeconds));
      while (DateTime.now().isBefore(holdDeadline)) {
        final gs = await VanguardEngine.getCameraGreenScreenDiagnostics();
        final fc = await VanguardEngine.getCameraFilterChainDiagnostics();
        if (gs != null) lastGsDiag = gs;
        if (fc != null) lastFcDiag = fc;
        _updateDiagnostics(lastGsDiag, lastFcDiag);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      // 7. Clear filters with setCameraFilterChain([]).
      // Assert both diagnostics return null within a short bounded wait.
      _updatePhase('CLEAR_FILTERS');
      await VanguardEngine.setCameraFilterChain(<VGFilterSpec>[]);
      final clearDeadline = DateTime.now().add(const Duration(seconds: 5));
      var cleared = false;
      while (DateTime.now().isBefore(clearDeadline)) {
        final gs = await VanguardEngine.getCameraGreenScreenDiagnostics();
        final fc = await VanguardEngine.getCameraFilterChainDiagnostics();
        if (gs == null && fc == null) {
          cleared = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      if (!cleared) {
        throw StateError(
          'Diagnostics did not return null within 5s after clearing filter chain',
        );
      }
      print('ANDROID_UFM_GREENSCREEN_STEP_CLEAR_FILTERS_PASS');

      pass = true;
      _updatePhase('PASS');
    } catch (error, stack) {
      pass = false;
      errorMessage = error.toString();
      errorStack = stack;
      _updatePhase('FAIL: $errorMessage');
    } finally {
      // 8. stopCamera in finally. Print ANDROID_UFM_GREENSCREEN_STEP_STOP_CAMERA_PASS if stop succeeds.
      try {
        await VanguardEngine.stopCamera();
        print('ANDROID_UFM_GREENSCREEN_STEP_STOP_CAMERA_PASS');
      } catch (stopError, stopStack) {
        pass = false;
        errorMessage ??= 'stopCamera failed: $stopError';
        errorStack ??= stopStack;
      }

      if (mounted) {
        setState(() {
          _isPassed = pass;
          _isFailed = !pass;
          _errorMessage = errorMessage;
        });
      }

      // 9. Single-line JSON marker and PASS/FAIL marker
      final jsonPayload = <String, dynamic>{
        'pass': pass,
        'textureId': textureId,
        'captureProfile': 'greenScreenLowLatency',
        'position': 2,
        'fps': 30,
        'argb': kParsedArgb,
        'warmupSeconds': kWarmupSeconds,
        'holdSeconds': kHoldSeconds,
        'claimsAllowed': <String>[
          'public UFM capture profile selected Android green-screen graph path',
          'solid-color green-screen filter activated through setCameraFilterChain',
          'preview texture was shown for manual observation',
          'native diagnostics proved mask frames',
          'filter clear returns diagnostics to null',
        ],
        'nonClaims': <String>[
          'no automated pixel-quality proof',
          'no beauty filter',
          'no alpha output',
          'no export/recording',
          'no Duet',
        ],
        'greenScreenDiagnostics': ?lastGsDiag,
        'filterChainDiagnostics': ?lastFcDiag,
        'error': ?errorMessage,
        if (errorStack != null) 'stackTrace': errorStack.toString(),
      };

      print('ANDROID_UFM_GREENSCREEN_JSON:${jsonEncode(jsonPayload)}');
      print(
        pass
            ? 'ANDROID_UFM_GREENSCREEN_PHYSICAL_PASS'
            : 'ANDROID_UFM_GREENSCREEN_PHYSICAL_FAIL',
      );

      // Auto-exit after short delay to allow logs to flush
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(pass ? 0 : 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Full-screen texture with BoxFit.cover
            if (_textureId != null)
              SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _textureWidth.toDouble(),
                    height: _textureHeight.toDouble(),
                    child: Texture(textureId: _textureId!),
                  ),
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),

            // Minimal top-positioned overlay
            if (!kHideOverlay)
              SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _isFailed
                            ? Colors.redAccent
                            : (_isPassed ? Colors.greenAccent : Colors.white24),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Android UFM Green Screen Physical Smoke',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Texture: ${_textureId ?? "none"}  |  Phase: $_phase  |  Elapsed: ${_stopwatch.elapsed.inSeconds}s',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          'Frames (graph/mask/steady): $_graphFrameCount / $_maskFrameCount / $_steadyMaskFrameCount',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          'Latency (mean/max): '
                          '${_meanLatencyMs != null ? "${_meanLatencyMs!.toStringAsFixed(1)}ms" : "N/A"} / '
                          '${_maxLatencyMs != null ? "${_maxLatencyMs!.toStringAsFixed(1)}ms" : "N/A"}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                        if (_errorMessage != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            'Error: $_errorMessage',
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 11,
                            ),
                          ),
                        ],
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
