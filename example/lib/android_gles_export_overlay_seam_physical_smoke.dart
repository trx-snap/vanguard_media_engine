// android_gles_export_overlay_seam_physical_smoke.dart
// Vanguard Media Engine - P5-GLES-EXPORT-OVERLAY-SEAM-A: diagnostic-only
// proof that a REAL MediaCodec decode -> SurfaceTexture ->
// GL_TEXTURE_EXTERNAL_OES frame, drawn on its own ES2 EGL pbuffer context,
// still routes into the caller-current native
// `GlesOverlayCompositor::drawOverlays` seam.
//
// Route:
//   assets/manual_test_clips/clip_B.mov -> MediaCodec decode onto a
//   SurfaceTexture bound to a harness-owned GL_TEXTURE_EXTERNAL_OES texture
//   -> minimal ES2 external-OES passthrough draw to a 128x128 EGL pbuffer ->
//   native `drawAndroidDagPhase5GlesExportOverlaySeam` seam call (one
//   semi-transparent red GL_TEXTURE_2D overlay layer) on the already-current
//   context -> glReadPixels composite/state-restoration assertions.
//
// Non-claims: diagnostic only. No production export/session/backend-
// selector/encoder change; `GlesOverlayCompositor` itself is untouched.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_gles_export_overlay_seam_smoke.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_SEAM_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_SEAM_PHYSICAL_SMOKE_FAIL';
const String _logPrefix = 'ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_SEAM';

void main() {
  runApp(const AndroidGlesExportOverlaySeamPhysicalSmokeApp());
}

class AndroidGlesExportOverlaySeamPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesExportOverlaySeamPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesExportOverlaySeamPhysicalSmokeApp> createState() =>
      _AndroidGlesExportOverlaySeamPhysicalSmokeAppState();
}

class _AndroidGlesExportOverlaySeamPhysicalSmokeAppState
    extends State<AndroidGlesExportOverlaySeamPhysicalSmokeApp> {
  String _status = 'Initializing GLES export overlay seam physical smoke...';

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
    VGGlesExportOverlaySeamSmokeReport? report;
    File? tempFile;

    try {
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      tempFile = File(
        '${tempDir.path}/gles_export_overlay_seam_clip_b_smoke.mov',
      );
      await tempFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      report =
          await VGGlesExportOverlaySeamSmokeReport.runAndroidDagPhase5GlesExportOverlaySeamSmoke(
            videoPath: tempFile.path,
            timeout: const Duration(seconds: 20),
          ).timeout(const Duration(seconds: 30));

      print(
        '${_logPrefix}_LANE_SETUP: eglSetupOk=${report.eglSetupPass} '
        'invalidArgumentsRejectedOk=${report.invalidArgumentsRejectedPass}',
      );
      print(
        '${_logPrefix}_LANE_DECODE: decodeOk=${report.decodePass} '
        'updateTexImageOk=${report.updateTexImagePass}',
      );
      print(
        '${_logPrefix}_LANE_DRAW: baseDrawOk=${report.baseDrawPass} '
        'seamCallOk=${report.seamCallPass} '
        'seamRaw=${report.details['seamRaw']}',
      );
      print(
        '${_logPrefix}_LANE_COMPOSITE: compositeAssertionOk=${report.compositeAssertionPass} '
        'beforeOutsideRgba=${report.details['beforeOutsideRgba']} '
        'afterOutsideRgba=${report.details['afterOutsideRgba']} '
        'beforeInsideRgba=${report.details['beforeInsideRgba']} '
        'afterInsideRgba=${report.details['afterInsideRgba']}',
      );
      print(
        '${_logPrefix}_LANE_STATE: stateRestoredOk=${report.stateRestoredPass}',
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
          'Watchdog timeout: GLES export overlay seam smoke exceeded timeout: $te';
      print('${_logPrefix}_SMOKE_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('${_logPrefix}_SMOKE_ERROR: $topLevelError');
    } finally {
      try {
        await tempFile?.delete();
      } catch (_) {}

      final pass = report?.isPass == true && topLevelError == null;

      final payload = <String, dynamic>{
        'unit': 'AndroidGlesExportOverlaySeamSmokeHarness',
        'slice': 'P5-GLES-EXPORT-OVERLAY-SEAM-A',
        'target': VGGlesExportOverlaySeamSmokeReport.proofBoundaryConstant,
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
