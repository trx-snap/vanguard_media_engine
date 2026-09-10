// Copyright 2026, Connects. All rights reserved.
// android_duet_gles_pixel_proof_physical_smoke.dart
//
// Frozen Android Duet deterministic GLES matte-upload + composited-pixel proof harness (Stage 1).
//
// Proof boundary:
//   - Device requirement: Android physical device with GLES 2.0 support.
//   - Claims allowed:
//       * GLES 2.0 mask upload with GL_UNPACK_ALIGNMENT=1
//       * UINT8_ALPHA and FLOAT32_CONFIDENCE conversion and upload
//       * Deterministic GLES green-screen blend math and boundary keying
//       * Viewport/scissor exterior isolation
//   - Non-claims:
//       * No ML human matte quality claim (synthetic mask patterns only)
//       * No CameraX or OES external texture claim (sampler2D synthetic camera used)
//       * No live preview lifecycle or SurfaceTexture concurrency claim
//       * No export MP4, MediaCodec, or A/V sync claim
//       * No GPU delegate promotion or TFLite/MediaPipe runtime claim

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String kSmokeStartMarker = 'ANDROID_DUET_GLES_PIXEL_PROOF_START';
const String kSmokePassMarker = 'ANDROID_DUET_GLES_PIXEL_PROOF_PHYSICAL_PASS';
const String kSmokeFailMarker = 'ANDROID_DUET_GLES_PIXEL_PROOF_PHYSICAL_FAIL';
const String kSmokeJsonPrefix = 'ANDROID_DUET_GLES_PIXEL_PROOF_JSON:';

const String kExpectedProofBoundary =
    'android_duet_gles_pixel_proof_synthetic_mask_upload_and_blend_only';

const String kProbeChannel =
    'vanguard_media_engine_example/duet_gles_pixel_proof';
const String kProbeMethod = 'runAndroidDuetGlesPixelProof';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndroidDuetGlesPixelProofSmokeApp());
}

class AndroidDuetGlesPixelProofSmokeApp extends StatefulWidget {
  const AndroidDuetGlesPixelProofSmokeApp({super.key});

  @override
  State<AndroidDuetGlesPixelProofSmokeApp> createState() =>
      _AndroidDuetGlesPixelProofSmokeAppState();
}

class _AndroidDuetGlesPixelProofSmokeAppState
    extends State<AndroidDuetGlesPixelProofSmokeApp> {
  static const MethodChannel _channel = MethodChannel(kProbeChannel);

  String _status = 'Starting GLES pixel proof...';
  String _step = 'INIT';
  Map<String, dynamic>? _resultDetails;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runProof();
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

  Future<void> _runProof() async {
    print(kSmokeStartMarker);
    _updateStatus('RUNNING', 'Invoking native GLES pixel proof harness...');

    bool pass = false;
    dynamic rawResult;
    String? errorMessage;

    try {
      rawResult = await _channel
          .invokeMethod<dynamic>(kProbeMethod)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
              'GLES pixel proof timed out after 30 seconds',
            ),
          );

      if (rawResult is Map) {
        final resultMap = Map<String, dynamic>.from(rawResult);
        final rawPass = resultMap['pass'] == true;
        final rawMarker = resultMap['marker'];
        final rawBoundary = resultMap['proofBoundary'];

        if (rawPass &&
            rawMarker == kSmokePassMarker &&
            rawBoundary == kExpectedProofBoundary) {
          pass = true;
          if (mounted) {
            setState(() {
              _resultDetails = resultMap;
            });
          }
        } else {
          pass = false;
          errorMessage =
              'Result validation failed: pass=$rawPass, marker=$rawMarker, boundary=$rawBoundary';
        }
      } else {
        pass = false;
        errorMessage = 'Harness returned unexpected non-map result: $rawResult';
      }
    } catch (e, st) {
      pass = false;
      errorMessage = '$e\n$st';
    }

    final Map<String, Object?> fallbackMap = <String, Object?>{
      'pass': false,
      'marker': kSmokeFailMarker,
      'proofBoundary': kExpectedProofBoundary,
    };
    if (errorMessage != null) {
      fallbackMap['error'] = errorMessage;
    }
    final dynamic jsonMap = rawResult is Map ? rawResult : fallbackMap;

    print('$kSmokeJsonPrefix${jsonEncode(jsonMap)}');

    if (pass) {
      print(kSmokePassMarker);
      _updateStatus('PASS', 'Deterministic GLES pixel proof passed');
    } else {
      print(kSmokeFailMarker);
      _updateStatus('FAIL', errorMessage ?? 'Proof failed');
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
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Android Duet GLES Pixel Proof',
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
                    'Proof Details:',
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
