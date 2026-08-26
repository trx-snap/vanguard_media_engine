// Vanguard Android True-DAG Phase 7.8G: Public VGEditorController sequential multi-clip playback route verification.
//
// Proves Android public VGEditorController routes work for sequential multi-clip plain video drafts using public Dart API only:
//   - VGEditorPreviewReadinessEvaluator -> evaluates two-clip plain video draft as ready before initialize
//   - VGEditorController.initialize -> native createTimelineTexture with cumulative multi-clip duration
//   - VGEditorTextureView -> renders editor timeline texture from VGEditorValue with aspect preservation
//   - VGEditorController.play -> native timelinePlay, observing positive PTS in first clip
//   - VGEditorController.seek (intra-clip) -> seeks within first clip
//   - VGEditorController.seek (cross-clip) -> seeks across clip boundary into second clip
//   - VGEditorController.play (after boundary) -> continues playback in second clip beyond boundary
//   - VGEditorController.disposeAsyncConfirmed/dispose -> native disposeTimeline with confirmed teardown

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidEditorControllerPlaybackPhysicalSmokeApp());
}

class AndroidEditorControllerPlaybackPhysicalSmokeApp extends StatefulWidget {
  const AndroidEditorControllerPlaybackPhysicalSmokeApp({super.key});

  @override
  State<AndroidEditorControllerPlaybackPhysicalSmokeApp> createState() =>
      _AndroidEditorControllerPlaybackPhysicalSmokeAppState();
}

class _AndroidEditorControllerPlaybackPhysicalSmokeAppState
    extends State<AndroidEditorControllerPlaybackPhysicalSmokeApp> {
  String _status =
      'Initializing Android VGEditorController playback physical smoke…';
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
    var playPass = false;
    var pausePass = false;
    var intraSeekPass = false;
    var crossSeekPass = false;
    var playAfterBoundaryPass = false;
    var disposePass = false;

    int? textureId;
    int? renderWidth;
    int? renderHeight;
    double? renderAspectRatio;
    var aspectPass = false;

    double? firstPositivePts;
    double? ptsAfterIntraSeek;
    double? currentPtsAfterCrossSeek;
    double? ptsAfterBoundary;
    String? errorMessage;

    Map<String, Object?>? readinessReportMap;
    VGEditorPreviewReadinessReport? readinessReport;

    try {
      // 0. Copy assets/manual_test_clips/clip_B.mov from rootBundle to two temp files
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      tempFile1 = File('${tempDir.path}/android_editor_multi_clip_1.mov');
      tempFile2 = File('${tempDir.path}/android_editor_multi_clip_2.mov');
      final bytesList = clipBytes.buffer.asUint8List(
        clipBytes.offsetInBytes,
        clipBytes.lengthInBytes,
      );
      await tempFile1.writeAsBytes(bytesList, flush: true);
      await tempFile2.writeAsBytes(bytesList, flush: true);

      const evaluator = VGEditorPreviewReadinessEvaluator();

      // 1. PRE-INIT READINESS EVALUATION (Two-clip plain video draft)
      print(
        'ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_PRE_INIT_READINESS: START',
      );
      final clip1 = VGClipDescriptor(
        id: 'clip_multi_1',
        mediaKind: VGMediaKind.video,
        sourcePath: tempFile1.path,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
        startTimeSeconds: 0.0,
      );
      final clip2 = VGClipDescriptor(
        id: 'clip_multi_2',
        mediaKind: VGMediaKind.video,
        sourcePath: tempFile2.path,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
        startTimeSeconds: 3.0,
      );

      final multiClipDraft = VGEditorDraft(
        id: 'draft_multi_clip_sequential',
        clips: [clip1, clip2],
        canvasWidth: 1280,
        canvasHeight: 720,
        fps: 30,
      );

      readinessReport = evaluator.evaluate(multiClipDraft);
      readinessReportMap = readinessReport.toMap();
      readinessPass =
          readinessReport.canUseAndroidEditorPlaybackRoute &&
          readinessReport.decision == VGEditorPreviewReadinessDecision.ready &&
          readinessReport.issues.isEmpty &&
          readinessReport.diagnostics['clipCount'] == 2 &&
          readinessReport.diagnostics['issueCount'] == 0;

      if (!readinessPass) {
        throw Exception(
          'Multi-clip pre-init readiness evaluation failed: decision=${readinessReport.decision.name}, '
          'canUse=${readinessReport.canUseAndroidEditorPlaybackRoute}, '
          'issues=${readinessReport.issues}, diagnostics=${readinessReport.diagnostics}',
        );
      }
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_PRE_INIT_READINESS: DONE');

      // 2. INIT MULTI-CLIP CONTROLLER
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_INIT: START');
      final controller = VGEditorController(initialDraft: multiClipDraft);
      cleanupController = controller;
      ptsSubscription = controller.ptsStream.listen((pts) {
        ptsValues.add(pts);
      });

      await controller.initialize().timeout(const Duration(seconds: 10));

      textureId = controller.textureId;
      renderWidth = controller.renderWidth;
      renderHeight = controller.renderHeight;
      renderAspectRatio = controller.renderAspectRatio;

      aspectPass =
          renderWidth != null &&
          renderHeight != null &&
          renderWidth > 0 &&
          renderHeight > 0 &&
          renderHeight > renderWidth &&
          renderAspectRatio != null &&
          (renderAspectRatio - (1080.0 / 1920.0)).abs() < 0.02;

      initPass =
          (textureId != null &&
          textureId >= 0 &&
          controller.isReady &&
          aspectPass);

      if (!initPass) {
        throw Exception(
          'Multi-clip init failed: textureId=$textureId, isReady=${controller.isReady}, '
          'renderWidth=$renderWidth, renderHeight=$renderHeight, '
          'aspectRatio=$renderAspectRatio, aspectPass=$aspectPass',
        );
      }

      presentationWidgetPass =
          controller.value.textureId != null &&
          controller.value.textureId! >= 0;

      if (mounted) {
        setState(() {
          _editorValue = controller.value;
          _status =
              'Initialized: textureId=$textureId (${renderWidth}x$renderHeight, 2 clips)';
        });
      }
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_INIT: DONE');

      // 3. PLAY AND OBSERVE POSITIVE PTS
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_PLAY: START');
      final positivePtsCompleter = Completer<double>();
      final playSub = controller.ptsStream.listen((pts) {
        if (pts > 0.0 && !positivePtsCompleter.isCompleted) {
          positivePtsCompleter.complete(pts);
        }
      });

      await controller.play();
      if (!controller.isPlaying) {
        throw Exception('Play failed: controller.isPlaying is false');
      }

      firstPositivePts = await positivePtsCompleter.future
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'No positive PTS received within 10s of play',
            ),
          )
          .whenComplete(() => playSub.cancel());

      await controller.pause();
      pausePass = !controller.isPlaying;
      playPass = (firstPositivePts > 0.0 && pausePass);

      if (!playPass) {
        throw Exception(
          'Play / pause failed: firstPositivePts=$firstPositivePts, pausePass=$pausePass',
        );
      }
      if (mounted) {
        setState(() {
          _status = 'Played clip 1: firstPositivePts=$firstPositivePts';
        });
      }
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_PLAY: DONE');

      // 4. SEEK WITHIN FIRST CLIP (Intra-clip seek)
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_INTRA_CLIP_SEEK: START');
      final intraSeekCompleter = Completer<double>();
      final intraSeekSub = controller.ptsStream.listen((pts) {
        if (!intraSeekCompleter.isCompleted) {
          intraSeekCompleter.complete(pts);
        }
      });

      await controller.seek(1.0);
      ptsAfterIntraSeek = controller.currentPTS;

      try {
        await intraSeekCompleter.future.timeout(const Duration(seconds: 2));
      } catch (_) {
        // stationary pause seek may not deliver new frame callback or was already set
      } finally {
        await intraSeekSub.cancel();
      }

      intraSeekPass = (ptsAfterIntraSeek >= 0.9 && ptsAfterIntraSeek < 2.9);
      if (!intraSeekPass) {
        throw Exception(
          'Intra-clip seek failed: currentPTS=$ptsAfterIntraSeek (expected ~1.0 in clip 1)',
        );
      }
      if (mounted) {
        setState(() {
          _status = 'Intra-clip seek to 1.0s (currentPTS=$ptsAfterIntraSeek)';
        });
      }
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_INTRA_CLIP_SEEK: DONE');

      // 5. SEEK ACROSS CLIP BOUNDARY INTO SECOND CLIP (Inter-clip seek)
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_CROSS_CLIP_SEEK: START');
      final crossSeekCompleter = Completer<double>();
      final crossSeekSub = controller.ptsStream.listen((pts) {
        if (!crossSeekCompleter.isCompleted) {
          crossSeekCompleter.complete(pts);
        }
      });

      // Seek to 4.0s (clip 0 is ~3.0s, so 4.0s is in clip 1, beyond boundary)
      await controller.seek(4.0);
      currentPtsAfterCrossSeek = controller.currentPTS;

      try {
        await crossSeekCompleter.future.timeout(const Duration(seconds: 3));
      } catch (_) {
        // stationary pause seek
      } finally {
        await crossSeekSub.cancel();
      }

      crossSeekPass = (currentPtsAfterCrossSeek >= 3.0);
      if (!crossSeekPass) {
        throw Exception(
          'Cross-clip seek failed: currentPTS=$currentPtsAfterCrossSeek (expected >= 3.0 in clip 2)',
        );
      }
      if (mounted) {
        setState(() {
          _status =
              'Cross-clip seek to 4.0s (currentPTS=$currentPtsAfterCrossSeek)';
        });
      }
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_CROSS_CLIP_SEEK: DONE');

      // 6. PLAY AFTER BOUNDARY (Continue playback in second clip)
      print(
        'ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_PLAY_AFTER_BOUNDARY: START',
      );
      final boundaryPlayCompleter = Completer<double>();
      final boundaryPlaySub = controller.ptsStream.listen((pts) {
        if (pts > 3.0 && !boundaryPlayCompleter.isCompleted) {
          boundaryPlayCompleter.complete(pts);
        }
      });

      await controller.play();
      if (!controller.isPlaying) {
        throw Exception(
          'Play after boundary failed: controller.isPlaying is false',
        );
      }

      ptsAfterBoundary = await boundaryPlayCompleter.future
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'No PTS > 3.0 received within 10s of play after boundary',
            ),
          )
          .whenComplete(() => boundaryPlaySub.cancel());

      await controller.pause();
      playAfterBoundaryPass = (ptsAfterBoundary > 3.0 && !controller.isPlaying);

      if (!playAfterBoundaryPass) {
        throw Exception(
          'Play after boundary failed: ptsAfterBoundary=$ptsAfterBoundary, isPlaying=${controller.isPlaying}',
        );
      }
      if (mounted) {
        setState(() {
          _status = 'Playback in clip 2 confirmed (PTS=$ptsAfterBoundary)';
        });
      }
      print(
        'ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_PLAY_AFTER_BOUNDARY: DONE',
      );

      // 7. DISPOSE
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_DISPOSE: START');
      await controller.disposeAsyncConfirmed().timeout(
        const Duration(seconds: 5),
      );
      controller.dispose();
      cleanupController = null;
      disposePass = true;
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_DISPOSE: DONE');
    } catch (e, st) {
      errorMessage = '$e';
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_ERROR: $e\n$st');
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
        playPass &&
        intraSeekPass &&
        crossSeekPass &&
        playAfterBoundaryPass &&
        disposePass;

    final jsonSummary = <String, dynamic>{
      'pass': overallPass,
      'readinessPass': readinessPass,
      'initPass': initPass,
      'presentationWidgetPass': presentationWidgetPass,
      'playPass': playPass,
      'intraSeekPass': intraSeekPass,
      'crossSeekPass': crossSeekPass,
      'playAfterBoundaryPass': playAfterBoundaryPass,
      'disposePass': disposePass,
      'readinessDecision': readinessReport?.decision.name,
      'readinessDiagnostics': readinessReport?.diagnostics,
      'readinessReport': readinessReportMap,
      'textureId': textureId,
      'renderWidth': renderWidth,
      'renderHeight': renderHeight,
      'renderAspectRatio': renderAspectRatio,
      'aspectPass': aspectPass,
      'firstPositivePts': firstPositivePts,
      'ptsAfterIntraSeek': ptsAfterIntraSeek,
      'currentPtsAfterCrossSeek': currentPtsAfterCrossSeek,
      'ptsAfterBoundary': ptsAfterBoundary,
      'totalPtsCount': ptsValues.length,
      'error': errorMessage,
    };

    print(
      'ANDROID_EDITOR_CONTROLLER_PLAYBACK_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(jsonSummary)}',
    );

    print(
      overallPass
          ? 'ANDROID_EDITOR_CONTROLLER_PLAYBACK_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_EDITOR_CONTROLLER_PLAYBACK_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = overallPass
            ? 'PASS: Android VGEditorController sequential multi-clip playback routes verified.'
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
