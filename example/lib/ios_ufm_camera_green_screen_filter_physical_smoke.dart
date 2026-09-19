// Copyright 2026, Connects. All rights reserved.
// ios_ufm_camera_green_screen_filter_physical_smoke.dart
//
// iOS physical smoke harness proving the new UFM camera graph greenScreen filter
// route is accepted, the S1-refined node is invoked by the active camera graph
// and actually keys frames (proved through native telemetry, not log
// visibility), and does NOT use standalone live green-screen, ARKit, or Duet paths.
//
// Optional Beauty V2 + greenScreen combined physical proof mode:
//   Set UFM_ENABLE_BEAUTY_V2=true to apply the combined chain:
//     [VGFilterSpecs.beauty(beautyVersion: 2, intensity: 0.5),
//      VGFilterSpecs.greenScreenSolidColor(argb: 0xFF00796B)]
//   Proves sequential co-execution in active camera graph and combined-chain
//   throughput (steadyProcessedFps >= 20.0 across steady frames >= 50).
//   Green-screen node telemetry measures greenScreen node time only, not
//   Beauty V2 per-node or cumulative latency.
//
// Harness proof lanes:
//   1. Start active UFM camera with VanguardEngine.startCamera(position: 2, fps: 30,
//      captureProfile: <UFM_CAMERA_CAPTURE_PROFILE>, sessionPreset: <UFM_CAMERA_PRESET>).
//      Production path by default: UFM_CAMERA_CAPTURE_PROFILE defaults to
//      greenScreenLowLatency (iOS: iFrame960x540 then 720p, chosen at start-camera
//      time, fixed for the session). Set UFM_CAMERA_CAPTURE_PROFILE=defaultQuality to
//      exercise the 1080p-first baseline. UFM_CAMERA_PRESET (raw AVCapture preset
//      string) remains the explicit A/B override; when non-empty it wins and the
//      profile is not sent (Dart-side precedence in VanguardEngine.startCamera).
//   2. Display the returned Texture(textureId: ...) full-screen with status overlay.
//   3. Observe baseline camera for 3 seconds.
//   4. Apply filter chain:
//      - If UFM_ENABLE_BEAUTY_V2=true:
//        VanguardEngine.setCameraFilterChain([
//          VGFilterSpecs.beauty(beautyVersion: 2, intensity: 0.5),
//          VGFilterSpecs.greenScreenSolidColor(argb: 0xFF00796B),
//        ])
//      - If UFM_ENABLE_BEAUTY_V2=false:
//        VanguardEngine.setCameraFilterChain([
//          VGFilterSpecs.greenScreenSolidColor(argb: 0xFF00796B),
//        ])
//   5. Observe keyed solid-color green screen for 10 seconds. Overlay clearly indicates
//      the active filter mode (greenScreen only or Beauty V2 + greenScreen),
//      not standalone live green-screen API.
//      After a bounded settle period, read the native telemetry snapshot with
//      VanguardEngine.getCameraGreenScreenDiagnostics() and assert:
//        non-null, proofLevel == 'S1', matteSource == 'visionPersonFast',
//        backgroundARGB == 0xFF00796B, processedFrameCount > 0,
//        morphologyCloseApplied / featherApplied / trimapApplied /
//        guidedEdgeApplied / allS1StagesApplied all true,
//        allS1StagesAppliedFrameCount > 0.
//      Steady window & throughput:
//        Computes steadyWindowSeconds from actual time between warmup and final
//        diagnostics, and steadyProcessedFps = steadyFrameCount / steadyWindowSeconds.
//        For Beauty V2 mode: asserts steadyProcessedFps >= 20.0, steadyFrameCount >= 50,
//        source long side < 1920, and existing greenScreen S1 flags.
//      Warmup-excluded latency reporting:
//        Reconstructs steady-state latency across steady frames (steadyFrameCount >= 50)
//        excluding the warmup settle period:
//          warmupExcludedMeanTotalMs, warmupExcludedMeanVisionMs, warmupExcludedMeanBlendRenderMs.
//        For non-Beauty mode: asserts total < 50ms, vision < 40ms, blend < 30ms.
//        Samples lastTotalMs 5 times across the active steady window.
//      Objective pixel metrics:
//        Samples pixels from the isolated video Texture RepaintBoundary against expected
//        solid teal (0, 121, 107).
//        In non-Beauty mode, asserts backgroundCoveragePct >= 15.0% and edgeTransitionRatioPct > 0.05%.
//        If pixel capture is unavailable, records fallback without failing.
//   6. Clear filters with VanguardEngine.setCameraFilterChain([]). Assert
//      getCameraGreenScreenDiagnostics() now returns null (no stale node
//      state). Observe passthrough camera for 3 seconds.
//   7. Stop camera in cleanup/dispose.
//
// Claims allowed:
//   - active UFM camera starts
//   - When Beauty V2 enabled: combined Beauty V2 + greenScreen filter chain accepted and co-executes
//   - When Beauty V2 enabled: combined-chain throughput/co-execution proven via steady processed FPS (>= 20.0 fps across steady frames >= 50)
//   - When greenScreen only: greenScreen filter route is accepted and S1-refined node is invoked by the active camera graph
//   - When greenScreen only: warmup-excluded latency reporting (steadyFrameCount >= 50, total < 50ms, vision < 40ms, blend < 30ms)
//   - native S1 stage telemetry proof is available and asserted (getCameraGreenScreenDiagnostics)
//   - objective pixel metrics sampled from active video texture
//   - same texture remains mounted
//   - clear returns to passthrough (native telemetry returns null after clear)
//   - startCamera captureProfile is a fixed start-time capture decision (greenScreenLowLatency asserts source long side < 1920 when no preset override)
//   - cleanup stops camera
//
// Non-claims:
//   - TikTok visual quality
//   - temporal smoothing
//   - image/video backgrounds
//   - recording/export/photo
//   - Duet
//   - Android
//   - native cumulative latency across combined chain (green-screen node telemetry excludes Beauty V2 per-node cost)

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String kSmokeStartMarker = 'IOS_UFM_GREENSCREEN_FILTER_SMOKE_START';
const String kStepCameraStartedMarker =
    'IOS_UFM_GREENSCREEN_FILTER_STEP_CAMERA_STARTED';
const String kStepBaselineObservedMarker =
    'IOS_UFM_GREENSCREEN_FILTER_STEP_BASELINE_OBSERVED';
const String kStepFilterAppliedMarker =
    'IOS_UFM_GREENSCREEN_FILTER_STEP_FILTER_APPLIED';
const String kStepDiagnosticsAssertedMarker =
    'IOS_UFM_GREENSCREEN_FILTER_STEP_DIAGNOSTICS_ASSERTED';
const String kStepWarmupSettledMarker =
    'IOS_UFM_GREENSCREEN_FILTER_STEP_WARMUP_SETTLED';
const String kStepSteadySampledMarker =
    'IOS_UFM_GREENSCREEN_FILTER_STEP_STEADY_SAMPLED';
const String kStepFrameCapturedMarker =
    'IOS_UFM_GREENSCREEN_FILTER_STEP_FRAME_CAPTURED';
const String kMetricsJsonMarker = 'IOS_UFM_GREENSCREEN_METRICS_JSON';
const String kStepFilterClearedMarker =
    'IOS_UFM_GREENSCREEN_FILTER_STEP_FILTER_CLEARED';
const String kStepDiagnosticsClearedMarker =
    'IOS_UFM_GREENSCREEN_FILTER_STEP_DIAGNOSTICS_CLEARED';
const String kStepCameraStoppedMarker =
    'IOS_UFM_GREENSCREEN_FILTER_STEP_CAMERA_STOPPED';
const String kSmokePassMarker = 'IOS_UFM_GREENSCREEN_FILTER_PASS';
const String kSmokeFailMarker = 'IOS_UFM_GREENSCREEN_FILTER_FAIL';

/// When true, exercises combined Beauty V2 + greenScreen filter proof mode.
/// When false (default), exercises greenScreen-only proof mode.
const bool kUfmEnableBeautyV2 = bool.fromEnvironment(
  'UFM_ENABLE_BEAUTY_V2',
  defaultValue: false,
);

const String kUfmCameraPreset = String.fromEnvironment(
  'UFM_CAMERA_PRESET',
  defaultValue: '',
);

/// Production capture profile selected at startCamera time. Defaults to the
/// low-latency green-screen profile so the harness proves the production path;
/// 'defaultQuality' exercises the 1080p-first baseline for A/B.
const String kUfmCameraCaptureProfile = String.fromEnvironment(
  'UFM_CAMERA_CAPTURE_PROFILE',
  defaultValue: 'greenScreenLowLatency',
);

/// Maps the dart-define string to the public enum. Fails closed on unknown
/// values so a typo never silently runs the wrong profile.
VanguardCameraCaptureProfile _resolveCaptureProfile(String raw) {
  switch (raw.trim()) {
    case 'greenScreenLowLatency':
      return VanguardCameraCaptureProfile.greenScreenLowLatency;
    case 'defaultQuality':
      return VanguardCameraCaptureProfile.defaultQuality;
    default:
      throw StateError(
        '[CONFIG] Unknown UFM_CAMERA_CAPTURE_PROFILE "$raw" '
        '(expected greenScreenLowLatency or defaultQuality)',
      );
  }
}

/// Long side of the 1080p-first default capture. When the effective path is
/// the greenScreenLowLatency profile (no UFM_CAMERA_PRESET override), native
/// telemetry must report a source strictly smaller than this on its long side
/// (540x960 when iFrame960x540 is supported, 720x1280 on the 720p fallback).
const int kDefaultQualityLongSidePx = 1920;

List<String> get kClaimsAllowed => <String>[
  'active UFM camera starts',
  if (kUfmEnableBeautyV2) ...<String>[
    'combined Beauty V2 + greenScreen filter chain is accepted and co-executes in active camera graph',
    'combined-chain throughput/co-execution proven via steady processed FPS (>= 20.0 fps across steady frames >= 50)',
  ] else ...<String>[
    'greenScreen filter route is accepted and S1-refined node is invoked by the active camera graph',
    'warmup-excluded latency reporting (steadyFrameCount >= 50, total < 50ms, vision < 40ms, blend < 30ms)',
  ],
  'native S1 stage telemetry proof is available and asserted (getCameraGreenScreenDiagnostics)',
  'objective pixel metrics sampled from active video texture',
  'same texture remains mounted',
  'clear returns to passthrough (native telemetry returns null after clear)',
  'startCamera captureProfile is a fixed start-time capture decision (greenScreenLowLatency asserts source long side < 1920 when no preset override)',
  'cleanup stops camera',
];

List<String> get kNonClaims => const <String>[
  'TikTok visual quality',
  'temporal smoothing',
  'image/video backgrounds',
  'recording/export/photo',
  'Duet',
  'Android',
  'native cumulative latency across combined chain',
  'green-screen node telemetry excludes Beauty V2 per-node cost',
];

/// Background applied through VGFilterSpecs.greenScreenSolidColor and asserted
/// back from the native telemetry snapshot (backgroundARGB).
const int kExpectedBackgroundARGB = 0xFF00796B;
const int kExpectedBgR = 0;
const int kExpectedBgG = 121;
const int kExpectedBgB = 107;

/// Total keyed-output observe window (lane 5).
const Duration kGreenScreenObserveDuration = Duration(seconds: 10);

/// Bounded settle period after the filter is applied before the first native
/// telemetry read; the graph needs a few frames through the S1 path.
const Duration kDiagnosticsSettleDelay = Duration(seconds: 3);

/// Bounded poll for the first snapshot with processedFrameCount > 0. The
/// assertions run on whichever snapshot the poll ends with, so a device that
/// never keys a frame still fails loudly rather than hanging.
const int kDiagnosticsPollAttempts = 5;
const Duration kDiagnosticsPollInterval = Duration(seconds: 1);

/// Stride used when sampling pixels across the RepaintBoundary image.
const int kPixelSampleStride = 4;

int _asInt(Object? value) => value is num ? value.toInt() : -1;

double _asDouble(Object? value) => value is num ? value.toDouble() : 0.0;

String _fmtMs(Object? value) => value is num ? value.toStringAsFixed(1) : '?';

/// Computes the warmup-excluded mean for [metricKey] between [snapshot1] and
/// [snapshot2] by reconstructing sums as (mean * count) and dividing delta sum
/// by delta frame count. Returns null if delta frame count <= 0.
double? _computeWarmupExcludedMean({
  required Map<String, dynamic> snapshot1,
  required Map<String, dynamic> snapshot2,
  required String metricKey,
}) {
  final n1 = _asInt(snapshot1['processedFrameCount']);
  final n2 = _asInt(snapshot2['processedFrameCount']);
  final deltaN = n2 - n1;
  if (n1 < 0 || n2 < 0 || deltaN <= 0) {
    return null;
  }
  final mean1 = _asDouble(snapshot1[metricKey]);
  final mean2 = _asDouble(snapshot2[metricKey]);
  final sum1 = mean1 * n1;
  final sum2 = mean2 * n2;
  final deltaSum = sum2 - sum1;
  final result = deltaSum / deltaN;
  return result >= 0.0 ? double.parse(result.toStringAsFixed(3)) : 0.0;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IosUfmCameraGreenScreenFilterPhysicalSmokeApp());
}

class IosUfmCameraGreenScreenFilterPhysicalSmokeApp extends StatefulWidget {
  const IosUfmCameraGreenScreenFilterPhysicalSmokeApp({super.key});

  @override
  State<IosUfmCameraGreenScreenFilterPhysicalSmokeApp> createState() =>
      _IosUfmCameraGreenScreenFilterPhysicalSmokeAppState();
}

class _IosUfmCameraGreenScreenFilterPhysicalSmokeAppState
    extends State<IosUfmCameraGreenScreenFilterPhysicalSmokeApp> {
  final GlobalKey _previewKey = GlobalKey();
  int? _textureId;
  String _currentStep = 'INIT';
  String _status = 'Initializing harness...';
  String _cameraModeDescription = 'Initializing';
  bool _isGreenScreenActive = false;
  bool _isPassed = false;
  bool _isFailed = false;
  bool _cameraActive = false;
  String _diagnosticsSummary = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  @override
  void dispose() {
    if (_cameraActive) {
      _cameraActive = false;
      VanguardEngine.stopCamera().catchError((Object _) {});
    }
    super.dispose();
  }

  void _updateStatus(String step, String status) {
    if (mounted) {
      setState(() {
        _currentStep = step;
        _status = status;
      });
    }
  }

  void _showDiagnostics(
    Map<String, dynamic> d, {
    Map<String, dynamic>? measurement,
    Map<String, dynamic>? pixelMetrics,
  }) {
    if (!mounted) return;
    setState(() {
      var summary =
          'Native S1 telemetry: processed=${d['processedFrameCount']} '
          'entered=${d['frameCount']} failOpen=${d['failOpenCount']} '
          'allS1=${d['allS1StagesApplied']} '
          '(allS1Frames=${d['allS1StagesAppliedFrameCount']}) '
          'src=${d['sourceWidth']}x${d['sourceHeight']} '
          'matte=${d['matteWidth']}x${d['matteHeight']}\n'
          'total ms last/mean/max='
          '${_fmtMs(d['lastTotalMs'])}/${_fmtMs(d['meanTotalMs'])}/${_fmtMs(d['maxTotalMs'])} '
          'vision mean=${_fmtMs(d['meanVisionMs'])} '
          'blend mean=${_fmtMs(d['meanBlendRenderMs'])}';

      if (measurement != null) {
        final fpsStr = measurement['steadyProcessedFps'] != null
            ? 'fps=${measurement['steadyProcessedFps']} '
            : '';
        final windowStr = measurement['steadyWindowSeconds'] != null
            ? ' in ${measurement['steadyWindowSeconds']}s'
            : '';
        summary +=
            '\nWarmup-excluded (steady=${measurement['steadyFrameCount']} frames$windowStr): '
            '$fpsStr'
            'total=${_fmtMs(measurement['warmupExcludedMeanTotalMs'])}ms '
            'vision=${_fmtMs(measurement['warmupExcludedMeanVisionMs'])}ms '
            'blend=${_fmtMs(measurement['warmupExcludedMeanBlendRenderMs'])}ms '
            'sampledLast min/mean/max=${_fmtMs(measurement['sampledMinLastTotalMs'])}/'
            '${_fmtMs(measurement['sampledMeanLastTotalMs'])}/'
            '${_fmtMs(measurement['sampledMaxLastTotalMs'])}ms';
      }

      if (pixelMetrics != null) {
        if (pixelMetrics['pixelCaptureAvailable'] == true) {
          summary +=
              '\nPixel metrics: bgCoverage=${pixelMetrics['backgroundCoveragePct']}% '
              'edgeRatio=${pixelMetrics['edgeTransitionRatioPct']}% '
              'samples=${pixelMetrics['sampledPixels']}';
        } else {
          summary +=
              '\nPixel metrics: unavailable (${pixelMetrics['error'] ?? 'capture skipped'})';
        }
      }

      _diagnosticsSummary = summary;
    });
  }

  /// Captures an image of the video Texture via [RenderRepaintBoundary] on
  /// [_previewKey] and computes objective pixel metrics against expected teal
  /// background RGB (0, 121, 107).
  Future<Map<String, dynamic>> _capturePixelMetrics() async {
    try {
      final boundary =
          _previewKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) {
        return <String, dynamic>{
          'width': 0,
          'height': 0,
          'sampledPixels': 0,
          'backgroundCoveragePct': 0.0,
          'edgeTransitionRatioPct': 0.0,
          'pixelCaptureAvailable': false,
          'error': 'RenderRepaintBoundary not found on preview key context',
        };
      }
      if (boundary.debugNeedsPaint) {
        await WidgetsBinding.instance.endOfFrame;
      }
      final ui.Image image = await boundary.toImage(pixelRatio: 0.5);
      try {
        final ByteData? byteData = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (byteData == null) {
          return <String, dynamic>{
            'width': image.width,
            'height': image.height,
            'sampledPixels': 0,
            'backgroundCoveragePct': 0.0,
            'edgeTransitionRatioPct': 0.0,
            'pixelCaptureAvailable': false,
            'error': 'toByteData returned null',
          };
        }

        final width = image.width;
        final height = image.height;
        final Uint8List bytes = byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        );

        int sampledPixels = 0;
        int backgroundPixels = 0;
        int transitionPixels = 0;

        for (int y = 0; y < height; y += kPixelSampleStride) {
          final rowOffset = y * width * 4;
          for (int x = 0; x < width; x += kPixelSampleStride) {
            final offset = rowOffset + (x * 4);
            if (offset + 2 >= bytes.length) continue;
            sampledPixels++;
            final r = bytes[offset];
            final g = bytes[offset + 1];
            final b = bytes[offset + 2];
            final dr = r - kExpectedBgR;
            final dg = g - kExpectedBgG;
            final db = b - kExpectedBgB;
            final dist = math.sqrt(dr * dr + dg * dg + db * db);
            if (dist <= 18.0) {
              backgroundPixels++;
            } else if (dist <= 80.0) {
              transitionPixels++;
            }
          }
        }

        final bgPct = sampledPixels > 0
            ? (backgroundPixels / sampledPixels) * 100.0
            : 0.0;
        final edgePct = sampledPixels > 0
            ? (transitionPixels / sampledPixels) * 100.0
            : 0.0;

        return <String, dynamic>{
          'width': width,
          'height': height,
          'sampledPixels': sampledPixels,
          'backgroundCoveragePct': double.parse(bgPct.toStringAsFixed(2)),
          'edgeTransitionRatioPct': double.parse(edgePct.toStringAsFixed(4)),
          'pixelCaptureAvailable': true,
        };
      } finally {
        image.dispose();
      }
    } catch (e) {
      return <String, dynamic>{
        'width': 0,
        'height': 0,
        'sampledPixels': 0,
        'backgroundCoveragePct': 0.0,
        'edgeTransitionRatioPct': 0.0,
        'pixelCaptureAvailable': false,
        'error': e.toString(),
      };
    }
  }

  /// Bounded poll: returns the first native snapshot whose processedFrameCount
  /// is > 0, or the last snapshot taken (possibly null) after
  /// [kDiagnosticsPollAttempts]. Assertions are applied by the caller.
  Future<Map<String, dynamic>?> _awaitProcessedGreenScreenDiagnostics() async {
    Map<String, dynamic>? snapshot;
    for (var attempt = 1; attempt <= kDiagnosticsPollAttempts; attempt++) {
      snapshot = await VanguardEngine.getCameraGreenScreenDiagnostics();
      if (_asInt(snapshot?['processedFrameCount']) > 0) {
        return snapshot;
      }
      if (attempt < kDiagnosticsPollAttempts) {
        await Future<void>.delayed(kDiagnosticsPollInterval);
      }
    }
    return snapshot;
  }

  /// Asserts the native telemetry contract for an active greenScreen node and
  /// returns the (non-null) snapshot. Latency values are reported, not gated.
  Map<String, dynamic> _assertGreenScreenDiagnostics(
    Map<String, dynamic>? d,
    String phase,
  ) {
    if (d == null) {
      throw StateError(
        '[$phase] getCameraGreenScreenDiagnostics returned null while the '
        'greenScreen filter is active',
      );
    }
    void check(bool condition, String claim) {
      if (!condition) {
        throw StateError(
          '[$phase] native telemetry assertion failed: $claim '
          '(snapshot=${jsonEncode(d)})',
        );
      }
    }

    check(
      d['proofLevel'] == 'S1',
      "proofLevel == 'S1' (got ${d['proofLevel']})",
    );
    check(
      d['matteSource'] == 'visionPersonFast',
      "matteSource == 'visionPersonFast' (got ${d['matteSource']})",
    );
    check(
      _asInt(d['backgroundARGB']) == kExpectedBackgroundARGB,
      'backgroundARGB == 0x${kExpectedBackgroundARGB.toRadixString(16).toUpperCase()} '
      '(got ${d['backgroundARGB']})',
    );
    check(
      _asInt(d['processedFrameCount']) > 0,
      'processedFrameCount > 0 (got ${d['processedFrameCount']})',
    );
    for (final flag in const <String>[
      'morphologyCloseApplied',
      'featherApplied',
      'trimapApplied',
      'guidedEdgeApplied',
      'allS1StagesApplied',
    ]) {
      check(d[flag] == true, '$flag == true (got ${d[flag]})');
    }
    check(
      _asInt(d['allS1StagesAppliedFrameCount']) > 0,
      'allS1StagesAppliedFrameCount > 0 '
      '(got ${d['allS1StagesAppliedFrameCount']})',
    );
    return d;
  }

  Future<void> _runSmoke() async {
    print(kSmokeStartMarker);
    final bool presetOverrideActive = kUfmCameraPreset.trim().isNotEmpty;
    print(
      'CONFIG: UFM_ENABLE_BEAUTY_V2=$kUfmEnableBeautyV2 '
      'UFM_CAMERA_CAPTURE_PROFILE="$kUfmCameraCaptureProfile" '
      'UFM_CAMERA_PRESET='
      '"${presetOverrideActive ? kUfmCameraPreset : "(none)"}" '
      'effectivePath=${presetOverrideActive ? "sessionPresetOverride" : "captureProfile"}',
    );

    int? textureId;
    bool cameraStarted = false;
    String? errorMessage;
    double? steadyWindowSeconds;
    double? steadyProcessedFps;
    Map<String, dynamic>? measurement;
    Map<String, dynamic> pixelMetrics = <String, dynamic>{
      'width': 0,
      'height': 0,
      'sampledPixels': 0,
      'backgroundCoveragePct': 0.0,
      'edgeTransitionRatioPct': 0.0,
      'pixelCaptureAvailable': false,
      'error': 'not_attempted',
    };

    try {
      // Lane 1: Start active UFM camera through the production captureProfile
      // path (default greenScreenLowLatency). UFM_CAMERA_PRESET, when set, is
      // passed as the explicit override and wins inside VanguardEngine.startCamera.
      final VanguardCameraCaptureProfile captureProfile =
          _resolveCaptureProfile(kUfmCameraCaptureProfile);
      final bool lowLatencyProfileEffective = !presetOverrideActive &&
          captureProfile == VanguardCameraCaptureProfile.greenScreenLowLatency;
      _updateStatus(
        'START_CAMERA',
        'Starting active UFM camera (front camera, 30 fps, '
        'captureProfile=${captureProfile.name}'
        '${presetOverrideActive ? ", sessionPreset=$kUfmCameraPreset" : ""})...',
      );
      textureId = await VanguardEngine.startCamera(
        position: 2,
        fps: 30,
        captureProfile: captureProfile,
        sessionPreset: presetOverrideActive ? kUfmCameraPreset : null,
      );
      cameraStarted = true;
      _cameraActive = true;

      // Lane 2: Display returned Texture(textureId: ...) full-screen with status overlay
      if (mounted) {
        setState(() {
          _textureId = textureId;
          _cameraModeDescription = 'Passthrough (baseline active camera)';
        });
      }
      print(kStepCameraStartedMarker);

      // Lane 3: Observe baseline camera for 3 seconds
      _updateStatus(
        'BASELINE_OBSERVE',
        'Observing baseline camera for 3 seconds...',
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      print(kStepBaselineObservedMarker);

      // Lane 4: Apply filter chain
      if (kUfmEnableBeautyV2) {
        _updateStatus(
          'APPLY_FILTER',
          'Applying UFM camera graph Beauty V2 + greenScreen filter chain '
          '(Beauty V2 intensity=0.5, solid teal 0xFF00796B, S1-refined)...',
        );
        await VanguardEngine.setCameraFilterChain(<VGFilterSpec>[
          VGFilterSpecs.beauty(beautyVersion: 2, intensity: 0.5),
          VGFilterSpecs.greenScreenSolidColor(argb: 0xFF00796B),
        ]);
        if (mounted) {
          setState(() {
            _isGreenScreenActive = true;
            _cameraModeDescription =
                'UFM camera graph Beauty V2 + greenScreen filter chain active (Beauty V2 + S1-refined)';
          });
        }
      } else {
        _updateStatus(
          'APPLY_FILTER',
          'Applying UFM camera graph greenScreen filter (solid teal 0xFF00796B, S1-refined)...',
        );
        await VanguardEngine.setCameraFilterChain(<VGFilterSpec>[
          VGFilterSpecs.greenScreenSolidColor(argb: 0xFF00796B),
        ]);
        if (mounted) {
          setState(() {
            _isGreenScreenActive = true;
            _cameraModeDescription =
                'UFM camera graph greenScreen filter active (S1-refined)';
          });
        }
      }
      print(kStepFilterAppliedMarker);

      // Lane 5: Observe keyed solid-color green screen for 10 seconds.
      // Overlay clearly indicates this is the UFM camera graph greenScreen filter
      // (S1-refined node), not standalone live green-screen API.
      //
      // Native telemetry proof (no NSLog dependency): after a bounded settle
      // period the harness reads VGGreenScreenFilterNode's diagnostics
      // snapshot through VanguardEngine.getCameraGreenScreenDiagnostics() and
      // asserts that the active node keyed frames with every S1 stage applied.
      _updateStatus(
        'GREENSCREEN_OBSERVE',
        kUfmEnableBeautyV2
            ? 'Observing UFM camera graph Beauty V2 + greenScreen filter chain for 10 seconds...'
            : 'Observing UFM camera graph greenScreen filter (S1-refined) for 10 seconds...',
      );
      final observeStart = DateTime.now();
      await Future<void>.delayed(kDiagnosticsSettleDelay);

      _updateStatus(
        'GREENSCREEN_DIAGNOSTICS',
        'Reading native greenScreen S1 telemetry snapshot...',
      );
      final warmupSnapshot = _assertGreenScreenDiagnostics(
        await _awaitProcessedGreenScreenDiagnostics(),
        'GREENSCREEN_DIAGNOSTICS_WARMUP',
      );
      final warmupTimestamp = DateTime.now();
      _showDiagnostics(warmupSnapshot);
      print('$kStepDiagnosticsAssertedMarker ${jsonEncode(warmupSnapshot)}');

      // Capture-profile proof: the profile is fixed at startCamera time, so the
      // source dimensions the greenScreen node sees must reflect it. Only
      // asserted when the low-latency profile is the effective path (no raw
      // preset override); the baseline/override runs just report dimensions.
      final int sourceW = _asInt(warmupSnapshot['sourceWidth']);
      final int sourceH = _asInt(warmupSnapshot['sourceHeight']);
      final int sourceLongSide = math.max(sourceW, sourceH);
      if (kUfmEnableBeautyV2) {
        if (sourceLongSide <= 0 || sourceLongSide >= kDefaultQualityLongSidePx) {
          throw StateError(
            '[BEAUTY_V2_CAPTURE] Beauty V2 mode requires source long side > 0 and < $kDefaultQualityLongSidePx '
            '(native telemetry reports source ${sourceW}x$sourceH)',
          );
        }
      } else if (lowLatencyProfileEffective) {
        if (sourceLongSide <= 0 || sourceLongSide >= kDefaultQualityLongSidePx) {
          throw StateError(
            '[CAPTURE_PROFILE] greenScreenLowLatency was requested at startCamera '
            'but native telemetry reports source ${sourceW}x$sourceH '
            '(long side must be > 0 and < $kDefaultQualityLongSidePx)',
          );
        }
      }
      print(kStepWarmupSettledMarker);

      // Sample lastTotalMs 5 times across the remaining active window and capture
      // objective pixel metrics around the middle of the steady window.
      final remaining =
          kGreenScreenObserveDuration - DateTime.now().difference(observeStart);
      final remainingMs = math.max(remaining.inMilliseconds, 3500);
      final sampleInterval = Duration(milliseconds: remainingMs ~/ 5);
      final sampledLastTotalMs = <double>[];
      pixelMetrics = <String, dynamic>{
        'width': 0,
        'height': 0,
        'sampledPixels': 0,
        'backgroundCoveragePct': 0.0,
        'edgeTransitionRatioPct': 0.0,
        'pixelCaptureAvailable': false,
        'error': 'not_attempted',
      };

      for (var i = 1; i <= 5; i++) {
        await Future<void>.delayed(sampleInterval);
        final sampleDiag =
            await VanguardEngine.getCameraGreenScreenDiagnostics();
        if (sampleDiag != null) {
          final sampleLast = _asDouble(sampleDiag['lastTotalMs']);
          if (sampleLast > 0.0) {
            sampledLastTotalMs.add(sampleLast);
          }
        }

        if (i == 3) {
          _updateStatus(
            'GREENSCREEN_CAPTURE',
            'Capturing objective pixel metrics around middle of steady window...',
          );
          pixelMetrics = await _capturePixelMetrics();
          if (pixelMetrics['pixelCaptureAvailable'] == true) {
            print('$kStepFrameCapturedMarker ${jsonEncode(pixelMetrics)}');
          }
        }
      }
      print(
        '$kStepSteadySampledMarker ${jsonEncode(<String, dynamic>{'sampleCount': sampledLastTotalMs.length, 'samples': sampledLastTotalMs})}',
      );

      _updateStatus(
        'GREENSCREEN_OBSERVE_END',
        'Reading final native greenScreen S1 telemetry snapshot...',
      );
      final finalDiagnosticsRaw =
          await VanguardEngine.getCameraGreenScreenDiagnostics();
      final finalTimestamp = DateTime.now();
      final finalDiagnostics = _assertGreenScreenDiagnostics(
        finalDiagnosticsRaw,
        'GREENSCREEN_OBSERVE_END',
      );

      final n1 = _asInt(warmupSnapshot['processedFrameCount']);
      final n2 = _asInt(finalDiagnostics['processedFrameCount']);
      final steadyFrameCount = n2 - n1;

      final elapsedMicroseconds =
          finalTimestamp.difference(warmupTimestamp).inMicroseconds;
      steadyWindowSeconds = elapsedMicroseconds > 0
          ? double.parse((elapsedMicroseconds / 1000000.0).toStringAsFixed(3))
          : 0.0;
      steadyProcessedFps = steadyWindowSeconds > 0.0
          ? double.parse(
              (steadyFrameCount / steadyWindowSeconds).toStringAsFixed(2),
            )
          : 0.0;

      final int finalSourceW = _asInt(finalDiagnostics['sourceWidth']);
      final int finalSourceH = _asInt(finalDiagnostics['sourceHeight']);
      final int finalSourceLongSide = math.max(finalSourceW, finalSourceH);

      if (kUfmEnableBeautyV2) {
        if (finalSourceLongSide <= 0 ||
            finalSourceLongSide >= kDefaultQualityLongSidePx) {
          throw StateError(
            '[BEAUTY_V2_CAPTURE] Beauty V2 mode requires source long side > 0 and < $kDefaultQualityLongSidePx '
            '(final native telemetry reports source ${finalSourceW}x$finalSourceH)',
          );
        }
        if (steadyFrameCount < 50) {
          throw StateError(
            '[BEAUTY_V2_MEASUREMENT] steadyFrameCount must be >= 50 '
            '(got $steadyFrameCount; warmupProcessed=$n1, finalProcessed=$n2)',
          );
        }
        if (steadyProcessedFps < 20.0) {
          throw StateError(
            '[BEAUTY_V2_MEASUREMENT] steadyProcessedFps must be >= 20.0 '
            '(got $steadyProcessedFps fps across $steadyFrameCount steady frames '
            'in ${steadyWindowSeconds}s)',
          );
        }
      } else {
        if (steadyFrameCount < 50) {
          throw StateError(
            '[GREENSCREEN_MEASUREMENT] steadyFrameCount must be >= 50 '
            '(got $steadyFrameCount; warmupProcessed=$n1, finalProcessed=$n2)',
          );
        }
      }

      final warmupExcludedMeanTotalMs = _computeWarmupExcludedMean(
        snapshot1: warmupSnapshot,
        snapshot2: finalDiagnostics,
        metricKey: 'meanTotalMs',
      );
      final warmupExcludedMeanVisionMs = _computeWarmupExcludedMean(
        snapshot1: warmupSnapshot,
        snapshot2: finalDiagnostics,
        metricKey: 'meanVisionMs',
      );
      final warmupExcludedMeanBlendRenderMs = _computeWarmupExcludedMean(
        snapshot1: warmupSnapshot,
        snapshot2: finalDiagnostics,
        metricKey: 'meanBlendRenderMs',
      );

      if (!kUfmEnableBeautyV2) {
        if (warmupExcludedMeanTotalMs == null ||
            warmupExcludedMeanTotalMs <= 0.0 ||
            warmupExcludedMeanTotalMs >= 50.0) {
          throw StateError(
            '[GREENSCREEN_MEASUREMENT] warmupExcludedMeanTotalMs must be > 0 and < 50 '
            '(got $warmupExcludedMeanTotalMs)',
          );
        }
        if (warmupExcludedMeanVisionMs == null ||
            warmupExcludedMeanVisionMs <= 0.0 ||
            warmupExcludedMeanVisionMs >= 40.0) {
          throw StateError(
            '[GREENSCREEN_MEASUREMENT] warmupExcludedMeanVisionMs must be > 0 and < 40 '
            '(got $warmupExcludedMeanVisionMs)',
          );
        }
        if (warmupExcludedMeanBlendRenderMs == null ||
            warmupExcludedMeanBlendRenderMs <= 0.0 ||
            warmupExcludedMeanBlendRenderMs >= 30.0) {
          throw StateError(
            '[GREENSCREEN_MEASUREMENT] warmupExcludedMeanBlendRenderMs must be > 0 and < 30 '
            '(got $warmupExcludedMeanBlendRenderMs)',
          );
        }
      }

      final sampledMinLastTotalMs = sampledLastTotalMs.isNotEmpty
          ? double.parse(sampledLastTotalMs.reduce(math.min).toStringAsFixed(3))
          : _asDouble(finalDiagnostics['lastTotalMs']);
      final sampledMaxLastTotalMs = sampledLastTotalMs.isNotEmpty
          ? double.parse(sampledLastTotalMs.reduce(math.max).toStringAsFixed(3))
          : _asDouble(finalDiagnostics['lastTotalMs']);
      final sampledMeanLastTotalMs = sampledLastTotalMs.isNotEmpty
          ? double.parse(
              (sampledLastTotalMs.reduce((a, b) => a + b) /
                      sampledLastTotalMs.length)
                  .toStringAsFixed(3),
            )
          : _asDouble(finalDiagnostics['lastTotalMs']);

      final backgroundCoveragePct = _asDouble(
        pixelMetrics['backgroundCoveragePct'],
      );
      final edgeTransitionRatioPct = _asDouble(
        pixelMetrics['edgeTransitionRatioPct'],
      );
      final pixelCaptureAvailable =
          pixelMetrics['pixelCaptureAvailable'] == true;

      if (!kUfmEnableBeautyV2 && pixelCaptureAvailable) {
        if (backgroundCoveragePct < 15.0) {
          throw StateError(
            '[GREENSCREEN_MEASUREMENT] backgroundCoveragePct must be >= 15.0 '
            '(got $backgroundCoveragePct%)',
          );
        }
        if (edgeTransitionRatioPct <= 0.05) {
          throw StateError(
            '[GREENSCREEN_MEASUREMENT] edgeTransitionRatioPct must be > 0.05 '
            '(got $edgeTransitionRatioPct%)',
          );
        }
      } else if (!pixelCaptureAvailable) {
        pixelMetrics['fallbackNote'] =
            'Pixel capture unavailable on this run; objective pixel coverage metrics skipped without claiming visual parity';
      }

      measurement = <String, dynamic>{
        'warmupProcessedCount': n1,
        'finalProcessedCount': n2,
        'steadyFrameCount': steadyFrameCount,
        'steadyWindowSeconds': steadyWindowSeconds,
        'steadyProcessedFps': steadyProcessedFps,
        'warmupExcludedMeanTotalMs': warmupExcludedMeanTotalMs,
        'warmupExcludedMeanVisionMs': warmupExcludedMeanVisionMs,
        'warmupExcludedMeanBlendRenderMs': warmupExcludedMeanBlendRenderMs,
        'sampledMinLastTotalMs': sampledMinLastTotalMs,
        'sampledMaxLastTotalMs': sampledMaxLastTotalMs,
        'sampledMeanLastTotalMs': sampledMeanLastTotalMs,
        'sampledLastTotalMs': sampledLastTotalMs,
        'backgroundCoveragePct': backgroundCoveragePct,
        'edgeTransitionRatioPct': edgeTransitionRatioPct,
        'pixelCaptureAvailable': pixelCaptureAvailable,
        if (!pixelCaptureAvailable)
          'fallbackNote': pixelMetrics['fallbackNote'],
      };

      final metricsPayload = <String, dynamic>{
        'beautyV2Enabled': kUfmEnableBeautyV2,
        'captureProfile': captureProfile.name,
        'sessionPresetOverride': presetOverrideActive ? kUfmCameraPreset : null,
        'lowLatencyProfileEffective': lowLatencyProfileEffective,
        'sourceWidth': sourceW,
        'sourceHeight': sourceH,
        'steadyFrameCount': steadyFrameCount,
        'steadyWindowSeconds': steadyWindowSeconds,
        'steadyProcessedFps': steadyProcessedFps,
        'warmupExcludedMeanTotalMs': warmupExcludedMeanTotalMs,
        'warmupExcludedMeanVisionMs': warmupExcludedMeanVisionMs,
        'warmupExcludedMeanBlendRenderMs': warmupExcludedMeanBlendRenderMs,
        'sampledMinLastTotalMs': sampledMinLastTotalMs,
        'sampledMaxLastTotalMs': sampledMaxLastTotalMs,
        'sampledMeanLastTotalMs': sampledMeanLastTotalMs,
        'sampledLastTotalMs': sampledLastTotalMs,
        'pixelMetrics': pixelMetrics,
        if (!pixelCaptureAvailable)
          'fallbackNote': pixelMetrics['fallbackNote'],
      };

      print('$kMetricsJsonMarker: ${jsonEncode(metricsPayload)}');

      _showDiagnostics(
        finalDiagnostics,
        measurement: measurement,
        pixelMetrics: pixelMetrics,
      );

      // Lane 6: Clear filters with VanguardEngine.setCameraFilterChain([]).
      // Observe passthrough camera for 3 seconds.
      _updateStatus(
        'CLEAR_FILTER',
        'Clearing camera filter chain (returning to passthrough)...',
      );
      await VanguardEngine.setCameraFilterChain(<VGFilterSpec>[]);
      if (mounted) {
        setState(() {
          _isGreenScreenActive = false;
          _cameraModeDescription = 'Passthrough (filters cleared)';
        });
      }
      print(kStepFilterClearedMarker);

      // Clear-to-null proof: with no greenScreen node in the committed filter
      // chain the native snapshot must be null (no stale node state retained).
      _updateStatus(
        'CLEAR_DIAGNOSTICS',
        'Verifying native greenScreen telemetry is null after clear...',
      );
      final clearedDiagnostics =
          await VanguardEngine.getCameraGreenScreenDiagnostics();
      if (clearedDiagnostics != null) {
        throw StateError(
          '[CLEAR_DIAGNOSTICS] getCameraGreenScreenDiagnostics must return '
          'null after the filter chain is cleared '
          '(got ${jsonEncode(clearedDiagnostics)})',
        );
      }
      print(kStepDiagnosticsClearedMarker);

      _updateStatus(
        'PASSTHROUGH_OBSERVE',
        'Observing passthrough camera for 3 seconds...',
      );
      await Future<void>.delayed(const Duration(seconds: 3));

      // Lane 7: Stop camera in cleanup/dispose
      _updateStatus('STOP_CAMERA', 'Stopping camera session...');
      await VanguardEngine.stopCamera();
      cameraStarted = false;
      _cameraActive = false;
      if (mounted) {
        setState(() {
          _cameraModeDescription = 'Camera stopped (cleanup complete)';
        });
      }
      print(kStepCameraStoppedMarker);

      final passPayload = <String, dynamic>{
        'pass': true,
        'beautyV2Enabled': kUfmEnableBeautyV2,
        'textureId': textureId,
        'captureProfile': captureProfile.name,
        'sessionPresetOverride': presetOverrideActive ? kUfmCameraPreset : null,
        'lowLatencyProfileEffective': lowLatencyProfileEffective,
        'sourceWidth': sourceW,
        'sourceHeight': sourceH,
        'steadyFrameCount': steadyFrameCount,
        'steadyWindowSeconds': steadyWindowSeconds,
        'steadyProcessedFps': steadyProcessedFps,
        'claimsAllowed': kClaimsAllowed,
        'nonClaims': kNonClaims,
        'diagnostics': finalDiagnostics,
        'diagnosticsClearedToNull': true,
        'measurement': measurement,
        'pixelMetrics': pixelMetrics,
      };
      print('$kSmokePassMarker ${jsonEncode(passPayload)}');

      if (mounted) {
        setState(() {
          _isPassed = true;
          _status = 'PASS';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e, st) {
      errorMessage = e.toString();
      _updateStatus('ERROR', 'Failure: $errorMessage');

      if (cameraStarted) {
        try {
          await VanguardEngine.stopCamera();
          cameraStarted = false;
          _cameraActive = false;
          print(kStepCameraStoppedMarker);
        } catch (stopErr) {
          // Preserve primary failure error
        }
      }

      final failPayload = <String, dynamic>{
        'pass': false,
        'beautyV2Enabled': kUfmEnableBeautyV2,
        'textureId': textureId,
        'captureProfileRequested': kUfmCameraCaptureProfile,
        'sessionPresetOverride': presetOverrideActive ? kUfmCameraPreset : null,
        'steadyWindowSeconds': steadyWindowSeconds,
        'steadyProcessedFps': steadyProcessedFps,
        'claimsAllowed': kClaimsAllowed,
        'nonClaims': kNonClaims,
        'error': errorMessage,
        if (e is PlatformException) 'platformErrorCode': e.code,
        if (e is PlatformException) 'platformErrorMessage': e.message,
        'stackTrace': st.toString(),
      };
      if (measurement != null) {
        failPayload['measurement'] = measurement;
      }
      failPayload['pixelMetrics'] = pixelMetrics;
      print('$kSmokeFailMarker ${jsonEncode(failPayload)}');

      if (mounted) {
        setState(() {
          _isFailed = true;
          _status = 'FAIL: $errorMessage';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(1);
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
            // Full-screen Texture display wrapped in RepaintBoundary for isolated capture
            if (_textureId != null)
              Center(
                child: SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: RepaintBoundary(
                      key: _previewKey,
                      child: SizedBox(
                        width: 1080,
                        height: 1920,
                        child: Texture(textureId: _textureId!),
                      ),
                    ),
                  ),
                ),
              )
            else
              const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      'Waiting for camera start...',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),

            // Status overlay (must remain outside the RepaintBoundary)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.80),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _isFailed
                          ? Colors.redAccent
                          : (_isPassed
                                ? Colors.greenAccent
                                : (_isGreenScreenActive
                                      ? Colors.tealAccent
                                      : Colors.white24)),
                      width: 1.5,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'iOS UFM Camera GreenScreen Filter Smoke',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Step: $_currentStep',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Status: $_status',
                        style: TextStyle(
                          color: _isFailed
                              ? Colors.redAccent
                              : (_isPassed ? Colors.greenAccent : Colors.white),
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      if (_textureId != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Texture ID: $_textureId (retained across filter changes)',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 11,
                          ),
                        ),
                      ],
                      const SizedBox(height: 2),
                      Text(
                        'Capture profile: $kUfmCameraCaptureProfile'
                        '${kUfmCameraPreset.trim().isNotEmpty ? " (overridden by UFM_CAMERA_PRESET=$kUfmCameraPreset)" : " (fixed at startCamera)"}',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Beauty V2 mode: ${kUfmEnableBeautyV2 ? "ENABLED (V2, intensity 0.5)" : "DISABLED (greenScreen only)"}',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Overlay explicitly distinguishing UFM camera graph greenScreen filter
                      // from standalone live green-screen API.
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: _isGreenScreenActive
                              ? const Color(0xFF004D40).withValues(alpha: 0.85)
                              : Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _isGreenScreenActive
                                ? const Color(0xFF80CBC4)
                                : Colors.white24,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _isGreenScreenActive
                                  ? (kUfmEnableBeautyV2
                                        ? 'UFM CAMERA GRAPH BEAUTY V2 + GREENSCREEN FILTER ACTIVE'
                                        : 'UFM CAMERA GRAPH GREENSCREEN FILTER ACTIVE (S1-REFINED)')
                                  : 'CAMERA MODE: $_cameraModeDescription',
                              style: TextStyle(
                                color: _isGreenScreenActive
                                    ? const Color(0xFF80CBC4)
                                    : Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _isGreenScreenActive
                                  ? (kUfmEnableBeautyV2
                                        ? 'Route: [VGFilterSpecs.beauty(beautyVersion: 2, intensity: 0.5), VGFilterSpecs.greenScreenSolidColor(argb: 0xFF00796B)]\n'
                                              'Pipeline: Active UFM camera graph Beauty V2 + S1-refined filter chain\n'
                                              'Proves: combined Beauty V2 + greenScreen filter chain is accepted and co-executes in active camera graph.\n'
                                              'Throughput proof: steadyProcessedFps >= 20.0 asserted across steady frames >= 50.\n'
                                              'Native proof: S1 stage telemetry read via getCameraGreenScreenDiagnostics and asserted (processed frames, all four S1 stages, steadyProcessedFps >= 20.0).\n'
                                              'Non-claims: green-screen node telemetry excludes Beauty V2 per-node cost; does NOT prove native cumulative latency across combined chain, TikTok visual quality, temporal smoothing, image/video backgrounds, recording/export/photo, Duet, or Android.'
                                        : 'Route: VGFilterSpecs.greenScreenSolidColor(argb: 0xFF00796B)\n'
                                              'Pipeline: Active UFM camera graph S1-refined filter node\n'
                                              'Proves: greenScreen filter route is accepted and S1-refined node '
                                              'is invoked by the active camera graph (not standalone live green-screen / ARKit / Duet).\n'
                                              'Native proof: S1 stage telemetry read via getCameraGreenScreenDiagnostics '
                                              'and asserted (processed frames, all four S1 stages, measured latency, '
                                              'warmup-excluded steady latency, and objective pixel metrics).\n'
                                              'Non-claims: Does NOT prove TikTok visual quality, temporal smoothing, '
                                              'image/video backgrounds, recording/export/photo, Duet, or Android.')
                                  : 'Active route: VanguardEngine.startCamera / setCameraFilterChain',
                              style: TextStyle(
                                color: _isGreenScreenActive
                                    ? Colors.white
                                    : Colors.white60,
                                fontSize: 11,
                                height: 1.3,
                              ),
                            ),
                            if (_diagnosticsSummary.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                _diagnosticsSummary,
                                style: const TextStyle(
                                  color: Color(0xFFB2DFDB),
                                  fontSize: 10,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ],
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
