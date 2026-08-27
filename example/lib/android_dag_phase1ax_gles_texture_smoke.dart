// Vanguard Android True-DAG Phase 1-Unit AX: Android GLES SurfaceProducer
// Flutter Texture DAG Render Smoke Foundation.
//
// Route:
//   Synthetic RGBA HardwareBuffer -> native GLES DAG playhead evaluation +
//   multi-frame render -> Flutter TextureRegistry.SurfaceProducer texture.
//
// Dart responsibilities:
//   - Invoke startAndroidDagPhase1AXGlesTextureRenderSmoke.
//   - Display Texture(textureId) once start returns.
//   - Await the onAndroidDagPhase1AXGlesTextureRenderSmokeComplete callback
//     with a bounded timeout.
//   - Gate PASS only on: pass == true, a valid textureId, renderedFrames ==
//     30, evaluatedPtsUs == (frameCount - 1) * frameDurationUs,
//     releaseFenceExported == true, textureSurface == true, the exact
//     proofBoundary string, and an empty/none lastError.
//   - Always call disposeAndroidDagPhase1AXGlesTextureRenderSmoke in finally.
//   - Print ANDROID_DAG_PHASE1AX_JSON:<json> and
//     ANDROID_DAG_PHASE1AX_PHYSICAL_SMOKE_PASS/FAIL.
//
// Non-claims: no MediaCodec decoded input, no ImageReader.PRIVATE, no
// product UI, no ConnectsApp wiring, no Phase 1 closure.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _proofBoundary =
    'gles_surfaceproducer_texture_dag_render_foundation_no_decoded_input_no_product_ui';

void main() {
  runApp(const AndroidDagPhase1AXGlesTextureSmokeApp());
}

class AndroidDagPhase1AXGlesTextureSmokeApp extends StatefulWidget {
  const AndroidDagPhase1AXGlesTextureSmokeApp({super.key});

  @override
  State<AndroidDagPhase1AXGlesTextureSmokeApp> createState() =>
      _AndroidDagPhase1AXGlesTextureSmokeAppState();
}

class _AndroidDagPhase1AXGlesTextureSmokeAppState
    extends State<AndroidDagPhase1AXGlesTextureSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _completeMethod =
      'onAndroidDagPhase1AXGlesTextureRenderSmokeComplete';
  static const _width = 64;
  static const _height = 64;
  static const _frameCount = 30;
  static const _frameDurationUs = 33333;

  String _status = 'Running Android DAG Phase 1AX GLES texture smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    int? activeTextureId;
    Map<String, dynamic> payload;

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
      final startResponse = await _channel.invokeMethod<Object?>(
        'startAndroidDagPhase1AXGlesTextureRenderSmoke',
        const {
          'width': _width,
          'height': _height,
          'frameCount': _frameCount,
          'frameDurationUs': _frameDurationUs,
        },
      );

      final startMap = Map<String, dynamic>.from(startResponse! as Map);
      activeTextureId = (startMap['textureId'] as num?)?.toInt();

      if (mounted && activeTextureId != null) {
        setState(() {
          _textureId = activeTextureId;
          _status =
              'Rendering Android DAG Phase 1AX texture smoke (textureId=$activeTextureId)…';
        });
      }

      payload = await completer.future.timeout(const Duration(seconds: 15));
    } catch (error, stack) {
      print('ANDROID_DAG_PHASE1AX_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'raw':
            'status=FAIL;reason=dart_exception;renderedFrames=0;frameCount=$_frameCount',
        'textureId': activeTextureId,
        'width': _width,
        'height': _height,
        'frameCount': _frameCount,
        'renderedFrames': 0,
        'evaluatedPtsUs': 0,
        'releaseFenceExported': false,
        'textureSurface': false,
        'proofBoundary': _proofBoundary,
        'lastError': 'dart_invoke_exception',
      };
    } finally {
      _channel.setMethodCallHandler(null);
    }

    final expectedEvaluatedPtsUs = (_frameCount - 1) * _frameDurationUs;
    final textureId =
        (payload['textureId'] as num?)?.toInt() ?? activeTextureId;
    final lastError = payload['lastError'];
    final lastErrorOk =
        lastError == null || lastError == '' || lastError == 'none';

    final pass =
        payload['pass'] == true &&
        textureId != null &&
        textureId >= 0 &&
        payload['renderedFrames'] == _frameCount &&
        payload['evaluatedPtsUs'] == expectedEvaluatedPtsUs &&
        payload['releaseFenceExported'] == true &&
        payload['textureSurface'] == true &&
        payload['proofBoundary'] == _proofBoundary &&
        lastErrorOk;

    print('ANDROID_DAG_PHASE1AX_JSON:${jsonEncode(payload)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE1AX_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE1AX_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: ${payload['raw']}';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));

    if (textureId != null) {
      try {
        await _channel.invokeMethod<Object?>(
          'disposeAndroidDagPhase1AXGlesTextureRenderSmoke',
          <String, Object>{'textureId': textureId},
        );
      } catch (_) {}
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
