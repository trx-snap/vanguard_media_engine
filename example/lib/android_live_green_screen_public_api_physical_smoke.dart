// Copyright 2026, Connects. All rights reserved.
// android_live_green_screen_public_api_physical_smoke.dart
//
// Dedicated physical smoke harness proving the generic (caller-agnostic) live
// green-screen public Dart API can route a full session lifecycle through
// the platform interface: start with a shrunk/offset foreground over a solid
// background, update the foreground transform, update the background color,
// and stop — all while a bounded live preview texture is visible for manual
// observation.
//
// This harness exercises the public contracts in `vg_live_green_screen.dart`
// only (via `MethodChannelVGLiveGreenScreenPlatform`); it is not scoped to
// any caller such as Duet, live meeting/calling, or the Universal Editor.
//
// Proof boundary:
//   - Device requirement: Android physical device with camera permission
//     already granted via the external adb grant path (this harness does not
//     request permissions itself).
//   - Harness command:
//       cd packages/vanguard_media_engine/example &&
//       flutter run -d <deviceId> \
//         -t lib/android_live_green_screen_public_api_physical_smoke.dart \
//         --dart-define=LIVE_GREENSCREEN_PUBLIC_API_HOLD_SECONDS=8
//   - Claims allowed:
//       * public Dart API route via VGLiveGreenScreenPlatformInterface
//         (MethodChannelVGLiveGreenScreenPlatform)
//       * startLiveGreenScreenSession accepted (720x1280 canvas, solid teal
//         background, scale-0.75 offset foreground transform)
//       * updateLiveGreenScreenTransform accepted for a second foreground
//         placement
//       * updateLiveGreenScreenBackground accepted for a second solid
//         background color
//       * stopLiveGreenScreenSession accepted
//       * bounded live preview texture present for manual observation across
//         both the initial and updated phases
//   - Non-claims:
//       * no automated pixel or matte quality proof
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
import 'package:vanguard_media_engine/vg_green_screen.dart';
import 'package:vanguard_media_engine/vg_live_green_screen.dart';

const String kSmokeStartMarker =
    'ANDROID_LIVE_GREENSCREEN_PUBLIC_API_PHYSICAL_SMOKE_START';
const String kSolidObserveBeginMarker =
    'ANDROID_LIVE_GREENSCREEN_PUBLIC_API_OBSERVE_SOLID_BEGIN';
const String kSolidObserveEndMarker =
    'ANDROID_LIVE_GREENSCREEN_PUBLIC_API_OBSERVE_SOLID_END';
const String kUpdatedObserveBeginMarker =
    'ANDROID_LIVE_GREENSCREEN_PUBLIC_API_OBSERVE_UPDATED_BEGIN';
const String kUpdatedObserveEndMarker =
    'ANDROID_LIVE_GREENSCREEN_PUBLIC_API_OBSERVE_UPDATED_END';
const String kSmokeJsonPrefix = 'ANDROID_LIVE_GREENSCREEN_PUBLIC_API_JSON:';
const String kSmokePassMarker =
    'ANDROID_LIVE_GREENSCREEN_PUBLIC_API_PHYSICAL_PASS';
const String kSmokeFailMarker =
    'ANDROID_LIVE_GREENSCREEN_PUBLIC_API_PHYSICAL_FAIL';

/// Length of each observation phase (initial and updated), in seconds.
/// Override with `--dart-define=LIVE_GREENSCREEN_PUBLIC_API_HOLD_SECONDS=<n>`.
/// Clamped to a minimum of 2 seconds.
const int _rawHoldSeconds = int.fromEnvironment(
  'LIVE_GREENSCREEN_PUBLIC_API_HOLD_SECONDS',
  defaultValue: 8,
);
const int kHoldSeconds = _rawHoldSeconds < 2 ? 2 : _rawHoldSeconds;

/// Initial solid background: a teal shade.
const int kInitialBackgroundArgb = 0xFF00695C;

/// Updated solid background: a green shade, chosen to be visibly distinct
/// from [kInitialBackgroundArgb] so the UPDATE_BACKGROUND_SOLID step is
/// observable on device.
const int kUpdatedBackgroundArgb = 0xFF2E7D32;

/// Foreground transform passed to `startLiveGreenScreenSession`: shrinks the
/// keyed camera layer to 75% and offsets it up and to the right so it is
/// clearly smaller than and repositioned within the canvas.
const VGLiveGreenScreenForegroundTransform kInitialForegroundTransform =
    VGLiveGreenScreenForegroundTransform(
      scale: 0.75,
      offsetX: 0.12,
      offsetY: -0.12,
    );

/// Foreground transform passed to `updateLiveGreenScreenTransform`: a
/// distinctly smaller scale and a different (bottom-left) offset, so the
/// UPDATE_TRANSFORM step is observable on device.
const VGLiveGreenScreenForegroundTransform kUpdatedForegroundTransform =
    VGLiveGreenScreenForegroundTransform(
      scale: 0.45,
      offsetX: -0.28,
      offsetY: 0.3,
    );

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidLiveGreenScreenPublicApiPhysicalSmokeApp());
}

class AndroidLiveGreenScreenPublicApiPhysicalSmokeApp extends StatefulWidget {
  const AndroidLiveGreenScreenPublicApiPhysicalSmokeApp({super.key});

  @override
  State<AndroidLiveGreenScreenPublicApiPhysicalSmokeApp> createState() =>
      _AndroidLiveGreenScreenPublicApiPhysicalSmokeAppState();
}

class _AndroidLiveGreenScreenPublicApiPhysicalSmokeAppState
    extends State<AndroidLiveGreenScreenPublicApiPhysicalSmokeApp> {
  String _status = 'Starting live green-screen public API harness...';
  String _currentStep = 'INIT';
  String _phaseLabel = 'INIT';
  VGLiveGreenScreenSession? _session;
  int _eventCount = 0;
  int _phaseElapsedSeconds = 0;

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
    int eventCount,
  ) {
    if (mounted) {
      setState(() {
        _phaseLabel = phaseLabel;
        _phaseElapsedSeconds = elapsedSeconds;
        _eventCount = eventCount;
        _status = 'Observing $phaseLabel ($elapsedSeconds/$totalSeconds s)';
      });
    }
  }

  Future<void> _runSmoke() async {
    print(kSmokeStartMarker);

    const platform = MethodChannelVGLiveGreenScreenPlatform();

    bool pass = false;
    String? sessionId;
    bool stopped = false;
    final events = <Map<String, dynamic>>[];
    StreamSubscription<VGLiveGreenScreenEvent>? eventsSub;

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
        print('ANDROID_LIVE_GREENSCREEN_PUBLIC_API_STEP_${stepName}_PASS');
        return result;
      } catch (e, st) {
        stepResults[stepName] = 'FAIL';
        final failureMsg = '$stepName: $e';
        if (!failures.contains(failureMsg)) {
          failures.add(failureMsg);
        }
        print(
          'ANDROID_LIVE_GREENSCREEN_PUBLIC_API_STEP_${stepName}_FAIL: $e\n$st',
        );
        rethrow;
      }
    }

    Future<void> observePhase(
      String phaseLabel,
      String beginMarker,
      String endMarker,
    ) async {
      print(beginMarker);
      var elapsed = 0;
      while (elapsed < kHoldSeconds) {
        final remaining = kHoldSeconds - elapsed;
        final step = remaining < 1 ? remaining : 1;
        await Future<void>.delayed(Duration(seconds: step));
        elapsed += step;
        _updateObserveProgress(
          phaseLabel,
          elapsed,
          kHoldSeconds,
          events.length,
        );
      }
      print(endMarker);
    }

    try {
      // Subscribe before starting the session so no event is missed.
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

      // Step 1: Start the session (720x1280 canvas, solid teal background,
      // scale-0.75 offset foreground transform).
      final session = await runStep<VGLiveGreenScreenSession>(
        'START',
        'Starting live green-screen session (720x1280, teal, scale 0.75)',
        () {
          final config = VGLiveGreenScreenConfig(
            canvasSize: const VGGreenScreenSize(720, 1280),
            background: const VGGreenScreenSolidColorBackground(
              kInitialBackgroundArgb,
            ),
            foregroundTransform: kInitialForegroundTransform,
          );
          return platform.startLiveGreenScreenSession(config);
        },
      );
      sessionId = session.sessionId;
      if (mounted) {
        setState(() {
          _session = session;
          _phaseLabel = 'INITIAL (teal, scale 0.75)';
        });
      }

      // Step 2: Observe the initial solid background + shrunk foreground.
      await runStep<void>(
        'OBSERVE_SOLID',
        'Observing initial teal background and shrunk foreground (${kHoldSeconds}s)',
        () => observePhase(
          'INITIAL (teal, scale 0.75)',
          kSolidObserveBeginMarker,
          kSolidObserveEndMarker,
        ),
      );

      // Step 3: Update the foreground transform to a different scale/offset.
      await runStep<void>(
        'UPDATE_TRANSFORM',
        'Updating foreground transform (scale 0.45, bottom-left offset)',
        () => platform.updateLiveGreenScreenTransform(
          sessionId!,
          kUpdatedForegroundTransform,
        ),
      );

      // Step 4: Update the solid background to a different color.
      await runStep<void>(
        'UPDATE_BACKGROUND_SOLID',
        'Updating solid background to green',
        () => platform.updateLiveGreenScreenBackground(
          sessionId!,
          const VGGreenScreenSolidColorBackground(kUpdatedBackgroundArgb),
        ),
      );
      if (mounted) {
        setState(() {
          _phaseLabel = 'UPDATED (green, scale 0.45)';
        });
      }

      // Step 5: Observe the updated background + transform.
      await runStep<void>(
        'OBSERVE_UPDATED',
        'Observing updated green background and repositioned foreground (${kHoldSeconds}s)',
        () => observePhase(
          'UPDATED (green, scale 0.45)',
          kUpdatedObserveBeginMarker,
          kUpdatedObserveEndMarker,
        ),
      );

      // Step 6: Stop the session.
      await runStep<void>(
        'STOP',
        'Stopping live green-screen session',
        () async {
          await platform.stopLiveGreenScreenSession(sessionId!);
          stopped = true;
        },
      );

      pass = true;
    } catch (e) {
      pass = false;
    } finally {
      await eventsSub?.cancel();

      // Guaranteed cleanup fallback: stop the session exactly once if the
      // STOP step never ran or never completed.
      if (sessionId != null && !stopped) {
        try {
          await platform.stopLiveGreenScreenSession(sessionId);
          stopped = true;
        } catch (e) {
          print('ANDROID_LIVE_GREENSCREEN_PUBLIC_API: cleanup stop note: $e');
        }
      }

      final payload = <String, Object?>{
        'pass': pass,
        'proofBoundary': 'android_live_green_screen_public_api_physical_smoke',
        'holdSeconds': kHoldSeconds,
        'sessionId': sessionId,
        'textureId': _session?.textureId,
        'stepResults': stepResults,
        'failures': failures,
        'events': events,
        'claimsAllowed': <String>[
          'public Dart API route via VGLiveGreenScreenPlatformInterface (MethodChannelVGLiveGreenScreenPlatform)',
          'startLiveGreenScreenSession accepted (720x1280 canvas, solid teal background, scale-0.75 offset foreground transform)',
          'updateLiveGreenScreenTransform accepted for a second foreground placement',
          'updateLiveGreenScreenBackground accepted for a second solid background color',
          'stopLiveGreenScreenSession accepted',
          'bounded live preview texture present for manual observation across both the initial and updated phases',
        ],
        'nonClaims': <String>[
          'no automated pixel or matte quality proof',
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
                        'Android Live Green Screen Public API Physical Smoke',
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
                        'Phase: $_phaseLabel | Elapsed: ${_phaseElapsedSeconds}s / ${kHoldSeconds}s | Events: $_eventCount',
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
