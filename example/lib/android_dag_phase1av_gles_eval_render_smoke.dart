import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase1AVGlesEvalRenderSmokeApp());
}

class AndroidDagPhase1AVGlesEvalRenderSmokeApp extends StatefulWidget {
  const AndroidDagPhase1AVGlesEvalRenderSmokeApp({super.key});

  @override
  State<AndroidDagPhase1AVGlesEvalRenderSmokeApp> createState() =>
      _AndroidDagPhase1AVGlesEvalRenderSmokeAppState();
}

class _AndroidDagPhase1AVGlesEvalRenderSmokeAppState
    extends State<AndroidDagPhase1AVGlesEvalRenderSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  static const _width = 64;
  static const _height = 64;
  static const _frameCount = 30;
  static const _frameDurationUs = 33333;
  String _status = 'Running Android DAG Phase 1AV GLES eval+render smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1AVGlesEvalRenderSmoke',
        const {
          'width': _width,
          'height': _height,
          'frameCount': _frameCount,
          'frameDurationUs': _frameDurationUs,
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error) {
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;error=${error.runtimeType}',
        'width': _width,
        'height': _height,
        'frameCount': _frameCount,
        'renderedFrames': 0,
        'evaluatedPtsUs': 0,
        'proofBoundary':
            'gles_dag_playhead_eval_multiframe_render_foundation_no_product_ui',
        'lastError': 'dart_invoke_exception',
      };
    }

    final expectedEvaluatedPtsUs = (_frameCount - 1) * _frameDurationUs;
    final lastError = payload['lastError'];
    final lastErrorOk =
        lastError == null || lastError == '' || lastError == 'none';
    final pass =
        payload['pass'] == true &&
        payload['renderedFrames'] == _frameCount &&
        payload['evaluatedPtsUs'] == expectedEvaluatedPtsUs &&
        payload['proofBoundary'] ==
            'gles_dag_playhead_eval_multiframe_render_foundation_no_product_ui' &&
        lastErrorOk;

    print('ANDROID_DAG_PHASE1AV_JSON:${jsonEncode(payload)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE1AV_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE1AV_PHYSICAL_SMOKE_FAIL',
    );
    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(body: Center(child: Text(_status))),
    );
  }
}
