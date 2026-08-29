// Vanguard Android True-DAG Phase 1-Unit AW-OES: Android GLES Decoded
// SurfaceTexture/OES DAG Render Foundation Physical Smoke.
//
// Route:
//   assets/manual_test_clips/clip_B.mov -> MediaCodec decode onto a
//   SurfaceTexture bound to a native-allocated GL_TEXTURE_EXTERNAL_OES
//   texture -> native SurfaceTexture.updateTexImage() + diagnostic DAG
//   playhead evaluation (gated on the decoded frame's
//   MediaCodec.BufferInfo.presentationTimeUs) -> GlesBackend
//   presentDiagnosticExternalOesTexture() on a Flutter
//   TextureRegistry.SurfaceProducer texture.
//
// Original Phase 1-Unit AW (ImageReader.PRIVATE + AHardwareBuffer import of
// the decoded frame) remains DEFERRED / VERIFIED_PHYSICAL_FAILURE
// (`ahb_import_unsupported_format`); this smoke does not claim to fix it --
// it proves only the alternate SurfaceTexture/OES render path, which never
// imports an AHardwareBuffer or uses ImageReader.PRIVATE.
//
// Dart responsibilities:
//   - Copy assets/manual_test_clips/clip_B.mov from rootBundle to a temp file
//     using only Dart SDK APIs (no path_provider, no file_picker).
//   - Invoke startAndroidDagPhase1AWOESGlesDecodedOesSmoke with the temp
//     path and maxFrames=10.
//   - Display Texture(textureId) once start returns.
//   - Await the onAndroidDagPhase1AWOESGlesDecodedOesSmokeComplete callback
//     with a bounded timeout.
//   - Gate PASS only on: pass == true, a valid textureId, renderedFrames ==
//     10, the exact proofBoundary string, a monotonic non-negative decoded
//     PTS list, and an empty/none lastError.
//   - Always call disposeAndroidDagPhase1AWOESGlesDecodedOesSmoke in finally.
//   - Print ANDROID_DAG_PHASE1AWOES_JSON:<json> and
//     ANDROID_DAG_PHASE1AWOES_PHYSICAL_SMOKE_PASS/FAIL.
//
// Non-claims (asserted explicitly in the printed report): no AHardwareBuffer
// import, no ImageReader.PRIVATE, no color-correct YUV->RGB conversion
// policy, no product UI, no ConnectsApp wiring.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _proofBoundary =
    'gles_decoded_surfacetexture_oes_dag_render_no_ahb_import_no_product_ui';

const _nonClaims = {
  'ahbImport': false,
  'imageReaderPrivate': false,
  'colorCorrectYuv': false,
  'productUi': false,
  'connectAppTouched': false,
};

void main() {
  runApp(const AndroidDagPhase1AWOESGlesDecodedOesSmokeApp());
}

class AndroidDagPhase1AWOESGlesDecodedOesSmokeApp extends StatefulWidget {
  const AndroidDagPhase1AWOESGlesDecodedOesSmokeApp({super.key});

  @override
  State<AndroidDagPhase1AWOESGlesDecodedOesSmokeApp> createState() =>
      _AndroidDagPhase1AWOESGlesDecodedOesSmokeAppState();
}

class _AndroidDagPhase1AWOESGlesDecodedOesSmokeAppState
    extends State<AndroidDagPhase1AWOESGlesDecodedOesSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _completeMethod =
      'onAndroidDagPhase1AWOESGlesDecodedOesSmokeComplete';
  static const _maxFrames = 10;

  String _status = 'Running Android DAG Phase 1AW-OES decoded OES smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    int? activeTextureId;
    Map<String, dynamic> payload;
    File? tempFile;

    final completer = Completer<Map<String, dynamic>>();

    _channel.setMethodCallHandler((call) async {
      if (call.method == _completeMethod) {
        if (!completer.isCompleted) {
          final args = call.arguments;
          completer.complete(
            args is Map ? Map<String, dynamic>.from(args) : <String, dynamic>{},
          );
        }
      }
    });

    try {
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      tempFile = File('${tempDir.path}/phase1aw_oes_clip_b_smoke.mov');
      await tempFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      final startResponse = await _channel.invokeMethod<Object?>(
        'startAndroidDagPhase1AWOESGlesDecodedOesSmoke',
        <String, Object>{'videoPath': tempFile.path, 'maxFrames': _maxFrames},
      );

      final startMap = Map<String, dynamic>.from(startResponse! as Map);
      activeTextureId = (startMap['textureId'] as num?)?.toInt();

      if (mounted && activeTextureId != null) {
        setState(() {
          _textureId = activeTextureId;
          _status =
              'Rendering Android DAG Phase 1AW-OES decoded OES smoke (textureId=$activeTextureId)…';
        });
      }

      payload = await completer.future.timeout(const Duration(seconds: 20));
    } catch (error, stack) {
      print('ANDROID_DAG_PHASE1AWOES_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'raw':
            'status=FAIL;reason=dart_exception;renderedFrames=0;'
            'frameCount=$_maxFrames',
        'textureId': activeTextureId,
        'frameCount': _maxFrames,
        'renderedFrames': 0,
        'decodedPtsUsList': <int>[],
        'proofBoundary': _proofBoundary,
        'lastError': 'dart_invoke_exception',
      };
    } finally {
      _channel.setMethodCallHandler(null);
      try {
        await tempFile?.delete();
      } catch (_) {}
      if (activeTextureId != null) {
        try {
          await _channel.invokeMethod<Object?>(
            'disposeAndroidDagPhase1AWOESGlesDecodedOesSmoke',
            <String, Object>{'textureId': activeTextureId},
          );
        } catch (_) {}
      }
    }

    final textureId =
        (payload['textureId'] as num?)?.toInt() ?? activeTextureId;
    final lastError = payload['lastError'];
    final lastErrorOk =
        lastError == null || lastError == '' || lastError == 'none';

    final decodedPtsUsList =
        (payload['decodedPtsUsList'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        const <int>[];
    var monotonicNonNegative = true;
    var previousPtsUs = -1;
    for (final ptsUs in decodedPtsUsList) {
      if (ptsUs < 0 || ptsUs < previousPtsUs) {
        monotonicNonNegative = false;
        break;
      }
      previousPtsUs = ptsUs;
    }
    monotonicNonNegative =
        monotonicNonNegative && decodedPtsUsList.length == _maxFrames;

    final pass =
        payload['pass'] == true &&
        textureId != null &&
        textureId >= 0 &&
        payload['renderedFrames'] == _maxFrames &&
        payload['proofBoundary'] == _proofBoundary &&
        monotonicNonNegative &&
        lastErrorOk;

    final report = <String, dynamic>{
      ...payload,
      'textureId': textureId,
      'monotonicNonNegativeDecodedPts': monotonicNonNegative,
      'nonClaims': _nonClaims,
      'pass': pass,
    };

    print('ANDROID_DAG_PHASE1AWOES_JSON:${jsonEncode(report)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE1AWOES_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE1AWOES_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: ${payload['raw']}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_textureId != null)
                SizedBox(
                  width: 64,
                  height: 64,
                  child: Texture(textureId: _textureId!),
                ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_status, textAlign: TextAlign.center),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
