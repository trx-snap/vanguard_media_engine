// android_animated_roi_sidecar_physical_smoke.dart
// Vanguard Media Engine - P5-ANIM-ROI-KEYFRAME-INTERP
// Android Animated / Keyframed ROI Sidecar Builder physical smoke harness.
//
// Pure Dart verification on physical Android device.
// Zero MethodChannel calls, zero file I/O, zero native state mutation.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAnimatedRoiSidecarPhysicalSmokeApp());
}

class AndroidAnimatedRoiSidecarPhysicalSmokeApp extends StatefulWidget {
  const AndroidAnimatedRoiSidecarPhysicalSmokeApp({super.key});

  @override
  State<AndroidAnimatedRoiSidecarPhysicalSmokeApp> createState() =>
      _AndroidAnimatedRoiSidecarPhysicalSmokeAppState();
}

class _AndroidAnimatedRoiSidecarPhysicalSmokeAppState
    extends State<AndroidAnimatedRoiSidecarPhysicalSmokeApp> {
  String _status =
      'Initializing Android Animated ROI Sidecar physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_ANIMATED_ROI_SIDECAR_SMOKE_START');
    final results = <String, bool>{};

    // Lane 1: Linear midpoint interpolation
    try {
      final startBox = VGROIBox(x: 0.1, y: 0.2, w: 0.3, h: 0.4);
      final endBox = VGROIBox(x: 0.3, y: 0.6, w: 0.5, h: 0.2);
      final sidecar = VGROIKeyframeSidecarBuilder.build(
        durationMs: 1000,
        outputWidth: 1080,
        outputHeight: 1920,
        sampleIntervalMs: 500,
        keyframes: [
          VGROIKeyframe(timestampMs: 0, box: startBox),
          VGROIKeyframe(timestampMs: 1000, box: endBox),
        ],
      );
      final mid = sidecar.samples.firstWhere((s) => s.timestampMs == 500).box!;
      final pass =
          (mid.x - 0.2).abs() < 1e-6 &&
          (mid.y - 0.4).abs() < 1e-6 &&
          (mid.w - 0.4).abs() < 1e-6 &&
          (mid.h - 0.3).abs() < 1e-6;
      results['lane_1_linear_midpoint'] = pass;
    } catch (e) {
      results['lane_1_linear_midpoint'] = false;
    }

    // Lane 2: easeInOut / smoothstep curve
    try {
      final startBox = VGROIBox(x: 0.0, y: 0.0, w: 0.2, h: 0.2);
      final endBox = VGROIBox(x: 0.8, y: 0.8, w: 0.2, h: 0.2);
      final easeSidecar = VGROIKeyframeSidecarBuilder.build(
        durationMs: 1000,
        outputWidth: 1080,
        outputHeight: 1920,
        sampleIntervalMs: 250,
        keyframes: [
          VGROIKeyframe(
            timestampMs: 0,
            box: startBox,
            interpolation: VGROIKeyframeInterpolation.easeInOut,
          ),
          VGROIKeyframe(timestampMs: 1000, box: endBox),
        ],
      );
      final linSidecar = VGROIKeyframeSidecarBuilder.build(
        durationMs: 1000,
        outputWidth: 1080,
        outputHeight: 1920,
        sampleIntervalMs: 250,
        keyframes: [
          VGROIKeyframe(timestampMs: 0, box: startBox),
          VGROIKeyframe(timestampMs: 1000, box: endBox),
        ],
      );
      final ease250 = easeSidecar.samples
          .firstWhere((s) => s.timestampMs == 250)
          .box!;
      final lin250 = linSidecar.samples
          .firstWhere((s) => s.timestampMs == 250)
          .box!;
      final pass =
          (ease250.x - 0.125).abs() < 1e-6 &&
          (lin250.x - 0.2).abs() < 1e-6 &&
          (ease250.x != lin250.x);
      results['lane_2_ease_in_out_curve'] = pass;
    } catch (e) {
      results['lane_2_ease_in_out_curve'] = false;
    }

    // Lane 3: Off-grid exact keyframe inclusion
    try {
      final box137 = VGROIBox(x: 0.2, y: 0.3, w: 0.25, h: 0.25);
      final sidecar = VGROIKeyframeSidecarBuilder.build(
        durationMs: 1000,
        outputWidth: 1080,
        outputHeight: 1920,
        sampleIntervalMs: 100,
        keyframes: [
          VGROIKeyframe(
            timestampMs: 0,
            box: VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
          ),
          VGROIKeyframe(timestampMs: 137, box: box137, quality: 'off_grid'),
          VGROIKeyframe(
            timestampMs: 1000,
            box: VGROIBox(x: 0.5, y: 0.5, w: 0.3, h: 0.3),
          ),
        ],
      );
      final sample137 = sidecar.samples.firstWhere((s) => s.timestampMs == 137);
      final pass = sample137.box == box137 && sample137.quality == 'off_grid';
      results['lane_3_off_grid_keyframe'] = pass;
    } catch (e) {
      results['lane_3_off_grid_keyframe'] = false;
    }

    // Lane 4: Missing / null endpoint handling
    try {
      final sidecar = VGROIKeyframeSidecarBuilder.build(
        durationMs: 1000,
        outputWidth: 1080,
        outputHeight: 1920,
        sampleIntervalMs: 100,
        keyframes: [
          VGROIKeyframe(
            timestampMs: 0,
            box: VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
          ),
          VGROIKeyframe(timestampMs: 500, box: null),
          VGROIKeyframe(
            timestampMs: 1000,
            box: VGROIBox(x: 0.5, y: 0.5, w: 0.3, h: 0.3),
          ),
        ],
      );
      final sample200 = sidecar.samples.firstWhere((s) => s.timestampMs == 200);
      final sample700 = sidecar.samples.firstWhere((s) => s.timestampMs == 700);
      final pass = sample200.box == null && sample700.box == null;
      results['lane_4_null_segment_safety'] = pass;
    } catch (e) {
      results['lane_4_null_segment_safety'] = false;
    }

    // Lane 5: Empty keyframes fallback
    try {
      final sidecar = VGROIKeyframeSidecarBuilder.build(
        durationMs: 2000,
        outputWidth: 720,
        outputHeight: 1280,
        keyframes: const [],
      );
      final pass =
          sidecar.coordinateSpace == 'export_output_normalized' &&
          sidecar.finalized &&
          sidecar.samples.isEmpty &&
          sidecar.coverage.coveragePercent == 0.0;
      results['lane_5_empty_fallback'] = pass;
    } catch (e) {
      results['lane_5_empty_fallback'] = false;
    }

    // Lane 6: Duplicate timestamp throws
    try {
      var threw = false;
      try {
        VGROIKeyframeSidecarBuilder.build(
          durationMs: 1000,
          outputWidth: 1080,
          outputHeight: 1920,
          keyframes: [
            VGROIKeyframe(
              timestampMs: 300,
              box: VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
            ),
            VGROIKeyframe(
              timestampMs: 300,
              box: VGROIBox(x: 0.2, y: 0.2, w: 0.2, h: 0.2),
            ),
          ],
        );
      } on ArgumentError {
        threw = true;
      }
      results['lane_6_duplicate_validation'] = threw;
    } catch (e) {
      results['lane_6_duplicate_validation'] = false;
    }

    // Lane 7: JSON roundtrip
    try {
      final sidecar = VGROIKeyframeSidecarBuilder.build(
        durationMs: 1000,
        outputWidth: 1080,
        outputHeight: 1920,
        sampleIntervalMs: 500,
        keyframes: [
          VGROIKeyframe(
            timestampMs: 0,
            box: VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
          ),
          VGROIKeyframe(
            timestampMs: 1000,
            box: VGROIBox(x: 0.5, y: 0.5, w: 0.3, h: 0.3),
          ),
        ],
      );
      final json = sidecar.toJson();
      final roundtrip = VGROISidecar.fromJson(json);
      final pass = roundtrip == sidecar && roundtrip.samples.length == 3;
      results['lane_7_json_roundtrip'] = pass;
    } catch (e) {
      results['lane_7_json_roundtrip'] = false;
    }

    final passedCount = results.values.where((v) => v).length;
    final totalCount = results.length;
    final allPass = totalCount == 7 && passedCount == 7;

    print(
      'ANDROID_ANIMATED_ROI_SIDECAR_JSON:${jsonEncode(<String, Object?>{'totalLanes': totalCount, 'passedLanes': passedCount, 'allPass': allPass, 'results': results})}',
    );

    print(
      'ANDROID_ANIMATED_ROI_SIDECAR_SUMMARY: $passedCount/$totalCount lanes passed',
    );

    print(
      allPass
          ? 'ANDROID_ANIMATED_ROI_SIDECAR_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_ANIMATED_ROI_SIDECAR_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS ($passedCount/$totalCount animated ROI lanes verified)'
            : 'FAIL ($passedCount/$totalCount animated ROI lanes passed)';
      });
    }

    await Future<void>.delayed(const Duration(seconds: 2));
    exit(allPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Android Animated ROI Smoke (P5-ANIM-ROI)'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18),
            ),
          ),
        ),
      ),
    );
  }
}
