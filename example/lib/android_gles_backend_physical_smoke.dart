import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesBackendPhysicalSmokeApp());
}

class AndroidGlesBackendPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesBackendPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesBackendPhysicalSmokeApp> createState() =>
      _AndroidGlesBackendPhysicalSmokeAppState();
}

class _AndroidGlesBackendPhysicalSmokeAppState
    extends State<AndroidGlesBackendPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android GLES backend Unit U physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1UGlesBackendSmoke',
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error) {
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'exception:${error.runtimeType}',
        'clientVersion': 0,
        'vendor': '',
        'renderer': '',
        'version': '',
        'initialize': 'exception:${error.runtimeType}',
        'idempotentInitialize': 'not_run',
        'clear': 'not_run',
        'swap': 'not_run',
        'hasSurface': false,
        'import': 'not_run',
        'renderFrame': 'not_run',
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'proofBoundary': 'offscreen_egl_pbuffer_no_window_surface',
      };
    }

    final passFlag = payload['pass'] == true;
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final initialize = payload['initialize'];
    final idempotentInitialize = payload['idempotentInitialize'];
    final clear = payload['clear'];
    final swap = payload['swap'];
    final hasSurface = payload['hasSurface'] == true;
    final importResult = (payload['import'] as String?) ?? '';
    final renderFrameResult = (payload['renderFrame'] as String?) ?? '';
    final shutdown = payload['shutdown'];
    final idempotentShutdown = payload['idempotentShutdown'];
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';

    final isPass =
        passFlag &&
        clientVersion >= 2 &&
        vendor.isNotEmpty &&
        renderer.isNotEmpty &&
        version.isNotEmpty &&
        (initialize == 'success' || initialize == true) &&
        (idempotentInitialize == 'success' || idempotentInitialize == true) &&
        (clear == 'success' || clear == true) &&
        (swap == 'success' || swap == true) &&
        !hasSurface &&
        importResult == 'unavailable' &&
        renderFrameResult == 'unavailable' &&
        (shutdown == 'success' || shutdown == true) &&
        (idempotentShutdown == 'success' || idempotentShutdown == true) &&
        proofBoundary == 'offscreen_egl_pbuffer_no_window_surface';

    // ignore: avoid_print
    print('ANDROID_GLES_BACKEND_UNIT_U_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_BACKEND_UNIT_U_PHYSICAL_PASS'
          : 'ANDROID_GLES_BACKEND_UNIT_U_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = isPass ? 'PASS' : 'FAIL';
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
