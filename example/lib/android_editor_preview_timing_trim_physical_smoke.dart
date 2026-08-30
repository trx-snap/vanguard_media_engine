// Vanguard Android True-DAG Phase 7.8: Public VGEditorController preview timing & trim verification.
//
// Proves Android public VGEditorController preview timing and trim semantics using public Dart API only:
//   - VGEditorPreviewReadinessEvaluator -> evaluates two-clip trimmed plain video draft as ready before initialize
//   - VGEditorController.initialize -> native createTimelineTexture with contiguous all-zero start time layout
//   - VGEditorTextureView -> renders editor timeline texture from VGEditorValue with aspect preservation
//   - VGEditorController.seek (intra-clip trimmed) -> seeks within first trimmed clip [0.0, 1.0)
//   - VGEditorController.seek (cross-clip trimmed) -> seeks across clip boundary into second clip [1.0, 2.0)
//   - VGEditorController.play / pause -> observes PTS progression in second clip (> 1.25 and < 2.1)
//   - VGEditorController.disposeAsyncConfirmed/dispose -> native disposeTimeline with confirmed teardown

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidEditorPreviewTimingTrimPhysicalSmokeApp());
}

class AndroidEditorPreviewTimingTrimPhysicalSmokeApp extends StatefulWidget {
  const AndroidEditorPreviewTimingTrimPhysicalSmokeApp({super.key});

  @override
  State<AndroidEditorPreviewTimingTrimPhysicalSmokeApp> createState() =>
      _AndroidEditorPreviewTimingTrimPhysicalSmokeAppState();
}

class _AndroidEditorPreviewTimingTrimPhysicalSmokeAppState
    extends State<AndroidEditorPreviewTimingTrimPhysicalSmokeApp> {
  String _status =
      'Initializing Android VGEditorController preview timing trim physical smoke…';
  VGEditorValue? _editorValue;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 1));

    File? tempFile1;
    File? tempFile2;
    VGEditorController? cleanupController;
    StreamSubscription<double>? ptsSubscription;
    final List<double> ptsValues = [];

    var readinessPass = false;
    var initPass = false;
    var presentationWidgetPass = false;
    var seekFirstClipPass = false;
    var seekSecondClipPass = false;
    var playSecondClipPass = false;
    var pausePass = false;
    var disposePass = false;
    var aspectPass = false;
    var durationPass = false;

    int? textureId;
    int? renderWidth;
    int? renderHeight;
    double? renderAspectRatio;
    double? draftDuration;

    double? ptsAfterSeek1;
    double? ptsAfterSeek2;
    double? ptsAfterPlay;
    String? errorMessage;

    Map<String, Object?>? readinessReportMap;
    VGEditorPreviewReadinessReport? readinessReport;

    try {
      // 0. Copy assets/manual_test_clips/clip_B.mov from rootBundle to two temp files
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      tempFile1 = File('${tempDir.path}/android_editor_timing_trim_1.mov');
      tempFile2 = File('${tempDir.path}/android_editor_timing_trim_2.mov');
      final bytesList = clipBytes.buffer.asUint8List(
        clipBytes.offsetInBytes,
        clipBytes.lengthInBytes,
      );
      await tempFile1.writeAsBytes(bytesList, flush: true);
      await tempFile2.writeAsBytes(bytesList, flush: true);

      const evaluator = VGEditorPreviewReadinessEvaluator();

      // 1. PRE-INIT READINESS EVALUATION (Two-clip direct trimmed video draft)
      print(
        'ANDROID_EDITOR_PREVIEW_TIMING_TRIM_STEP_PRE_INIT_READINESS: START',
      );
      final clip1 = VGClipDescriptor(
        id: 'clip_trim_1',
        mediaKind: VGMediaKind.video,
        sourcePath: tempFile1.path,
        durationSeconds: 3.0,
        trimStartSeconds: 0.5,
        trimEndSeconds: 1.5,
        startTimeSeconds: 0.0,
      );
      final clip2 = VGClipDescriptor(
        id: 'clip_trim_2',
        mediaKind: VGMediaKind.video,
        sourcePath: tempFile2.path,
        durationSeconds: 3.0,
        trimStartSeconds: 1.0,
        trimEndSeconds: 2.0,
        startTimeSeconds: 0.0,
      );

      final timingTrimDraft = VGEditorDraft(
        id: 'draft_preview_timing_trim',
        clips: [clip1, clip2],
        canvasWidth: 1280,
        canvasHeight: 720,
        fps: 30,
      );

      readinessReport = evaluator.evaluate(timingTrimDraft);
      readinessReportMap = readinessReport.toMap();
      readinessPass =
          readinessReport.canUseAndroidEditorPlaybackRoute &&
          readinessReport.decision == VGEditorPreviewReadinessDecision.ready &&
          readinessReport.issues.isEmpty &&
          readinessReport.diagnostics['clipCount'] == 2 &&
          readinessReport.diagnostics['issueCount'] == 0;

      if (!readinessPass) {
        throw Exception(
          'Readiness evaluation failed: decision=${readinessReport.decision.name}, '
          'canUse=${readinessReport.canUseAndroidEditorPlaybackRoute}, '
          'issues=${readinessReport.issues}, diagnostics=${readinessReport.diagnostics}',
        );
      }
      print('ANDROID_EDITOR_PREVIEW_TIMING_TRIM_STEP_PRE_INIT_READINESS: DONE');

      // 2. INIT CONTROLLER
      print('ANDROID_EDITOR_PREVIEW_TIMING_TRIM_STEP_INIT: START');
      final controller = VGEditorController(initialDraft: timingTrimDraft);
      cleanupController = controller;
      ptsSubscription = controller.ptsStream.listen((pts) {
        ptsValues.add(pts);
      });

      await controller.initialize().timeout(const Duration(seconds: 10));

      textureId = controller.textureId;
      renderWidth = controller.renderWidth;
      renderHeight = controller.renderHeight;
      renderAspectRatio = controller.renderAspectRatio;
      draftDuration = controller.value.draft.durationSeconds;

      aspectPass =
          renderWidth != null &&
          renderHeight != null &&
          renderWidth > 0 &&
          renderHeight > 0 &&
          renderHeight > renderWidth &&
          renderAspectRatio != null &&
          (renderAspectRatio - (1080.0 / 1920.0)).abs() < 0.02;

      durationPass = (draftDuration - 2.0).abs() < 0.01;

      initPass =
          (textureId != null &&
          textureId >= 0 &&
          controller.isReady &&
          aspectPass &&
          durationPass);

      if (!initPass) {
        throw Exception(
          'Init failed: textureId=$textureId, isReady=${controller.isReady}, '
          'renderWidth=$renderWidth, renderHeight=$renderHeight, '
          'aspectRatio=$renderAspectRatio, aspectPass=$aspectPass, '
          'draftDuration=$draftDuration, durationPass=$durationPass',
        );
      }

      presentationWidgetPass =
          controller.value.textureId != null &&
          controller.value.textureId! >= 0;

      if (mounted) {
        setState(() {
          _editorValue = controller.value;
          _status =
              'Initialized: textureId=$textureId (${renderWidth}x$renderHeight, duration=${draftDuration?.toStringAsFixed(2) ?? 'null'}s)';
        });
      }
      print('ANDROID_EDITOR_PREVIEW_TIMING_TRIM_STEP_INIT: DONE');

      // 3. SEEK TO 0.25s (First trimmed clip window)
      print('ANDROID_EDITOR_PREVIEW_TIMING_TRIM_STEP_SEEK_FIRST_CLIP: START');
      final seek1Completer = Completer<double>();
      final seek1Sub = controller.ptsStream.listen((pts) {
        if (!seek1Completer.isCompleted) {
          seek1Completer.complete(pts);
        }
      });

      await controller.seek(0.25);
      ptsAfterSeek1 = controller.currentPTS;

      try {
        await seek1Completer.future.timeout(const Duration(seconds: 2));
      } catch (_) {
        // stationary pause seek may not deliver new frame callback or was already set
      } finally {
        await seek1Sub.cancel();
      }

      seekFirstClipPass = (ptsAfterSeek1 >= 0.0 && ptsAfterSeek1 < 1.0);
      if (!seekFirstClipPass) {
        throw Exception(
          'First clip seek failed: currentPTS=$ptsAfterSeek1 (expected >= 0.0 and < 1.0)',
        );
      }
      if (mounted) {
        setState(() {
          _status = 'Seeked to 0.25s (currentPTS=$ptsAfterSeek1)';
        });
      }
      print('ANDROID_EDITOR_PREVIEW_TIMING_TRIM_STEP_SEEK_FIRST_CLIP: DONE');

      // 4. SEEK TO 1.25s (Cross-clip into second trimmed clip)
      print('ANDROID_EDITOR_PREVIEW_TIMING_TRIM_STEP_SEEK_SECOND_CLIP: START');
      final seek2Completer = Completer<double>();
      final seek2Sub = controller.ptsStream.listen((pts) {
        if (!seek2Completer.isCompleted) {
          seek2Completer.complete(pts);
        }
      });

      await controller.seek(1.25);
      ptsAfterSeek2 = controller.currentPTS;

      try {
        await seek2Completer.future.timeout(const Duration(seconds: 3));
      } catch (_) {
        // stationary pause seek
      } finally {
        await seek2Sub.cancel();
      }

      seekSecondClipPass = (ptsAfterSeek2 >= 1.0 && ptsAfterSeek2 < 2.0);
      if (!seekSecondClipPass) {
        throw Exception(
          'Cross-clip seek to 1.25s failed: currentPTS=$ptsAfterSeek2 (expected >= 1.0 and < 2.0)',
        );
      }
      if (mounted) {
        setState(() {
          _status = 'Cross-clip seek to 1.25s (currentPTS=$ptsAfterSeek2)';
        });
      }
      print('ANDROID_EDITOR_PREVIEW_TIMING_TRIM_STEP_SEEK_SECOND_CLIP: DONE');

      // 5. PLAY IN SECOND CLIP AND OBSERVE PTS > 1.25 AND < 2.1
      print('ANDROID_EDITOR_PREVIEW_TIMING_TRIM_STEP_PLAY_SECOND_CLIP: START');
      final playCompleter = Completer<double>();
      final playSub = controller.ptsStream.listen((pts) {
        if (pts > 1.25 && pts < 2.1 && !playCompleter.isCompleted) {
          playCompleter.complete(pts);
        }
      });

      await controller.play();
      if (!controller.isPlaying) {
        throw Exception('Play failed: controller.isPlaying is false');
      }

      ptsAfterPlay = await playCompleter.future
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'No PTS > 1.25 and < 2.1 received within 10s of play in second clip',
            ),
          )
          .whenComplete(() => playSub.cancel());

      await controller.pause();
      pausePass = !controller.isPlaying;
      playSecondClipPass =
          (ptsAfterPlay > 1.25 && ptsAfterPlay < 2.1 && pausePass);

      if (!playSecondClipPass) {
        throw Exception(
          'Play / pause in second clip failed: ptsAfterPlay=$ptsAfterPlay, pausePass=$pausePass',
        );
      }
      if (mounted) {
        setState(() {
          _status = 'Playback in second clip confirmed (PTS=$ptsAfterPlay)';
        });
      }
      print('ANDROID_EDITOR_PREVIEW_TIMING_TRIM_STEP_PLAY_SECOND_CLIP: DONE');

      // 6. DISPOSE
      print('ANDROID_EDITOR_PREVIEW_TIMING_TRIM_STEP_DISPOSE: START');
      await controller.disposeAsyncConfirmed().timeout(
        const Duration(seconds: 5),
      );
      controller.dispose();
      cleanupController = null;
      disposePass = true;
      print('ANDROID_EDITOR_PREVIEW_TIMING_TRIM_STEP_DISPOSE: DONE');
    } catch (e, st) {
      errorMessage = '$e';
      print('ANDROID_EDITOR_PREVIEW_TIMING_TRIM_ERROR: $e\n$st');
    } finally {
      await ptsSubscription?.cancel();
      if (cleanupController != null) {
        try {
          await cleanupController.disposeAsyncConfirmed();
        } catch (_) {}
        cleanupController.dispose();
      }
      if (tempFile1 != null && await tempFile1.exists()) {
        try {
          await tempFile1.delete();
        } catch (_) {}
      }
      if (tempFile2 != null && await tempFile2.exists()) {
        try {
          await tempFile2.delete();
        } catch (_) {}
      }
    }

    final overallPass =
        readinessPass &&
        initPass &&
        presentationWidgetPass &&
        seekFirstClipPass &&
        seekSecondClipPass &&
        playSecondClipPass &&
        pausePass &&
        disposePass;

    final jsonSummary = <String, dynamic>{
      'pass': overallPass,
      'readinessPass': readinessPass,
      'initPass': initPass,
      'presentationWidgetPass': presentationWidgetPass,
      'seekFirstClipPass': seekFirstClipPass,
      'seekSecondClipPass': seekSecondClipPass,
      'playSecondClipPass': playSecondClipPass,
      'pausePass': pausePass,
      'disposePass': disposePass,
      'readinessDecision': readinessReport?.decision.name,
      'readinessDiagnostics': readinessReport?.diagnostics,
      'readinessReport': readinessReportMap,
      'textureId': textureId,
      'renderWidth': renderWidth,
      'renderHeight': renderHeight,
      'renderAspectRatio': renderAspectRatio,
      'aspectPass': aspectPass,
      'draftDuration': draftDuration,
      'durationPass': durationPass,
      'ptsAfterSeek1': ptsAfterSeek1,
      'ptsAfterSeek2': ptsAfterSeek2,
      'ptsAfterPlay': ptsAfterPlay,
      'totalPtsCount': ptsValues.length,
      'error': errorMessage,
    };

    print(
      'ANDROID_EDITOR_PREVIEW_TIMING_TRIM_PHYSICAL_JSON:${jsonEncode(jsonSummary)}',
    );

    print(
      overallPass
          ? 'ANDROID_EDITOR_PREVIEW_TIMING_TRIM_PHYSICAL_PASS'
          : 'ANDROID_EDITOR_PREVIEW_TIMING_TRIM_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = overallPass
            ? 'PASS: Android VGEditorController preview timing & trim verified.'
            : 'FAIL: $errorMessage';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(overallPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_editorValue != null)
                SizedBox(
                  height: 360,
                  child: VGEditorTextureView(
                    value: _editorValue!,
                    fit: BoxFit.contain,
                    backgroundColor: Colors.black,
                  ),
                ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
