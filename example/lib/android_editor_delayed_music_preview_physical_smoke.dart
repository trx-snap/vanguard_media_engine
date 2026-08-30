// Vanguard Android True-DAG: Delayed-music preview physical smoke test.
//
// Proves Android public VGEditorController preview playback with a single-clip delayed music sidecar:
//   - Copies real video (clip_B.mov) and audio (clip_A.mp3) assets to temporary files
//   - Constructs a single-clip VGEditorDraft with VGAudioSidecarTrack (role='music', startTime=0.8, duration=1.0, volume=0.8)
//   - Initializes VGEditorController, validating textureId and render dimensions
//   - Plays continuously past delayed start (0.8s) and track end (1.8s) up to PTS >= 2.05s
//   - Seeks inside the music window (1.2s) with resumeAfterSeek=true
//   - Seeks past the music window (2.2s) with resumeAfterSeek=true
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
  runApp(const AndroidEditorDelayedMusicPreviewPhysicalSmokeApp());
}

class AndroidEditorDelayedMusicPreviewPhysicalSmokeApp extends StatefulWidget {
  const AndroidEditorDelayedMusicPreviewPhysicalSmokeApp({super.key});

  @override
  State<AndroidEditorDelayedMusicPreviewPhysicalSmokeApp> createState() =>
      _AndroidEditorDelayedMusicPreviewPhysicalSmokeAppState();
}

class _AndroidEditorDelayedMusicPreviewPhysicalSmokeAppState
    extends State<AndroidEditorDelayedMusicPreviewPhysicalSmokeApp> {
  String _status =
      'Initializing Android VGEditorController delayed-music preview physical smoke…';
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
    var delayedPlayPass = false;
    var seekInsidePass = false;
    var seekPastPass = false;
    var disposePass = false;

    int? textureId;
    int? renderWidth;
    int? renderHeight;
    double? renderAspectRatio;
    double? draftDuration;

    double? ptsReachedInDelayedPlay;
    double? ptsAfterSeekInside;
    double? ptsAfterSeekPast;
    String? errorMessage;

    final runId = DateTime.now().millisecondsSinceEpoch;
    final trackId = 'android_delayed_music_preview_$runId';

    try {
      // 1. PREPARE SOURCES
      print('ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_STEP_SOURCE_PREPARE: START');
      final tempDir = Directory.systemTemp;
      tempVideoFile = File('${tempDir.path}/android_delayed_video_$runId.mov');
      tempMusicFile = File('${tempDir.path}/android_delayed_music_$runId.mp3');

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

      const timelineDuration = 3.0;
      final videoClip = VGClipDescriptor(
        id: 'clip_video_main_$runId',
        mediaKind: VGMediaKind.video,
        sourcePath: tempVideoFile.path,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: timelineDuration,
        startTimeSeconds: 0.0,
      );

      final musicTrack = VGAudioSidecarTrack(
        trackId: trackId,
        url: tempMusicFile.path,
        startTime: 0.8,
        duration: 1.0,
        volume: 0.8,
        role: 'music',
      );

      final draft = VGEditorDraft(
        id: 'draft_delayed_music_preview_$runId',
        clips: [videoClip],
        canvasWidth: 720,
        canvasHeight: 1280,
        fps: 30,
        audioSidecarPlan: VGAudioSidecarPlan(tracks: [musicTrack]),
      );

      sourcePreparePass = true;
      print('ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_STEP_SOURCE_PREPARE: DONE');

      // 2. INIT CONTROLLER
      print('ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_STEP_INIT: START');
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
      print('ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_STEP_INIT: DONE');

      // 3. CONTINUOUS DELAYED-START PLAY LANE (advance past 0.8s and 1.8s to >= 2.05s)
      print('ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_STEP_DELAYED_PLAY: START');
      final delayedPlayCompleter = Completer<double>();
      final delayedPlaySub = controller.ptsStream.listen((pts) {
        if (pts >= 2.05 && !delayedPlayCompleter.isCompleted) {
          delayedPlayCompleter.complete(pts);
        }
      });

      await controller.play();
      if (!controller.isPlaying) {
        throw Exception('Play failed: controller.isPlaying is false');
      }

      ptsReachedInDelayedPlay = await delayedPlayCompleter.future
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException(
              'PTS did not reach >= 2.05s within 15s of play (currentPTS=${controller.currentPTS})',
            ),
          )
          .whenComplete(() => delayedPlaySub.cancel());

      await controller.pause();
      delayedPlayPass =
          (ptsReachedInDelayedPlay >= 2.05 && !controller.isPlaying);
      if (!delayedPlayPass) {
        throw Exception(
          'Delayed play verification failed: ptsReachedInDelayedPlay=$ptsReachedInDelayedPlay',
        );
      }

      // Allow brief pause settle
      await Future<void>.delayed(const Duration(milliseconds: 400));

      if (mounted) {
        setState(() {
          _status =
              'Delayed play reached PTS=$ptsReachedInDelayedPlay (paused)';
        });
      }
      print('ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_STEP_DELAYED_PLAY: DONE');

      // 4. SEEK-INSIDE LANE (seek to 1.2s with resumeAfterSeek=true)
      print('ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_STEP_SEEK_INSIDE: START');
      final seekInsideCompleter = Completer<double>();
      final seekInsideSub = controller.ptsStream.listen((pts) {
        if (pts >= 1.25 && !seekInsideCompleter.isCompleted) {
          seekInsideCompleter.complete(pts);
        }
      });

      await controller.seek(1.2, resumeAfterSeek: true);
      ptsAfterSeekInside = controller.currentPTS;

      try {
        await seekInsideCompleter.future.timeout(const Duration(seconds: 4));
      } catch (_) {
        // Advancing or stationary
      } finally {
        await seekInsideSub.cancel();
      }

      // Allow brief playback after seek inside
      await Future<void>.delayed(const Duration(milliseconds: 600));

      await controller.pause();
      seekInsidePass = (ptsAfterSeekInside >= 1.1 && ptsAfterSeekInside <= 3.0);
      if (!seekInsidePass) {
        throw Exception(
          'Seek inside failed: ptsAfterSeekInside=$ptsAfterSeekInside (expected ~1.2s)',
        );
      }

      if (mounted) {
        setState(() {
          _status =
              'Seeked inside window to 1.2s (currentPTS=$ptsAfterSeekInside)';
        });
      }
      print('ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_STEP_SEEK_INSIDE: DONE');

      // 5. SEEK-PAST LANE (seek to 2.2s with resumeAfterSeek=true)
      print('ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_STEP_SEEK_PAST: START');
      await controller.seek(2.2, resumeAfterSeek: true);
      ptsAfterSeekPast = controller.currentPTS;

      // Allow brief settle
      await Future<void>.delayed(const Duration(milliseconds: 600));

      await controller.pause();
      seekPastPass = (ptsAfterSeekPast >= 2.0 && ptsAfterSeekPast <= 3.0);
      if (!seekPastPass) {
        throw Exception(
          'Seek past failed: ptsAfterSeekPast=$ptsAfterSeekPast (expected ~2.2s)',
        );
      }

      if (mounted) {
        setState(() {
          _status = 'Seeked past window to 2.2s (currentPTS=$ptsAfterSeekPast)';
        });
      }
      print('ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_STEP_SEEK_PAST: DONE');

      // 6. DISPOSE
      print('ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_STEP_DISPOSE: START');
      await controller.disposeAsyncConfirmed().timeout(
        const Duration(seconds: 5),
      );
      controller.dispose();
      cleanupController = null;
      disposePass = true;
      print('ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_STEP_DISPOSE: DONE');
    } catch (e, st) {
      errorMessage = '$e';
      print('ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_ERROR: $e\n$st');
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
        delayedPlayPass &&
        seekInsidePass &&
        seekPastPass &&
        disposePass;

    final jsonSummary = <String, dynamic>{
      'pass': overallPass,
      'runId': runId,
      'trackId': trackId,
      'sourcePreparePass': sourcePreparePass,
      'initPass': initPass,
      'delayedPlayPass': delayedPlayPass,
      'seekInsidePass': seekInsidePass,
      'seekPastPass': seekPastPass,
      'disposePass': disposePass,
      'textureId': textureId,
      'renderWidth': renderWidth,
      'renderHeight': renderHeight,
      'renderAspectRatio': renderAspectRatio,
      'draftDuration': draftDuration,
      'ptsReachedInDelayedPlay': ptsReachedInDelayedPlay,
      'ptsAfterSeekInside': ptsAfterSeekInside,
      'ptsAfterSeekPast': ptsAfterSeekPast,
      'totalPtsCount': ptsValues.length,
      'error': errorMessage,
    };

    print(
      'ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_JSON:${jsonEncode(jsonSummary)}',
    );
    print(
      overallPass
          ? 'ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_PHYSICAL_PASS'
          : 'ANDROID_EDITOR_DELAYED_MUSIC_PREVIEW_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = overallPass
            ? 'PASS: Android VGEditorController delayed-music preview verified.'
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
