// android_timeline_overlay_export_physical_smoke.dart
// Vanguard Media Engine - P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A / P5-GLES-EXPORT-TRANSITION-OVERLAYS:
// Android production `exportTimeline` static sticker, text, and emoji overlay smoke physical proof.
//
// Proof boundary: production_exportTimeline_vulkan_overlay_and_forced_gles_transition_overlay_route_a
//   (covers production Vulkan overlay export and forced GLES transition-overlay route)
//
// Claims: dynamic keyframed static sticker overlay export
// (P5-OVERLAYS-DYNAMIC-KEYFRAME-EXPORT), static sticker overlay compositing
// on solo frames, AND on all supported Vulkan transition overlap frames
// (dissolve, crossfade, slideLeft, slideRight, slideUp, slideDown,
// wipeLeft, wipeRight, wipeUp, wipeDown) under
// P5-OVERLAYS-ALL-SUPPORTED-TRANSITION-DIRECTIONS-PROOF / P5-OVERLAYS-TRANS,
// AND overlays alongside clip-level Beauty V2 on both transition overlap
// frames (P5-OVERLAYS-BEAUTY-TRANSITION-OVERLAP-ONLY) and solo frames
// (P5-OVERLAYS-BEAUTY-SOLO), text overlay production export via
// rasterized RGBA texture upload (P5-OVERLAYS-TEXT-PRODUCTION-EXPORT), AND
// emoji overlay production export via rasterized RGBA texture upload
// (P5-OVERLAYS-EMOJI-PRODUCTION-EXPORT), AND forced GLES overlay+transition export
// (P5-GLES-EXPORT-TRANSITION-OVERLAYS).
//
// Strict non-claims:
//   - All supported Vulkan transition wire types with overlays are physically
//     proved on SM-A566B; unsupported transitions (e.g. fade) fail closed elsewhere;
//   - GLES overlay export outside supported forced transition overlap scopes
//     (Beauty/reverse/still-image/colorMatrix in GLES remain excluded/fail closed);
//   - No realtime playback overlay compositing;
//   - No playback, app/editor UI, product, iOS, or streaming/cache;
//   - No fleet coverage beyond attached device;
//   - No pixel-quality typography / emoji glyph guarantee beyond route metrics and prior renderer proofs.
//
// Drives the REAL production `exportTimeline` MethodChannel route (no
// diagnostic native path) via VGTimelineOverlayExportSmokeRunner.
// Emits canonical ANDROID_TIMELINE_OVERLAY_EXPORT_JSON:<json> and report.marker,
// then exits 0/1.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_timeline_overlay_export_smoke.dart';

void main() {
  runApp(const AndroidTimelineOverlayExportSmokeApp());
}

class AndroidTimelineOverlayExportSmokeApp extends StatefulWidget {
  const AndroidTimelineOverlayExportSmokeApp({super.key});

  @override
  State<AndroidTimelineOverlayExportSmokeApp> createState() =>
      _AndroidTimelineOverlayExportSmokeAppState();
}

class _AndroidTimelineOverlayExportSmokeAppState
    extends State<AndroidTimelineOverlayExportSmokeApp> {
  String _status = 'Running Android timeline overlay export physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<File> _copyAsset(String asset, String target) async {
    final data = await rootBundle.load(asset);
    final file = File(target);
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    return file;
  }

  Future<void> _runSmoke() async {
    print('ANDROID_TIMELINE_OVERLAY_EXPORT_SMOKE: START');
    VGTimelineOverlayExportSmokeReport report;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final workDir = Directory(
      '${Directory.systemTemp.path}/vg_overlay_smoke_$stamp',
    );
    final cleanupFiles = <File>[];

    try {
      workDir.createSync(recursive: true);

      final clipA = await _copyAsset(
        'assets/manual_test_clips/clip_B.mov',
        '${workDir.path}/vg_overlay_export_clipA_$stamp.mov',
      );
      final clipB = await _copyAsset(
        'assets/manual_test_clips/clip_B.mov',
        '${workDir.path}/vg_overlay_export_clipB_$stamp.mov',
      );
      final sticker = await _copyAsset(
        'assets/manual_test_clips/still_C.png',
        '${workDir.path}/vg_overlay_export_sticker_$stamp.png',
      );
      cleanupFiles.addAll(<File>[clipA, clipB, sticker]);

      final nonExistentAssetPath =
          '${workDir.path}/vg_missing_sticker_$stamp.png';

      final requests = buildDefaultOverlayExportSmokeSuite(
        clipPathA: clipA.path,
        clipPathB: clipB.path,
        stickerAssetPath: sticker.path,
        nonExistentAssetPath: nonExistentAssetPath,
        outputDirectory: workDir.path,
      );

      for (final request in requests) {
        cleanupFiles.add(File(request.outputPath));
        cleanupFiles.add(File('${request.outputPath}.roi.json'));
      }

      report = await const VGTimelineOverlayExportSmokeRunner().run(requests);
      for (final lane in report.lanes) {
        print('$overlayLanePrefix${jsonEncode(lane.toMap())}');
      }
    } catch (error, stack) {
      print('ANDROID_TIMELINE_OVERLAY_EXPORT_ERROR: $error\n$stack');
      report = VGTimelineOverlayExportSmokeReport(
        lanes: <VGTimelineOverlayExportSmokeLaneReport>[
          VGTimelineOverlayExportSmokeLaneReport(
            laneId: 'harness',
            pass: false,
            status: 'FAIL',
            failureReason: 'harness_exception:$error',
            expectedSuccess: true,
            expectedDurationSeconds: 0.0,
          ),
        ],
      );
    } finally {
      for (final file in cleanupFiles) {
        try {
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
      }
      try {
        if (workDir.existsSync()) {
          workDir.deleteSync();
        }
      } catch (_) {}
    }

    final payload = report.toMap();
    print('$overlayJsonPrefix${jsonEncode(payload)}');
    print(report.marker);

    if (mounted) {
      setState(() {
        _status = report.pass
            ? 'PASS\n${report.lanes.map((l) => '${l.laneId}: ${l.status} '
                  'backend=${l.renderBackend ?? '-'} '
                  'dur=${l.durationSeconds?.toStringAsFixed(3) ?? '-'} '
                  'overlays=${l.overlayCount ?? '-'}').join('\n')}'
            : 'FAIL: ${report.failureReason}';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(report.pass ? 0 : 1);
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
