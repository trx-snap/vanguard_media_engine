// Vanguard Android True-DAG Phase 1-Unit BC: Android GLES SurfaceProducer
// Texture DAG Two-Source Composition Active Dispose & Cancellation Physical
// Proof.
//
// Route:
//   Reuses the Phase 1-Unit BB bridge/native route
//   (startAndroidDagPhase1BBGlesTextureCompositionDagSmoke /
//   disposeAndroidDagPhase1BBGlesTextureCompositionDagSmoke /
//   onAndroidDagPhase1BBGlesTextureCompositionDagSmokeComplete), extended
//   with a diagnostic-only frameDelayMs so a dispose() call can be proven to
//   land while the background two-source composition render worker is still
//   active, matching the Unit AY active-dispose pattern.
//
// Dart responsibilities:
//   - Start the smoke with frameCount=5, frameDelayMs=500 (worker stays
//     active for well over 500ms).
//   - Mount Texture(textureId) once start returns.
//   - Wait 500ms, then dispose while the worker is still active; assert the
//     dispose response has pass=true, surfaceProducerReleased=false, and a
//     raw string containing "dispose_requested_pending_completion" — proof
//     that runCompleted was false at dispose time.
//   - Await the completion callback with a bounded timeout; gate PASS on
//     pass==true, a matching textureId, successful
//     initialize/attach/graphBuild/importA/importB/evaluation/renderFrame/
//     releaseA/releaseB, renderedFrames==5, frameCount==5, frameDelayMs==500,
//     textureSurface==true, releaseFenceExported==true,
//     compositorActive==true, monotonicWeights==true, startWeightB==0.0,
//     endWeightB==1.0, the exact proofBoundary string, an empty/none
//     lastError, and surfaceProducerReleased==true.
//   - Print ANDROID_DAG_PHASE1BC_JSON:<json> and
//     ANDROID_DAG_PHASE1BC_PHYSICAL_SMOKE_PASS/FAIL.
//
// Non-claims: no decoded input, no ImageReader.PRIVATE, no product UI, no
// ConnectsApp wiring, no graph-owned pixel handle transport, no preemptive
// native thread interruption (the native loop finishes its delayed
// iterations safely, as Unit AY did). No Phase 1 closure.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _proofBoundary =
    'gles_surfaceproducer_texture_dag_two_source_composition_no_decoded_input_no_product_ui';

void main() {
  runApp(const AndroidDagPhase1BCGlesTextureCompositionActiveDisposeSmokeApp());
}

class AndroidDagPhase1BCGlesTextureCompositionActiveDisposeSmokeApp
    extends StatefulWidget {
  const AndroidDagPhase1BCGlesTextureCompositionActiveDisposeSmokeApp({
    super.key,
  });

  @override
  State<AndroidDagPhase1BCGlesTextureCompositionActiveDisposeSmokeApp>
  createState() =>
      _AndroidDagPhase1BCGlesTextureCompositionActiveDisposeSmokeAppState();
}

class _AndroidDagPhase1BCGlesTextureCompositionActiveDisposeSmokeAppState
    extends
        State<AndroidDagPhase1BCGlesTextureCompositionActiveDisposeSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _completeMethod =
      'onAndroidDagPhase1BBGlesTextureCompositionDagSmokeComplete';
  static const _width = 64;
  static const _height = 64;
  static const _frameCount = 5;
  static const _frameDurationUs = 33333;
  static const _frameDelayMs = 500;

  String _status =
      'Running Android DAG Phase 1BC GLES texture composition active-dispose smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    int? activeTextureId;
    var startPayload = <String, dynamic>{};
    var disposePayload = <String, dynamic>{};
    var completionPayload = <String, dynamic>{};
    var disposeAttempted = false;
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
        const {
          'width': _width,
          'height': _height,
          'frameCount': _frameCount,
          'frameDurationUs': _frameDurationUs,
          'frameDelayMs': _frameDelayMs,
        },
      );

      startPayload = Map<String, dynamic>.from(startResponse! as Map);
      activeTextureId = (startPayload['textureId'] as num?)?.toInt();

      if (mounted && activeTextureId != null) {
        setState(() {
          _textureId = activeTextureId;
          _status =
              'Rendering Android DAG Phase 1BC texture composition smoke (textureId=$activeTextureId)…';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));

      if (activeTextureId != null) {
        disposeAttempted = true;
        final disposeResponse = await _channel.invokeMethod<Object?>(
          'disposeAndroidDagPhase1BBGlesTextureCompositionDagSmoke',
          <String, Object>{'textureId': activeTextureId},
        );
        disposePayload = Map<String, dynamic>.from(disposeResponse! as Map);
      }

      completionPayload = await completer.future.timeout(
        const Duration(seconds: 15),
      );
      completionReached = true;
    } catch (error, stack) {
      print('ANDROID_DAG_PHASE1BC_ERROR: $error\n$stack');
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
      };
    } finally {
      _channel.setMethodCallHandler(null);
      if (!completionReached || !disposeAttempted) {
        if (activeTextureId != null) {
          try {
            await _channel.invokeMethod<Object?>(
              'disposeAndroidDagPhase1BBGlesTextureCompositionDagSmoke',
              <String, Object>{'textureId': activeTextureId},
            );
          } catch (_) {}
        }
      }
    }

    final disposeRaw = disposePayload['raw']?.toString() ?? '';
    final disposeOk =
        disposeAttempted &&
        disposePayload['pass'] == true &&
        disposePayload['surfaceProducerReleased'] == false &&
        disposeRaw.contains('dispose_requested_pending_completion');

    final completionTextureId = (completionPayload['textureId'] as num?)
        ?.toInt();
    final lastError = completionPayload['lastError'];
    final lastErrorOk =
        lastError == null || lastError == '' || lastError == 'none';

    final completionOk =
        completionReached &&
        completionPayload['pass'] == true &&
        completionTextureId != null &&
        completionTextureId >= 0 &&
        completionTextureId == activeTextureId &&
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
        completionPayload['surfaceProducerReleased'] == true;

    final pass = disposeOk && completionOk;

    final report = <String, dynamic>{
      'start': startPayload,
      'dispose': disposePayload,
      'completion': completionPayload,
      'pass': pass,
    };

    print('ANDROID_DAG_PHASE1BC_JSON:${jsonEncode(report)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE1BC_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE1BC_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: ${completionPayload['raw']}';
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
