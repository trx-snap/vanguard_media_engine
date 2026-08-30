// android_timeline_color_matrix_export_smoke.dart
// Vanguard Media Engine — Android timeline video export colorMatrix parity smoke harness.
//
// Proof boundary: production_exportTimeline_color_matrix_vulkan_native_pixel_oracle
// Validates:
// 1. The production export session renders via the native Vulkan backend
//    (renderBackend == "vulkan") -- a GLES fallback/retry must not be able to
//    pass this oracle, since colorMatrix is applied natively on the Vulkan
//    export path and is within Vulkan's safe scope.
// 2. Production export session success with 20-element 4x5 color matrix.
// 3. Pixel oracle verification comparing extracted frame mean RGB against
//    expected transformed RGB and ensuring difference from source color.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidTimelineColorMatrixExportSmokeApp());
}

class AndroidTimelineColorMatrixExportSmokeApp extends StatefulWidget {
  const AndroidTimelineColorMatrixExportSmokeApp({super.key});

  @override
  State<AndroidTimelineColorMatrixExportSmokeApp> createState() =>
      _AndroidTimelineColorMatrixExportSmokeAppState();
}

class _AndroidTimelineColorMatrixExportSmokeAppState
    extends State<AndroidTimelineColorMatrixExportSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android timeline colorMatrix export physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    print('ANDROID_TIMELINE_COLOR_MATRIX_EXPORT_SMOKE: START');
    Map<String, dynamic> payload;

    try {
      final tempDir = Directory.systemTemp;
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidTimelineColorMatrixExportSmoke',
        <String, Object>{
          'outputDir': tempDir.path,
          'width': 1280,
          'height': 720,
          'outputWidth': 1280,
          'outputHeight': 720,
          'fps': 30,
          'bitrateBps': 4000000,
          'trimEndSeconds': 1.0,
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      print('ANDROID_TIMELINE_COLOR_MATRIX_EXPORT_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'reason': 'dart_exception: $error',
        'sourcePath': '',
        'outputPath': '',
        'outputSize': 0,
        'outputWidth': 0,
        'outputHeight': 0,
        'sourceMeanRgb': <String, double>{'r': 96.0, 'g': 64.0, 'b': 32.0},
        'expectedMeanRgb': <String, double>{'r': 84.0, 'g': 103.6, 'b': 91.2},
        'actualMeanRgb': <String, double>{'r': 0.0, 'g': 0.0, 'b': 0.0},
        'perChannelAbsDiff': <String, double>{'r': 0.0, 'g': 0.0, 'b': 0.0},
        'filterAppliedOraclePass': false,
        'productionPass': false,
        'pixelPass': false,
        'proofBoundary':
            'production_exportTimeline_color_matrix_vulkan_native_pixel_oracle',
        'matrixMode': 'row_major_4x5_with_offsets',
        'colorMatrix': <double>[],
        'progressSamples': <double>[],
        'errorCode': null,
        'errorMessage': '$error',
        'contentRegionOnly': true,
        'renderBackend': null,
      };
    }

    // Validate all required payload fields
    final requiredKeys = [
      'pass',
      'reason',
      'sourcePath',
      'outputPath',
      'outputSize',
      'outputWidth',
      'outputHeight',
      'sourceMeanRgb',
      'expectedMeanRgb',
      'actualMeanRgb',
      'perChannelAbsDiff',
      'filterAppliedOraclePass',
      'productionPass',
      'pixelPass',
      'proofBoundary',
      'matrixMode',
      'colorMatrix',
      'progressSamples',
      'contentRegionOnly',
      'renderBackend',
    ];

    final missingKeys = requiredKeys
        .where((k) => !payload.containsKey(k))
        .toList();
    final bool fieldsValid =
        missingKeys.isEmpty &&
        payload['proofBoundary'] ==
            'production_exportTimeline_color_matrix_vulkan_native_pixel_oracle' &&
        payload['productionPass'] == true &&
        payload['pixelPass'] == true &&
        payload['filterAppliedOraclePass'] == true &&
        payload['contentRegionOnly'] == true &&
        payload['renderBackend'] == 'vulkan';

    final pass = (payload['pass'] == true) && fieldsValid;

    print('ANDROID_TIMELINE_COLOR_MATRIX_EXPORT_JSON:${jsonEncode(payload)}');
    print(
      pass
          ? 'ANDROID_TIMELINE_COLOR_MATRIX_EXPORT_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_TIMELINE_COLOR_MATRIX_EXPORT_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        if (pass) {
          _status =
              'PASS\nOutput: ${payload['outputPath']} (${payload['outputSize']} bytes)\nActual RGB: ${payload['actualMeanRgb']}\nExpected RGB: ${payload['expectedMeanRgb']}\nDiff: ${payload['perChannelAbsDiff']}';
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
