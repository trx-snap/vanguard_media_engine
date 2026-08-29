// Android Vulkan export native seam smoke.
//
// Native VulkanBackend renders HardwareBuffer frames directly into a
// MediaCodec encoder input Surface -> deterministic CFR H.264 MP4 through MediaMuxer.
//
// Dart responsibilities:
//   - Create a unique output path under Directory.systemTemp.
//   - Invoke MethodChannel('vanguard_media_engine').invokeMethod(
//       'runAndroidVulkanExportNativeSeamSmoke',
//       {
//         'width': 64,
//         'height': 64,
//         'frameCount': 10,
//         'frameDurationUs': 33333,
//         'bitrate': 1000000,
//         'outputPath': outputPath,
//       }
//     )
//   - Print ANDROID_VULKAN_EXPORT_NATIVE_SEAM_JSON:<json>
//   - Print ANDROID_VULKAN_EXPORT_NATIVE_SEAM_PHYSICAL_SMOKE_PASS or ..._FAIL
//   - Preserve output on pass for inspection, include outputPath/outputSize in UI/status
//   - Best-effort delete on fail

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidVulkanExportNativeSeamSmokeApp());
}

class AndroidVulkanExportNativeSeamSmokeApp extends StatefulWidget {
  const AndroidVulkanExportNativeSeamSmokeApp({super.key});

  @override
  State<AndroidVulkanExportNativeSeamSmokeApp> createState() =>
      _AndroidVulkanExportNativeSeamSmokeAppState();
}

class _AndroidVulkanExportNativeSeamSmokeAppState
    extends State<AndroidVulkanExportNativeSeamSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android Vulkan export native seam smoke…';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    final tempDir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final outputPath =
        '${tempDir.path}/vulkan_export_native_seam_smoke_$timestamp.mp4';

    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidVulkanExportNativeSeamSmoke',
        <String, Object>{
          'width': 64,
          'height': 64,
          'frameCount': 10,
          'frameDurationUs': 33333,
          'bitrate': 1000000,
          'outputPath': outputPath,
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_VULKAN_EXPORT_NATIVE_SEAM_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;reason=dart_exception;detail=$error',
        'width': 64,
        'height': 64,
        'frameCount': 10,
        'encodedFrames': 0,
        'frameDurationUs': 33333,
        'outputPath': outputPath,
        'outputSize': 0,
        'proofBoundary': 'media_codec_input_surface_vulkan_export_native_seam',
      };
    }

    final pass = payload['pass'] == true;
    final outputSize = (payload['outputSize'] as num?)?.toInt() ?? 0;
    final reportedPath = payload['outputPath'] as String? ?? outputPath;

    // Clean up partial output file on failure if still lingering.
    if (!pass) {
      try {
        final f = File(outputPath);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }

    // ignore: avoid_print
    print('ANDROID_VULKAN_EXPORT_NATIVE_SEAM_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_VULKAN_EXPORT_NATIVE_SEAM_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_VULKAN_EXPORT_NATIVE_SEAM_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        if (pass) {
          _status = 'PASS\nPath: $reportedPath\nSize: $outputSize bytes';
        } else {
          _status = 'FAIL: ${payload['raw']}';
        }
      });
    }
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
