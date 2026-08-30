// android_still_image_color_matrix_export_smoke.dart
// Vanguard Media Engine — Android timeline still-image export colorMatrix
// parity smoke harness (GLES 2D still-image draw path).
//
// Proof boundary: production_exportTimeline_still_image_color_matrix_gles_pixel_oracle
// Validates:
// 1. The production export session renders the still-image clip via the
//    GLES fallback backend (renderBackend == "gles") -- still-image clips
//    are outside AndroidExportRenderBackendSelector's Vulkan safe scope.
// 2. Lane A: a still image carrying a non-trivial 20-element 4x5 colorMatrix
//    is actually filtered by the GLES 2D still-image draw path (pixel
//    oracle matches the expected transformed RGB and diverges from source).
// 3. Lane B: a still image with no colorMatrix remains close to its source
//    color (regression against the pre-existing unfiltered passthrough).

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidStillImageColorMatrixExportSmokeApp());
}

class AndroidStillImageColorMatrixExportSmokeApp extends StatefulWidget {
  const AndroidStillImageColorMatrixExportSmokeApp({super.key});

  @override
  State<AndroidStillImageColorMatrixExportSmokeApp> createState() =>
      _AndroidStillImageColorMatrixExportSmokeAppState();
}

class _AndroidStillImageColorMatrixExportSmokeAppState
    extends State<AndroidStillImageColorMatrixExportSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android still-image colorMatrix export physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    print('ANDROID_STILL_IMAGE_COLOR_MATRIX_EXPORT_SMOKE: START');
    Map<String, dynamic> payload;

    try {
      final tempDir = Directory.systemTemp;
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidStillImageColorMatrixExportSmoke',
        <String, Object>{
          'outputDir': tempDir.path,
          'width': 1280,
          'height': 720,
          'fps': 30,
          'bitrateBps': 4000000,
          'durationSeconds': 1.0,
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      print('ANDROID_STILL_IMAGE_COLOR_MATRIX_EXPORT_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'reason': 'dart_exception: $error',
        'proofBoundary':
            'production_exportTimeline_still_image_color_matrix_gles_pixel_oracle',
        'renderBackend': null,
        'colorMatrix': <double>[],
        'expectedMeanRgb': <String, double>{'r': 84.0, 'g': 103.6, 'b': 91.2},
        'sourceMeanRgb': <String, double>{'r': 96.0, 'g': 64.0, 'b': 32.0},
        'laneA': null,
        'laneB': null,
        'laneAPass': false,
        'laneBPass': false,
      };
    }

    // Validate all required payload fields.
    final requiredKeys = [
      'pass',
      'reason',
      'proofBoundary',
      'renderBackend',
      'colorMatrix',
      'expectedMeanRgb',
      'sourceMeanRgb',
      'laneA',
      'laneB',
      'laneAPass',
      'laneBPass',
    ];

    final missingKeys = requiredKeys
        .where((k) => !payload.containsKey(k))
        .toList();

    final bool fieldsValid =
        missingKeys.isEmpty &&
        payload['proofBoundary'] ==
            'production_exportTimeline_still_image_color_matrix_gles_pixel_oracle' &&
        payload['laneAPass'] == true &&
        payload['laneBPass'] == true &&
        payload['renderBackend'] == 'gles';

    final pass = (payload['pass'] == true) && fieldsValid;

    print(
      'ANDROID_STILL_IMAGE_COLOR_MATRIX_EXPORT_JSON:${jsonEncode(payload)}',
    );
    print(
      pass
          ? 'ANDROID_STILL_IMAGE_COLOR_MATRIX_EXPORT_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_STILL_IMAGE_COLOR_MATRIX_EXPORT_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        if (pass) {
          _status =
              'PASS\nlaneA: ${payload['laneA']}\nlaneB: ${payload['laneB']}';
        } else {
          _status =
              'FAIL: ${payload['reason']} (missingKeys=$missingKeys, fieldsValid=$fieldsValid)';
        }
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_status, textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
