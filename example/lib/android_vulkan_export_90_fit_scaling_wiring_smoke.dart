// android_vulkan_export_90_fit_scaling_wiring_smoke.dart
// Vanguard Media Engine — Android Vulkan-first export 90-degree rotated aspect-preserving fit/scaling proof harness with generated synthetic source.
//
// Proof lanes:
//   Lane A: Production route under test (AndroidTimelineExportSession with 640x360 rot-90 synthetic clip -> 1280x720 canvas)
//   Lane B: GLES baseline skipped (fit_region oracle mode)
//   Lane C: Independent fit region & black bar oracle on production output

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidVulkanExport90FitScalingWiringSmokeApp());
}

class AndroidVulkanExport90FitScalingWiringSmokeApp extends StatefulWidget {
  const AndroidVulkanExport90FitScalingWiringSmokeApp({super.key});

  @override
  State<AndroidVulkanExport90FitScalingWiringSmokeApp> createState() =>
      _AndroidVulkanExport90FitScalingWiringSmokeAppState();
}

class _AndroidVulkanExport90FitScalingWiringSmokeAppState
    extends State<AndroidVulkanExport90FitScalingWiringSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android Vulkan export 90 fit scaling wiring physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    print('ANDROID_VULKAN_EXPORT_90_FIT_SCALING_WIRING_SMOKE: START');
    Map<String, dynamic> payload;

    try {
      final tempDir = Directory.systemTemp;
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidVulkanExportProductionWiringSmoke',
        <String, Object>{
          'outputDir': tempDir.path,
          'useSyntheticSource': true,
          'width': 640,
          'height': 360,
          'outputWidth': 1280,
          'outputHeight': 720,
          'fps': 30,
          'bitrateBps': 4000000,
          'trimEndSeconds': 1.0,
          'sourceRotationDegrees': 90,
          'oracleMode': 'fit_region',
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      print(
        'ANDROID_VULKAN_EXPORT_90_FIT_SCALING_WIRING_ERROR: $error\n$stack',
      );
      payload = <String, dynamic>{
        'pass': false,
        'reason': 'dart_exception: $error',
        'sourceMode': 'synthetic',
        'sourcePath': '',
        'generatedSourcePath': null,
        'generatedSourceSize': 0,
        'sourceRotationDegrees': 90,
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
        'proofBoundary': 'production_exportTimeline_vulkan_fit_region_oracle',
        'oracleMode': 'fit_region',
        'glesBaselineSkipped': true,
        'rotationRegionOraclePass': false,
        'fitRegionOraclePass': false,
        'blackBarOraclePass': false,
        'expectedFitRect': <String, int>{},
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
    final fitRegionOraclePass = payload['fitRegionOraclePass'] == true;
    final blackBarOraclePass = payload['blackBarOraclePass'] == true;
    final glesBaselineSkipped = payload['glesBaselineSkipped'] == true;
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
        sourceRotationDegrees == 90 &&
        sourceMetadataRotationDegrees == 90 &&
        productionPass &&
        pixelPass &&
        fitRegionOraclePass &&
        blackBarOraclePass &&
        glesBaselineSkipped &&
        prodWidth == 1280 &&
        prodHeight == 720 &&
        oracleMode == 'fit_region' &&
        proofBoundary == 'production_exportTimeline_vulkan_fit_region_oracle';

    print(
      'ANDROID_VULKAN_EXPORT_90_FIT_SCALING_WIRING_JSON:${jsonEncode(payload)}',
    );
    print(
      pass
          ? 'ANDROID_VULKAN_EXPORT_90_FIT_SCALING_WIRING_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_VULKAN_EXPORT_90_FIT_SCALING_WIRING_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        if (pass) {
          _status =
              'PASS\nProduction: ${payload['productionOutputPath']} ($prodSize bytes)\nOutput Geometry: ${prodWidth}x$prodHeight\nGenerated: ${payload['generatedSourcePath']} ($genSize bytes)\nRotation: $sourceRotationDegrees\nMetadata Rotation: $sourceMetadataRotationDegrees\nFit Rect: ${payload['expectedFitRect']}\nOracle: $oracleMode ($proofBoundary)';
        } else {
          _status =
              'FAIL: ${payload['reason']} (passFlag=$passFlag, sourceModeMatch=$sourceModeMatch, genSize=$genSize, prodSize=$prodSize, rot=$sourceRotationDegrees, metaRot=$sourceMetadataRotationDegrees, prodPass=$productionPass, pixelPass=$pixelPass, fitPass=$fitRegionOraclePass, barPass=$blackBarOraclePass, glesSkipped=$glesBaselineSkipped, outW=$prodWidth, outH=$prodHeight, oracle=$oracleMode, boundary=$proofBoundary)';
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
