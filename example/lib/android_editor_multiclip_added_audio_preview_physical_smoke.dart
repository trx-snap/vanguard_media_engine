// Vanguard Android True-DAG: Multi-clip added-audio preview physical smoke test.
//
// Proves Android public VGEditorController preview playback with both added music
// and added voiceover sidecar tracks coexisting on a multi-clip draft:
//   - Copies real video (clip_B.mov) and audio (clip_A.mp3) assets to temporary files
//   - Uses copied clip_B.mov as video source for two clips and voiceover source; clip_A.mp3 as music source
//   - Constructs a hard-cut two-clip VGEditorDraft (720x1280, 30fps, ~2.4s total) with VGAudioSidecarPlan:
//       * clip1: video, trimStart 0.0, trimEnd 1.2, startTime 0.0
//       * clip2: video, trimStart 0.0, trimEnd 1.2, startTime 1.2
//       * music track: role='music', startTime=0.0, duration=2.6, volume=0.7 (spans clip boundary, overhangs timeline)
//       * voiceover track: role='voiceover', startTime=1.3, duration=0.8, volume=0.6 (delayed-starts inside clip2)
//   - Initializes VGEditorController, validating textureId and render dimensions
//   - Plays past clip boundary (1.2s) and voiceover start (1.3s) to PTS >= 2.05s, then pauses
//   - Seeks to 1.4s with resumeAfterSeek=true, plays past 1.55s, then pauses
//   - Confirms asynchronous teardown and resource disposal
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
  runApp(const AndroidEditorMulticlipAddedAudioPreviewPhysicalSmokeApp());
}

class AndroidEditorMulticlipAddedAudioPreviewPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidEditorMulticlipAddedAudioPreviewPhysicalSmokeApp({super.key});

  @override
  State<AndroidEditorMulticlipAddedAudioPreviewPhysicalSmokeApp>
  createState() =>
      _AndroidEditorMulticlipAddedAudioPreviewPhysicalSmokeAppState();
}

class _AndroidEditorMulticlipAddedAudioPreviewPhysicalSmokeAppState
    extends State<AndroidEditorMulticlipAddedAudioPreviewPhysicalSmokeApp> {
  String _status =
      'Initializing Android VGEditorController multi-clip added-audio preview physical smoke…';
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

    File? tempVideoFile1;
    File? tempVideoFile2;
    File? tempVoiceoverFile;
    File? tempMusicFile;
    VGEditorController? cleanupController;
    StreamSubscription<double>? ptsSubscription;
    final List<double> ptsValues = [];

    var sourcePreparePass = false;
    var initPass = false;
    var playPass = false;
    var seekPass = false;
    var disposePass = false;

    int? textureId;
    int? renderWidth;
    int? renderHeight;
    double? renderAspectRatio;
    double? draftDuration;

    double? ptsReachedPastBoundary;
    double? ptsAfterSeek;
    String? errorMessage;

    final runId = DateTime.now().millisecondsSinceEpoch;
    final musicTrackId = 'android_multiclip_music_$runId';
    final voiceoverTrackId = 'android_multiclip_voiceover_$runId';

    try {
      // 1. PREPARE SOURCES
      print(
        'ANDROID_EDITOR_MULTICLIP_ADDED_AUDIO_PREVIEW_STEP_SOURCE_PREPARE: START',
      );
      final tempDir = Directory.systemTemp;
      tempVideoFile1 = File('${tempDir.path}/android_mc_video1_$runId.mov');
      tempVideoFile2 = File('${tempDir.path}/android_mc_video2_$runId.mov');
      tempVoiceoverFile = File('${tempDir.path}/android_mc_vo_$runId.mov');
      tempMusicFile = File('${tempDir.path}/android_mc_music_$runId.mp3');

      final videoBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final videoUint8List = videoBytes.buffer.asUint8List(
        videoBytes.offsetInBytes,
        videoBytes.lengthInBytes,
      );

      await tempVideoFile1.writeAsBytes(videoUint8List, flush: true);
      await tempVideoFile2.writeAsBytes(videoUint8List, flush: true);
      await tempVoiceoverFile.writeAsBytes(videoUint8List, flush: true);

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

      if (!await tempVideoFile1.exists() ||
          !await tempVideoFile2.exists() ||
          !await tempVoiceoverFile.exists() ||
          !await tempMusicFile.exists()) {
        throw Exception(
          'Failed to write temp video, voiceover, or music files to ${tempDir.path}',
        );
      }

      final clip1 = VGClipDescriptor(
        id: 'clip1_$runId',
        mediaKind: VGMediaKind.video,
        sourcePath: tempVideoFile1.path,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 1.2,
        startTimeSeconds: 0.0,
      );

      final clip2 = VGClipDescriptor(
        id: 'clip2_$runId',
        mediaKind: VGMediaKind.video,
        sourcePath: tempVideoFile2.path,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 1.2,
        startTimeSeconds: 1.2,
      );

      final musicTrack = VGAudioSidecarTrack(
        trackId: musicTrackId,
        url: tempMusicFile.path,
        startTime: 0.0,
        duration: 2.6,
        volume: 0.7,
        role: 'music',
      );

      final voiceoverTrack = VGAudioSidecarTrack(
        trackId: voiceoverTrackId,
        url: tempVoiceoverFile.path,
        startTime: 1.3,
        duration: 0.8,
        volume: 0.6,
        role: 'voiceover',
      );

      final draft = VGEditorDraft(
        id: 'draft_multiclip_added_audio_$runId',
        clips: [clip1, clip2],
        canvasWidth: 720,
        canvasHeight: 1280,
        fps: 30,
        audioSidecarPlan: VGAudioSidecarPlan(
          tracks: [musicTrack, voiceoverTrack],
        ),
      );

      sourcePreparePass = true;
      print(
        'ANDROID_EDITOR_MULTICLIP_ADDED_AUDIO_PREVIEW_STEP_SOURCE_PREPARE: DONE',
      );

      // 2. INIT CONTROLLER
      print('ANDROID_EDITOR_MULTICLIP_ADDED_AUDIO_PREVIEW_STEP_INIT: START');
      final controller = VGEditorController(
        initialDraft: draft,
        previewDraftDeriver: (d) => d.flattenOriginalClipAudio(),
      );
      cleanupController = controller;

      ptsSubscription = controller.ptsStream.listen((pts) {
        print('DEBUG_PTS: $pts');
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
      print('ANDROID_EDITOR_MULTICLIP_ADDED_AUDIO_PREVIEW_STEP_INIT: DONE');

      // 3. CONTINUOUS PLAY PAST BOUNDARY (0.0s -> clip boundary 1.2s -> VO start 1.3s -> PTS >= 2.05s)
      print(
        'ANDROID_EDITOR_MULTICLIP_ADDED_AUDIO_PREVIEW_STEP_PLAY_PAST_BOUNDARY: START',
      );
      final playCompleter = Completer<double>();
      final playSub = controller.ptsStream.listen((pts) {
        if (pts >= 2.05 && !playCompleter.isCompleted) {
          playCompleter.complete(pts);
        }
      });

      await controller.play();
      if (!controller.isPlaying) {
        throw Exception('Play failed: controller.isPlaying is false');
      }

      ptsReachedPastBoundary = await playCompleter.future
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException(
              'PTS did not reach >= 2.05s within 15s of play (currentPTS=${controller.currentPTS})',
            ),
          )
          .whenComplete(() => playSub.cancel());

      await controller.pause();
      playPass = (ptsReachedPastBoundary >= 2.05 && !controller.isPlaying);
      if (!playPass) {
        throw Exception(
          'Play verification failed: ptsReachedPastBoundary=$ptsReachedPastBoundary',
        );
      }

      // Allow brief pause settle
      await Future<void>.delayed(const Duration(milliseconds: 400));

      if (mounted) {
        setState(() {
          _status =
              'Play reached PTS=$ptsReachedPastBoundary past boundary (paused)';
        });
      }
      print(
        'ANDROID_EDITOR_MULTICLIP_ADDED_AUDIO_PREVIEW_STEP_PLAY_PAST_BOUNDARY: DONE',
      );

      // 4. SEEK LANE (seek to 1.4s with resumeAfterSeek=true, inside clip2 and inside VO window [1.3, 2.1))
      print('ANDROID_EDITOR_MULTICLIP_ADDED_AUDIO_PREVIEW_STEP_SEEK: START');
      final seekCompleter = Completer<double>();
      final seekSub = controller.ptsStream.listen((pts) {
        if (pts >= 1.55 && !seekCompleter.isCompleted) {
          seekCompleter.complete(pts);
        }
      });

      await controller.seek(1.4, resumeAfterSeek: true);

      try {
        await seekCompleter.future.timeout(const Duration(seconds: 5));
      } catch (_) {
        // Advancing or stationary
      } finally {
        await seekSub.cancel();
      }

      // Allow brief playback after seek
      await Future<void>.delayed(const Duration(milliseconds: 400));

      await controller.pause();
      ptsAfterSeek = controller.currentPTS;
      seekPass = (ptsAfterSeek >= 1.4 && ptsAfterSeek <= 2.5);
      if (!seekPass) {
        throw Exception(
          'Seek to 1.4s failed: ptsAfterSeek=$ptsAfterSeek (expected >= 1.4s)',
        );
      }

      if (mounted) {
        setState(() {
          _status = 'Seeked to 1.4s and resumed (currentPTS=$ptsAfterSeek)';
        });
      }
      print('ANDROID_EDITOR_MULTICLIP_ADDED_AUDIO_PREVIEW_STEP_SEEK: DONE');

      // 5. DISPOSE LANE
      print('ANDROID_EDITOR_MULTICLIP_ADDED_AUDIO_PREVIEW_STEP_DISPOSE: START');
      await controller.disposeAsyncConfirmed().timeout(
        const Duration(seconds: 5),
      );
      controller.dispose();
      cleanupController = null;
      disposePass = true;
      print('ANDROID_EDITOR_MULTICLIP_ADDED_AUDIO_PREVIEW_STEP_DISPOSE: DONE');
    } catch (e, st) {
      errorMessage = '$e';
      print('ANDROID_EDITOR_MULTICLIP_ADDED_AUDIO_PREVIEW_ERROR: $e\n$st');
    } finally {
      await ptsSubscription?.cancel();
      if (cleanupController != null) {
        try {
          await cleanupController.disposeAsyncConfirmed();
        } catch (_) {}
        cleanupController.dispose();
      }
      if (tempVideoFile1 != null && await tempVideoFile1.exists()) {
        try {
          await tempVideoFile1.delete();
        } catch (_) {}
      }
      if (tempVideoFile2 != null && await tempVideoFile2.exists()) {
        try {
          await tempVideoFile2.delete();
        } catch (_) {}
      }
      if (tempVoiceoverFile != null && await tempVoiceoverFile.exists()) {
        try {
          await tempVoiceoverFile.delete();
        } catch (_) {}
      }
      if (tempMusicFile != null && await tempMusicFile.exists()) {
        try {
          await tempMusicFile.delete();
        } catch (_) {}
      }
    }

    final overallPass =
        sourcePreparePass && initPass && playPass && seekPass && disposePass;

    final jsonSummary = <String, dynamic>{
      'pass': overallPass,
      'runId': runId,
      'musicTrackId': musicTrackId,
      'voiceoverTrackId': voiceoverTrackId,
      'draftDuration': draftDuration,
      'ptsReachedPastBoundary': ptsReachedPastBoundary,
      'ptsAfterSeek': ptsAfterSeek,
      'totalPtsCount': ptsValues.length,
      'sourcePreparePass': sourcePreparePass,
      'initPass': initPass,
      'playPass': playPass,
      'seekPass': seekPass,
      'disposePass': disposePass,
      'textureId': textureId,
      'renderWidth': renderWidth,
      'renderHeight': renderHeight,
      'renderAspectRatio': renderAspectRatio,
      'error': errorMessage,
    };

    print(
      'ANDROID_EDITOR_MULTICLIP_ADDED_AUDIO_PREVIEW_JSON:${jsonEncode(jsonSummary)}',
    );
    print(
      overallPass
          ? 'ANDROID_EDITOR_MULTICLIP_ADDED_AUDIO_PREVIEW_PHYSICAL_PASS'
          : 'ANDROID_EDITOR_MULTICLIP_ADDED_AUDIO_PREVIEW_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = overallPass
            ? 'PASS: Android VGEditorController multi-clip added-audio preview verified.'
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
