// Copyright 2026, Connects. All rights reserved.
// ios_duet_pixel_proof_smoke.dart
//
// iOS Duet deterministic CoreImage/Metal matte-blend pixel proof harness
// (diagnostic-only, simulator-safe).
//
// Proves that the existing VGDuetPreviewCompositor green-screen path
// (CIBlendWithMask) blends a synthetic camera foreground over a synthetic
// source/background through a single-channel mask, with pixel assertions.
// Also proves deterministic Duet straight-alpha foreground free-transform
// rotation/off-canvas pixel behavior via a real VGDuetPreviewCompositor
// instance (DEC-V2-123C follow-up).
//
// Proof boundary:
//   ios_duet_coreimage_pixel_proof_synthetic_mask_blend_only
//
// Non-claims: no real camera hardware or AVCaptureSession lifecycle, no
// Vision/ML segmentation quality, no video decoder, no MP4 export, no audio,
// no ConnectsApp/Universal Editor/upload wiring.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String kSmokeStartMarker = 'IOS_DUET_PIXEL_PROOF_START';
const String kSmokePassMarker = 'IOS_DUET_PIXEL_PROOF_PASS';
const String kSmokeFailMarker = 'IOS_DUET_PIXEL_PROOF_FAIL';
const String kSmokeJsonPrefix = 'IOS_DUET_PIXEL_PROOF_JSON:';

const String kExpectedProofBoundary =
    'ios_duet_coreimage_pixel_proof_synthetic_mask_blend_only';

const String kMethodChannelName = 'vanguard_media_engine';
const String kProbeMethod = 'runIosDuetPixelProof';

const List<String> kExpectedGateKeys = <String>[
  'compositorInitOk',
  'syntheticBuffersOk',
  'blendFilterOk',
  'boundaryKeyingOk',
  'fractionalBlendMathOk',
  'viewportExteriorOk',
  'cleanupOk',
  'canonical',
  // DEC-V2-123C follow-up: Duet straight-alpha foreground free-transform
  // rotation/off-canvas rendered pixel proof lane (VGDuetPreviewCompositor,
  // not VGLiveGreenScreenCompositor). The harness fails unless these pass
  // alongside the CIBlendWithMask gates above.
  'straightAlphaRotation0Ok',
  'straightAlphaRotation90Ok',
  'straightAlphaRgbAlphaCoTransformOk',
  'straightAlphaOffCanvasClipOk',
  'rotationCanonicalOk',
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IosDuetPixelProofSmokeApp());
}

class IosDuetPixelProofSmokeApp extends StatefulWidget {
  const IosDuetPixelProofSmokeApp({super.key});

  @override
  State<IosDuetPixelProofSmokeApp> createState() =>
      _IosDuetPixelProofSmokeAppState();
}

class _IosDuetPixelProofSmokeAppState extends State<IosDuetPixelProofSmokeApp> {
  static const MethodChannel _channel = MethodChannel(kMethodChannelName);

  String _status = 'Starting iOS Duet pixel proof...';
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
    _updateStatus('RUNNING', 'Invoking native iOS Duet pixel proof harness...');

    bool pass = false;
    dynamic rawResult;
    String? errorMessage;

    try {
      rawResult = await _channel
          .invokeMethod<dynamic>(kProbeMethod)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
              'iOS Duet pixel proof timed out after 30 seconds',
            ),
          );

      if (rawResult is Map) {
        final resultMap = Map<String, dynamic>.from(rawResult);
        final rawPass = resultMap['pass'] == true;
        final rawMarker = resultMap['marker'];
        final rawBoundary = resultMap['proofBoundary'];
        final rawGates = resultMap['gates'];
        final rawMaxDelta = resultMap['maxDelta'];
        final rawTolerance = resultMap['tolerance'];
        final rawSampleCount = resultMap['sampleCount'];
        final rawMismatches = resultMap['mismatches'];

        final gatesMap = rawGates is Map
            ? Map<String, dynamic>.from(rawGates)
            : <String, dynamic>{};
        final allGatesPresent = kExpectedGateKeys.every(gatesMap.containsKey);
        final allGatesPass =
            allGatesPresent &&
            kExpectedGateKeys.every((key) => gatesMap[key] == true);

        final maxDelta = (rawMaxDelta is num)
            ? rawMaxDelta.toDouble()
            : double.infinity;
        final tolerance = (rawTolerance is num)
            ? rawTolerance.toDouble()
            : -1.0;
        final sampleCount = (rawSampleCount is num)
            ? rawSampleCount.toInt()
            : 0;
        final mismatchesEmpty = rawMismatches is List && rawMismatches.isEmpty;

        if (rawPass &&
            rawMarker == kSmokePassMarker &&
            rawBoundary == kExpectedProofBoundary &&
            allGatesPass &&
            maxDelta <= tolerance &&
            sampleCount >= 5 &&
            mismatchesEmpty) {
          pass = true;
          if (mounted) {
            setState(() {
              _resultDetails = resultMap;
            });
          }
        } else {
          pass = false;
          errorMessage =
              'Result validation failed: pass=$rawPass, marker=$rawMarker, '
              'boundary=$rawBoundary, allGatesPass=$allGatesPass, '
              'maxDelta=$maxDelta, tolerance=$tolerance, '
              'sampleCount=$sampleCount, mismatchesEmpty=$mismatchesEmpty';
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
      _updateStatus(
        'PASS',
        'Deterministic iOS Duet pixel proof passed '
            '(mask blend + straight-alpha rotation/off-canvas)',
      );
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
                  'iOS Duet Pixel Proof',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const Text(
                  'Mask blend + straight-alpha rotation/off-canvas',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
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
