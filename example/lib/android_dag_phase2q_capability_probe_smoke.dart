import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase2QCapabilityProbeSmokeApp());
}

class AndroidDagPhase2QCapabilityProbeSmokeApp extends StatefulWidget {
  const AndroidDagPhase2QCapabilityProbeSmokeApp({super.key});

  @override
  State<AndroidDagPhase2QCapabilityProbeSmokeApp> createState() =>
      _AndroidDagPhase2QCapabilityProbeSmokeAppState();
}

class _AndroidDagPhase2QCapabilityProbeSmokeAppState
    extends State<AndroidDagPhase2QCapabilityProbeSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Phase 2Q capability probe smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase2QCapabilityProbe',
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error) {
      payload = <String, dynamic>{
        'pass': false,
        'fallbackReason': 'exception:${error.runtimeType}',
        'profileGateStatus': 'probe_exception',
        'blacklistStatus': 'not_evaluated',
        'vulkanSupported': false,
        'selectedBackend': 2,
        'gpuVendor': '',
        'gpuRenderer': '',
        'vendorId': 0,
        'deviceId': 0,
        'apiVersion': 0,
        'vulkanDriverVersion': 0,
      };
    }

    final pass = payload['pass'] == true;
    print('ANDROID_DAG_PHASE2Q_JSON:${jsonEncode(payload)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE2Q_CAPABILITY_PROBE_PASS'
          : 'ANDROID_DAG_PHASE2Q_CAPABILITY_PROBE_FAIL',
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
