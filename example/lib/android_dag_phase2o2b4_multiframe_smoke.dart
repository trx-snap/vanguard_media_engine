import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagMultiFrameSmokeApp());
}

class AndroidDagMultiFrameSmokeApp extends StatefulWidget {
  const AndroidDagMultiFrameSmokeApp({super.key});

  @override
  State<AndroidDagMultiFrameSmokeApp> createState() =>
      _AndroidDagMultiFrameSmokeAppState();
}

class _AndroidDagMultiFrameSmokeAppState
    extends State<AndroidDagMultiFrameSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Phase 2O2B4 multi-frame smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase2O2B4MultiFrameSmoke',
        const {'width': 64, 'height': 64, 'frameCount': 30},
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error) {
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'status=FAIL;error=${error.runtimeType}',
        'width': 64,
        'height': 64,
        'frameCount': 30,
      };
    }

    final pass = payload['pass'] == true;
    print('ANDROID_DAG_PHASE2O2B4_JSON:${jsonEncode(payload)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE2O2B4_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE2O2B4_PHYSICAL_SMOKE_FAIL',
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
      home: Scaffold(
        body: Center(child: Text(_status)),
      ),
    );
  }
}
