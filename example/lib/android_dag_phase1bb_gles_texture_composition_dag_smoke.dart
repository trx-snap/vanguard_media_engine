// Vanguard Android True-DAG Phase 1-Unit BB: Android GLES SurfaceProducer
// Texture DAG Two-Source Composition & Playhead Evaluation Physical Proof.
//
// Route:
//   startAndroidDagPhase1BBGlesTextureCompositionDagSmoke /
//   disposeAndroidDagPhase1BBGlesTextureCompositionDagSmoke /
//   onAndroidDagPhase1BBGlesTextureCompositionDagSmokeComplete.
//
//   Two synthetic RGBA HardwareBuffer sources (solid red / solid blue) ->
//   native diagnostic DAG (source A + source B -> compositor -> sink) ->
//   per-frame Graph::evaluatePlayhead() gating + compositor blend-weight
//   extraction -> GlesBackend::diagnosticPresentCompositeFrames() onto a
//   real Flutter TextureRegistry.SurfaceProducer texture.
//
// Dart responsibilities:
//   - Start the smoke with width=64, height=64, frameCount=30,
//     frameDurationUs=33333.
//   - Mount Texture(textureId) once start returns, while awaiting the
//     completion callback.
//   - Await the completion callback with a bounded timeout; validate
//     pass/textureId/surfaceProducerReleased plus the native status fields
//     (renderedFrames, frameCount, textureSurface, releaseFenceExported,
//     compositorActive, monotonicWeights, startWeightB/endWeightB,
//     proofBoundary, lastError).
//   - Dispose in `finally`; require pass=true, surfaceProducerReleased=true,
//     and the dispose raw string to contain status=OK;disposed=true.
//   - Print ANDROID_DAG_PHASE1BB_JSON:<json> and
//     ANDROID_DAG_PHASE1BB_PHYSICAL_SMOKE_PASS/FAIL.
//
// Non-claims: no MediaCodec decoded input, no ImageReader.PRIVATE, no
// product UI, no ConnectsApp wiring, no Phase 1 closure.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _proofBoundary =
    'gles_surfaceproducer_texture_dag_two_source_composition_no_decoded_input_no_product_ui';

void main() {
  runApp(const AndroidDagPhase1BBGlesTextureCompositionDagSmokeApp());
}

class AndroidDagPhase1BBGlesTextureCompositionDagSmokeApp
    extends StatefulWidget {
  const AndroidDagPhase1BBGlesTextureCompositionDagSmokeApp({super.key});

  @override
  State<AndroidDagPhase1BBGlesTextureCompositionDagSmokeApp> createState() =>
      _AndroidDagPhase1BBGlesTextureCompositionDagSmokeAppState();
}

class _AndroidDagPhase1BBGlesTextureCompositionDagSmokeAppState
    extends State<AndroidDagPhase1BBGlesTextureCompositionDagSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _startMethod =
      'startAndroidDagPhase1BBGlesTextureCompositionDagSmoke';
  static const _disposeMethod =
      'disposeAndroidDagPhase1BBGlesTextureCompositionDagSmoke';
  static const _completeMethod =
      'onAndroidDagPhase1BBGlesTextureCompositionDagSmokeComplete';
  static const _width = 64;
  static const _height = 64;
  static const _frameCount = 30;
  static const _frameDurationUs = 33333;

  String _status =
      'Running Android DAG Phase 1BB GLES texture composition DAG smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  bool _isSuccess(Map<String, dynamic> result, String key) =>
      result[key] == 'success';

  bool _isClose(Object? value, double expected, {double epsilon = 0.01}) {
    final numeric = value is num ? value.toDouble() : null;
    if (numeric == null) return false;
    return (numeric - expected).abs() <= epsilon;
  }

  Future<void> _runSmoke() async {
    int? activeTextureId;
    var startPayload = <String, dynamic>{};
    var disposePayload = <String, dynamic>{};
    var completionPayload = <String, dynamic>{};
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
      final startResponse = await _channel
          .invokeMethod<Object?>(_startMethod, const {
            'width': _width,
            'height': _height,
            'frameCount': _frameCount,
            'frameDurationUs': _frameDurationUs,
          });

      startPayload = Map<String, dynamic>.from(startResponse! as Map);
      activeTextureId = (startPayload['textureId'] as num?)?.toInt();

      if (mounted && activeTextureId != null) {
        setState(() {
          _textureId = activeTextureId;
          _status =
              'Compositing Android DAG Phase 1BB texture smoke (textureId=$activeTextureId)…';
        });
      }

      completionPayload = await completer.future.timeout(
        const Duration(seconds: 20),
      );
      completionReached = true;
    } catch (error, stack) {
      print('ANDROID_DAG_PHASE1BB_ERROR: $error\n$stack');
      completionPayload = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;lastError=dart_invoke_exception',
        'textureId': activeTextureId,
        'width': _width,
        'height': _height,
        'frameCount': _frameCount,
        'renderedFrames': 0,
        'proofBoundary': _proofBoundary,
        'surfaceProducerReleased': false,
        'lastError': 'dart_invoke_exception',
      };
    } finally {
      _channel.setMethodCallHandler(null);
      if (activeTextureId != null) {
        try {
          final disposeResponse = await _channel.invokeMethod<Object?>(
            _disposeMethod,
            <String, Object>{'textureId': activeTextureId},
          );
          disposePayload = Map<String, dynamic>.from(disposeResponse! as Map);
        } catch (_) {}
      }
    }

    final completionTextureId = (completionPayload['textureId'] as num?)
        ?.toInt();

    final lastError = completionPayload['lastError'];
    final lastErrorOk =
        lastError == null || lastError == '' || lastError == 'none';

    final completionOk =
        completionReached &&
        completionPayload['pass'] == true &&
        completionTextureId != null &&
        completionTextureId == activeTextureId &&
        completionPayload['surfaceProducerReleased'] == false &&
        _isSuccess(completionPayload, 'initialize') &&
        _isSuccess(completionPayload, 'attach') &&
        _isSuccess(completionPayload, 'graphBuild') &&
        _isSuccess(completionPayload, 'importA') &&
        _isSuccess(completionPayload, 'importB') &&
        _isSuccess(completionPayload, 'evaluation') &&
        _isSuccess(completionPayload, 'renderFrame') &&
        _isSuccess(completionPayload, 'releaseA') &&
        _isSuccess(completionPayload, 'releaseB') &&
        completionPayload['renderedFrames'] == _frameCount &&
        completionPayload['frameCount'] == _frameCount &&
        completionPayload['textureSurface'] == true &&
        completionPayload['releaseFenceExported'] == true &&
        completionPayload['compositorActive'] == true &&
        completionPayload['monotonicWeights'] == true &&
        _isClose(completionPayload['startWeightB'], 0.0) &&
        _isClose(completionPayload['endWeightB'], 1.0) &&
        completionPayload['proofBoundary'] == _proofBoundary &&
        lastErrorOk;

    final disposeRaw = disposePayload['raw'];
    final disposeOk =
        disposePayload['pass'] == true &&
        disposePayload['surfaceProducerReleased'] == true &&
        disposeRaw is String &&
        disposeRaw.contains('status=OK;disposed=true');

    final pass = completionOk && disposeOk;

    final report = <String, dynamic>{
      'start': startPayload,
      'completion': completionPayload,
      'dispose': disposePayload,
      'pass': pass,
    };

    print('ANDROID_DAG_PHASE1BB_JSON:${jsonEncode(report)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE1BB_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE1BB_PHYSICAL_SMOKE_FAIL',
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
