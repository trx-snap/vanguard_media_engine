// Copyright 2026, Connects. All rights reserved.
// android_live_green_screen_video_background_physical_smoke.dart
//
// Dedicated physical smoke harness proving the generic (caller-agnostic) live
// green-screen public Dart API with a moving video file background on Android
// hardware (Slice 2).
//
// Exercises the public contracts in `vg_live_green_screen.dart` via
// `MethodChannelVGLiveGreenScreenPlatform` (not Duet-owned).
//
// Scenarios verified:
//   1. Stage the tracked 60s MP4 fixture (`duet_sustained_motion_60s_720x1280.mp4`)
//      from rootBundle into a temp file.
//   2. Start generic live green-screen session with canvas size 720x1280 directly
//      using `VGGreenScreenBackgroundSource.videoFile(tempPath)`.
//   3. Observe sustained video background playback for `LIVE_GREENSCREEN_VIDEO_HOLD_SECONDS`
//      (default 20s, minimum 4s) across UI progress and begin/end markers.
//   4. Test invalid background update fails closed: update to a non-existent file path,
//      assert it throws an exception.
//   5. Confirm session remains alive and keeps playing the old video background
//      (fail-open session preservation, 5s observation).
//   6. Test dynamic update to solid color (teal, 3s observation).
//   7. Dynamic update back to video background using the same staged file (5s observation).
//   8. Clean session stop and guaranteed temp directory cleanup in finally.
//   9. Exit(0) on pass and exit(1) on fail after emitting structured JSON report.
//
// Proof boundary:
//   - Device requirement: Android physical device with camera permission already
//     granted via adb or user prompt.
//   - Harness command:
//       cd packages/vanguard_media_engine/example &&
//       flutter run -d <deviceId> \
//         -t lib/android_live_green_screen_video_background_physical_smoke.dart \
//         --dart-define=LIVE_GREENSCREEN_VIDEO_HOLD_SECONDS=20
//   - Claims allowed:
//       * public Dart API route via VGLiveGreenScreenPlatformInterface (MethodChannelVGLiveGreenScreenPlatform)
//       * Android generic Live GreenScreen start accepts video file background (720x1280 canvas, staged 60s MP4 fixture)
//       * sustained bounded observation of moving video background without crash or freeze
//       * invalid background update fails closed with exception while previous video session remains alive
//       * dynamic background update to solid color accepted
//       * dynamic background update back to video background accepted
//       * clean live green-screen session stop
//       * staged video fixture temp file and directory guaranteed cleanup on pass and fail paths
//   - Non-claims:
//       * no automated pixel or matte quality proof; video background is verified via platform route, session lifecycle, and bounded on-device manual observation
//       * no Duet proof; generic caller-agnostic Live GreenScreen public API only
//       * no export proof
//       * no recording proof
//       * no audio proof
//       * no iOS proof
//       * no all-device or low-end device performance proof

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_green_screen.dart';
import 'package:vanguard_media_engine/vg_live_green_screen.dart';

const String kVideoBackgroundAssetPath =
    'assets/manual_test_clips/duet_sustained_motion_60s_720x1280.mp4';

const String kSmokeStartMarker =
    'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_PHYSICAL_SMOKE_START';
const String kSmokeJsonPrefix =
    'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_PHYSICAL_JSON:';
const String kSmokePassMarker =
    'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_PHYSICAL_PASS';
const String kSmokeFailMarker =
    'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_PHYSICAL_FAIL';

const String kObserveSustainedVideoBeginMarker =
    'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_OBSERVE_SUSTAINED_VIDEO_BEGIN';
const String kObserveSustainedVideoEndMarker =
    'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_OBSERVE_SUSTAINED_VIDEO_END';

const String kObservePostInvalidUpdateBeginMarker =
    'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_OBSERVE_POST_INVALID_UPDATE_BEGIN';
const String kObservePostInvalidUpdateEndMarker =
    'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_OBSERVE_POST_INVALID_UPDATE_END';

const String kObserveSolidColorBeginMarker =
    'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_OBSERVE_SOLID_COLOR_BEGIN';
const String kObserveSolidColorEndMarker =
    'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_OBSERVE_SOLID_COLOR_END';

const String kObserveRestoredVideoBeginMarker =
    'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_OBSERVE_RESTORED_VIDEO_BEGIN';
const String kObserveRestoredVideoEndMarker =
    'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_OBSERVE_RESTORED_VIDEO_END';

/// Length of the initial sustained video observation phase in seconds.
/// Override via `--dart-define=LIVE_GREENSCREEN_VIDEO_HOLD_SECONDS=<n>`.
/// Default is 20s; minimum is 4s.
const int _rawHoldSeconds = int.fromEnvironment(
  'LIVE_GREENSCREEN_VIDEO_HOLD_SECONDS',
  defaultValue: 20,
);
const int kHoldSeconds = _rawHoldSeconds < 4 ? 4 : _rawHoldSeconds;

/// Solid color background used in the dynamic switch scenario (teal).
const int kSolidBackgroundArgb = 0xFF008080;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidLiveGreenScreenVideoBgPhysicalSmokeApp());
}

class AndroidLiveGreenScreenVideoBgPhysicalSmokeApp extends StatefulWidget {
  const AndroidLiveGreenScreenVideoBgPhysicalSmokeApp({super.key});

  @override
  State<AndroidLiveGreenScreenVideoBgPhysicalSmokeApp> createState() =>
      _AndroidLiveGreenScreenVideoBgPhysicalSmokeAppState();
}

class _AndroidLiveGreenScreenVideoBgPhysicalSmokeAppState
    extends State<AndroidLiveGreenScreenVideoBgPhysicalSmokeApp> {
  String _status =
      'Starting live green-screen video background physical smoke harness...';
  String _currentStep = 'INIT';
  String _phaseLabel = 'INIT';
  int _phaseElapsedSeconds = 0;
  int _phaseTotalSeconds = 0;
  VGLiveGreenScreenSession? _session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  void _updateStatus(String step, String status) {
    if (mounted) {
      setState(() {
        _currentStep = step;
        _status = status;
      });
    }
  }

  void _updateObserveProgress(
    String phaseLabel,
    int elapsedSeconds,
    int totalSeconds,
  ) {
    if (mounted) {
      setState(() {
        _phaseLabel = phaseLabel;
        _phaseElapsedSeconds = elapsedSeconds;
        _phaseTotalSeconds = totalSeconds;
        _status = 'Observing $phaseLabel ($elapsedSeconds/$totalSeconds s)';
      });
    }
  }

  Future<void> _runSmoke() async {
    print(kSmokeStartMarker);
    print('SUSTAINED_HOLD_SECONDS=$kHoldSeconds');

    const platform = MethodChannelVGLiveGreenScreenPlatform();

    bool pass = false;
    String? sessionId;
    bool stopped = false;
    Directory? videoFixtureTempDir;
    bool isVideoFixtureCleaned = false;
    late final File videoFile;

    final stepResults = <String, String>{};
    final failures = <String>[];
    final events = <Map<String, dynamic>>[];
    StreamSubscription<VGLiveGreenScreenEvent>? eventsSub;

    Future<T> runStep<T>(
      String stepName,
      String description,
      Future<T> Function() action,
    ) async {
      _updateStatus(stepName, description);
      try {
        final result = await action();
        stepResults[stepName] = 'PASS';
        print('ANDROID_LIVE_GREENSCREEN_VIDEO_BG_STEP_${stepName}_PASS');
        return result;
      } catch (e, st) {
        stepResults[stepName] = 'FAIL';
        final failureMsg = '$stepName: $e';
        if (!failures.contains(failureMsg)) {
          failures.add(failureMsg);
        }
        print(
          'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_STEP_${stepName}_FAIL: $e\n$st',
        );
        rethrow;
      }
    }

    Future<void> observePhase(
      String phaseLabel,
      String beginMarker,
      String endMarker,
      int durationSeconds,
    ) async {
      print(beginMarker);
      var elapsed = 0;
      _updateObserveProgress(phaseLabel, 0, durationSeconds);
      while (elapsed < durationSeconds) {
        final remaining = durationSeconds - elapsed;
        final step = remaining < 1 ? remaining : 1;
        await Future<void>.delayed(Duration(seconds: step));
        elapsed += step;
        _updateObserveProgress(phaseLabel, elapsed, durationSeconds);
      }
      print(endMarker);
    }

    try {
      // Listen to generic live green-screen events.
      eventsSub = VGLiveGreenScreenEvents.stream.listen((event) {
        events.add(<String, dynamic>{
          'type': event.type.name,
          'sessionId': event.sessionId,
          'previousBackend': event.previousBackend,
          'currentBackend': event.currentBackend,
          'reason': event.reason,
          'userMessage': event.userMessage,
        });
      });

      // Step 1: Stage the 60s video fixture into temp directory.
      await runStep<void>(
        'STAGE_VIDEO_FIXTURE',
        'Staging $kVideoBackgroundAssetPath into temp directory',
        () async {
          videoFixtureTempDir = await Directory.systemTemp.createTemp(
            'live_gs_video_bg_smoke_',
          );
          videoFile = File('${videoFixtureTempDir!.path}/video_bg_60s.mp4');
          final videoData = await rootBundle.load(kVideoBackgroundAssetPath);
          await videoFile.writeAsBytes(
            videoData.buffer.asUint8List(
              videoData.offsetInBytes,
              videoData.lengthInBytes,
            ),
            flush: true,
          );
          if (!await videoFile.exists() || await videoFile.length() == 0) {
            throw StateError('Staged video fixture missing or empty');
          }
          print(
            'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_STAGED_PATH: ${videoFile.path} (${await videoFile.length()} bytes)',
          );
        },
      );

      // Step 2: Start generic live green-screen session directly with video background (720x1280).
      final session = await runStep<VGLiveGreenScreenSession>(
        'START_WITH_VIDEO_BACKGROUND',
        'Starting live green screen session with video background (720x1280)',
        () {
          final config = VGLiveGreenScreenConfig(
            canvasSize: const VGGreenScreenSize(720, 1280),
            background: VGGreenScreenBackgroundSource.videoFile(videoFile.path),
          );
          return platform.startLiveGreenScreenSession(config);
        },
      );
      sessionId = session.sessionId;
      if (mounted) {
        setState(() {
          _session = session;
          _phaseLabel = 'VIDEO_BACKGROUND_ACTIVE';
        });
      }

      // Step 3: Observe sustained looping video background for kHoldSeconds.
      await runStep<void>(
        'OBSERVE_SUSTAINED_VIDEO',
        'Observing sustained video background (${kHoldSeconds}s)',
        () => observePhase(
          'SUSTAINED_VIDEO',
          kObserveSustainedVideoBeginMarker,
          kObserveSustainedVideoEndMarker,
          kHoldSeconds,
        ),
      );

      // Step 4: Test invalid background update fails closed.
      await runStep<void>(
        'TEST_INVALID_UPDATE_FAILS',
        'Testing invalid background update with non-existent file path fails closed',
        () async {
          bool threw = false;
          try {
            await platform.updateLiveGreenScreenBackground(
              sessionId!,
              const VGGreenScreenBackgroundSource.videoFile(
                '/non/existent/bogus_live_video_bg_file_12345.mp4',
              ),
            );
          } catch (e) {
            threw = true;
            print(
              'ANDROID_LIVE_GREENSCREEN_VIDEO_BG_INVALID_UPDATE_EXPECTED_EXCEPTION: $e',
            );
          }
          if (!threw) {
            throw StateError(
              'Expected updateLiveGreenScreenBackground to fail for non-existent file, but it succeeded',
            );
          }
        },
      );

      // Step 5: Observe that the video background remains alive after invalid update (5s).
      await runStep<void>(
        'OBSERVE_OLD_VIDEO_BG_SURVIVES_INVALID_UPDATE',
        'Observing old video background remains alive after invalid update (5s)',
        () => observePhase(
          'OLD_VIDEO_POST_INVALID_UPDATE',
          kObservePostInvalidUpdateBeginMarker,
          kObservePostInvalidUpdateEndMarker,
          5,
        ),
      );

      // Step 6: Test dynamic update to solid color.
      await runStep<void>(
        'UPDATE_BACKGROUND_SOLID',
        'Updating background from video to solid teal',
        () => platform.updateLiveGreenScreenBackground(
          sessionId!,
          const VGGreenScreenSolidColorBackground(kSolidBackgroundArgb),
        ),
      );
      if (mounted) {
        setState(() {
          _phaseLabel = 'SOLID_COLOR_ACTIVE';
        });
      }

      // Step 7: Observe solid color (3s).
      await runStep<void>(
        'OBSERVE_SOLID_COLOR',
        'Observing solid teal background (3s)',
        () => observePhase(
          'SOLID_COLOR',
          kObserveSolidColorBeginMarker,
          kObserveSolidColorEndMarker,
          3,
        ),
      );

      // Step 8: Update background back to video using the staged file.
      await runStep<void>(
        'UPDATE_BACKGROUND_BACK_TO_VIDEO',
        'Updating background from solid teal back to staged video file',
        () => platform.updateLiveGreenScreenBackground(
          sessionId!,
          VGGreenScreenBackgroundSource.videoFile(videoFile.path),
        ),
      );
      if (mounted) {
        setState(() {
          _phaseLabel = 'VIDEO_BACKGROUND_RESTORED';
        });
      }

      // Step 9: Observe restored video (5s).
      await runStep<void>(
        'OBSERVE_RESTORED_VIDEO',
        'Observing restored video background (5s)',
        () => observePhase(
          'RESTORED_VIDEO',
          kObserveRestoredVideoBeginMarker,
          kObserveRestoredVideoEndMarker,
          5,
        ),
      );

      // Step 10: Stop session cleanly.
      await runStep<void>(
        'STOP_SESSION',
        'Stopping live green screen session cleanly',
        () async {
          await platform.stopLiveGreenScreenSession(sessionId!);
          stopped = true;
        },
      );

      pass = failures.isEmpty;
    } catch (e) {
      pass = false;
      print('ANDROID_LIVE_GREENSCREEN_VIDEO_BG_EXCEPTION: $e');
    } finally {
      await eventsSub?.cancel();

      // Guaranteed cleanup: stop session if needed.
      if (sessionId != null && !stopped) {
        try {
          await platform.stopLiveGreenScreenSession(sessionId);
          stopped = true;
        } catch (e) {
          print('ANDROID_LIVE_GREENSCREEN_VIDEO_BG: cleanup stop note: $e');
        }
      }

      // Guaranteed cleanup: delete temp directory on both pass and fail paths.
      if (videoFixtureTempDir != null) {
        try {
          if (await videoFixtureTempDir!.exists()) {
            await videoFixtureTempDir!.delete(recursive: true);
          }
          isVideoFixtureCleaned = true;
        } catch (e) {
          print('ANDROID_LIVE_GREENSCREEN_VIDEO_BG: cleanup temp dir note: $e');
        }
      } else {
        isVideoFixtureCleaned = true;
      }

      final payload = <String, Object?>{
        'pass': pass,
        'proofBoundary':
            'android_live_green_screen_video_background_physical_smoke',
        'holdSeconds': kHoldSeconds,
        'sessionId': sessionId,
        'textureId': _session?.textureId,
        'videoBackgroundAssetPath': kVideoBackgroundAssetPath,
        'videoFixtureCleaned': isVideoFixtureCleaned,
        'stepResults': stepResults,
        'failures': failures,
        'claimsAllowed': <String>[
          'public Dart API route via VGLiveGreenScreenPlatformInterface (MethodChannelVGLiveGreenScreenPlatform)',
          'Android generic Live GreenScreen start accepts video file background (720x1280 canvas, staged 60s MP4 fixture)',
          'sustained bounded observation of moving video background without crash or freeze',
          'invalid background update fails closed with exception while previous video session remains alive',
          'dynamic background update to solid color accepted',
          'dynamic background update back to video background accepted',
          'clean live green-screen session stop',
          'staged video fixture temp file and directory guaranteed cleanup on pass and fail paths',
        ],
        'nonClaims': <String>[
          'no automated pixel or matte quality proof; video background is verified via platform route, session lifecycle, and bounded on-device manual observation',
          'no Duet proof; generic caller-agnostic Live GreenScreen public API only',
          'no export proof',
          'no recording proof',
          'no audio proof',
          'no iOS proof',
          'no all-device or low-end device performance proof',
        ],
      };

      print('$kSmokeJsonPrefix${jsonEncode(payload)}');
      print(pass ? kSmokePassMarker : kSmokeFailMarker);

      if (mounted) {
        setState(() {
          _status = pass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(pass ? 0 : 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: const Color(0xFF041F1F),
        body: Stack(
          children: [
            if (session != null)
              SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: session.canvasSize.width.toDouble(),
                    height: session.canvasSize.height.toDouble(),
                    child: Texture(textureId: session.textureId),
                  ),
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(color: Colors.tealAccent),
              ),
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.tealAccent, width: 1),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Android Live Green Screen Video Background Physical Smoke',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Status: $_status',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                      if (session != null)
                        Text(
                          'Session: ${session.sessionId} | Texture ID: ${session.textureId}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      Text(
                        'Phase: $_phaseLabel | Elapsed: ${_phaseElapsedSeconds}s / ${_phaseTotalSeconds}s',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                      if (_currentStep.isNotEmpty)
                        Text(
                          'Step: $_currentStep',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
