// android_gles_export_overlay_production_physical_smoke.dart
// Vanguard Media Engine - P5-GLES-EXPORT-OVERLAY-PRODUCTION-ROUTE-A:
// Physical smoke test verifying production AndroidTimelineVideoEncoder
// directly executes GLES overlay composition on caller-current context.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_gles_export_overlay_production_smoke.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_PRODUCTION_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_PRODUCTION_PHYSICAL_SMOKE_FAIL';
const String _logPrefix = 'ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_PRODUCTION';

void main() {
  runApp(const AndroidGlesExportOverlayProductionPhysicalSmokeApp());
}

class AndroidGlesExportOverlayProductionPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidGlesExportOverlayProductionPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesExportOverlayProductionPhysicalSmokeApp> createState() =>
      _AndroidGlesExportOverlayProductionPhysicalSmokeAppState();
}

class _AndroidGlesExportOverlayProductionPhysicalSmokeAppState
    extends State<AndroidGlesExportOverlayProductionPhysicalSmokeApp> {
  String _status =
      'Initializing GLES export overlay production physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('${_logPrefix}_SMOKE_START');
    String? topLevelError;
    VGGlesExportOverlayProductionSmokeReport? report;
    Directory? tempDir;

    try {
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final stickerBytes = await rootBundle.load(
        'assets/manual_test_clips/still_C.png',
      );

      tempDir = await Directory.systemTemp.createTemp(
        'vg_p5_gles_export_overlay_prod_',
      );

      final videoFile = File('${tempDir.path}/clip_B.mov');
      await videoFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      final stickerFile = File('${tempDir.path}/still_C.png');
      await stickerFile.writeAsBytes(
        stickerBytes.buffer.asUint8List(
          stickerBytes.offsetInBytes,
          stickerBytes.lengthInBytes,
        ),
        flush: true,
      );

      final outDir = Directory('${tempDir.path}/out');
      await outDir.create(recursive: true);

      report =
          await VGGlesExportOverlayProductionSmokeReport.runAndroidDagPhase5GlesExportOverlayProductionSmoke(
            videoPath: videoFile.path,
            stickerPath: stickerFile.path,
            outputDir: outDir.path,
            timeout: const Duration(seconds: 30),
          ).timeout(const Duration(seconds: 40));

      print(
        '${_logPrefix}_LANE_INPUT_METADATA: inputValidationOk=${report.inputValidationPass} '
        'sourceMetadataOk=${report.sourceMetadataPass} '
        'width=${report.details['sourceWidth']} '
        'height=${report.details['sourceHeight']} '
        'durationUs=${report.details['sourceDurationUs']}',
      );
      print(
        '${_logPrefix}_LANE_ENCODE: baselineEncodeOk=${report.baselineEncodePass} '
        'baselineSamples=${report.details['baselineWrittenSamples']} '
        'overlayEncodeOk=${report.overlayEncodePass} '
        'overlaySamples=${report.details['overlayWrittenSamples']} '
        'overlayFrameCountOk=${report.overlayFrameCountPass} '
        'overlayFrameCount=${report.details['overlayFrameCount']}',
      );
      print(
        '${_logPrefix}_LANE_PIXEL: frameExtractOk=${report.frameExtractPass} '
        'pixelDeltaOk=${report.pixelDeltaPass} '
        'changedPixels=${report.details['changedPixels']} '
        'meanDelta=${report.details['meanDelta']} '
        'baselineMeanRgb=${report.details['baselineMeanRgb']} '
        'overlayMeanRgb=${report.details['overlayMeanRgb']}',
      );
      print(
        '${_logPrefix}_LANE_FAIL_CLOSED: missingBridgeRejectedOk=${report.missingBridgeRejectedPass} '
        'missingBridgeReason=${report.details['missingBridgeRejectedReason']}',
      );
      print(
        '${_logPrefix}_LANE_STILL_IMAGE_OVERLAY: stillImageOverlayEncodeOk=${report.stillImageOverlayEncodePass} '
        'stillImageOverlayReason=${report.details['stillImageOverlayReason']} '
        'stillImageOverlaySamples=${report.details['stillImageOverlayWrittenSamples']} '
        'stillImageOverlayFrameCount=${report.details['stillImageOverlayFrameCount']}',
      );
      print(
        '${_logPrefix}_LANE_CLEANUP: cleanupOk=${report.cleanupPass} '
        'canonical=${report.canonicalPass}',
      );
      print(
        '${_logPrefix}_LANE_SUMMARY: pass=${report.pass} isPass=${report.isPass} '
        'status=${report.status} marker=${report.marker} '
        'proofBoundary=${report.proofBoundary} '
        'failureReason=${report.failureReason}',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: GLES export overlay production smoke exceeded timeout: $te';
      print('${_logPrefix}_SMOKE_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('${_logPrefix}_SMOKE_ERROR: $topLevelError');
    } finally {
      if (tempDir != null) {
        try {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        } catch (_) {}
      }

      final pass = report?.isPass == true && topLevelError == null;

      final payload = <String, dynamic>{
        'unit': 'AndroidGlesExportOverlayProductionSmokeHarness',
        'slice': 'P5-GLES-EXPORT-OVERLAY-PRODUCTION-ROUTE-A',
        'target':
            VGGlesExportOverlayProductionSmokeReport.proofBoundaryConstant,
        'pass': pass,
        'marker': pass ? _passMarker : _failMarker,
        'smokeReport': report?.toMap(),
        'error': topLevelError,
      };

      print('${_logPrefix}_JSON:${jsonEncode(payload)}');
      print(pass ? _passMarker : _failMarker);

      if (mounted) {
        setState(() {
          _status = pass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(pass ? 0 : 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
