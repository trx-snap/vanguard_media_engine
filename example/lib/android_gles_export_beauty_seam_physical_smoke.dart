// android_gles_export_beauty_seam_physical_smoke.dart
// Vanguard Media Engine - P5-GLES-EXPORT-OES-2D-BEAUTY-RESOLVE-READINESS:
// diagnostic-only proof that a REAL MediaCodec decode -> SurfaceTexture ->
// GL_TEXTURE_EXTERNAL_OES frame, resolved on its own current-verified ES3
// EGL pbuffer context to a GL_TEXTURE_2D RGBA8 raster, still routes into the
// caller-current native `GlesBeautyV2Compositor::DrawBeautyV2` seam.
//
// Route:
//   assets/manual_test_clips/clip_B.mov -> MediaCodec decode onto a
//   SurfaceTexture bound to a harness-owned GL_TEXTURE_EXTERNAL_OES texture
//   -> ES3 current-context assertion (GL_MAJOR_VERSION query, no GL error)
//   -> minimal ES2-compatible external-OES passthrough draw into an FBO
//   resolving to GL_TEXTURE_2D RGBA8 -> native
//   `drawAndroidDagPhase5GlesExportBeautySeam` seam call (default- and
//   strong-intensity variants) on the already-current ES3 context ->
//   glReadPixels composite/state-restoration assertions.
//
// Non-claims: diagnostic only. No production GLES Beauty export route/
// session/backend-selector/encoder change; `GlesBeautyV2Compositor` itself
// is untouched.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_gles_export_beauty_seam_smoke.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE5_GLES_EXPORT_BEAUTY_SEAM_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_GLES_EXPORT_BEAUTY_SEAM_PHYSICAL_SMOKE_FAIL';
const String _logPrefix = 'ANDROID_DAG_PHASE5_GLES_EXPORT_BEAUTY_SEAM';

void main() {
  runApp(const AndroidGlesExportBeautySeamPhysicalSmokeApp());
}

class AndroidGlesExportBeautySeamPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesExportBeautySeamPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesExportBeautySeamPhysicalSmokeApp> createState() =>
      _AndroidGlesExportBeautySeamPhysicalSmokeAppState();
}

class _AndroidGlesExportBeautySeamPhysicalSmokeAppState
    extends State<AndroidGlesExportBeautySeamPhysicalSmokeApp> {
  String _status = 'Initializing GLES export beauty seam physical smoke...';

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
    VGGlesExportBeautySeamSmokeReport? report;
    File? tempFile;

    try {
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      tempFile = File(
        '${tempDir.path}/gles_export_beauty_seam_clip_b_smoke.mov',
      );
      await tempFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      report =
          await VGGlesExportBeautySeamSmokeReport.runAndroidDagPhase5GlesExportBeautySeamSmoke(
            videoPath: tempFile.path,
            timeout: const Duration(seconds: 20),
          ).timeout(const Duration(seconds: 30));

      print(
        '${_logPrefix}_LANE_SETUP: eglSetupOk=${report.eglSetupPass} '
        'invalidArgumentsRejectedOk=${report.invalidArgumentsRejectedPass}',
      );
      print(
        '${_logPrefix}_LANE_ES3_CONTEXT: es3ContextVerifiedOk=${report.es3ContextVerifiedPass} '
        'glMajorVersion=${report.details['glMajorVersion']} '
        'es3ContextDetails=${report.details['es3ContextDetails']}',
      );
      print(
        '${_logPrefix}_LANE_DECODE: decodeOk=${report.decodePass} '
        'updateTexImageOk=${report.updateTexImagePass}',
      );
      print(
        '${_logPrefix}_LANE_RESOLVE: oesResolveOk=${report.oesResolvePass} '
        'resolvedNonUniformOk=${report.resolvedNonUniformPass} '
        'beforeBeautyRgba=${report.details['beforeBeautyRgba']}',
      );
      print(
        '${_logPrefix}_LANE_SEAM: seamCallOk=${report.seamCallPass} '
        'seamDefaultRaw=${report.details['seamDefaultRaw']} '
        'seamStrongRaw=${report.details['seamStrongRaw']}',
      );
      print(
        '${_logPrefix}_LANE_COMPOSITE: beautyDeltaOk=${report.beautyDeltaPass} '
        'strongIntensityDeltaOk=${report.strongIntensityDeltaPass} '
        'defaultTotalDelta=${report.details['defaultTotalDelta']} '
        'strongTotalDelta=${report.details['strongTotalDelta']}',
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
          'Watchdog timeout: GLES export beauty seam smoke exceeded timeout: $te';
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
        'unit': 'AndroidGlesExportBeautySeamSmokeHarness',
        'slice': 'P5-GLES-EXPORT-OES-2D-BEAUTY-RESOLVE-READINESS',
        'target': VGGlesExportBeautySeamSmokeReport.proofBoundaryConstant,
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
