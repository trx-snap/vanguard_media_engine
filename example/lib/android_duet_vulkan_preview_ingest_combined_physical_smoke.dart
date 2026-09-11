// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_duet_vulkan_preview_ingest_combined_smoke.dart';

void main() {
  runApp(
    const MaterialApp(home: AndroidDuetVulkanPreviewIngestCombinedSmokeApp()),
  );
}

class AndroidDuetVulkanPreviewIngestCombinedSmokeApp extends StatefulWidget {
  const AndroidDuetVulkanPreviewIngestCombinedSmokeApp({super.key});

  @override
  State<AndroidDuetVulkanPreviewIngestCombinedSmokeApp> createState() =>
      _AndroidDuetVulkanPreviewIngestCombinedSmokeAppState();
}

class _AndroidDuetVulkanPreviewIngestCombinedSmokeAppState
    extends State<AndroidDuetVulkanPreviewIngestCombinedSmokeApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmokeTest();
    });
  }

  Future<void> _runSmokeTest() async {
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
          await VGDuetVulkanPreviewIngestCombinedSmokeReport.runAndroidDuetVulkanPreviewIngestCombinedSmoke(
            clipPath: tempFile.path,
          );

      print(
        'ANDROID_DUET_VULKAN_PREVIEW_INGEST_COMBINED_JSON:${jsonEncode(report.toMap())}',
      );
      print(report.marker);
    } catch (e) {
      print(
        'ANDROID_DUET_VULKAN_PREVIEW_INGEST_COMBINED_JSON:{"pass":false,"failureReason":"unhandled_dart_exception"}',
      );
      print('ANDROID_DUET_VULKAN_PREVIEW_INGEST_COMBINED_PHYSICAL_FAIL');
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
    return const Scaffold(body: Center(child: Text('Running test...')));
  }
}
