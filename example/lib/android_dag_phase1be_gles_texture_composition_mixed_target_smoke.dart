// Vanguard Android True-DAG Phase 1-Unit BE: Android GLES SurfaceProducer
// Texture DAG Two-Source Mixed Target / OES Composition Physical Proof.
//
// Route:
//   Reuses the Phase 1-Unit BB bridge/native route
//   (startAndroidDagPhase1BBGlesTextureCompositionDagSmoke /
//   disposeAndroidDagPhase1BBGlesTextureCompositionDagSmoke /
//   onAndroidDagPhase1BBGlesTextureCompositionDagSmokeComplete), extended
//   with independent per-source sourceKindA/sourceKindB ("2d"/"oes")
//   arguments so the same Graph::evaluatePlayhead ->
//   compositor weight -> GlesBackend::diagnosticPresentCompositeFrames loop
//   can render all four source target permutations. No new MethodChannel
//   route.
//
// Dart responsibilities:
//   - Loop the four source-kind permutations (2d+2d, oes+2d, 2d+oes,
//     oes+oes) below.
//   - For each case, start the smoke with width=64, height=64,
//     frameCount=30, frameDurationUs=33333, frameDelayMs=0, plus the case's
//     sourceKindA/sourceKindB arguments; mount Texture(textureId) once start
//     returns; await the completion callback with a bounded timeout; dispose
//     in finally before the next case.
//   - Gate each case's PASS on: pass == true, a valid/matching textureId,
//     surfaceProducerReleased == false before dispose, all BB core success
//     fields (initialize/attach/graphBuild/importA/importB/evaluation/
//     renderFrame/releaseA/releaseB) == success, renderedFrames == 30,
//     frameCount == 30, frameDelayMs == 0, textureSurface == true,
//     releaseFenceExported == true, compositorActive == true,
//     monotonicWeights == true, startWeightB == 0.0, endWeightB == 1.0, the
//     exact proofBoundary string, an empty/none lastError, and
//     sourceKindA/sourceKindB/targetA/targetB matching the case's expected
//     values (targetA/targetB 3553 for "2d", 36197 for "oes"). Dispose after
//     completion must return surfaceProducerReleased == true and a raw
//     string containing disposed=true.
//   - Aggregate a JSON report across all cases and print
//     ANDROID_DAG_PHASE1BE_JSON:<json> and
//     ANDROID_DAG_PHASE1BE_PHYSICAL_SMOKE_PASS/FAIL.
//
// Non-claims: no decoded input, no MediaCodec, no ImageReader.PRIVATE, no
// product UI, no ConnectsApp wiring, no graph-owned pixel-handle transport,
// no Dart visual pixel verification. No Phase 1 closure.

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

const _glTextureTarget2D = 3553; // GL_TEXTURE_2D (0x0DE1)
const _glTextureTargetOes = 36197; // GL_TEXTURE_EXTERNAL_OES (0x8D65)

class _SourceKindCase {
  const _SourceKindCase({required this.sourceKindA, required this.sourceKindB});

  final String sourceKindA;
  final String sourceKindB;

  int get expectedTargetA =>
      sourceKindA == 'oes' ? _glTextureTargetOes : _glTextureTarget2D;
  int get expectedTargetB =>
      sourceKindB == 'oes' ? _glTextureTargetOes : _glTextureTarget2D;
}

const _cases = <_SourceKindCase>[
  _SourceKindCase(sourceKindA: '2d', sourceKindB: '2d'),
  _SourceKindCase(sourceKindA: 'oes', sourceKindB: '2d'),
  _SourceKindCase(sourceKindA: '2d', sourceKindB: 'oes'),
  _SourceKindCase(sourceKindA: 'oes', sourceKindB: 'oes'),
];

void main() {
  runApp(const AndroidDagPhase1BEGlesTextureCompositionMixedTargetSmokeApp());
}

class AndroidDagPhase1BEGlesTextureCompositionMixedTargetSmokeApp
    extends StatefulWidget {
  const AndroidDagPhase1BEGlesTextureCompositionMixedTargetSmokeApp({
    super.key,
  });

  @override
  State<AndroidDagPhase1BEGlesTextureCompositionMixedTargetSmokeApp>
  createState() =>
      _AndroidDagPhase1BEGlesTextureCompositionMixedTargetSmokeAppState();
}

class _AndroidDagPhase1BEGlesTextureCompositionMixedTargetSmokeAppState
    extends State<AndroidDagPhase1BEGlesTextureCompositionMixedTargetSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _completeMethod =
      'onAndroidDagPhase1BBGlesTextureCompositionDagSmokeComplete';

  String _status =
      'Running Android DAG Phase 1BE GLES texture composition mixed target '
      'smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<Map<String, dynamic>> _runCase(_SourceKindCase testCase) async {
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
          'sourceKindA': testCase.sourceKindA,
          'sourceKindB': testCase.sourceKindB,
        },
      );

      final startMap = Map<String, dynamic>.from(startResponse! as Map);
      activeTextureId = (startMap['textureId'] as num?)?.toInt();

      if (mounted && activeTextureId != null) {
        setState(() {
          _textureId = activeTextureId;
          _status =
              'Rendering Android DAG Phase 1BE texture composition mixed '
              'target smoke (textureId=$activeTextureId, '
              'sourceKindA=${testCase.sourceKindA}, '
              'sourceKindB=${testCase.sourceKindB})…';
        });
      }

      completionPayload = await completer.future.timeout(
        const Duration(seconds: 15),
      );
      completionReached = true;
    } catch (error, stack) {
      print(
        'ANDROID_DAG_PHASE1BE_ERROR: '
        'sourceKindA=${testCase.sourceKindA} '
        'sourceKindB=${testCase.sourceKindB} '
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
        'sourceKindA': testCase.sourceKindA,
        'sourceKindB': testCase.sourceKindB,
        'targetA': -1,
        'targetB': -1,
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
        completionPayload['textureSurface'] == true &&
        completionPayload['releaseFenceExported'] == true &&
        completionPayload['compositorActive'] == true &&
        completionPayload['monotonicWeights'] == true &&
        (completionPayload['startWeightB'] as num?) == 0.0 &&
        (completionPayload['endWeightB'] as num?) == 1.0 &&
        completionPayload['proofBoundary'] == _proofBoundary &&
        lastErrorOk &&
        completionPayload['sourceKindA'] == testCase.sourceKindA &&
        completionPayload['sourceKindB'] == testCase.sourceKindB &&
        (completionPayload['targetA'] as num?) == testCase.expectedTargetA &&
        (completionPayload['targetB'] as num?) == testCase.expectedTargetB;

    final pass = completionOk && disposeOk;

    return <String, dynamic>{
      'sourceKindA': testCase.sourceKindA,
      'sourceKindB': testCase.sourceKindB,
      'expectedTargetA': testCase.expectedTargetA,
      'expectedTargetB': testCase.expectedTargetB,
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

    print('ANDROID_DAG_PHASE1BE_JSON:${jsonEncode(report)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE1BE_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE1BE_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: see ANDROID_DAG_PHASE1BE_JSON log';
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
