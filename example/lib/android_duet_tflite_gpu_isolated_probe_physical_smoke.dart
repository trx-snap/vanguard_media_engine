// Copyright 2026, Connects. All rights reserved.
// android_duet_tflite_gpu_isolated_probe_physical_smoke.dart
//
// Frozen Android Duet OUT-OF-PROCESS forced raw TensorFlow Lite GPU
// diagnostic probe physical smoke harness.
//
// Why this exists:
//   MediaPipe Tasks GPU SIGABRTs below the JVM on SM-A566B / Android 16 for
//   both confidence and category masks, and the in-process raw TFLite probe
//   respects CompatibilityList (supported=false on that device), so it never
//   reaches the GPU delegate. This harness drives an example-app-only native
//   route where the raw GPU delegate is FORCED (CompatibilityList recorded but
//   bypassed) inside a separate child process (android:process=":gpuprobe").
//   A vendor/native abort can only kill the child; the parent Flutter process
//   observes binder death and reports it as a normal payload.
//
// Proof boundary:
//   - Device requirement: Android physical device, debuggable example app.
//     No camera permission needed (one synthetic RGB frame, no CameraX).
//   - Harness command:
//       cd packages/vanguard_media_engine/example && flutter run -d <deviceId> -t lib/android_duet_tflite_gpu_isolated_probe_physical_smoke.dart
//   - Native structured logs (logcat tag DuetTfliteGpuIsolated; child lines
//     carry the :gpuprobe pid, so use logcat rather than only the flutter
//     console). Child markers are also relayed inside the JSON payload under
//     nativeResult.child.markers when the child replies.
//       ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_START
//       ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_START
//       ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_COMPAT supported=<true|false> bypass=true
//       ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_INTERPRETER_READY inputShape=... outputShape=...
//       ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_PROBE_PASS ...
//       ANDROID_DUET_TFLITE_GPU_ISOLATED_CHILD_PROBE_FAIL code=... message=...
//       ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_CHILD_DIED
//       ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_ALIVE_AFTER_CHILD_DEATH
//       ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_ALIVE_AFTER_RESULT
//   - Dart pass marker is printed ONLY when one of these holds:
//       * mode=forced_gpu_completed: the forced GPU invoke completed with
//         non-zero output coverage in the child.
//       * mode=child_process_died_parent_survived: the child died before
//         replying AND the parent returned its alive proof.
//     Both are distinguishable through `mode` / `result` in the JSON line.
//   - Claims allowed:
//       * example-only debug native route in a separate child process
//       * no live Duet session, no CameraX
//       * parent process survives a child GPU abort (if that mode passes)
//       * forced raw TFLite GPU delegate ran one synthetic frame (if that
//         mode passes)
//   - Non-claims:
//       * no production enablement (ladder stays mediapipe_cpu -> mlkit -> none)
//       * no quality proof (synthetic frame; matte content is not judged)
//       * no MediaPipe Tasks GPU proof
//       * no MLKit fallback wiring proof
//       * no export/audio/app wiring proof
//       * no low-end/budget Android proof

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String kSmokeStartMarker =
    'ANDROID_DUET_TFLITE_GPU_ISOLATED_PHYSICAL_SMOKE_START';
const String kSmokePassMarker =
    'ANDROID_DUET_TFLITE_GPU_ISOLATED_PHYSICAL_PASS';
const String kSmokeFailMarker =
    'ANDROID_DUET_TFLITE_GPU_ISOLATED_PHYSICAL_FAIL';
const String kSmokeJsonPrefix =
    'ANDROID_DUET_TFLITE_GPU_ISOLATED_PHYSICAL_JSON:';

const String kProbeChannel =
    'vanguard_media_engine_example/tflite_gpu_isolated_probe';
const String kProbeMethod = 'runTfliteGpuIsolatedProbe';
const Duration kProbeTimeout = Duration(seconds: 35);
const String kModelAssetPath = String.fromEnvironment(
  'DUET_GPU_PROBE_MODEL_ASSET',
  defaultValue: 'selfie_segmenter.tflite',
);

const String kModeForcedGpuCompleted = 'forced_gpu_completed';
const String kModeChildDiedParentSurvived =
    'child_process_died_parent_survived';
const String kModeChildProbeFailed = 'child_probe_failed';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetTfliteGpuIsolatedProbeSmokeApp());
}

class AndroidDuetTfliteGpuIsolatedProbeSmokeApp extends StatefulWidget {
  const AndroidDuetTfliteGpuIsolatedProbeSmokeApp({super.key});

  @override
  State<AndroidDuetTfliteGpuIsolatedProbeSmokeApp> createState() =>
      _AndroidDuetTfliteGpuIsolatedProbeSmokeAppState();
}

class _AndroidDuetTfliteGpuIsolatedProbeSmokeAppState
    extends State<AndroidDuetTfliteGpuIsolatedProbeSmokeApp> {
  static const MethodChannel _channel = MethodChannel(kProbeChannel);

  String _status = 'Starting isolated forced raw TFLite GPU probe...';
  String _step = 'INIT';
  Map<String, dynamic>? _resultDetails;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_started) return;
      _started = true;
      _runProbe();
    });
  }

  void _updateStatus(String step, String status) {
    if (mounted) {
      setState(() {
        _step = step;
        _status = status;
      });
    }
  }

  Future<void> _runProbe() async {
    print(kSmokeStartMarker);
    _updateStatus(
      'RUNNING',
      'Binding :gpuprobe child process and forcing the raw TFLite GPU delegate...',
    );

    bool pass = false;
    String? mode;
    String result = 'fail';
    dynamic rawResult;
    Map<String, dynamic>? native;
    String? errorCode;
    String? errorMessage;

    try {
      rawResult = await _channel
          .invokeMethod<dynamic>(kProbeMethod, <String, dynamic>{
            'modelAssetPath': kModelAssetPath,
          })
          .timeout(
            kProbeTimeout,
            onTimeout: () => throw TimeoutException(
              'Probe timed out after ${kProbeTimeout.inSeconds}s waiting for native response',
            ),
          );

      if (rawResult is Map) {
        native = Map<String, dynamic>.from(rawResult);
        mode = native['mode'] as String?;
        final parentAlive = native['parentAlive'] == true;
        switch (mode) {
          case kModeForcedGpuCompleted:
            final child = native['child'];
            final nonZero = child is Map ? child['outputNonZeroTotal'] : null;
            final coverage = nonZero is num && nonZero > 0;
            if (native['pass'] == true && coverage && parentAlive) {
              pass = true;
              result = 'forced_gpu_invoke_completed_nonzero_output';
            } else {
              errorCode = 'forced_gpu_zero_coverage';
              errorMessage =
                  'mode=forced_gpu_completed but pass=${native['pass']} outputNonZeroTotal=$nonZero parentAlive=$parentAlive';
            }
          case kModeChildDiedParentSurvived:
            if (native['code'] == 'child_process_died' &&
                native['childDied'] == true &&
                parentAlive) {
              pass = true;
              result = 'child_process_died_parent_alive_proof_returned';
            } else {
              errorCode = 'child_death_without_alive_proof';
              errorMessage =
                  'mode=child_process_died_parent_survived but code=${native['code']} childDied=${native['childDied']} parentAlive=$parentAlive';
            }
          case kModeChildProbeFailed:
            errorCode = (native['code'] as String?) ?? 'child_probe_failed';
            errorMessage =
                (native['message'] as String?) ??
                'Child reported a catchable failure';
            result = 'child_catchable_failure';
          default:
            errorCode = 'unexpected_mode';
            errorMessage = 'Probe returned unexpected mode=$mode: $rawResult';
        }
      } else {
        errorCode = 'unexpected_result';
        errorMessage = 'Probe returned unexpected result: $rawResult';
      }
    } on PlatformException catch (e, st) {
      errorCode = e.code;
      errorMessage = '${e.message}\n${e.details}\n$st';
      final details = e.details;
      if (details is Map) {
        mode = details['mode'] as String?;
      }
      result = errorCode == 'timeout' ? 'parent_timeout' : 'parent_failure';
    } on MissingPluginException catch (e, st) {
      errorCode = 'missing_native_method';
      errorMessage = '$e\n$st';
    } on TimeoutException catch (e, st) {
      errorCode = 'dart_timeout';
      errorMessage = '$e\n$st';
      result = 'dart_timeout';
    } catch (e, st) {
      errorCode = 'unexpected_error';
      errorMessage = '$e\n$st';
    }

    if (mounted && native != null) {
      setState(() {
        _resultDetails = native;
      });
    }

    final payload = <String, Object?>{
      'pass': pass,
      'mode': mode,
      'result': result,
      'proofBoundary': 'android_duet_tflite_gpu_isolated_probe_physical_smoke',
      'route': 'raw_tflite_interpreter_forced_gpu_delegate_isolated_process',
      'childProcess': ':gpuprobe',
      'channel': kProbeChannel,
      'method': kProbeMethod,
      'modelAssetPath': kModelAssetPath,
      'passModes': const <String>[
        kModeForcedGpuCompleted,
        kModeChildDiedParentSurvived,
      ],
      'claimsAllowed': <String>[
        'example-only debug native route in a separate child process',
        'no live Duet session, no CameraX',
        'parent process survives a child GPU abort (child_process_died_parent_survived only)',
        'forced raw TFLite GPU delegate ran one synthetic frame (forced_gpu_completed only)',
      ],
      'nonClaims': <String>[
        'no production enablement (ladder stays mediapipe_cpu -> mlkit -> none)',
        'no quality proof',
        'no MediaPipe Tasks GPU proof',
        'no MLKit fallback wiring proof',
        'no export/audio/app wiring proof',
        'no low-end/budget Android proof',
      ],
      if (rawResult != null) 'nativeResult': rawResult,
      if (errorCode != null) 'errorCode': errorCode,
      if (errorMessage != null) 'error': errorMessage,
    };

    print('$kSmokeJsonPrefix${jsonEncode(payload)}');
    if (pass) {
      print(kSmokePassMarker);
      _updateStatus(
        'PASS',
        mode == kModeForcedGpuCompleted
            ? 'Forced raw TFLite GPU invoke completed in :gpuprobe with non-zero output; parent alive'
            : ':gpuprobe child died; parent observed binder death and stayed alive',
      );
    } else {
      print(kSmokeFailMarker);
      _updateStatus('FAIL', errorMessage ?? 'Probe failed');
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Android Duet isolated forced raw TFLite GPU Probe',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Example-only. Child process :gpuprobe. Not production enablement.',
                    style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Step: $_step',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Status: $_status',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  if (_resultDetails != null) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Native Details:',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    Text(
                      jsonEncode(_resultDetails),
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
