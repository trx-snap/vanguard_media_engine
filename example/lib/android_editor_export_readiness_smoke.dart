// android_editor_export_readiness_smoke.dart
// Vanguard Media Engine — Phase 5-Unit J
// Android VGEditor export readiness evaluator physical smoke harness.
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
  runApp(const AndroidEditorExportReadinessSmokeApp());
}

class AndroidEditorExportReadinessSmokeApp extends StatefulWidget {
  const AndroidEditorExportReadinessSmokeApp({super.key});

  @override
  State<AndroidEditorExportReadinessSmokeApp> createState() =>
      _AndroidEditorExportReadinessSmokeAppState();
}

class _AndroidEditorExportReadinessSmokeAppState
    extends State<AndroidEditorExportReadinessSmokeApp> {
  String _status =
      'Initializing Android VGEditor Export Readiness physical smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
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
    print('ANDROID_EXPORT_READINESS_UNIT_J: START');
    const evaluator = VGEditorExportReadinessEvaluator();
    final results = <String, bool>{};

    try {
      // ── Lane 1: READY_SINGLE_CLIP ──────────────────────────────────────────
      final lane1Draft = VGEditorDraft(
        id: 'draft-lane-1',
        clips: [_makeClip(id: 'c1')],
        canvasWidth: 1080,
        canvasHeight: 1920,
        fps: 30,
      );
      final lane1Report = evaluator.evaluate(draft: lane1Draft);
      final lane1Pass =
          lane1Report.isReady &&
          lane1Report.canUseAndroidEditorExportRoute &&
          !lane1Report.isBlocked &&
          lane1Report.issues.isEmpty &&
          lane1Report.diagnostics['clipCount'] == 1 &&
          lane1Report.diagnostics['resolvedWidth'] == 1080 &&
          lane1Report.diagnostics['resolvedHeight'] == 1920 &&
          lane1Report.diagnostics['resolvedFps'] == 30;
      results['LANE_1_READY_SINGLE_CLIP'] = lane1Pass;
      print(
        'ANDROID_EXPORT_READINESS_UNIT_J_LANE_1_READY_SINGLE_CLIP: ${lane1Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 2: READY_MULTI_CLIP ───────────────────────────────────────────
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
        canvasWidth: 720,
        canvasHeight: 1280,
        fps: 60,
      );
      final lane2Report = evaluator.evaluate(
        draft: lane2Draft,
        request: const VGEditorExportRequest(bitrateBps: 8000000),
      );
      final lane2Pass =
          lane2Report.isReady &&
          lane2Report.issues.isEmpty &&
          lane2Report.diagnostics['clipCount'] == 2 &&
          lane2Report.diagnostics['resolvedWidth'] == 720 &&
          lane2Report.diagnostics['resolvedHeight'] == 1280 &&
          lane2Report.diagnostics['resolvedFps'] == 60 &&
          lane2Report.diagnostics['requestedBitrateBps'] == 8000000;
      results['LANE_2_READY_MULTI_CLIP'] = lane2Pass;
      print(
        'ANDROID_EXPORT_READINESS_UNIT_J_LANE_2_READY_MULTI_CLIP: ${lane2Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 3: READY_AUDIO_SIDECAR ────────────────────────────────────────
      final lane3Draft = VGEditorDraft(
        id: 'draft-lane-3',
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
      final lane3Report = evaluator.evaluate(draft: lane3Draft);
      final lane3Pass =
          lane3Report.isReady &&
          lane3Report.issues.isEmpty &&
          lane3Report.diagnostics['hasAudioSidecarPlan'] == true;
      results['LANE_3_READY_AUDIO_SIDECAR'] = lane3Pass;
      print(
        'ANDROID_EXPORT_READINESS_UNIT_J_LANE_3_READY_AUDIO_SIDECAR: ${lane3Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 4: BLOCKED_UNSUPPORTED_CANVAS_CONTENT_MODE ────────────────────
      final lane4Draft = VGEditorDraft(
        id: 'draft-lane-4',
        clips: [_makeClip(id: 'c1')],
        canvas: VGCanvasDescriptor(
          width: 1080,
          height: 1920,
          contentMode: VGCanvasContentMode.fill,
        ),
      );
      final lane4Report = evaluator.evaluate(draft: lane4Draft);
      final lane4Pass =
          lane4Report.isBlocked &&
          !lane4Report.canUseAndroidEditorExportRoute &&
          lane4Report.issues.any(
            (i) =>
                i.code ==
                VGEditorExportReadinessIssueCode.unsupportedCanvasContentMode,
          );
      results['LANE_4_BLOCKED_UNSUPPORTED_CANVAS_CONTENT_MODE'] = lane4Pass;
      print(
        'ANDROID_EXPORT_READINESS_UNIT_J_LANE_4_BLOCKED_UNSUPPORTED_CANVAS_CONTENT_MODE: ${lane4Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 5: BLOCKED_ODD_REQUEST_DIMENSIONS ─────────────────────────────
      final lane5Draft = VGEditorDraft(
        id: 'draft-lane-5',
        clips: [_makeClip(id: 'c1')],
      );
      final lane5Report = evaluator.evaluate(
        draft: lane5Draft,
        request: const VGEditorExportRequest(width: 721, height: 1280),
      );
      final lane5Pass =
          lane5Report.isBlocked &&
          lane5Report.issues.any(
            (i) =>
                i.code ==
                VGEditorExportReadinessIssueCode.invalidRequestDimensions,
          );
      results['LANE_5_BLOCKED_ODD_REQUEST_DIMENSIONS'] = lane5Pass;
      print(
        'ANDROID_EXPORT_READINESS_UNIT_J_LANE_5_BLOCKED_ODD_REQUEST_DIMENSIONS: ${lane5Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 6: BLOCKED_INVALID_FPS_AND_BITRATE ────────────────────────────
      final lane6Draft = VGEditorDraft(
        id: 'draft-lane-6',
        clips: [_makeClip(id: 'c1')],
      );
      final lane6Report = evaluator.evaluate(
        draft: lane6Draft,
        request: const VGEditorExportRequest(fps: -1, bitrateBps: 0),
      );
      final lane6Pass =
          lane6Report.isBlocked &&
          lane6Report.issues.any(
            (i) => i.code == VGEditorExportReadinessIssueCode.invalidFps,
          ) &&
          lane6Report.issues.any(
            (i) => i.code == VGEditorExportReadinessIssueCode.invalidBitrate,
          );
      results['LANE_6_BLOCKED_INVALID_FPS_AND_BITRATE'] = lane6Pass;
      print(
        'ANDROID_EXPORT_READINESS_UNIT_J_LANE_6_BLOCKED_INVALID_FPS_AND_BITRATE: ${lane6Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 7: BLOCKED_TEMPORAL_DENOISE ───────────────────────────────────
      final lane7Draft = VGEditorDraft(
        id: 'draft-lane-7',
        clips: [_makeClip(id: 'c1')],
      );
      final lane7Report = evaluator.evaluate(
        draft: lane7Draft,
        request: const VGEditorExportRequest(temporalDenoiseEnabled: true),
      );
      final lane7Pass =
          lane7Report.isBlocked &&
          lane7Report.issues.any(
            (i) =>
                i.code ==
                VGEditorExportReadinessIssueCode.unsupportedTemporalDenoise,
          ) &&
          lane7Report.diagnostics['hasTemporalDenoiseRequest'] == true;
      results['LANE_7_BLOCKED_TEMPORAL_DENOISE'] = lane7Pass;
      print(
        'ANDROID_EXPORT_READINESS_UNIT_J_LANE_7_BLOCKED_TEMPORAL_DENOISE: ${lane7Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 8: BLOCKED_NON_LOCAL_AND_EMPTY_SOURCE ─────────────────────────
      final lane8Draft = VGEditorDraft(
        id: 'draft-lane-8',
        clips: [
          _makeClip(id: 'c-empty', sourcePath: ''),
          _makeClip(
            id: 'c-remote',
            sourcePath: 'https://cdn.example.com/stream.mp4',
          ),
          _makeClip(id: 'c-relative', sourcePath: 'relative/clip.mp4'),
        ],
      );
      final lane8Report = evaluator.evaluate(draft: lane8Draft);
      final lane8Pass =
          lane8Report.isBlocked &&
          lane8Report.issues.any(
            (i) => i.code == VGEditorExportReadinessIssueCode.emptySourcePath,
          ) &&
          lane8Report.issues
                  .where(
                    (i) =>
                        i.code ==
                        VGEditorExportReadinessIssueCode.nonLocalSourcePath,
                  )
                  .length ==
              2;
      results['LANE_8_BLOCKED_NON_LOCAL_AND_EMPTY_SOURCE'] = lane8Pass;
      print(
        'ANDROID_EXPORT_READINESS_UNIT_J_LANE_8_BLOCKED_NON_LOCAL_AND_EMPTY_SOURCE: ${lane8Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 9: BLOCKED_PER_CLIP_EFFECTS ───────────────────────────────────
      final lane9Draft = VGEditorDraft(
        id: 'draft-lane-9',
        clips: [
          _makeClip(id: 'c-speed', speed: 1.5),
          _makeClip(id: 'c-rev', isReversed: true),
          _makeClip(
            id: 'c-xform',
            transform: const VGClipTransformDescriptor(
              scaleX: 1.2,
              scaleY: 1.2,
            ),
          ),
          _makeClip(id: 'c-crop', cropRect: const [0.1, 0.1, 0.8, 0.8]),
          _makeClip(id: 'c-freeze', freezePTS: 1.0),
          _makeClip(
            id: 'c-dual',
            dualCamera: VGDualCameraDescriptor(
              primaryClip: _makeClip(id: 'c-pri'),
              secondaryClip: _makeClip(
                id: 'c-sec',
                sourcePath: '/data/sec.mp4',
              ),
            ),
          ),
          _makeClip(
            id: 'c-remap',
            timeRemap: VGTimeRemapDescriptor(
              segments: const [
                VGSpeedSegmentDescriptor(
                  sourceStartTime: 0.0,
                  sourceDuration: 5.0,
                  speedMultiplier: 2.0,
                ),
              ],
            ),
          ),
          _makeClip(
            id: 'c-track',
            transformTrack: VGTransformTrackDescriptor(
              keyframes: const [
                VGTransformKeyframeDescriptor(
                  timeUs: 0,
                  scaleX: 1.0,
                  scaleY: 1.0,
                ),
              ],
            ),
          ),
          _makeClip(id: 'c-matrix', colorMatrix: List<double>.filled(20, 0.0)),
        ],
      );
      final lane9Report = evaluator.evaluate(draft: lane9Draft);
      final lane9ExpectedCodes = {
        VGEditorExportReadinessIssueCode.unsupportedSpeed,
        VGEditorExportReadinessIssueCode.reversedClipPresent,
        VGEditorExportReadinessIssueCode.clipTransformPresent,
        VGEditorExportReadinessIssueCode.stillImageFitOrCropPresent,
        VGEditorExportReadinessIssueCode.freezeFramePresent,
        VGEditorExportReadinessIssueCode.dualCameraPresent,
        VGEditorExportReadinessIssueCode.timeRemapPresent,
        VGEditorExportReadinessIssueCode.transformTrackPresent,
        VGEditorExportReadinessIssueCode.colorMatrixPresent,
      };
      final lane9ActualCodes = lane9Report.issues.map((i) => i.code).toSet();
      final lane9Pass =
          lane9Report.isBlocked &&
          lane9ExpectedCodes.every((c) => lane9ActualCodes.contains(c));
      results['LANE_9_BLOCKED_PER_CLIP_EFFECTS'] = lane9Pass;
      print(
        'ANDROID_EXPORT_READINESS_UNIT_J_LANE_9_BLOCKED_PER_CLIP_EFFECTS: ${lane9Pass ? "PASS" : "FAIL"}',
      );

      // ── Lane 10: BLOCKED_TRANSITIONS_AND_OVERLAYS ──────────────────────────
      final lane10Draft = VGEditorDraft(
        id: 'draft-lane-10',
        clips: [
          _makeClip(id: 'c1'),
          _makeClip(id: 'c2', sourcePath: '/data/c2.mp4'),
        ],
        transitions: const [
          VGTransitionDescriptor(
            id: 'tr-1',
            type: VGTransitionType.dissolve,
            durationSeconds: 1.0,
            fromClipId: 'c1',
            toClipId: 'c2',
          ),
        ],
        overlays: [
          VGOverlayDescriptor(
            id: 'ov-1',
            type: VGOverlayType.text,
            textContent: 'Sample Overlay',
            startTimeSeconds: 0.0,
            durationSeconds: 2.0,
          ),
        ],
      );
      final lane10Report = evaluator.evaluate(draft: lane10Draft);
      final lane10Pass =
          lane10Report.isBlocked &&
          lane10Report.issues.any(
            (i) =>
                i.code == VGEditorExportReadinessIssueCode.transitionsPresent,
          ) &&
          lane10Report.issues.any(
            (i) => i.code == VGEditorExportReadinessIssueCode.overlaysPresent,
          ) &&
          lane10Report.diagnostics['transitionCount'] == 1 &&
          lane10Report.diagnostics['overlayCount'] == 1;
      results['LANE_10_BLOCKED_TRANSITIONS_AND_OVERLAYS'] = lane10Pass;
      print(
        'ANDROID_EXPORT_READINESS_UNIT_J_LANE_10_BLOCKED_TRANSITIONS_AND_OVERLAYS: ${lane10Pass ? "PASS" : "FAIL"}',
      );
    } catch (e, st) {
      print('ANDROID_EXPORT_READINESS_UNIT_J_ERROR: $e\n$st');
    }

    final int passedCount = results.values.where((v) => v).length;
    final int totalCount = results.length;
    final bool allPass = totalCount == 10 && passedCount == 10;

    print(
      'ANDROID_EXPORT_READINESS_UNIT_J_JSON:${jsonEncode(<String, Object?>{'totalLanes': totalCount, 'passedLanes': passedCount, 'allPass': allPass, 'results': results})}',
    );

    print(
      'ANDROID_EXPORT_READINESS_UNIT_J_SUMMARY: $passedCount/$totalCount lanes passed',
    );

    print(
      allPass
          ? 'ANDROID_EXPORT_READINESS_UNIT_J_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_EXPORT_READINESS_UNIT_J_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS ($passedCount/$totalCount export readiness lanes verified)'
            : 'FAIL ($passedCount/$totalCount export readiness lanes passed)';
      });
    }

    // Exit process after marker so runner finishes cleanly
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(allPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Android Export Readiness Smoke (Unit J)'),
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
