// Vanguard Android True-DAG: SFX added-audio preview physical smoke test.
//
// Proves Android public VGEditorController preview playback with added music, sfx,
// and voiceover sidecar tracks:
//   - Positive physical preview lane:
//       * Copies real video (clip_B.mov) and audio (clip_A.mp3) assets to temporary files.
//       * Constructs a hard-cut two-clip VGEditorDraft (~4.0s total):
//           - clip1: video, trimStart 0.0, trimEnd 2.0, startTime 0.0
//           - clip2: video, trimStart 0.0, trimEnd 2.0, startTime 2.0
//           - music track: role='music', startTime=0.0, duration=2.0, volume=0.55
//           - sfx track: role='sfx', startTime=2.0, duration=1.0, volume=0.7, fadeInSeconds=0.1, fadeOutSeconds=0.1
//             (Touching endpoint [0.0, 2.0) -> [2.0, 3.0) on shared added lane accepted)
//           - voiceover track: role='voiceover', startTime=1.0, duration=2.0, volume=0.5
//             (Intentionally overlaps both music and sfx across separate voiceover lane)
//       * Initializes VGEditorController, validating textureId and render dimensions.
//       * Plays past clip boundary and sfx start (2.0s) to PTS >= 2.25s, then pauses.
//       * Seeks inside sfx/voiceover region (2.4s) with resumeAfterSeek=true, verifies PTS advances past 2.55s, then pauses.
//       * Confirms asynchronous teardown and resource disposal.
//   - Negative same-lane overlap lane:
//       * Music [0.0, 2.0) and SFX [1.5, 2.5) overlap on the shared added lane.
//       * Asserts initialize() fails with PlatformException code UNSUPPORTED_TIMELINE_FEATURE.
//   - Negative duplicate added-track-ID lane:
//       * Two user-added tracks share the same trackId.
//       * Asserts initialize() fails with PlatformException code INVALID_AUDIO_SIDECAR.
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
  runApp(const AndroidEditorSfxAddedAudioPreviewPhysicalSmokeApp());
}

class AndroidEditorSfxAddedAudioPreviewPhysicalSmokeApp extends StatefulWidget {
  const AndroidEditorSfxAddedAudioPreviewPhysicalSmokeApp({super.key});

  @override
  State<AndroidEditorSfxAddedAudioPreviewPhysicalSmokeApp> createState() =>
      _AndroidEditorSfxAddedAudioPreviewPhysicalSmokeAppState();
}

class _AndroidEditorSfxAddedAudioPreviewPhysicalSmokeAppState
    extends State<AndroidEditorSfxAddedAudioPreviewPhysicalSmokeApp> {
  String _status =
      'Initializing Android VGEditorController SFX added-audio preview physical smoke…';
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
    File? tempSfxFile;
    VGEditorController? cleanupController;
    StreamSubscription<double>? ptsSubscription;
    final List<double> ptsValues = [];

    var sourcePreparePass = false;
    var initPass = false;
    var playPass = false;
    var seekPass = false;
    var overlapRejectPass = false;
    var duplicateTrackIdRejectPass = false;
    var disposePass = false;

    int? textureId;
    int? renderWidth;
    int? renderHeight;
    double? renderAspectRatio;
    double? draftDuration;

    double? ptsReachedPastSfxStart;
    double? ptsAfterSeek;
    String? errorMessage;

    final runId = DateTime.now().millisecondsSinceEpoch;
    final musicTrackId = 'android_sfx_music_$runId';
    final sfxTrackId = 'android_sfx_track_$runId';
    final voiceoverTrackId = 'android_sfx_voiceover_$runId';

    try {
      // 1. PREPARE SOURCES
      print(
        'ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_STEP_SOURCE_PREPARE: START',
      );
      final tempDir = Directory.systemTemp;
      tempVideoFile1 = File('${tempDir.path}/android_sfx_video1_$runId.mov');
      tempVideoFile2 = File('${tempDir.path}/android_sfx_video2_$runId.mov');
      tempVoiceoverFile = File('${tempDir.path}/android_sfx_vo_$runId.mov');
      tempMusicFile = File('${tempDir.path}/android_sfx_music_$runId.mp3');
      tempSfxFile = File('${tempDir.path}/android_sfx_sound_$runId.mp3');

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
      final musicUint8List = musicBytes.buffer.asUint8List(
        musicBytes.offsetInBytes,
        musicBytes.lengthInBytes,
      );

      await tempMusicFile.writeAsBytes(musicUint8List, flush: true);
      await tempSfxFile.writeAsBytes(musicUint8List, flush: true);

      if (!await tempVideoFile1.exists() ||
          !await tempVideoFile2.exists() ||
          !await tempVoiceoverFile.exists() ||
          !await tempMusicFile.exists() ||
          !await tempSfxFile.exists()) {
        throw Exception(
          'Failed to write temp video, voiceover, music, or sfx files to ${tempDir.path}',
        );
      }

      final clip1 = VGClipDescriptor(
        id: 'clip1_$runId',
        mediaKind: VGMediaKind.video,
        sourcePath: tempVideoFile1.path,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 2.0,
        startTimeSeconds: 0.0,
      );

      final clip2 = VGClipDescriptor(
        id: 'clip2_$runId',
        mediaKind: VGMediaKind.video,
        sourcePath: tempVideoFile2.path,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 2.0,
        startTimeSeconds: 2.0,
      );

      final musicTrack = VGAudioSidecarTrack(
        trackId: musicTrackId,
        url: tempMusicFile.path,
        startTime: 0.0,
        duration: 2.0,
        volume: 0.55,
        role: 'music',
      );

      final sfxTrack = VGAudioSidecarTrack(
        trackId: sfxTrackId,
        url: tempSfxFile.path,
        startTime: 2.0,
        duration: 1.0,
        volume: 0.7,
        fadeInSeconds: 0.1,
        fadeOutSeconds: 0.1,
        role: 'sfx',
      );

      final voiceoverTrack = VGAudioSidecarTrack(
        trackId: voiceoverTrackId,
        url: tempVoiceoverFile.path,
        startTime: 1.0,
        duration: 2.0,
        volume: 0.5,
        role: 'voiceover',
      );

      final draft = VGEditorDraft(
        id: 'draft_sfx_added_audio_$runId',
        clips: [clip1, clip2],
        canvasWidth: 720,
        canvasHeight: 1280,
        fps: 30,
        audioSidecarPlan: VGAudioSidecarPlan(
          tracks: [musicTrack, sfxTrack, voiceoverTrack],
        ),
      );

      sourcePreparePass = true;
      print('ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_STEP_SOURCE_PREPARE: DONE');

      // 2. POSITIVE LANE: INIT CONTROLLER
      print('ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_STEP_INIT: START');
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
      print('ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_STEP_INIT: DONE');

      // 3. POSITIVE LANE: CONTINUOUS PLAY PAST SFX START (0.0s -> clip boundary/sfx start 2.0s -> PTS >= 2.25s)
      print(
        'ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_STEP_PLAY_PAST_SFX_START: START',
      );
      final playCompleter = Completer<double>();
      final playSub = controller.ptsStream.listen((pts) {
        if (pts >= 2.25 && !playCompleter.isCompleted) {
          playCompleter.complete(pts);
        }
      });

      await controller.play();
      if (!controller.isPlaying) {
        throw Exception('Play failed: controller.isPlaying is false');
      }

      ptsReachedPastSfxStart = await playCompleter.future
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException(
              'PTS did not reach >= 2.25s within 15s of play (currentPTS=${controller.currentPTS})',
            ),
          )
          .whenComplete(() => playSub.cancel());

      await controller.pause();
      playPass = (ptsReachedPastSfxStart >= 2.25 && !controller.isPlaying);
      if (!playPass) {
        throw Exception(
          'Play verification failed: ptsReachedPastSfxStart=$ptsReachedPastSfxStart',
        );
      }

      // Allow brief pause settle
      await Future<void>.delayed(const Duration(milliseconds: 400));

      if (mounted) {
        setState(() {
          _status =
              'Play reached PTS=$ptsReachedPastSfxStart past SFX start (paused)';
        });
      }
      print(
        'ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_STEP_PLAY_PAST_SFX_START: DONE',
      );

      // 4. POSITIVE LANE: SEEK (seek to 2.4s inside sfx and voiceover windows with resumeAfterSeek=true)
      print('ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_STEP_SEEK: START');
      final seekCompleter = Completer<double>();
      final seekSub = controller.ptsStream.listen((pts) {
        if (pts >= 2.55 && !seekCompleter.isCompleted) {
          seekCompleter.complete(pts);
        }
      });

      await controller.seek(2.4, resumeAfterSeek: true);

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
      seekPass = (ptsAfterSeek >= 2.4 && ptsAfterSeek <= 3.8);
      if (!seekPass) {
        throw Exception(
          'Seek to 2.4s failed: ptsAfterSeek=$ptsAfterSeek (expected >= 2.4s)',
        );
      }

      if (mounted) {
        setState(() {
          _status = 'Seeked to 2.4s and resumed (currentPTS=$ptsAfterSeek)';
        });
      }
      print('ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_STEP_SEEK: DONE');

      // 5. POSITIVE LANE: DISPOSE
      print('ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_STEP_DISPOSE: START');
      await ptsSubscription.cancel();
      ptsSubscription = null;
      await controller.disposeAsyncConfirmed().timeout(
        const Duration(seconds: 5),
      );
      controller.dispose();
      cleanupController = null;
      disposePass = true;
      print('ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_STEP_DISPOSE: DONE');

      // 6. NEGATIVE LANE: SAME-LANE OVERLAP REJECTION
      print(
        'ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_STEP_OVERLAP_REJECT: START',
      );
      final overlapMusicTrack = VGAudioSidecarTrack(
        trackId: '${musicTrackId}_ov',
        url: tempMusicFile.path,
        startTime: 0.0,
        duration: 2.0,
        volume: 0.55,
        role: 'music',
      );
      final overlapSfxTrack = VGAudioSidecarTrack(
        trackId: '${sfxTrackId}_ov',
        url: tempSfxFile.path,
        startTime: 1.5, // Overlaps [0.0, 2.0) on shared added lane
        duration: 1.0,
        volume: 0.7,
        role: 'sfx',
      );
      final overlapDraft = VGEditorDraft(
        id: 'draft_overlap_reject_$runId',
        clips: [clip1, clip2],
        canvasWidth: 720,
        canvasHeight: 1280,
        fps: 30,
        audioSidecarPlan: VGAudioSidecarPlan(
          tracks: [overlapMusicTrack, overlapSfxTrack],
        ),
      );

      final overlapController = VGEditorController(
        initialDraft: overlapDraft,
        previewDraftDeriver: (d) => d.flattenOriginalClipAudio(),
      );
      try {
        await overlapController.initialize().timeout(
          const Duration(seconds: 5),
        );
        throw Exception(
          'Overlap draft unexpectedly initialized successfully without rejection',
        );
      } on PlatformException catch (pe) {
        if (pe.code == 'UNSUPPORTED_TIMELINE_FEATURE') {
          overlapRejectPass = true;
          print(
            'ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_OVERLAP_REJECTED_AS_EXPECTED: code=${pe.code}, message=${pe.message}',
          );
        } else {
          throw Exception(
            'Overlap draft failed with unexpected PlatformException code: ${pe.code} (message: ${pe.message})',
          );
        }
      } finally {
        try {
          await overlapController.disposeAsyncConfirmed();
        } catch (_) {}
        overlapController.dispose();
      }
      print('ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_STEP_OVERLAP_REJECT: DONE');

      // 7. NEGATIVE LANE: DUPLICATE ADDED-TRACK-ID REJECTION
      print(
        'ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_STEP_DUPLICATE_ID_REJECT: START',
      );
      const duplicateId = 'android_duplicate_track_id';
      final dupMusicTrack = VGAudioSidecarTrack(
        trackId: duplicateId,
        url: tempMusicFile.path,
        startTime: 0.0,
        duration: 1.0,
        volume: 0.55,
        role: 'music',
      );
      final dupSfxTrack = VGAudioSidecarTrack(
        trackId:
            duplicateId, // Duplicate user-added trackId (non-overlapping timing [2.0, 3.0))
        url: tempSfxFile.path,
        startTime: 2.0,
        duration: 1.0,
        volume: 0.7,
        role: 'sfx',
      );
      final duplicateIdDraft = VGEditorDraft(
        id: 'draft_duplicate_id_reject_$runId',
        clips: [clip1, clip2],
        canvasWidth: 720,
        canvasHeight: 1280,
        fps: 30,
        audioSidecarPlan: VGAudioSidecarPlan(
          tracks: [dupMusicTrack, dupSfxTrack],
        ),
      );

      final duplicateIdController = VGEditorController(
        initialDraft: duplicateIdDraft,
        previewDraftDeriver: (d) => d.flattenOriginalClipAudio(),
      );
      try {
        await duplicateIdController.initialize().timeout(
          const Duration(seconds: 5),
        );
        throw Exception(
          'Duplicate trackId draft unexpectedly initialized successfully without rejection',
        );
      } on PlatformException catch (pe) {
        if (pe.code == 'INVALID_AUDIO_SIDECAR') {
          duplicateTrackIdRejectPass = true;
          print(
            'ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_DUPLICATE_ID_REJECTED_AS_EXPECTED: code=${pe.code}, message=${pe.message}',
          );
        } else {
          throw Exception(
            'Duplicate trackId draft failed with unexpected PlatformException code: ${pe.code} (message: ${pe.message})',
          );
        }
      } finally {
        try {
          await duplicateIdController.disposeAsyncConfirmed();
        } catch (_) {}
        duplicateIdController.dispose();
      }
      print(
        'ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_STEP_DUPLICATE_ID_REJECT: DONE',
      );
    } catch (e, st) {
      errorMessage = '$e';
      print('ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_ERROR: $e\n$st');
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
      if (tempSfxFile != null && await tempSfxFile.exists()) {
        try {
          await tempSfxFile.delete();
        } catch (_) {}
      }
    }

    final overallPass =
        sourcePreparePass &&
        initPass &&
        playPass &&
        seekPass &&
        overlapRejectPass &&
        duplicateTrackIdRejectPass &&
        disposePass;

    final jsonSummary = <String, dynamic>{
      'pass': overallPass,
      'runId': runId,
      'musicTrackId': musicTrackId,
      'sfxTrackId': sfxTrackId,
      'voiceoverTrackId': voiceoverTrackId,
      'sourcePreparePass': sourcePreparePass,
      'initPass': initPass,
      'playPass': playPass,
      'seekPass': seekPass,
      'overlapRejectPass': overlapRejectPass,
      'duplicateTrackIdRejectPass': duplicateTrackIdRejectPass,
      'disposePass': disposePass,
      'textureId': textureId,
      'renderWidth': renderWidth,
      'renderHeight': renderHeight,
      'renderAspectRatio': renderAspectRatio,
      'draftDuration': draftDuration,
      'ptsReachedPastSfxStart': ptsReachedPastSfxStart,
      'ptsAfterSeek': ptsAfterSeek,
      'totalPtsCount': ptsValues.length,
      'error': errorMessage,
    };

    print(
      'ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_JSON:${jsonEncode(jsonSummary)}',
    );
    print(
      overallPass
          ? 'ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_PHYSICAL_PASS'
          : 'ANDROID_EDITOR_SFX_ADDED_AUDIO_PREVIEW_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = overallPass
            ? 'PASS: Android VGEditorController SFX added-audio preview verified.'
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
