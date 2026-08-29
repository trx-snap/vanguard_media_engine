// android_vulkan_export_production_wiring_smoke.dart
// Vanguard Media Engine — Android Vulkan-first export production wiring smoke harness.
//
// Proof lanes:
//   Lane A: Production route under test (AndroidTimelineExportSession with 1280x720 rot-0 synthetic clip)
//   Lane B: Direct GLES baseline (AndroidTimelineVideoEncoder with identical clip geometry)
//   Lane C: Pixel parity comparison (extracted frame mean RGB diff <= 30.0)

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidVulkanExportProductionWiringSmokeApp());
}

class AndroidVulkanExportProductionWiringSmokeApp extends StatefulWidget {
  const AndroidVulkanExportProductionWiringSmokeApp({super.key});

  @override
  State<AndroidVulkanExportProductionWiringSmokeApp> createState() =>
      _AndroidVulkanExportProductionWiringSmokeAppState();
}

class _AndroidVulkanExportProductionWiringSmokeAppState
    extends State<AndroidVulkanExportProductionWiringSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android Vulkan export production wiring physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    print('ANDROID_VULKAN_EXPORT_PRODUCTION_WIRING_SMOKE: START');
    Map<String, dynamic> payload;

    try {
      final tempDir = Directory.systemTemp;
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidVulkanExportProductionWiringSmoke',
        <String, Object>{
          'outputDir': tempDir.path,
          'useSyntheticSource': true,
          'width': 1280,
          'height': 720,
          'fps': 30,
          'bitrateBps': 4000000,
          'trimEndSeconds': 1.0,
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      print('ANDROID_VULKAN_EXPORT_PRODUCTION_WIRING_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'reason': 'dart_exception: $error',
        'sourceMode': 'synthetic',
        'sourcePath': '',
        'generatedSourcePath': null,
        'generatedSourceSize': 0,
        'productionPass': false,
        'glesPass': false,
        'pixelPass': false,
        'productionOutputPath': '',
        'glesOutputPath': '',
        'productionOutputSize': 0,
        'glesOutputSize': 0,
        'productionSidecarPath': '',
        'productionSidecarExists': false,
        'productionErrorCode': null,
        'productionErrorMessage': '$error',
        'productionProgressSamples': <double>[],
        'glesProgressSamples': <double>[],
        'productionMeanRgb': <String, double>{'r': 0.0, 'g': 0.0, 'b': 0.0},
        'glesMeanRgb': <String, double>{'r': 0.0, 'g': 0.0, 'b': 0.0},
        'meanAbsDiff': -1.0,
        'proofBoundary':
            'production_exportTimeline_vulkan_vs_direct_gles_pixel_parity',
      };
    }

    final pass = payload['pass'] == true;

    print(
      'ANDROID_VULKAN_EXPORT_PRODUCTION_WIRING_JSON:${jsonEncode(payload)}',
    );
    print(
      pass
          ? 'ANDROID_VULKAN_EXPORT_PRODUCTION_WIRING_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_VULKAN_EXPORT_PRODUCTION_WIRING_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        if (pass) {
          _status =
              'PASS\nProduction: ${payload['productionOutputPath']} (${payload['productionOutputSize']} bytes)\nGLES: ${payload['glesOutputPath']} (${payload['glesOutputSize']} bytes)\nMean Abs Diff: ${payload['meanAbsDiff']}';
        } else {
          _status = 'FAIL: ${payload['reason']}';
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
