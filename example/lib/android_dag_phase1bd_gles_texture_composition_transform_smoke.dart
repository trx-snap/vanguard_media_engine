// Vanguard Android True-DAG Phase 1-Unit BD: Android GLES SurfaceProducer
// Texture DAG Two-Source Composition Hardware Render Transform Physical
// Proof.
//
// Route:
//   Reuses the Phase 1-Unit BB bridge/native route
//   (startAndroidDagPhase1BBGlesTextureCompositionDagSmoke /
//   disposeAndroidDagPhase1BBGlesTextureCompositionDagSmoke /
//   onAndroidDagPhase1BBGlesTextureCompositionDagSmokeComplete), extended
//   with independent per-source rotationDegreesA/mirrorHorizontalA and
//   rotationDegreesB/mirrorHorizontalB render-transform arguments, matching
//   the Unit AZ pattern. No new MethodChannel route.
//
// Dart responsibilities:
//   - Loop the 8-case decision-complete matrix (see _cases below), covering
//     cardinal rotations on either/both sources, independent mirroring, and
//     a non-cardinal (45-degree) case that must normalize to 0 for both
//     sources while the raw input fields are preserved unchanged.
//   - For each case, start the smoke with width=64, height=64,
//     frameCount=30, frameDurationUs=33333, frameDelayMs=0, plus the case's
//     per-source rotation/mirror arguments; mount Texture(textureId) once
//     start returns; await the completion callback with a bounded timeout;
//     dispose in finally before the next case.
//   - Gate each case's PASS on: pass == true, a valid/matching textureId,
//     surfaceProducerReleased == false before dispose, all BB core success
//     fields (initialize/attach/graphBuild/importA/importB/evaluation/
//     renderFrame/releaseA/releaseB) == success, renderedFrames == 30,
//     frameCount == 30, frameDelayMs == 0, releaseFenceExported == true,
//     compositorActive == true, monotonicWeights == true, startWeightB ==
//     0.0, endWeightB == 1.0, the exact proofBoundary string, an empty/none
//     lastError, raw rotationDegreesA/mirrorHorizontalA/rotationDegreesB/
//     mirrorHorizontalB matching the case input, and
//     normalizedRotationDegreesA/B matching the Dart normalization function.
//     Dispose after completion must return surfaceProducerReleased == true
//     and a raw string containing disposed=true.
//   - Aggregate a JSON report across all cases and print
//     ANDROID_DAG_PHASE1BD_JSON:<json> and
//     ANDROID_DAG_PHASE1BD_PHYSICAL_SMOKE_PASS/FAIL.
//
// Non-claims: no decoded input, no ImageReader.PRIVATE, no product UI, no
// ConnectsApp wiring, no graph-owned pixel-handle transport, no Dart visual
// pixel verification. No Phase 1 closure.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _proofBoundary =
    'gles_surfaceproducer_texture_dag_two_source_composition_no_decoded_input_no_product_ui';

const _width = 64;
const _height = 64;
const _frameCount = 30;
const _frameDurationUs = 33333;
const _frameDelayMs = 0;

class _TransformCase {
  const _TransformCase({
    required this.rotationDegreesA,
    required this.mirrorHorizontalA,
    required this.rotationDegreesB,
    required this.mirrorHorizontalB,
  });

  final int rotationDegreesA;
  final bool mirrorHorizontalA;
  final int rotationDegreesB;
  final bool mirrorHorizontalB;
}

const _cases = <_TransformCase>[
  _TransformCase(
    rotationDegreesA: 0,
    mirrorHorizontalA: false,
    rotationDegreesB: 0,
    mirrorHorizontalB: false,
  ),
  _TransformCase(
    rotationDegreesA: 90,
    mirrorHorizontalA: false,
    rotationDegreesB: 0,
    mirrorHorizontalB: false,
  ),
  _TransformCase(
    rotationDegreesA: 180,
    mirrorHorizontalA: true,
    rotationDegreesB: 0,
    mirrorHorizontalB: false,
  ),
  _TransformCase(
    rotationDegreesA: 0,
    mirrorHorizontalA: false,
    rotationDegreesB: 90,
    mirrorHorizontalB: false,
  ),
  _TransformCase(
    rotationDegreesA: 0,
    mirrorHorizontalA: false,
    rotationDegreesB: 180,
    mirrorHorizontalB: true,
  ),
  _TransformCase(
    rotationDegreesA: 90,
    mirrorHorizontalA: true,
    rotationDegreesB: 270,
    mirrorHorizontalB: false,
  ),
  _TransformCase(
    rotationDegreesA: 270,
    mirrorHorizontalA: false,
    rotationDegreesB: 90,
    mirrorHorizontalB: true,
  ),
  _TransformCase(
    rotationDegreesA: 45,
    mirrorHorizontalA: true,
    rotationDegreesB: 45,
    mirrorHorizontalB: true,
  ),
];

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
  runApp(const AndroidDagPhase1BDGlesTextureCompositionTransformSmokeApp());
}

class AndroidDagPhase1BDGlesTextureCompositionTransformSmokeApp
    extends StatefulWidget {
  const AndroidDagPhase1BDGlesTextureCompositionTransformSmokeApp({super.key});

  @override
  State<AndroidDagPhase1BDGlesTextureCompositionTransformSmokeApp>
  createState() =>
      _AndroidDagPhase1BDGlesTextureCompositionTransformSmokeAppState();
}

class _AndroidDagPhase1BDGlesTextureCompositionTransformSmokeAppState
    extends State<AndroidDagPhase1BDGlesTextureCompositionTransformSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _completeMethod =
      'onAndroidDagPhase1BBGlesTextureCompositionDagSmokeComplete';

  String _status =
      'Running Android DAG Phase 1BD GLES texture composition transform smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<Map<String, dynamic>> _runCase(_TransformCase testCase) async {
    int? activeTextureId;
    var completionPayload = <String, dynamic>{};
    var disposePayload = <String, dynamic>{};
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
        'startAndroidDagPhase1BBGlesTextureCompositionDagSmoke',
        {
          'width': _width,
          'height': _height,
          'frameCount': _frameCount,
          'frameDurationUs': _frameDurationUs,
          'frameDelayMs': _frameDelayMs,
          'rotationDegreesA': testCase.rotationDegreesA,
          'mirrorHorizontalA': testCase.mirrorHorizontalA,
          'rotationDegreesB': testCase.rotationDegreesB,
          'mirrorHorizontalB': testCase.mirrorHorizontalB,
        },
      );

      final startMap = Map<String, dynamic>.from(startResponse! as Map);
      activeTextureId = (startMap['textureId'] as num?)?.toInt();

      if (mounted && activeTextureId != null) {
        setState(() {
          _textureId = activeTextureId;
          _status =
              'Rendering Android DAG Phase 1BD texture composition transform '
              'smoke (textureId=$activeTextureId, '
              'rotationDegreesA=${testCase.rotationDegreesA}, '
              'mirrorHorizontalA=${testCase.mirrorHorizontalA}, '
              'rotationDegreesB=${testCase.rotationDegreesB}, '
              'mirrorHorizontalB=${testCase.mirrorHorizontalB})…';
        });
      }

      completionPayload = await completer.future.timeout(
        const Duration(seconds: 15),
      );
      completionReached = true;
    } catch (error, stack) {
      print(
        'ANDROID_DAG_PHASE1BD_ERROR: '
        'rotationDegreesA=${testCase.rotationDegreesA} '
        'mirrorHorizontalA=${testCase.mirrorHorizontalA} '
        'rotationDegreesB=${testCase.rotationDegreesB} '
        'mirrorHorizontalB=${testCase.mirrorHorizontalB} '
        '$error\n$stack',
      );
      completionPayload = <String, dynamic>{
        'pass': false,
        'raw':
            'status=FAIL;reason=dart_exception;renderedFrames=0;frameCount=$_frameCount',
        'textureId': activeTextureId,
        'width': _width,
        'height': _height,
        'frameCount': _frameCount,
        'frameDelayMs': _frameDelayMs,
        'renderedFrames': 0,
        'releaseFenceExported': false,
        'textureSurface': false,
        'compositorActive': false,
        'monotonicWeights': false,
        'startWeightB': 0.0,
        'endWeightB': 0.0,
        'proofBoundary': _proofBoundary,
        'lastError': 'dart_invoke_exception',
        'surfaceProducerReleased': false,
        'rotationDegreesA': testCase.rotationDegreesA,
        'mirrorHorizontalA': testCase.mirrorHorizontalA,
        'normalizedRotationDegreesA': _normalizeRotation(
          testCase.rotationDegreesA,
        ),
        'rotationDegreesB': testCase.rotationDegreesB,
        'mirrorHorizontalB': testCase.mirrorHorizontalB,
        'normalizedRotationDegreesB': _normalizeRotation(
          testCase.rotationDegreesB,
        ),
      };
    } finally {
      _channel.setMethodCallHandler(null);
      if (activeTextureId != null) {
        if (mounted && _textureId == activeTextureId) {
          setState(() {
            _textureId = null;
          });
          await WidgetsBinding.instance.endOfFrame;
          await Future<void>.delayed(const Duration(milliseconds: 32));
        }
        try {
          final disposeResponse = await _channel.invokeMethod<Object?>(
            'disposeAndroidDagPhase1BBGlesTextureCompositionDagSmoke',
            <String, Object>{'textureId': activeTextureId},
          );
          disposePayload = Map<String, dynamic>.from(disposeResponse! as Map);
        } catch (_) {}
      }
    }

    final expectedNormalizedRotationDegreesA = _normalizeRotation(
      testCase.rotationDegreesA,
    );
    final expectedNormalizedRotationDegreesB = _normalizeRotation(
      testCase.rotationDegreesB,
    );
    final textureId =
        (completionPayload['textureId'] as num?)?.toInt() ?? activeTextureId;
    final lastError = completionPayload['lastError'];
    final lastErrorOk =
        lastError == null || lastError == '' || lastError == 'none';

    final disposeRaw = disposePayload['raw']?.toString() ?? '';
    final disposeOk =
        disposePayload['pass'] == true &&
        disposePayload['surfaceProducerReleased'] == true &&
        disposeRaw.contains('disposed=true');

    final completionOk =
        completionReached &&
        completionPayload['pass'] == true &&
        textureId != null &&
        textureId >= 0 &&
        textureId == activeTextureId &&
        completionPayload['surfaceProducerReleased'] == false &&
        completionPayload['initialize'] == 'success' &&
        completionPayload['attach'] == 'success' &&
        completionPayload['graphBuild'] == 'success' &&
        completionPayload['importA'] == 'success' &&
        completionPayload['importB'] == 'success' &&
        completionPayload['evaluation'] == 'success' &&
        completionPayload['renderFrame'] == 'success' &&
        completionPayload['releaseA'] == 'success' &&
        completionPayload['releaseB'] == 'success' &&
        completionPayload['renderedFrames'] == _frameCount &&
        completionPayload['frameCount'] == _frameCount &&
        completionPayload['frameDelayMs'] == _frameDelayMs &&
        completionPayload['releaseFenceExported'] == true &&
        completionPayload['textureSurface'] == true &&
        completionPayload['compositorActive'] == true &&
        completionPayload['monotonicWeights'] == true &&
        (completionPayload['startWeightB'] as num?) == 0.0 &&
        (completionPayload['endWeightB'] as num?) == 1.0 &&
        completionPayload['proofBoundary'] == _proofBoundary &&
        lastErrorOk &&
        completionPayload['rotationDegreesA'] == testCase.rotationDegreesA &&
        completionPayload['mirrorHorizontalA'] == testCase.mirrorHorizontalA &&
        completionPayload['normalizedRotationDegreesA'] ==
            expectedNormalizedRotationDegreesA &&
        completionPayload['rotationDegreesB'] == testCase.rotationDegreesB &&
        completionPayload['mirrorHorizontalB'] == testCase.mirrorHorizontalB &&
        completionPayload['normalizedRotationDegreesB'] ==
            expectedNormalizedRotationDegreesB;

    final pass = completionOk && disposeOk;

    return <String, dynamic>{
      'rotationDegreesA': testCase.rotationDegreesA,
      'mirrorHorizontalA': testCase.mirrorHorizontalA,
      'rotationDegreesB': testCase.rotationDegreesB,
      'mirrorHorizontalB': testCase.mirrorHorizontalB,
      'expectedNormalizedRotationDegreesA': expectedNormalizedRotationDegreesA,
      'expectedNormalizedRotationDegreesB': expectedNormalizedRotationDegreesB,
      'completionPayload': completionPayload,
      'disposePayload': disposePayload,
      'pass': pass,
    };
  }

  Future<void> _runSmoke() async {
    final caseReports = <Map<String, dynamic>>[];

    for (final testCase in _cases) {
      final caseReport = await _runCase(testCase);
      caseReports.add(caseReport);
    }

    final pass = caseReports.every((caseReport) => caseReport['pass'] == true);

    final report = <String, dynamic>{'cases': caseReports, 'pass': pass};

    print('ANDROID_DAG_PHASE1BD_JSON:${jsonEncode(report)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE1BD_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE1BD_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: see ANDROID_DAG_PHASE1BD_JSON log';
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
