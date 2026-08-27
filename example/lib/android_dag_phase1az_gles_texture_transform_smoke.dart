// Vanguard Android True-DAG Phase 1-Unit AZ: Android GLES SurfaceProducer
// Texture DAG Hardware Render Transform (Rotation & Horizontal Mirroring)
// Physical Proof.
//
// Route:
//   Reuses the Phase 1-Unit AX/AY bridge/native route
//   (startAndroidDagPhase1AXGlesTextureRenderSmoke /
//   disposeAndroidDagPhase1AXGlesTextureRenderSmoke /
//   onAndroidDagPhase1AXGlesTextureRenderSmokeComplete), extended with
//   rotationDegrees/mirrorHorizontal render-transform arguments. No new
//   MethodChannel route.
//
// Dart responsibilities:
//   - Loop all 8 cases: rotationDegrees in {0, 90, 180, 270} x
//     mirrorHorizontal in {false, true}.
//   - For each case, start the smoke with width=64, height=64,
//     frameCount=30, frameDurationUs=33333, frameDelayMs=0, plus the case's
//     rotationDegrees/mirrorHorizontal; mount Texture(textureId) once start
//     returns; await the completion callback with a 15s timeout.
//   - Gate each case's PASS on: pass == true, a valid/matching textureId,
//     renderedFrames == 30, frameCount == 30, evaluatedPtsUs == 966657,
//     textureSurface == true, releaseFenceExported == true, the exact
//     proofBoundary string, an empty/none lastError, rotationDegrees ==
//     input, mirrorHorizontal == input, and normalizedRotationDegrees ==
//     the expected cardinal normalization.
//   - Dispose the texture after each case (before starting the next), with
//     a best-effort dispose in finally on timeout/failure.
//   - Aggregate a JSON report across all 8 cases and print
//     ANDROID_DAG_PHASE1AZ_JSON:<json> and
//     ANDROID_DAG_PHASE1AZ_PHYSICAL_SMOKE_PASS/FAIL.
//
// Non-claims: no Flutter texture pixel readback/visual correctness, no
// MediaCodec decoded input, no ImageReader.PRIVATE, no product UI, no
// ConnectsApp wiring, no Phase 1 closure.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _proofBoundary =
    'gles_surfaceproducer_texture_dag_render_foundation_no_decoded_input_no_product_ui';

const _width = 64;
const _height = 64;
const _frameCount = 30;
const _frameDurationUs = 33333;
const _frameDelayMs = 0;
const _expectedEvaluatedPtsUs = 966657;

const _rotationCases = [0, 90, 180, 270];
const _mirrorCases = [false, true];

int _normalizeRotation(int degrees) {
  final normalized = degrees % 360;
  switch (normalized) {
    case 0:
    case 90:
    case 180:
    case 270:
      return normalized;
    default:
      return 0;
  }
}

void main() {
  runApp(const AndroidDagPhase1AZGlesTextureTransformSmokeApp());
}

class AndroidDagPhase1AZGlesTextureTransformSmokeApp extends StatefulWidget {
  const AndroidDagPhase1AZGlesTextureTransformSmokeApp({super.key});

  @override
  State<AndroidDagPhase1AZGlesTextureTransformSmokeApp> createState() =>
      _AndroidDagPhase1AZGlesTextureTransformSmokeAppState();
}

class _AndroidDagPhase1AZGlesTextureTransformSmokeAppState
    extends State<AndroidDagPhase1AZGlesTextureTransformSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _completeMethod =
      'onAndroidDagPhase1AXGlesTextureRenderSmokeComplete';

  String _status =
      'Running Android DAG Phase 1AZ GLES texture transform smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<Map<String, dynamic>> _runCase(
    int rotationDegrees,
    bool mirrorHorizontal,
  ) async {
    int? activeTextureId;
    Map<String, dynamic> payload;
    var completionReached = false;

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
        {
          'width': _width,
          'height': _height,
          'frameCount': _frameCount,
          'frameDurationUs': _frameDurationUs,
          'frameDelayMs': _frameDelayMs,
          'rotationDegrees': rotationDegrees,
          'mirrorHorizontal': mirrorHorizontal,
        },
      );

      final startMap = Map<String, dynamic>.from(startResponse! as Map);
      activeTextureId = (startMap['textureId'] as num?)?.toInt();

      if (mounted && activeTextureId != null) {
        setState(() {
          _textureId = activeTextureId;
          _status =
              'Rendering Android DAG Phase 1AZ texture transform smoke '
              '(textureId=$activeTextureId, rotationDegrees=$rotationDegrees, '
              'mirrorHorizontal=$mirrorHorizontal)…';
        });
      }

      payload = await completer.future.timeout(const Duration(seconds: 15));
      completionReached = true;
    } catch (error, stack) {
      print(
        'ANDROID_DAG_PHASE1AZ_ERROR: '
        'rotationDegrees=$rotationDegrees mirrorHorizontal=$mirrorHorizontal '
        '$error\n$stack',
      );
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
        'rotationDegrees': rotationDegrees,
        'mirrorHorizontal': mirrorHorizontal,
        'normalizedRotationDegrees': _normalizeRotation(rotationDegrees),
      };
    } finally {
      _channel.setMethodCallHandler(null);
      if (activeTextureId != null) {
        try {
          await _channel.invokeMethod<Object?>(
            'disposeAndroidDagPhase1AXGlesTextureRenderSmoke',
            <String, Object>{'textureId': activeTextureId},
          );
        } catch (_) {}
      }
    }

    final expectedNormalizedRotationDegrees = _normalizeRotation(
      rotationDegrees,
    );
    final textureId =
        (payload['textureId'] as num?)?.toInt() ?? activeTextureId;
    final lastError = payload['lastError'];
    final lastErrorOk =
        lastError == null || lastError == '' || lastError == 'none';

    final pass =
        completionReached &&
        payload['pass'] == true &&
        textureId != null &&
        textureId >= 0 &&
        textureId == activeTextureId &&
        payload['renderedFrames'] == _frameCount &&
        payload['frameCount'] == _frameCount &&
        payload['evaluatedPtsUs'] == _expectedEvaluatedPtsUs &&
        payload['textureSurface'] == true &&
        payload['releaseFenceExported'] == true &&
        payload['proofBoundary'] == _proofBoundary &&
        lastErrorOk &&
        payload['rotationDegrees'] == rotationDegrees &&
        payload['mirrorHorizontal'] == mirrorHorizontal &&
        payload['normalizedRotationDegrees'] ==
            expectedNormalizedRotationDegrees;

    return <String, dynamic>{
      'rotationDegrees': rotationDegrees,
      'mirrorHorizontal': mirrorHorizontal,
      'expectedNormalizedRotationDegrees': expectedNormalizedRotationDegrees,
      'completionPayload': payload,
      'pass': pass,
    };
  }

  Future<void> _runSmoke() async {
    final caseReports = <Map<String, dynamic>>[];

    for (final rotationDegrees in _rotationCases) {
      for (final mirrorHorizontal in _mirrorCases) {
        final caseReport = await _runCase(rotationDegrees, mirrorHorizontal);
        caseReports.add(caseReport);
      }
    }

    final pass = caseReports.every((caseReport) => caseReport['pass'] == true);

    final report = <String, dynamic>{'cases': caseReports, 'pass': pass};

    print('ANDROID_DAG_PHASE1AZ_JSON:${jsonEncode(report)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE1AZ_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE1AZ_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: see ANDROID_DAG_PHASE1AZ_JSON log';
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
