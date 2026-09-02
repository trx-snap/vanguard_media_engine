// android_overlay_keyframe_physical_smoke.dart
// Vanguard Media Engine - P5-OVERLAYS-KEYFRAME-INTERP
// Android Overlay Keyframe & Spatial Transform Interpolation physical smoke harness.
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
  runApp(const AndroidOverlayKeyframePhysicalSmokeApp());
}

class AndroidOverlayKeyframePhysicalSmokeApp extends StatefulWidget {
  const AndroidOverlayKeyframePhysicalSmokeApp({super.key});

  @override
  State<AndroidOverlayKeyframePhysicalSmokeApp> createState() =>
      _AndroidOverlayKeyframePhysicalSmokeAppState();
}

class _AndroidOverlayKeyframePhysicalSmokeAppState
    extends State<AndroidOverlayKeyframePhysicalSmokeApp> {
  String _status =
      'Initializing Android Overlay Keyframe Interpolation physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE5_OVERLAY_KEYFRAME_INTERP_SMOKE_START');
    final results = <String, bool>{};

    // Lane 1: Linear midpoint interpolation
    try {
      final overlay = VGOverlayDescriptor(
        id: 'lane1_ov',
        startTimeSeconds: 0.0,
        durationSeconds: 2.0,
      );
      final kf0 = VGOverlayKeyframe(
        timeSeconds: 0.0,
        translationX: 0.0,
        translationY: 50.0,
        width: 100.0,
        height: 60.0,
        rotation: 0.0,
        scale: 1.0,
        opacity: 0.2,
      );
      final kf1 = VGOverlayKeyframe(
        timeSeconds: 2.0,
        translationX: 100.0,
        translationY: 150.0,
        width: 200.0,
        height: 120.0,
        rotation: 1.0,
        scale: 2.0,
        opacity: 0.8,
      );

      final eval = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 1.0,
        keyframes: [kf0, kf1],
      );

      final pass =
          eval != null &&
          (eval.translationX - 50.0).abs() < 1e-6 &&
          (eval.translationY - 100.0).abs() < 1e-6 &&
          (eval.width - 150.0).abs() < 1e-6 &&
          (eval.height - 90.0).abs() < 1e-6 &&
          (eval.rotation - 0.5).abs() < 1e-6 &&
          (eval.scale - 1.5).abs() < 1e-6 &&
          (eval.opacity - 0.5).abs() < 1e-6;

      results['lane_1_linear_midpoint'] = pass;
    } catch (e) {
      results['lane_1_linear_midpoint'] = false;
    }

    // Lane 2: easeInOut / smoothstep cubic curve
    try {
      final overlay = VGOverlayDescriptor(
        id: 'lane2_ov',
        startTimeSeconds: 0.0,
        durationSeconds: 4.0,
      );
      final kf0 = VGOverlayKeyframe(
        timeSeconds: 0.0,
        translationX: 0.0,
        interpolation: VGOverlayInterpolation.easeInOut,
      );
      final kf1 = VGOverlayKeyframe(timeSeconds: 4.0, translationX: 100.0);

      // At t=1.0 (progress=0.25): cubic smoothstep is 0.25^2 * (3 - 2*0.25) = 0.15625
      final eval = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 1.0,
        keyframes: [kf0, kf1],
      );

      final pass =
          eval != null &&
          (eval.translationX - 15.625).abs() < 1e-6 &&
          (eval.translationX != 25.0);

      results['lane_2_ease_in_out_curve'] = pass;
    } catch (e) {
      results['lane_2_ease_in_out_curve'] = false;
    }

    // Lane 3: Hold mode
    try {
      final overlay = VGOverlayDescriptor(
        id: 'lane3_ov',
        startTimeSeconds: 0.0,
        durationSeconds: 4.0,
      );
      final kf0 = VGOverlayKeyframe(
        timeSeconds: 1.0,
        translationX: 10.0,
        interpolation: VGOverlayInterpolation.hold,
      );
      final kf1 = VGOverlayKeyframe(timeSeconds: 3.0, translationX: 80.0);

      final evalHeld = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 2.0,
        keyframes: [kf0, kf1],
      );
      final evalJumped = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 3.0,
        keyframes: [kf0, kf1],
      );

      final pass =
          evalHeld != null &&
          evalJumped != null &&
          evalHeld.translationX == 10.0 &&
          evalJumped.translationX == 80.0;

      results['lane_3_hold_mode'] = pass;
    } catch (e) {
      results['lane_3_hold_mode'] = false;
    }

    // Lane 4: Exact keyframes and clamping boundaries
    try {
      final overlay = VGOverlayDescriptor(
        id: 'lane4_ov',
        startTimeSeconds: 0.0,
        durationSeconds: 5.0,
      );
      final kf0 = VGOverlayKeyframe(timeSeconds: 1.0, scale: 1.5);
      final kf1 = VGOverlayKeyframe(timeSeconds: 3.0, scale: 3.0);

      final evalPre = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 0.5,
        keyframes: [kf0, kf1],
      );
      final evalExact = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 1.0,
        keyframes: [kf0, kf1],
      );
      final evalPost = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 4.5,
        keyframes: [kf0, kf1],
      );

      final pass =
          evalPre?.scale == 1.5 &&
          evalExact?.scale == 1.5 &&
          evalPost?.scale == 3.0;

      results['lane_4_exact_and_clamping'] = pass;
    } catch (e) {
      results['lane_4_exact_and_clamping'] = false;
    }

    // Lane 5: Active interval check & static fallback
    try {
      final overlay = VGOverlayDescriptor(
        id: 'lane5_ov',
        type: VGOverlayType.text,
        startTimeSeconds: 1.0,
        durationSeconds: 3.0,
        translationX: 42.0,
        textContent: 'static_check',
      );

      final evalBefore = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 0.5,
      );
      final evalEnd = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 4.0, // Exclusive end boundary
      );
      final evalStatic = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 2.0,
      );

      final pass =
          evalBefore == null &&
          evalEnd == null &&
          evalStatic != null &&
          evalStatic.translationX == 42.0 &&
          evalStatic.textContent == 'static_check';

      results['lane_5_active_interval_and_static_fallback'] = pass;
    } catch (e) {
      results['lane_5_active_interval_and_static_fallback'] = false;
    }

    // Lane 6: Multi-overlay deterministic sorting (zIndex asc, id asc)
    try {
      final ovA = VGOverlayDescriptor(
        id: 'ov_a',
        startTimeSeconds: 0.0,
        durationSeconds: 5.0,
        zIndex: 2,
      );
      final ovB = VGOverlayDescriptor(
        id: 'ov_b',
        startTimeSeconds: 0.0,
        durationSeconds: 5.0,
        zIndex: 1,
      );
      final ovC = VGOverlayDescriptor(
        id: 'ov_c',
        startTimeSeconds: 0.0,
        durationSeconds: 5.0,
        zIndex: 1,
      );
      final ovInactive = VGOverlayDescriptor(
        id: 'ov_inact',
        startTimeSeconds: 6.0,
        durationSeconds: 2.0,
        zIndex: 0,
      );

      final resultsList = VGOverlayTransformEvaluator.evaluateOverlays(
        overlays: [ovA, ovB, ovC, ovInactive],
        ptsSeconds: 2.0,
      );

      final pass =
          resultsList.length == 3 &&
          resultsList[0].id == 'ov_b' &&
          resultsList[1].id == 'ov_c' &&
          resultsList[2].id == 'ov_a';

      results['lane_6_multi_overlay_sorting'] = pass;
    } catch (e) {
      results['lane_6_multi_overlay_sorting'] = false;
    }

    // Lane 7: Validation fail-closed and JSON roundtrip
    try {
      final kf = VGOverlayKeyframe(
        timeSeconds: 1.25,
        translationX: 33.0,
        scale: 1.4,
        interpolation: VGOverlayInterpolation.smoothstep,
      );
      final map = kf.toMap();
      final restored = VGOverlayKeyframe.fromMap(map);
      final jsonMatches = restored == kf;

      var duplicateThrew = false;
      try {
        VGOverlayTransformEvaluator.validateKeyframes([
          VGOverlayKeyframe(timeSeconds: 1.0),
          VGOverlayKeyframe(timeSeconds: 1.0),
        ], 3.0);
      } on ArgumentError {
        duplicateThrew = true;
      }

      results['lane_7_validation_and_json_roundtrip'] =
          jsonMatches && duplicateThrew;
    } catch (e) {
      results['lane_7_validation_and_json_roundtrip'] = false;
    }

    final passedCount = results.values.where((v) => v).length;
    final totalCount = results.length;
    final allPass = totalCount == 7 && passedCount == 7;

    print(
      'ANDROID_DAG_PHASE5_OVERLAY_KEYFRAME_INTERP_JSON:${jsonEncode(<String, Object?>{'totalLanes': totalCount, 'passedLanes': passedCount, 'allPass': allPass, 'results': results})}',
    );

    print(
      'ANDROID_DAG_PHASE5_OVERLAY_KEYFRAME_INTERP_SUMMARY: $passedCount/$totalCount lanes passed',
    );

    print(
      allPass
          ? 'ANDROID_DAG_PHASE5_OVERLAY_KEYFRAME_INTERP_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE5_OVERLAY_KEYFRAME_INTERP_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS ($passedCount/$totalCount overlay keyframe lanes verified)'
            : 'FAIL ($passedCount/$totalCount overlay keyframe lanes passed)';
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
          title: const Text(
            'Android Overlay Keyframe Smoke (P5-OVERLAYS-TRANS)',
          ),
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
