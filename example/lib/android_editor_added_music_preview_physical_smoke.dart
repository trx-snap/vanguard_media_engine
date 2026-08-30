// Vanguard Android True-DAG: Added-music preview physical smoke test.
//
// Proves Android public VGEditorController preview playback with a single-clip added music sidecar:
//   - Copies real video (clip_B.mov) and audio (clip_A.mp3) assets to temporary files
//   - Constructs a single-clip VGEditorDraft with VGAudioSidecarPlan (role='music', volume=0.8, startTime=0.0)
//   - Initializes VGEditorController, validating textureId and render dimensions
//   - Plays and observes positive timeline PTS
//   - Seeks to 0.8s with resumeAfterSeek=true
//   - Pauses and performs confirmed teardown/disposal
//
// Dart asserts structural/mechanical behavior; logcat validates native MediaPlayer lifecycle.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidEditorAddedMusicPreviewPhysicalSmokeApp());
}

class AndroidEditorAddedMusicPreviewPhysicalSmokeApp extends StatefulWidget {
  const AndroidEditorAddedMusicPreviewPhysicalSmokeApp({super.key});

  @override
  State<AndroidEditorAddedMusicPreviewPhysicalSmokeApp> createState() =>
      _AndroidEditorAddedMusicPreviewPhysicalSmokeAppState();
}

class _AndroidEditorAddedMusicPreviewPhysicalSmokeAppState
    extends State<AndroidEditorAddedMusicPreviewPhysicalSmokeApp> {
  String _status =
      'Initializing Android VGEditorController added-music preview physical smoke…';
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

    File? tempVideoFile;
    File? tempMusicFile;
    VGEditorController? cleanupController;
    StreamSubscription<double>? ptsSubscription;
    final List<double> ptsValues = [];

    var sourcePreparePass = false;
    var initPass = false;
    var playPass = false;
    var seekPass = false;
    var pausePass = false;
    var disposePass = false;

    int? textureId;
    int? renderWidth;
    int? renderHeight;
    double? renderAspectRatio;
    double? draftDuration;

    double? firstPositivePts;
    double? ptsAfterSeek;
    String? errorMessage;

    final runId = DateTime.now().millisecondsSinceEpoch;

    try {
      // 1. PREPARE SOURCES
      print('ANDROID_EDITOR_ADDED_MUSIC_PREVIEW_STEP_SOURCE_PREPARE: START');
      final tempDir = Directory.systemTemp;
      tempVideoFile = File('${tempDir.path}/android_editor_video_$runId.mov');
      tempMusicFile = File('${tempDir.path}/android_editor_music_$runId.mp3');

      final videoBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      await tempVideoFile.writeAsBytes(
        videoBytes.buffer.asUint8List(
          videoBytes.offsetInBytes,
          videoBytes.lengthInBytes,
        ),
        flush: true,
      );

      final musicBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_A.mp3',
      );
      await tempMusicFile.writeAsBytes(
        musicBytes.buffer.asUint8List(
          musicBytes.offsetInBytes,
          musicBytes.lengthInBytes,
        ),
        flush: true,
      );

      if (!await tempVideoFile.exists() || !await tempMusicFile.exists()) {
        throw Exception(
          'Failed to write temp video or music files to ${tempDir.path}',
        );
      }

      const timelineDuration = 2.5;
      final videoClip = VGClipDescriptor(
        id: 'clip_video_main',
        mediaKind: VGMediaKind.video,
        sourcePath: tempVideoFile.path,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: timelineDuration,
        startTimeSeconds: 0.0,
      );

      final musicTrack = VGAudioSidecarTrack(
        trackId: 'android_added_music_preview',
        url: tempMusicFile.path,
        startTime: 0.0,
        duration: timelineDuration,
        volume: 0.8,
        role: 'music',
      );

      final draft = VGEditorDraft(
        id: 'draft_added_music_preview_$runId',
        clips: [videoClip],
        canvasWidth: 720,
        canvasHeight: 1280,
        fps: 30,
        audioSidecarPlan: VGAudioSidecarPlan(tracks: [musicTrack]),
      );

      sourcePreparePass = true;
      print('ANDROID_EDITOR_ADDED_MUSIC_PREVIEW_STEP_SOURCE_PREPARE: DONE');

      // 2. INIT CONTROLLER
      print('ANDROID_EDITOR_ADDED_MUSIC_PREVIEW_STEP_INIT: START');
      final controller = VGEditorController(initialDraft: draft);
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

      initPass =
          (textureId != null &&
          textureId >= 0 &&
          controller.isReady &&
          renderWidth != null &&
          renderWidth > 0 &&
          renderHeight != null &&
          renderHeight > 0);

      if (!initPass) {
        throw Exception(
          'Init failed: textureId=$textureId, isReady=${controller.isReady}, '
          'renderWidth=$renderWidth, renderHeight=$renderHeight',
        );
      }

      if (mounted) {
        setState(() {
          _editorValue = controller.value;
          _status =
              'Initialized: textureId=$textureId (${renderWidth}x$renderHeight, duration=${draftDuration?.toStringAsFixed(2) ?? 'null'}s)';
        });
      }
      print('ANDROID_EDITOR_ADDED_MUSIC_PREVIEW_STEP_INIT: DONE');

      // 3. PLAY AND OBSERVE POSITIVE PTS
      print('ANDROID_EDITOR_ADDED_MUSIC_PREVIEW_STEP_PLAY: START');
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

      playPass = (firstPositivePts > 0.0 && controller.isPlaying);
      if (!playPass) {
        throw Exception(
          'Play verification failed: firstPositivePts=$firstPositivePts',
        );
      }

      // Wait briefly for native playback logs to emit
      await Future<void>.delayed(const Duration(milliseconds: 600));

      if (mounted) {
        setState(() {
          _status = 'Playing (first positive PTS=$firstPositivePts)';
        });
      }
      print('ANDROID_EDITOR_ADDED_MUSIC_PREVIEW_STEP_PLAY: DONE');

      // 4. SEEK TO 0.8s WITH RESUME
      print('ANDROID_EDITOR_ADDED_MUSIC_PREVIEW_STEP_SEEK: START');
      final seekCompleter = Completer<double>();
      final seekSub = controller.ptsStream.listen((pts) {
        if (pts >= 0.75 && !seekCompleter.isCompleted) {
          seekCompleter.complete(pts);
        }
      });

      await controller.seek(0.8, resumeAfterSeek: true);
      ptsAfterSeek = controller.currentPTS;

      try {
        await seekCompleter.future.timeout(const Duration(seconds: 4));
      } catch (_) {
        // Stationary or advancing
      } finally {
        await seekSub.cancel();
      }

      seekPass = (ptsAfterSeek >= 0.7 && ptsAfterSeek <= 2.5);
      if (!seekPass) {
        throw Exception(
          'Seek failed: currentPTS=$ptsAfterSeek (expected ~0.8s)',
        );
      }

      // Allow brief playback after seek
      await Future<void>.delayed(const Duration(milliseconds: 600));

      if (mounted) {
        setState(() {
          _status = 'Seeked to 0.8s (currentPTS=$ptsAfterSeek)';
        });
      }
      print('ANDROID_EDITOR_ADDED_MUSIC_PREVIEW_STEP_SEEK: DONE');

      // 5. PAUSE AND DISPOSE
      print('ANDROID_EDITOR_ADDED_MUSIC_PREVIEW_STEP_PAUSE_DISPOSE: START');
      await controller.pause();
      pausePass = !controller.isPlaying;
      if (!pausePass) {
        throw Exception('Pause failed: controller.isPlaying is true');
      }

      await controller.disposeAsyncConfirmed().timeout(
        const Duration(seconds: 5),
      );
      controller.dispose();
      cleanupController = null;
      disposePass = true;
      print('ANDROID_EDITOR_ADDED_MUSIC_PREVIEW_STEP_PAUSE_DISPOSE: DONE');
    } catch (e, st) {
      errorMessage = '$e';
      print('ANDROID_EDITOR_ADDED_MUSIC_PREVIEW_ERROR: $e\n$st');
    } finally {
      await ptsSubscription?.cancel();
      if (cleanupController != null) {
        try {
          await cleanupController.disposeAsyncConfirmed();
        } catch (_) {}
        cleanupController.dispose();
      }
      if (tempVideoFile != null && await tempVideoFile.exists()) {
        try {
          await tempVideoFile.delete();
        } catch (_) {}
      }
      if (tempMusicFile != null && await tempMusicFile.exists()) {
        try {
          await tempMusicFile.delete();
        } catch (_) {}
      }
    }

    final overallPass =
        sourcePreparePass &&
        initPass &&
        playPass &&
        seekPass &&
        pausePass &&
        disposePass;

    final jsonSummary = <String, dynamic>{
      'pass': overallPass,
      'sourcePreparePass': sourcePreparePass,
      'initPass': initPass,
      'playPass': playPass,
      'seekPass': seekPass,
      'pausePass': pausePass,
      'disposePass': disposePass,
      'textureId': textureId,
      'renderWidth': renderWidth,
      'renderHeight': renderHeight,
      'renderAspectRatio': renderAspectRatio,
      'draftDuration': draftDuration,
      'firstPositivePts': firstPositivePts,
      'ptsAfterSeek': ptsAfterSeek,
      'totalPtsCount': ptsValues.length,
      'error': errorMessage,
    };

    print('ANDROID_EDITOR_ADDED_MUSIC_PREVIEW_JSON:${jsonEncode(jsonSummary)}');
    print(
      overallPass
          ? 'ANDROID_EDITOR_ADDED_MUSIC_PREVIEW_PHYSICAL_PASS'
          : 'ANDROID_EDITOR_ADDED_MUSIC_PREVIEW_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = overallPass
            ? 'PASS: Android VGEditorController added-music preview verified.'
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
