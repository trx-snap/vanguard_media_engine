// android_gles_dual_oes_transition_physical_smoke.dart
// Vanguard Media Engine - P5-GLES-EXPORT-DUAL-OES-TRANSITION-READINESS:
// diagnostic-only proof that TWO real MediaCodec decoders feed two
// independent SurfaceTexture / GL_TEXTURE_EXTERNAL_OES textures on one
// caller-owned ES3 EGL context, then render one compositor-owned GLES
// transition frame through the private
// `GlesTimelineTransitionCompositor::drawTransition` helper.
//
// Route:
//   assets/manual_test_clips/clip_A.mov ("from") and clip_B.mov ("to") ->
//   two independent MediaCodec decodes onto two harness-owned
//   GL_TEXTURE_EXTERNAL_OES textures (one caller-owned ES3 EGL pbuffer
//   context) -> ES3 current-context assertion -> bounded wait for both
//   frame-available callbacks -> updateTexImage() for both -> native
//   `drawAndroidDagPhase5GlesDualOesTransition` seam call (fixed crossfade
//   midpoint, progress 0.5) on the already-current ES3 context ->
//   glReadPixels pixel-proof/state-restoration assertions.
//
// Non-claims: diagnostic only. No production GLES transition export route;
// `GlesTimelineTransitionCompositor` itself is untouched.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_gles_dual_oes_transition_smoke.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE5_GLES_DUAL_OES_TRANSITION_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_GLES_DUAL_OES_TRANSITION_PHYSICAL_SMOKE_FAIL';
const String _logPrefix = 'ANDROID_DAG_PHASE5_GLES_DUAL_OES_TRANSITION';

void main() {
  runApp(const AndroidGlesDualOesTransitionPhysicalSmokeApp());
}

class AndroidGlesDualOesTransitionPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesDualOesTransitionPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesDualOesTransitionPhysicalSmokeApp> createState() =>
      _AndroidGlesDualOesTransitionPhysicalSmokeAppState();
}

class _AndroidGlesDualOesTransitionPhysicalSmokeAppState
    extends State<AndroidGlesDualOesTransitionPhysicalSmokeApp> {
  String _status = 'Initializing GLES dual-OES transition physical smoke...';

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
    VGGlesDualOesTransitionSmokeReport? report;
    File? fromTempFile;
    File? toTempFile;

    try {
      final fromBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_A.mov',
      );
      final toBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      fromTempFile = File(
        '${tempDir.path}/gles_dual_oes_transition_clip_a_smoke.mov',
      );
      toTempFile = File(
        '${tempDir.path}/gles_dual_oes_transition_clip_b_smoke.mov',
      );
      await fromTempFile.writeAsBytes(
        fromBytes.buffer.asUint8List(
          fromBytes.offsetInBytes,
          fromBytes.lengthInBytes,
        ),
        flush: true,
      );
      await toTempFile.writeAsBytes(
        toBytes.buffer.asUint8List(
          toBytes.offsetInBytes,
          toBytes.lengthInBytes,
        ),
        flush: true,
      );

      report =
          await VGGlesDualOesTransitionSmokeReport.runAndroidDagPhase5GlesDualOesTransitionSmoke(
            fromClipPath: fromTempFile.path,
            toClipPath: toTempFile.path,
            timeout: const Duration(seconds: 20),
          ).timeout(const Duration(seconds: 30));

      print(
        '${_logPrefix}_LANE_ARGS: argumentValidationOk=${report.argumentValidationPass}',
      );
      print(
        '${_logPrefix}_LANE_SETUP: eglSetupOk=${report.eglSetupPass} '
        'es3ContextVerifiedOk=${report.es3ContextVerifiedPass} '
        'glMajorVersion=${report.glMajorVersion}',
      );
      print(
        '${_logPrefix}_LANE_DECODE: dualDecoderSetupOk=${report.dualDecoderSetupPass} '
        'bothFramesAvailableOk=${report.bothFramesAvailablePass} '
        'bothUpdateTexImageOk=${report.bothUpdateTexImagePass} '
        'fromPtsUs=${report.fromPtsUs} toPtsUs=${report.toPtsUs}',
      );
      print(
        '${_logPrefix}_LANE_TRANSITION: nativeTransitionDrawOk=${report.nativeTransitionDrawPass} '
        'pixelProofOk=${report.pixelProofPass} '
        'nativeRaw=${report.nativeRaw}',
      );
      print(
        '${_logPrefix}_LANE_STATE: stateRestoredOk=${report.stateRestoredPass}',
      );
      print('${_logPrefix}_LANE_CLEANUP: cleanupOk=${report.cleanupPass}');
      print(
        '${_logPrefix}_LANE_SUMMARY: pass=${report.pass} isPass=${report.isPass} '
        'status=${report.status} marker=${report.marker} '
        'proofBoundary=${report.proofBoundary} '
        'failureReason=${report.failureReason}',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: GLES dual-OES transition smoke exceeded timeout: $te';
      print('${_logPrefix}_SMOKE_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('${_logPrefix}_SMOKE_ERROR: $topLevelError');
    } finally {
      try {
        await fromTempFile?.delete();
      } catch (_) {}
      try {
        await toTempFile?.delete();
      } catch (_) {}

      final pass = report?.isPass == true && topLevelError == null;

      final payload = <String, dynamic>{
        'unit': 'AndroidGlesDualOesTransitionSmokeHarness',
        'slice': 'P5-GLES-EXPORT-DUAL-OES-TRANSITION-READINESS',
        'target': VGGlesDualOesTransitionSmokeReport.proofBoundaryConstant,
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
