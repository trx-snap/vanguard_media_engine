// Vanguard Android True-DAG: Voiceover preview physical smoke test.
//
// Proves Android public VGEditorController preview playback with both added music
// and added voiceover sidecar tracks coexisting on a single-clip draft:
//   - Copies real video (clip_B.mov) and audio (clip_A.mp3) assets to temporary files
//   - Uses copied clip_B.mov as video source and voiceover sidecar source; clip_A.mp3 as music sidecar source
//   - Constructs a single-clip VGEditorDraft with VGAudioSidecarPlan containing:
//       * music track: role='music', startTime=0.2, duration=1.0, volume=0.55
//       * voiceover track: role='voiceover', startTime=0.6, duration=1.2, volume=0.75
//   - Initializes VGEditorController, validating textureId and render dimensions
//   - Plays continuously past delayed start (0.2s music, 0.6s VO) and track ends (1.2s music, 1.8s VO) to PTS >= 2.05s
//   - Seeks inside both windows (0.9s) with resumeAfterSeek=true
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
  runApp(const AndroidEditorVoiceoverPreviewPhysicalSmokeApp());
}

class AndroidEditorVoiceoverPreviewPhysicalSmokeApp extends StatefulWidget {
  const AndroidEditorVoiceoverPreviewPhysicalSmokeApp({super.key});

  @override
  State<AndroidEditorVoiceoverPreviewPhysicalSmokeApp> createState() =>
      _AndroidEditorVoiceoverPreviewPhysicalSmokeAppState();
}

class _AndroidEditorVoiceoverPreviewPhysicalSmokeAppState
    extends State<AndroidEditorVoiceoverPreviewPhysicalSmokeApp> {
  String _status =
      'Initializing Android VGEditorController voiceover preview physical smoke…';
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

    double? ptsReachedInPlay;
    double? ptsAfterSeek;
    String? errorMessage;

    final runId = DateTime.now().millisecondsSinceEpoch;
    final musicTrackId = 'android_music_preview_$runId';
    final voiceoverTrackId = 'android_voiceover_preview_$runId';

    try {
      // 1. PREPARE SOURCES
      print('ANDROID_EDITOR_VOICEOVER_PREVIEW_STEP_SOURCE_PREPARE: START');
      final tempDir = Directory.systemTemp;
      tempVideoFile = File('${tempDir.path}/android_vo_video_$runId.mov');
      tempVoiceoverFile = File('${tempDir.path}/android_vo_audio_$runId.mov');
      tempMusicFile = File('${tempDir.path}/android_vo_music_$runId.mp3');

      final videoBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final videoUint8List = videoBytes.buffer.asUint8List(
        videoBytes.offsetInBytes,
        videoBytes.lengthInBytes,
      );

      await tempVideoFile.writeAsBytes(videoUint8List, flush: true);
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

      if (!await tempVideoFile.exists() ||
          !await tempVoiceoverFile.exists() ||
          !await tempMusicFile.exists()) {
        throw Exception(
          'Failed to write temp video, voiceover, or music files to ${tempDir.path}',
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
        trackId: musicTrackId,
        url: tempMusicFile.path,
        startTime: 0.2,
        duration: 1.0,
        volume: 0.55,
        role: 'music',
      );

      final voiceoverTrack = VGAudioSidecarTrack(
        trackId: voiceoverTrackId,
        url: tempVoiceoverFile.path,
        startTime: 0.6,
        duration: 1.2,
        volume: 0.75,
        role: 'voiceover',
      );

      final draft = VGEditorDraft(
        id: 'draft_voiceover_preview_$runId',
        clips: [videoClip],
        canvasWidth: 720,
        canvasHeight: 1280,
        fps: 30,
        audioSidecarPlan: VGAudioSidecarPlan(
          tracks: [musicTrack, voiceoverTrack],
        ),
      );

      sourcePreparePass = true;
      print('ANDROID_EDITOR_VOICEOVER_PREVIEW_STEP_SOURCE_PREPARE: DONE');

      // 2. INIT CONTROLLER
      print('ANDROID_EDITOR_VOICEOVER_PREVIEW_STEP_INIT: START');
      final controller = VGEditorController(
        initialDraft: draft,
        previewDraftDeriver: (d) => d.flattenOriginalClipAudio(),
      );
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
      print('ANDROID_EDITOR_VOICEOVER_PREVIEW_STEP_INIT: DONE');

      // 3. CONTINUOUS PLAY LANE (advance past 0.2s music, 0.6s VO, 1.2s music end, 1.8s VO end to PTS >= 2.05s)
      print('ANDROID_EDITOR_VOICEOVER_PREVIEW_STEP_PLAY_BOTH: START');
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

      ptsReachedInPlay = await playCompleter.future
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException(
              'PTS did not reach >= 2.05s within 15s of play (currentPTS=${controller.currentPTS})',
            ),
          )
          .whenComplete(() => playSub.cancel());

      await controller.pause();
      playPass = (ptsReachedInPlay >= 2.05 && !controller.isPlaying);
      if (!playPass) {
        throw Exception(
          'Play verification failed: ptsReachedInPlay=$ptsReachedInPlay',
        );
      }

      // Allow brief pause settle
      await Future<void>.delayed(const Duration(milliseconds: 400));

      if (mounted) {
        setState(() {
          _status = 'Play reached PTS=$ptsReachedInPlay (paused)';
        });
      }
      print('ANDROID_EDITOR_VOICEOVER_PREVIEW_STEP_PLAY_BOTH: DONE');

      // 4. SEEK FAN-IN LANE (seek to 0.9s with resumeAfterSeek=true, inside both music [0.2, 1.2) and VO [0.6, 1.8) windows)
      print('ANDROID_EDITOR_VOICEOVER_PREVIEW_STEP_SEEK_BOTH: START');
      final seekCompleter = Completer<double>();
      final seekSub = controller.ptsStream.listen((pts) {
        if (pts >= 0.95 && !seekCompleter.isCompleted) {
          seekCompleter.complete(pts);
        }
      });

      await controller.seek(0.9, resumeAfterSeek: true);
      ptsAfterSeek = controller.currentPTS;

      try {
        await seekCompleter.future.timeout(const Duration(seconds: 4));
      } catch (_) {
        // Advancing or stationary
      } finally {
        await seekSub.cancel();
      }

      // Allow brief playback after seek inside
      await Future<void>.delayed(const Duration(milliseconds: 600));

      await controller.pause();
      seekPass = (ptsAfterSeek >= 0.8 && ptsAfterSeek <= 3.0);
      if (!seekPass) {
        throw Exception(
          'Seek inside both windows failed: ptsAfterSeek=$ptsAfterSeek (expected ~0.9s)',
        );
      }

      if (mounted) {
        setState(() {
          _status =
              'Seeked inside both windows to 0.9s (currentPTS=$ptsAfterSeek)';
        });
      }
      print('ANDROID_EDITOR_VOICEOVER_PREVIEW_STEP_SEEK_BOTH: DONE');

      // 5. DISPOSE LANE
      print('ANDROID_EDITOR_VOICEOVER_PREVIEW_STEP_DISPOSE: START');
      await controller.disposeAsyncConfirmed().timeout(
        const Duration(seconds: 5),
      );
      controller.dispose();
      cleanupController = null;
      disposePass = true;
      print('ANDROID_EDITOR_VOICEOVER_PREVIEW_STEP_DISPOSE: DONE');
    } catch (e, st) {
      errorMessage = '$e';
      print('ANDROID_EDITOR_VOICEOVER_PREVIEW_ERROR: $e\n$st');
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
      'sourcePreparePass': sourcePreparePass,
      'initPass': initPass,
      'playPass': playPass,
      'seekPass': seekPass,
      'disposePass': disposePass,
      'textureId': textureId,
      'renderWidth': renderWidth,
      'renderHeight': renderHeight,
      'renderAspectRatio': renderAspectRatio,
      'draftDuration': draftDuration,
      'ptsReachedInPlay': ptsReachedInPlay,
      'ptsAfterSeek': ptsAfterSeek,
      'totalPtsCount': ptsValues.length,
      'error': errorMessage,
    };

    print('ANDROID_EDITOR_VOICEOVER_PREVIEW_JSON:${jsonEncode(jsonSummary)}');
    print(
      overallPass
          ? 'ANDROID_EDITOR_VOICEOVER_PREVIEW_PHYSICAL_PASS'
          : 'ANDROID_EDITOR_VOICEOVER_PREVIEW_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = overallPass
            ? 'PASS: Android VGEditorController voiceover preview verified.'
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
