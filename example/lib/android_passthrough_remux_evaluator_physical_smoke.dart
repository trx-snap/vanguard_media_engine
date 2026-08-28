// android_passthrough_remux_evaluator_physical_smoke.dart
// Vanguard Media Engine — Phase 2-Unit W
// Android PassthroughRemuxSinkNode direct-copy preflight evaluator physical smoke harness.
//
// Pure Dart preflight evaluation verification on physical Android device.
// Zero MethodChannel calls, zero file I/O, zero native state mutation.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidPassthroughRemuxEvaluatorPhysicalSmokeApp());
}

class AndroidPassthroughRemuxEvaluatorPhysicalSmokeApp extends StatefulWidget {
  const AndroidPassthroughRemuxEvaluatorPhysicalSmokeApp({super.key});

  @override
  State<AndroidPassthroughRemuxEvaluatorPhysicalSmokeApp> createState() =>
      _AndroidPassthroughRemuxEvaluatorPhysicalSmokeAppState();
}

class _AndroidPassthroughRemuxEvaluatorPhysicalSmokeAppState
    extends State<AndroidPassthroughRemuxEvaluatorPhysicalSmokeApp> {
  String _status =
      'Initializing Android Passthrough Remux Evaluator physical smoke…';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 30), () {
      print(
        'ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W: TIMEOUT (30s exceeded)',
      );
      print('ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W_PHYSICAL_FAIL');
      exit(1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  VGClipDescriptor _makeClip({
    String id = 'clip-1',
    String sourcePath = '/data/user/0/com.connects.vanguard/cache/clip1.mp4',
    VGMediaKind mediaKind = VGMediaKind.video,
    double startTimeSeconds = 0.0,
    double durationSeconds = 10.0,
    double trimStartSeconds = 0.0,
    double trimEndSeconds = 10.0,
    double speed = 1.0,
    VGClipTransformDescriptor? transform,
    VGStillImageFitMode fitMode = VGStillImageFitMode.fit,
    List<double>? cropRect,
    double? freezePTS,
    bool isReversed = false,
    VGDualCameraDescriptor? dualCamera,
    VGTimeRemapDescriptor? timeRemap,
    VGTransformTrackDescriptor? transformTrack,
    List<double>? colorMatrix,
  }) {
    return VGClipDescriptor(
      id: id,
      sourcePath: sourcePath,
      mediaKind: mediaKind,
      startTimeSeconds: startTimeSeconds,
      durationSeconds: durationSeconds,
      trimStartSeconds: trimStartSeconds,
      trimEndSeconds: trimEndSeconds,
      speed: speed,
      transform: transform,
      fitMode: fitMode,
      cropRect: cropRect,
      freezePTS: freezePTS,
      isReversed: isReversed,
      dualCamera: dualCamera,
      timeRemap: timeRemap,
      transformTrack: transformTrack,
      colorMatrix: colorMatrix,
    );
  }

  Future<void> _runSmoke() async {
    print('ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W: START');
    const evaluator = VGPassthroughRemuxEvaluator();
    final results = <String, bool>{};

    try {
      // ── Lane 1: ELIGIBLE_SINGLE_MP4 ─────────────────────────────────────────
      final lane1Draft = VGEditorDraft(
        id: 'draft-lane-1',
        clips: [_makeClip(id: 'c1')],
        canvasWidth: 1080,
        canvasHeight: 1920,
        fps: 30,
      );
      final lane1Report = evaluator.evaluate(
        draft: lane1Draft,
        request: const VGEditorExportRequest(
          outputPath: '/data/user/0/com.connects.vanguard/cache/export.mp4',
        ),
      );
      final lane1Pass =
          lane1Report.isEligible &&
          lane1Report.canUseAndroidPassthroughRemux &&
          !lane1Report.isIneligible &&
          lane1Report.issues.isEmpty &&
          lane1Report.diagnostics['clipCount'] == 1 &&
          lane1Report.diagnostics['resolvedWidth'] == 1080 &&
          lane1Report.diagnostics['resolvedHeight'] == 1920 &&
          lane1Report.diagnostics['resolvedFps'] == 30 &&
          lane1Report.diagnostics['resolvedContainerFormat'] == 'mp4' &&
          lane1Report.diagnostics['requestHasOutputPath'] == true;
      results['LANE_1_ELIGIBLE_SINGLE_MP4'] = lane1Pass;
      print(
        'ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W_LANE_1_ELIGIBLE_SINGLE_MP4: ${lane1Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 2: BLOCKED_MULTI_CLIP ──────────────────────────────────────────
      final lane2Draft = VGEditorDraft(
        id: 'draft-lane-2',
        clips: [
          _makeClip(id: 'c1', durationSeconds: 5.0, trimEndSeconds: 5.0),
          _makeClip(
            id: 'c2',
            sourcePath: '/data/user/0/com.connects.vanguard/cache/clip2.mp4',
            startTimeSeconds: 5.0,
            durationSeconds: 5.0,
            trimEndSeconds: 5.0,
          ),
        ],
        canvasWidth: 1080,
        canvasHeight: 1920,
        fps: 30,
      );
      final lane2Report = evaluator.evaluate(draft: lane2Draft);
      final lane2Pass =
          lane2Report.isIneligible &&
          !lane2Report.canUseAndroidPassthroughRemux &&
          lane2Report.issues.any(
            (i) => i.code == VGPassthroughRemuxIssueCode.multiClip,
          );
      results['LANE_2_BLOCKED_MULTI_CLIP'] = lane2Pass;
      print(
        'ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W_LANE_2_BLOCKED_MULTI_CLIP: ${lane2Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 3: BLOCKED_RESIZE ──────────────────────────────────────────────
      final lane3Draft = VGEditorDraft(
        id: 'draft-lane-3',
        clips: [_makeClip(id: 'c1')],
        canvasWidth: 1080,
        canvasHeight: 1920,
        fps: 30,
      );
      final lane3Report = evaluator.evaluate(
        draft: lane3Draft,
        request: const VGEditorExportRequest(width: 720, height: 1280),
      );
      final lane3Pass =
          lane3Report.isIneligible &&
          !lane3Report.canUseAndroidPassthroughRemux &&
          lane3Report.issues.any(
            (i) =>
                i.code ==
                VGPassthroughRemuxIssueCode.incompatibleOutputDimensions,
          );
      results['LANE_3_BLOCKED_RESIZE'] = lane3Pass;
      print(
        'ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W_LANE_3_BLOCKED_RESIZE: ${lane3Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 4: BLOCKED_BITRATE ─────────────────────────────────────────────
      final lane4Draft = VGEditorDraft(
        id: 'draft-lane-4',
        clips: [_makeClip(id: 'c1')],
      );
      final lane4Report = evaluator.evaluate(
        draft: lane4Draft,
        request: const VGEditorExportRequest(bitrateBps: 8000000),
      );
      final lane4Pass =
          lane4Report.isIneligible &&
          lane4Report.issues.any(
            (i) =>
                i.code ==
                VGPassthroughRemuxIssueCode.unsupportedBitrateOverride,
          );
      results['LANE_4_BLOCKED_BITRATE'] = lane4Pass;
      print(
        'ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W_LANE_4_BLOCKED_BITRATE: ${lane4Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 5: BLOCKED_AUDIO_SIDECAR ───────────────────────────────────────
      final lane5Draft = VGEditorDraft(
        id: 'draft-lane-5',
        clips: [_makeClip(id: 'c1')],
        audioSidecarPlan: VGAudioSidecarPlan(
          tracks: const [
            VGAudioSidecarTrack(
              trackId: 'bgm-1',
              url: '/data/user/0/com.connects.vanguard/cache/bgm.m4a',
              startTime: 0.0,
              duration: 10.0,
            ),
          ],
        ),
      );
      final lane5Report = evaluator.evaluate(draft: lane5Draft);
      final lane5Pass =
          lane5Report.isIneligible &&
          lane5Report.issues.any(
            (i) =>
                i.code == VGPassthroughRemuxIssueCode.audioSidecarPlanPresent,
          ) &&
          lane5Report.diagnostics['hasAudioSidecarPlan'] == true;
      results['LANE_5_BLOCKED_AUDIO_SIDECAR'] = lane5Pass;
      print(
        'ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W_LANE_5_BLOCKED_AUDIO_SIDECAR: ${lane5Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 6: BLOCKED_UNSUPPORTED_EXTENSION ───────────────────────────────
      final lane6Draft = VGEditorDraft(
        id: 'draft-lane-6',
        clips: [_makeClip(id: 'c1')],
      );
      final lane6Report = evaluator.evaluate(
        draft: lane6Draft,
        request: const VGEditorExportRequest(outputPath: '/data/export.mov'),
      );
      final lane6Pass =
          lane6Report.isIneligible &&
          lane6Report.issues.any(
            (i) =>
                i.code ==
                VGPassthroughRemuxIssueCode.incompatibleContainerFormat,
          ) &&
          lane6Report.diagnostics['resolvedContainerFormat'] == 'unsupported';
      results['LANE_6_BLOCKED_UNSUPPORTED_EXTENSION'] = lane6Pass;
      print(
        'ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W_LANE_6_BLOCKED_UNSUPPORTED_EXTENSION: ${lane6Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 7: DIAGNOSTICS_NON_CLAIMS ──────────────────────────────────────
      final lane7Draft = VGEditorDraft(
        id: 'draft-lane-7',
        clips: [_makeClip(id: 'c1')],
      );
      final lane7Report = evaluator.evaluate(draft: lane7Draft);
      final nonClaims =
          lane7Report.diagnostics['nonClaims'] as Map<String, bool>? ??
          const {};
      final lane7Pass =
          lane7Report.proofBoundary ==
              'passthrough_remux_preflight_advisory_no_file_io_no_native_mux' &&
          nonClaims['nativeMuxExecuted'] == false &&
          nonClaims['mediaExtractorOpened'] == false &&
          nonClaims['mediaMuxerStarted'] == false &&
          nonClaims['sourceFileRead'] == false &&
          nonClaims['outputFileWritten'] == false &&
          nonClaims['codecAllocated'] == false;
      results['LANE_7_DIAGNOSTICS_NON_CLAIMS'] = lane7Pass;
      print(
        'ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W_LANE_7_DIAGNOSTICS_NON_CLAIMS: ${lane7Pass ? "PASS" : "FAIL"}',
      );
    } catch (e, st) {
      print('ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W_ERROR: $e\n$st');
    }

    final int passedCount = results.values.where((v) => v).length;
    final int totalCount = results.length;
    final bool allPass = totalCount == 7 && passedCount == 7;

    print(
      'ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W_JSON:${jsonEncode(<String, Object?>{'totalLanes': totalCount, 'passedLanes': passedCount, 'allPass': allPass, 'results': results})}',
    );

    print(
      'ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W_SUMMARY: $passedCount/$totalCount lanes passed',
    );

    print(
      allPass
          ? 'ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W_PHYSICAL_PASS'
          : 'ANDROID_PASSTHROUGH_REMUX_EVALUATOR_UNIT_W_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS ($passedCount/$totalCount passthrough remux evaluator lanes verified)'
            : 'FAIL ($passedCount/$totalCount passthrough remux evaluator lanes passed)';
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(allPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Passthrough Remux Evaluator Smoke (Unit W)'),
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
