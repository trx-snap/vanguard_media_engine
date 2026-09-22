// Copyright 2026, Connects. All rights reserved.
// android_ufm_camera_green_screen_filter_physical_smoke.dart
//
// Focused Android physical smoke harness proving the independent UFM camera
// green-screen path via the public Dart API.
//
// Output mode is selected via the ANDROID_UFM_GREENSCREEN_OUTPUT_MODE
// dart-define ('solidColor', the default, or 'alpha'):
//   - solidColor: unchanged behavior — applies
//     VGFilterSpecs.greenScreenSolidColor(argb: parsed argb) and proves mask
//     frames via diagnostics, exactly as before this slice.
//   - alpha: applies VGFilterSpecs.greenScreenAlpha() and asserts
//     getCameraGreenScreenDiagnostics() reports outputMode=='alpha',
//     backgroundType=='alpha', backgroundARGB==null,
//     alphaByteSelfTestPassed==true, alphaEncoding=='straight'. This proves
//     native API acceptance plus a byte-level straight-alpha diagnostic
//     self-test only — no visual transparent-preview claim is made.
//
// solidColor-mode diagnostics proof has two possible routes, matching the
// camera-graph source's backend selection (mirrors the live green-screen
// session's GPU-resident-primary / CPU-compositor-fallback policy):
//   A. GPU-resident route (expected default): getCameraGreenScreenDiagnostics()
//      reports gpuResident==true, segmentationBackend=='raw_tflite_gpu',
//      cameraSourceMode=='camera2_preview_only', camera.analysisEnabled==false,
//      camera.source=='camera2_front_preview_only', cameraStarted==true. There
//      is no CPU pipeline in this route, so getCameraFilterChainDiagnostics()
//      frame counts are not required.
//   B. CPU-compositor fallback route (only if the GPU backend's bootstrap
//      failed on-device): legacy proof via
//      graphFrameCount/maskFrameCount/steadyMaskFrameCount > 0, exactly as
//      before this slice.
//
// Sequence:
//   1. print ANDROID_UFM_GREENSCREEN_PHYSICAL_START
//   2. startCamera with greenScreenLowLatency (front camera: position 2, fps 30);
//      if texture id valid, print ANDROID_UFM_GREENSCREEN_STEP_START_CAMERA_PASS
//   3. During warmup, keep filter cleared/off and show normal camera.
//   4. Apply exactly one filter — solidColor mode:
//      VGFilterSpecs.greenScreenSolidColor(argb: parsed argb); alpha mode:
//      VGFilterSpecs.greenScreenAlpha(). Print
//      ANDROID_UFM_GREENSCREEN_STEP_APPLY_FILTER_PASS
//   5. solidColor mode: poll diagnostics until greenScreenDiagnostics is
//      non-null and either the GPU-resident route (A) or the CPU-fallback
//      frame-count route (B) above is satisfied, or time out after 12
//      seconds. alpha mode: poll until greenScreenDiagnostics is non-null and
//      reports the alpha contract fields above, or time out after 12 seconds.
//      Print ANDROID_UFM_GREENSCREEN_STEP_DIAGNOSTICS_PASS, then for alpha
//      mode also print ANDROID_UFM_GREENSCREEN_ALPHA_DIAGNOSTICS_PASS.
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

const String kDefaultOutputMode = 'solidColor';

const String kOutputMode = String.fromEnvironment(
  'ANDROID_UFM_GREENSCREEN_OUTPUT_MODE',
  defaultValue: kDefaultOutputMode,
);

final bool kIsAlphaMode = kOutputMode == 'alpha';

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

  /// Alpha-mode diagnostics contract asserted from native telemetry only:
  /// outputMode=='alpha', backgroundType=='alpha', backgroundARGB==null,
  /// alphaByteSelfTestPassed==true (native's deterministic byte-level
  /// straight-alpha construction self-test), alphaEncoding=='straight'. This
  /// proves API acceptance and the native self-test only — no Flutter preview
  /// transparency or export/recording alpha claim.
  static bool _alphaDiagnosticsSatisfied(Map<String, dynamic>? gsDiag) {
    if (gsDiag == null) return false;
    return gsDiag['outputMode'] == 'alpha' &&
        gsDiag['backgroundType'] == 'alpha' &&
        gsDiag['backgroundARGB'] == null &&
        gsDiag['alphaByteSelfTestPassed'] == true &&
        gsDiag['alphaEncoding'] == 'straight';
  }

  /// GPU-resident route (A): the camera-graph source's backend-selection
  /// policy (mirrors AndroidLiveGreenScreenSessionCoordinator) defaults to
  /// AndroidGreenScreenGpuResidentPreviewBackend, which performs
  /// segmentation inside its own frame transaction — there is no CPU
  /// clean-segmentation pipeline or ImageReader in this route, so this
  /// checks the camera-graph diagnostics fields the native side reports for
  /// it rather than any frame counter.
  static bool _gpuResidentRouteSatisfied(Map<String, dynamic>? gsDiag) {
    if (gsDiag == null) return false;
    final camera = gsDiag['camera'];
    final cameraMap = camera is Map
        ? camera.map((k, v) => MapEntry(k.toString(), v))
        : null;
    return gsDiag['gpuResident'] == true &&
        gsDiag['segmentationBackend'] == 'raw_tflite_gpu' &&
        gsDiag['cameraSourceMode'] == 'camera2_preview_only' &&
        gsDiag['cameraStarted'] == true &&
        cameraMap != null &&
        cameraMap['analysisEnabled'] == false &&
        cameraMap['source'] == 'camera2_front_preview_only';
  }

  /// CPU-compositor fallback route (B): only reachable if the GPU-resident
  /// backend's bootstrap failed on-device, in which case the camera-graph
  /// source runs the same production CPU clean-segmentation pipeline as
  /// before this slice.
  static bool _cpuFallbackRouteSatisfied(
    Map<String, dynamic>? gsDiag,
    Map<String, dynamic>? fcDiag,
  ) {
    return _extractGraphFrameCount(fcDiag) > 0 ||
        _extractMaskFrameCount(gsDiag) > 0 ||
        _extractSteadyMaskFrameCount(gsDiag) > 0;
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

      // 4. Apply exactly one filter — solidColor mode:
      // VGFilterSpecs.greenScreenSolidColor(argb: parsed argb); alpha mode:
      // VGFilterSpecs.greenScreenAlpha().
      _updatePhase('APPLY_FILTER');
      await VanguardEngine.setCameraFilterChain(<VGFilterSpec>[
        if (kIsAlphaMode)
          VGFilterSpecs.greenScreenAlpha()
        else
          VGFilterSpecs.greenScreenSolidColor(argb: kParsedArgb),
      ]);
      print('ANDROID_UFM_GREENSCREEN_STEP_APPLY_FILTER_PASS');

      // 5. solidColor mode: poll diagnostics until both greenScreenDiagnostics
      // and filterChainDiagnostics are non-null and graphFrameCount or
      // maskFrameCount/steadyMaskFrameCount is > 0, or time out after 12
      // seconds. alpha mode: poll until greenScreenDiagnostics reports the
      // alpha contract (outputMode/backgroundType/backgroundARGB/
      // alphaByteSelfTestPassed/alphaEncoding), or time out after 12 seconds.
      _updatePhase('POLL_DIAGNOSTICS');
      final pollDeadline = DateTime.now().add(const Duration(seconds: 12));
      var diagSatisfied = false;
      var alphaDiagSatisfied = false;

      while (DateTime.now().isBefore(pollDeadline)) {
        final gs = await VanguardEngine.getCameraGreenScreenDiagnostics();
        final fc = await VanguardEngine.getCameraFilterChainDiagnostics();
        if (gs != null) {
          lastGsDiag = gs;
          if (fc != null) lastFcDiag = fc;
          _updateDiagnostics(gs, fc);

          if (kIsAlphaMode) {
            if (_alphaDiagnosticsSatisfied(gs)) {
              diagSatisfied = true;
              alphaDiagSatisfied = true;
              break;
            }
          } else {
            // Route A (GPU-resident, no CPU pipeline/frame counts to wait on)
            // or route B (CPU-compositor fallback frame counters).
            if (_gpuResidentRouteSatisfied(gs) ||
                _cpuFallbackRouteSatisfied(gs, fc)) {
              diagSatisfied = true;
              break;
            }
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      if (!diagSatisfied) {
        throw TimeoutException(
          kIsAlphaMode
              ? 'Timed out after 12s waiting for alpha green-screen diagnostics contract: '
                    'gsDiag=${lastGsDiag != null} (outputMode=${lastGsDiag?['outputMode']}, '
                    'backgroundType=${lastGsDiag?['backgroundType']}, '
                    'backgroundARGB=${lastGsDiag?['backgroundARGB']}, '
                    'alphaByteSelfTestPassed=${lastGsDiag?['alphaByteSelfTestPassed']}, '
                    'alphaEncoding=${lastGsDiag?['alphaEncoding']})'
              : 'Timed out after 12s waiting for green-screen diagnostics on either the '
                    'GPU-resident route (gpuResident=${lastGsDiag?['gpuResident']}, '
                    'segmentationBackend=${lastGsDiag?['segmentationBackend']}, '
                    'cameraSourceMode=${lastGsDiag?['cameraSourceMode']}, '
                    'cameraStarted=${lastGsDiag?['cameraStarted']}) or the CPU-fallback frame-count '
                    'route: gsDiag=${lastGsDiag != null}, fcDiag=${lastFcDiag != null}',
        );
      }
      print('ANDROID_UFM_GREENSCREEN_STEP_DIAGNOSTICS_PASS');
      if (alphaDiagSatisfied) {
        print('ANDROID_UFM_GREENSCREEN_ALPHA_DIAGNOSTICS_PASS');
      }

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
      final gpuRouteProven =
          !kIsAlphaMode && _gpuResidentRouteSatisfied(lastGsDiag);
      final cpuFallbackProven =
          !kIsAlphaMode && _cpuFallbackRouteSatisfied(lastGsDiag, lastFcDiag);

      final jsonPayload = <String, dynamic>{
        'pass': pass,
        'textureId': textureId,
        'captureProfile': 'greenScreenLowLatency',
        'position': 2,
        'fps': 30,
        'outputMode': kOutputMode,
        if (!kIsAlphaMode) 'argb': kParsedArgb,
        'warmupSeconds': kWarmupSeconds,
        'holdSeconds': kHoldSeconds,
        if (!kIsAlphaMode) 'gpuResidentRouteProven': gpuRouteProven,
        if (!kIsAlphaMode) 'cpuFallbackRouteProven': cpuFallbackProven,
        'claimsAllowed': kIsAlphaMode
            ? <String>[
                'public UFM capture profile selected Android green-screen graph path',
                'VGFilterSpecs.greenScreenAlpha() was accepted by setCameraFilterChain '
                    '(not UNSUPPORTED_FILTER_TYPE)',
                'native telemetry reports outputMode==alpha, backgroundType==alpha, '
                    'backgroundARGB==null, alphaEncoding==straight',
                'native alphaByteSelfTestPassed==true: a deterministic Kotlin byte-level '
                    'self-test proved straight-alpha pixel construction (foreground RGB '
                    'unchanged, alpha equals mask, across transparent/edge/opaque cases)',
                'filter clear returns diagnostics to null',
              ]
            : <String>[
                'public UFM capture profile selected Android green-screen graph path',
                'solid-color green-screen filter activated through setCameraFilterChain',
                'preview texture was shown for manual observation',
                if (gpuRouteProven)
                  'native diagnostics proved the GPU-resident route: gpuResident==true, '
                      'segmentationBackend==raw_tflite_gpu, '
                      'cameraSourceMode==camera2_preview_only, '
                      'camera.analysisEnabled==false, '
                      'camera.source==camera2_front_preview_only, cameraStarted==true',
                if (cpuFallbackProven)
                  'native diagnostics proved mask frames via the CPU-compositor '
                      'fallback route (graphFrameCount/maskFrameCount/'
                      'steadyMaskFrameCount > 0)',
                'filter clear returns diagnostics to null',
              ],
        'nonClaims': kIsAlphaMode
            ? <String>[
                'alpha mode proves native API acceptance plus a byte-level straight-alpha '
                    'diagnostic self-test only',
                'no visual transparent-preview claim: the Flutter Texture composites the '
                    'frame with its own alpha interpretation',
                'no export/recording alpha proof',
                'no Duet/beauty/app wiring claim',
                'no automated pixel-quality proof of the live camera matte',
              ]
            : <String>[
                'no automated pixel-quality proof',
                'no beauty filter',
                'no export/recording',
                'no Duet',
                if (gpuRouteProven && !cpuFallbackProven)
                  'no CPU clean-segmentation pipeline proof: the GPU-resident '
                      'backend never opens one on this route',
                if (cpuFallbackProven && !gpuRouteProven)
                  'no GPU-resident backend proof: this run used the CPU-compositor '
                      'fallback route',
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
