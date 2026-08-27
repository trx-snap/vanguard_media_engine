// Vanguard Android True-DAG Phase 1-Unit BA: Android GLES SurfaceProducer
// Two-Texture Composition Physical Proof.
//
// Route:
//   startAndroidDagPhase1BAGlesTextureCompositorSmoke /
//   disposeAndroidDagPhase1BAGlesTextureCompositorSmoke /
//   onAndroidDagPhase1BAGlesTextureCompositorSmokeComplete.
//
//   Runs the existing Phase 1-Unit AS (two-texture RGBA compositor) and
//   Phase 1-Unit AT (mixed external/OES compositor) native proofs against a
//   single real Flutter TextureRegistry.SurfaceProducer surface, sequentially
//   on one background thread, and reports one combined BA callback.
//
// Dart responsibilities:
//   - Start the smoke with width=64, height=64.
//   - Mount Texture(textureId) once start returns, while awaiting the
//     completion callback.
//   - Await the completion callback with a bounded timeout; validate both
//     the AS and AT result maps (initialize/attach/composite/release
//     lifecycle fields and their proof boundaries) plus the BA-level
//     pass/proofBoundary/surfaceProducerReleased fields.
//   - Dispose in `finally` and include the dispose result in the report.
//   - Print ANDROID_DAG_PHASE1BA_JSON:<json> and
//     ANDROID_DAG_PHASE1BA_PHYSICAL_SMOKE_PASS/FAIL.
//
// Non-claims: no MediaCodec decoded input, no product UI, no ConnectsApp
// wiring, no Phase 1 closure.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _baProofBoundary =
    'gles_surfaceproducer_two_texture_compositor_foundation_no_decoded_input_no_product_ui';
const _asProofBoundary =
    'gles_two_texture_compositor_rgba_blend_foundation_at_compatible_no_color_conversion_no_product';
const _atProofBoundary =
    'gles_mixed_texture_compositor_oes_permutation_foundation_no_color_conversion_no_product';

void main() {
  runApp(const AndroidDagPhase1BAGlesTextureCompositorSmokeApp());
}

class AndroidDagPhase1BAGlesTextureCompositorSmokeApp extends StatefulWidget {
  const AndroidDagPhase1BAGlesTextureCompositorSmokeApp({super.key});

  @override
  State<AndroidDagPhase1BAGlesTextureCompositorSmokeApp> createState() =>
      _AndroidDagPhase1BAGlesTextureCompositorSmokeAppState();
}

class _AndroidDagPhase1BAGlesTextureCompositorSmokeAppState
    extends State<AndroidDagPhase1BAGlesTextureCompositorSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _startMethod =
      'startAndroidDagPhase1BAGlesTextureCompositorSmoke';
  static const _disposeMethod =
      'disposeAndroidDagPhase1BAGlesTextureCompositorSmoke';
  static const _completeMethod =
      'onAndroidDagPhase1BAGlesTextureCompositorSmokeComplete';
  static const _width = 64;
  static const _height = 64;

  String _status =
      'Running Android DAG Phase 1BA GLES texture compositor smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  bool _isSuccess(Map<String, dynamic> result, String key) =>
      result[key] == 'success';

  bool _validateAsResult(Map<String, dynamic> as) {
    return as['pass'] == true &&
        _isSuccess(as, 'initialize') &&
        _isSuccess(as, 'attach') &&
        _isSuccess(as, 'presentComposite') &&
        _isSuccess(as, 'releaseBufferA') &&
        _isSuccess(as, 'releaseBufferB') &&
        _isSuccess(as, 'detach') &&
        _isSuccess(as, 'shutdown') &&
        as['proofBoundary'] == _asProofBoundary;
  }

  bool _validateAtResult(Map<String, dynamic> at) {
    return at['pass'] == true &&
        _isSuccess(at, 'initialize') &&
        _isSuccess(at, 'attach') &&
        _isSuccess(at, 'twoDTwoDComposite') &&
        _isSuccess(at, 'oesTwoDComposite') &&
        _isSuccess(at, 'twoDOesComposite') &&
        _isSuccess(at, 'oesOesComposite') &&
        _isSuccess(at, 'releaseBufferA') &&
        _isSuccess(at, 'releaseBufferB') &&
        _isSuccess(at, 'releaseYcbcrA') &&
        _isSuccess(at, 'releaseYcbcrB') &&
        _isSuccess(at, 'detach') &&
        _isSuccess(at, 'shutdown') &&
        at['proofBoundary'] == _atProofBoundary;
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
      final startResponse = await _channel.invokeMethod<Object?>(
        _startMethod,
        const {'width': _width, 'height': _height},
      );

      startPayload = Map<String, dynamic>.from(startResponse! as Map);
      activeTextureId = (startPayload['textureId'] as num?)?.toInt();

      if (mounted && activeTextureId != null) {
        setState(() {
          _textureId = activeTextureId;
          _status =
              'Compositing Android DAG Phase 1BA texture smoke (textureId=$activeTextureId)…';
        });
      }

      completionPayload = await completer.future.timeout(
        const Duration(seconds: 20),
      );
      completionReached = true;
    } catch (error, stack) {
      print('ANDROID_DAG_PHASE1BA_ERROR: $error\n$stack');
      completionPayload = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;lastError=dart_invoke_exception',
        'textureId': activeTextureId,
        'width': _width,
        'height': _height,
        'asResult': <String, dynamic>{'pass': false},
        'atResult': <String, dynamic>{'pass': false},
        'proofBoundary': _baProofBoundary,
        'surfaceProducerReleased': false,
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

    final asResult = completionPayload['asResult'] is Map
        ? Map<String, dynamic>.from(completionPayload['asResult'] as Map)
        : <String, dynamic>{};
    final atResult = completionPayload['atResult'] is Map
        ? Map<String, dynamic>.from(completionPayload['atResult'] as Map)
        : <String, dynamic>{};

    final completionTextureId = (completionPayload['textureId'] as num?)
        ?.toInt();

    final disposeRaw = disposePayload['raw'];
    final disposeOk =
        disposePayload['pass'] == true &&
        disposePayload['surfaceProducerReleased'] == true &&
        disposeRaw is String &&
        disposeRaw.contains('status=OK;disposed=true');

    final completionOk =
        completionReached &&
        completionPayload['pass'] == true &&
        completionTextureId != null &&
        completionTextureId == activeTextureId &&
        completionPayload['width'] == _width &&
        completionPayload['height'] == _height &&
        completionPayload['proofBoundary'] == _baProofBoundary &&
        completionPayload['surfaceProducerReleased'] == false &&
        _validateAsResult(asResult) &&
        _validateAtResult(atResult);

    final pass = completionOk && disposeOk;

    final report = <String, dynamic>{
      'start': startPayload,
      'completion': completionPayload,
      'dispose': disposePayload,
      'pass': pass,
    };

    print('ANDROID_DAG_PHASE1BA_JSON:${jsonEncode(report)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE1BA_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE1BA_PHYSICAL_SMOKE_FAIL',
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
