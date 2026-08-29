// android_vulkan_export_180_rotation_wiring_smoke.dart
// Vanguard Media Engine — Android Vulkan-first export 180-degree rotation proof harness with generated synthetic source.
//
// Proof lanes:
//   Lane A: Production route under test (AndroidTimelineExportSession with 1280x720 rot-180 synthetic clip)
//   Lane B: Direct GLES baseline (AndroidTimelineVideoEncoder with identical clip geometry and rotation 180)
//   Lane C: Pixel parity comparison (extracted frame mean RGB diff <= 30.0)

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidVulkanExport180RotationWiringSmokeApp());
}

class AndroidVulkanExport180RotationWiringSmokeApp extends StatefulWidget {
  const AndroidVulkanExport180RotationWiringSmokeApp({super.key});

  @override
  State<AndroidVulkanExport180RotationWiringSmokeApp> createState() =>
      _AndroidVulkanExport180RotationWiringSmokeAppState();
}

class _AndroidVulkanExport180RotationWiringSmokeAppState
    extends State<AndroidVulkanExport180RotationWiringSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android Vulkan export 180 rotation wiring physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    print('ANDROID_VULKAN_EXPORT_180_ROTATION_WIRING_SMOKE: START');
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
          'sourceRotationDegrees': 180,
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      print('ANDROID_VULKAN_EXPORT_180_ROTATION_WIRING_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'reason': 'dart_exception: $error',
        'sourceMode': 'synthetic',
        'sourcePath': '',
        'generatedSourcePath': null,
        'generatedSourceSize': 0,
        'sourceRotationDegrees': 180,
        'sourceMetadataRotationDegrees': 0,
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

    final passFlag = payload['pass'] == true;
    final sourceModeMatch = payload['sourceMode'] == 'synthetic';
    final genSize = (payload['generatedSourceSize'] as num?)?.toInt() ?? 0;
    final prodSize = (payload['productionOutputSize'] as num?)?.toInt() ?? 0;
    final glesSize = (payload['glesOutputSize'] as num?)?.toInt() ?? 0;
    final meanAbsDiff = (payload['meanAbsDiff'] as num?)?.toDouble() ?? -1.0;
    final sourceRotationDegrees =
        (payload['sourceRotationDegrees'] as num?)?.toInt() ?? 0;
    final sourceMetadataRotationDegrees =
        (payload['sourceMetadataRotationDegrees'] as num?)?.toInt() ?? 0;

    final pass =
        passFlag &&
        sourceModeMatch &&
        genSize > 0 &&
        prodSize > 0 &&
        glesSize > 0 &&
        meanAbsDiff >= 0.0 &&
        meanAbsDiff <= 30.0 &&
        sourceRotationDegrees == 180 &&
        sourceMetadataRotationDegrees == 180;

    print(
      'ANDROID_VULKAN_EXPORT_180_ROTATION_WIRING_JSON:${jsonEncode(payload)}',
    );
    print(
      pass
          ? 'ANDROID_VULKAN_EXPORT_180_ROTATION_WIRING_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_VULKAN_EXPORT_180_ROTATION_WIRING_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        if (pass) {
          _status =
              'PASS\nProduction: ${payload['productionOutputPath']} ($prodSize bytes)\nGLES: ${payload['glesOutputPath']} ($glesSize bytes)\nGenerated: ${payload['generatedSourcePath']} ($genSize bytes)\nRotation: $sourceRotationDegrees\nMetadata Rotation: $sourceMetadataRotationDegrees\nMean Abs Diff: $meanAbsDiff';
        } else {
          _status =
              'FAIL: ${payload['reason']} (passFlag=$passFlag, sourceModeMatch=$sourceModeMatch, genSize=$genSize, prodSize=$prodSize, glesSize=$glesSize, meanAbsDiff=$meanAbsDiff, sourceRotationDegrees=$sourceRotationDegrees, sourceMetadataRotationDegrees=$sourceMetadataRotationDegrees)';
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
