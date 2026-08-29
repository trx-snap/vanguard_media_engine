// android_vulkan_export_multiclip_fit_rotation_smoke.dart
// Vanguard Media Engine — Android Vulkan-first export multi-clip fit/rotation proof harness with generated synthetic sources.
//
// Proof lanes:
//   Lane A: Production route under test (AndroidTimelineExportSession with clip A: 640x640 rot-0 + clip B: 640x360 rot-90 -> 1280x720 canvas)
//   Lane B: GLES baseline skipped (multi_clip_fit_rotation oracle mode)
//   Lane C: Independent multi-clip fit region & black bar oracle on production output

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidVulkanExportMultiClipFitRotationSmokeApp());
}

class AndroidVulkanExportMultiClipFitRotationSmokeApp extends StatefulWidget {
  const AndroidVulkanExportMultiClipFitRotationSmokeApp({super.key});

  @override
  State<AndroidVulkanExportMultiClipFitRotationSmokeApp> createState() =>
      _AndroidVulkanExportMultiClipFitRotationSmokeAppState();
}

class _AndroidVulkanExportMultiClipFitRotationSmokeAppState
    extends State<AndroidVulkanExportMultiClipFitRotationSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android Vulkan export multi-clip fit rotation physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    print('ANDROID_VULKAN_EXPORT_MULTICLIP_FIT_ROTATION_SMOKE: START');
    Map<String, dynamic> payload;

    try {
      final tempDir = Directory.systemTemp;
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidVulkanExportProductionWiringSmoke',
        <String, Object>{
          'scenarioMode': 'multi_clip_fit_rotation',
          'outputDir': tempDir.path,
          'useSyntheticSource': true,
          'outputWidth': 1280,
          'outputHeight': 720,
          'fps': 30,
          'bitrateBps': 4000000,
          'trimEndSeconds': 1.0,
          'oracleMode': 'fit_region',
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      print(
        'ANDROID_VULKAN_EXPORT_MULTICLIP_FIT_ROTATION_ERROR: $error\n$stack',
      );
      payload = <String, dynamic>{
        'pass': false,
        'reason': 'dart_exception: $error',
        'scenarioMode': 'multi_clip_fit_rotation',
        'sourceMode': 'synthetic',
        'sourcePath': '',
        'generatedSourcePath': null,
        'generatedSourcePaths': <String>[],
        'generatedSourceSize': 0,
        'generatedSourceSizes': <int>[],
        'sourceRotationDegrees': 0,
        'sourceMetadataRotationDegrees': 0,
        'productionPass': false,
        'glesPass': false,
        'pixelPass': false,
        'multiClipFitRegionOraclePass': false,
        'clipResults': <dynamic>[],
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
            'production_exportTimeline_vulkan_multiclip_fit_rotation_oracle',
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
    final scenarioMode = payload['scenarioMode'] as String? ?? '';
    final prodSize = (payload['productionOutputSize'] as num?)?.toInt() ?? 0;
    final productionPass = payload['productionPass'] == true;
    final pixelPass = payload['pixelPass'] == true;
    final multiClipFitRegionOraclePass =
        payload['multiClipFitRegionOraclePass'] == true;
    final glesBaselineSkipped = payload['glesBaselineSkipped'] == true;
    final prodWidth = (payload['productionOutputWidth'] as num?)?.toInt() ?? 0;
    final prodHeight =
        (payload['productionOutputHeight'] as num?)?.toInt() ?? 0;
    final proofBoundary = payload['proofBoundary'] as String? ?? '';

    final rawClips = (payload['clipResults'] as List?) ?? const [];
    final clipResults = rawClips
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    final clipsValid =
        clipResults.length == 2 &&
        clipResults[0]['fitRegionOraclePass'] == true &&
        clipResults[0]['blackBarOraclePass'] == true &&
        clipResults[1]['fitRegionOraclePass'] == true &&
        clipResults[1]['blackBarOraclePass'] == true;

    final rawGenSizes = (payload['generatedSourceSizes'] as List?) ?? const [];
    final genSizes = rawGenSizes
        .whereType<num>()
        .map((n) => n.toInt())
        .toList();
    final genSizesValid =
        genSizes.length == 2 && genSizes[0] > 0 && genSizes[1] > 0;

    final pass =
        passFlag &&
        scenarioMode == 'multi_clip_fit_rotation' &&
        genSizesValid &&
        prodSize > 0 &&
        productionPass &&
        pixelPass &&
        multiClipFitRegionOraclePass &&
        clipsValid &&
        glesBaselineSkipped &&
        prodWidth == 1280 &&
        prodHeight == 720 &&
        proofBoundary ==
            'production_exportTimeline_vulkan_multiclip_fit_rotation_oracle';

    print(
      'ANDROID_VULKAN_EXPORT_MULTICLIP_FIT_ROTATION_JSON:${jsonEncode(payload)}',
    );
    print(
      pass
          ? 'ANDROID_VULKAN_EXPORT_MULTICLIP_FIT_ROTATION_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_VULKAN_EXPORT_MULTICLIP_FIT_ROTATION_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        if (pass) {
          _status =
              'PASS\nProduction: ${payload['productionOutputPath']} ($prodSize bytes)\nOutput Geometry: ${prodWidth}x$prodHeight\nGenerated: ${payload['generatedSourcePaths']} ($genSizes bytes)\nClips: ${clipResults.length} evaluated\nBoundary: $proofBoundary';
        } else {
          _status =
              'FAIL: ${payload['reason']} (passFlag=$passFlag, scenarioMode=$scenarioMode, genSizesValid=$genSizesValid, prodSize=$prodSize, prodPass=$productionPass, pixelPass=$pixelPass, multiClipOracle=$multiClipFitRegionOraclePass, clipsValid=$clipsValid, glesSkipped=$glesBaselineSkipped, outW=$prodWidth, outH=$prodHeight, boundary=$proofBoundary)';
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
