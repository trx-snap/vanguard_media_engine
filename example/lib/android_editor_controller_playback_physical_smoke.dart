// Vanguard Android True-DAG Phase 7.8A: Public VGEditorController playback route parity physical smoke test.
//
// Proves Android public VGEditorController routes work for one local video clip using public Dart API only:
//   - VGEditorController.initialize -> native createTimelineTexture
//   - VGEditorController.play -> native timelinePlay
//   - VGEditorController.pause -> native timelinePause
//   - VGEditorController.seek -> native timelineSeek
//   - VGEditorController.updateDraft -> native updateTimeline
//   - VGEditorController.disposeAsyncConfirmed/dispose -> native disposeTimeline
//   - negative multi-clip initialize returns PlatformException code UNSUPPORTED_TIMELINE

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
  int? _textureId;

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

    File? tempFile;
    VGEditorController? cleanupController;
    StreamSubscription<double>? ptsSubscription;
    final List<double> ptsValues = [];

    var initPass = false;
    var playPass = false;
    var pausePass = false;
    var seekPass = false;
    var updatePass = false;
    var replayPass = false;
    var multiClipRejectPass = false;
    var disposePass = false;

    int? initialTextureId;
    int? updatedTextureId;
    double? firstPositivePts;
    double? currentPtsAfterSeek;
    double? ptsAfterSeek;
    double? replayPositivePts;
    String? multiClipErrorCode;
    String? errorMessage;

    try {
      // 0. Copy assets/manual_test_clips/clip_B.mov from rootBundle to Directory.systemTemp
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      tempFile = File('${tempDir.path}/android_editor_controller_clip_b.mov');
      await tempFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      // 1. INIT
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_INIT: START');
      final clipDescriptor = VGClipDescriptor(
        id: 'clip_b_0',
        mediaKind: VGMediaKind.video,
        sourcePath: tempFile.path,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
      );

      final initialDraft = VGEditorDraft(
        id: 'draft_single_clip',
        clips: [clipDescriptor],
        canvasWidth: 1280,
        canvasHeight: 720,
        fps: 30,
      );

      final controller = VGEditorController(initialDraft: initialDraft);
      cleanupController = controller;
      ptsSubscription = controller.ptsStream.listen((pts) {
        ptsValues.add(pts);
      });

      await controller.initialize().timeout(const Duration(seconds: 10));

      initialTextureId = controller.textureId;
      initPass =
          (initialTextureId != null &&
          initialTextureId >= 0 &&
          controller.isReady);
      if (!initPass) {
        throw Exception(
          'Init failed: textureId=$initialTextureId, isReady=${controller.isReady}',
        );
      }

      if (mounted) {
        setState(() {
          _textureId = initialTextureId;
          _status = 'Initialized: textureId=$initialTextureId';
        });
      }
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_INIT: DONE');

      // 2. PLAY
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

      playPass = (firstPositivePts > 0.0 && controller.isPlaying);
      if (mounted) {
        setState(() {
          _status = 'Playing: firstPositivePts=$firstPositivePts';
        });
      }
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_PLAY: DONE');

      // 3. PAUSE
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_PAUSE: START');
      await controller.pause();
      pausePass = !controller.isPlaying;
      if (!pausePass) {
        throw Exception('Pause failed: controller.isPlaying is still true');
      }
      if (mounted) {
        setState(() {
          _status = 'Paused at ${controller.currentPTS.toStringAsFixed(2)}s';
        });
      }
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_PAUSE: DONE');

      // 4. SEEK
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_SEEK: START');
      final seekPtsCompleter = Completer<double>();
      final seekSub = controller.ptsStream.listen((pts) {
        if (!seekPtsCompleter.isCompleted) {
          seekPtsCompleter.complete(pts);
        }
      });

      await controller.seek(1.0);
      currentPtsAfterSeek = controller.currentPTS;

      try {
        ptsAfterSeek = await seekPtsCompleter.future.timeout(
          const Duration(seconds: 2),
        );
      } catch (_) {
        // stationary pause seek may not deliver new frame callback or was already set
      } finally {
        await seekSub.cancel();
      }

      seekPass =
          (currentPtsAfterSeek >= 0.9) ||
          (ptsAfterSeek != null && ptsAfterSeek >= 0.9);
      if (!seekPass) {
        throw Exception(
          'Seek failed: currentPTS=$currentPtsAfterSeek, ptsAfterSeek=$ptsAfterSeek',
        );
      }
      if (mounted) {
        setState(() {
          _status = 'Seeked to 1.0s (currentPTS=$currentPtsAfterSeek)';
        });
      }
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_SEEK: DONE');

      // 5. UPDATE
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_UPDATE: START');
      final freshClip = VGClipDescriptor(
        id: 'clip_b_fresh',
        mediaKind: VGMediaKind.video,
        sourcePath: tempFile.path,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
      );

      final freshDraft = VGEditorDraft(
        id: 'draft_fresh_clip',
        clips: [freshClip],
        canvasWidth: 1280,
        canvasHeight: 720,
        fps: 30,
      );

      await controller
          .updateDraft(freshDraft)
          .timeout(const Duration(seconds: 10));
      updatedTextureId = controller.textureId;
      updatePass =
          (updatedTextureId != null &&
          updatedTextureId >= 0 &&
          controller.isReady);
      if (!updatePass) {
        throw Exception(
          'UpdateDraft failed: textureId=$updatedTextureId, isReady=${controller.isReady}',
        );
      }
      if (mounted) {
        setState(() {
          _textureId = updatedTextureId;
          _status = 'Updated draft (textureId=$updatedTextureId)';
        });
      }
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_UPDATE: DONE');

      // 6. REPLAY
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_REPLAY: START');
      final replayPtsCompleter = Completer<double>();
      final replaySub = controller.ptsStream.listen((pts) {
        if (pts > 0.0 && !replayPtsCompleter.isCompleted) {
          replayPtsCompleter.complete(pts);
        }
      });

      await controller.play();
      if (!controller.isPlaying) {
        throw Exception('Replay failed: controller.isPlaying is false');
      }

      replayPositivePts = await replayPtsCompleter.future
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'No positive PTS received within 10s of replay',
            ),
          )
          .whenComplete(() => replaySub.cancel());

      await controller.pause();
      replayPass = (replayPositivePts > 0.0);
      if (!replayPass) {
        throw Exception('Replay failed: replayPositivePts=$replayPositivePts');
      }
      if (mounted) {
        setState(() {
          _status = 'Replay completed (positive PTS=$replayPositivePts)';
        });
      }
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_REPLAY: DONE');

      // 7. DISPOSE
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_DISPOSE: START');
      await controller.disposeAsyncConfirmed().timeout(
        const Duration(seconds: 5),
      );
      controller.dispose();
      cleanupController = null;
      disposePass = true;
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_DISPOSE: DONE');

      // 8. MULTI_CLIP_REJECT
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_MULTI_CLIP_REJECT: START');
      final multiClip1 = VGClipDescriptor(
        id: 'clip_multi_1',
        mediaKind: VGMediaKind.video,
        sourcePath: tempFile.path,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
      );
      final multiClip2 = VGClipDescriptor(
        id: 'clip_multi_2',
        mediaKind: VGMediaKind.video,
        sourcePath: tempFile.path,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
      );
      final multiClipDraft = VGEditorDraft(
        id: 'draft_multi_clip',
        clips: [multiClip1, multiClip2],
        canvasWidth: 1280,
        canvasHeight: 720,
        fps: 30,
      );

      final multiController = VGEditorController(initialDraft: multiClipDraft);
      try {
        await multiController.initialize().timeout(const Duration(seconds: 5));
      } on PlatformException catch (e) {
        multiClipErrorCode = e.code;
        if (e.code == 'UNSUPPORTED_TIMELINE') {
          multiClipRejectPass = true;
        }
      } finally {
        try {
          await multiController.disposeAsyncConfirmed();
        } catch (_) {}
        multiController.dispose();
      }

      if (!multiClipRejectPass) {
        throw Exception(
          'Multi-clip reject failed: errorCode=$multiClipErrorCode, expected UNSUPPORTED_TIMELINE',
        );
      }
      print('ANDROID_EDITOR_CONTROLLER_PLAYBACK_STEP_MULTI_CLIP_REJECT: DONE');
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
      if (tempFile != null && await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }

    final overallPass =
        initPass &&
        playPass &&
        pausePass &&
        seekPass &&
        updatePass &&
        replayPass &&
        multiClipRejectPass &&
        disposePass;

    final jsonSummary = <String, dynamic>{
      'pass': overallPass,
      'initPass': initPass,
      'playPass': playPass,
      'pausePass': pausePass,
      'seekPass': seekPass,
      'updatePass': updatePass,
      'replayPass': replayPass,
      'multiClipRejectPass': multiClipRejectPass,
      'disposePass': disposePass,
      'initialTextureId': initialTextureId,
      'updatedTextureId': updatedTextureId,
      'firstPositivePts': firstPositivePts,
      'currentPtsAfterSeek': currentPtsAfterSeek,
      'ptsAfterSeek': ptsAfterSeek,
      'replayPositivePts': replayPositivePts,
      'multiClipErrorCode': multiClipErrorCode,
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
            ? 'PASS: Android VGEditorController playback routes verified.'
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
              if (_textureId != null)
                SizedBox(
                  width: 320,
                  height: 180,
                  child: Texture(textureId: _textureId!),
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
