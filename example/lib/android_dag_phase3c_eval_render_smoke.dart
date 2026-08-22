import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase3CEvalRenderSmokeApp());
}

class AndroidDagPhase3CEvalRenderSmokeApp extends StatefulWidget {
  const AndroidDagPhase3CEvalRenderSmokeApp({super.key});

  @override
  State<AndroidDagPhase3CEvalRenderSmokeApp> createState() =>
      _AndroidDagPhase3CEvalRenderSmokeAppState();
}

class _AndroidDagPhase3CEvalRenderSmokeAppState
    extends State<AndroidDagPhase3CEvalRenderSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Phase 3C eval+render smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase3CEvalRenderSmoke',
        const {
          'width': 64,
          'height': 64,
          'frameCount': 30,
          'frameDurationUs': 33333,
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error) {
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;error=${error.runtimeType}',
        'width': 64,
        'height': 64,
        'frameCount': 30,
        'evaluatedPtsUs': 0,
      };
    }

    final pass = payload['pass'] == true;
    print('ANDROID_DAG_PHASE3C_JSON:${jsonEncode(payload)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE3C_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE3C_PHYSICAL_SMOKE_FAIL',
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
