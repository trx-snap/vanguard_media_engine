// Copyright 2026, Connects. All rights reserved.
// android_duet_gpu_category_mask_probe_physical_smoke.dart
//
// Frozen Android Duet GPU category-mask diagnostic probe physical smoke harness.
//
// Proof boundary:
//   - Device requirement: Android physical device with camera permission available.
//   - Harness command:
//       cd packages/vanguard_media_engine/example && flutter run -d <deviceId> -t lib/android_duet_gpu_category_mask_probe_physical_smoke.dart
//   - Claims allowed:
//       * example-only debug native route
//       * no live Duet session
//       * MediaPipe GPU category-mask conversion survived 30 frames if pass
//       * clean close
//   - Non-claims:
//       * no production enablement
//       * no confidence-mask GPU proof
//       * no MLKit fallback proof
//       * no matte quality proof
//       * no export/audio/app wiring proof
//       * no low-end/budget Android proof

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String kSmokeStartMarker =
    'ANDROID_DUET_GPU_CATEGORY_MASK_PHYSICAL_SMOKE_START';
const String kSmokePassMarker = 'ANDROID_DUET_GPU_CATEGORY_MASK_PHYSICAL_PASS';
const String kSmokeFailMarker = 'ANDROID_DUET_GPU_CATEGORY_MASK_PHYSICAL_FAIL';
const String kSmokeJsonPrefix = 'ANDROID_DUET_GPU_CATEGORY_MASK_PHYSICAL_JSON:';

const String kProbeChannel =
    'vanguard_media_engine_example/gpu_category_mask_probe';
const String kProbeMethod = 'runGpuCategoryMaskProbe';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetGpuCategoryMaskProbeSmokeApp());
}

class AndroidDuetGpuCategoryMaskProbeSmokeApp extends StatefulWidget {
  const AndroidDuetGpuCategoryMaskProbeSmokeApp({super.key});

  @override
  State<AndroidDuetGpuCategoryMaskProbeSmokeApp> createState() =>
      _AndroidDuetGpuCategoryMaskProbeSmokeAppState();
}

class _AndroidDuetGpuCategoryMaskProbeSmokeAppState
    extends State<AndroidDuetGpuCategoryMaskProbeSmokeApp> {
  static const MethodChannel _channel = MethodChannel(kProbeChannel);

  String _status = 'Starting GPU category mask probe...';
  String _step = 'INIT';
  Map<String, dynamic>? _resultDetails;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    _updateStatus('RUNNING', 'Invoking native GPU category mask probe...');

    bool pass = false;
    dynamic rawResult;
    String? errorMessage;

    try {
      rawResult = await _channel
          .invokeMethod<dynamic>(kProbeMethod)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
              'Probe timed out after 30 seconds waiting for native response',
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
        pass = false;
        errorMessage = 'Probe returned unexpected result: $rawResult';
      }
    } catch (e, st) {
      pass = false;
      errorMessage = '$e\n$st';
    }

    final payload = <String, Object?>{
      'pass': pass,
      'proofBoundary': 'android_duet_gpu_category_mask_probe_physical_smoke',
      'claimsAllowed': <String>[
        'example-only debug native route',
        'no live Duet session',
        'MediaPipe GPU category-mask conversion survived 30 frames if pass',
        'clean close',
      ],
      'nonClaims': <String>[
        'no production enablement',
        'no confidence-mask GPU proof',
        'no MLKit fallback proof',
        'no matte quality proof',
        'no export/audio/app wiring proof',
        'no low-end/budget Android proof',
      ],
      if (rawResult != null) 'nativeResult': rawResult,
      if (errorMessage != null) 'error': errorMessage,
    };

    print('$kSmokeJsonPrefix${jsonEncode(payload)}');
    if (pass) {
      print(kSmokePassMarker);
      _updateStatus('PASS', '30 frames processed without abort; clean close');
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Android Duet GPU Category Mask Diagnostic Probe',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
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
    );
  }
}
