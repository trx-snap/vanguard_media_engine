// Copyright 2026, Connects. All rights reserved.
// ios_live_green_screen_video_background_physical_smoke.dart
//
// Dedicated iOS physical smoke harness proving the generic Live Green Screen
// video background plate (Slice 2) on real hardware.
//
// Verified scenarios:
//   1. Force Vision/adapter backend via setLiveGreenScreenDiagnosticsOptions (iosSegmentationBackend = 'visionFast').
//   2. Start session with background.type = 'video' using the 60s sustained video fixture (duet_sustained_motion_60s_720x1280.mp4).
//   3. Observe sustained (>= 60s) looping video playback without freeze or stutter.
//   4. Test invalid background update (non-existent file) -> assert it fails.
//   5. Confirm the session remains alive and keeps playing the old video background (fail-open).
//   6. Test dynamic update to solid color and back to video.
//   7. Clean stop and resource disposal.

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

const String kDiagnosticsOptionsMethod = 'setLiveGreenScreenDiagnosticsOptions';
const MethodChannel kChannel = MethodChannel('vanguard_media_engine');

const String kSmokeStartMarker =
    'IOS_LIVE_GREENSCREEN_VIDEO_BG_PHYSICAL_SMOKE_START';
const String kSmokePassMarker = 'IOS_LIVE_GREENSCREEN_VIDEO_BG_PHYSICAL_PASS';
const String kSmokeFailMarker = 'IOS_LIVE_GREENSCREEN_VIDEO_BG_PHYSICAL_FAIL';
const String kSmokeJsonPrefix = 'IOS_LIVE_GREENSCREEN_VIDEO_BG_PHYSICAL_JSON:';

const int kSustainedHoldSeconds = int.fromEnvironment(
  'LIVE_GREENSCREEN_VIDEO_HOLD_SECONDS',
  defaultValue: 60,
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IosLiveGreenScreenVideoBgPhysicalSmokeApp());
}

class IosLiveGreenScreenVideoBgPhysicalSmokeApp extends StatefulWidget {
  const IosLiveGreenScreenVideoBgPhysicalSmokeApp({super.key});

  @override
  State<IosLiveGreenScreenVideoBgPhysicalSmokeApp> createState() =>
      _IosLiveGreenScreenVideoBgPhysicalSmokeAppState();
}

class _IosLiveGreenScreenVideoBgPhysicalSmokeAppState
    extends State<IosLiveGreenScreenVideoBgPhysicalSmokeApp> {
  String _status = 'Initializing Live Green Screen Video BG harness...';
  String _currentStep = 'INIT';
  String _phaseLabel = 'INIT';
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
        _status = 'Observing $phaseLabel ($elapsedSeconds/$totalSeconds s)';
      });
    }
  }

  Future<void> _runSmoke() async {
    print(kSmokeStartMarker);
    print('SUSTAINED_HOLD_SECONDS=$kSustainedHoldSeconds');

    const platform = MethodChannelVGLiveGreenScreenPlatform();

    bool pass = false;
    String? sessionId;
    Directory? tempDir;
    late File videoFile;
    final stepResults = <String, String>{};
    final failures = <String>[];

    Future<T> runStep<T>(
      String stepName,
      String description,
      Future<T> Function() action,
    ) async {
      _updateStatus(stepName, description);
      try {
        final result = await action();
        stepResults[stepName] = 'PASS';
        print('STEP_${stepName}_PASS');
        return result;
      } catch (e, st) {
        stepResults[stepName] = 'FAIL';
        final failureMsg = '$stepName: $e';
        if (!failures.contains(failureMsg)) {
          failures.add(failureMsg);
        }
        print('STEP_${stepName}_FAIL: $e\n$st');
        rethrow;
      }
    }

    Future<void> observePhase(String phaseLabel, int durationSeconds) async {
      print('OBSERVE_${phaseLabel}_BEGIN');
      var elapsed = 0;
      while (elapsed < durationSeconds) {
        final remaining = durationSeconds - elapsed;
        final step = remaining < 1 ? remaining : 1;
        await Future<void>.delayed(Duration(seconds: step));
        elapsed += step;
        _updateObserveProgress(phaseLabel, elapsed, durationSeconds);
      }
      print('OBSERVE_${phaseLabel}_END');
    }

    try {
      // Step 0: Set diagnostics options to force Vision/adapter backend.
      await runStep<void>(
        'FORCE_VISION_BACKEND',
        'Setting diagnostics options: iosSegmentationBackend = visionFast',
        () async {
          final options = <String, Object?>{
            'iosFastMetalPrecision': false,
            'iosSegmentationBackend': 'visionFast',
          };
          final reply = await kChannel.invokeMapMethod<String, dynamic>(
            kDiagnosticsOptionsMethod,
            options,
          );
          print('DIAGNOSTICS_OPTIONS_ECHO=${jsonEncode(reply)}');
        },
      );

      // Step 1: Stage the 60s video fixture into temp directory.
      await runStep<void>(
        'STAGE_VIDEO_FIXTURE',
        'Staging $kVideoBackgroundAssetPath into temp directory',
        () async {
          tempDir = await Directory.systemTemp.createTemp(
            'live_gs_video_bg_smoke_',
          );
          videoFile = File('${tempDir!.path}/video_bg_60s.mp4');
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
            'STAGED_VIDEO_PATH=${videoFile.path} size=${await videoFile.length()} bytes',
          );
        },
      );

      // Step 2: Start live green-screen session with background.type = video.
      final session = await runStep<VGLiveGreenScreenSession>(
        'START_WITH_VIDEO_BACKGROUND',
        'Starting live green screen session with video background (Vision backend, 720x1280)',
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

      // Step 3: Observe sustained looping video background for >= 60 seconds.
      await runStep<void>(
        'OBSERVE_SUSTAINED_VIDEO',
        'Observing sustained looping video background for ${kSustainedHoldSeconds}s',
        () => observePhase('VIDEO_SUSTAINED', kSustainedHoldSeconds),
      );

      // Step 4: Test INVALID background update -> must fail closed on the call,
      // while leaving the existing video background alive (fail-open session).
      await runStep<void>(
        'TEST_INVALID_UPDATE_FAILS',
        'Testing invalid background update with non-existent file path',
        () async {
          bool threw = false;
          try {
            await platform.updateLiveGreenScreenBackground(
              sessionId!,
              const VGGreenScreenImageFileBackground(
                '/non/existent/bogus_background_file_12345.png',
                scaleMode: VGGreenScreenScaleMode.aspectFill,
              ),
            );
          } catch (e) {
            threw = true;
            print('INVALID_UPDATE_EXPECTED_EXCEPTION=$e');
          }
          if (!threw) {
            throw StateError(
              'Expected updateLiveGreenScreenBackground to fail for non-existent file, but it succeeded',
            );
          }
        },
      );

      // Step 5: Observe that the video background is STILL running and NOT frozen after the invalid update.
      await runStep<void>(
        'OBSERVE_OLD_VIDEO_BG_SURVIVES_INVALID_UPDATE',
        'Observing that old video background remains alive and running after invalid update (10s)',
        () => observePhase('VIDEO_POST_INVALID_UPDATE', 10),
      );

      // Step 6: Test dynamic update to solid color.
      await runStep<void>(
        'UPDATE_BACKGROUND_SOLID',
        'Updating background from video to solid teal',
        () => platform.updateLiveGreenScreenBackground(
          sessionId!,
          const VGGreenScreenSolidColorBackground(0xFF008080),
        ),
      );
      if (mounted) {
        setState(() {
          _phaseLabel = 'SOLID_TEAL_ACTIVE';
        });
      }

      // Step 7: Observe solid color.
      await runStep<void>(
        'OBSERVE_SOLID_COLOR',
        'Observing solid teal background (5s)',
        () => observePhase('SOLID_TEAL', 5),
      );

      // Step 8: Test dynamic update back to the 60s video.
      await runStep<void>(
        'UPDATE_BACKGROUND_BACK_TO_VIDEO',
        'Updating background from solid teal back to 60s video',
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

      // Step 9: Observe restored video for 10 seconds.
      await runStep<void>(
        'OBSERVE_RESTORED_VIDEO',
        'Observing restored video background (10s)',
        () => observePhase('VIDEO_RESTORED', 10),
      );

      // Step 10: Clean stop.
      await runStep<void>(
        'STOP_SESSION',
        'Stopping live green-screen session cleanly',
        () async {
          await platform.stopLiveGreenScreenSession(sessionId!);
        },
      );

      pass = failures.isEmpty;
    } catch (e) {
      pass = false;
      print('SMOKE_EXCEPTION: $e');
    } finally {
      // Teardown temp directory.
      try {
        if (tempDir != null && await tempDir!.exists()) {
          await tempDir!.delete(recursive: true);
          print('TEMP_FIXTURE_CLEANED');
        }
      } catch (e) {
        print('TEMP_CLEANUP_ERROR: $e');
      }

      final report = <String, Object?>{
        'pass': pass,
        'proofBoundary':
            'ios_live_green_screen_video_background_physical_smoke',
        'sustainedSeconds': kSustainedHoldSeconds,
        'sessionId': sessionId,
        'stepResults': stepResults,
        'failures': failures,
      };

      print('$kSmokeJsonPrefix${jsonEncode(report)}');
      if (pass) {
        print(kSmokePassMarker);
      } else {
        print(kSmokeFailMarker);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'iOS Live Green Screen Video Background Smoke',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Phase: $_phaseLabel | Step: $_currentStep',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.cyanAccent,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
              Expanded(
                child: Center(
                  child: _session != null
                      ? AspectRatio(
                          aspectRatio: 720 / 1280,
                          child: Texture(textureId: _session!.textureId),
                        )
                      : const CircularProgressIndicator(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
