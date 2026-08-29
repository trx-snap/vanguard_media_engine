// android_vulkan_export_270_rotation_wiring_smoke.dart
// Vanguard Media Engine — Android Vulkan-first export 270-degree rotation proof harness with generated synthetic source.
//
// Proof lanes:
//   Lane A: Production route under test (AndroidTimelineExportSession with 1280x720 rot-270 synthetic clip -> 720x1280 canvas)
//   Lane B: GLES baseline skipped (90/270 non-square swapped geometry)
//   Lane C: Independent 4-quadrant color region / chirality oracle on production output

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidVulkanExport270RotationWiringSmokeApp());
}

class AndroidVulkanExport270RotationWiringSmokeApp extends StatefulWidget {
  const AndroidVulkanExport270RotationWiringSmokeApp({super.key});

  @override
  State<AndroidVulkanExport270RotationWiringSmokeApp> createState() =>
      _AndroidVulkanExport270RotationWiringSmokeAppState();
}

class _AndroidVulkanExport270RotationWiringSmokeAppState
    extends State<AndroidVulkanExport270RotationWiringSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android Vulkan export 270 rotation wiring physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    print('ANDROID_VULKAN_EXPORT_270_ROTATION_WIRING_SMOKE: START');
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
          'outputWidth': 720,
          'outputHeight': 1280,
          'fps': 30,
          'bitrateBps': 4000000,
          'trimEndSeconds': 1.0,
          'sourceRotationDegrees': 270,
          'oracleMode': 'rotation_region',
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      print('ANDROID_VULKAN_EXPORT_270_ROTATION_WIRING_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'reason': 'dart_exception: $error',
        'sourceMode': 'synthetic',
        'sourcePath': '',
        'generatedSourcePath': null,
        'generatedSourceSize': 0,
        'sourceRotationDegrees': 270,
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
            'production_exportTimeline_vulkan_rotation_region_oracle',
        'oracleMode': 'rotation_region',
        'glesBaselineSkipped': true,
        'rotationRegionOraclePass': false,
        'productionOutputWidth': 0,
        'productionOutputHeight': 0,
      };
    }

    final passFlag = payload['pass'] == true;
    final sourceModeMatch = payload['sourceMode'] == 'synthetic';
    final genSize = (payload['generatedSourceSize'] as num?)?.toInt() ?? 0;
    final prodSize = (payload['productionOutputSize'] as num?)?.toInt() ?? 0;
    final sourceRotationDegrees =
        (payload['sourceRotationDegrees'] as num?)?.toInt() ?? 0;
    final sourceMetadataRotationDegrees =
        (payload['sourceMetadataRotationDegrees'] as num?)?.toInt() ?? 0;
    final productionPass = payload['productionPass'] == true;
    final pixelPass = payload['pixelPass'] == true;
    final rotationRegionOraclePass =
        payload['rotationRegionOraclePass'] == true;
    final prodWidth = (payload['productionOutputWidth'] as num?)?.toInt() ?? 0;
    final prodHeight =
        (payload['productionOutputHeight'] as num?)?.toInt() ?? 0;
    final oracleMode = payload['oracleMode'] as String? ?? '';
    final proofBoundary = payload['proofBoundary'] as String? ?? '';

    final pass =
        passFlag &&
        sourceModeMatch &&
        genSize > 0 &&
        prodSize > 0 &&
        sourceRotationDegrees == 270 &&
        sourceMetadataRotationDegrees == 270 &&
        productionPass &&
        pixelPass &&
        rotationRegionOraclePass &&
        prodWidth == 720 &&
        prodHeight == 1280 &&
        oracleMode == 'rotation_region' &&
        proofBoundary ==
            'production_exportTimeline_vulkan_rotation_region_oracle';

    print(
      'ANDROID_VULKAN_EXPORT_270_ROTATION_WIRING_JSON:${jsonEncode(payload)}',
    );
    print(
      pass
          ? 'ANDROID_VULKAN_EXPORT_270_ROTATION_WIRING_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_VULKAN_EXPORT_270_ROTATION_WIRING_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        if (pass) {
          _status =
              'PASS\nProduction: ${payload['productionOutputPath']} ($prodSize bytes)\nOutput Geometry: ${prodWidth}x$prodHeight\nGenerated: ${payload['generatedSourcePath']} ($genSize bytes)\nRotation: $sourceRotationDegrees\nMetadata Rotation: $sourceMetadataRotationDegrees\nOracle: $oracleMode ($proofBoundary)';
        } else {
          _status =
              'FAIL: ${payload['reason']} (passFlag=$passFlag, sourceModeMatch=$sourceModeMatch, genSize=$genSize, prodSize=$prodSize, rot=$sourceRotationDegrees, metaRot=$sourceMetadataRotationDegrees, prodPass=$productionPass, pixelPass=$pixelPass, regionPass=$rotationRegionOraclePass, outW=$prodWidth, outH=$prodHeight, oracle=$oracleMode, boundary=$proofBoundary)';
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
