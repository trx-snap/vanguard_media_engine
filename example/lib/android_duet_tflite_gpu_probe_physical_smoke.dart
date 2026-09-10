// Copyright 2026, Connects. All rights reserved.
// android_duet_tflite_gpu_probe_physical_smoke.dart
//
// Frozen Android Duet raw TensorFlow Lite GPU Interpreter diagnostic probe
// physical smoke harness.
//
// Why this exists:
//   MediaPipe Tasks GPU native-aborted on SM-A566B / Android 16 for both the
//   confidence-mask and category-mask routes (image_frame.cc Format UNKNOWN).
//   This harness drives an example-app-only native route that owns a raw
//   `org.tensorflow.lite.Interpreter` with a standalone `GpuDelegate`, owning
//   the input/output tensor buffers directly, with no MediaPipe layer.
//
// Proof boundary:
//   - Device requirement: Android physical device with a front camera and the
//     CAMERA permission already granted to the debuggable example app, e.g.
//       adb shell pm grant com.example.vanguard_media_engine_example android.permission.CAMERA
//   - Harness command:
//       cd packages/vanguard_media_engine/example && flutter run -d <deviceId> -t lib/android_duet_tflite_gpu_probe_physical_smoke.dart
//   - Native structured logs (logcat / stdout, tag DuetTfliteGpuProbe):
//       ANDROID_DUET_TFLITE_GPU_PROBE_START
//       ANDROID_DUET_TFLITE_GPU_COMPAT supported=... delegate=standalone
//       ANDROID_DUET_TFLITE_GPU_INTERPRETER_READY inputShape=... inputType=... outputShape=... outputType=...
//       ANDROID_DUET_TFLITE_GPU_FIRST frames=1 outputMin=... outputMax=... positive=... nonZero=...
//       ANDROID_DUET_TFLITE_GPU_PROGRESS frames=...
//       ANDROID_DUET_TFLITE_GPU_CLOSE_PASS
//       ANDROID_DUET_TFLITE_GPU_PROBE_PASS frames=30 ...
//       ANDROID_DUET_TFLITE_GPU_PROBE_FAIL code=... message=...   (catchable error)
//     A vendor GPU-driver native abort (Fatal signal 6) kills the process before
//     any Dart marker; that is itself diagnostic evidence.
//   - Claims allowed:
//       * example-only debug native route
//       * no live Duet session
//       * raw TFLite GPU delegate/interpreter survived 30 frames if pass
//       * clean close
//   - Non-claims:
//       * no production enablement
//       * no MediaPipe Tasks GPU proof
//       * no MLKit fallback wiring proof
//       * no matte quality proof
//       * no export/audio/app wiring proof
//       * no low-end/budget Android proof

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String kSmokeStartMarker = 'ANDROID_DUET_TFLITE_GPU_PHYSICAL_SMOKE_START';
const String kSmokePassMarker = 'ANDROID_DUET_TFLITE_GPU_PHYSICAL_PASS';
const String kSmokeFailMarker = 'ANDROID_DUET_TFLITE_GPU_PHYSICAL_FAIL';
const String kSmokeJsonPrefix = 'ANDROID_DUET_TFLITE_GPU_PHYSICAL_JSON:';

const String kProbeChannel = 'vanguard_media_engine_example/tflite_gpu_probe';
const String kProbeMethod = 'runTfliteGpuProbe';
const Duration kProbeTimeout = Duration(seconds: 30);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetTfliteGpuProbeSmokeApp());
}

class AndroidDuetTfliteGpuProbeSmokeApp extends StatefulWidget {
  const AndroidDuetTfliteGpuProbeSmokeApp({super.key});

  @override
  State<AndroidDuetTfliteGpuProbeSmokeApp> createState() =>
      _AndroidDuetTfliteGpuProbeSmokeAppState();
}

class _AndroidDuetTfliteGpuProbeSmokeAppState
    extends State<AndroidDuetTfliteGpuProbeSmokeApp> {
  static const MethodChannel _channel = MethodChannel(kProbeChannel);

  String _status = 'Starting raw TFLite GPU probe...';
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
    _updateStatus('RUNNING', 'Invoking native raw TFLite GPU probe...');

    bool pass = false;
    dynamic rawResult;
    String? errorCode;
    String? errorMessage;

    try {
      rawResult = await _channel
          .invokeMethod<dynamic>(kProbeMethod)
          .timeout(
            kProbeTimeout,
            onTimeout: () => throw TimeoutException(
              'Probe timed out after ${kProbeTimeout.inSeconds}s waiting for native response',
            ),
          );

      if (rawResult is Map && rawResult['pass'] == true) {
        pass = true;
        if (mounted) {
          setState(() {
            _resultDetails = Map<String, dynamic>.from(rawResult);
          });
        }
      } else {
        errorCode = 'unexpected_result';
        errorMessage = 'Probe returned unexpected result: $rawResult';
      }
    } on PlatformException catch (e, st) {
      errorCode = e.code;
      errorMessage = '${e.message}\n${e.details}\n$st';
    } on MissingPluginException catch (e, st) {
      errorCode = 'missing_native_method';
      errorMessage = '$e\n$st';
    } on TimeoutException catch (e, st) {
      errorCode = 'dart_timeout';
      errorMessage = '$e\n$st';
    } catch (e, st) {
      errorCode = 'unexpected_error';
      errorMessage = '$e\n$st';
    }

    final payload = <String, Object?>{
      'pass': pass,
      'proofBoundary': 'android_duet_tflite_gpu_probe_physical_smoke',
      'route': 'raw_tflite_interpreter_standalone_gpu_delegate',
      'channel': kProbeChannel,
      'method': kProbeMethod,
      'claimsAllowed': <String>[
        'example-only debug native route',
        'no live Duet session',
        'raw TFLite GPU delegate/interpreter survived 30 frames if pass',
        'clean close',
      ],
      'nonClaims': <String>[
        'no production enablement',
        'no MediaPipe Tasks GPU proof',
        'no MLKit fallback wiring proof',
        'no matte quality proof',
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
        '30 GPU inferences completed without abort; interpreter and delegate closed cleanly',
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
                    'Android Duet raw TFLite GPU Diagnostic Probe',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Example-only. Not production enablement.',
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
