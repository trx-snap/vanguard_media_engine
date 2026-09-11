// android_duet_vulkan_preview_presentation_physical_smoke.dart
// Vanguard Media Engine — DUET-VULKAN-PREVIEW-PRESENTATION: Android
// Vulkan green-screen composite presented through Flutter SurfaceProducer
// / Android Surface / ANativeWindow / VkSurfaceKHR swapchain physical smoke harness.
//
// Claims: diagnostic-only proof of SurfaceProducer presentation through Vulkan swapchain,
// real camera+decoder AHB import/resolve, no-readback green-screen blend, one-frame present, cleanup.
// Non-claims: production preview, sustained FPS, CameraX replacement, export/audio/UI/upload,
// segmentation GPU, low-end parity.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_duet_vulkan_preview_presentation_smoke.dart';

const String _passMarker =
    'ANDROID_DUET_VULKAN_PREVIEW_PRESENTATION_PHYSICAL_PASS';
const String _failMarker =
    'ANDROID_DUET_VULKAN_PREVIEW_PRESENTATION_PHYSICAL_FAIL';
const String _logPrefix = 'ANDROID_DUET_VULKAN_PREVIEW_PRESENTATION';

void main() {
  runApp(
    const MaterialApp(
      home: AndroidDuetVulkanPreviewPresentationPhysicalSmokeApp(),
    ),
  );
}

class AndroidDuetVulkanPreviewPresentationPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidDuetVulkanPreviewPresentationPhysicalSmokeApp({super.key});

  @override
  State<AndroidDuetVulkanPreviewPresentationPhysicalSmokeApp> createState() =>
      _AndroidDuetVulkanPreviewPresentationPhysicalSmokeAppState();
}

class _AndroidDuetVulkanPreviewPresentationPhysicalSmokeAppState
    extends State<AndroidDuetVulkanPreviewPresentationPhysicalSmokeApp> {
  String _status =
      'Initializing Android Duet Vulkan Preview Presentation Smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('${_logPrefix}_SMOKE_START');
    File? tempFile;
    try {
      final tempDir = Directory.systemTemp;
      tempFile = File(
        '${tempDir.path}/clip_B_${DateTime.now().millisecondsSinceEpoch}.mov',
      );
      final byteData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      await tempFile.writeAsBytes(
        byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        ),
      );

      final report =
          await VGDuetVulkanPreviewPresentationSmokeReport.runAndroidDuetVulkanPreviewPresentationSmoke(
            clipPath: tempFile.path,
            surfaceWidth: 720,
            surfaceHeight: 1280,
          );

      if (report.isUnsupported) {
        print(
          '${_logPrefix}_UNSUPPORTED: status=${report.status} '
          'failureReason=${report.failureReason}',
        );
      }

      final lane1Pass = report.argumentValidationOk && report.surfaceAcquireOk;
      print(
        '${_logPrefix}_LANE_1: pass=$lane1Pass '
        'argumentValidationOk=${report.argumentValidationOk} '
        'surfaceAcquireOk=${report.surfaceAcquireOk} '
        'textureId=${report.details['textureId']}',
      );

      final lane2Pass = report.nativeWindowOk && report.vulkanSetupOk;
      print(
        '${_logPrefix}_LANE_2: pass=$lane2Pass '
        'nativeWindowOk=${report.nativeWindowOk} '
        'vulkanSetupOk=${report.vulkanSetupOk} '
        'deviceName=${report.details['deviceName']}',
      );

      final lane3Pass = report.swapchainCreateOk;
      print(
        '${_logPrefix}_LANE_3: pass=$lane3Pass '
        'swapchainCreateOk=${report.swapchainCreateOk} '
        'swapchainFormat=${report.details['swapchainFormatName']} '
        'extent=${report.details['swapchainExtentWidth']}x${report.details['swapchainExtentHeight']}',
      );

      final lane4Pass =
          report.cameraFrameAcquireOk && report.decoderFrameAcquireOk;
      print(
        '${_logPrefix}_LANE_4: pass=$lane4Pass '
        'cameraFrameAcquireOk=${report.cameraFrameAcquireOk} '
        'decoderFrameAcquireOk=${report.decoderFrameAcquireOk}',
      );

      final lane5Pass =
          report.cameraImportOk && report.decoderImportOk && report.resolveOk;
      print(
        '${_logPrefix}_LANE_5: pass=$lane5Pass '
        'cameraImportOk=${report.cameraImportOk} '
        'decoderImportOk=${report.decoderImportOk} '
        'resolveOk=${report.resolveOk}',
      );

      final lane6Pass = report.maskUploadOk && report.blendRenderNoReadbackOk;
      print(
        '${_logPrefix}_LANE_6: pass=$lane6Pass '
        'maskUploadOk=${report.maskUploadOk} '
        'blendRenderNoReadbackOk=${report.blendRenderNoReadbackOk}',
      );

      final lane7Pass = report.swapchainPresentOk;
      print(
        '${_logPrefix}_LANE_7: pass=$lane7Pass '
        'swapchainPresentOk=${report.swapchainPresentOk} '
        'presentationPath=${report.details['presentationPath']}',
      );

      final lane8Pass = report.resourceReleaseOk && report.diagnosticTeardownOk;
      print(
        '${_logPrefix}_LANE_8: pass=$lane8Pass '
        'resourceReleaseOk=${report.resourceReleaseOk} '
        'diagnosticTeardownOk=${report.diagnosticTeardownOk}',
      );

      final lane9Pass =
          report.pass &&
          report.allNativeLanesPass &&
          report.marker == _passMarker;
      print(
        '${_logPrefix}_LANE_9: pass=$lane9Pass '
        'allNativeLanesPass=${report.allNativeLanesPass} '
        'reportPass=${report.pass} '
        'marker=${report.marker} '
        'proofBoundary=${report.proofBoundary}',
      );

      print('${_logPrefix}_JSON:${jsonEncode(report.toMap())}');
      print(report.marker);

      if (mounted) {
        setState(() {
          _status = report.pass
              ? 'PASS: ${report.marker}'
              : 'FAIL: ${report.failureReason}';
        });
      }
    } catch (e) {
      print(
        '${_logPrefix}_JSON:{"pass":false,"failureReason":"unhandled_dart_exception:$e"}',
      );
      print(_failMarker);
      if (mounted) {
        setState(() {
          _status = 'FAIL: $e';
        });
      }
    } finally {
      if (tempFile != null && tempFile.existsSync()) {
        try {
          tempFile.deleteSync();
        } catch (_) {}
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Duet Vulkan Preview Presentation Smoke'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Text(
            _status,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16),
          ),
        ),
      ),
    );
  }
}
